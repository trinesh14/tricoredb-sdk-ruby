# frozen_string_literal: true

require "json"

module TriCoreDB
  # A SQL result set. Every cell is the server's text rendering of the value.
  class Rows
    include Enumerable

    # @return [Array<String>]
    attr_reader :columns
    # @return [Array<Array<String, nil>>]
    attr_reader :rows

    def initialize(columns, rows)
      @columns = columns
      @rows = rows
    end

    def each(&block)
      return enum_for(:each) unless block

      @rows.each(&block)
    end

    # @return [Integer]
    def size
      @rows.size
    end
    alias length size

    # @return [Array<Hash{String => String}>] rows keyed by column name
    def to_hashes
      @rows.map { |r| @columns.zip(r).to_h }
    end
  end

  # One entry of a cache stream.
  StreamEntry = Struct.new(:id, :fields) do
    # @return [Hash{String => String}] fields decoded as UTF-8, for the all-text case
    def text
      fields.to_h { |f, v| [f.dup.force_encoding(Encoding::UTF_8), v.dup.force_encoding(Encoding::UTF_8)] }
    end
  end

  # A server RESPONSE: typed data plus how it was produced.
  class Response
    # @return [String]
    attr_reader :request_id
    # @return [String] `ok`, `error` or `not_implemented`
    attr_reader :status
    # @return [Object] the externally tagged ResponseData (`"Empty"`, `{"Json" => ...}`, ...)
    attr_reader :data
    # @return [Hash]
    attr_reader :diagnostics

    # @param raw [Hash] the decoded RESPONSE payload
    def initialize(raw)
      raw = {} unless raw.is_a?(Hash)
      @request_id = raw["request_id"].to_s
      @status = raw["status"] || "error"
      @data = raw["data"]
      @diagnostics = raw["diagnostics"].is_a?(Hash) ? raw["diagnostics"] : {}
    end

    def ok?
      @status == "ok"
    end

    # @return [Array<String>] non-fatal warnings; a partially applied broadcast reports here while still `ok`
    def warnings
      @diagnostics["warnings"] || []
    end

    # @return [String, nil]
    def error_code
      @diagnostics["error_code"]
    end

    # @return [String, nil]
    def leader_hint
      @diagnostics["leader_hint"]
    end

    def redirect?
      error_code == NOT_LEADER
    end

    # @return [Integer, nil] `rows_affected` from a SQL write, when the server reported it
    def rows_affected
      json = arm("Json")
      json.is_a?(Hash) && json["rows_affected"].is_a?(Integer) ? json["rows_affected"] : nil
    end

    # Whether the data carries the named arm (`Json`, `Rows`, ...). A `null` value still counts.
    def arm?(name)
      @data.is_a?(Hash) && @data.key?(name)
    end

    # @return [Object, nil]
    def arm(name)
      @data.is_a?(Hash) ? @data[name] : nil
    end

    # @return [String] the kind of data, for messages
    def kind
      @data.is_a?(Hash) ? (@data.keys.first || "{}") : @data.inspect
    end

    # Build the error for a response that is not `ok`.
    #
    # @param txn_open [Boolean] whether a session transaction was open on the connection
    # @return [ServerError]
    def to_error(txn_open = false)
      text = arm("Message") || (arm?("Json") ? JSON.generate(arm("Json")) : nil) || "request failed"
      message = "#{text} (server status: #{@status})"
      if redirect?
        message += if leader_hint
                     " [not_leader: the leader serves clients at `#{leader_hint}`. This driver does not follow " \
                     "the hint on its own; send the request there."
                   else
                     " [not_leader: there is no leader address to name (an election is in progress, or the " \
                     "leader has no address configured). Wait and try again."
                   end
        message += " The open session transaction is over: it cannot continue on another node." if txn_open
        message += "]"
      end
      ServerError.new(message, code: error_code, leader_hint: leader_hint, status: @status, response: self)
    end
  end
end
