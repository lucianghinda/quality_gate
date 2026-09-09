# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module QualityGate
  class ReportersVisibilityTest < Minitest::Test
    def test_field_sanitizer_is_not_part_of_the_public_reporters_constant_surface
      error = assert_raises(NameError) do
        QualityGate::Reporters::FieldSanitizer
      end

      assert_includes error.message, "FieldSanitizer"
    end
  end

  class TextReporterTest < Minitest::Test
    def test_clean_run_prints_only_the_summary_line
      io = StringIO.new
      result = Runner::Result.new(findings: [])

      Reporters::Text.new(io: io).call(result)

      assert_equal "0 findings, 0 tool failures\n", io.string
    end

    def test_findings_are_printed_in_order_before_the_summary
      io = StringIO.new
      result = Runner::Result.new(
        findings: [
          build_finding(tool: "rubocop", file: "lib/a.rb", line: 4, rule: "Layout/First", message: "First message"),
          Finding.tool_failure(tool: "reek", message: "timed out")
        ]
      )

      Reporters::Text.new(io: io).call(result)

      assert_equal [
        "rubocop warning lib/a.rb:4 Layout/First First message",
        "reek error tool_failure timed out",
        "2 findings, 1 tool failures"
      ], io.string.lines(chomp: true)
    end

    def test_text_reporter_preserves_multiline_messages_with_indentation
      io = StringIO.new
      result = Runner::Result.new(
        findings: [
          build_finding(
            tool: "rubocop",
            file: "lib/example.rb",
            line: 7,
            rule: "Layout/LineLength",
            message: "First line\n\e[31mSecond\u2028third"
          )
        ]
      )

      Reporters::Text.new(io: io).call(result)

      assert_equal [
        "rubocop warning lib/example.rb:7 Layout/LineLength First line",
        "  [31mSecond third",
        "1 findings, 0 tool failures"
      ], io.string.lines(chomp: true)
    end

    def test_text_reporter_omits_empty_locations_but_keeps_a_real_file_at_line_zero
      io = StringIO.new
      result = Runner::Result.new(
        findings: [
          build_finding(tool: "bundler_audit", file: "Gemfile.lock", line: 0, rule: "CVE-1", message: "unsafe"),
          Finding.tool_failure(tool: "test_suite", message: "failed")
        ]
      )

      Reporters::Text.new(io: io).call(result)

      assert_equal [
        "bundler_audit warning Gemfile.lock CVE-1 unsafe",
        "test_suite error tool_failure failed",
        "2 findings, 1 tool failures"
      ], io.string.lines(chomp: true)
    end

    def test_checks_are_printed_as_a_table_before_findings_and_the_summary
      io = StringIO.new
      result = Runner::Result.new(
        findings: [],
        checks: [
          { tool: "test_suite", status: "clean", scope: "test_suite", requested_files: [], duration_ms: 189_137 },
          { tool: "undercover", status: "clean", scope: "git_diff", requested_files: [], duration_ms: 619 },
          { tool: "simplecov", status: "clean", scope: "coverage_summary", requested_files: [], duration_ms: 0 }
        ]
      )

      Reporters::Text.new(io: io).call(result)

      assert_equal [
        "test_suite   clean        test_suite           189137ms",
        "undercover   clean        git_diff                619ms",
        "simplecov    clean        coverage_summary          0ms",
        "0 findings, 0 tool failures"
      ], io.string.lines(chomp: true)
    end

    def test_no_checks_table_is_printed_when_checks_are_empty
      io = StringIO.new
      result = Runner::Result.new(findings: [], checks: [])

      Reporters::Text.new(io: io).call(result)

      assert_equal "0 findings, 0 tool failures\n", io.string
    end

    def test_a_non_clean_check_status_is_printed_in_the_table
      io = StringIO.new
      result = Runner::Result.new(
        findings: [Finding.tool_failure(tool: "reek", message: "timed out")],
        checks: [
          { tool: "reek", status: "tool_failure", scope: "selected_files", requested_files: [], duration_ms: 42 }
        ]
      )

      Reporters::Text.new(io: io).call(result)

      assert_equal [
        "reek         tool_failure selected_files           42ms",
        "reek error tool_failure timed out",
        "1 findings, 1 tool failures"
      ], io.string.lines(chomp: true)
    end

    def test_check_fields_are_sanitized_against_terminal_escape_injection
      io = StringIO.new
      result = Runner::Result.new(
        findings: [],
        checks: [
          {
            tool: "rub\e[31mocop",
            status: "clean",
            scope: "selected_files",
            requested_files: [],
            duration_ms: 4
          }
        ]
      )

      Reporters::Text.new(io: io).call(result)

      line = io.string.lines(chomp: true).first
      refute_includes line, "\e"
      assert_includes line, "rub [31mocop"
    end

    def test_check_duration_falls_back_to_zero_for_a_nil_or_non_numeric_value
      io = StringIO.new
      result = Runner::Result.new(
        findings: [],
        checks: [
          { tool: "rubocop", status: "clean", scope: "selected_files", requested_files: [], duration_ms: nil },
          { tool: "reek", status: "clean", scope: "selected_files", requested_files: [], duration_ms: "oops" }
        ]
      )

      Reporters::Text.new(io: io).call(result)

      assert_equal [
        "rubocop      clean        selected_files            0ms",
        "reek         clean        selected_files            0ms",
        "0 findings, 0 tool failures"
      ], io.string.lines(chomp: true)
    end

    def test_text_reporter_scrubs_invalid_utf8_without_mutating_the_finding
      io = StringIO.new
      invalid_tool = "rub\xFFocop".dup.force_encoding(Encoding::UTF_8)
      invalid_message = "bad\xFFmessage".dup.force_encoding(Encoding::UTF_8)
      finding = Finding.new(
        tool: invalid_tool,
        file: "lib/example.rb",
        line: 7,
        rule: "Layout/LineLength",
        severity: :warning,
        message: invalid_message
      )

      Reporters::Text.new(io: io).call(Runner::Result.new(findings: [finding]))

      assert_predicate io.string, :valid_encoding?
      assert_includes io.string, "rub�ocop"
      assert_includes io.string, "bad�message"
      refute_predicate finding.tool, :valid_encoding?
      refute_predicate finding.message, :valid_encoding?
    end
  end

  class JsonReporterTest < Minitest::Test
    def test_json_reporter_adds_check_metadata_without_changing_existing_envelopes
      io = StringIO.new
      result = Runner::Result.new(
        findings: [],
        checks: [
          {
            tool: "rubocop",
            status: "clean",
            scope: "selected_files",
            requested_files: ["lib/example.rb"],
            duration_ms: 4
          },
          {
            tool: "test_suite",
            status: "clean",
            scope: "test_suite",
            requested_files: [],
            duration_ms: 0
          }
        ]
      )

      Reporters::Json.new(io: io).call(result)

      assert_equal [
        {
          "tool" => "rubocop",
          "status" => "clean",
          "scope" => "selected_files",
          "requested_files" => ["lib/example.rb"],
          "duration_ms" => 4
        },
        {
          "tool" => "test_suite",
          "status" => "clean",
          "scope" => "test_suite",
          "requested_files" => [],
          "duration_ms" => 0
        }
      ], JSON.parse(io.string).fetch("checks")
    end

    def test_result_is_written_as_one_json_object_with_summary
      io = StringIO.new
      result = Runner::Result.new(
        findings: [
          build_finding(
            tool: "rubocop",
            file: "lib/a.rb",
            line: 4,
            rule: "Layout/First",
            severity: :warning,
            message: "First message"
          ),
          Finding.tool_failure(tool: "reek", message: "timed out")
        ]
      )

      Reporters::Json.new(io: io).call(result)

      parsed = JSON.parse(io.string)

      assert_equal(
        {
          "checks" => [],
          "findings" => [
            {
              "tool" => "rubocop",
              "file" => "lib/a.rb",
              "line" => 4,
              "rule" => "Layout/First",
              "severity" => "warning",
              "message" => "First message"
            },
            {
              "tool" => "reek",
              "file" => "",
              "line" => 0,
              "rule" => "tool_failure",
              "severity" => "error",
              "message" => "timed out"
            }
          ],
          "summary" => {
            "findings" => 2,
            "tool_failures" => 1,
            "failed_tools" => ["reek"]
          }
        },
        parsed
      )
      assert_equal 1, io.string.lines.length
      assert io.string.end_with?("\n")
    end

    def test_json_reporter_scrubs_invalid_utf8_in_findings_and_failed_tools
      io = StringIO.new
      invalid_tool = "re\xFFek".dup.force_encoding(Encoding::UTF_8)
      invalid_message = "timed\xFFout".dup.force_encoding(Encoding::UTF_8)
      result = Runner::Result.new(
        findings: [Finding.tool_failure(tool: invalid_tool, message: invalid_message)]
      )

      Reporters::Json.new(io: io).call(result)

      parsed = JSON.parse(io.string)

      assert_equal "re�ek", parsed.fetch("findings").fetch(0).fetch("tool")
      assert_equal "timed�out", parsed.fetch("findings").fetch(0).fetch("message")
      assert_equal ["re�ek"], parsed.fetch("summary").fetch("failed_tools")
      refute_predicate result.findings.fetch(0).tool, :valid_encoding?
    end

    private

    def build_finding(**attributes)
      Finding.new(
        tool: attributes.fetch(:tool),
        file: attributes.fetch(:file),
        line: attributes.fetch(:line),
        rule: attributes.fetch(:rule),
        severity: attributes.fetch(:severity),
        message: attributes.fetch(:message)
      )
    end
  end

  class TextReporterTest
    private

    def build_finding(tool:, file:, line:, rule:, message:)
      Finding.new(
        tool: tool,
        file: file,
        line: line,
        rule: rule,
        severity: :warning,
        message: message
      )
    end
  end
end
