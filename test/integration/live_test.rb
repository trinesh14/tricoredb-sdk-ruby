# frozen_string_literal: true

require_relative "../test_helper"

# Everything this driver can do, against a real `tricore-server`.
#
# Each case reads the value *back* rather than only checking that nothing was
# raised: a driver that mangled a quote, a backslash or a 100 KiB payload would
# pass a "no error" test and fail every one of these.
#
# Run with `rake test:integration`. Without a server binary every test skips, with
# the reason printed.
class LiveTest < Minitest::Test
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

  def test_a_session_authenticates_and_negotiates_its_capabilities
    @db.ping
    assert @db.features[:server_params], "the server binds parameters"
    assert @db.features[:session_txn], "the server holds transactions open"
    refute @db.closed?
  end

  def test_values_round_trip_through_bound_parameters_byte_for_byte
    table = unique("rb_params")
    @db.execute("CREATE TABLE #{table} (id INT PRIMARY KEY, t TEXT, b BLOB, f DOUBLE, k BOOL)")
    victim = unique("rb_victim")
    @db.execute("CREATE TABLE #{victim} (id INT PRIMARY KEY)")

    quote = "O'Hara said 'hi'"
    backslash = 'C:\\Users\\trine\\a\\\'b'
    injection = "'; DROP TABLE #{victim}; --"
    { 1 => quote, 2 => backslash, 3 => injection }.each do |id, text|
      @db.execute("INSERT INTO #{table} (id, t) VALUES (?, ?)", [id, text])
      rows = @db.query("SELECT t FROM #{table} WHERE id = ?", [id])
      assert_equal text, rows.first[0], "value #{id} changed in flight"
    end
    # The proof that the injection string was data: the table it named is still there.
    @db.query("SELECT id FROM #{victim}")

    blob = TriCoreDB::Binary.new([0x00, 0x01, 0xff, 0xfe, 0x27, 0x5c, 0x68, 0x69, 0x00])
    @db.execute("INSERT INTO #{table} (id, b, f, k) VALUES (?, ?, ?, ?)", [4, blob, -0.125, true])
    row = @db.query("SELECT b, f, k FROM #{table} WHERE id = ?", [4]).first
    assert_equal "0x0001fffe275c686900", row[0], "every byte survives, NUL and invalid UTF-8 included"
    assert_equal "-0.125", row[1]
    assert_equal "true", row[2]

    # A bound nil is SQL NULL, not the four letters N-U-L-L.
    @db.execute("INSERT INTO #{table} (id, t) VALUES (?, ?)", [5, nil])
    nulls = @db.query("SELECT COUNT(*) FROM #{table} WHERE id = ? AND t IS NULL", [5])
    assert_equal "1", nulls.first[0]

    @db.execute("DROP TABLE #{table}")
    @db.execute("DROP TABLE #{victim}")
  end

  def test_the_query_and_execute_split_is_enforced_by_the_server
    table = unique("rb_split")
    @db.execute("CREATE TABLE #{table} (id INT PRIMARY KEY)")

    assert_raises(TriCoreDB::ServerError) { @db.query("INSERT INTO #{table} VALUES (1)") }
    error = assert_raises(TriCoreDB::ServerError) { @db.execute("THIS IS NOT SQL AT ALL") }
    refute_nil error.code
    refute @db.closed?, "a refusal leaves the connection usable"
    @db.ping
    @db.execute("DROP TABLE #{table}")
  end

  def test_transactions_commit_together_and_roll_back_together
    table = unique("rb_txn")
    @db.execute("CREATE TABLE #{table} (id INT PRIMARY KEY, name TEXT)")

    @db.transaction do
      @db.execute("INSERT INTO #{table} VALUES (?, ?)", [1, "ada"])
      @db.execute("INSERT INTO #{table} VALUES (?, ?)", [2, "grace"])
    end
    assert_equal "2", @db.query("SELECT COUNT(*) FROM #{table}").first[0]

    @db.begin_transaction
    @db.execute("INSERT INTO #{table} VALUES (?, ?)", [3, "hopper"])
    @db.rollback
    assert_equal "2", @db.query("SELECT COUNT(*) FROM #{table}").first[0],
                 "a rolled-back write must not persist"
    refute @db.in_transaction?

    # A block that raises rolls back and re-raises the caller's own error.
    assert_raises(RuntimeError) do
      @db.transaction do
        @db.execute("INSERT INTO #{table} VALUES (?, ?)", [4, "eve"])
        raise "give up"
      end
    end
    assert_equal "2", @db.query("SELECT COUNT(*) FROM #{table}").first[0]
    @db.execute("DROP TABLE #{table}")
  end

  def test_a_cache_value_of_100_kib_round_trips_byte_for_byte
    ns = unique("rb_cache")
    # Larger than one TCP segment: the case a single-read driver passes locally and
    # corrupts in production.
    big = (0...(100 * 1024)).map { |i| (i * 31 + 7) % 256 }.pack("C*")
    @db.cache_set(ns, "big", big)
    assert_equal big, @db.cache_get(ns, "big")

    assert_nil @db.cache_get(ns, "absent"), "a miss is nil"
    @db.cache_set(ns, "empty", "")
    assert_equal "", @db.cache_get(ns, "empty"), "an empty value is not a miss"

    assert @db.cache_exists?(ns, "big")
    assert @db.cache_delete(ns, "big")
    refute @db.cache_delete(ns, "big"), "deleting an absent key is false, not an error"
    @db.cache_clear_namespace(ns)
  end

  def test_cache_collections_behave
    ns = unique("rb_coll")
    @db.cache_ping

    assert_equal 2, @db.cache_rpush(ns, "q", %w[a b])
    assert_equal 3, @db.cache_lpush(ns, "q", ["z"])
    assert_equal 3, @db.cache_llen(ns, "q")
    assert_equal "z", @db.cache_lpop(ns, "q")
    assert_equal "b", @db.cache_rpop(ns, "q")

    assert_equal 2, @db.cache_sadd(ns, "tags", %w[ruby db])
    assert_equal 0, @db.cache_sadd(ns, "tags", ["ruby"]), "an existing member adds nothing"
    assert @db.cache_sismember?(ns, "tags", "db")
    assert_equal 2, @db.cache_scard(ns, "tags")

    # A field and a value that are not valid UTF-8 must survive, which is why this
    # API speaks bytes rather than text.
    field = [0xff, 0x00, 0xfe].pack("C*")
    value = [0x00, 0xc3, 0x28].pack("C*")
    @db.cache_hset(ns, "h", [[field, value]])
    assert_equal value, @db.cache_hget(ns, "h", field)
    assert_equal 1, @db.cache_hlen(ns, "h")

    id = @db.cache_xadd(ns, "events", [%w[msg hi]])
    refute_empty id
    assert_equal 1, @db.cache_xlen(ns, "events")
    entries = @db.cache_xrange(ns, "events")
    assert_equal({ "msg" => "hi" }, entries.first.text)

    assert_equal 5, @db.cache_incr(ns, "hits", 5)
    assert @db.cache_set_nx(ns, "lock", "1")
    refute @db.cache_set_nx(ns, "lock", "2"), "set-if-absent is how a lock is taken"
    @db.cache_clear_namespace(ns)
  end

  def test_documents_can_be_written_queried_and_aggregated
    collection = unique("rb_docs")
    @db.doc_create_collection(collection)

    id = @db.doc_insert(collection, { "name" => "widget", "price" => 9, "kind" => "tool" })
    @db.doc_insert(collection, { "name" => "gadget", "price" => 20, "kind" => "tool" }, id: "gadget")

    assert_equal "gadget", @db.doc_get(collection, "gadget")["name"]
    assert_nil @db.doc_get(collection, "missing"), "an absent document is nil, not an empty Hash"
    assert_equal 1, @db.doc_find(collection, TriCoreDB::Filter.gt("price", 10)).size
    assert_equal 2, @db.doc_find(collection).size

    @db.doc_update_one(collection, "gadget", inc: { "price" => 5 })
    assert_equal 25, @db.doc_get(collection, "gadget")["price"]

    counts = @db.doc_update_many(collection, TriCoreDB::Filter.eq("kind", "tool"), set: { "kind" => "hardware" })
    assert_equal 2, counts["matched"]

    @db.doc_create_index(collection, "by_name", "name", unique: true)
    assert(@db.doc_list_indexes(collection).any? { |i| i["index_name"] == "by_name" })
    @db.doc_drop_index(collection, "by_name")
    assert_equal 2, @db.doc_analyze(collection)["document_count"]

    totals = @db.doc_aggregate(collection, [
                                 TriCoreDB::Stage.match(TriCoreDB::Filter.gt("price", 1)),
                                 TriCoreDB::Stage.group(TriCoreDB::Stage.by_constant("all"),
                                                        [TriCoreDB::Acc.sum("total", "price"),
                                                         TriCoreDB::Acc.count("n")])
                               ])
    assert_equal 1, totals.size
    assert_equal 34, totals.first["total"], "9 + 25"
    assert_equal 2, totals.first["n"]

    @db.doc_delete(collection, id)
    @db.doc_drop_collection(collection)
  end

  def test_vectors_are_searchable_and_filterable
    collection = unique("rb_vec")
    @db.vector_create_collection(collection, 3, metric: "cosine")
    @db.vector_upsert(collection, "a", [0.1, 0.2, 0.3], metadata: { "kind" => "doc" })
    @db.vector_upsert(collection, "b", [0.9, 0.1, 0.0], metadata: { "kind" => "image" })

    stored = @db.vector_get(collection, "a")
    assert_equal 3, stored["vector"].size
    assert_nil @db.vector_get(collection, "zz")

    hits = @db.vector_search(collection, [0.1, 0.2, 0.3], 2)
    assert_equal "a", hits.first["id"], "the nearest vector comes first"

    filtered = @db.vector_search(collection, [0.1, 0.2, 0.3], 5, filter: { "kind" => "image" })
    assert_equal ["b"], filtered.map { |h| h["id"] }

    info = @db.vector_describe_collection(collection)
    assert_equal 3, info["dimension"]
    assert_equal 2, info["count"]

    # A wrong-length vector is refused rather than padded or truncated.
    assert_raises(TriCoreDB::ServerError) { @db.vector_upsert(collection, "bad", [1.0, 2.0]) }

    @db.vector_delete(collection, "a")
    @db.vector_drop_collection(collection)
  end

  def test_graphs_traverse_and_find_paths
    graph = unique("rb_graph")
    @db.graph_create(graph)
    %w[u1 u2 u3].each { |id| @db.graph_add_node(graph, id, labels: ["User"]) }
    @db.graph_add_edge(graph, "e1", "u1", "u2", "FOLLOWS", properties: { "weight" => 1.0 })
    @db.graph_add_edge(graph, "e2", "u2", "u3", "FOLLOWS", properties: { "weight" => 1.0 })

    node = @db.graph_get_node(graph, "u1")
    assert_equal ["User"], node["labels"]
    assert_nil @db.graph_get_node(graph, "nobody")

    assert_equal 1, @db.graph_neighbors(graph, "u1").size
    assert_equal 2, @db.graph_degree(graph, "u2", direction: "both")
    assert(@db.graph_traverse(graph, "u1", max_depth: 5)["nodes"].any? { |n| n["id"] == "u3" })

    path = @db.graph_shortest_path(graph, "u1", "u3")
    assert path["found"]
    assert_equal %w[u1 u2 u3], path["node_path"]

    # No path is an answer, not an error.
    refute @db.graph_shortest_path(graph, "u3", "u1")["found"]

    @db.graph_delete_edge(graph, "e1")
    @db.graph_delete_node(graph, "u1")
    @db.graph_drop(graph)
  end

  def test_context_exports_render_in_the_format_asked_for
    table = unique("rb_llm")
    @db.execute("CREATE TABLE #{table} (id INT PRIMARY KEY, name TEXT)")
    @db.execute("INSERT INTO #{table} VALUES (?, ?)", [1, "ada"])

    bundle = @db.llm_context([TriCoreDB::LlmSource.sql("SELECT id, name FROM #{table}")], format: "toon")
    assert_includes bundle, "ada"
    refute_empty @db.llm_schema(format: "markdown")

    @db.execute("DROP TABLE #{table}")
  end

  def test_a_disabled_module_is_refused_by_name
    # The test server runs without the cluster module, so the admin plane says so
    # rather than pretending to be healthy.
    error = assert_raises(TriCoreDB::ServerError) { @db.admin_ping }
    refute_nil error.code
    @db.ping
  end

  def test_a_pool_serves_several_threads_at_once
    table = unique("rb_pool")
    pool = TriCoreDB::Pool.new(size: 4, host: @server.host, port: @server.port, user: "admin", secret: "pw")
    begin
      pool.with { |db| db.execute("CREATE TABLE #{table} (id INT PRIMARY KEY)") }
      threads = (1..8).map do |id|
        Thread.new { pool.with { |db| db.execute("INSERT INTO #{table} VALUES (?)", [id]) } }
      end
      threads.each(&:join)
      pool.with do |db|
        assert_equal "8", db.query("SELECT COUNT(*) FROM #{table}").first[0]
        db.execute("DROP TABLE #{table}")
      end
      assert_equal 0, pool.stats[:in_use], "every connection came back"
    ensure
      pool.close
    end
  end
end
