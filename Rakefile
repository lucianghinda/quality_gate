# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"

test_task = Minitest::TestTask.create do |task|
  task.test_globs = [
    "test/test_*.rb",
    "test/*_test.rb",
    "test/acceptance/**/*_test.rb",
    "test/quality_gate/**/*_test.rb"
  ]
end

namespace :test do
  desc "Run tests in separate processes (TEST_WORKERS defaults to 2)"
  task :parallel do
    require_relative "test/support/parallel_runner"

    abort "Parallel tests failed" unless ParallelTestRunner.new(test_task).call
  end
end

require "rubocop/rake_task"

RuboCop::RakeTask.new

task default: %i[test rubocop]
