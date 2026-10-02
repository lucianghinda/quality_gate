# frozen_string_literal: true

require "json"
require "rbconfig"
require "tmpdir"
require "test_helper"
require_relative "../../../lib/quality_gate/adapters/debride"

module QualityGate
  module Adapters
    class DebrideTest < Minitest::Test
      def test_name_and_default_command_are_project_wide
        adapter = build_adapter(files: ["ignored.rb"])

        assert_equal "debride", adapter.name
        assert_equal %w[debride --json .], adapter.command
      end

      def test_command_appends_json_and_project_to_configured_launcher
        adapter = build_adapter(launcher: [RbConfig.ruby, "-e", "exit 0"])

        assert_equal [RbConfig.ruby, "-e", "exit 0", "--json", "."], adapter.command
      end

      def test_parse_returns_no_findings_for_a_clean_report
        assert_empty build_adapter.parse(JSON.generate("missing" => {}))
      end

      def test_parse_builds_warning_findings_for_scoped_and_top_level_candidates
        report = {
          "missing" => {
            "Example::Worker" => [
              ["run", "app/lib:old/worker.rb:12-14"], ["up", "lib/path.rb:5-5"]
            ],
            "main" => [["LEGACY", "lib/app constants.rb:7"]]
          },
          "focus" => ["ignored upstream metadata"]
        }

        assert_equal [
          Finding.new(
            tool: "debride", file: "app/lib:old/worker.rb", line: 12,
            rule: "potentially_unused_method", severity: :warning,
            message: "Example::Worker: run is potentially unused"
          ),
          Finding.new(
            tool: "debride", file: "lib/path.rb", line: 5,
            rule: "potentially_unused_method", severity: :warning,
            message: "Example::Worker: up is potentially unused"
          ),
          Finding.new(
            tool: "debride", file: "lib/app constants.rb", line: 7,
            rule: "potentially_unused_method", severity: :warning,
            message: "main: LEGACY is potentially unused"
          )
        ], build_adapter.parse(JSON.generate(report))
      end

      def test_parse_rejects_invalid_json_and_malformed_reports
        invalid_reports.each do |report|
          assert_raises(ParseError, report) { build_adapter.parse(report) }
        end
      end

      def test_call_accepts_a_candidate_json_producer_with_expected_arguments
        adapter = build_adapter(launcher: ruby_script(<<~RUBY))
          abort "unexpected args: #{ARGV.inspect}" unless ARGV == ["--json", "."]
          print JSON.generate("missing" => { "Example" => [["run", "lib/example.rb:4-5"]] })
          warn "  \t"
        RUBY

        assert_equal "Example: run is potentially unused", adapter.call.fetch(0).message
      end

      def test_call_rejects_successful_json_with_stderr_diagnostics
        adapter = build_adapter(launcher: ruby_script(<<~RUBY))
          print JSON.generate("missing" => {})
          warn "warning: skipped a source file"
        RUBY

        finding = adapter.call.fetch(0)

        assert finding.tool_failure?
        assert_includes finding.message, "warning: skipped a source file"
      end

      def test_call_rejects_malformed_json_and_retains_stderr
        adapter = build_adapter(launcher: ruby_script(<<~RUBY))
          puts "not json"
          warn "producer diagnostic"
        RUBY

        finding = adapter.call.fetch(0)

        assert finding.tool_failure?
        assert_includes finding.message, "producer diagnostic"
      end

      def test_call_rejects_nonzero_status_even_with_valid_json
        adapter = build_adapter(launcher: ruby_script(<<~RUBY))
          print JSON.generate("missing" => {})
          warn "Debride failed"
          exit 2
        RUBY

        finding = adapter.call.fetch(0)

        assert finding.tool_failure?
        assert_includes finding.message, "Debride failed"
      end

      def test_call_rejects_signaled_process
        adapter = build_adapter(launcher: ruby_script(<<~RUBY))
          print JSON.generate("missing" => {})
          Process.kill("TERM", Process.pid)
        RUBY

        assert adapter.call.fetch(0).tool_failure?
      end

      def test_call_rejects_missing_process_status
        adapter = build_adapter
        adapter.define_singleton_method(:capture) { |_argv, _timeout| [JSON.generate("missing" => {}), "", nil] }

        finding = adapter.call.fetch(0)

        assert finding.tool_failure?
        assert_includes finding.message, "status 0"
      end

      def test_call_reports_a_missing_executable
        adapter = build_adapter(launcher: ["/missing/debride-executable"])

        assert adapter.call.fetch(0).tool_failure?
      end

      def test_call_reports_a_timed_out_process
        adapter = build_adapter(launcher: ruby_script("sleep 3"), timeout: 1)

        finding = adapter.call.fetch(0)

        assert finding.tool_failure?
        assert_includes finding.message, "timeout"
      end

      def test_timeout_uses_per_tool_override_before_default
        assert_equal 9, build_adapter(timeout: 9).timeout
      end

      def test_timeout_uses_default_when_no_tool_override_exists
        config = Config.new(Config.defaults.merge(timeouts: { default: 9 }))

        assert_equal 9, Debride.new(config:).timeout
      end

      private

      def invalid_reports
        [
          "[",
          JSON.generate([]),
          JSON.generate({}),
          JSON.generate("missing" => []),
          JSON.generate("missing" => { "" => [] }),
          JSON.generate("missing" => { "Example" => {} }),
          JSON.generate("missing" => { "Example" => ["bad"] }),
          JSON.generate("missing" => { "Example" => [["run"]] }),
          JSON.generate("missing" => { "Example" => [["", "file.rb:1"]] }),
          JSON.generate("missing" => { "Example" => [["run", "file.rb:1"], ["bad", "file.rb:0"]] }),
          JSON.generate("missing" => { "Example" => [["run", "file.rb:4-2"]] }),
          JSON.generate("missing" => { "Example" => [["run", "file.rb:1-two"]] }),
          JSON.generate("missing" => { "Example" => [["run", ":1"]] })
        ]
      end

      def build_adapter(launcher: nil, files: [], timeout: 5)
        commands = Config.defaults.fetch(:commands).merge(deep: { debride: launcher }.compact)
        timeouts = Config.defaults.fetch(:timeouts).merge(default: 3, debride: timeout)
        config = Config.new(Config.defaults.merge(commands:, timeouts:))
        Debride.new(config:, files:)
      end

      def ruby_script(source)
        [RbConfig.ruby, "-e", "require 'json'; #{source}", "--"]
      end
    end
  end
end
