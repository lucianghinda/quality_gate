# frozen_string_literal: true

require "rbconfig"
require "shellwords"
require "tmpdir"
require_relative "parallel_coverage"

# Runs file groups in separate Ruby processes; no test code executes in threads.
class ParallelTestRunner
  def initialize(task, workers: ENV.fetch("TEST_WORKERS", "2"))
    @task = task
    @workers = Integer(workers)
    raise ArgumentError, "TEST_WORKERS must be positive" unless @workers.positive?

    @workers = 1 if ENV["QUALITY_GATE_ACCEPTANCE_TIMING"] == "1"
  end

  def call
    groups = file_groups
    raise ArgumentError, "No test files selected" if groups.empty?

    Dir.mktmpdir("quality-gate-tests") do |directory|
      if ENV["COVERAGE"] == "1"
        ParallelCoverage.new(directory, groups.length).run { run_groups(groups, directory) }
      else
        run_groups(groups, directory)
      end
    end
  end

  private

  def file_groups
    files = Dir[*@task.test_globs].uniq.sort_by { |file| [-File.size(file), file] }
    groups = Array.new([@workers, files.length].min) { [] }
    files.each_with_index { |file, index| groups[index % groups.length] << file }
    groups
  end

  def run_groups(groups, directory)
    processes = []
    groups.each_with_index do |files, index|
      log = File.join(directory, "worker-#{index}.log")
      pid = start_worker(files, directory, index, log)
      processes << [pid, log]
    end
    processes.map { |pid, log| finish_worker(pid, log) }.all?
  ensure
    processes&.each { reap_worker(_1.first) }
  end

  def start_worker(files, directory, index, log)
    coverage = File.join(directory, "worker-#{index}") if ENV["COVERAGE"] == "1"
    environment = { "QUALITY_GATE_TEST_COVERAGE" => coverage }
    command = [RbConfig.ruby, *Shellwords.split(@task.make_test_cmd(files))]
    Process.spawn(environment, *command, out: log, err: %i[child out])
  end

  def finish_worker(pid, log)
    _pid, status = Process.wait2(pid)
    puts "--- Test worker #{pid} ---"
    print File.read(log)
    status.success?
  end

  def reap_worker(pid)
    return if Process.waitpid(pid, Process::WNOHANG)

    Process.kill("TERM", pid)
    Process.waitpid(pid)
  rescue Errno::ECHILD, Errno::ESRCH
    # Already collected, or the worker exited while cleanup was starting.
    nil
  end
end
