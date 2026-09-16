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

**Leader redirects.** In a cluster, a write that reaches a follower fails with
`code == "not_leader"`, which `error.redirect?` and `response.redirect?` test. When
the cluster knows the leader, `leader_hint` holds its `host:port`; a `nil` hint means
the destination is unknown yet, so wait and retry — it does not mean the failure was
something else. This driver does not follow the redirect for you.

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
port: point `TRICORE_SERVER_BIN` at the binary, and without one they skip.

## License

[Apache License 2.0](LICENSE)
