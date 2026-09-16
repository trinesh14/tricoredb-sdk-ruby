# frozen_string_literal: true

module TriCoreDB
  # The code a not-leader refusal carries in `diagnostics.error_code`.
  NOT_LEADER = "not_leader"

  # Base class for every failure raised by this gem.
  #
  # Branch on {#code}, never on the message: the message is prose the server is
  # free to reword, the code is contract.
  class Error < StandardError
    # @return [String, nil] the machine-readable reason, when the server sent one
    attr_reader :code
    # @return [String, nil] a `host:port` of the current leader, only alongside `not_leader`
    attr_reader :leader_hint

    # @param message [String, nil]
    # @param code [String, nil]
    # @param leader_hint [String, nil]
    def initialize(message = nil, code: nil, leader_hint: nil)
      super(message)
      @code = code
      @leader_hint = leader_hint
    end

    # Whether the request was right but reached a node that is not the leader.
    #
    # The driver never follows {#leader_hint} on its own: the address may not be
    # reachable from this client, a new connection must authenticate again, and
    # an open session transaction cannot move to another node at all.
    #
    # @return [Boolean]
    def redirect?
      code == NOT_LEADER
    end
  end

  # The server refused the credentials (an AUTH_OK frame with `ok: false`).
  class AuthError < Error; end

  # The byte stream can no longer be trusted: a bad header, an oversized frame,
  # an unexpected tag, or a refused handshake. The connection is closed.
  class ProtocolError < Error; end

  # The socket failed or was closed. The connection is unusable.
  class ConnectionError < Error; end

  # No reply arrived within the connection's `read_timeout`. The connection is
  # closed, because the late reply would otherwise be read as the answer to the
  # next request.
  class ReadTimeout < ConnectionError; end

  # The server processed the request and did not complete it: a RESPONSE whose
  # status is not `ok`, or an ERROR frame answering a request.
  class ServerError < Error
    # @return [String, nil] `error` or `not_implemented` for a RESPONSE; nil for an ERROR frame
    attr_reader :status
    # @return [Response, nil] the full response, for its diagnostics
    attr_reader :response

    def initialize(message = nil, code: nil, leader_hint: nil, status: nil, response: nil, frame: false)
      super(message, code: code, leader_hint: leader_hint)
      @status = status
      @response = response
      @frame = frame
    end

    # @return [Boolean] true when the refusal arrived as an ERROR frame rather than a RESPONSE
    def frame?
      @frame
    end
  end

  # The server did not grant a capability this call needs. Raised before
  # anything is sent.
  class FeatureNotGranted < Error
    # @return [String] the feature name, e.g. `SERVER_PARAMS`
    attr_reader :feature

    def initialize(feature, message)
      super(message)
      @feature = feature
    end
  end

  # A SQL parameter this driver will not encode. Raised before anything is sent.
  class ParameterError < Error
    # @return [Integer] the 1-based parameter position
    attr_reader :index

    def initialize(index, message)
      super("parameter ##{index}: #{message}")
      @index = index
    end
  end

  # {Pool#with} waited longer than its checkout timeout.
  class PoolTimeout < Error; end
end
