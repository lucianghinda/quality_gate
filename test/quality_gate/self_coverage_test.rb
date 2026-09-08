# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "timeout"
require "tmpdir"
require "yaml"

module QualityGate
  class SelfCoverageTest < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)
    TEST_HELPER = File.join(ROOT, "test", "test_helper.rb")
    CONFIG = File.join(ROOT, ".quality_gate.yml")

    def test_coverage_switch_starts_before_quality_gate_with_the_repo_formatters
      state = covered_helper_state

      assert state.fetch("coverage_running")
      assert state.fetch("quality_gate_tracked")
      assert state.fetch("branch_coverage")
      assert_includes state.fetch("filters"), "/test/"
      assert_equal [
        "SimpleCov::Formatter::HTMLFormatter",
        "SimpleCov::Formatter::Undercover"
      ], state.fetch("formatters")
    end

    def test_test_helper_does_not_load_simplecov_without_the_coverage_switch
      stdout, stderr, status = run_probe(coverage: nil, source: <<~'RUBY')
        require ARGV.fetch(0)
        abort "SimpleCov unexpectedly loaded" if Object.const_defined?(:SimpleCov, false)
        puts "coverage inactive"
      RUBY

      assert_predicate status, :success?, stderr
      assert_includes stdout.lines, "coverage inactive\n"
    end

    def test_repository_config_runs_the_three_verify_adapters_with_independent_budgets
      assert_path_exists CONFIG
      return unless File.file?(CONFIG)

      config = YAML.safe_load_file(CONFIG)

      assert_equal %w[commands adapters coverage timeouts], config.keys
      assert_equal %w[bundle exec rake test], config.dig("commands", "verify", "test_suite")
      assert_equal %w[test_suite undercover simplecov], config.dig("adapters", "verify")
      assert_equal({ "minimum_line" => 96, "minimum_branch" => 83 }, config.fetch("coverage"))
      assert_equal({ "test_suite" => 240 }, config.fetch("timeouts"))
    end

    private

    def covered_helper_state
      source = <<~'RUBY'
        require "json"
        require ARGV.fetch(0)

        formatter_names = SimpleCov.formatter.new.formatters.map do |formatter|
          if formatter == SimpleCov::Formatter::Undercover
            "SimpleCov::Formatter::Undercover"
          elsif formatter == SimpleCov::Formatter::HTMLFormatter
            "SimpleCov::Formatter::HTMLFormatter"
          else
            formatter.is_a?(Class) ? formatter.name : formatter.class.name
          end
        end
        state = {
          coverage_running: Coverage.running?,
          quality_gate_tracked: Coverage.peek_result.key?(File.realpath(ARGV.fetch(1))),
          branch_coverage: SimpleCov.branch_coverage?,
          filters: SimpleCov.filters.map(&:filter_argument),
          formatters: formatter_names
        }
        SimpleCov.at_exit {}
        puts "SELF_COVERAGE_STATE=#{JSON.generate(state)}"
      RUBY
      quality_gate = File.join(ROOT, "lib", "quality_gate.rb")
      stdout, stderr, status = Dir.mktmpdir do |dir|
        run_probe(coverage: "1", source:, arguments: [quality_gate], chdir: dir)
      end

      assert_predicate status, :success?, "stdout: #{stdout}\nstderr: #{stderr}"
      line = stdout.lines.find { _1.start_with?("SELF_COVERAGE_STATE=") }
      refute_nil line, "missing coverage state in stdout: #{stdout}"

      JSON.parse(line.delete_prefix("SELF_COVERAGE_STATE="))
    end

    def run_probe(coverage:, source:, arguments: [], chdir: ROOT)
      Open3.capture3(
        probe_environment(coverage),
        RbConfig.ruby,
        "-rbundler/setup",
        "-e",
        source,
        TEST_HELPER,
        *arguments,
        chdir:
      )
    end

    def probe_environment(coverage)
      {
        "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"),
        "COVERAGE" => coverage
      }
    end
  end

  class SelfCoverageReportTest < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)
    TEST_HELPER = File.join(ROOT, "test", "test_helper.rb")
    FORMATTER_FAILURE = /Formatter .* failed/

    def test_repeated_coverage_runs_refresh_both_report_formats
      Dir.mktmpdir do |dir|
        assert_reporting_probe(dir)
        html_path = File.join(dir, "coverage", "index.html")
        json_path = File.join(dir, "coverage", "coverage.json")
        assert_path_exists html_path
        assert_path_exists json_path
        File.write(html_path, "stale")
        File.write(json_path, "stale")

        assert_reporting_probe(dir)

        refute_equal "stale", File.read(html_path)
        refute_equal "stale", File.read(json_path)
        assert_undercover_record(JSON.parse(File.read(json_path)), dir)
      end
    end

    private

    def assert_reporting_probe(dir)
      stdout, stderr, status = run_reporting_probe(dir)
      output = "#{stdout}\n#{stderr}"

      assert_predicate status, :success?, output
      refute_match FORMATTER_FAILURE, output
    end

    def assert_undercover_record(record, dir)
      assert_equal File.realpath(dir), record.dig("meta", "simplecov_root")
      assert_kind_of Array, record.dig("meta", "ignored_files")
      assert_kind_of Hash, record.fetch("coverage")
    end

    def run_reporting_probe(dir)
      Open3.capture3(
        { "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"), "COVERAGE" => "1" },
        RbConfig.ruby,
        "-rbundler/setup",
        "-e",
        "require ARGV.fetch(0)",
        TEST_HELPER,
        chdir: dir
      )
    end
  end

  class SelfCoverageLockTest < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)
    TEST_HELPER = File.join(ROOT, "test", "test_helper.rb")
    LIFECYCLE_LOCK = ".quality_gate.lock"
    LOCK_PROBE = <<~'RUBY'
      $stdout.sync = true
      original_flock = File.instance_method(:flock)
      File.define_method(:flock) do |operation|
        STDOUT.puts "lock requested" if operation == File::LOCK_EX
        original_flock.bind_call(self, operation)
      end
      puts "started"
      require ARGV.fetch(0)
      puts "covered code entered"
    RUBY

    def test_concurrent_coverage_helper_waits_for_the_lifecycle_lock
      Dir.mktmpdir { verify_serialized_helper_start(_1) }
    end

    private

    def verify_serialized_helper_start(dir)
      lock = acquire_lifecycle_lock(dir)
      stdin, stdout, stderr, thread = spawn_lock_probe(dir)
      stdin.close
      assert_probe_waits(stdout, thread)
      lock.flock(File::LOCK_UN)
      assert_probe_resumes(stdout, stderr, thread)
    ensure
      release_lifecycle_lock(lock)
      terminate_probe(thread)
      [stdin, stdout, stderr].compact.each { _1.close unless _1.closed? }
    end

    def assert_probe_waits(stdout, thread)
      assert_equal "started\n", read_probe_line(stdout)
      assert_equal "lock requested\n", read_probe_line(stdout)
      assert_predicate thread, :alive?
      refute IO.select([stdout], nil, nil, 0.1), "covered code ran while the lifecycle lock was held"
    end

    def assert_probe_resumes(stdout, stderr, thread)
      assert_equal "covered code entered\n", read_probe_line(stdout)
      status = Timeout.timeout(10) { thread.value }
      assert_predicate status, :success?, stderr.read
    end

    def acquire_lifecycle_lock(dir)
      coverage_dir = File.join(dir, "coverage")
      FileUtils.mkdir_p(coverage_dir)
      File.open(File.join(coverage_dir, LIFECYCLE_LOCK), File::RDWR | File::CREAT, 0o644).tap do |lock|
        lock.flock(File::LOCK_EX)
      end
    end

    def spawn_lock_probe(dir)
      Open3.popen3(
        { "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"), "COVERAGE" => "1" },
        RbConfig.ruby,
        "-rbundler/setup",
        "-e",
        LOCK_PROBE,
        TEST_HELPER,
        chdir: dir
      )
    end

    def read_probe_line(stdout)
      Timeout.timeout(10) { stdout.gets }
    end

    def release_lifecycle_lock(lock)
      return unless lock && !lock.closed?

      lock.flock(File::LOCK_UN)
      lock.close
    end

    def terminate_probe(thread)
      return unless thread&.alive?

      Process.kill("TERM", thread.pid)
      thread.join(2)
    end
  end

  class SelfCoverageMinitestLockTest < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)
    TEST_HELPER = File.join(ROOT, "test", "test_helper.rb")
    PROBE_ENVIRONMENT = { "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"), "COVERAGE" => "1" }.freeze
    LOCK_PROBE = <<~'RUBY'
      lock = File.open(ARGV.fetch(0), File::RDWR | File::CREAT, 0o644)
      exit(lock.flock(File::LOCK_EX | File::LOCK_NB) ? 0 : 1)
    RUBY
    MINITEST_PROBE = <<~'RUBY'
      require "minitest/autorun"
      require "rbconfig"

      lifecycle_log = ARGV.fetch(1)
      lock_path = ARGV.fetch(2)
      lock_available = proc { system(RbConfig.ruby, "-e", ARGV.fetch(3), lock_path) }
      record = proc { |event| File.open(lifecycle_log, "a") { _1.puts(event) } }

      Minitest.after_run do
        record.call(lock_available.call ? "released after format" : "locked after release")
      end

      require ARGV.fetch(0)
      formatter = Class.new do
        define_method(:format) do |_result|
          record.call(lock_available.call ? "unlocked during format" : "locked during format")
        end
      end
      SimpleCov.formatters [formatter]
    RUBY

    def test_preloaded_minitest_holds_lock_through_formatting_then_releases_it
      Dir.mktmpdir do |dir|
        lifecycle_log = File.join(dir, "coverage-lifecycle.log")
        lock_path = File.join(dir, "coverage", ".quality_gate.lock")
        stdout, stderr, status = run_minitest_probe(dir, lifecycle_log, lock_path)

        assert_predicate status, :success?, "stdout: #{stdout}\nstderr: #{stderr}"
        assert_equal ["locked during format\n", "released after format\n"], File.readlines(lifecycle_log)
      end
    end

    private

    def run_minitest_probe(dir, lifecycle_log, lock_path)
      arguments = [
        RbConfig.ruby, "-rbundler/setup", "-e",
        MINITEST_PROBE,
        TEST_HELPER, lifecycle_log, lock_path, LOCK_PROBE
      ]
      Open3.capture3(PROBE_ENVIRONMENT, *arguments, chdir: dir)
    end
  end
end
