# frozen_string_literal: true

require "json"

module QualityGate
  module Adapters
    # Evaluates the most recent SimpleCov summary against configured budgets.
    class SimpleCov < Adapter
      COVERAGE_PATH = "coverage/.last_run.json"

      class InvalidRecord < StandardError; end
      private_constant :InvalidRecord

      def name = "simplecov"

      def call
        result = result_from_record
        findings = line_findings(result)
        findings.concat(branch_findings(result))
        validate_findings!(findings, expected_tool: name)
        findings
      rescue JSON::ParserError, SystemCallError, InvalidRecord
        [simplecov_wiring_failure]
      end

      private

      def result_from_record
        record = JSON.parse(File.read(COVERAGE_PATH))
        invalid_record! unless record.is_a?(Hash)
        result = record["result"]
        invalid_record! unless result.is_a?(Hash)
        percentage(result["line"])

        result
      end

      def line_findings(result)
        minimum = coverage.fetch(:minimum_line, nil)
        return [] unless minimum

        budget_finding("line", percentage(result["line"]), minimum)
      end

      def branch_findings(result)
        minimum = coverage.fetch(:minimum_branch, nil)
        return [] unless minimum

        actual = result["branch"]
        return [branch_wiring_failure] unless valid_percentage?(actual)

        budget_finding("branch", actual, minimum)
      end

      def budget_finding(kind, actual, minimum)
        return [] unless actual < minimum

        [
          Finding.new(
            tool: name, file: "", line: 0,
            severity: :error,
            rule: "#{kind}_coverage_below_minimum",
            message: "#{kind} coverage #{actual}% is below configured minimum #{minimum}%"
          )
        ]
      end

      def coverage
        config.fetch(:coverage)
      end

      def percentage(value)
        invalid_record! unless valid_percentage?(value)

        value
      end

      def valid_percentage?(value)
        value.is_a?(Numeric) && value.finite? && value.between?(0, 100)
      end

      def invalid_record!
        raise InvalidRecord
      end

      def simplecov_wiring_failure
        Finding.tool_failure(
          tool: name,
          message: "#{COVERAGE_PATH} is missing or unusable; require \"simplecov\" and call " \
                   "SimpleCov.start before loading application code"
        )
      end

      def branch_wiring_failure
        Finding.tool_failure(
          tool: name,
          message: "#{COVERAGE_PATH} has no usable branch percentage; add " \
                   "enable_coverage :branch inside SimpleCov.start"
        )
      end
    end
  end
end
