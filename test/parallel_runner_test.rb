# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

class ParallelRunnerTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  RUNNER = File.join(ROOT, "test/support/parallel_runner.rb")
  HELPER = File.join(ROOT, "test/test_helper.rb")
  BOOT = <<~'RUBY'
    require "minitest/test_task"
    require ARGV.fetch(0)
    task = Minitest::TestTask.new
    task.test_globs = ["test/*_test.rb"]
    task.warning = false
    exit(ParallelTestRunner.new(task).call ? 0 : 1)
  RUBY

  def test_workers_run_concurrently_and_execute_each_file_once
    with_project do |dir|
      2.times do |index|
        write_test(dir, index, <<~RUBY)
          require "timeout"
          File.write("ready-#{index}", Process.pid.to_s)
          Timeout.timeout(10) { sleep 0.01 until File.exist?("ready-#{1 - index}") }
          File.write("done-#{index}", "done")
        RUBY
      end

      output, status = run_tests(dir)

      assert_predicate status, :success?, output
      assert_equal %w[done-0 done-1], Dir.children(dir).grep(/\Adone-/).sort
      refute_equal File.read(File.join(dir, "ready-0")), File.read(File.join(dir, "ready-1"))
    end
  end

  def test_worker_failure_is_reported_and_other_worker_output_is_retained
    with_project do |dir|
      write_test(dir, 0, 'warn "intentional failure"; exit 1')
      write_test(dir, 1, 'puts "other worker completed"')

      output, status = run_tests(dir)

      refute_predicate status, :success?
      assert_includes output, "intentional failure"
      assert_includes output, "other worker completed"
    end
  end

  def test_signaled_worker_fails_the_run
    with_project do |dir|
      write_test(dir, 0, 'Process.kill("TERM", Process.pid)')

      _output, status = run_tests(dir)

      refute_predicate status, :success?
    end
  end

  def test_invalid_worker_count_fails_without_running_tests
    with_project do |dir|
      write_test(dir, 0, 'File.write("started", "yes")')
      %w[0 -1 invalid].each do |workers|
        output, status = run_tests(dir, workers:)

        refute_predicate status, :success?, output
        refute_path_exists File.join(dir, "started")
      end
    end
  end

  def test_empty_suite_fails
    with_project do |dir|
      _output, status = run_tests(dir)

      refute_predicate status, :success?
    end
  end

  def test_uncovered_workers_do_not_inherit_coverage_configuration
    with_project do |dir|
      write_test(dir, 0, 'abort "coverage configuration leaked" if ENV.key?("QUALITY_GATE_TEST_COVERAGE")')

      output, status = run_tests(dir)

      assert_predicate status, :success?, output
    end
  end

  def test_worker_count_one_and_timing_runs_execute_in_one_process
    with_project do |dir|
      2.times { |index| write_test(dir, index, "File.write('pid-#{index}', Process.pid.to_s)") }
      [{ workers: "1" }, { timing: "1" }].each do |options|
        output, status = run_tests(dir, **options)

        assert_predicate status, :success?, output
        assert_equal File.read(File.join(dir, "pid-0")), File.read(File.join(dir, "pid-1"))
      end
    end
  end

  def test_coverage_merges_all_workers_and_matches_serial_coverage
    with_project do |dir|
      write_covered_tests(dir)
      serial_output, serial_status = run_tests(dir, workers: "1", coverage: "1")
      assert_predicate serial_status, :success?, serial_output
      serial = coverage_summary(dir)

      output, status = run_tests(dir, coverage: "1")

      assert_predicate status, :success?, output
      assert_equal serial, coverage_summary(dir)
      assert_equal 100.0, coverage_summary(dir).fetch("branch")
      assert_coverage_reports(dir)
    end
  end

  def test_coverage_does_not_reuse_previous_worker_results
    with_project do |dir|
      write_covered_tests(dir)
      output, status = run_tests(dir, coverage: "1")
      assert_predicate status, :success?, output
      assert_equal 100.0, coverage_summary(dir).fetch("branch")
      write_covered_tests(dir, flags: [true, true])

      output, status = run_tests(dir, coverage: "1")

      assert_predicate status, :success?, output
      assert_equal 50.0, coverage_summary(dir).fetch("branch")
    end
  end

  def test_missing_worker_coverage_fails_even_when_every_worker_exits_zero
    with_project do |dir|
      write_covered_tests(dir)
      write_test(dir, 1, "exit 0")

      output, status = run_tests(dir, coverage: "1")

      refute_predicate status, :success?, output
      assert_includes output, "Missing coverage"
      refute_path_exists File.join(dir, "coverage", ".last_run.json")
    end
  end

  def test_failed_worker_does_not_leave_a_previous_passing_report
    with_project do |dir|
      write_covered_tests(dir)
      output, status = run_tests(dir, coverage: "1")
      assert_predicate status, :success?, output
      write_test(dir, 1, "exit 1")

      _output, status = run_tests(dir, coverage: "1")

      refute_predicate status, :success?
      refute_path_exists File.join(dir, "coverage", ".last_run.json")
      refute_path_exists File.join(dir, "coverage", "coverage.json")
      refute_path_exists File.join(dir, "coverage", "index.html")
    end
  end

  def test_formatter_failure_cannot_report_a_successful_run
    with_project do |dir|
      write_covered_tests(dir)
      boot = <<~RUBY
        require "simplecov"
        SimpleCov::Formatter::HTMLFormatter.class_eval do
          def format(_result)
            raise "intentional formatter failure"
          end
        end
        #{BOOT}
      RUBY

      output, status = run_tests(dir, coverage: "1", boot:)

      refute_predicate status, :success?, output
      assert_includes output, "Missing coverage report"
    end
  end

  private

  def with_project
    Dir.mktmpdir("parallel-test-project") do |dir|
      FileUtils.mkdir_p(File.join(dir, "test"))
      yield dir
    end
  end

  def write_test(dir, index, body)
    File.write(File.join(dir, "test", "worker_#{index}_test.rb"), body)
  end

  def write_covered_tests(dir, flags: [true, false])
    FileUtils.mkdir_p(File.join(dir, "lib"))
    File.write(File.join(dir, "lib", "choice.rb"), <<~RUBY)
      def covered_choice(flag)
        if flag
          :yes
        else
          :no
        end
      end
    RUBY
    flags.each_with_index do |flag, index|
      write_test(dir, index, <<~RUBY)
        require #{HELPER.inspect}
        abort "worker configuration leaked" if ENV.key?("QUALITY_GATE_TEST_COVERAGE")
        require "./lib/choice"
        covered_choice(#{flag})
      RUBY
    end
  end

  def coverage_summary(dir)
    JSON.parse(File.read(File.join(dir, "coverage", ".last_run.json"))).fetch("result")
  end

  def assert_coverage_reports(dir)
    assert_path_exists File.join(dir, "coverage", "index.html")
    report = JSON.parse(File.read(File.join(dir, "coverage", "coverage.json")))
    assert_equal File.realpath(dir), report.dig("meta", "simplecov_root")
  end

  def run_tests(dir, boot: BOOT, **options)
    environment = {
      "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"),
      "TEST_WORKERS" => options.fetch(:workers, "2"),
      "COVERAGE" => options[:coverage],
      "QUALITY_GATE_ACCEPTANCE_TIMING" => options[:timing]
    }
    Open3.capture2e(environment, RbConfig.ruby, "-rbundler/setup", "-e", boot, RUNNER, chdir: dir)
  end
end
