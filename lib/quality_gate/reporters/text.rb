# frozen_string_literal: true

module QualityGate
  module Reporters
    # Writes line-oriented reports for humans.
    class Text
      def initialize(io:)
        @io = io
      end

      def call(result)
        print_checks(result.checks)

        result.findings.each do |finding|
          io.puts(render_finding(finding))
        end

        io.puts("#{result.findings.length} findings, #{result.failed_tools.length} tool failures")
      end

      private

      attr_reader :io

      def print_checks(checks)
        return if checks.empty?

        checks.each { |check| io.puts(render_check(check)) }
      end

      def render_check(check)
        format(
          "%<tool>-12s %<status>-12s %<scope>-18s %<duration>8dms",
          tool: FieldSanitizer.for_text(check[:tool]),
          status: FieldSanitizer.for_text(check[:status]),
          scope: FieldSanitizer.for_text(check[:scope]),
          duration: duration_ms_for(check)
        )
      end

      def duration_ms_for(check)
        Integer(check[:duration_ms], exception: false) || 0
      end

      def render_finding(finding)
        lines = FieldSanitizer.for_text_message(finding.message).split("\n", -1)
        ["#{finding_prefix(finding)} #{lines.first}", *lines.drop(1).map { "  #{_1}" }].join("\n")
      end

      def finding_prefix(finding)
        [
          FieldSanitizer.for_text(finding.tool),
          FieldSanitizer.for_text(finding.severity.to_s),
          finding_location(finding),
          FieldSanitizer.for_text(finding.rule)
        ].compact.join(" ")
      end

      def finding_location(finding)
        file = FieldSanitizer.for_text(finding.file)
        return if file.empty?

        finding.line.zero? ? file : "#{file}:#{finding.line}"
      end
    end
  end
end
