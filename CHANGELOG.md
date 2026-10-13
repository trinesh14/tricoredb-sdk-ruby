# Changelog

All notable changes to the `tricoredb` gem are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the gem uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.3.0] - 2026-10-13

Every method added here needs a server at **0.1.0-rc.3 or later**. An older server
does not know the operation and answers it with an error.

### Added

- 116 methods, one for each operation the server gained since 0.1.0-rc.2. The README
  lists every one beside the server operation it sends.
  - Cache (53): sorted sets, locks with fencing tokens, bitmaps, HyperLogLog,
    multi-key reads and writes, conditional and atomic read-and-change writes,
    stale-while-revalidate reads, list moves and blocking pops, set algebra,
    pipelines, transactions and scripts, publish and poll, namespace limits and
    statistics.
  - Documents (13): `doc_replace`, `doc_insert_many`, `doc_delete_many`,
    `doc_bulk_write`, `doc_explain`, collection options, renaming, index rebuilds
    and transactions spanning requests.
  - Vectors (21): batch upserts and deletes, batch, multi-query and by-example
    searches, named vectors, aliases, filters, counts, partitions, text embedding,
    index statistics and collection configuration.
  - Graphs (29): bulk writes, in-place updates, traversals and algorithms
    (components, cycles, k shortest paths, centrality, communities, PageRank and
    more), indexes and constraints, CSV import, Cypher writes and transactions.
- `TriCoreDB::BulkOp`, the four kinds of item a `doc_bulk_write` takes, and
  `TriCoreDB::CacheOp`, the operations a cache pipeline, transaction or script runs.
- `TriCoreDB::ScoreBound` and `TriCoreDB::CacheExpiry`.
- `txn:` on `request` and on the document reads and writes, naming the document
  transaction a call runs inside.

### Fixed

- `in_transaction?` stays true while an outer transaction is open. Since 2026-09-29
  the server opens a nested block when `BEGIN` is sent inside a transaction, and the
  `COMMIT` or `ROLLBACK` that ends the block (answered with `nested_depth`) leaves
  the outer transaction open. The driver used to report the transaction as over, so
  a pool could lend the connection on with it still open.


## [0.2.0] - 2026-09-17

### Added

- Following the leader: a request refused with `not_leader` is sent again, to the
  leader the refusal names (over a new connection that replaces the current one) or,
  while no leader is known, to the same node after a pause. On by default;
  `follow_leader: false` restores the previous behaviour, and `leader_retries` (5) and
  `leader_retry_delay` (0.25 s) bound it. Never inside a session transaction.
- `TriCoreDB::OUTCOME_UNKNOWN`: a request that may or may not have been applied. It is
  never sent again.
- `Client#address`.

### Changed

- A `not_leader` error message says whether the client already retried.

## [0.1.0] - 2026-09-16

First release.

### Added

- `TriCoreDB::Client`: the native `tricore` wire protocol over TCP or TLS, with
  HELLO feature negotiation and password authentication. Ruby 3.1 and later, and
  nothing outside the standard library.
- SQL: `query` and `execute` with `?` placeholders bound **by the server**, plus
  one-request scripts (`transaction`) and session transactions
  (`begin_transaction`, `commit`, `rollback`).
- `TriCoreDB::Pool`: a thread-safe pool that lends a connection to a block and never
  returns one with a transaction still open.
- Families for documents, cache (keys, lists, sets, hashes, streams), vectors,
  graphs, LLM context export and the admin reads.
- Builders for filters, aggregation stages, accumulators and LLM sources, so the
  request JSON is never written by hand.
- Typed failures under `TriCoreDB::Error`, each carrying the server's own `code`;
  `redirect?` and `leader_hint` for a `not_leader` refusal.
- `TriCoreDB::Binary` for values bound to a `BLOB` column, whatever the String's
  encoding.

### Security

- A call that needs a capability the server did not grant — server-side parameters,
  session transactions — raises `FeatureNotGranted` before anything is sent, rather
  than falling back to a weaker behaviour.
- Both directions enforce the protocol's frame ceilings, and a declared length is
  checked before a payload byte is read, so a wrong or hostile peer cannot make the
  driver allocate what it claimed.
- A connection that timed out or lost frame alignment is dropped rather than reused:
  a late reply can never be read as the answer to the next request.
- A value with no SQL form is refused by name instead of being pushed through
  `to_s`, and text that is not valid UTF-8 is refused rather than sent as mojibake.

[Unreleased]: https://github.com/trinesh14/tricoredb-sdk-ruby/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/trinesh14/tricoredb-sdk-ruby/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/trinesh14/tricoredb-sdk-ruby/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/trinesh14/tricoredb-sdk-ruby/releases/tag/v0.1.0
