# frozen_string_literal: true

require "time"

begin
  require "bigdecimal"
rescue LoadError
  # bigdecimal is a bundled gem from Ruby 3.4; without it, BigDecimal values simply cannot occur.
end

module TriCoreDB
  # Explicit marker for bytes bound to a BLOB column, whatever the String's encoding.
  #
  # @example
  #   db.execute("INSERT INTO files VALUES (?, ?)", [1, TriCoreDB::Binary.new(File.binread("a.png"))])
  class Binary
    # @return [String] the bytes, as a binary (ASCII-8BIT) String
    attr_reader :bytes

    # @param bytes [String, Array<Integer>]
    def initialize(bytes)
      @bytes = bytes.is_a?(Array) ? bytes.pack("C*") : String(bytes).b
      @bytes.freeze
    end

    # @return [String] the `0x…` hex text a BLOB column parses
    def to_param
      "0x#{@bytes.unpack1('H*')}"
    end

    def ==(other)
      other.is_a?(Binary) && other.bytes == bytes
    end
    alias eql? ==

    def hash
      bytes.hash
    end
  end

  # @param bytes [String, Array<Integer>]
  # @return [Binary]
  def self.binary(bytes)
    Binary.new(bytes)
  end

  # Conversion of Ruby values to server-side SQL parameters.
  #
  # The wire carries JSON scalars only. The mapping:
  #
  # - `nil`, `true`, `false` as themselves
  # - `Integer` as an exact JSON number, Bignum included (the server refuses anything outside i64 by name)
  # - `Float` as a JSON number; NaN and infinities are refused
  # - `String` in **binary encoding (ASCII-8BIT)** as `0x` + hex, for a BLOB column
  # - any other `String` as UTF-8 text; invalid UTF-8 is refused
  # - {Binary} as `0x` + hex, whatever the String's encoding was
  # - `BigDecimal` as plain decimal text with no exponent (`to_s("F")`); non-finite values are refused
  # - `Time` as ISO-8601 with microseconds; `Date`/`DateTime` as ISO-8601
  #
  # Everything else is refused by name rather than sent through `to_s`.
  module Params
    module_function

    # @param params [Array]
    # @return [Array] wire values
    def encode_all(params)
      raise ArgumentError, "SQL parameters must be an Array, got #{params.class}" unless params.is_a?(Array)

      params.each_with_index.map { |value, i| encode(value, i + 1) }
    end

    # @param value [Object]
    # @param index [Integer] 1-based position, for the error message
    # @return [nil, true, false, Integer, Float, String]
    def encode(value, index = 1)
      case value
      when nil, true, false, Integer
        value
      when Float
        raise ParameterError.new(index, "#{value} is not a finite number and has no SQL value") unless value.finite?

        value
      when Binary
        value.to_param
      when String
        encode_string(value, index)
      when Time
        value.iso8601(6)
      else
        encode_other(value, index)
      end
    end

    def encode_string(value, index)
      return "0x#{value.unpack1('H*')}" if value.encoding == Encoding::BINARY

      text = value.encoding == Encoding::UTF_8 ? value : value.encode(Encoding::UTF_8)
      raise ParameterError.new(index, "string is not valid UTF-8; mark bytes with TriCoreDB::Binary or String#b") unless text.valid_encoding?

      text
    rescue EncodingError => e
      raise ParameterError.new(index, "string cannot be converted to UTF-8 (#{e.message})")
    end

    def encode_other(value, index)
      if defined?(::BigDecimal) && value.is_a?(::BigDecimal)
        raise ParameterError.new(index, "BigDecimal #{value} is not finite and has no SQL value") unless value.finite?

        return value.to_s("F")
      end
      return value.iso8601 if defined?(::Date) && value.is_a?(::Date)

      raise ParameterError.new(
        index,
        "no SQL parameter form for #{value.class}. Convert it explicitly (a String, Integer, Float, " \
        "BigDecimal, Time, TriCoreDB::Binary, true/false or nil)"
      )
    end
    private_class_method :encode_string, :encode_other
  end
end
