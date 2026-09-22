# frozen_string_literal: true

require "fileutils"
require "json"

# Owns final report publication; workers only write isolated raw resultsets.
class ParallelCoverage
  REPORTS = %w[index.html coverage.json .last_run.json].freeze

  def initialize(directory, workers)
    @directory = directory
    @workers = workers
    @destination = File.expand_path("coverage")
  end

  def run
    FileUtils.mkdir_p(@destination)
    File.open(File.join(@destination, ".quality_gate.lock"), File::RDWR | File::CREAT, 0o644) do |lock|
      lock.flock(File::LOCK_EX)
      clear_reports
      return false unless yield

      collate(result_paths)
      validate_reports
      true
    end
  end

  private

  def clear_reports
    [*REPORTS, ".resultset.json"].each do |name|
      FileUtils.rm_f(File.join(@destination, name))
    end
  end

  def validate_reports
    REPORTS.each do |name|
      raise "Missing coverage report: #{name}" unless File.file?(File.join(@destination, name))
    end
  end

  def result_paths
    Array.new(@workers) do |index|
      name = "worker-#{index}"
      path = File.join(@directory, name, ".resultset.json")
      raise "Missing coverage for #{name}" unless File.file?(path)

      coverage = JSON.parse(File.read(path)).fetch(name).fetch("coverage")
      raise "Invalid coverage for #{name}" unless coverage.is_a?(Hash)

      path
    end
  end

  def collate(paths)
    require "simplecov"
    require "undercover/simplecov_formatter"

    destination = @destination
    SimpleCov.collate(paths, processes: 1) do
      coverage_path destination
      enable_coverage :branch
      add_filter "/test/"
      formatters [SimpleCov::Formatter::HTMLFormatter, SimpleCov::Formatter::Undercover]
    end
  end
end
