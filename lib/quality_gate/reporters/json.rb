# frozen_string_literal: true

require "json"

module QualityGate
  module Reporters
    # Writes machine-readable reports as one JSON object per run.
    class Json
      def initialize(io:)
        @io = io
      end

      def call(result)
        io.puts(::JSON.generate(payload_for(result)))
      end

      private

      attr_reader :io

      def payload_for(result)
        {
          "checks" => result.checks.map { serialize_check(_1) },
          "findings" => result.findings.map { serialize_finding(_1) },
          "summary" => {
            "findings" => result.findings.length,
            "tool_failures" => result.failed_tools.length,
            "failed_tools" => result.failed_tools.map { FieldSanitizer.for_json(_1) }
          }
        }
      end

      def serialize_finding(finding)
        {
          "tool" => FieldSanitizer.for_json(finding.tool),
          "file" => FieldSanitizer.for_json(finding.file),
          "line" => finding.line,
          "rule" => FieldSanitizer.for_json(finding.rule),
          "severity" => FieldSanitizer.for_json(finding.severity.to_s),
          "message" => FieldSanitizer.for_json(finding.message)
        }
      end

      def serialize_check(check)
        {
          "tool" => FieldSanitizer.for_json(check_value(check, :tool)),
          "status" => FieldSanitizer.for_json(check_value(check, :status)),
          "scope" => FieldSanitizer.for_json(check_value(check, :scope)),
          "requested_files" => check_value(check, :requested_files).map { FieldSanitizer.for_json(_1) },
          "duration_ms" => check_value(check, :duration_ms)
        }
      end

      def check_value(check, key)
        check.fetch(key) { check.fetch(key.to_s) }
      end
    end
  end
end
