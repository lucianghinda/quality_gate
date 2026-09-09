# frozen_string_literal: true

# quality_gate coverage — start
if ENV["COVERAGE"] == "1"
  require "simplecov"
  require "undercover/simplecov_formatter"

  SimpleCov.formatter = SimpleCov::Formatter::Undercover
  SimpleCov.start do
    enable_coverage :branch
    add_filter "/test/"
    add_filter "/spec/"
  end
end
# quality_gate coverage — end
if ENV["COVERAGE"] == "1"
  require "fileutils"
  require "simplecov"
  require "undercover/simplecov_formatter"

  coverage_directory = File.expand_path(SimpleCov.coverage_path)
  FileUtils.mkdir_p(coverage_directory)
  coverage_lock = File.open(
    File.join(coverage_directory, ".quality_gate.lock"),
    File::RDWR | File::CREAT,
    0o644
  )
  release_coverage_lock = proc do
    next if coverage_lock.closed?

    coverage_lock.flock(File::LOCK_UN)
    coverage_lock.close
  end

  # Register before SimpleCov.start so reverse callback order keeps the lock through formatting.
  if defined?(Minitest) && Minitest.respond_to?(:after_run)
    Minitest.after_run(&release_coverage_lock)
  else
    at_exit(&release_coverage_lock)
  end
  coverage_lock.flock(File::LOCK_EX)

  # The formatters use incompatible coverage.json metadata, so HTML must not read Undercover's prior report.
  FileUtils.rm_f(File.join(coverage_directory, "coverage.json"))
  SimpleCov.formatters [SimpleCov::Formatter::HTMLFormatter, SimpleCov::Formatter::Undercover]
  SimpleCov.start do
    enable_coverage :branch
    add_filter "/test/"
  end
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "quality_gate"

require "minitest/autorun"
