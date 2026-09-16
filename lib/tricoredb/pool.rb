# frozen_string_literal: true

module TriCoreDB
  # A thread-safe pool of connections.
  #
  # A connection is lent to exactly one block at a time. Connections are
  # created lazily up to `size`.
  #
  # A session transaction is bound to its connection, so a connection is never
  # returned mid-transaction: a block that raises with one open has it rolled
  # back, and a block that returns with one open has it rolled back and raises.
  #
  # @example
  #   pool = TriCoreDB::Pool.new(size: 8, host: "db", port: 8427, user: "app", secret: ENV["TRICORE_SECRET"])
  #   pool.with { |db| db.query("SELECT 1") }
  #   pool.close
  class Pool
    # @return [Integer]
    attr_reader :size

    # @param size [Integer] maximum connections
    # @param checkout_timeout [Numeric] seconds {#with} waits for a free connection
    # @param connect_options [Hash] passed to {Client.connect}, `tls:` included
    def initialize(size: 8, checkout_timeout: 10, **connect_options)
      raise ArgumentError, "pool size must be >= 1" if size < 1

      @size = size
      @checkout_timeout = checkout_timeout
      @connect_options = connect_options
      @idle = []
      @created = 0
      @waiting = 0
      @closed = false
      @lock = Mutex.new
      @available = ConditionVariable.new
    end

    # Borrow a connection for the duration of the block.
    #
    # @yieldparam db [Client]
    # @return [Object] the block's value
    # @raise [PoolTimeout] when none frees up within the timeout
    def with(timeout: @checkout_timeout)
      raise ArgumentError, "Pool#with needs a block" unless block_given?

      client = checkout(timeout)
      broken = false
      begin
        begin
          result = yield client
        rescue Exception => e # rubocop:disable Lint/RescueException
          if client.closed? || stream_broken?(e)
            broken = true
          elsif client.in_transaction?
            broken = !abandon_transaction(client)
          end
          raise
        end
        if client.in_transaction?
          broken = !abandon_transaction(client)
          raise Error, "the block returned with a session transaction still open on the pooled connection; it " \
                       "has been rolled back rather than returned to the pool. Commit or roll back inside the " \
                       "block, or use db.transaction { }"
        end
        result
      ensure
        checkin(client, broken)
      end
    end

    # @return [Hash{Symbol => Integer}]
    def stats
      @lock.synchronize do
        { size: @size, created: @created, idle: @idle.size, in_use: @created - @idle.size, waiting: @waiting }
      end
    end

    # Close idle connections and refuse further checkouts. Connections in use are
    # closed when they are returned.
    def close
      idle = @lock.synchronize do
        @closed = true
        @available.broadcast
        list = @idle.dup
        @idle.clear
        @created -= list.size
        list
      end
      idle.each(&:close)
      nil
    end

    private

    def stream_broken?(error)
      case error
      when ConnectionError, ProtocolError then true
      when ServerError then error.frame?
      else false
      end
    end

    def abandon_transaction(client)
      client.rollback
      true
    rescue StandardError
      false
    end

    def checkout(timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      @lock.synchronize do
        loop do
          raise Error, "pool is closed" if @closed

          return @idle.pop unless @idle.empty?

          if @created < @size
            @created += 1
            break
          end
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise PoolTimeout, "no pooled connection available within #{timeout}s (size=#{@size})" if remaining <= 0

          @waiting += 1
          begin
            @available.wait(@lock, remaining)
          ensure
            @waiting -= 1
          end
        end
      end
      begin
        Client.connect(**@connect_options)
      rescue Exception # rubocop:disable Lint/RescueException
        @lock.synchronize do
          @created -= 1
          @available.signal
        end
        raise
      end
    end

    def checkin(client, broken)
      discard = @lock.synchronize do
        if broken || @closed || client.closed? || client.in_transaction?
          @created -= 1
          @available.signal
          true
        else
          @idle.push(client)
          @available.signal
          false
        end
      end
      client.close if discard
    end
  end
end
