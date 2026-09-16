# frozen_string_literal: true

require_relative "../test_helper"

# The frame layout, and the ceilings that keep a wrong or hostile peer from making
# this driver allocate whatever length it declares.
class FrameTest < Minitest::Test
  def test_the_header_is_version_tag_and_a_big_endian_length
    bytes = TriCoreDB::Frame.encode(TriCoreDB::Frame::REQUEST, { "a" => 1 })
    assert_equal [1, 2, 0, 0, 0, 7], bytes.bytes.first(6)
    assert_equal '{"a":1}'.bytesize + 6, bytes.bytesize

    empty = TriCoreDB::Frame.encode(TriCoreDB::Frame::PING, nil)
    assert_equal [1, 4, 0, 0, 0, 0], empty.bytes
  end

  def test_a_frame_round_trips
    bytes = TriCoreDB::Frame.encode(TriCoreDB::Frame::AUTH_OK, { "ok" => false })
    tag, length = TriCoreDB::Frame.decode_header(bytes[0, 6])

    assert_equal TriCoreDB::Frame::AUTH_OK, tag
    assert_equal({ "ok" => false }, TriCoreDB::Frame.decode_body(bytes[6, length]))
  end

  def test_only_request_and_response_frames_take_the_large_ceiling
    assert_equal 16 * 1024 * 1024, TriCoreDB::Frame.max_payload_for(TriCoreDB::Frame::REQUEST)
    assert_equal 16 * 1024 * 1024, TriCoreDB::Frame.max_payload_for(TriCoreDB::Frame::RESPONSE)
    [TriCoreDB::Frame::HELLO, TriCoreDB::Frame::AUTH, TriCoreDB::Frame::PING,
     TriCoreDB::Frame::AUTH_OK, TriCoreDB::Frame::CANCEL_OK].each do |tag|
      assert_equal 64 * 1024, TriCoreDB::Frame.max_payload_for(tag)
    end
    # A tag this build cannot name is a tag whose size it cannot vouch for.
    assert_equal 64 * 1024, TriCoreDB::Frame.max_payload_for(99)
  end

  def test_an_oversized_control_frame_is_refused_on_the_way_out
    too_big = { "secret" => "x" * (TriCoreDB::Frame::MAX_CONTROL_PAYLOAD + 1) }
    error = assert_raises(TriCoreDB::ProtocolError) do
      TriCoreDB::Frame.encode(TriCoreDB::Frame::AUTH, too_big)
    end
    assert_equal "frame_too_large", error.code
    # The same payload is fine on a REQUEST, which has the larger ceiling.
    TriCoreDB::Frame.encode(TriCoreDB::Frame::REQUEST, too_big)
  end

  def test_a_declared_length_above_the_ceiling_is_refused_before_the_payload_is_read
    # Six header bytes claiming 64 KiB + 1, and not one byte of body. A driver that
    # trusted the length would allocate it and then wait for ever.
    header = [1, TriCoreDB::Frame::AUTH_OK, TriCoreDB::Frame::MAX_CONTROL_PAYLOAD + 1].pack("CCN")
    error = assert_raises(TriCoreDB::ProtocolError) { TriCoreDB::Frame.decode_header(header) }
    assert_equal "frame_too_large", error.code
  end

  def test_a_frame_version_this_driver_cannot_read_is_refused_by_name
    header = [2, TriCoreDB::Frame::RESPONSE, 0].pack("CCN")
    error = assert_raises(TriCoreDB::ProtocolError) { TriCoreDB::Frame.decode_header(header) }
    assert_equal "frame_version", error.code
  end

  def test_a_short_header_is_refused
    assert_raises(TriCoreDB::ProtocolError) { TriCoreDB::Frame.decode_header("\x01\x03") }
  end

  def test_a_payload_that_is_not_json_is_a_protocol_error
    assert_nil TriCoreDB::Frame.decode_body("")
    assert_raises(TriCoreDB::ProtocolError) { TriCoreDB::Frame.decode_body("{not json") }
  end

  def test_tags_have_readable_names
    assert_equal "HELLO_OK", TriCoreDB::Frame.name(TriCoreDB::Frame::HELLO_OK)
    assert_equal "tag 99", TriCoreDB::Frame.name(99)
  end
end
