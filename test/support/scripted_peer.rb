# frozen_string_literal: true

require "socket"
require "json"

# A peer that speaks the handshake and then plays one scripted answer.
#
# A real server cannot be asked to answer `not_leader` on demand, to hang up
# mid-frame, or to declare a payload it does not send. What is under test is this
# driver's reading of those answers, and the shape it reads is the same one a real
# cluster sends.
class ScriptedPeer
  # Run +script+ against a client built by +block+, then clean both up.
  #
  # @yieldparam peer [ScriptedPeer] the conversation, inside the script
  # @yieldparam client [TriCoreDB::Client] the connected client, inside the block
  def self.run(script, features: 7, connect: true, &block)
    peer = new(script)
    begin
      client = connect ? peer.connect : nil
      block.call(client, peer)
    ensure
      begin
        client&.close
      rescue StandardError
        nil
      end
      peer.stop
    end
  end

  # @return [Integer] the port this peer listens on
  attr_reader :port

  def initialize(script)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new do
      socket = @server.accept
      begin
        script.call(Conversation.new(socket))
      rescue StandardError, IOError
        nil
      ensure
        begin
          socket.close
        rescue StandardError
          nil
        end
      end
    end
    @thread.abort_on_exception = false
  end

  # Connect a driver to this peer.
  def connect(user: "admin", **options)
    TriCoreDB::Client.connect(host: "127.0.0.1", port: @port, user: user, secret: "pw",
                              connect_timeout: 5, **options)
  end

  def stop
    @thread&.kill
    @server.close
  rescue StandardError
    nil
  end

  # One side of the scripted conversation.
  class Conversation
    def initialize(socket)
      @socket = socket
    end

    # Read one frame the client sent.
    #
    # @return [Array(Integer, Object)] the tag and the decoded payload
    def read
      header = @socket.read(TriCoreDB::Frame::HEADER_SIZE)
      raise IOError, "client hung up" if header.nil?

      tag, length = TriCoreDB::Frame.decode_header(header)
      body = length.zero? ? "" : @socket.read(length)
      [tag, TriCoreDB::Frame.decode_body(body.to_s)]
    end

    # Send one frame, with a JSON-serialisable payload.
    def send_frame(tag, payload)
      @socket.write(TriCoreDB::Frame.encode(tag, payload))
      @socket.flush
    end

    # Send raw bytes, for the malformed cases a codec would refuse to produce.
    def send_raw(bytes)
      @socket.write(bytes)
      @socket.flush
    end

    # Answer HELLO and AUTH the way a healthy server would, granting +features+.
    def handshake(features: 7)
      read
      send_frame(TriCoreDB::Frame::HELLO_OK,
                 { "ok" => true, "server_version" => { "major" => 1, "minor" => 0 },
                   "message" => "ok", "features" => features })
      read
      send_frame(TriCoreDB::Frame::AUTH_OK, { "ok" => true, "session_id" => "s-1" })
    end

    # Answer the next request with +payload+, then wait for the client to hang up
    # so the reply is not lost to a close race.
    def answer_once(payload)
      read
      send_frame(TriCoreDB::Frame::RESPONSE, payload)
      begin
        read
      rescue StandardError, IOError
        nil
      end
    end

    # Stop reading and writing, leaving the client with a closed socket.
    def hang_up
      @socket.close
    rescue StandardError
      nil
    end
  end
end
