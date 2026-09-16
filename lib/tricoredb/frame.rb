# frozen_string_literal: true

require "json"

module TriCoreDB
  # The native frame format: `version:u8 | tag:u8 | payload_len:u32be | payload`.
  module Frame
    # The frame format version this driver writes.
    VERSION = 1
    # The highest frame format version this driver can read.
    MAX_SUPPORTED_VERSION = 1
    HEADER_SIZE = 6
    # Ceiling for REQUEST and RESPONSE payloads.
    MAX_DATA_PAYLOAD = 16 * 1024 * 1024
    # Ceiling for every other frame.
    MAX_CONTROL_PAYLOAD = 64 * 1024

    HELLO = 0
    AUTH = 1
    REQUEST = 2
    RESPONSE = 3
    PING = 4
    PONG = 5
    ERROR = 6
    CLOSE = 7
    HELLO_OK = 8
    AUTH_OK = 9
    BYE = 10
    CANCEL = 11
    CANCEL_OK = 12

    NAMES = {
      HELLO => "HELLO", AUTH => "AUTH", REQUEST => "REQUEST", RESPONSE => "RESPONSE",
      PING => "PING", PONG => "PONG", ERROR => "ERROR", CLOSE => "CLOSE",
      HELLO_OK => "HELLO_OK", AUTH_OK => "AUTH_OK", BYE => "BYE",
      CANCEL => "CANCEL", CANCEL_OK => "CANCEL_OK"
    }.freeze

    module_function

    # @param tag [Integer]
    # @return [Integer] the payload ceiling for that tag; an unknown tag gets the tighter one
    def max_payload_for(tag)
      tag == REQUEST || tag == RESPONSE ? MAX_DATA_PAYLOAD : MAX_CONTROL_PAYLOAD
    end

    # @param tag [Integer]
    # @return [String]
    def name(tag)
      NAMES.fetch(tag) { "tag #{tag}" }
    end

    # Encode one frame.
    #
    # @param tag [Integer]
    # @param payload [Object, nil] JSON-serialisable; nil sends an empty payload
    # @return [String] binary frame bytes
    # @raise [ProtocolError] when the payload exceeds the ceiling for its tag
    def encode(tag, payload)
      body = payload.nil? ? "".b : JSON.generate(payload).b
      limit = max_payload_for(tag)
      if body.bytesize > limit
        raise ProtocolError.new(
          "refusing to send a #{body.bytesize}-byte #{name(tag)} payload; the protocol caps it at #{limit} bytes",
          code: "frame_too_large"
        )
      end
      [VERSION, tag, body.bytesize].pack("CCN") + body
    end

    # Decode and validate a six-byte header before any payload byte is read.
    #
    # @param header [String] exactly {HEADER_SIZE} bytes
    # @return [Array(Integer, Integer)] `[tag, payload_length]`
    # @raise [ProtocolError]
    def decode_header(header)
      raise ProtocolError, "short frame header (#{header.bytesize} bytes)" if header.bytesize != HEADER_SIZE

      version, tag, length = header.unpack("CCN")
      if version > MAX_SUPPORTED_VERSION
        raise ProtocolError.new(
          "frame header version #{version} is newer than this driver can read (max #{MAX_SUPPORTED_VERSION})",
          code: "frame_version"
        )
      end
      limit = max_payload_for(tag)
      if length > limit
        raise ProtocolError.new(
          "#{name(tag)} frame declares a #{length}-byte payload, above the #{limit}-byte limit; refusing to buffer it",
          code: "frame_too_large"
        )
      end
      [tag, length]
    end

    # @param body [String]
    # @return [Object, nil] the parsed JSON, or nil for an empty payload
    def decode_body(body)
      return nil if body.empty?

      JSON.parse(body.dup.force_encoding(Encoding::UTF_8))
    rescue JSON::ParserError => e
      raise ProtocolError, "frame payload is not valid JSON: #{e.message}"
    end
  end
end
