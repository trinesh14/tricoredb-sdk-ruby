# frozen_string_literal: true

require "test_helper"
require "socket"
require "json"

# Following the leader: what the client does with `not_leader` by default.
# Peers that accept any number of connections stand in for a follower and a
# leader; a real follower's refusal was applied nowhere, which is what makes
# sending the request again safe.
class FollowLeaderTest < Minitest::Test
  # A peer serving any number of connections; the block answers the n-th request.
  class Peer
    attr_reader :port, :users, :request_ids, :connections

    def initialize(&reply)
      @reply = reply
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @users = []
      @request_ids = []
      @connections = 0
      @lock = Mutex.new
      @thread = Thread.new do
        loop do
          socket = @server.accept
          @lock.synchronize { @connections += 1 }
          Thread.new(socket) { |s| serve(s) }
        end
      rescue IOError, SystemCallError
        nil
      end
    end

    def address
      "127.0.0.1:#{@port}"
    end

    def requests
      @lock.synchronize { @request_ids.size }
    end

    def stop
      @server.close
    rescue IOError
      nil
    end

    private

    def serve(socket)
      loop do
        header = socket.read(6)
        break if header.nil? || header.bytesize < 6

        _version, tag, length = header.unpack("CCN")
        body = length.positive? ? JSON.parse(socket.read(length)) : nil
        case tag
        when TriCoreDB::Frame::HELLO then write(socket, TriCoreDB::Frame::HELLO_OK, { "ok" => true, "features" => 7 })
        when TriCoreDB::Frame::AUTH
          @lock.synchronize { @users << body["username"] }
          write(socket, TriCoreDB::Frame::AUTH_OK, { "ok" => true, "session_id" => "s-1" })
        when TriCoreDB::Frame::CLOSE
          write(socket, TriCoreDB::Frame::BYE, {})
          break
        when TriCoreDB::Frame::REQUEST
          rid = body["request_id"]
          n = @lock.synchronize do
            @request_ids << rid
            @request_ids.size
          end
          write(socket, TriCoreDB::Frame::RESPONSE, @reply.call(rid, n))
        end
      end
    rescue IOError, SystemCallError
      nil
    ensure
      socket.close
    end

    def write(socket, tag, payload)
      json = JSON.generate(payload)
      socket.write([1, tag, json.bytesize].pack("CCN") + json)
    end
  end

  def ok(rid)
    { "request_id" => rid, "status" => "ok",
      "data" => { "Json" => { "transaction" => "began" } }, "diagnostics" => {} }
  end

  def refusal(rid, code, leader = nil)
    diagnostics = { "error_code" => code }
    diagnostics["leader_hint"] = leader if leader
    { "request_id" => rid, "status" => "error",
      "data" => { "Message" => "not the raft leader" }, "diagnostics" => diagnostics }
  end

  def connect(peer, **options)
    TriCoreDB::Client.connect(host: "127.0.0.1", port: peer.port, connect_timeout: 5,
                              leader_retry_delay: 0.001, **options)
  end

  def with_peers(*peers)
    yield(*peers)
  ensure
    peers.each(&:stop)
  end

  def test_a_refused_request_goes_to_the_leader_and_stays_there
    leader = Peer.new { |rid, _| ok(rid) }
    follower = Peer.new { |rid, _| refusal(rid, TriCoreDB::NOT_LEADER, leader.address) }
    with_peers(leader, follower) do
      db = connect(follower, user: "u", secret: "s")
      db.execute("INSERT INTO t VALUES (1)")
      assert_equal leader.address, db.address
      db.execute("INSERT INTO t VALUES (2)")
      assert_equal [1, 2, 1], [follower.requests, leader.requests, leader.connections]
      assert_equal ["u"], leader.users
      assert_equal follower.request_ids.first, leader.request_ids.first
      db.close
    end
  end

  def test_with_no_leader_named_the_client_waits_and_asks_again
    peer = Peer.new { |rid, n| n < 3 ? refusal(rid, TriCoreDB::NOT_LEADER) : ok(rid) }
    with_peers(peer) do
      db = connect(peer)
      db.execute("INSERT INTO t VALUES (1)")
      assert_equal [3, 1], [peer.requests, peer.connections]
      db.close
    end
  end

  def test_retries_are_bounded_and_reported
    peer = Peer.new { |rid, _| refusal(rid, TriCoreDB::NOT_LEADER) }
    with_peers(peer) do
      db = connect(peer, leader_retries: 2)
      error = assert_raises(TriCoreDB::ServerError) { db.execute("INSERT INTO t VALUES (1)") }
      assert error.redirect?
      assert_match(/sent it again 2 time/, error.message)
      assert_equal 3, peer.requests
      db.close
    end
  end

  def test_an_unreachable_leader_leaves_the_connection_where_it_was
    dead = TCPServer.new("127.0.0.1", 0)
    nowhere = "127.0.0.1:#{dead.addr[1]}"
    dead.close
    peer = Peer.new { |rid, n| n == 1 ? refusal(rid, TriCoreDB::NOT_LEADER, nowhere) : ok(rid) }
    with_peers(peer) do
      db = connect(peer)
      db.execute("INSERT INTO t VALUES (1)")
      assert_equal peer.address, db.address
      assert_equal 2, peer.requests
      db.close
    end
  end

  def test_nothing_is_sent_again_inside_a_session_transaction
    peer = Peer.new { |rid, n| n == 1 ? ok(rid) : refusal(rid, TriCoreDB::NOT_LEADER) }
    with_peers(peer) do
      db = connect(peer)
      db.begin_transaction
      error = assert_raises(TriCoreDB::ServerError) { db.execute("INSERT INTO t VALUES (1)") }
      assert error.redirect?
      assert_equal 2, peer.requests
      db.close
    end
  end

  def test_outcome_unknown_is_never_sent_again
    peer = Peer.new { |rid, _| refusal(rid, TriCoreDB::OUTCOME_UNKNOWN) }
    with_peers(peer) do
      db = connect(peer)
      error = assert_raises(TriCoreDB::ServerError) { db.execute("INSERT INTO t VALUES (1)") }
      assert_equal TriCoreDB::OUTCOME_UNKNOWN, error.code
      refute error.redirect?
      assert_equal 1, peer.requests
      db.close
    end
  end

  def test_pooled_connections_follow_the_leader
    leader = Peer.new { |rid, _| ok(rid) }
    follower = Peer.new { |rid, _| refusal(rid, TriCoreDB::NOT_LEADER, leader.address) }
    with_peers(leader, follower) do
      pool = TriCoreDB::Pool.new(size: 2, host: "127.0.0.1", port: follower.port, leader_retry_delay: 0.001)
      2.times { |i| pool.with { |db| db.execute("INSERT INTO t VALUES (#{i})") } }
      pool.close
      assert_equal [1, 2], [follower.requests, leader.requests]
    end
  end
end
