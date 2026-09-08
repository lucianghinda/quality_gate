# frozen_string_literal: true

require "rbconfig"
require "securerandom"
require "test_helper"
require_relative "../../../lib/quality_gate/adapters/test_suite"

module QualityGate
  module Adapters
    class TestSuiteTest < Minitest::Test
      def test_name_and_tail_line_contract
        assert_equal "test_suite", build_adapter.name
        assert_equal 20, TestSuite::TAIL_LINES
        assert_predicate TestSuite::TAIL_LINES, :frozen?
      end

      def test_default_command_runs_the_whole_suite_and_ignores_files
        adapter = build_adapter(files: ["test/models/user_test.rb"])

        assert_equal %w[bin/rails test], adapter.command
      end

      def test_command_uses_the_configured_argv
        configured_command = ruby_command("exit 0")
        adapter = build_adapter(config: config_with_command(configured_command))

        assert_equal configured_command, adapter.command
      end

      def test_env_enables_coverage
        assert_equal({ "COVERAGE" => "1" }, build_adapter.env)
      end

      def test_passing_suite_returns_no_findings_and_preserves_host_environment
        host_key = "QUALITY_GATE_TEST_SUITE_HOST_#{SecureRandom.hex(6)}"
        previous_host = ENV[host_key]
        previous_coverage = ENV["COVERAGE"]
        ENV[host_key] = "preserved"
        ENV["COVERAGE"] = "disabled"
        command = ruby_command(<<~RUBY, host_key)
          exit 1 unless ENV.fetch(ARGV.fetch(0)) == "preserved"
          exit 1 unless ENV.fetch("COVERAGE") == "1"
        RUBY

        assert_equal [], build_adapter(config: config_with_command(command)).call
      ensure
        ENV[host_key] = previous_host if host_key
        ENV["COVERAGE"] = previous_coverage
      end

      def test_failing_suite_returns_one_finding_with_only_the_last_twenty_output_lines
        with_temp_project do
          command = ruby_command(<<~RUBY)
            $stdout.sync = true
            30.times { |index| puts format("stdout-%02d", index + 1) }
            warn "stderr-last"
            exit 1
          RUBY
          adapter = build_adapter(config: config_with_command(command))

          findings = adapter.call

          assert_equal 1, findings.length
          finding = findings.first
          tail, log_path = finding.message.split("\nFull test output: ", 2)
          expected_output = ((1..30).map { format("stdout-%02d", _1) } + ["stderr-last"]).join("\n")
          assert_equal ((12..30).map { format("stdout-%02d", _1) } + ["stderr-last"]).join("\n"), tail
          assert_match(%r{\Alog/quality_gate/test-suite-[^/]+\.log\z}, log_path)
          assert_equal "#{expected_output}\n", File.read(log_path)
          refute_includes tail, "stdout-11"
        end
      end

      def test_failed_suites_get_unique_retained_logs
        with_temp_project do
          paths = concurrent_failed_findings.map { |finding| retained_log_path(finding) }

          assert_equal 2, paths.uniq.length
          assert_equal %w[first second], paths.map { |path| File.read(path).strip }.sort
          assert_equal [0o600, 0o600], paths.map { |path| File.stat(path).mode & 0o777 }.sort
        end
      end

      def test_passing_suite_does_not_create_a_retained_log
        with_temp_project do
          command = ruby_command("exit 0")

          assert_empty build_adapter(config: config_with_command(command)).call
          refute Dir.exist?("log/quality_gate")
        end
      end

      def test_log_write_failure_preserves_test_failure_tail_and_reports_diagnostic
        with_temp_project do
          File.write("log", "a file blocks the log directory")
          command = ruby_command('puts "failure detail"; exit 1')

          finding = build_adapter(config: config_with_command(command)).call.fetch(0)

          refute finding.tool_failure?
          assert_equal "test_failure", finding.rule
          assert_includes finding.message, "failure detail"
          assert_includes finding.message, "Could not write full test output log"
        end
      end

      def test_command_launcher_is_not_reported_as_a_failure_location
        with_temp_project do
          command = ["bundle", "exec", *ruby_command('warn "suite failed"; exit 1')]

          finding = build_adapter(config: config_with_command(command)).call.fetch(0)

          assert_equal "test_failure", finding.rule
          assert_equal "", finding.file
          assert_equal 0, finding.line
          assert_includes finding.message, "suite failed"
        end
      end

      def test_failure_tail_preserves_stdout_and_stderr_emission_order_and_stream_boundaries
        with_temp_project do
          command = ruby_command(<<~RUBY)
            $stdout.sync = true
            $stderr.sync = true
            1.upto(22) do |number|
              stream = number.odd? ? $stdout : $stderr
              stream.puts format("line-%02d", number)
            end
            $stdout.write "joined-"
            $stderr.write "boundary\n"
            $stdout.puts "line-24"
            exit 1
          RUBY
          adapter = build_adapter(config: config_with_command(command))

          finding = adapter.call.fetch(0)

          expected_lines = (5..22).map { format("line-%02d", _1) } + %w[joined-boundary line-24]
          assert_includes finding.message, expected_lines.join("\n")
        end
      end

      def test_missing_test_program_uses_the_standard_tool_failure
        command = ["missing-test-program-#{SecureRandom.hex(6)}"]

        findings = build_adapter(config: config_with_command(command)).call

        assert_equal 1, findings.length
        assert findings.first.tool_failure?
        assert_equal "test_suite", findings.first.tool
      end

      private

      def build_adapter(config: Config.new(Config.defaults), files: [])
        TestSuite.new(config:, files:)
      end

      def config_with_command(command)
        commands = Config.defaults.fetch(:commands).merge(verify: { test_suite: command })
        Config.new(Config.defaults.merge(commands:))
      end

      def ruby_command(script, *args)
        [RbConfig.ruby, "-e", script, *args]
      end

      def concurrent_failed_findings
        adapters = %w[first second].map do |label|
          command = ruby_command("puts ARGV.fetch(0); exit 1", label)
          build_adapter(config: config_with_command(command))
        end
        adapters.map { |adapter| Thread.new { adapter.call.fetch(0) } }.map(&:value)
      end

      def retained_log_path(finding)
        finding.message.split("\nFull test output: ", 2).fetch(1)
      end

      def with_temp_project(&block)
        Dir.mktmpdir do |dir|
          Dir.chdir(dir, &block)
        end
      end
    end
  end
end
