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
    # Following the leader: the longest pause between attempts, and the connect
    # budget for the new connection, in seconds.
    MAX_LEADER_RETRY_DELAY = 2.0
    FOLLOW_CONNECT_TIMEOUT = 3

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
    # @return [Boolean] send a `not_leader` refusal again, to the leader (see {Client.connect})
    attr_accessor :follow_leader
    # @return [Integer] how many times a refused request is sent again
    attr_accessor :leader_retries
    # @return [Numeric] the first pause, in seconds, before asking again; it doubles up to 2
    attr_accessor :leader_retry_delay
    # @return [String] the `host:port` this connection talks to; it changes when the client follows the leader
    attr_reader :address

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
    # @param follow_leader [Boolean] send a request the server refused with `not_leader` again: to the
    #   leader the refusal names, over a new connection that replaces this one (same user, secret and
    #   TLS settings, with the leader's host as the certificate name), or, while no leader is known, to
    #   the same node after a pause. Safe because a `not_leader` refusal was applied nowhere; never
    #   inside a session transaction.
    # @param leader_retries [Integer] how many times a refused request is sent again
    # @param leader_retry_delay [Numeric] the first pause, in seconds; it doubles up to 2
    # @return [Client]
    # @raise [ConnectionError, ProtocolError, AuthError]
    def self.connect(host: "127.0.0.1", port: DEFAULT_PORT, user: nil, secret: "", database: DEFAULT_DATABASE,
                     connect_timeout: 10, read_timeout: nil, request_timeout_ms: nil, tls: nil,
                     client_name: "tricoredb-ruby/#{VERSION}", features: Features::ALL,
                     follow_leader: true, leader_retries: 5, leader_retry_delay: 0.25)
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
      client.follow_leader = follow_leader
      client.leader_retries = leader_retries
      client.leader_retry_delay = leader_retry_delay
      client.send(:remember_connect_options,
                  host: host, port: Integer(port), user: user, secret: secret, database: database,
                  connect_timeout: connect_timeout, read_timeout: read_timeout,
                  request_timeout_ms: request_timeout_ms, tls: tls, client_name: client_name,
                  features: features)
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
      @follow_leader = true
      @leader_retries = 5
      @leader_retry_delay = 0.25
      @connect_options = nil
      @address = ""
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
    # @param txn [String, nil] an open document or graph transaction the request runs inside
    # @return [Response] only when its status is `ok`
    # @raise [ServerError] for any other status, or an ERROR frame
    def request(op, database: @database, correlation_id: nil, txn: nil)
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
      payload["options"] = (payload["options"] || {}).merge("txn" => txn.to_s) unless txn.nil?
      pause = @leader_retry_delay
      retried = 0
      loop do
        response = send_request(payload)
        return response if response.ok?

        # A `not_leader` refusal was applied nowhere, so sending it again cannot
        # apply it twice. A session transaction belongs to this connection.
        unless response.redirect? && @follow_leader && !@txn_open && retried < @leader_retries
          raise response.to_error(@txn_open, retried: @follow_leader ? retried : nil)
        end

        retried += 1
        hint = response.leader_hint
        next if hint && hint != @address && move_to(hint)

        sleep(pause)
        pause = (pause * 2).clamp(0.001, MAX_LEADER_RETRY_DELAY)
      end
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

    # Store a value that answers as fresh for the given time and as stale after it, until
    # its TTL (if any) ends. Returns the instant, in Unix milliseconds, it stops being
    # fresh.
    # @return [Integer]
    def cache_set_fresh(namespace, key, value, fresh_ms, ttl_ms: nil, database: @database)
      body = {
        "namespace" => namespace,
        "key" => key,
        "value" => bytes(value, "value"),
        "fresh_ms" => Integer(fresh_ms),
        "ttl_ms" => ttl_ms
      }
      json(cache("SetFresh", body, database), "setFresh")["freshUntilMs"]
    end

    # Read with stale-while-revalidate and stampede protection. The state is `fresh`,
    # `stale` (with `refresh` true for the one caller holding the refresh lease),
    # `missing` (a cached absence) or `miss` (with `lease` true for the one caller that
    # should compute the value).
    # @return [Hash] `"state"`, plus `"value"` (a binary String), `"refresh"`, `"lease"` and `"retryAfterMs"` when they apply
    def cache_get_fresh(namespace, key, owner, lease_ms, database: @database)
      body = { "namespace" => namespace, "key" => key, "owner" => owner, "lease_ms" => Integer(lease_ms) }
      fresh_read(json(cache("GetFresh", body, database), "getFresh"))
    end

    # Negative caching: remember for the given time that the source has no value for the
    # key.
    def cache_set_missing(namespace, key, ttl_ms, database: @database)
      body = { "namespace" => namespace, "key" => key, "ttl_ms" => Integer(ttl_ms) }
      cache("SetMissing", body, database)
      nil
    end

    # Cache warming: write the entries that are not already cached, leaving live values
    # alone. Answers `written` and `alreadyCached`.
    # @return [Hash]
    def cache_warm(namespace, entries, ttl_ms: nil, database: @database)
      body = { "namespace" => namespace, "entries" => cache_entries(entries), "ttl_ms" => ttl_ms }
      json(cache("Warm", body, database), "warm")
    end

    # Read many values in one request. One result per requested key, in order, with null
    # where the key is absent or expired. Not a snapshot.
    # @return [Array<String, nil>] binary Strings, nil where a key is absent
    def cache_mget(namespace, keys, database: @database)
      body = { "namespace" => namespace, "keys" => Array(keys).map(&:to_s) }
      cache_values(cache("MGet", body, database), "mget")
    end

    # Write many values as one batch, all with the same optional TTL. A repeated key is
    # refused. Returns how many were written.
    # @return [Integer]
    def cache_mset(namespace, entries, ttl_ms: nil, database: @database)
      body = { "namespace" => namespace, "entries" => cache_entries(entries), "ttl_ms" => ttl_ms }
      json(cache("MSet", body, database), "mset")["set"]
    end

    # Write a value under a condition, with explicit control over the TTL. False means the
    # condition was not met, not that anything failed.
    # @return [Boolean]
    def cache_set_if(namespace, key, value, condition: "Always", expiry: CacheExpiry.clear, database: @database)
      body = {
        "namespace" => namespace,
        "key" => key,
        "value" => bytes(value, "value"),
        "condition" => condition.to_s,
        "expiry" => expiry
      }
      json(cache("SetIf", body, database), "setIf")["set"] == true
    end

    # Add scored members to a sorted set, or re-score ones already there. Answers `added`
    # and `updated`. A NaN score is refused.
    # @return [Hash]
    def cache_zadd(namespace, key, members, database: @database)
      body = { "namespace" => namespace, "key" => key, "members" => scored_members(members) }
      json(cache("ZAdd", body, database), "zadd")
    end

    # Remove members from a sorted set, returning how many were present.
    # @return [Integer]
    def cache_zrem(namespace, key, members, database: @database)
      body = { "namespace" => namespace, "key" => key, "members" => byte_list(members, "members") }
      json(cache("ZRem", body, database), "zrem")["removed"]
    end

    # The score of one member, or null when it is not in the set.
    # @return [Float, nil]
    def cache_zscore(namespace, key, member, database: @database)
      body = { "namespace" => namespace, "key" => key, "member" => bytes(member, "member") }
      json(cache("ZScore", body, database), "zscore")["score"]
    end

    # How many members a sorted set holds.
    # @return [Integer]
    def cache_zcard(namespace, key, database: @database)
      body = { "namespace" => namespace, "key" => key }
      json(cache("ZCard", body, database), "zcard")["cardinality"]
    end

    # A member's position in the ordering, or null when it is absent. `rev` counts from
    # the high-scoring end.
    # @return [Integer, nil]
    def cache_zrank(namespace, key, member, rev: false, database: @database)
      body = {
        "namespace" => namespace,
        "key" => key,
        "member" => bytes(member, "member"),
        "rev" => rev ? true : false
      }
      json(cache("ZRank", body, database), "zrank")["rank"]
    end

    # Members by rank, `start..=stop` inclusive. Negative indices count from the end, so
    # `0, -1` is the whole set.
    # @return [Array] members as binary Strings, or `[member, score]` pairs when read with scores
    def cache_zrange(namespace, key, start, stop, rev: false, with_scores: false, database: @database)
      body = {
        "namespace" => namespace,
        "key" => key,
        "start" => Integer(start),
        "stop" => Integer(stop),
        "rev" => rev ? true : false,
        "with_scores" => with_scores ? true : false
      }
      sorted_members(json(cache("ZRange", body, database), "zrange"))
    end

    # Members by score, between two bounds. `limit` is `(offset, count)`, applied after
    # the range is selected.
    # @return [Array] members as binary Strings, or `[member, score]` pairs when read with scores
    def cache_zrangebyscore(namespace, key, min, max, rev: false, with_scores: false, limit: nil, database: @database)
      body = {
        "namespace" => namespace,
        "key" => key,
        "min" => score_bound(min),
        "max" => score_bound(max),
        "rev" => rev ? true : false,
        "with_scores" => with_scores ? true : false,
        "limit" => int_pair(limit)
      }
      sorted_members(json(cache("ZRangeByScore", body, database), "zrangebyscore"))
    end

    # Add to a member's score, creating it at that score when absent. Returns the
    # resulting score.
    # @return [Float]
    def cache_zincrby(namespace, key, member, by, database: @database)
      body = { "namespace" => namespace, "key" => key, "member" => bytes(member, "member"), "by" => by }
      json(cache("ZIncrBy", body, database), "zincrby")["score"]
    end

    # Take a lease on a lock, or refresh one already held by `owner`. Answers `acquired`,
    # `token` (a fencing token that strictly increases with every acquisition and is never
    # reused), `holder` and `expiresAtMs`.
    # @return [Hash]
    def cache_lock_acquire(namespace, key, owner, ttl_ms, database: @database)
      body = { "namespace" => namespace, "key" => key, "owner" => owner, "ttl_ms" => Integer(ttl_ms) }
      json(cache("LockAcquire", body, database), "lockAcquire")
    end

    # Extend a lease the caller still holds. Answers `renewed`, `token` and `expiresAtMs`.
    # Refused once the lease has lapsed, even if nobody else has taken the lock since.
    # @return [Hash]
    def cache_lock_renew(namespace, key, owner, ttl_ms, database: @database)
      body = { "namespace" => namespace, "key" => key, "owner" => owner, "ttl_ms" => Integer(ttl_ms) }
      json(cache("LockRenew", body, database), "lockRenew")
    end

    # Give up a lock. Only the current, live holder can release it.
    # @return [Boolean]
    def cache_lock_release(namespace, key, owner, database: @database)
      body = { "namespace" => namespace, "key" => key, "owner" => owner }
      json(cache("LockRelease", body, database), "lockRelease")["released"] == true
    end

    # Set one bit of a string value, growing it with zero bytes if needed. Returns the
    # bit's old value. Bits are numbered from the most significant bit of byte 0.
    # @return [Integer]
    def cache_setbit(namespace, key, offset, value, database: @database)
      body = { "namespace" => namespace, "key" => key, "offset" => Integer(offset), "value" => value ? true : false }
      json(cache("SetBit", body, database), "setbit")["previous"]
    end

    # Read one bit. Past the end of the value, and on a missing key, every bit is 0.
    # @return [Integer]
    def cache_getbit(namespace, key, offset, database: @database)
      body = { "namespace" => namespace, "key" => key, "offset" => Integer(offset) }
      json(cache("GetBit", body, database), "getbit")["bit"]
    end

    # Count the set bits, optionally within a byte range `(start, end)` with signed
    # indices.
    # @return [Integer]
    def cache_bitcount(namespace, key, range: nil, database: @database)
      body = { "namespace" => namespace, "key" => key, "range" => int_pair(range) }
      json(cache("BitCount", body, database), "bitcount")["count"]
    end

    # The position of the first bit equal to `bit`, optionally within a byte range, or -1
    # when there is none.
    # @return [Integer]
    def cache_bitpos(namespace, key, bit, range: nil, database: @database)
      body = { "namespace" => namespace, "key" => key, "bit" => bit ? true : false, "range" => int_pair(range) }
      json(cache("BitPos", body, database), "bitpos")["position"]
    end

    # Combine several values bitwise and store the result at `dest`. Returns the result's
    # size in bytes.
    # @return [Integer]
    def cache_bitop(namespace, op, dest, keys, database: @database)
      body = { "namespace" => namespace, "op" => op.to_s, "dest" => dest, "keys" => Array(keys).map(&:to_s) }
      json(cache("BitOp", body, database), "bitop")["length"]
    end

    # Add elements to a HyperLogLog, creating it when absent. Returns whether the estimate
    # may have moved.
    # @return [Boolean]
    def cache_pfadd(namespace, key, elements, database: @database)
      body = { "namespace" => namespace, "key" => key, "elements" => byte_list(elements, "elements") }
      json(cache("PfAdd", body, database), "pfadd")["changed"] == true
    end

    # Estimated number of distinct elements. With several keys, the estimate is of their
    # union.
    # @return [Integer]
    def cache_pfcount(namespace, keys, database: @database)
      body = { "namespace" => namespace, "keys" => Array(keys).map(&:to_s) }
      json(cache("PfCount", body, database), "pfcount")["count"]
    end

    # Merge several HyperLogLogs into `dest`, which is included as a source when it
    # already exists.
    def cache_pfmerge(namespace, dest, sources, database: @database)
      body = { "namespace" => namespace, "dest" => dest, "sources" => Array(sources).map(&:to_s) }
      cache("PfMerge", body, database)
      nil
    end

    # Atomically pop an element from one end of `source` and push it onto one end of
    # `destination`. Returns the element, or null when `source` is empty.
    # @return [String, nil]
    def cache_lmove(namespace, source, destination, from, to, database: @database)
      body = {
        "namespace" => namespace,
        "source" => source,
        "destination" => destination,
        "from" => from.to_s,
        "to" => to.to_s
      }
      cache_value(cache("LMove", body, database), "lmove")
    end

    # Set the absolute instant an existing live key dies. A deadline already passed
    # deletes the key. Answers `updated` and `deleted`.
    # @return [Hash]
    def cache_expire_at(namespace, key, at_ms, database: @database)
      body = { "namespace" => namespace, "key" => key, "at_ms" => Integer(at_ms) }
      json(cache("ExpireAt", body, database), "expireAt")
    end

    # What this node's cache is doing: lookup hits and misses, the memory budget and the
    # eviction policy. Node-wide, not per database.
    # @return [Hash]
    def cache_stats(database: @database)
      json(request({ "Cache" => "Stats" }, database: database), "stats")
    end

    # Delete every cache key in this database, across every namespace. Returns how many
    # keys were removed.
    # @return [Integer]
    def cache_flush_database(database: @database)
      json(request({ "Cache" => "FlushDatabase" }, database: database), "flushDatabase")["cleared"]
    end

    # Concatenate bytes onto what a key already holds, and return the new length. A
    # missing key is created; an existing key keeps its expiry.
    # @return [Integer]
    def cache_append(namespace, key, value, database: @database)
      body = { "namespace" => namespace, "key" => key, "value" => bytes(value, "value") }
      json(cache("Append", body, database), "append")["length"]
    end

    # Write only if the key still holds `expected` (null: the key must be absent). A null
    # `value` deletes the key. Answers `swapped`; on a mismatch, `current` holds the value
    # present when it is valid UTF-8, and `currentIsBinary` is true when it is not.
    # @return [Hash]
    def cache_compare_and_swap(namespace, key, expected, value, ttl_ms: nil, database: @database)
      body = {
        "namespace" => namespace,
        "key" => key,
        "expected" => expected.nil? ? nil : bytes(expected, "expected"),
        "value" => value.nil? ? nil : bytes(value, "value"),
        "ttl_ms" => ttl_ms
      }
      json(cache("CompareAndSwap", body, database), "compareAndSwap")
    end

    # Read a key and delete it in one atomic step. Null when the key was absent or
    # expired.
    # @return [String, nil]
    def cache_getdel(namespace, key, database: @database)
      body = { "namespace" => namespace, "key" => key }
      cache_value(cache("GetDel", body, database), "getdel")
    end

    # Write a value and return the one it replaced, atomically. Any TTL on the old value
    # is dropped.
    # @return [String, nil]
    def cache_getset(namespace, key, value, ttl_ms: nil, database: @database)
      body = { "namespace" => namespace, "key" => key, "value" => bytes(value, "value"), "ttl_ms" => ttl_ms }
      cache_value(cache("GetSet", body, database), "getset")
    end

    # Read a key and change its expiry in the same atomic step. The value itself is never
    # modified.
    # @return [String, nil]
    def cache_getex(namespace, key, expiry, database: @database)
      body = { "namespace" => namespace, "key" => key, "expiry" => expiry }
      cache_value(cache("GetEx", body, database), "getex")
    end

    # Keep only the inclusive index range of a list, dropping everything outside it.
    # Answers `length` and `removed`.
    # @return [Hash]
    def cache_ltrim(namespace, key, start, stop, database: @database)
      body = { "namespace" => namespace, "key" => key, "start" => Integer(start), "stop" => Integer(stop) }
      json(cache("LTrim", body, database), "ltrim")
    end

    # Every member of every named set, without duplicates. A missing key is the empty set.
    # @return [Array<String>]
    def cache_sunion(namespace, keys, database: @database)
      body = { "namespace" => namespace, "keys" => Array(keys).map(&:to_s) }
      binaries(json(cache("SUnion", body, database), "sunion")["members"])
    end

    # The members present in every named set.
    # @return [Array<String>]
    def cache_sinter(namespace, keys, database: @database)
      body = { "namespace" => namespace, "keys" => Array(keys).map(&:to_s) }
      binaries(json(cache("SInter", body, database), "sinter")["members"])
    end

    # The members of the first set that are in none of the rest.
    # @return [Array<String>]
    def cache_sdiff(namespace, keys, database: @database)
      body = { "namespace" => namespace, "keys" => Array(keys).map(&:to_s) }
      binaries(json(cache("SDiff", body, database), "sdiff")["members"])
    end

    # Random members of a set, without removing them. No count: at most one. A positive
    # count: up to that many distinct members. A negative count: exactly that many,
    # repeats allowed.
    # @return [Array<String>]
    def cache_srandmember(namespace, key, count: nil, database: @database)
      body = { "namespace" => namespace, "key" => key, "count" => count }
      binaries(json(cache("SRandMember", body, database), "srandmember")["members"])
    end

    # Add to one hash field, atomically, returning its new value. A missing field starts
    # at zero.
    # @return [Integer]
    def cache_hincrby(namespace, key, field, by, database: @database)
      body = { "namespace" => namespace, "key" => key, "field" => bytes(field, "field"), "by" => Integer(by) }
      json(cache("HIncrBy", body, database), "hincrby")["value"]
    end

    # Run cache operations in order in one round trip, each exactly as if it had been sent
    # alone. A failing operation does not stop the rest.
    # @return [Array<Hash>] one per operation: `{"ok" => data}` or `{"error" => message}`
    def cache_pipeline(ops, database: @database)
      body = { "ops" => ops }
      json(cache("Pipeline", body, database), "pipeline")["results"] || []
    end

    # Run cache operations in order holding the cache write lock, so no other writer
    # interleaves with them. Every operation's inputs are checked before any runs; after
    # that there is no rollback.
    # @return [Array<Hash>] one per operation: `{"ok" => data}` or `{"error" => message}`
    def cache_transaction(ops, database: @database)
      body = { "ops" => ops }
      json(cache("Transaction", body, database), "transaction")["results"] || []
    end

    # Store a script: operations run as one transaction, where any string (or value)
    # written `$1`, `$2`, ... is replaced by that argument at run time. Loading the same
    # name again replaces it.
    def cache_script_load(name, ops, database: @database)
      body = { "name" => name, "ops" => ops }
      cache("ScriptLoad", body, database)
      nil
    end

    # Run a stored script with these arguments as one transaction.
    # @return [Array<Hash>] one per operation: `{"ok" => data}` or `{"error" => message}`
    def cache_script_run(name, args: [], database: @database)
      body = { "name" => name, "args" => Array(args).map(&:to_s) }
      json(cache("ScriptRun", body, database), "scriptRun")["results"] || []
    end

    # The most frequently addressed keys on this node since it started, with estimated
    # counts. The server must be configured with `[cache] hot_keys` above zero; otherwise
    # it refuses.
    # @return [Hash]
    def cache_hot_keys(limit: nil, database: @database)
      body = { "limit" => limit }
      json(cache("HotKeys", body, database), "hotKeys")
    end

    # Delete every expired cache key in this database now, rather than leaving it to
    # compaction. Returns how many went.
    # @return [Integer]
    def cache_purge_expired(database: @database)
      json(request({ "Cache" => "PurgeExpired" }, database: database), "purgeExpired")["purged"]
    end

    # Pop the head of the first non-empty list among `keys`, waiting up to the timeout for
    # one to receive an element. Null when the wait ran out.
    # @return [Array(String, String), nil] `[key, value]`, or nil when the wait ran out
    def cache_blpop(namespace, keys, timeout_ms, database: @database)
      body = { "namespace" => namespace, "keys" => Array(keys).map(&:to_s), "timeout_ms" => Integer(timeout_ms) }
      popped(cache("BLPop", body, database), "blpop")
    end

    # Pop the tail of the first non-empty list among `keys`, waiting up to the timeout for
    # one to receive an element. Null when the wait ran out.
    # @return [Array(String, String), nil] `[key, value]`, or nil when the wait ran out
    def cache_brpop(namespace, keys, timeout_ms, database: @database)
      body = { "namespace" => namespace, "keys" => Array(keys).map(&:to_s), "timeout_ms" => Integer(timeout_ms) }
      popped(cache("BRPop", body, database), "brpop")
    end

    # Cap a namespace at `max_keys` live keys and `max_bytes` of values. A write that
    # would pass either is refused. Both absent removes the limit.
    # @return [Hash]
    def cache_set_namespace_limit(namespace, max_keys: nil, max_bytes: nil, database: @database)
      body = { "namespace" => namespace, "max_keys" => max_keys, "max_bytes" => max_bytes }
      json(cache("SetNamespaceLimit", body, database), "setNamespaceLimit")
    end

    # A namespace's limit and what it holds now: `max_keys`, `max_bytes`, `keys` and
    # `bytes`.
    # @return [Hash]
    def cache_get_namespace_limit(namespace, database: @database)
      body = { "namespace" => namespace }
      json(cache("GetNamespaceLimit", body, database), "getNamespaceLimit")
    end

    # Append a message to a channel, returning the id it was given.
    # @return [Integer]
    def cache_publish(channel, message, database: @database)
      body = { "channel" => channel, "message" => message }
      json(cache("Publish", body, database), "publish")["id"]
    end

    # The messages after id `after` on these channels (a trailing `*` is a pattern).
    # Answers `messages` and `next`, the id to pass as `after` next time.
    # @return [Hash]
    def cache_poll(channels, after: 0, limit: 100, database: @database)
      body = { "channels" => Array(channels).map(&:to_s), "after" => Integer(after), "limit" => Integer(limit) }
      json(cache("Poll", body, database), "poll")
    end

    # ---- document --------------------------------------------------------------

    def doc_create_collection(collection, database: @database)
      document("CreateCollection", { "collection" => collection }, database)
      nil
    end

    # @param id [String, nil] omitted, the server generates one
    # @return [String] the stored id
    def doc_insert(collection, doc, id: nil, txn: nil, database: @database)
      json(document("Insert", { "collection" => collection, "id" => id, "document" => doc }, database, txn), "insert")["id"]
    end

    # @return [Hash, nil]
    def doc_get(collection, id, txn: nil, database: @database)
      documents(document("Get", { "collection" => collection, "id" => id }, database, txn), "get").first
    end

    # @param filter [String, Hash] from {Filter}
    # @return [Array<Hash>]
    def doc_find(collection, filter = Filter.all, limit: nil, txn: nil, database: @database)
      documents(document("Find", { "collection" => collection, "filter" => filter, "limit" => limit }, database, txn), "find")
    end

    # Set fields on an existing document (dot paths). Not an upsert.
    def doc_update(collection, id, set, txn: nil, database: @database)
      document("Update", { "collection" => collection, "id" => id, "set" => set }, database, txn)
      nil
    end

    # @return [Hash] `"updated"`, `"inserted"`, `"id"`
    def doc_update_one(collection, id, set: nil, inc: nil, upsert: false, txn: nil, database: @database)
      body = { "collection" => collection, "id" => id, "update" => update_body(set, inc), "upsert" => upsert ? true : false }
      json(document("UpdateOne", body, database, txn), "updateOne")
    end

    # @return [Hash] `"matched"`, `"modified"`
    def doc_update_many(collection, filter, set: nil, inc: nil, txn: nil, database: @database)
      body = { "collection" => collection, "filter" => filter, "update" => update_body(set, inc) }
      json(document("UpdateMany", body, database, txn), "updateMany")
    end

    def doc_delete(collection, id, txn: nil, database: @database)
      document("Delete", { "collection" => collection, "id" => id }, database, txn)
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
    def doc_aggregate(collection, pipeline, txn: nil, database: @database)
      documents(document("Aggregate", { "collection" => collection, "pipeline" => pipeline }, database, txn), "aggregate")
    end

    # Swap a document's whole body for a new one: afterwards the stored body is exactly
    # `document`, plus `_id`. With `upsert`, a missing document is created rather than
    # refused. Answers `id`, `replaced`, `inserted` and, when asked for, `document`.
    # @return [Hash]
    def doc_replace(collection, id, document,
                    upsert: false, return_document: "None", expected_version: nil, txn: nil, database: @database)
      body = {
        "collection" => collection,
        "id" => id,
        "document" => document,
        "upsert" => upsert ? true : false,
        "return" => return_document.to_s,
        "expected_version" => expected_version
      }
      json(document("Replace", body, database, txn), "replace")
    end

    # Insert several documents as one atomic batch: either every document lands or none
    # does. Each document's id is its own `_id` when it carries one, and is generated
    # otherwise. Returns the ids, in order.
    # @return [Array<String>]
    def doc_insert_many(collection, documents, txn: nil, database: @database)
      body = { "collection" => collection, "documents" => documents }
      json(document("InsertMany", body, database, txn), "insertMany")["ids"] || []
    end

    # Delete every document a filter matches, returning how many went.
    # @return [Integer]
    def doc_delete_many(collection, filter, txn: nil, database: @database)
      body = { "collection" => collection, "filter" => filter }
      json(document("DeleteMany", body, database, txn), "deleteMany")["deleted"]
    end

    # Move a collection, with its documents and indexes, to a new name. Refused when the
    # new name already exists.
    def doc_rename_collection(collection, to, database: @database)
      body = { "collection" => collection, "to" => to }
      document("RenameCollection", body, database)
      nil
    end

    # Delete the documents a TTL index says have expired, now. Returns how many went.
    # @return [Integer]
    def doc_purge_expired(collection, database: @database)
      body = { "collection" => collection }
      json(document("PurgeExpired", body, database), "purgeExpired")["purged"]
    end

    # Run a find and describe how it ran instead of returning its documents: the plan, the
    # index, why it scanned, the estimate, records examined and returned, and the time
    # taken.
    # @return [Hash]
    def doc_explain(collection, filter: Filter.all, limit: nil, sort: [], skip: nil, database: @database)
      body = {
        "collection" => collection,
        "filter" => filter,
        "limit" => limit,
        "sort" => sort || [],
        "skip" => skip
      }
      json(document("Explain", body, database), "explain")
    end

    # Open a document transaction spanning requests, returning its id. Each later call
    # given that id as `txn` reads and writes inside it, seeing its own writes and nobody
    # else's since it began. Snapshot isolation, or serializable.
    # @return [String]
    def doc_begin_transaction(serializable: false, database: @database)
      body = { "serializable" => serializable ? true : false }
      json(document("BeginTransaction", body, database), "beginTransaction")["txn"]
    end

    # Commit a document transaction: every write lands as one atomic batch, or a conflict
    # is returned and nothing lands.
    # @return [Hash]
    def doc_commit_transaction(txn, database: @database)
      json(request({ "Document" => "CommitTransaction" }, database: database, txn: txn), "commitTransaction")
    end

    # Discard a document transaction.
    def doc_rollback_transaction(txn, database: @database)
      request({ "Document" => "RollbackTransaction" }, database: database, txn: txn)
      nil
    end

    # Rebuild one index from the stored documents. Answers `rebuilt`, `documents` and
    # `entries`.
    # @return [Hash]
    def doc_rebuild_index(collection, index_name, database: @database)
      body = { "collection" => collection, "index_name" => index_name }
      json(document("RebuildIndex", body, database), "rebuildIndex")
    end

    # Set a collection's options (`schema`, `defaults`, `versioned`), replacing any it
    # had. Refused when an existing document would break the new schema.
    # @return [Hash]
    def doc_set_collection_options(collection, options, database: @database)
      body = { "collection" => collection, "options" => options }
      json(document("SetCollectionOptions", body, database), "setCollectionOptions")
    end

    # A collection's options.
    # @return [Hash]
    def doc_get_collection_options(collection, database: @database)
      body = { "collection" => collection }
      json(document("GetCollectionOptions", body, database), "getCollectionOptions")["options"] || {}
    end

    # Many inserts, updates, replaces and deletes on one collection, applied in order as
    # one atomic batch: every operation lands or none does. Answers `inserted`,
    # `inserted_ids`, `updated`, `upserted`, `replaced` and `deleted`.
    # @return [Hash]
    def doc_bulk_write(collection, ops, txn: nil, database: @database)
      body = { "collection" => collection, "ops" => ops }
      json(document("BulkWrite", body, database, txn), "bulkWrite")
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

    # Embed texts with the server's built-in embedder (deterministic feature hashing:
    # lexical, no model). Nothing is stored. Answers `vectors`, `sparse`, `embedder` and
    # `dimension`.
    # @return [Hash]
    def vector_embed(texts, dimension, database: @database)
      body = { "texts" => Array(texts).map(&:to_s), "dimension" => Integer(dimension) }
      json(vector("Embed", body, database), "embed")
    end

    # Embed each text at the collection's dimension and upsert the vectors as one atomic
    # batch. Items are `{id, text, metadata}`; the text is kept in the metadata under
    # `text`. Returns how many were written.
    # @return [Integer]
    def vector_upsert_text(collection, items, database: @database)
      body = { "collection" => collection, "items" => items }
      json(vector("UpsertText", body, database), "upsertText")["upserted"]
    end

    # Point an alias at a collection; a null collection removes it. Every operation naming
    # the alias acts on the collection.
    def vector_set_alias(alias_name, collection: nil, database: @database)
      body = { "alias" => alias_name, "collection" => collection }
      vector("SetAlias", body, database)
      nil
    end

    # Every alias and the collection it names, as `{alias, collection}`.
    # @return [Array<Hash>]
    def vector_list_aliases(database: @database)
      json(request({ "Vector" => "ListAliases" }, database: database), "listAliases")["aliases"] || []
    end

    # Declare a named vector on a collection: a second vector per item, with its own
    # dimension and metric.
    def vector_add_named_vector(collection, name, dimension, metric: "cosine", database: @database)
      body = {
        "collection" => collection,
        "name" => name,
        "dimension" => Integer(dimension),
        "metric" => metric.to_s
      }
      vector("AddNamedVector", body, database)
      nil
    end

    # Write an item's vectors by name (`default` is the collection's own), each with the
    # same metadata.
    def vector_upsert_named(collection, id, vectors, metadata: nil, database: @database)
      body = { "collection" => collection, "id" => id, "vectors" => vectors, "metadata" => metadata }
      vector("UpsertNamed", body, database)
      nil
    end

    # Write many vectors as one atomic batch. Items are `{id, vector, metadata}`. Every
    # item is validated before any is written, and a repeated id is refused. Returns how
    # many were written.
    # @return [Integer]
    def vector_upsert_many(collection, items, database: @database)
      body = { "collection" => collection, "items" => items }
      json(vector("UpsertMany", body, database), "upsertMany")["upserted"]
    end

    # Delete many vectors by id as one atomic batch, returning how many of the ids were
    # present.
    # @return [Integer]
    def vector_delete_many(collection, ids, database: @database)
      body = { "collection" => collection, "ids" => Array(ids).map(&:to_s) }
      json(vector("DeleteMany", body, database), "deleteMany")["deleted"]
    end

    # Run several query vectors against one collection in one request. One result list per
    # query, in the order asked, each what a single search with the same arguments
    # returns.
    # @return [Array<Array<Hash>>] one list of hits per query
    def vector_search_batch(collection, vectors, top_k,
                            filter: nil, min_score: nil, include_vectors: false, options: nil, database: @database)
      body = {
        "collection" => collection,
        "vectors" => vectors.map { |v| numbers(v) },
        "top_k" => Integer(top_k),
        "filter" => filter,
        "min_score" => min_score,
        "include_vectors" => include_vectors ? true : false
      }.merge(search_options(options))
      json(vector("SearchBatch", body, database), "searchBatch")["results"] || []
    end

    # Delete every vector whose metadata matches a filter, as one atomic batch. An empty
    # filter is refused.
    # @return [Integer]
    def vector_delete_by_filter(collection, filter, database: @database)
      body = { "collection" => collection, "filter" => filter }
      json(vector("DeleteByFilter", body, database), "deleteByFilter")["deleted"]
    end

    # Merge `set` into the metadata of every vector matching a filter, as one atomic
    # batch. Vectors are never touched.
    # @return [Integer]
    def vector_update_by_filter(collection, filter, set, database: @database)
      body = { "collection" => collection, "filter" => filter, "set" => set }
      json(vector("UpdateByFilter", body, database), "updateByFilter")["updated"]
    end

    # How many vectors a collection holds, or, with a filter, how many match it. An exact
    # count.
    # @return [Integer]
    def vector_count(collection, filter: nil, database: @database)
      body = { "collection" => collection, "filter" => filter }
      json(vector("Count", body, database), "count")["count"]
    end

    # The partitions of a collection: each distinct value of `field` (`_namespace` or
    # `_tenant`) with its vector count, under `partitions`, plus `unpartitioned`.
    # @return [Hash]
    def vector_list_partitions(collection, field: "_namespace", database: @database)
      body = { "collection" => collection, "field" => field }
      json(vector("ListPartitions", body, database), "listPartitions")
    end

    # Rename a collection, moving its catalog record and every vector with it. Refused
    # when the new name already exists.
    def vector_rename_collection(collection, to, database: @database)
      body = { "collection" => collection, "to" => to }
      vector("RenameCollection", body, database)
      nil
    end

    # Rebuild the collection's ANN index from its stored vectors and persist it, clearing
    # every tombstone.
    # @return [Hash]
    def vector_rebuild_index(collection, database: @database)
      body = { "collection" => collection }
      json(vector("RebuildIndex", body, database), "rebuildIndex")
    end

    # The shape of the collection's ANN index: layers, degrees, tombstones, reachability
    # and memory.
    # @return [Hash]
    def vector_index_stats(collection, database: @database)
      body = { "collection" => collection }
      json(vector("IndexStats", body, database), "indexStats")
    end

    # Measure the ANN index's recall: sampled stored vectors are each searched through the
    # index and by an exact scan, and the overlap is reported under `recall`.
    # @return [Hash]
    def vector_measure_recall(collection, sample: nil, top_k: nil, ef_search: nil, database: @database)
      body = { "collection" => collection, "sample" => sample, "top_k" => top_k, "ef_search" => ef_search }
      json(vector("MeasureRecall", body, database), "measureRecall")
    end

    # Search with several query vectors and return one fused ranking.
    # @return [Array<Hash>] `"id"`, `"score"`, `"metadata"`, best first
    def vector_search_multi(collection, vectors, top_k, fusion: "rrf", filter: nil, database: @database)
      body = {
        "collection" => collection,
        "vectors" => vectors.map { |v| numbers(v) },
        "top_k" => Integer(top_k),
        "fusion" => fusion.to_s,
        "filter" => filter
      }
      json(vector("SearchMulti", body, database), "searchMulti")["results"] || []
    end

    # Change a collection's configuration, returning it. `normalize` can only change on an
    # empty collection; `m` and `ef_construction` shape the HNSW graph; `multi_tenant`
    # requires every vector to carry a `_tenant`.
    # @return [Hash]
    def vector_set_collection_config(collection,
                                     normalize: nil, m: nil, ef_construction: nil, multi_tenant: nil, database: @database)
      body = {
        "collection" => collection,
        "normalize" => normalize,
        "m" => m,
        "ef_construction" => ef_construction,
        "multi_tenant" => multi_tenant
      }
      json(vector("SetCollectionConfig", body, database), "setCollectionConfig")
    end

    # Copy a collection (configuration and every vector) to a new name. Refused when the
    # new name exists.
    def vector_copy_collection(collection, to, database: @database)
      body = { "collection" => collection, "to" => to }
      vector("CopyCollection", body, database)
      nil
    end

    # Search with a query built from examples: the sum of the positive examples minus the
    # sum of the negative ones. An example is a stored vector's id or a vector given
    # inline. Examples named by id are left out of the results unless `exclude_examples`
    # is false.
    # @return [Array<Hash>] `"id"`, `"score"`, `"metadata"`, best first
    def vector_search_by_examples(collection, top_k,
                                  positive: [], negative: [], filter: nil, min_score: nil, include_vectors: false, exclude_examples: true, options: nil, database: @database)
      body = {
        "collection" => collection,
        "top_k" => Integer(top_k),
        "positive" => positive,
        "negative" => negative,
        "filter" => filter,
        "min_score" => min_score,
        "include_vectors" => include_vectors ? true : false,
        "exclude_examples" => exclude_examples ? true : false
      }.merge(search_options(options))
      json(vector("SearchByExamples", body, database), "searchByExamples")["results"] || []
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

    # Write many nodes and edges as one unit: every record lands or none does. Nodes are
    # `{id, labels, properties}` and edges `{id, from, to, label, properties}`; an edge
    # may join nodes created in the same batch. Answers `nodes` and `edges`.
    # @return [Hash]
    def graph_add_many(graph, nodes: [], edges: [], database: @database)
      body = { "graph" => graph, "nodes" => nodes || [], "edges" => edges || [] }
      json(graph_op("AddMany", body, database), "addMany")
    end

    # Delete many nodes and edges as one unit. An id that is not there is skipped. With
    # `detach`, every edge touching a removed node goes too. Answers `nodes_removed` and
    # `edges_removed`.
    # @return [Hash]
    def graph_remove_many(graph, nodes: [], edges: [], detach: false, database: @database)
      body = {
        "graph" => graph,
        "nodes" => Array(nodes).map(&:to_s),
        "edges" => Array(edges).map(&:to_s),
        "detach" => detach ? true : false
      }
      json(graph_op("RemoveMany", body, database), "removeMany")
    end

    # Change an existing node in place, returning it. `properties` is a JSON merge patch:
    # a key set to a value is set, a key set to null is removed. `remove_labels` applies
    # before `add_labels`.
    # @return [Hash]
    def graph_update_node(graph, id, properties: {}, add_labels: [], remove_labels: [], database: @database)
      body = {
        "graph" => graph,
        "id" => id,
        "properties" => properties || {},
        "add_labels" => Array(add_labels).map(&:to_s),
        "remove_labels" => Array(remove_labels).map(&:to_s)
      }
      json(graph_op("UpdateNode", body, database), "updateNode")
    end

    # Change an existing edge in place, returning it. `properties` merges as for a node,
    # and `label`, when given, changes the edge's type. The endpoints cannot change.
    # @return [Hash]
    def graph_update_edge(graph, id, properties: {}, label: nil, database: @database)
      body = { "graph" => graph, "id" => id, "properties" => properties || {}, "label" => label }
      json(graph_op("UpdateEdge", body, database), "updateEdge")
    end

    # Copy a graph (nodes, edges and schema) to a new name. Refused when the new name
    # exists. Answers `nodes` and `edges`.
    # @return [Hash]
    def graph_copy(graph, to, database: @database)
      body = { "graph" => graph, "to" => to }
      json(graph_op("CopyGraph", body, database), "copy")
    end

    # A bounded depth-first walk from a node: the nodes within `max_depth` hops (default
    # 3, at most 10), in DFS preorder, each with the shortest `depth` found.
    # @return [Hash]
    def graph_dfs(graph, start, direction: "outgoing", label: nil, max_depth: nil, limit: nil, database: @database)
      body = {
        "graph" => graph,
        "start" => start,
        "direction" => direction.to_s,
        "label" => label,
        "max_depth" => max_depth,
        "limit" => limit
      }
      json(graph_op("Dfs", body, database), "dfs")
    end

    # Partition the graph's nodes into connected components, largest first. `weak` ignores
    # edge direction; `strong` groups nodes that can each reach the other.
    # @return [Hash]
    def graph_connected_components(graph, kind: "weak", label: nil, limit: nil, database: @database)
      body = { "graph" => graph, "kind" => kind.to_s, "label" => label, "limit" => limit }
      json(graph_op("ConnectedComponents", body, database), "connectedComponents")
    end

    # Whether the graph contains a cycle (`hasCycle`), and one `cycle` as evidence.
    # @return [Hash]
    def graph_detect_cycle(graph, directed: true, label: nil, database: @database)
      body = { "graph" => graph, "directed" => directed ? true : false, "label" => label }
      json(graph_op("DetectCycle", body, database), "detectCycle")
    end

    # Counts describing a graph: nodes and edges, per node label and per edge type,
    # self-loops, isolated nodes, degree extremes, and edges whose endpoint no longer
    # exists.
    # @return [Hash]
    def graph_stats(graph, database: @database)
      body = { "graph" => graph }
      json(graph_op("GraphStats", body, database), "stats")
    end

    # The part of the graph within `max_depth` hops of the seeds: the nodes reached and
    # every edge joining two of them.
    # @return [Hash]
    def graph_subgraph(graph, seeds, direction: "both", label: nil, max_depth: nil, limit: nil, database: @database)
      body = {
        "graph" => graph,
        "seeds" => Array(seeds).map(&:to_s),
        "direction" => direction.to_s,
        "label" => label,
        "max_depth" => max_depth,
        "limit" => limit
      }
      json(graph_op("Subgraph", body, database), "subgraph")
    end

    # What the graph's data looks like: its node labels and edge types, each with a count
    # and the property keys seen on it.
    # @return [Hash]
    def graph_schema(graph, database: @database)
      body = { "graph" => graph }
      json(graph_op("GraphSchema", body, database), "schema")
    end

    # The `k` cheapest loopless paths between two nodes, cheapest first (default 3, at
    # most 20). Without `weight_property` every edge costs 1.
    # @return [Hash]
    def graph_k_shortest_paths(graph, from, to,
                               k: nil, direction: "outgoing", label: nil, weight_property: nil, database: @database)
      body = {
        "graph" => graph,
        "from" => from,
        "to" => to,
        "k" => k,
        "direction" => direction.to_s,
        "label" => label,
        "weight_property" => weight_property
      }
      json(graph_op("KShortestPaths", body, database), "kShortestPaths")
    end

    # Every simple path between two nodes of at most `max_depth` edges (default 5, at most
    # 10). `complete` says whether the enumeration finished.
    # @return [Hash]
    def graph_all_paths(graph, from, to,
                        direction: "outgoing", label: nil, max_depth: nil, limit: nil, database: @database)
      body = {
        "graph" => graph,
        "from" => from,
        "to" => to,
        "direction" => direction.to_s,
        "label" => label,
        "max_depth" => max_depth,
        "limit" => limit
      }
      json(graph_op("AllPaths", body, database), "allPaths")
    end

    # Betweenness, closeness or eigenvector centrality: the top `limit` nodes (default 20)
    # under `results`. `iterations` and `tolerance` tune eigenvector only.
    # @return [Hash]
    def graph_centrality(graph, measure,
                         directed: true, label: nil, limit: nil, iterations: nil, tolerance: nil, database: @database)
      body = {
        "graph" => graph,
        "measure" => measure.to_s,
        "directed" => directed ? true : false,
        "label" => label,
        "limit" => limit,
        "iterations" => iterations,
        "tolerance" => tolerance
      }
      json(graph_op("Centrality", body, database), "centrality")
    end

    # Communities by Louvain modularity optimisation, direction ignored, largest first,
    # with the partition's `modularity`.
    # @return [Hash]
    def graph_communities(graph, label: nil, iterations: nil, limit: nil, database: @database)
      body = { "graph" => graph, "label" => label, "iterations" => iterations, "limit" => limit }
      json(graph_op("Communities", body, database), "communities")
    end

    # Triangles and clustering coefficients, direction ignored.
    # @return [Hash]
    def graph_triangle_count(graph, label: nil, limit: nil, database: @database)
      body = { "graph" => graph, "label" => label, "limit" => limit }
      json(graph_op("TriangleCount", body, database), "triangleCount")
    end

    # The nodes whose neighbour sets most resemble a node's, under `results`.
    # @return [Hash]
    def graph_node_similarity(graph, node,
                              direction: "both", label: nil, metric: "jaccard", limit: nil, database: @database)
      body = {
        "graph" => graph,
        "node" => node,
        "direction" => direction.to_s,
        "label" => label,
        "metric" => metric.to_s,
        "limit" => limit
      }
      json(graph_op("NodeSimilarity", body, database), "nodeSimilarity")
    end

    # Check a graph's stored records against each other and against the resident mirror:
    # dangling edges, undecodable records, misfiled records and any disagreement between
    # mirror and storage.
    # @return [Hash]
    def graph_check_consistency(graph, database: @database)
      body = { "graph" => graph }
      json(graph_op("CheckConsistency", body, database), "checkConsistency")
    end

    # Index node properties for finding nodes. With one property it is a property index,
    # with several a composite one; `label` limits it to nodes carrying that label.
    def graph_create_node_index(graph, name, properties, label: nil, database: @database)
      body = { "graph" => graph, "name" => name, "properties" => Array(properties).map(&:to_s), "label" => label }
      graph_op("CreateNodeIndex", body, database)
      nil
    end

    # Enforce a rule on a property of every node (or, with target `edge`, every
    # relationship) carrying a label. Refused when a stored record already breaks it;
    # afterwards every write that would break it is refused.
    def graph_create_constraint(graph, name, label, property, kind, target: "node", database: @database)
      body = {
        "graph" => graph,
        "name" => name,
        "label" => label,
        "property" => property,
        "kind" => kind.to_s,
        "target" => target.to_s
      }
      graph_op("CreateConstraint", body, database)
      nil
    end

    # Drop an index or a constraint by name.
    def graph_drop_schema_object(graph, name, database: @database)
      body = { "graph" => graph, "name" => name }
      graph_op("DropSchemaObject", body, database)
      nil
    end

    # A graph's `indexes` and `constraints`.
    # @return [Hash]
    def graph_list_schema_objects(graph, database: @database)
      body = { "graph" => graph }
      json(graph_op("ListSchemaObjects", body, database), "listSchemaObjects")
    end

    # Nodes with a label (when given) whose properties equal the given values, in id
    # order. `plan` says whether an index, the label index or a scan answered.
    # @return [Hash]
    def graph_find_nodes(graph, label: nil, properties: {}, limit: nil, database: @database)
      body = { "graph" => graph, "label" => label, "properties" => properties || {}, "limit" => limit }
      json(graph_op("FindNodes", body, database), "findNodes")
    end

    # Import nodes and edges from CSV text as one atomic batch, so constraints apply.
    # Answers `nodes` and `edges`.
    # @return [Hash]
    def graph_import_csv(graph, nodes: nil, edges: nil, database: @database)
      body = { "graph" => graph, "nodes" => nodes, "edges" => edges }
      json(graph_op("ImportCsv", body, database), "importCsv")
    end

    # PageRank over edge direction: the top `limit` nodes (default 20) under `ranks`.
    # `damping` defaults to 0.85.
    # @return [Hash]
    def graph_page_rank(graph,
                        damping: nil, iterations: nil, tolerance: nil, label: nil, limit: nil, database: @database)
      body = {
        "graph" => graph,
        "damping" => damping,
        "iterations" => iterations,
        "tolerance" => tolerance,
        "label" => label,
        "limit" => limit
      }
      json(graph_op("PageRank", body, database), "pageRank")
    end

    # Run a Cypher write: `CREATE`, `MERGE`, `SET`, `REMOVE` or `[DETACH] DELETE`,
    # optionally after `MATCH ... [WHERE ...]`. Given a transaction id as `txn`, the
    # statement is queued rather than applied.
    # @return [Hash]
    def graph_execute(graph, cypher, txn: nil, database: @database)
      body = { "graph" => graph, "cypher" => cypher }
      json(graph_op("Execute", body, database, txn), "execute")
    end

    # Open a transaction on a graph, returning its id. An execute given that id as `txn`
    # is queued until the transaction commits.
    # @return [String]
    def graph_begin_transaction(graph, database: @database)
      body = { "graph" => graph }
      json(graph_op("BeginTransaction", body, database), "beginTransaction")["transaction"]
    end

    # Apply every statement queued in a graph transaction as one: all of them or none.
    # @return [Hash]
    def graph_commit_transaction(graph, txn, database: @database)
      body = { "graph" => graph }
      json(graph_op("CommitTransaction", body, database, txn), "commitTransaction")
    end

    # Discard a graph transaction and its queued statements.
    def graph_rollback_transaction(graph, txn, database: @database)
      body = { "graph" => graph }
      graph_op("RollbackTransaction", body, database, txn)
      nil
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

    def remember_connect_options(**options)
      @connect_options = options
      @address = join_address(options[:host], options[:port])
    end

    def send_request(payload)
      tag, body = exchange(Frame::REQUEST, payload)
      raise ServerError.new(error_text(body), code: error_code(body), frame: true) if tag == Frame::ERROR
      fail_stream(ProtocolError.new("expected RESPONSE, got #{Frame.name(tag)}")) unless tag == Frame::RESPONSE

      Response.new(body)
    end

    # Replace this connection with one to `target`, opened the way this one was.
    # @return [Boolean] false, leaving this connection untouched, when that fails
    def move_to(target)
      return false if @connect_options.nil?

      host, port = split_address(target)
      return false if host.nil?

      options = @connect_options.merge(
        host: host, port: port,
        connect_timeout: [@connect_options[:connect_timeout] || FOLLOW_CONNECT_TIMEOUT, FOLLOW_CONNECT_TIMEOUT].min,
        tls: leader_tls(@connect_options[:tls], host),
        follow_leader: false
      )
      fresh = begin
        Client.connect(**options)
      rescue Error, SystemCallError, IOError
        return false
      end
      old = @transport
      @transport = fresh.send(:detach_transport)
      @session_id = fresh.session_id
      @granted_features = fresh.granted_features
      @address = target
      old.close
      true
    end

    # The leader's certificate is checked against the name the hint gives.
    def leader_tls(tls, host)
      return tls if tls.nil? || tls == false

      (tls == true ? {} : tls.transform_keys(&:to_sym)).merge(server_name: host)
    end

    def detach_transport
      transport = @transport
      @transport = Transport.new(nil)
      transport
    end

    def split_address(address)
      match = /\A\[(?<host>[^\]]+)\]:(?<port>\d+)\z/.match(address) || /\A(?<host>[^:]+):(?<port>\d+)\z/.match(address)
      return nil if match.nil?

      port = Integer(match[:port], 10)
      port.between?(1, 65_535) ? [match[:host], port] : nil
    end

    def join_address(host, port)
      host.to_s.include?(":") ? "[#{host}]:#{port}" : "#{host}:#{port}"
    end

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
      outcome = json(resp, keyword)
      # A BEGIN inside an open transaction opens a nested block, and the COMMIT or
      # ROLLBACK that ends it answers with `nested_depth`: the outer one is still open.
      @txn_open = keyword == "BEGIN" || (outcome.is_a?(Hash) && outcome.key?("nested_depth"))
      outcome
    end

    def cache(variant, body, database)
      request({ "Cache" => { variant => body } }, database: database)
    end

    def document(variant, body, database, txn = nil)
      request({ "Document" => { variant => body } }, database: database, txn: txn)
    end

    def vector(variant, body, database)
      request({ "Vector" => { variant => body } }, database: database)
    end

    def graph_op(variant, body, database, txn = nil)
      request({ "Graph" => { variant => body } }, database: database, txn: txn)
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

    def cache_values(resp, what)
      raise ProtocolError, "expected CacheValues for #{what}, got #{resp.kind}" unless resp.arm?("CacheValues")

      (resp.arm("CacheValues") || []).map { |v| v.nil? ? nil : v.pack("C*") }
    end

    # A blocking pop answers `[key, value]`, or `[nil, nil]` when the wait ran out.
    def popped(resp, what)
      key, value = cache_values(resp, what)
      key.nil? || value.nil? ? nil : [key.force_encoding(Encoding::UTF_8), value]
    end

    # A value that is valid UTF-8 arrives as text under `value`; any other arrives
    # as hex under `valueHex`. Either way the caller gets the bytes under `value`.
    def fresh_read(json)
      out = json.dup
      hex = out.delete("valueHex")
      out["value"] = out["value"].b if out["value"].is_a?(String)
      out["value"] = [hex].pack("H*") if hex.is_a?(String)
      out
    end

    # A range read with scores answers `{member, score}` objects; without, the members alone.
    def sorted_members(json)
      (json["members"] || []).map do |m|
        m.is_a?(Hash) ? [m["member"].pack("C*"), m["score"]] : m.pack("C*")
      end
    end

    def cache_entries(entries)
      list = entries.is_a?(Hash) ? entries.to_a : entries
      raise ArgumentError, "entries must be a non-empty Hash or Array of pairs" unless list.is_a?(Array) && !list.empty?

      list.map { |key, value| { "key" => key.to_s, "value" => bytes(value, "entries value") } }
    end

    def scored_members(members)
      list = members.is_a?(Hash) ? members.to_a : members
      raise ArgumentError, "members must be a non-empty Hash or Array of pairs" unless list.is_a?(Array) && !list.empty?

      list.map do |member, score|
        raise ArgumentError, "a score must be a finite number" unless score.is_a?(Numeric) && score.to_f.finite?

        { "score" => score.to_f, "member" => bytes(member.is_a?(Symbol) ? member.to_s : member, "member") }
      end
    end

    def score_bound(bound)
      return ScoreBound.inclusive(bound) if bound.is_a?(Numeric)
      return bound if bound.is_a?(Hash)

      raise ArgumentError, "a score bound must be a number or come from TriCoreDB::ScoreBound, got #{bound.class}"
    end

    def int_pair(pair)
      return nil if pair.nil?
      raise ArgumentError, "expected a pair of Integers" unless pair.is_a?(Array) && pair.size == 2

      [Integer(pair[0]), Integer(pair[1])]
    end

    # Only the options given are sent; the server's defaults apply to the rest.
    def search_options(options)
      (options || {}).to_h { |k, v| [k.to_s, v] }
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
