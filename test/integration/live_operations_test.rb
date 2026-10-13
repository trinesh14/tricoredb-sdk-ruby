# frozen_string_literal: true

require_relative "../test_helper"

# The operations added for server 0.1.0-rc.3, against a real server.
#
# Run with `rake test:integration`. Without a server every test skips.
class LiveOperationsTest < Minitest::Test
  def setup
    reason = LiveServer.skip_reason
    skip reason if reason

    @server = LiveServer.shared
    @db = @server.connect
  end

  def teardown
    @db&.close
  rescue StandardError
    nil
  end

  def test_a_nested_begin_opens_a_block_the_outer_transaction_outlives
    table = unique("rb_nested")
    @db.execute("CREATE TABLE #{table} (id INT PRIMARY KEY, n INT)")

    @db.begin_transaction
    @db.execute("INSERT INTO #{table} VALUES (?, ?)", [1, 1])
    assert_equal 1, @db.begin_transaction["nested_depth"]
    @db.execute("INSERT INTO #{table} VALUES (?, ?)", [2, 2])
    @db.rollback
    assert @db.in_transaction?, "the rollback ended the inner block, not the transaction"

    @db.begin_transaction
    @db.execute("INSERT INTO #{table} VALUES (?, ?)", [3, 3])
    @db.commit
    assert @db.in_transaction?, "the commit released the inner block, not the transaction"

    @db.commit
    refute @db.in_transaction?
    assert_equal [["1"], ["3"]], @db.query("SELECT id FROM #{table} ORDER BY id").rows
    @db.execute("DROP TABLE #{table}")
  end

  def test_sorted_sets_rank_range_and_rescore_their_members
    ns = unique("rb_zset")
    assert_equal 3, @db.cache_zadd(ns, "z", { "a" => 1.5, "b" => 2, "c" => 3 })["added"]
    assert_equal 3, @db.cache_zcard(ns, "z")
    assert_equal 1.5, @db.cache_zscore(ns, "z", "a")
    assert_nil @db.cache_zscore(ns, "z", "nobody")
    assert_equal 1, @db.cache_zrank(ns, "z", "b")
    assert_equal 0, @db.cache_zrank(ns, "z", "c", rev: true)
    assert_nil @db.cache_zrank(ns, "z", "nobody")

    assert_equal [["a", 1.5], ["b", 2.0], ["c", 3.0]], @db.cache_zrange(ns, "z", 0, -1, with_scores: true)
    assert_equal ["c"], @db.cache_zrange(ns, "z", 0, 0, rev: true)
    middle = @db.cache_zrangebyscore(ns, "z", TriCoreDB::ScoreBound.exclusive(1.5), TriCoreDB::ScoreBound.highest,
                                     limit: [0, 1])
    assert_equal ["b"], middle
    assert_equal 3, @db.cache_zrangebyscore(ns, "z", TriCoreDB::ScoreBound.lowest, 3).size

    assert_equal 3.75, @db.cache_zincrby(ns, "z", "a", 2.25)
    assert_equal 1, @db.cache_zrem(ns, "z", %w[c nobody])
  end

  def test_a_lock_has_one_holder_and_a_token_that_only_rises
    ns = unique("rb_lock")
    first = @db.cache_lock_acquire(ns, "job", "worker-1", 30_000)
    assert first["acquired"]
    second = @db.cache_lock_acquire(ns, "job", "worker-2", 30_000)
    refute second["acquired"]
    assert_equal "worker-1", second["holder"]
    renewed = @db.cache_lock_renew(ns, "job", "worker-1", 30_000)
    assert renewed["renewed"]
    assert_equal first["token"], renewed["token"]
    refute @db.cache_lock_release(ns, "job", "worker-2")
    assert @db.cache_lock_release(ns, "job", "worker-1")
    assert_operator @db.cache_lock_acquire(ns, "job", "worker-2", 30_000)["token"], :>, first["token"]
  end

  def test_bitmaps_and_hyperloglogs
    ns = unique("rb_bits")
    assert_equal 0, @db.cache_setbit(ns, "a", 7, true)
    assert_equal 1, @db.cache_setbit(ns, "a", 7, true)
    assert_equal 1, @db.cache_getbit(ns, "a", 7)
    assert_equal 0, @db.cache_getbit(ns, "a", 6)
    assert_equal 1, @db.cache_bitcount(ns, "a")
    assert_equal 1, @db.cache_bitcount(ns, "a", range: [0, 0])
    assert_equal 7, @db.cache_bitpos(ns, "a", true)
    @db.cache_setbit(ns, "b", 0, true)
    assert_equal 1, @db.cache_bitop(ns, "Or", "c", %w[a b])
    assert_equal "\x81".b, @db.cache_get(ns, "c")

    assert @db.cache_pfadd(ns, "x", %w[a b c])
    @db.cache_pfadd(ns, "y", %w[c d])
    assert_equal 3, @db.cache_pfcount(ns, ["x"])
    assert_equal 4, @db.cache_pfcount(ns, %w[x y])
    @db.cache_pfmerge(ns, "all", %w[x y])
    assert_equal 4, @db.cache_pfcount(ns, ["all"])
  end

  def test_many_keys_conditional_writes_and_atomic_read_and_change
    ns = unique("rb_multi")
    assert_equal 2, @db.cache_mset(ns, { "a" => "1", "b" => "2" })
    assert_equal ["1", nil, "2", "1"], @db.cache_mget(ns, %w[a missing b a])
    warmed = @db.cache_warm(ns, { "a" => "other", "c" => "3" })
    assert_equal [1, 1], [warmed["written"], warmed["alreadyCached"]]

    refute @db.cache_set_if(ns, "k", "v1", condition: "IfPresent")
    assert @db.cache_set_if(ns, "k", "v1", condition: "IfAbsent")
    assert @db.cache_set_if(ns, "k", "v2", condition: "IfPresent", expiry: TriCoreDB::CacheExpiry.set(300_000))
    refute_nil @db.cache_ttl(ns, "k")
    assert_equal "v2", @db.cache_getex(ns, "k", TriCoreDB::CacheExpiry.clear)
    assert_nil @db.cache_ttl(ns, "k")
    assert_equal "v2", @db.cache_getset(ns, "k", "v3")
    assert_equal 3, @db.cache_append(ns, "k", "!")
    assert_equal "v3!", @db.cache_getdel(ns, "k")
    assert_nil @db.cache_getdel(ns, "k")

    assert @db.cache_compare_and_swap(ns, "cas", nil, "one")["swapped"]
    lost = @db.cache_compare_and_swap(ns, "cas", "wrong", "two")
    refute lost["swapped"]
    assert_equal "one", lost["current"]
    assert @db.cache_compare_and_swap(ns, "cas", "one", nil)["swapped"]
    refute @db.cache_exists?(ns, "cas")

    at = ((Time.now.to_f + 300) * 1000).to_i
    @db.cache_set(ns, "e", "x")
    assert @db.cache_expire_at(ns, "e", at)["updated"]
    refute @db.cache_expire_at(ns, "nokey", at)["updated"]
  end

  def test_fresh_stale_missing_and_miss_are_told_apart
    ns = unique("rb_fresh")
    miss = @db.cache_get_fresh(ns, "k", "me", 5000)
    assert_equal "miss", miss["state"]
    assert miss["lease"], "the first caller computes the value"
    refute @db.cache_get_fresh(ns, "k", "you", 5000)["lease"]

    assert_operator @db.cache_set_fresh(ns, "k", "v", 60_000), :>, (Time.now.to_f * 1000).to_i
    fresh = @db.cache_get_fresh(ns, "k", "me", 5000)
    assert_equal %w[fresh v], [fresh["state"], fresh["value"]]

    binary = [0, 159, 146, 150].pack("C*")
    @db.cache_set_fresh(ns, "bin", binary, 60_000)
    assert_equal binary, @db.cache_get_fresh(ns, "bin", "me", 5000)["value"]

    @db.cache_set_fresh(ns, "old", "v", 1, ttl_ms: 60_000)
    sleep 0.05
    stale = @db.cache_get_fresh(ns, "old", "me", 5000)
    assert_equal "stale", stale["state"]
    assert stale["refresh"]

    @db.cache_set_missing(ns, "gone", 60_000)
    assert_equal "missing", @db.cache_get_fresh(ns, "gone", "me", 5000)["state"]
  end

  def test_lists_move_trim_and_pop_with_a_wait_and_sets_combine
    ns = unique("rb_coll")
    @db.cache_rpush(ns, "src", %w[a b c])
    assert_equal "a", @db.cache_lmove(ns, "src", "dst", "Left", "Right")
    assert_nil @db.cache_lmove(ns, "none", "dst", "Left", "Right")
    assert_equal 1, @db.cache_ltrim(ns, "src", 0, 0)["length"]
    assert_equal %w[dst a], @db.cache_blpop(ns, %w[empty dst], 100)
    assert_nil @db.cache_brpop(ns, ["empty"], 100)

    @db.cache_sadd(ns, "s1", %w[a b])
    @db.cache_sadd(ns, "s2", %w[b c])
    assert_equal %w[a b c], @db.cache_sunion(ns, %w[s1 s2])
    assert_equal ["b"], @db.cache_sinter(ns, %w[s1 s2])
    assert_equal ["a"], @db.cache_sdiff(ns, %w[s1 s2])
    assert_equal 1, @db.cache_srandmember(ns, "s1").size
    assert_equal 5, @db.cache_srandmember(ns, "s1", count: -5).size
    assert_equal 5, @db.cache_hincrby(ns, "h", "n", 5)
    assert_equal 3, @db.cache_hincrby(ns, "h", "n", -2)
  end

  def test_a_pipeline_a_transaction_and_a_script_report_each_operation
    ns = unique("rb_pipe")
    results = @db.cache_pipeline([
                                   TriCoreDB::CacheOp.set(ns, "k", "x"),
                                   TriCoreDB::CacheOp.get(ns, "k"),
                                   TriCoreDB::CacheOp.incr(ns, "k"),
                                   TriCoreDB::CacheOp.exists(ns, "k"),
                                   TriCoreDB::CacheOp.ping
                                 ])
    assert_equal 5, results.size
    assert_equal({ "Json" => { "set" => true } }, results[0]["ok"])
    assert_equal "x".bytes, results[1]["ok"]["CacheValue"]
    assert_match(/not a valid i64/, results[2]["error"])
    assert results[3]["ok"]["Json"]["exists"], "a failing operation does not stop the rest"

    atomic = @db.cache_transaction([TriCoreDB::CacheOp.set(ns, "n", "1"), TriCoreDB::CacheOp.incr(ns, "n", 4)])
    assert_equal 5, atomic[1]["ok"]["Json"]["value"]

    script = unique("rb_script")
    @db.cache_script_load(script, [TriCoreDB::CacheOp.set(ns, "$1", "$2"), TriCoreDB::CacheOp.get(ns, "$1")])
    ran = @db.cache_script_run(script, args: %w[sk sv])
    assert_equal "sv".bytes, ran[1]["ok"]["CacheValue"]
    assert_equal "sv", @db.cache_get(ns, "sk")
  end

  def test_published_messages_are_polled_and_limits_and_stats_are_reported
    channel = unique("rb_channel")
    first = @db.cache_publish(channel, "hello")
    second = @db.cache_publish(channel, "again")
    polled = @db.cache_poll([channel], after: first - 1)
    assert_equal %w[hello again], polled["messages"].map { |m| m["message"] }
    assert_equal second, polled["next"]
    assert_empty @db.cache_poll([channel], after: second, limit: 10)["messages"]

    ns = unique("rb_limit")
    assert_equal 1, @db.cache_set_namespace_limit(ns, max_keys: 1)["max_keys"]
    @db.cache_set(ns, "a", "x")
    assert_raises(TriCoreDB::ServerError) { @db.cache_set(ns, "b", "x") }
    assert_equal 1, @db.cache_get_namespace_limit(ns)["keys"]
    assert_nil @db.cache_set_namespace_limit(ns)["max_keys"]
    @db.cache_set(ns, "b", "x")

    assert_kind_of Integer, @db.cache_stats["hits"]
  end

  def test_a_database_of_its_own_is_purged_and_flushed_and_hot_keys_need_tracking
    # These two act on a whole database, so they get one nobody else uses.
    database = unique("rb_db")
    @db.cache_set("n", "keep", "x", database: database)
    @db.cache_set("n", "gone", "x", ttl_ms: 1, database: database)
    sleep 0.05
    assert_equal 1, @db.cache_purge_expired(database: database)
    assert_equal 1, @db.cache_flush_database(database: database)
    refute @db.cache_exists?("n", "keep", database: database)

    begin
      assert_kind_of Hash, @db.cache_hot_keys(limit: 3)
    rescue TriCoreDB::ServerError => e
      assert_match(/tracking is off/, e.message)
    end
  end

  def test_documents_are_written_in_bulk_replaced_and_deleted_by_filter
    collection = unique("rb_docs")
    @db.doc_create_collection(collection)
    ids = @db.doc_insert_many(collection, [{ "_id" => "a", "n" => 1, "city" => "Pune" }, { "n" => 2, "city" => "Pune" },
                                           { "_id" => "c", "n" => 3, "city" => "Delhi" }])
    assert_equal 3, ids.size
    assert_equal "a", ids.first

    replaced = @db.doc_replace(collection, "a", { "n" => 10 }, return_document: "After")
    assert_equal({ "_id" => "a", "n" => 10 }, replaced["document"])
    refute @db.doc_get(collection, "a").key?("city"), "a replace keeps nothing of the old body"
    assert_raises(TriCoreDB::ServerError) { @db.doc_replace(collection, "nobody", { "n" => 1 }) }
    assert @db.doc_replace(collection, "new", { "n" => 5 }, upsert: true)["inserted"]

    bulk = @db.doc_bulk_write(collection, [
                                TriCoreDB::BulkOp.insert({ "n" => 1 }, id: "b1"),
                                TriCoreDB::BulkOp.insert({ "n" => 2 }),
                                TriCoreDB::BulkOp.update_one("b1", set: { "n" => 5 }, inc: { "m" => 1 }),
                                TriCoreDB::BulkOp.update_one("b9", set: { "n" => 9 }, upsert: true),
                                TriCoreDB::BulkOp.replace("a", { "n" => 7 }),
                                TriCoreDB::BulkOp.delete("new")
                              ])
    assert_equal [2, 1, 1, 1, 1], bulk.values_at("inserted", "updated", "upserted", "replaced", "deleted")
    assert_equal 5, @db.doc_get(collection, "b1")["n"]
    assert_raises(TriCoreDB::ServerError) do
      @db.doc_bulk_write(collection, [TriCoreDB::BulkOp.insert({ "n" => 1 }, id: "fresh"),
                                      TriCoreDB::BulkOp.insert({ "n" => 1 }, id: "b1")])
    end
    assert_nil @db.doc_get(collection, "fresh"), "one refused operation leaves nothing of the batch behind"

    assert_equal 1, @db.doc_delete_many(collection, TriCoreDB::Filter.eq("city", "Delhi"))
    plan = @db.doc_explain(collection, filter: TriCoreDB::Filter.eq("city", "Pune"), limit: 5)
    assert_equal 1, plan["rows_returned"]

    @db.doc_create_index(collection, "by_n", "n")
    assert_equal "by_n", @db.doc_rebuild_index(collection, "by_n")["rebuilt"]
    assert_equal 0, @db.doc_purge_expired(collection)

    @db.doc_rename_collection(collection, "#{collection}_renamed")
    refute_nil @db.doc_get("#{collection}_renamed", "a")
    @db.doc_drop_collection("#{collection}_renamed")
  end

  def test_collection_options_and_document_transactions
    collection = unique("rb_opts")
    @db.doc_create_collection(collection)
    assert_equal({ "versioned" => false }, @db.doc_get_collection_options(collection))
    @db.doc_set_collection_options(collection, {
                                     "schema" => { "required" => ["n"],
                                                   "fields" => { "n" => { "type" => "number", "minimum" => 0 } } },
                                     "defaults" => { "status" => "new" }, "versioned" => true
                                   })
    assert @db.doc_get_collection_options(collection)["versioned"]
    @db.doc_insert(collection, { "n" => 1 }, id: "v")
    stored = @db.doc_get(collection, "v")
    assert_equal ["new", 1], stored.values_at("status", "_version")
    assert_raises(TriCoreDB::ServerError) { @db.doc_insert(collection, { "x" => 1 }) }
    @db.doc_replace(collection, "v", { "n" => 2 }, expected_version: 1)
    error = assert_raises(TriCoreDB::ServerError) { @db.doc_replace(collection, "v", { "n" => 3 }, expected_version: 1) }
    assert_match(/version conflict/, error.message)

    txn = @db.doc_begin_transaction
    @db.doc_insert(collection, { "n" => 1 }, id: "t1", txn: txn)
    refute_nil @db.doc_get(collection, "t1", txn: txn)
    assert_nil @db.doc_get(collection, "t1")
    assert @db.doc_commit_transaction(txn)["committed"]
    refute_nil @db.doc_get(collection, "t1")

    discarded = @db.doc_begin_transaction(serializable: true)
    @db.doc_insert_many(collection, [{ "_id" => "t2", "n" => 1 }], txn: discarded)
    @db.doc_rollback_transaction(discarded)
    assert_nil @db.doc_get(collection, "t2")
    assert_raises(TriCoreDB::ServerError) { @db.doc_commit_transaction(discarded) }
    @db.doc_drop_collection(collection)
  end

  def test_vectors_are_written_and_searched_in_batches
    collection = unique("rb_vec")
    @db.vector_create_collection(collection, 3)
    items = [
      { "id" => "a", "vector" => [1.0, 0.0, 0.0], "metadata" => { "kind" => "x", "_namespace" => "n1" } },
      { "id" => "b", "vector" => [0.0, 1.0, 0.0], "metadata" => { "kind" => "y", "_namespace" => "n1" } },
      { "id" => "c", "vector" => [0.0, 0.0, 1.0] },
      { "id" => "d", "vector" => [0.9, 0.1, 0.0], "metadata" => { "kind" => "x", "_namespace" => "n2" } }
    ]
    assert_equal 4, @db.vector_upsert_many(collection, items)

    batches = @db.vector_search_batch(collection, [[1, 0, 0], [0, 1, 0]], 2)
    assert_equal %w[a b], batches.map { |hits| hits.first["id"] }
    exact = @db.vector_search_batch(collection, [[1, 0, 0]], 2, filter: { "kind" => "x" }, include_vectors: true,
                                                               options: { exact: true, namespace: "n1", explain: true })
    assert_equal ["a"], exact.first.map { |hit| hit["id"] }
    assert_equal [1.0, 0.0, 0.0], exact.first.first["vector"]

    assert_equal 4, @db.vector_count(collection)
    assert_equal 2, @db.vector_count(collection, filter: { "kind" => "x" })
    assert_equal 2, @db.vector_update_by_filter(collection, { "kind" => "x" }, { "seen" => true })
    assert @db.vector_get(collection, "a")["metadata"]["seen"]
    partitions = @db.vector_list_partitions(collection)
    assert_equal [{ "count" => 2, "name" => "n1" }, { "count" => 1, "name" => "n2" }], partitions["partitions"]

    assert_equal 2, @db.vector_search_multi(collection, [[1, 0, 0], [0, 1, 0]], 3, fusion: "max").first["matched"]
    alike = @db.vector_search_by_examples(collection, 2, positive: ["a", [0.0, 1.0, 0.0]], negative: ["c"])
    refute_includes alike.map { |hit| hit["id"] }, "a", "an example named by id is left out"
    assert_equal "a", @db.vector_search_by_examples(collection, 1, positive: ["a"], exclude_examples: false).first["id"]

    assert_equal 1, @db.vector_delete_many(collection, %w[c nobody])
    assert_equal 1, @db.vector_delete_by_filter(collection, { "kind" => "y" })
    assert_raises(TriCoreDB::ServerError) { @db.vector_delete_by_filter(collection, {}) }
    assert_equal 2, @db.vector_index_stats(collection)["stored"]
    assert @db.vector_rebuild_index(collection)["rebuilt"]
    assert_kind_of Numeric, @db.vector_measure_recall(collection, sample: 2)["recall"]

    @db.vector_copy_collection(collection, "#{collection}_copy")
    @db.vector_rename_collection("#{collection}_copy", "#{collection}_renamed")
    assert_equal 2, @db.vector_count("#{collection}_renamed")
    @db.vector_drop_collection("#{collection}_renamed")
    @db.vector_drop_collection(collection)
  end

  def test_named_vectors_aliases_configuration_and_text
    collection = unique("rb_named")
    @db.vector_create_collection(collection, 3)
    configured = @db.vector_set_collection_config(collection, normalize: true, m: 8, ef_construction: 100)
    assert_equal [true, 8], configured.values_at("normalize", "m")
    @db.vector_add_named_vector(collection, "title", 2, metric: "dot")
    @db.vector_upsert_named(collection, "n1", { "default" => [1.0, 0.0, 0.0], "title" => [1.0, 0.0] },
                            metadata: { "kind" => "named" })
    assert_equal 1, @db.vector_count(collection)

    name = unique("rb_alias")
    @db.vector_set_alias(name, collection: collection)
    assert_includes @db.vector_list_aliases, { "alias" => name, "collection" => collection }
    assert_equal 1, @db.vector_count(name), "an operation naming the alias acts on the collection"
    @db.vector_set_alias(name)
    refute_includes @db.vector_list_aliases, { "alias" => name, "collection" => collection }
    @db.vector_drop_collection(collection)

    embedded = @db.vector_embed(["hello world", "goodbye"], 4)
    assert_equal [4, 2], [embedded["dimension"], embedded["vectors"].size]
    texts = unique("rb_text")
    @db.vector_create_collection(texts, 8)
    assert_equal 2, @db.vector_upsert_text(texts, [{ "id" => "t1", "text" => "the quick brown fox" },
                                                    { "id" => "t2", "text" => "lazy dog" }])
    assert_equal "the quick brown fox", @db.vector_get(texts, "t1")["metadata"]["text"]
    @db.vector_drop_collection(texts)
  end

  def test_graphs_are_written_in_bulk_and_walked
    graph = unique("rb_graph")
    @db.graph_create(graph)
    nodes = [
      { "id" => "a", "labels" => ["Person"], "properties" => { "name" => "ada", "age" => 36 } },
      { "id" => "b", "labels" => ["Person"], "properties" => { "name" => "bob" } },
      { "id" => "c", "labels" => ["Person"], "properties" => { "name" => "cy" } },
      { "id" => "d" }, { "id" => "e", "labels" => ["City"] }
    ]
    edges = [
      { "id" => "e1", "from" => "a", "to" => "b", "label" => "KNOWS", "properties" => { "w" => 1 } },
      { "id" => "e2", "from" => "b", "to" => "c", "label" => "KNOWS", "properties" => { "w" => 2 } },
      { "id" => "e3", "from" => "c", "to" => "a", "label" => "KNOWS" },
      { "id" => "e4", "from" => "a", "to" => "c", "label" => "LIKES" },
      { "id" => "e5", "from" => "c", "to" => "d", "label" => "KNOWS" }
    ]
    assert_equal [5, 5], @db.graph_add_many(graph, nodes: nodes, edges: edges).values_at("nodes", "edges")

    node = @db.graph_update_node(graph, "a", properties: { "age" => nil, "city" => "Pune" }, add_labels: ["Admin"])
    assert_equal %w[Person Admin], node["labels"]
    assert_equal({ "city" => "Pune", "name" => "ada" }, node["properties"])
    assert_equal "LOVES", @db.graph_update_edge(graph, "e4", properties: { "since" => 2020 }, label: "LOVES")["label"]

    assert_equal ["depth_first", 4], @db.graph_dfs(graph, "a").values_at("order", "count")
    assert @db.graph_dfs(graph, "a", direction: "both", label: "KNOWS", max_depth: 1, limit: 2)["truncated"]
    assert_equal [2, 4], @db.graph_connected_components(graph).values_at("count", "largest")
    assert_equal 3, @db.graph_connected_components(graph, kind: "strong", label: "KNOWS")["largest"]
    assert @db.graph_detect_cycle(graph)["hasCycle"]
    refute @db.graph_detect_cycle(graph, directed: false, label: "LOVES")["hasCycle"]
    assert_equal({ "KNOWS" => 4, "LOVES" => 1 }, @db.graph_stats(graph)["edgeTypes"])
    assert_equal 5, @db.graph_schema(graph)["nodes"]
    assert_equal [3, 4], @db.graph_subgraph(graph, ["a"]).values_at("node_count", "edge_count")

    assert_equal 2, @db.graph_k_shortest_paths(graph, "a", "c", k: 2)["count"]
    weighted = @db.graph_k_shortest_paths(graph, "a", "c", label: "KNOWS", weight_property: "w")
    assert_equal 3.0, weighted["paths"].first["cost"]
    assert_equal [true, 2], @db.graph_all_paths(graph, "a", "c").values_at("complete", "count")
    %w[betweenness closeness eigenvector].each do |measure|
      assert_equal 3, @db.graph_centrality(graph, measure, limit: 3)["results"].size
    end
    assert_equal "louvain", @db.graph_communities(graph)["algorithm"]
    assert_equal 1, @db.graph_triangle_count(graph)["triangles"]
    assert_equal 1, @db.graph_node_similarity(graph, "a", metric: "overlap", limit: 1)["results"].size
    assert_equal 2, @db.graph_page_rank(graph, damping: 0.9, limit: 2)["ranks"].size
    assert @db.graph_check_consistency(graph)["consistent"]

    removed = @db.graph_remove_many(graph, nodes: %w[d nobody], edges: ["e4"], detach: true)
    assert_equal [1, 2], removed.values_at("nodes_removed", "edges_removed")
    assert_equal 4, @db.graph_copy(graph, "#{graph}_copy")["nodes"]
    assert_raises(TriCoreDB::ServerError) { @db.graph_copy(graph, "#{graph}_copy") }
    @db.graph_drop("#{graph}_copy")
    @db.graph_drop(graph)
  end

  def test_graph_indexes_constraints_cypher_writes_and_transactions
    graph = unique("rb_schema")
    @db.graph_create(graph)
    @db.graph_import_csv(graph, nodes: "id,labels,name\nx1,Person,xena\nx2,Person,yuri\n",
                                edges: "id,from,to,label\nxe1,x1,x2,KNOWS\n")
    @db.graph_create_node_index(graph, "by_name", ["name"], label: "Person")
    @db.graph_create_constraint(graph, "unique_name", "Person", "name", "unique")
    objects = @db.graph_list_schema_objects(graph)
    assert_equal ["by_name"], objects["indexes"].map { |i| i["name"] }
    assert_equal ["unique"], objects["constraints"].map { |c| c["kind"] }

    found = @db.graph_find_nodes(graph, label: "Person", properties: { "name" => "xena" })
    assert_equal 1, found["count"]
    assert_match(/by_name/, found["plan"])
    assert_raises(TriCoreDB::ServerError) do
      @db.graph_add_node(graph, "dup", labels: ["Person"], properties: { "name" => "xena" })
    end
    assert_raises(TriCoreDB::ServerError) do
      @db.graph_create_constraint(graph, "edge_since", "KNOWS", "since", "required", target: "edge")
    end
    @db.graph_drop_schema_object(graph, "unique_name")

    assert_equal 1, @db.graph_execute(graph, "CREATE (n:Person {name: 'zed'})")["nodesCreated"]
    txn = @db.graph_begin_transaction(graph)
    assert_equal 1, @db.graph_execute(graph, "CREATE (n:Person {name: 'queued'})", txn: txn)["queued"]
    assert_equal 0, @db.graph_find_nodes(graph, properties: { "name" => "queued" })["count"]
    assert_equal 1, @db.graph_commit_transaction(graph, txn)["committed"]
    assert_equal 1, @db.graph_find_nodes(graph, properties: { "name" => "queued" })["count"]

    discarded = @db.graph_begin_transaction(graph)
    @db.graph_execute(graph, "CREATE (n:Person {name: 'never'})", txn: discarded)
    @db.graph_rollback_transaction(graph, discarded)
    assert_equal 0, @db.graph_find_nodes(graph, properties: { "name" => "never" })["count"]
    @db.graph_drop(graph)
  end
end
