# Changelog

All notable changes to the `tricoredb` gem are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the gem uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/trinesh14/tricoredb-sdk-ruby/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/trinesh14/tricoredb-sdk-ruby/releases/tag/v0.1.0
