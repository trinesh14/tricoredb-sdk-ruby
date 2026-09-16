# frozen_string_literal: true

require_relative "tricoredb/version"
require_relative "tricoredb/errors"
require_relative "tricoredb/frame"
require_relative "tricoredb/params"
require_relative "tricoredb/builders"
require_relative "tricoredb/response"
require_relative "tricoredb/transport"
require_relative "tricoredb/client"
require_relative "tricoredb/pool"

# Ruby driver for TriCoreDB's native `tricore` protocol.
module TriCoreDB
  # Shorthand for {Client.connect}.
  #
  # @return [Client]
  def self.connect(**options)
    Client.connect(**options)
  end
end
