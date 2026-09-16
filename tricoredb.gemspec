# frozen_string_literal: true

require_relative "lib/tricoredb/version"

Gem::Specification.new do |spec|
  spec.name = "tricoredb"
  spec.version = TriCoreDB::VERSION
  spec.authors = ["Trinesh Kumar"]
  spec.summary = "Ruby driver for TriCoreDB's native tricore protocol"
  spec.description = "A dependency-free Ruby client for TriCoreDB: SQL with server-side parameters, " \
                     "session transactions, document, vector, graph, cache, LLM context and admin operations " \
                     "over the native framed protocol, with TLS, timeouts, cancellation and a thread-safe pool."
  spec.license = "Apache-2.0"
  spec.homepage = "https://github.com/trinesh14/tricoredb-sdk-ruby"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "documentation_uri" => "https://rubydoc.info/gems/tricoredb",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir.glob("lib/**/*.rb") + %w[README.md LICENSE CHANGELOG.md tricoredb.gemspec]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest", "~> 5.16"
  spec.add_development_dependency "rake", "~> 13.0"
end
