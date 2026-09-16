# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/unit/**/*_test.rb"]
  t.warning = true
end

namespace :test do
  desc "Run the live tests; needs TRICORE_HOST, TRICORE_PORT, TRICORE_USER and TRICORE_SECRET"
  Rake::TestTask.new(:integration) do |t|
    t.libs << "lib" << "test"
    t.test_files = FileList["test/integration/**/*_test.rb"]
    t.warning = true
  end
end

desc "Build the gem"
task :build do
  sh "gem build tricoredb.gemspec"
end

task default: :test
