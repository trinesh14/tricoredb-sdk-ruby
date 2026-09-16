# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "tricoredb"

require_relative "support/scripted_peer"
require_relative "support/live_server"
