# frozen_string_literal: true

require "test_helper"

module QualityGate
  class FindingTest < Minitest::Test
    def test_builds_an_immutable_finding_with_all_fields
      finding = build_finding

      assert_equal "rubocop", finding.tool
      assert_equal "lib/quality_gate/finding.rb", finding.file
      assert_equal 12, finding.line
      assert_equal "Layout/LineLength", finding.rule
      assert_equal :warning, finding.severity
      assert_equal "Line is too long", finding.message
      assert_raises(NoMethodError) { finding.tool = "reek" }
    end

    def test_construction_copies_input_strings
      attributes = mutable_string_attributes
      finding = Finding.new(**finding_attributes(attributes))

      mutate_string_attributes(attributes)

      assert_string_fields(finding, expected_string_fields)
    end

    def test_string_members_are_frozen
      finding = Finding.new(**finding_attributes(mutable_string_attributes))

      string_replacements.each do |member, replacement|
        assert_raises(FrozenError) { finding.public_send(member).replace(replacement) }
      end
    end

    def test_with_copies_and_freezes_replacement_strings
      source = String.new("Updated elsewhere")
      finding = build_finding.with(message: source)

      source.replace("Mutated after with")

      assert_equal "Updated elsewhere", finding.message
      assert_raises(FrozenError) { finding.message.replace("Changed again") }
    end

    def test_constants_are_exact_and_frozen
      assert_equal %i[error warning info], Finding::SEVERITIES
      assert Finding::SEVERITIES.frozen?
      assert_equal "tool_failure", Finding::TOOL_FAILURE_RULE
      assert Finding::TOOL_FAILURE_RULE.frozen?
    end

    def test_tool_failure_builds_the_expected_synthetic_finding
      finding = Finding.tool_failure(tool: "brakeman", message: "command failed")

      assert_equal "brakeman", finding.tool
      assert_equal "", finding.file
      assert_equal 0, finding.line
      assert_equal Finding::TOOL_FAILURE_RULE, finding.rule
      assert_equal :error, finding.severity
      assert_equal "command failed", finding.message
      assert finding.tool_failure?
    end

    def test_non_tool_failures_report_false
      finding = Finding.new(
        tool: "rubocop",
        file: "lib/quality_gate/finding.rb",
        line: 8,
        rule: "Style/FrozenStringLiteralComment",
        severity: :info,
        message: "Missing frozen string literal comment"
      )

      refute finding.tool_failure?
    end

    def test_unknown_runtime_severity_is_not_rejected
      finding = Finding.new(
        tool: "rubocop",
        file: "lib/quality_gate/finding.rb",
        line: 12,
        rule: "Layout/LineLength",
        severity: :fatal,
        message: "Line is too long"
      )

      assert_equal :fatal, finding.severity
    end

    def test_non_string_fields_are_rejected
      bad_fields = {
        tool: :rubocop,
        file: Object.new,
        rule: :layout,
        message: ["Line is too long"]
      }

      bad_fields.each do |member, value|
        error = assert_raises(TypeError) do
          Finding.new(**finding_attributes(expected_string_fields).merge(member => value))
        end

        assert_includes error.message, member.to_s
      end
    end

    def test_non_integer_lines_are_rejected
      [12.5, "12"].each do |line|
        error = assert_raises(TypeError) do
          Finding.new(**finding_attributes(expected_string_fields).merge(line:))
        end

        assert_includes error.message, "line"
      end
    end

    def test_negative_lines_are_rejected
      error = assert_raises(ArgumentError) do
        Finding.new(**finding_attributes(expected_string_fields).merge(line: -1))
      end

      assert_includes error.message, "line"
    end

    def test_tool_failure_line_zero_is_allowed
      finding = Finding.tool_failure(tool: "brakeman", message: "command failed")

      assert_equal 0, finding.line
    end

    def test_multiline_message_is_preserved
      message = "first line\nsecond line"
      finding = Finding.new(**finding_attributes(expected_string_fields).merge(message:))

      assert_equal message, finding.message
    end

    private

    def build_finding = Finding.new(**finding_attributes(expected_string_fields))

    def expected_string_fields = {
      tool: "rubocop",
      file: "lib/quality_gate/finding.rb",
      rule: "Layout/LineLength",
      message: "Line is too long"
    }

    def finding_attributes(string_attributes) = string_attributes.merge(line: 12, severity: :warning)

    def mutable_string_attributes = expected_string_fields.transform_values { String.new(_1) }

    def mutate_string_attributes(attributes)
      string_replacements.each do |member, replacement|
        attributes.fetch(member).replace(replacement)
      end
    end

    def assert_string_fields(finding, expected_fields)
      expected_fields.each do |member, value|
        assert_equal value, finding.public_send(member)
      end
    end

    def string_replacements = {
      tool: "reek",
      file: "lib/quality_gate/other.rb",
      rule: "Lint/UselessAssignment",
      message: "Changed elsewhere"
    }
  end
end
