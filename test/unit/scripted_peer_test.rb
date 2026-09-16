# frozen_string_literal: true

require_relative "../test_helper"

# How this driver reads the protocol, proved against scripted peers rather than a
# server. These need no binary and always run.
class ScriptedPeerTest < Minitest::Test
  def test_a_not_leader_refusal_is_typed_and_carries_the_leader_address
    script = lambda do |peer|
      peer.handshake
      peer.answer_once(
        "request_id" => "r1", "status" => "error",
        "data" => { "Message" => "not the raft leader" },
        "diagnostics" => { "error_code" => "not_leader", "leader_hint" => "10.9.9.7:8427" }
      )
    end

    ScriptedPeer.run(script) do |db|
      error = assert_raises(TriCoreDB::ServerError) { db.execute("INSERT INTO t VALUES (1)") }
      assert_equal TriCoreDB::NOT_LEADER, error.code
      assert_equal "10.9.9.7:8427", error.leader_hint
      assert_match(/does not follow the hint/, error.message)
      refute db.closed?, "a refusal leaves the connection usable"
    end
  end

  def test_an_ordinary_failure_is_not_read_as_a_redirect
    script = lambda do |peer|
      peer.handshake
      peer.answer_once(
        "request_id" => "r1", "status" => "error",
        "data" => { "Message" => "syntax error" },
        "diagnostics" => { "error_code" => "request.invalid" }
      )
    end

    ScriptedPeer.run(script) do |db|
      error = assert_raises(TriCoreDB::ServerError) { db.execute("NOT SQL") }
      assert_equal "request.invalid", error.code
      assert_nil error.leader_hint
      assert_match(/syntax error/, error.message)
    end
  end

  def test_an_auth_ok_frame_carrying_ok_false_is_still_a_refusal
    script = lambda do |peer|
      peer.read
      peer.send_frame(TriCoreDB::Frame::HELLO_OK, { "ok" => true, "message" => "ok", "features" => 7 })
      peer.read
      # The tag names the answer's shape; the body is the verdict.
      peer.send_frame(TriCoreDB::Frame::AUTH_OK, { "ok" => false, "message" => "bad password" })
    end

    ScriptedPeer.run(script, connect: false) do |_, peer|
      error = assert_raises(TriCoreDB::AuthError) { peer.connect }
      assert_match(/bad password/, error.message)
    end
  end

  def test_a_handshake_refusal_is_reported_as_one
    script = lambda do |peer|
      peer.read
      peer.send_frame(TriCoreDB::Frame::HELLO_OK,
                      { "ok" => false, "message" => "unsupported protocol version", "code" => "protocol_version" })
    end

    ScriptedPeer.run(script, connect: false) do |_, peer|
      error = assert_raises(TriCoreDB::Error) { peer.connect }
      assert_match(/unsupported protocol/, error.message)
    end
  end

  def test_a_declared_payload_above_the_ceiling_is_refused_before_it_is_read
    script = lambda do |peer|
      peer.handshake
      peer.read
      # A control frame claiming 64 KiB + 1 bytes, with none of them sent.
      peer.send_raw([1, TriCoreDB::Frame::AUTH_OK, TriCoreDB::Frame::MAX_CONTROL_PAYLOAD + 1].pack("CCN"))
    end

    ScriptedPeer.run(script) do |db|
      error = assert_raises(TriCoreDB::ProtocolError) { db.ping }
      assert_equal "frame_too_large", error.code
      assert db.closed?, "a stream that cannot be resynchronised is dropped, not reused"
    end
  end

  def test_a_peer_that_hangs_up_mid_frame_does_not_leave_the_driver_waiting
    script = lambda do |peer|
      peer.handshake
      peer.read
      peer.send_raw([1, TriCoreDB::Frame::RESPONSE, 10].pack("CCN") + "{")
      peer.hang_up
    end

    ScriptedPeer.run(script) do |db|
      assert_raises(TriCoreDB::Error) { db.execute("SELECT 1") }
      assert db.closed?
    end
  end

  def test_a_status_this_driver_does_not_know_is_treated_as_a_failure
    script = lambda do |peer|
      peer.handshake
      peer.answer_once(
        "request_id" => "r1", "status" => "not_implemented",
        "data" => { "Message" => "Cache::XGroup is refused in V1" }
      )
    end

    ScriptedPeer.run(script) do |db|
      error = assert_raises(TriCoreDB::ServerError) { db.request({ "Cache" => { "XGroup" => {} } }) }
      assert_match(/XGroup/, error.message)
      assert_match(/not_implemented/, error.message)
    end
  end

  def test_a_server_that_granted_nothing_makes_the_driver_refuse_before_sending
    script = lambda do |peer|
      # An older server omits the feature field entirely.
      peer.read
      peer.send_frame(TriCoreDB::Frame::HELLO_OK, { "ok" => true, "message" => "ok" })
      peer.read
      peer.send_frame(TriCoreDB::Frame::AUTH_OK, { "ok" => true, "session_id" => "s-1" })
      sleep 5
    end

    ScriptedPeer.run(script) do |db|
      error = assert_raises(TriCoreDB::FeatureNotGranted) { db.query("SELECT * FROM t WHERE id = ?", [1]) }
      assert_match(/SERVER_PARAMS/, error.message)
      refute db.closed?, "nothing was sent, so the connection is untouched"

      begin_error = assert_raises(TriCoreDB::FeatureNotGranted) { db.begin }
      assert_match(/SESSION_TXN/, begin_error.message)
    end
  end

  def test_warnings_and_diagnostics_reach_the_caller_on_a_successful_response
    script = lambda do |peer|
      peer.handshake
      peer.answer_once(
        "request_id" => "r1", "status" => "ok", "data" => { "Message" => "done" },
        "diagnostics" => { "route" => "local", "elapsed_ms" => 4, "warnings" => ["shard 2 was unreachable"] }
      )
    end

    ScriptedPeer.run(script) do |db|
      response = db.request({ "Admin" => "Ping" })
      assert response.ok?
      assert_equal ["shard 2 was unreachable"], response.warnings
      assert_equal "local", response.diagnostics["route"]
    end
  end
end
