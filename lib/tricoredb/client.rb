# frozen_string_literal: true

require "securerandom"

module TriCoreDB
  # Optional protocol capabilities, negotiated in HELLO as a bitmap.
  module Features
    # The server echoes `correlation_id` into its logs and traces.
    CORRELATION_ID = 1
    # The server binds `?` placeholders itself, from a typed `params` array.
    SERVER_PARAMS = 2
    # `BEGIN`, statements and `COMMIT`/`ROLLBACK` as separate requests on one connection.
    SESSION_TXN = 4
    # Every capability this driver understands.
    ALL = CORRELATION_ID | SERVER_PARAMS | SESSION_TXN
  end

  # One connection to a TriCoreDB server, speaking the native `tricore` protocol.
  #
  # A connection is a single request/response stream. Calls from several threads
  # are serialised by an internal lock, so they are safe but not concurrent; use
  # a {Pool} for concurrency.
  #
  # @example
  #   db = TriCoreDB.connect(host: "127.0.0.1", port: 8427, user: "admin", secret: ENV["TRICORE_SECRET"])
  #   db.execute("INSERT INTO t VALUES (?, ?)", [1, "ada"])
  #   db.query("SELECT name FROM t WHERE id = ?", [1]).rows # => [["ada"]]
  #   db.close
  class Client
    DEFAULT_PORT = 8427
    DEFAULT_DATABASE = "main"
    CLOSE_TIMEOUT = 2

    # @return [Integer] the feature bitmap the server granted in HELLO_OK
    attr_reader :granted_features
    # @return [String, nil] the session id issued by AUTH_OK
    attr_reader :session_id
    # @return [String, nil] the request id most recently sent; pass it to {#cancel} on another connection
    attr_reader :last_request_id
    # @return [String] the database used when a call does not name one
    attr_accessor :database
    # @return [Numeric, nil] client-side seconds to wait for a reply; nil (the default) waits for as long as the statement runs
    attr_accessor :read_timeout
    # @return [Integer, nil] a server-side deadline in milliseconds sent with every request
    attr_accessor :request_timeout_ms

    # Connect, handshake and (when `user` is given) authenticate.
    #
    # @param host [String]
    # @param port [Integer]
    # @param user [String, nil]
    # @param secret [String] password or token; sent as its bytes
    # @param database [String]
    # @param connect_timeout [Numeric, nil] seconds covering TCP connect, TLS, HELLO and AUTH
    # @param read_timeout [Numeric, nil] seconds to wait for each reply after connecting
    # @param request_timeout_ms [Integer, nil] server-side deadline for every request
    # @param tls [Hash, true, nil] see {Transport.tls_context}
    # @param client_name [String]
    # @param features [Integer] capabilities to request
    # @return [Client]
    # @raise [ConnectionError, ProtocolError, AuthError]
    def self.connect(host: "127.0.0.1", port: DEFAULT_PORT, user: nil, secret: "", database: DEFAULT_DATABASE,
                     connect_timeout: 10, read_timeout: nil, request_timeout_ms: nil, tls: nil,
                     client_name: "tricoredb-ruby/#{VERSION}", features: Features::ALL)
      transport = Transport.open(host, Integer(port), connect_timeout: connect_timeout, tls: tls)
      client = new(transport, database: database)
      begin
        client.handshake(client_name: client_name, features: features, timeout: connect_timeout)
        client.authenticate(user, secret, timeout: connect_timeout) unless user.nil?
      rescue Exception # rubocop:disable Lint/RescueException
        transport.close
        raise
      end
      client.read_timeout = read_timeout
      client.request_timeout_ms = request_timeout_ms
      client
    end

    # Wrap an already-open transport. {Client.connect} is the usual entry point.
    #
    # @param transport [Transport]
    # @param database [String]
    def initialize(transport, database: DEFAULT_DATABASE)
      @transport = transport
      @database = database
      @lock = Mutex.new
      @rid = 0
      @rid_prefix = "rb-#{Process.pid.to_s(16)}-#{SecureRandom.hex(6)}"
      @granted_features = 0
      @txn_open = false
      @read_timeout = nil
      @request_timeout_ms = nil
    end

    # @return [Hash{Symbol => Object}] the granted features by name, plus `:mask`
    def features
      g = @granted_features
      {
        mask: g,
        correlation_id: g & Features::CORRELATION_ID != 0,
        server_params: g & Features::SERVER_PARAMS != 0,
        session_txn: g & Features::SESSION_TXN != 0
      }
    end

    # @return [Boolean]
    def closed?
      @transport.closed?
    end

    # @return [Boolean] true from a successful {#begin_transaction} until commit or rollback
    def in_transaction?
      @txn_open && !closed?
    end

    # Send HELLO and read HELLO_OK. Called by {Client.connect}.
    # @return [Integer] the granted feature bitmap
    def handshake(client_name: "tricoredb-ruby/#{VERSION}", features: Features::ALL, timeout: 10)
      tag, body = exchange(Frame::HELLO, {
                             "protocol" => "tricore",
                             "version" => { "major" => 1, "minor" => 0 },
                             "client" => client_name,
                             "features" => features
                           }, timeout: timeout)
      if tag == Frame::ERROR
        fail_stream(ProtocolError.new(error_text(body), code: error_code(body)))
      end
      fail_stream(ProtocolError.new("expected HELLO_OK, got #{Frame.name(tag)}")) unless tag == Frame::HELLO_OK
      unless body.is_a?(Hash) && body["ok"] == true
        message = body.is_a?(Hash) ? body["message"] : nil
        fail_stream(ProtocolError.new(message || "handshake refused", code: body.is_a?(Hash) ? body["code"] : nil))
      end
      @granted_features = Integer(body["features"] || 0)
    end

    # Send AUTH and read AUTH_OK.
    #
    # A refused login arrives as AUTH_OK with `ok: false`, not as an ERROR frame;
    # both are raised as {AuthError}.
    #
    # @return [String, nil] the session id
    # @raise [AuthError]
    def authenticate(user, secret, timeout: @read_timeout)
      tag, body = exchange(Frame::AUTH, { "username" => user.to_s, "secret" => secret.to_s.bytes }, timeout: timeout)
      raise AuthError.new(error_text(body), code: error_code(body)) if tag == Frame::ERROR
      fail_stream(ProtocolError.new("expected AUTH_OK, got #{Frame.name(tag)}")) unless tag == Frame::AUTH_OK
      unless body.is_a?(Hash) && body["ok"] == true
        raise AuthError, (body.is_a?(Hash) && body["message"]) || "authentication refused"
      end

      @session_id = body["session_id"]
    end

    # Exchange PING/PONG. Never reaches a module; see {#admin_ping} for a full round trip.
    # @return [true]
    def ping
      tag, _body = exchange(Frame::PING, nil)
      fail_stream(ProtocolError.new("expected PONG, got #{Frame.name(tag)}")) unless tag == Frame::PONG
      true
    end

    # Ask the server to stop one of this principal's running statements.
    #
    # Send this on a **second connection**: the connection running the statement
    # is waiting for its reply and cannot carry anything else.
    #
    # @param request_id [String]
    # @return [Integer] how many executions were cancelled (0 for an unknown id)
    def cancel(request_id)
      tag, body = exchange(Frame::CANCEL, { "request_id" => request_id.to_s })
      raise ServerError.new(error_text(body), code: error_code(body), frame: true) if tag == Frame::ERROR
      fail_stream(ProtocolError.new("expected CANCEL_OK, got #{Frame.name(tag)}")) unless tag == Frame::CANCEL_OK
      body.is_a?(Hash) ? Integer(body["cancelled"] || 0) : 0
    end

    # Say goodbye and close the socket. Idempotent; never raises.
    def close
      return if closed?

      begin
        exchange(Frame::CLOSE, nil, timeout: CLOSE_TIMEOUT)
      rescue StandardError
        nil
      ensure
        @transport.close
      end
      nil
    end

    # Send a raw operation.
    #
    # @param op [Hash, String] an externally tagged TriCoreOp, e.g. `{"Cache" => "Ping"}`
    # @param database [String]
    # @param correlation_id [String, nil] requires the CORRELATION_ID feature
    # @return [Response] only when its status is `ok`
    # @raise [ServerError] for any other status, or an ERROR frame
    def request(op, database: @database, correlation_id: nil)
      payload = {
        "request_id" => next_request_id,
        "database" => database,
        "region_hint" => nil,
        "op" => op
      }
      unless correlation_id.nil?
        require_feature(Features::CORRELATION_ID, "CORRELATION_ID", "a correlation id")
        payload["correlation_id"] = correlation_id.to_s
      end
      unless @request_timeout_ms.nil?
        payload["options"] = {
          "cache" => { "mode" => "disabled" },
          "output" => "native",
          "consistency" => "strong_primary",
          "timeout_ms" => Integer(@request_timeout_ms),
          "llm" => nil
        }
      end
      tag, body = exchange(Frame::REQUEST, payload)
      raise ServerError.new(error_text(body), code: error_code(body), frame: true) if tag == Frame::ERROR
      fail_stream(ProtocolError.new("expected RESPONSE, got #{Frame.name(tag)}")) unless tag == Frame::RESPONSE

      response = Response.new(body)
      raise response.to_error(@txn_open) unless response.ok?

      response
    end

    # ---- SQL -----------------------------------------------------------------

    # Run a write or DDL statement.
    #
    # @param sql [String]
    # @param params [Array, nil] values for `?` placeholders, bound by the server; see {Params}
    # @return [Response] use {Response#rows_affected}
    # @raise [FeatureNotGranted] when params are given and SERVER_PARAMS was not granted
    def execute(sql, params = nil, database: @database)
      request({ "Sql" => { "Exec" => sql_body(sql, params) } }, database: database)
    end

    # Run a read. The server refuses a write sent this way.
    #
    # @param sql [String]
    # @param params [Array, nil]
    # @return [Rows]
    def query(sql, params = nil, database: @database)
      resp = request({ "Sql" => { "Query" => sql_body(sql, params) } }, database: database)
      rows = resp.arm("Rows")
      raise ProtocolError, "expected Rows, got #{resp.kind}" unless rows.is_a?(Hash)

      Rows.new(rows["columns"] || [], rows["rows"] || [])
    end

    # ---- session transactions ---------------------------------------------------

    # Open a session transaction on this connection. Requires SESSION_TXN.
    # @return [Hash] the server's outcome
    # @raise [FeatureNotGranted]
    def begin_transaction(database: @database)
      require_feature(Features::SESSION_TXN, "SESSION_TXN",
                      "begin/commit/rollback (send a whole `BEGIN; ...; COMMIT` script with #execute instead)")
      txn_control("BEGIN", database)
    end
    alias begin begin_transaction

    # Commit the open block.
    # @return [Hash]
    def commit(database: @database)
      txn_control("COMMIT", database)
    end

    # Discard the open block.
    # @return [Hash]
    def rollback(database: @database)
      txn_control("ROLLBACK", database)
    end

    # Begin, yield this connection, and commit. If the block raises, roll back
    # and re-raise the original exception.
    #
    # @yieldparam db [Client]
    # @return [Object] the block's value
    def transaction(database: @database)
      raise ArgumentError, "transaction needs a block" unless block_given?

      begin_transaction(database: database)
      begin
        result = yield self
      rescue Exception # rubocop:disable Lint/RescueException
        if in_transaction?
          begin
            rollback(database: database)
          rescue StandardError
            nil
          end
        end
        raise
      end
      commit(database: database)
      result
    end

    # ---- cache ---------------------------------------------------------------
    #
    # Values are bytes. Pass any String (its bytes are sent as they are) or an
    # Array of Integers; values come back as binary (ASCII-8BIT) Strings.

    # Liveness through the cache module.
    def cache_ping(database: @database)
      request({ "Cache" => "Ping" }, database: database)
      true
    end

    def cache_set(namespace, key, value, ttl_ms: nil, database: @database)
      cache("Set", { "namespace" => namespace, "key" => key, "value" => bytes(value, "value"), "ttl_ms" => ttl_ms }, database)
      nil
    end

    # @return [String, nil] binary String, nil on a miss
    def cache_get(namespace, key, database: @database)
      cache_value(cache("Get", nk(namespace, key), database), "get")
    end

    # @return [Boolean] whether the key existed
    def cache_delete(namespace, key, database: @database)
      json(cache("Delete", nk(namespace, key), database), "delete")["deleted"] == true
    end

    # @return [Boolean]
    def cache_exists?(namespace, key, database: @database)
      json(cache("Exists", nk(namespace, key), database), "exists")["exists"] == true
    end

    # @return [Integer, nil] remaining milliseconds; nil when the key is missing or has no expiry
    def cache_ttl(namespace, key, database: @database)
      ttl = json(cache("Ttl", nk(namespace, key), database), "ttl")["ttl_ms"]
      ttl.is_a?(Integer) ? ttl : nil
    end

    # @return [Integer] keys removed
    def cache_clear_namespace(namespace, database: @database)
      json(cache("ClearNamespace", { "namespace" => namespace }, database), "clear")["cleared"]
    end

    # @return [Integer] the new value
    def cache_incr(namespace, key, by = 1, database: @database)
      json(cache("Incr", nk(namespace, key).merge("by" => Integer(by)), database), "incr")["value"]
    end

    # @return [Boolean] false when the key does not exist
    def cache_expire(namespace, key, ttl_ms, database: @database)
      json(cache("Expire", nk(namespace, key).merge("ttl_ms" => Integer(ttl_ms)), database), "expire")["updated"] == true
    end

    # @return [Boolean] false when the key had no TTL
    def cache_persist(namespace, key, database: @database)
      json(cache("Persist", nk(namespace, key), database), "persist")["persisted"] == true
    end

    # Set only if absent.
    # @return [Boolean] whether this call stored the value
    def cache_set_nx(namespace, key, value, ttl_ms: nil, database: @database)
      body = nk(namespace, key).merge("value" => bytes(value, "value"), "ttl_ms" => ttl_ms)
      json(cache("SetNx", body, database), "setnx")["set"] == true
    end

    # @param pattern [String, nil] a glob where `*` matches any run of characters
    # @return [Array<Hash>] one Hash per key (`"key"`, and the TTL and size the server reports)
    def cache_keys(namespace, pattern: nil, limit: nil, database: @database)
      json(cache("Keys", { "namespace" => namespace, "pattern" => pattern, "limit" => limit }, database), "keys")["keys"] || []
    end

    # @return [Integer] the new length
    def cache_lpush(namespace, key, values, database: @database)
      json(cache("LPush", nk(namespace, key).merge("values" => byte_list(values, "values")), database), "lpush")["length"]
    end

    # @return [Integer] the new length
    def cache_rpush(namespace, key, values, database: @database)
      json(cache("RPush", nk(namespace, key).merge("values" => byte_list(values, "values")), database), "rpush")["length"]
    end

    # @return [String, nil]
    def cache_lpop(namespace, key, database: @database)
      cache_value(cache("LPop", nk(namespace, key), database), "lpop")
    end

    # @return [String, nil]
    def cache_rpop(namespace, key, database: @database)
      cache_value(cache("RPop", nk(namespace, key), database), "rpop")
    end

    # Inclusive range; negative indices count from the end.
    # @return [Array<String>]
    def cache_lrange(namespace, key, start, stop, database: @database)
      body = nk(namespace, key).merge("start" => Integer(start), "stop" => Integer(stop))
      binaries(json(cache("LRange", body, database), "lrange")["values"])
    end

    # @return [Integer]
    def cache_llen(namespace, key, database: @database)
      json(cache("LLen", nk(namespace, key), database), "llen")["length"]
    end

    # @return [String, nil]
    def cache_lindex(namespace, key, index, database: @database)
      cache_value(cache("LIndex", nk(namespace, key).merge("index" => Integer(index)), database), "lindex")
    end

    # @return [Integer] members newly added
    def cache_sadd(namespace, key, members, database: @database)
      json(cache("SAdd", nk(namespace, key).merge("members" => byte_list(members, "members")), database), "sadd")["added"]
    end

    # @return [Integer] members that were present
    def cache_srem(namespace, key, members, database: @database)
      json(cache("SRem", nk(namespace, key).merge("members" => byte_list(members, "members")), database), "srem")["removed"]
    end

    # @return [Boolean]
    def cache_sismember?(namespace, key, member, database: @database)
      body = nk(namespace, key).merge("member" => bytes(member, "member"))
      json(cache("SIsMember", body, database), "sismember")["is_member"] == true
    end

    # @return [Integer]
    def cache_scard(namespace, key, database: @database)
      json(cache("SCard", nk(namespace, key), database), "scard")["cardinality"]
    end

    # @return [Array<String>] in ascending byte order
    def cache_smembers(namespace, key, database: @database)
      binaries(json(cache("SMembers", nk(namespace, key), database), "smembers")["members"])
    end

    # @param entries [Hash, Array<Array(String, String)>] field => value
    # @return [Integer] fields newly created
    def cache_hset(namespace, key, entries, database: @database)
      json(cache("HSet", nk(namespace, key).merge("entries" => pairs(entries, "entries")), database), "hset")["created"]
    end

    # @return [String, nil]
    def cache_hget(namespace, key, field, database: @database)
      cache_value(cache("HGet", nk(namespace, key).merge("field" => bytes(field, "field")), database), "hget")
    end

    # @return [Integer] fields that were present
    def cache_hdel(namespace, key, fields, database: @database)
      json(cache("HDel", nk(namespace, key).merge("fields" => byte_list(fields, "fields")), database), "hdel")["deleted"]
    end

    # @return [Array<Array(String, String)>] binary pairs in ascending field order
    def cache_hgetall(namespace, key, database: @database)
      (json(cache("HGetAll", nk(namespace, key), database), "hgetall")["entries"] || []).map do |f, v|
        [f.pack("C*"), v.pack("C*")]
      end
    end

    # @return [Boolean]
    def cache_hexists?(namespace, key, field, database: @database)
      json(cache("HExists", nk(namespace, key).merge("field" => bytes(field, "field")), database), "hexists")["exists"] == true
    end

    # @return [Integer]
    def cache_hlen(namespace, key, database: @database)
      json(cache("HLen", nk(namespace, key), database), "hlen")["length"]
    end

    # Append a stream entry.
    # @param fields [Hash, Array<Array(String, String)>]
    # @param id [String, nil] nil or `*` to auto-generate
    # @return [String] the assigned `<ms>-<seq>` id
    def cache_xadd(namespace, key, fields, id: nil, database: @database)
      body = nk(namespace, key).merge("id" => id, "fields" => pairs(fields, "fields"))
      json(cache("XAdd", body, database), "xadd")["id"]
    end

    # @return [Integer]
    def cache_xlen(namespace, key, database: @database)
      json(cache("XLen", nk(namespace, key), database), "xlen")["length"]
    end

    # @return [Array<StreamEntry>] oldest first
    def cache_xrange(namespace, key, start = "-", stop = "+", count: nil, database: @database)
      body = nk(namespace, key).merge("start" => start, "end" => stop, "count" => count)
      stream_entries(json(cache("XRange", body, database), "xrange"))
    end

    # Entries strictly newer than `after`. Never blocks.
    # @return [Array<StreamEntry>]
    def cache_xread(namespace, key, after = "0-0", count: nil, database: @database)
      body = nk(namespace, key).merge("after" => after, "count" => count)
      stream_entries(json(cache("XRead", body, database), "xread"))
    end

    # @return [Integer] entries deleted
    def cache_xdel(namespace, key, ids, database: @database)
      json(cache("XDel", nk(namespace, key).merge("ids" => Array(ids).map(&:to_s)), database), "xdel")["deleted"]
    end

    # @return [Integer] entries evicted
    def cache_xtrim(namespace, key, max_len, database: @database)
      json(cache("XTrim", nk(namespace, key).merge("max_len" => Integer(max_len)), database), "xtrim")["trimmed"]
    end

    # ---- document --------------------------------------------------------------

    def doc_create_collection(collection, database: @database)
      document("CreateCollection", { "collection" => collection }, database)
      nil
    end

    # @param id [String, nil] omitted, the server generates one
    # @return [String] the stored id
    def doc_insert(collection, doc, id: nil, database: @database)
      json(document("Insert", { "collection" => collection, "id" => id, "document" => doc }, database), "insert")["id"]
    end

    # @return [Hash, nil]
    def doc_get(collection, id, database: @database)
      documents(document("Get", { "collection" => collection, "id" => id }, database), "get").first
    end

    # @param filter [String, Hash] from {Filter}
    # @return [Array<Hash>]
    def doc_find(collection, filter = Filter.all, limit: nil, database: @database)
      documents(document("Find", { "collection" => collection, "filter" => filter, "limit" => limit }, database), "find")
    end

    # Set fields on an existing document (dot paths). Not an upsert.
    def doc_update(collection, id, set, database: @database)
      document("Update", { "collection" => collection, "id" => id, "set" => set }, database)
      nil
    end

    # @return [Hash] `"updated"`, `"inserted"`, `"id"`
    def doc_update_one(collection, id, set: nil, inc: nil, upsert: false, database: @database)
      body = { "collection" => collection, "id" => id, "update" => update_body(set, inc), "upsert" => upsert ? true : false }
      json(document("UpdateOne", body, database), "updateOne")
    end

    # @return [Hash] `"matched"`, `"modified"`
    def doc_update_many(collection, filter, set: nil, inc: nil, database: @database)
      body = { "collection" => collection, "filter" => filter, "update" => update_body(set, inc) }
      json(document("UpdateMany", body, database), "updateMany")
    end

    def doc_delete(collection, id, database: @database)
      document("Delete", { "collection" => collection, "id" => id }, database)
      nil
    end

    # @return [Array<String>]
    def doc_list_collections(database: @database)
      json(request({ "Document" => "ListCollections" }, database: database), "listCollections")["collections"] || []
    end

    def doc_drop_collection(collection, database: @database)
      document("DropCollection", { "collection" => collection }, database)
      nil
    end

    def doc_create_index(collection, index_name, field, unique: false, database: @database)
      body = { "collection" => collection, "index_name" => index_name, "field" => field, "unique" => unique ? true : false }
      document("CreateIndex", body, database)
      nil
    end

    def doc_drop_index(collection, index_name, database: @database)
      document("DropIndex", { "collection" => collection, "index_name" => index_name }, database)
      nil
    end

    # @return [Array<Hash>] `"index_name"`, `"field"`, `"unique"`
    def doc_list_indexes(collection, database: @database)
      json(document("ListIndexes", { "collection" => collection }, database), "listIndexes")["indexes"] || []
    end

    # @return [Hash] `"document_count"` and the other statistics
    def doc_analyze(collection, database: @database)
      json(document("Analyze", { "collection" => collection }, database), "analyze")
    end

    # @param pipeline [Array<Hash>] from {Stage}
    # @return [Array<Hash>]
    def doc_aggregate(collection, pipeline, database: @database)
      documents(document("Aggregate", { "collection" => collection, "pipeline" => pipeline }, database), "aggregate")
    end

    # ---- vector ----------------------------------------------------------------

    # @param metric [String] `cosine`, `dot` or `l2`
    # @param quantization [String] `none` or `int8`
    def vector_create_collection(collection, dimension, metric: "cosine", quantization: "none", database: @database)
      body = { "collection" => collection, "dimension" => Integer(dimension), "metric" => metric.to_s,
               "quantization" => quantization.to_s }
      vector("CreateCollection", body, database)
      nil
    end

    # @return [String] the id
    def vector_upsert(collection, id, values, metadata: nil, database: @database)
      body = { "collection" => collection, "id" => id, "vector" => numbers(values), "metadata" => metadata }
      json(vector("Upsert", body, database), "upsert")["id"]
    end

    # @return [Hash, nil] `"id"`, `"vector"`, `"metadata"`
    def vector_get(collection, id, database: @database)
      json(vector("Get", { "collection" => collection, "id" => id }, database), "vector get")
    end

    def vector_delete(collection, id, database: @database)
      vector("Delete", { "collection" => collection, "id" => id }, database)
      nil
    end

    # @param filter [Hash, nil] metadata field => required value (exact equality)
    # @return [Array<Hash>] `"id"`, `"score"`, `"metadata"`, best first
    def vector_search(collection, values, top_k, filter: nil, database: @database)
      body = { "collection" => collection, "vector" => numbers(values), "top_k" => Integer(top_k), "filter" => filter }
      json(vector("Search", body, database), "search")["results"] || []
    end

    # @return [Array<String>]
    def vector_list_collections(database: @database)
      json(request({ "Vector" => "ListCollections" }, database: database), "listCollections")["collections"] || []
    end

    # @return [Hash] `"dimension"`, `"metric"`, `"count"`, `"quantization"`
    def vector_describe_collection(collection, database: @database)
      json(vector("DescribeCollection", { "collection" => collection }, database), "describeCollection")
    end

    # @return [Hash] `"vectors"`, `"count"`, `"total"`, `"truncated"`
    def vector_list_vectors(collection, limit: nil, offset: nil, database: @database)
      json(vector("ListVectors", { "collection" => collection, "limit" => limit, "offset" => offset }, database), "listVectors")
    end

    def vector_drop_collection(collection, database: @database)
      vector("DropCollection", { "collection" => collection }, database)
      nil
    end

    # ---- graph -----------------------------------------------------------------
    #
    # `direction` is `outgoing` (the default), `incoming` or `both`.

    def graph_create(graph, database: @database)
      graph_op("CreateGraph", { "graph" => graph }, database)
      nil
    end

    def graph_drop(graph, database: @database)
      graph_op("DropGraph", { "graph" => graph }, database)
      nil
    end

    # @return [Array<String>]
    def graph_list(database: @database)
      json(request({ "Graph" => "ListGraphs" }, database: database), "listGraphs")["graphs"] || []
    end

    # @return [String] the id
    def graph_add_node(graph, id, labels: [], properties: {}, database: @database)
      body = { "graph" => graph, "id" => id, "labels" => Array(labels), "properties" => properties || {} }
      json(graph_op("AddNode", body, database), "addNode")["id"]
    end

    # @return [Hash, nil] `"id"`, `"labels"`, `"properties"`
    def graph_get_node(graph, id, database: @database)
      json(graph_op("GetNode", { "graph" => graph, "id" => id }, database), "getNode")
    end

    def graph_delete_node(graph, id, database: @database)
      graph_op("DeleteNode", { "graph" => graph, "id" => id }, database)
      nil
    end

    # @return [String] the id
    def graph_add_edge(graph, id, from, to, label, properties: {}, database: @database)
      body = { "graph" => graph, "id" => id, "from" => from, "to" => to, "label" => label, "properties" => properties || {} }
      json(graph_op("AddEdge", body, database), "addEdge")["id"]
    end

    # @return [Hash, nil] `"id"`, `"from"`, `"to"`, `"label"`, `"properties"`
    def graph_get_edge(graph, id, database: @database)
      json(graph_op("GetEdge", { "graph" => graph, "id" => id }, database), "getEdge")
    end

    def graph_delete_edge(graph, id, database: @database)
      graph_op("DeleteEdge", { "graph" => graph, "id" => id }, database)
      nil
    end

    # @return [Array<Hash>] `"node_id"`, `"edge_id"`, `"label"`, `"direction"`
    def graph_neighbors(graph, node_id, direction: "outgoing", label: nil, limit: nil, database: @database)
      body = { "graph" => graph, "node_id" => node_id, "direction" => direction.to_s, "label" => label, "limit" => limit }
      json(graph_op("Neighbors", body, database), "neighbors")["neighbors"] || []
    end

    # @return [Integer]
    def graph_degree(graph, node_id, direction: "outgoing", database: @database)
      body = { "graph" => graph, "node_id" => node_id, "direction" => direction.to_s }
      json(graph_op("Degree", body, database), "degree")["degree"]
    end

    # Bounded breadth-first walk.
    # @return [Hash] `"nodes"` (each with `"depth"`), `"count"`, `"truncated"`, `"max_depth"`, `"limit"`
    def graph_traverse(graph, start, direction: "outgoing", label: nil, max_depth: nil, limit: nil, database: @database)
      body = { "graph" => graph, "start" => start, "direction" => direction.to_s, "label" => label,
               "max_depth" => max_depth, "limit" => limit }
      json(graph_op("Traverse", body, database), "traverse")
    end

    # Fewest hops. "No path" is `"found" => false`, not an error.
    # @return [Hash] `"found"`, `"hops"`, `"node_path"`, `"edge_path"`
    def graph_shortest_path(graph, from, to, direction: "outgoing", label: nil, max_depth: nil, database: @database)
      body = { "graph" => graph, "from" => from, "to" => to, "direction" => direction.to_s, "label" => label,
               "max_depth" => max_depth }
      json(graph_op("ShortestPath", body, database), "shortestPath")
    end

    # Least summed edge weight.
    # @return [Hash] `"found"`, `"total_cost"`, `"node_path"`, `"edge_path"`
    def graph_weighted_shortest_path(graph, from, to, direction: "outgoing", label: nil, weight_property: nil,
                                     database: @database)
      body = { "graph" => graph, "from" => from, "to" => to, "direction" => direction.to_s, "label" => label,
               "weight_property" => weight_property }
      json(graph_op("WeightedShortestPath", body, database), "weightedShortestPath")
    end

    # @return [Hash] `"nodes"`, `"count"`, `"total"`, `"truncated"`
    def graph_list_nodes(graph, limit: nil, offset: nil, database: @database)
      json(graph_op("ListNodes", { "graph" => graph, "limit" => limit, "offset" => offset }, database), "listNodes")
    end

    # @return [Hash] `"edges"`, `"count"`, `"total"`, `"truncated"`
    def graph_list_edges(graph, limit: nil, offset: nil, database: @database)
      json(graph_op("ListEdges", { "graph" => graph, "limit" => limit, "offset" => offset }, database), "listEdges")
    end

    # Read-only Cypher subset.
    # @return [Hash] `"columns"`, `"rows"`, `"count"`, `"truncated"`
    def graph_query(graph, cypher, database: @database)
      json(graph_op("Query", { "graph" => graph, "cypher" => cypher }, database), "query")
    end

    # ---- llm ---------------------------------------------------------------------

    # Export the schema catalogue.
    # @param format [String] `toon`, `json`, `markdown` or `native`
    # @return [String, Object] text for toon/markdown, a JSON value otherwise
    def llm_schema(format: "toon", max_rows: nil, redact_sensitive: true, include_schema: false, database: @database)
      body = { "format" => format.to_s, "options" => llm_options(max_rows, redact_sensitive, include_schema) }
      rendered(request({ "Llm" => { "Schema" => body } }, database: database))
    end

    # Assemble a context bundle from read-only sources.
    # @param sources [Array<Hash>] from {LlmSource}, or `{sql:}` / `{collection:}`
    # @return [String, Object]
    def llm_context(sources, format: "toon", max_rows: nil, redact_sensitive: true, include_schema: false,
                    database: @database)
      wire = (sources.is_a?(Array) ? sources : [sources]).map { |s| LlmSource.coerce(s) }
      raise ArgumentError, "a context bundle needs at least one source" if wire.empty?

      body = { "sources" => wire, "format" => format.to_s,
               "options" => llm_options(max_rows, redact_sensitive, include_schema) }
      rendered(request({ "Llm" => { "Context" => body } }, database: database))
    end

    # ---- admin -------------------------------------------------------------------

    # A request through the full pipeline (auth, routing, dispatch).
    def admin_ping(database: @database)
      request({ "Admin" => "Ping" }, database: database)
      true
    end

    # @return [Hash]
    def admin_status(database: @database)
      resp = request({ "Admin" => "Status" }, database: database)
      return { "message" => resp.arm("Message") } if resp.arm?("Message")

      json(resp, "status")
    end

    # Holds the connection lock for one frame pair. Any failure between writing
    # and finishing the read closes the connection: the stream position is unknown.
    # @api private
    def exchange(tag, payload, timeout: @read_timeout)
      @lock.synchronize do
        raise ConnectionError, "connection is closed" if closed?

        bytes = Frame.encode(tag, payload)
        done = false
        begin
          @transport.io.write(bytes)
          result = @transport.read_frame(timeout)
          done = true
          result
        rescue IOError, SystemCallError, OpenSSL::SSL::SSLError => e
          raise ConnectionError, "socket error: #{e.message}"
        ensure
          unless done
            @transport.close
            @txn_open = false
          end
        end
      end
    end

    private

    def fail_stream(error)
      @transport.close
      @txn_open = false
      raise error
    end

    def next_request_id
      @lock.synchronize do
        @rid += 1
        @last_request_id = "#{@rid_prefix}-#{@rid}"
      end
    end

    def require_feature(bit, name, what)
      return if @granted_features & bit != 0

      raise FeatureNotGranted.new(
        name,
        "the server did not grant #{name} in the handshake, so this connection cannot use #{what}"
      )
    end

    def sql_body(sql, params)
      raise ArgumentError, "sql must be a String" unless sql.is_a?(String)

      body = { "sql" => sql }
      return body if params.nil?

      require_feature(Features::SERVER_PARAMS, "SERVER_PARAMS",
                      "server-side `?` parameters; this driver never interpolates values into SQL text")
      encoded = Params.encode_all(params)
      body["params"] = encoded unless encoded.empty?
      body
    end

    def txn_control(keyword, database)
      resp = begin
        request({ "Sql" => { "Exec" => { "sql" => keyword } } }, database: database)
      rescue FeatureNotGranted
        raise
      rescue Error
        @txn_open = false unless keyword == "BEGIN"
        raise
      end
      @txn_open = keyword == "BEGIN"
      json(resp, keyword)
    end

    def cache(variant, body, database)
      request({ "Cache" => { variant => body } }, database: database)
    end

    def document(variant, body, database)
      request({ "Document" => { variant => body } }, database: database)
    end

    def vector(variant, body, database)
      request({ "Vector" => { variant => body } }, database: database)
    end

    def graph_op(variant, body, database)
      request({ "Graph" => { variant => body } }, database: database)
    end

    def nk(namespace, key)
      { "namespace" => namespace.to_s, "key" => key.to_s }
    end

    def json(resp, what)
      raise ProtocolError, "expected Json for #{what}, got #{resp.kind}" unless resp.arm?("Json")

      resp.arm("Json")
    end

    def documents(resp, what)
      raise ProtocolError, "expected Documents for #{what}, got #{resp.kind}" unless resp.arm?("Documents")

      resp.arm("Documents") || []
    end

    def cache_value(resp, what)
      raise ProtocolError, "expected CacheValue for #{what}, got #{resp.kind}" unless resp.arm?("CacheValue")

      value = resp.arm("CacheValue")
      value.nil? ? nil : value.pack("C*")
    end

    def rendered(resp)
      return resp.arm("Toon") if resp.arm?("Toon")
      return resp.arm("Json") if resp.arm?("Json")
      return resp.arm("Message") if resp.arm?("Message")

      raise ProtocolError, "expected a rendered export, got #{resp.kind}"
    end

    def bytes(value, name)
      case value
      when String then value.bytes
      when Binary then value.bytes.bytes
      when Array
        unless value.all? { |b| b.is_a?(Integer) && b.between?(0, 255) }
          raise ArgumentError, "#{name} as an Array must hold Integers 0..255"
        end

        value
      else
        raise ArgumentError, "#{name} must be a String, TriCoreDB::Binary or Array of bytes, got #{value.class}"
      end
    end

    def byte_list(values, name)
      raise ArgumentError, "#{name} must be a non-empty Array" unless values.is_a?(Array) && !values.empty?

      values.map { |v| bytes(v, "#{name} element") }
    end

    def pairs(entries, name)
      list = entries.is_a?(Hash) ? entries.to_a : entries
      raise ArgumentError, "#{name} must be a non-empty Hash or Array of pairs" unless list.is_a?(Array) && !list.empty?

      list.map do |pair|
        raise ArgumentError, "each #{name} entry must be a [field, value] pair" unless pair.is_a?(Array) && pair.size == 2

        [bytes(pair[0].is_a?(Symbol) ? pair[0].to_s : pair[0], "#{name} field"), bytes(pair[1], "#{name} value")]
      end
    end

    def binaries(values)
      (values || []).map { |v| v.pack("C*") }
    end

    def stream_entries(json)
      (json["entries"] || []).map do |e|
        StreamEntry.new(e["id"], (e["fields"] || []).map { |f, v| [f.pack("C*"), v.pack("C*")] })
      end
    end

    def numbers(values)
      list = values.to_a
      list.each do |v|
        raise ArgumentError, "vector components must be finite numbers" unless v.is_a?(Numeric) && v.to_f.finite?
      end
      list
    end

    def update_body(set, inc)
      body = {}
      body["set"] = set if set && !set.empty?
      body["inc"] = inc if inc && !inc.empty?
      body
    end

    def llm_options(max_rows, redact_sensitive, include_schema)
      { "max_rows" => max_rows, "redact_sensitive" => redact_sensitive ? true : false,
        "include_schema" => include_schema ? true : false }
    end

    def error_text(body)
      return body["message"] || body["error"] || JSON.generate(body) if body.is_a?(Hash)

      body.to_s
    end

    def error_code(body)
      body.is_a?(Hash) && body["code"].is_a?(String) && !body["code"].empty? ? body["code"] : nil
    end
  end
end
