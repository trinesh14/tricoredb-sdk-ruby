# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "socket"
require "securerandom"

# A private `tricore-server` for the tests that need a real one.
#
# The binary is named by TRICORE_SERVER_BIN, or found in a sibling
# `tricore/tricore-db/target/{release,debug}` checkout. It is never built here:
# building the server from a test is slow and collides with anything else
# compiling.
#
# When there is no binary, {.skip_reason} says so and the live tests skip. Someone
# who installed this gem from RubyGems has no server, and `rake test` must still be
# green for them.
class LiveServer
  CONFIG = <<~TOML
    [server]
    host = "127.0.0.1"
    port = 0
    protocol = "tricore"
    node_id = "sdk-ruby-tests"
    region_id = "local"

    [modules]
    sql = true
    document = true
    cache = true
    vector = true
    graph = true
    llm = true
    cluster = false

    [security]
    auth_mode = "password"
    dev_auth = true
    allow_default_admin = false

    [tls]
    enabled = false
  TOML

  class << self
    # @return [String, nil] why the live tests cannot run, or nil when they can
    def skip_reason
      return nil if binary

      "no tricore-server binary: set TRICORE_SERVER_BIN, or run one from the Docker image (see the README)"
    end

    # One server shared by every live test in this process.
    def shared
      @shared ||= start
    end

    def binary
      @binary ||= find_binary
    end

    def start
      raise skip_reason if binary.nil?

      new(binary)
    end

    private

    def find_binary
      name = Gem.win_platform? ? "tricore-server.exe" : "tricore-server"
      named = ENV["TRICORE_SERVER_BIN"]
      return named if named && !named.empty? && File.file?(named)
      return nil if named && !named.empty?

      dir = File.expand_path(__dir__)
      while dir != File.dirname(dir)
        %w[release debug].each do |profile|
          candidate = File.join(dir, "target", profile, name)
          return candidate if File.file?(candidate)
        end
        dir = File.dirname(dir)
      end
      nil
    end
  end

  # @return [String] the host the server bound to
  attr_reader :host
  # @return [Integer] the port it listens on
  attr_reader :port

  def initialize(binary)
    @dir = Dir.mktmpdir("tricoredb-ruby-")
    config = File.join(@dir, "tricore.toml")
    File.write(config, CONFIG)
    data = File.join(@dir, "data")
    Dir.mkdir(data)

    read_end, write_end = IO.pipe
    @pid = spawn(binary, "--config", config, "--port", "0", "--data-dir", data,
                 out: write_end, err: File::NULL)
    write_end.close

    # The address is read from the server's own line rather than assumed: sibling
    # runs bind their own servers at the same time. The reader keeps draining
    # afterwards, because a full pipe would stop the server dead.
    address = nil
    @drain = Thread.new do
      read_end.each_line do |line|
        address ||= line[/listening on (\S+)/, 1]
      end
    rescue IOError
      nil
    end

    deadline = Time.now + 60
    sleep 0.05 while address.nil? && Time.now < deadline
    raise "the server never said which address it is listening on" if address.nil?

    @host, port = address.split(":")
    @port = Integer(port)
    at_exit { stop }
  end

  # Connect to this server as `admin`.
  def connect(**options)
    TriCoreDB::Client.connect(host: @host, port: @port, user: "admin", secret: "pw",
                              connect_timeout: 15, **options)
  end

  def stop
    begin
      Process.kill("KILL", @pid)
      Process.wait(@pid)
    rescue StandardError
      nil
    end
    @drain&.kill
    begin
      FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
    rescue StandardError
      # The server may still hold a file open on Windows; a leftover temp
      # directory is not worth failing a test run over.
      nil
    end
  end
end

# A name no other test in this run uses, so tests can share one server safely.
def unique(prefix)
  "#{prefix}_#{SecureRandom.hex(5)}"
end
