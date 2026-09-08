# frozen_string_literal: true

require "json"
require "test_helper"

module QualityGate
  module Adapters
    class BrakemanTest < Minitest::Test
      ROOT = File.expand_path("../../..", __dir__)
      FIXTURES = File.join(ROOT, "test", "fixtures", "brakeman")

      class CapturedBrakeman < Brakeman
        def initialize(stdout:, status:, stderr: "", **keywords)
          super(**keywords)
          @captured_result = [stdout, stderr, status]
        end

        private

        def capture(_argv, _timeout_seconds)
          @captured_result
        end
      end

      def test_load_wiring
        assert defined?(QualityGate::Adapters::Brakeman), "expected QualityGate::Adapters::Brakeman to be loaded"
      end

      def test_name
        assert_equal "brakeman", build_adapter.name
      end

      def test_command_scans_the_whole_application_and_ignores_files
        command = build_adapter(files: ["app/models/user.rb"]).command

        assert_equal ["brakeman", "-f", "json", "-q", "--no-pager"], command
      end

      def test_confidence_map_is_public_and_frozen
        expected = { "High" => :error, "Medium" => :warning, "Weak" => :info }
        actual = QualityGate::Adapters::Brakeman.const_get(:CONFIDENCE_MAP, false)

        assert_equal expected, actual
        assert_predicate actual, :frozen?
      end

      def test_parse_turns_recorded_warnings_into_findings_in_report_order
        findings = build_adapter.parse(fixture("warnings_report.json"))

        assert_equal expected_findings, findings
      end

      def test_parse_returns_empty_for_a_clean_report
        assert_equal [], build_adapter.parse(JSON.dump(clean_report))
      end

      def test_parse_raises_parse_error_for_invalid_json
        error = assert_raises(ParseError) { build_adapter.parse("{") }

        assert_equal "brakeman", error.tool
      end

      def test_parse_raises_parse_error_for_invalid_report_shapes
        invalid_reports = {
          "report not object" => [],
          "missing warnings" => {},
          "warnings not array" => { "warnings" => {}, "errors" => [] },
          "missing errors" => { "warnings" => [] },
          "errors not array" => { "warnings" => [], "errors" => {} },
          "nonempty errors" => { "warnings" => [], "errors" => [{ "error" => "scan failed" }] },
          "warning not object" => { "warnings" => ["bad"], "errors" => [] },
          "missing file" => report_with(warning_without("file")),
          "file not string" => report_with(valid_warning.merge("file" => 7)),
          "missing line" => report_with(warning_without("line")),
          "line not integer" => report_with(valid_warning.merge("line" => "14")),
          "line false" => report_with(valid_warning.merge("line" => false)),
          "line negative" => report_with(valid_warning.merge("line" => -1)),
          "missing warning type" => report_with(warning_without("warning_type")),
          "warning type not string" => report_with(valid_warning.merge("warning_type" => 7)),
          "missing confidence" => report_with(warning_without("confidence")),
          "unknown confidence" => report_with(valid_warning.merge("confidence" => "Certain")),
          "missing message" => report_with(warning_without("message")),
          "message not string" => report_with(valid_warning.merge("message" => 7))
        }

        invalid_reports.each do |description, report|
          assert_raises(ParseError, description) { build_adapter.parse(JSON.dump(report)) }
        end
      end

      def test_parse_does_not_hide_adapter_programming_errors
        adapter = build_adapter
        adapter.define_singleton_method(:parse_warnings) { |_warnings| raise "adapter bug" }

        error = assert_raises(RuntimeError) { adapter.parse('{"warnings":[],"errors":[]}') }

        assert_equal "adapter bug", error.message
      end

      def test_parse_does_not_hide_type_errors_from_parser_collaborators
        adapter = build_adapter
        adapter.define_singleton_method(:parse_warnings) { |_warnings| raise TypeError, "adapter type bug" }

        error = assert_raises(TypeError) { adapter.parse('{"warnings":[],"errors":[]}') }

        assert_equal "adapter type bug", error.message
      end

      def test_parse_does_not_hide_argument_errors_from_parser_collaborators
        adapter = build_adapter
        adapter.define_singleton_method(:parse_warnings) { |_warnings| raise ArgumentError, "adapter argument bug" }

        error = assert_raises(ArgumentError) { adapter.parse('{"warnings":[],"errors":[]}') }

        assert_equal "adapter argument bug", error.message
      end

      def test_call_accepts_a_clean_report_with_exit_zero
        assert_equal [], captured_adapter(report: clean_report, exitstatus: 0).call
      end

      def test_call_accepts_warnings_with_exit_zero
        findings = captured_adapter(report: warning_report, exitstatus: 0).call

        assert_ordinary_warning(findings)
      end

      def test_call_accepts_warnings_with_exit_three
        findings = captured_adapter(report: warning_report, exitstatus: 3).call

        assert_ordinary_warning(findings)
      end

      def test_call_rejects_a_clean_report_with_exit_three
        findings = captured_adapter(report: clean_report, exitstatus: 3).call

        assert_one_tool_failure(findings, message: "disagrees with its warning count")
      end

      def test_call_rejects_supported_reports_with_unsupported_exit_four
        [clean_report, warning_report].each do |report|
          findings = captured_adapter(report:, exitstatus: 4).call

          assert_one_tool_failure(findings, message: "unsupported status 4")
        end
      end

      def test_call_rejects_a_signalled_process
        findings = captured_adapter(report: clean_report, exitstatus: nil, exited: false).call

        assert_one_tool_failure(findings, message: "did not exit normally")
      end

      def test_call_rejects_a_report_missing_errors
        findings = captured_adapter(report: { "warnings" => [] }, exitstatus: 0).call

        assert_one_tool_failure(findings, message: "report must include errors")
      end

      def test_call_rejects_a_report_with_non_array_errors
        report = { "warnings" => [], "errors" => {} }

        findings = captured_adapter(report:, exitstatus: 0).call

        assert_one_tool_failure(findings, message: "errors must be an array")
      end

      def test_call_rejects_scan_errors_with_exit_seven
        findings = captured_adapter(report: error_report, exitstatus: 7).call

        assert_one_tool_failure(findings, message: "report contains scan errors")
      end

      def test_call_rejects_a_clean_report_with_exit_seven
        findings = captured_adapter(report: clean_report, exitstatus: 7).call

        assert_one_tool_failure(findings, message: "unsupported status 7")
      end

      def test_runner_reports_scan_errors_as_a_failed_brakeman_tool
        config = Config.new(Config.defaults)
        adapter = captured_adapter(report: error_report, exitstatus: 7, config:)

        result = Runner.new(adapters: [adapter], config:).call

        assert_equal ["brakeman"], result.failed_tools
        assert_equal ExitCode::TOOL_FAILURE, result.exit_code
        assert_equal 1, result.findings.length
        assert_predicate result.findings.first, :tool_failure?
      end

      private

      def build_adapter(files: [])
        QualityGate::Adapters::Brakeman.new(config: Config.new(Config.defaults), files:)
      end

      def captured_adapter(report:, exitstatus:, exited: true, config: Config.new(Config.defaults))
        status = Object.new.tap do |value|
          value.define_singleton_method(:exited?) { exited }
          value.define_singleton_method(:exitstatus) { exitstatus }
        end
        CapturedBrakeman.new(stdout: JSON.generate(report), status:, config:)
      end

      def expected_findings
        [
          Finding.new(
            tool: "brakeman",
            file: "app/controllers/users_controller.rb",
            line: 14,
            rule: "SQL Injection",
            severity: :error,
            message: %q{Possible SQL injection near line 14: User.where("name = '#{params[:name]}'")}
          ),
          Finding.new(
            tool: "brakeman",
            file: "app/views/users/show.html.erb",
            line: 8,
            rule: "Cross-Site Scripting",
            severity: :warning,
            message: "Unescaped parameter value"
          ),
          Finding.new(
            tool: "brakeman",
            file: "app/views/users/show.html.erb",
            line: 0,
            rule: "Cross-Site Scripting",
            severity: :info,
            message: "Parameter value rendered with limited context"
          )
        ]
      end

      def fixture(name)
        File.read(File.join(FIXTURES, name))
      end

      def report_with(warning)
        { "warnings" => [warning], "errors" => [] }
      end

      def clean_report = { "warnings" => [], "errors" => [] }

      def warning_report = report_with(valid_warning)

      def error_report
        { "warnings" => [], "errors" => [{ "error" => "scan failed" }] }
      end

      def warning_without(key)
        valid_warning.tap { _1.delete(key) }
      end

      def valid_warning
        {
          "warning_type" => "SQL Injection",
          "message" => "Possible SQL injection",
          "file" => "app/controllers/users_controller.rb",
          "line" => 14,
          "confidence" => "High"
        }
      end

      def assert_ordinary_warning(findings)
        assert_equal 1, findings.length
        finding = findings.first
        refute_predicate finding, :tool_failure?
        assert_equal "SQL Injection", finding.rule
      end

      def assert_one_tool_failure(findings, message:)
        assert_equal 1, findings.length
        finding = findings.first
        assert_predicate finding, :tool_failure?
        assert_equal "brakeman", finding.tool
        assert_equal :error, finding.severity
        assert_includes finding.message, message
      end
    end
  end
end
