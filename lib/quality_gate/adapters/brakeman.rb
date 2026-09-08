# frozen_string_literal: true

require "json"

module QualityGate
  module Adapters
    # Runs Brakeman across the application and normalizes its JSON report.
    class Brakeman < Adapter
      class InvalidReport < StandardError; end
      private_constant :InvalidReport

      CONFIDENCE_MAP = {
        "High" => :error,
        "Medium" => :warning,
        "Weak" => :info
      }.freeze

      def call
        tool = name
        stderr = +""
        stdout, stderr, status = capture(validated_command, resolved_timeout(tool))
        findings = parse(stdout)
        validate_findings!(findings, expected_tool: tool)
        validate_cli_result!(status, findings)
        findings
      rescue StandardError => e
        [failure_finding(tool, e, stderr)]
      end

      def name = "brakeman"

      def command = ["brakeman", "-f", "json", "-q", "--no-pager"]

      def parse(stdout)
        report = parse_report(stdout)
        warnings = report.fetch("warnings") { invalid_report!("report must include warnings") }
        errors = report.fetch("errors") { invalid_report!("report must include errors") }
        validate_errors!(errors)
        parse_warnings(warnings)
      rescue JSON::ParserError, InvalidReport => e
        fail ParseError.new(tool: name, reason: e.message) # rubocop:disable Style/SignalException
      end

      private

      def parse_report(stdout)
        report = JSON.parse(stdout)
        invalid_report!("report must be a JSON object") unless report.is_a?(Hash)

        report
      end

      def parse_warnings(entries)
        invalid_report!("warnings must be an array") unless entries.is_a?(Array)

        entries.map { build_finding(_1) }
      end

      def validate_errors!(errors)
        invalid_report!("errors must be an array") unless errors.is_a?(Array)
        invalid_report!("report contains scan errors") unless errors.empty?
      end

      def validate_cli_result!(status, findings)
        cli_contract_error!("Brakeman did not exit normally") unless status&.exited?

        exitstatus = status.exitstatus
        return if exitstatus.zero?
        return if exitstatus == 3 && findings.any?

        if exitstatus == 3
          cli_contract_error!("Brakeman exit status 3 disagrees with its warning count")
        else
          cli_contract_error!("Brakeman exited with unsupported status #{exitstatus.inspect}")
        end
      end

      def cli_contract_error!(reason)
        fail ParseError.new(tool: name, reason:) # rubocop:disable Style/SignalException
      end

      def build_finding(warning)
        invalid_report!("warning must be an object") unless warning.is_a?(Hash)

        Finding.new(tool: name, **finding_attributes(warning))
      end

      def finding_attributes(warning)
        line = warning_field(warning, "line")
        confidence = string_field(warning, "confidence")

        {
          file: string_field(warning, "file"),
          line: validated_line(line),
          rule: string_field(warning, "warning_type"),
          severity: CONFIDENCE_MAP.fetch(confidence) { invalid_report!("unknown confidence #{confidence.inspect}") },
          message: string_field(warning, "message")
        }
      end

      def warning_field(warning, field)
        warning.fetch(field) { invalid_report!("warning must include #{field}") }
      end

      def string_field(warning, field)
        value = warning_field(warning, field)
        invalid_report!("#{field} must be a String") unless value.is_a?(String)

        value
      end

      def validated_line(line)
        return 0 if line.nil?

        invalid_report!("line must be a non-negative Integer") unless line.is_a?(Integer) && line >= 0

        line
      end

      def invalid_report!(reason)
        raise InvalidReport, reason
      end
    end
  end
end
