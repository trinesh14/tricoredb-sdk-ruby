# frozen_string_literal: true

require "socket"
require "openssl"

module TriCoreDB
  # A framed byte stream over TCP or TLS, with deadline-bounded reads.
  class Transport
    # @return [IO] the underlying socket (a TCPSocket, an SSLSocket, or any IO in tests)
    attr_reader :io

    # Open a TCP connection, optionally wrapped in TLS.
    #
    # @param host [String]
    # @param port [Integer]
    # @param connect_timeout [Numeric, nil] seconds for TCP connect and the TLS handshake
    # @param tls [Hash, true, nil] see {Transport.tls_context}
    # @return [Transport]
    # @raise [ConnectionError]
    def self.open(host, port, connect_timeout: 10, tls: nil)
      sock = begin
        Socket.tcp(host, port, connect_timeout: connect_timeout)
      rescue SystemCallError, SocketError, IOError => e
        raise ConnectionError, "connect to #{host}:#{port} failed: #{e.message}"
      rescue StandardError => e
        raise ConnectionError, "connect to #{host}:#{port} failed: #{e.class}: #{e.message}" if e.class.name.include?("Timeout")

        raise
      end
      sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      return new(sock) if tls.nil? || tls == false

      opts = tls == true ? {} : tls
      new(start_tls(sock, host, opts, connect_timeout))
    end

    # Build the SSL context.
    #
    # Accepted options:
    # - `ca_file`: PEM bundle used to verify the server; without it the system trust store is used
    # - `server_name`: expected certificate name and SNI (default: the host)
    # - `client_cert_file` / `client_key_file`: identity for mutual TLS, both or neither
    # - `danger_accept_invalid_certs`: skip verification entirely (development only)
    #
    # @param opts [Hash]
    # @return [OpenSSL::SSL::SSLContext]
    def self.tls_context(opts)
      opts = opts.transform_keys(&:to_sym)
      cert_file = opts[:client_cert_file]
      key_file = opts[:client_key_file]
      if cert_file.nil? != key_file.nil?
        missing = cert_file.nil? ? "client_cert_file" : "client_key_file"
        raise ArgumentError, "tls #{missing} is required alongside the other (both are needed for mutual TLS)"
      end

      ctx = OpenSSL::SSL::SSLContext.new
      ctx.min_version = OpenSSL::SSL::TLS1_2_VERSION
      if opts[:danger_accept_invalid_certs]
        ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
      else
        ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
        store = OpenSSL::X509::Store.new
        if opts[:ca_file]
          read_file(opts[:ca_file], "ca_file")
          store.add_file(opts[:ca_file])
        else
          store.set_default_paths
        end
        ctx.cert_store = store
      end
      if cert_file
        ctx.cert = OpenSSL::X509::Certificate.new(read_file(cert_file, "client_cert_file"))
        ctx.key = OpenSSL::PKey.read(read_file(key_file, "client_key_file"))
      end
      ctx
    end

    def self.read_file(path, label)
      File.binread(path)
    rescue SystemCallError => e
      raise ArgumentError, "tls #{label} `#{path}`: #{e.class.name.split('::').last}"
    end
    private_class_method :read_file

    def self.start_tls(sock, host, opts, timeout)
      opts = opts.transform_keys(&:to_sym)
      ctx = tls_context(opts)
      server_name = opts[:server_name] || host
      ssl = OpenSSL::SSL::SSLSocket.new(sock, ctx)
      ssl.hostname = server_name if server_name && server_name !~ /\A[\d.:]+\z/
      ssl.sync_close = true
      ssl.sync = true
      deadline = timeout && monotonic + timeout
      loop do
        result = ssl.connect_nonblock(exception: false)
        break unless result.is_a?(Symbol)

        wait(ssl, result, deadline) || raise(ConnectionError, "tls handshake with #{host} timed out")
      end
      ssl.post_connection_check(server_name) unless opts[:danger_accept_invalid_certs]
      ssl
    rescue OpenSSL::SSL::SSLError, SystemCallError, IOError => e
      sock.close unless sock.closed?
      raise ConnectionError, "tls verification of `#{server_name}` failed: #{e.message}"
    end
    private_class_method :start_tls

    def self.monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # @return [Boolean] false on timeout
    def self.wait(io, what, deadline)
      remaining = deadline && (deadline - monotonic)
      return false if remaining && remaining <= 0

      ready = what == :wait_writable ? IO.select(nil, [io], nil, remaining) : IO.select([io], nil, nil, remaining)
      !ready.nil?
    end

    # @param io [IO]
    def initialize(io)
      @io = io
    end

    # @return [Boolean]
    def closed?
      @io.nil?
    end

    # Write one frame.
    def write_frame(tag, payload)
      bytes = Frame.encode(tag, payload)
      raise ConnectionError, "connection is closed" if @io.nil?

      @io.write(bytes)
      @io.flush if @io.respond_to?(:flush)
      nil
    end

    # Read one frame.
    #
    # @param timeout [Numeric, nil] seconds; nil waits indefinitely
    # @return [Array(Integer, Object)] `[tag, decoded_payload]`
    def read_frame(timeout)
      deadline = timeout && self.class.monotonic + timeout
      tag, length = Frame.decode_header(read_exactly(Frame::HEADER_SIZE, deadline, timeout))
      body = length.zero? ? "".b : read_exactly(length, deadline, timeout)
      [tag, Frame.decode_body(body)]
    end

    # Close the socket. Idempotent.
    def close
      io = @io
      @io = nil
      io&.close
    rescue StandardError
      nil
    end

    private

    def read_exactly(n, deadline, timeout)
      buf = +"".b
      while buf.bytesize < n
        raise ConnectionError, "connection is closed" if @io.nil?

        chunk = @io.read_nonblock(n - buf.bytesize, exception: false)
        case chunk
        when :wait_readable, :wait_writable
          unless self.class.wait(@io, chunk, deadline)
            raise ReadTimeout, "no reply within #{timeout}s; the connection is closed because the reply may still " \
                               "be in flight and would be read as the next request's answer"
          end
        when nil
          raise ConnectionError, "connection closed by the server"
        else
          buf << chunk
        end
      end
      buf
    end
  end
end
