# tricoredb

Official Ruby client for [TriCoreDB](https://hub.docker.com/r/trinesh14/tricoredb):
SQL, documents, vectors, graphs and cache over one native connection.

[![Gem Version](https://img.shields.io/gem/v/tricoredb?logo=rubygems&label=gem&color=blue&cacheSeconds=1800)](https://rubygems.org/gems/tricoredb)
[![Downloads](https://img.shields.io/gem/dt/tricoredb?label=downloads&color=blue&cacheSeconds=1800)](https://rubygems.org/gems/tricoredb)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue?cacheSeconds=86400)](LICENSE)

- **No dependencies** beyond the Ruby standard library.
- **Server-side parameters.** Values never become part of the SQL text.
- **Typed errors** you rescue by class and branch on by code.
- **Transactions, a thread-safe pool, TLS and mutual TLS.**

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Running a server](#running-a-server)
- [Quick start](#quick-start)
- [Connecting](#connecting)
- [SQL](#sql)
- [Transactions](#transactions)
- [Connection pool](#connection-pool)
- [Cache](#cache)
- [Documents](#documents)
- [Vectors](#vectors)
- [Graphs](#graphs)
- [LLM context](#llm-context)
- [Admin](#admin)
- [Errors](#errors)
- [TLS](#tls)
- [Testing](#testing)

## Requirements

- Ruby **3.1** or later
- A TriCoreDB server speaking protocol 1.0 (`tricore-server` 0.1.0-rc.1 or later).
  See [Running a server](#running-a-server).

## Installation

```bash
gem install tricoredb
```

Or in a Gemfile:

```ruby
gem "tricoredb"
```

## Running a server

The quickest way is the official Docker image,
[`trinesh14/tricoredb`](https://hub.docker.com/r/trinesh14/tricoredb).

**Local development** (no TLS and no encryption, for this machine only). Set
`TRICORE_ADMIN_PASSWORD` in your shell first. Then create the admin and start the
server:

```bash
docker run --rm -v tricoredb-dev:/var/lib/tricoredb -e TRICORE_ADMIN_PASSWORD --entrypoint /usr/local/bin/tricore trinesh14/tricoredb:0.1.0-rc.1-r2 auth init-admin --user admin --password-env TRICORE_ADMIN_PASSWORD --data-dir /var/lib/tricoredb/data
docker run -d --name tricoredb-dev -p 127.0.0.1:8427:8427 -e TRICORE_TLS=off -e TRICORE_ENCRYPTION=off -e TRICORE_MODULES=all -v tricoredb-dev:/var/lib/tricoredb trinesh14/tricoredb:0.1.0-rc.1-r2
```

**Anything else:** by default the image runs with **TLS on** and an **encrypted data
volume**. Follow the quick start on the
[Docker Hub page](https://hub.docker.com/r/trinesh14/tricoredb) to create the
certificate and key, then connect with [TLS](#tls).

`TRICORE_MODULES=all` enables every data model. The image's default is `sql`,
`document` and `cache`; a call to a disabled model raises `TriCoreDB::ServerError`
whose `code` is `engine.disabled`.

## Quick start

```ruby
require "tricoredb"

db = TriCoreDB::Client.connect(host: "127.0.0.1", port: 8427, user: "admin", secret: "your-password")

db.execute("CREATE TABLE IF NOT EXISTS users (id INT PRIMARY KEY, name TEXT)")
db.execute("INSERT INTO users VALUES (?, ?)", [1, "O'Hara"])

rows = db.query("SELECT id, name FROM users WHERE id = ?", [1])
rows.first          # => ["1", "O'Hara"]
rows.to_hashes      # => [{"id" => "1", "name" => "O'Hara"}]

db.cache_set("sessions", "u1", "token")
db.cache_get("sessions", "u1")   # => "token", or nil on a miss

db.close
```

## Connecting

`TriCoreDB::Client.connect` opens one authenticated connection.

| Keyword | Default | Meaning |
| --- | --- | --- |
| `host` | `"127.0.0.1"` | Server host |
| `port` | `8427` | Server port |
| `user` | `nil` | Principal to authenticate as; `nil` skips authentication |
| `secret` | `""` | Password or token |
| `database` | `"main"` | Database named in every request |
| `connect_timeout` | `10` | Seconds allowed for the connect, TLS and handshake |
| `read_timeout` | `nil` | Seconds allowed for each reply |
| `request_timeout_ms` | `nil` | Server-side deadline stamped on each request |
| `tls` | `nil` | See [TLS](#tls) |
| `client_name` | `"tricoredb-ruby/<version>"` | Name reported in the handshake |
| `features` | every capability | Bitmap announced in the handshake |
| `follow_leader` | `true` | Send a `not_leader` refusal again, to the leader |
| `leader_retries` | `5` | How many times a refused request is sent again |
| `leader_retry_delay` | `0.25` | First pause, in seconds, before asking again; doubles up to 2 |

A connection is a single request/response stream, so one connection serves one
thread. For concurrent work use a [pool](#connection-pool).

## SQL

`query` runs only `SELECT`. `execute` runs everything else. The server enforces the
split: a write sent through `query` is refused.

```ruby
db.execute("INSERT INTO users VALUES (?, ?)", [2, "ada"])
rows = db.query("SELECT id, name FROM users")

rows.size           # => 2
rows.each { |row| puts row.inspect }
rows.to_hashes      # rows keyed by column name
```

Placeholders are bound **on the server**: the values travel next to the statement,
so a value can never be read as SQL syntax, however it is spelled. How a Ruby value
goes out:

| Ruby value | Sent as |
| --- | --- |
| `nil`, `true`, `false` | themselves |
| `Integer` | an exact number, Bignum included |
| `Float` | a number; `NaN` and infinities are refused |
| `BigDecimal` | plain digits, no exponent — for `DECIMAL` |
| `String` (UTF-8) | text; invalid UTF-8 is refused |
| `String` (ASCII-8BIT) or `TriCoreDB::Binary` | `0x`-prefixed hex, for `BLOB` |
| `Time`, `Date`, `DateTime` | ISO-8601 text |

Anything else is refused by name rather than pushed through `to_s`:

```ruby
db.execute("INSERT INTO files VALUES (?, ?)", [1, TriCoreDB::Binary.new(File.binread("a.png"))])
db.execute("INSERT INTO t VALUES (?)", [[1, 2]])   # raises TriCoreDB::ParameterError
```

Binding needs the `SERVER_PARAMS` capability, agreed in the handshake
(`db.features[:server_params]`). Against a server that did not grant it, a call with
parameters raises `TriCoreDB::FeatureNotGranted` **before anything is sent** — it
never falls back to pasting values into the statement text.

## Transactions

`transaction` sends a whole `BEGIN … COMMIT` script in **one request**, and rolls
back if the block raises:

```ruby
db.transaction do
  db.execute("UPDATE accounts SET balance = balance - ? WHERE id = ?", [10, 1])
  db.execute("UPDATE accounts SET balance = balance + ? WHERE id = ?", [10, 2])
end
```

`begin_transaction`, `commit` and `rollback` keep a transaction open **across
requests on this connection**, so a later statement can depend on what an earlier
one read. They need the `SESSION_TXN` capability; without it `begin_transaction`
raises by name rather than running each statement on its own.

```ruby
db.begin_transaction
begin
  db.execute("INSERT INTO t VALUES (?, ?)", [1, "ada"])
  db.commit
rescue StandardError
  db.rollback
  raise
end
```

The transaction belongs to this connection: another connection cannot commit it, and
a dropped socket rolls it back. `db.in_transaction?` says whether one is open.

## Connection pool

```ruby
pool = TriCoreDB::Pool.new(size: 8, host: "db.internal", user: "admin", secret: "your-password")

threads = 8.times.map do |i|
  Thread.new { pool.with { |db| db.execute("INSERT INTO users VALUES (?, ?)", [i, "grace"]) } }
end
threads.each(&:join)

pool.stats   # => {size: 8, created: 8, idle: 8, in_use: 0, waiting: 0}
pool.close
```

`pool.with` lends a connection for the duration of the block. A connection is never
returned with a transaction still open, and a broken one is retired rather than
handed to the next caller. When every connection is busy, a caller waits up to
`checkout_timeout` seconds and then gets `TriCoreDB::PoolTimeout` — the pool never
grows past `size`.

## Cache

Values are byte strings. `nil` is a miss, which is how a miss is told apart from a
stored empty value.

```ruby
db.cache_set("sessions", "u1", "token")
db.cache_set("sessions", "u2", "token", ttl_ms: 30_000)
db.cache_get("sessions", "u1")          # => "token" | nil

db.cache_incr("counters", "hits")
db.cache_rpush("queue", "jobs", %w[a b])
db.cache_sadd("tags", "post:1", %w[ruby db])
db.cache_hset("user:1", "profile", [%w[name ada]])
id = db.cache_xadd("events", "log", [%w[msg hi]])
```

| Family | Methods |
| --- | --- |
| Keys | `cache_get`, `cache_set`, `cache_set_nx`, `cache_delete`, `cache_exists?`, `cache_ttl`, `cache_expire`, `cache_persist`, `cache_incr`, `cache_keys`, `cache_clear_namespace`, `cache_ping` |
| Lists | `cache_lpush`, `cache_rpush`, `cache_lpop`, `cache_rpop`, `cache_lrange`, `cache_llen`, `cache_lindex` |
| Sets | `cache_sadd`, `cache_srem`, `cache_sismember?`, `cache_scard`, `cache_smembers` |
| Hashes | `cache_hset`, `cache_hget`, `cache_hdel`, `cache_hgetall`, `cache_hexists?`, `cache_hlen` |
| Streams | `cache_xadd`, `cache_xlen`, `cache_xrange`, `cache_xread`, `cache_xdel`, `cache_xtrim` |

## Documents

Filters and pipeline stages are built with `TriCoreDB::Filter`, `TriCoreDB::Stage`
and `TriCoreDB::Acc`, so the request JSON is never written by hand.

```ruby
db.doc_create_collection("products")
id = db.doc_insert("products", { "name" => "widget", "price" => 9 })
db.doc_find("products", TriCoreDB::Filter.gt("price", 5))
db.doc_update_one("products", id, inc: { "price" => 1 })

totals = db.doc_aggregate("orders", [
  TriCoreDB::Stage.match(TriCoreDB::Filter.eq("status", "paid")),
  TriCoreDB::Stage.group(TriCoreDB::Stage.by_field("customer"), [TriCoreDB::Acc.sum("total", "amount")]),
  TriCoreDB::Stage.sort([["total", true]]),
  TriCoreDB::Stage.limit(10)
])
```

Also available: `doc_get`, `doc_update`, `doc_update_many`, `doc_delete`,
`doc_list_collections`, `doc_drop_collection`, `doc_create_index`, `doc_drop_index`,
`doc_list_indexes` and `doc_analyze`.

## Vectors

```ruby
db.vector_create_collection("embeddings", 3, metric: "cosine")
db.vector_upsert("embeddings", "a", [0.1, 0.2, 0.3], metadata: { "kind" => "doc" })

hits = db.vector_search("embeddings", [0.1, 0.2, 0.3], 5)
hits.first["id"]      # the nearest vector comes first
hits.first["score"]

db.vector_search("embeddings", [0.1, 0.2, 0.3], 5, filter: { "kind" => "doc" })
```

The score is a **similarity**: higher is closer under every metric. L2 is the case
worth knowing — the server negates the squared distance, so an L2 score is `<= 0`
and `-0.02` is nearer than `-196.0`.

## Graphs

```ruby
db.graph_create("social")
db.graph_add_node("social", "u1", labels: ["User"], properties: { "name" => "ada" })
db.graph_add_node("social", "u2", labels: ["User"])
db.graph_add_edge("social", "e1", "u1", "u2", "FOLLOWS")

db.graph_neighbors("social", "u1")
path = db.graph_shortest_path("social", "u1", "u2")
path["found"]      # => true
path["node_path"]  # => ["u1", "u2"]
```

"No path" comes back as `found => false`, not as an error. Also available:
`graph_get_node`, `graph_get_edge`, `graph_delete_node`, `graph_delete_edge`,
`graph_list`, `graph_drop`, `graph_traverse`, `graph_weighted_shortest_path`,
`graph_degree`, `graph_list_nodes`, `graph_list_edges` and `graph_query` for the
read-only Cypher subset.

## Operations added for server 0.1.0-rc.3

These need a server at **0.1.0-rc.3 or later**. An older server does not know the
operation and answers it with an error, which this client raises like any other
refusal.

### Cache

| Method | Server operation | What it does |
| --- | --- | --- |
| `cache_set_fresh` | `Cache.SetFresh` | Store a value that answers as fresh for the given time and as stale after it, until its TTL (if any) ends |
| `cache_get_fresh` | `Cache.GetFresh` | Read with stale-while-revalidate and stampede protection |
| `cache_set_missing` | `Cache.SetMissing` | Negative caching |
| `cache_warm` | `Cache.Warm` | Cache warming |
| `cache_mget` | `Cache.MGet` | Read many values in one request |
| `cache_mset` | `Cache.MSet` | Write many values as one batch, all with the same optional TTL |
| `cache_set_if` | `Cache.SetIf` | Write a value under a condition, with explicit control over the TTL |
| `cache_zadd` | `Cache.ZAdd` | Add scored members to a sorted set, or re-score ones already there |
| `cache_zrem` | `Cache.ZRem` | Remove members from a sorted set, returning how many were present |
| `cache_zscore` | `Cache.ZScore` | The score of one member, or null when it is not in the set |
| `cache_zcard` | `Cache.ZCard` | How many members a sorted set holds |
| `cache_zrank` | `Cache.ZRank` | A member's position in the ordering, or null when it is absent |
| `cache_zrange` | `Cache.ZRange` | Members by rank, `start..=stop` inclusive |
| `cache_zrangebyscore` | `Cache.ZRangeByScore` | Members by score, between two bounds |
| `cache_zincrby` | `Cache.ZIncrBy` | Add to a member's score, creating it at that score when absent |
| `cache_lock_acquire` | `Cache.LockAcquire` | Take a lease on a lock, or refresh one already held by `owner` |
| `cache_lock_renew` | `Cache.LockRenew` | Extend a lease the caller still holds |
| `cache_lock_release` | `Cache.LockRelease` | Give up a lock |
| `cache_setbit` | `Cache.SetBit` | Set one bit of a string value, growing it with zero bytes if needed |
| `cache_getbit` | `Cache.GetBit` | Read one bit |
| `cache_bitcount` | `Cache.BitCount` | Count the set bits, optionally within a byte range `(start, end)` with signed indices |
| `cache_bitpos` | `Cache.BitPos` | The position of the first bit equal to `bit`, optionally within a byte range, or -1 when there is none |
| `cache_bitop` | `Cache.BitOp` | Combine several values bitwise and store the result at `dest` |
| `cache_pfadd` | `Cache.PfAdd` | Add elements to a HyperLogLog, creating it when absent |
| `cache_pfcount` | `Cache.PfCount` | Estimated number of distinct elements |
| `cache_pfmerge` | `Cache.PfMerge` | Merge several HyperLogLogs into `dest`, which is included as a source when it already exists |
| `cache_lmove` | `Cache.LMove` | Atomically pop an element from one end of `source` and push it onto one end of `destination` |
| `cache_expire_at` | `Cache.ExpireAt` | Set the absolute instant an existing live key dies |
| `cache_stats` | `Cache.Stats` | What this node's cache is doing |
| `cache_flush_database` | `Cache.FlushDatabase` | Delete every cache key in this database, across every namespace |
| `cache_append` | `Cache.Append` | Concatenate bytes onto what a key already holds, and return the new length |
| `cache_compare_and_swap` | `Cache.CompareAndSwap` | Write only if the key still holds `expected` (null |
| `cache_getdel` | `Cache.GetDel` | Read a key and delete it in one atomic step |
| `cache_getset` | `Cache.GetSet` | Write a value and return the one it replaced, atomically |
| `cache_getex` | `Cache.GetEx` | Read a key and change its expiry in the same atomic step |
| `cache_ltrim` | `Cache.LTrim` | Keep only the inclusive index range of a list, dropping everything outside it |
| `cache_sunion` | `Cache.SUnion` | Every member of every named set, without duplicates |
| `cache_sinter` | `Cache.SInter` | The members present in every named set |
| `cache_sdiff` | `Cache.SDiff` | The members of the first set that are in none of the rest |
| `cache_srandmember` | `Cache.SRandMember` | Random members of a set, without removing them |
| `cache_hincrby` | `Cache.HIncrBy` | Add to one hash field, atomically, returning its new value |
| `cache_pipeline` | `Cache.Pipeline` | Run cache operations in order in one round trip, each exactly as if it had been sent alone |
| `cache_transaction` | `Cache.Transaction` | Run cache operations in order holding the cache write lock, so no other writer interleaves with them |
| `cache_script_load` | `Cache.ScriptLoad` | Store a script |
| `cache_script_run` | `Cache.ScriptRun` | Run a stored script with these arguments as one transaction |
| `cache_hot_keys` | `Cache.HotKeys` | The most frequently addressed keys on this node since it started, with estimated counts |
| `cache_purge_expired` | `Cache.PurgeExpired` | Delete every expired cache key in this database now, rather than leaving it to compaction |
| `cache_blpop` | `Cache.BLPop` | Pop the head of the first non-empty list among `keys`, waiting up to the timeout for one to receive an element |
| `cache_brpop` | `Cache.BRPop` | Pop the tail of the first non-empty list among `keys`, waiting up to the timeout for one to receive an element |
| `cache_set_namespace_limit` | `Cache.SetNamespaceLimit` | Cap a namespace at `max_keys` live keys and `max_bytes` of values |
| `cache_get_namespace_limit` | `Cache.GetNamespaceLimit` | A namespace's limit and what it holds now |
| `cache_publish` | `Cache.Publish` | Append a message to a channel, returning the id it was given |
| `cache_poll` | `Cache.Poll` | The messages after id `after` on these channels (a trailing `*` is a pattern) |

### Documents

| Method | Server operation | What it does |
| --- | --- | --- |
| `doc_replace` | `Document.Replace` | Swap a document's whole body for a new one |
| `doc_insert_many` | `Document.InsertMany` | Insert several documents as one atomic batch |
| `doc_delete_many` | `Document.DeleteMany` | Delete every document a filter matches, returning how many went |
| `doc_rename_collection` | `Document.RenameCollection` | Move a collection, with its documents and indexes, to a new name |
| `doc_purge_expired` | `Document.PurgeExpired` | Delete the documents a TTL index says have expired, now |
| `doc_explain` | `Document.Explain` | Run a find and describe how it ran instead of returning its documents |
| `doc_begin_transaction` | `Document.BeginTransaction` | Open a document transaction spanning requests, returning its id |
| `doc_commit_transaction` | `Document.CommitTransaction` | Commit a document transaction |
| `doc_rollback_transaction` | `Document.RollbackTransaction` | Discard a document transaction |
| `doc_rebuild_index` | `Document.RebuildIndex` | Rebuild one index from the stored documents |
| `doc_set_collection_options` | `Document.SetCollectionOptions` | Set a collection's options (`schema`, `defaults`, `versioned`), replacing any it had |
| `doc_get_collection_options` | `Document.GetCollectionOptions` | A collection's options |
| `doc_bulk_write` | `Document.BulkWrite` | Many inserts, updates, replaces and deletes on one collection, applied in order as one atomic batch |

### Vectors

| Method | Server operation | What it does |
| --- | --- | --- |
| `vector_embed` | `Vector.Embed` | Embed texts with the server's built-in embedder (deterministic feature hashing |
| `vector_upsert_text` | `Vector.UpsertText` | Embed each text at the collection's dimension and upsert the vectors as one atomic batch |
| `vector_set_alias` | `Vector.SetAlias` | Point an alias at a collection; a null collection removes it |
| `vector_list_aliases` | `Vector.ListAliases` | Every alias and the collection it names, as `{alias, collection}` |
| `vector_add_named_vector` | `Vector.AddNamedVector` | Declare a named vector on a collection |
| `vector_upsert_named` | `Vector.UpsertNamed` | Write an item's vectors by name (`default` is the collection's own), each with the same metadata |
| `vector_upsert_many` | `Vector.UpsertMany` | Write many vectors as one atomic batch |
| `vector_delete_many` | `Vector.DeleteMany` | Delete many vectors by id as one atomic batch, returning how many of the ids were present |
| `vector_search_batch` | `Vector.SearchBatch` | Run several query vectors against one collection in one request |
| `vector_delete_by_filter` | `Vector.DeleteByFilter` | Delete every vector whose metadata matches a filter, as one atomic batch |
| `vector_update_by_filter` | `Vector.UpdateByFilter` | Merge `set` into the metadata of every vector matching a filter, as one atomic batch |
| `vector_count` | `Vector.Count` | How many vectors a collection holds, or, with a filter, how many match it |
| `vector_list_partitions` | `Vector.ListPartitions` | The partitions of a collection |
| `vector_rename_collection` | `Vector.RenameCollection` | Rename a collection, moving its catalog record and every vector with it |
| `vector_rebuild_index` | `Vector.RebuildIndex` | Rebuild the collection's ANN index from its stored vectors and persist it, clearing every tombstone |
| `vector_index_stats` | `Vector.IndexStats` | The shape of the collection's ANN index |
| `vector_measure_recall` | `Vector.MeasureRecall` | Measure the ANN index's recall |
| `vector_search_multi` | `Vector.SearchMulti` | Search with several query vectors and return one fused ranking |
| `vector_set_collection_config` | `Vector.SetCollectionConfig` | Change a collection's configuration, returning it |
| `vector_copy_collection` | `Vector.CopyCollection` | Copy a collection (configuration and every vector) to a new name |
| `vector_search_by_examples` | `Vector.SearchByExamples` | Search with a query built from examples |

### Graphs

| Method | Server operation | What it does |
| --- | --- | --- |
| `graph_add_many` | `Graph.AddMany` | Write many nodes and edges as one unit |
| `graph_remove_many` | `Graph.RemoveMany` | Delete many nodes and edges as one unit |
| `graph_update_node` | `Graph.UpdateNode` | Change an existing node in place, returning it |
| `graph_update_edge` | `Graph.UpdateEdge` | Change an existing edge in place, returning it |
| `graph_copy` | `Graph.CopyGraph` | Copy a graph (nodes, edges and schema) to a new name |
| `graph_dfs` | `Graph.Dfs` | A bounded depth-first walk from a node |
| `graph_connected_components` | `Graph.ConnectedComponents` | Partition the graph's nodes into connected components, largest first |
| `graph_detect_cycle` | `Graph.DetectCycle` | Whether the graph contains a cycle (`hasCycle`), and one `cycle` as evidence |
| `graph_stats` | `Graph.GraphStats` | Counts describing a graph |
| `graph_subgraph` | `Graph.Subgraph` | The part of the graph within `max_depth` hops of the seeds |
| `graph_schema` | `Graph.GraphSchema` | What the graph's data looks like |
| `graph_k_shortest_paths` | `Graph.KShortestPaths` | The `k` cheapest loopless paths between two nodes, cheapest first (default 3, at most 20) |
| `graph_all_paths` | `Graph.AllPaths` | Every simple path between two nodes of at most `max_depth` edges (default 5, at most 10) |
| `graph_centrality` | `Graph.Centrality` | Betweenness, closeness or eigenvector centrality |
| `graph_communities` | `Graph.Communities` | Communities by Louvain modularity optimisation, direction ignored, largest first, with the partition's `modularity` |
| `graph_triangle_count` | `Graph.TriangleCount` | Triangles and clustering coefficients, direction ignored |
| `graph_node_similarity` | `Graph.NodeSimilarity` | The nodes whose neighbour sets most resemble a node's, under `results` |
| `graph_check_consistency` | `Graph.CheckConsistency` | Check a graph's stored records against each other and against the resident mirror |
| `graph_create_node_index` | `Graph.CreateNodeIndex` | Index node properties for finding nodes |
| `graph_create_constraint` | `Graph.CreateConstraint` | Enforce a rule on a property of every node (or, with target `edge`, every relationship) carrying a label |
| `graph_drop_schema_object` | `Graph.DropSchemaObject` | Drop an index or a constraint by name |
| `graph_list_schema_objects` | `Graph.ListSchemaObjects` | A graph's `indexes` and `constraints` |
| `graph_find_nodes` | `Graph.FindNodes` | Nodes with a label (when given) whose properties equal the given values, in id order |
| `graph_import_csv` | `Graph.ImportCsv` | Import nodes and edges from CSV text as one atomic batch, so constraints apply |
| `graph_page_rank` | `Graph.PageRank` | PageRank over edge direction |
| `graph_execute` | `Graph.Execute` | Run a Cypher write |
| `graph_begin_transaction` | `Graph.BeginTransaction` | Open a transaction on a graph, returning its id |
| `graph_commit_transaction` | `Graph.CommitTransaction` | Apply every statement queued in a graph transaction as one |
| `graph_rollback_transaction` | `Graph.RollbackTransaction` | Discard a graph transaction and its queued statements |
`doc_bulk_write` takes its operations from `TriCoreDB::BulkOp` (`insert`,
`update_one`, `replace`, `delete`), and a cache pipeline, transaction or script takes
its from `TriCoreDB::CacheOp`:

```ruby
db.doc_bulk_write("people", [
  TriCoreDB::BulkOp.insert({ "name" => "ada" }, id: "a"),
  TriCoreDB::BulkOp.update_one("a", set: { "city" => "Pune" }),
  TriCoreDB::BulkOp.delete("b")
]) # every operation lands, or none does

results = db.cache_pipeline([
  TriCoreDB::CacheOp.set("sessions", "abc", "ada"),
  TriCoreDB::CacheOp.get("sessions", "abc")
]) # => [{"ok" => {"Json" => {"set" => true}}}, {"ok" => {"CacheValue" => [97, 100, 97]}}]
```

A document transaction is named in each call that runs inside it, and a graph
transaction queues Cypher writes until it commits:

```ruby
txn = db.doc_begin_transaction
db.doc_insert("people", { "name" => "ada" }, id: "a", txn: txn)
db.doc_commit_transaction(txn)

graph_txn = db.graph_begin_transaction("social")
db.graph_execute("social", "CREATE (n:Person {name: 'ada'})", txn: graph_txn)
db.graph_commit_transaction("social", graph_txn)
```

A result with one meaningful field comes back as that value; a larger one comes back
as the server's own Hash, with the server's field names. Sorted-set bounds come from
`TriCoreDB::ScoreBound` (a bare number is an inclusive bound) and expiries from
`TriCoreDB::CacheExpiry`; search `options:` are the server's own names (`offset`,
`exact`, `using`, `namespace`, ...).

## LLM context

```ruby
bundle = db.llm_context([
  TriCoreDB::LlmSource.sql("SELECT id, name FROM users"),
  TriCoreDB::LlmSource.documents("products", limit: 50)
], format: "toon")

schema = db.llm_schema(format: "markdown")
```

Sensitive fields are redacted by default (`redact_sensitive: true`).

## Admin

```ruby
db.admin_ping
db.admin_status
```

Admin calls need the cluster module enabled on the server, even on a single node.
`db.ping` checks the connection itself and reaches no module.

## Errors

Every failure is a `TriCoreDB::Error`. Rescue the class you mean, and branch on
`code` rather than on the message text:

| Class | Means |
| --- | --- |
| `ServerError` | The request arrived and the operation failed. The connection stays usable. |
| `AuthError` | The credentials were refused. |
| `ProtocolError` | An ERROR frame, or a peer that broke the protocol. |
| `ConnectionError` | The transport failed, or the connection was already closed. |
| `ReadTimeout` | No reply in time; the connection is dropped, because the late reply must not be read as the next answer. |
| `FeatureNotGranted` | The server lacks a capability this call needs, so nothing was sent. |
| `ParameterError` | A value with no SQL form; nothing was sent. |
| `PoolTimeout` | No pooled connection became free in time. |

**Leader redirects.** In a cluster only the leader accepts writes, and a follower
refuses with `code == "not_leader"` (`error.redirect?`). The client handles that
itself (`follow_leader: true`, the default):

- when the refusal names the leader (`leader_hint`), it opens a connection there with
  the same user, secret and TLS settings (the leader's host is the certificate name),
  sends the request again, and keeps that connection (`db.address` reports it);
- while an election is in progress (no hint), it waits and asks the same node again,
  pausing 0.25 s, then 0.5 s, up to 2 s;
- after `leader_retries` (5) it raises the last refusal.

This is safe because a `not_leader` refusal was applied nowhere. Nothing is sent again
inside a session transaction, and never a refusal with `TriCoreDB::OUTCOME_UNKNOWN`: a
follower handed that request to the leader and lost the answer, or the leader could
not confirm it, so it may have been applied. The leader's address must be reachable
from your application; when it is not, the client keeps its connection and waits. A
pool passes these options to every connection. To handle redirects yourself, connect
with `follow_leader: false`:

```ruby
begin
  db.execute("INSERT INTO t VALUES (1)")
rescue TriCoreDB::ServerError => e
  raise unless e.code == TriCoreDB::NOT_LEADER
  retry_against(e.leader_hint) if e.leader_hint
end
```

## TLS

TLS is off until `tls:` is given.

```ruby
db = TriCoreDB::Client.connect(
  host: "db.internal", user: "admin", secret: "your-password",
  tls: { ca_file: "/etc/tricore/ca.pem", server_name: "db.internal" }
)
```

`tls: true` uses the system trust store. The options are `ca_file`, `server_name`,
`client_cert_file` and `client_key_file` (both or neither, for mutual TLS), and
`danger_accept_invalid_certs` — **development only**, since it encrypts the traffic
while authenticating nobody.

## Testing

```bash
rake test              # unit tests and the scripted-peer tests; no server needed
rake test:integration  # the live tests, against a private tricore-server
```

The scripted-peer tests play the answers a real cluster would send — a `not_leader`
refusal, a refused handshake, a frame that declares more bytes than it sends — so
they need no server. The live tests start their own `tricore-server` on an ephemeral
port: point `TRICORE_SERVER_BIN` at the binary. To use a server that is already
running instead, set `TRICORE_HOST`, `TRICORE_PORT`, `TRICORE_USER` and
`TRICORE_SECRET`. Without either they skip.

## License

[Apache License 2.0](LICENSE)
