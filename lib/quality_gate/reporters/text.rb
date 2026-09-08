# frozen_string_literal: true

module QualityGate
  module Reporters
    # Writes line-oriented reports for humans.
    class Text
      def initialize(io:)
        @io = io
      end

      def call(result)
        result.findings.each do |finding|
          io.puts(render_finding(finding))
        end

        io.puts("#{result.findings.length} findings, #{result.failed_tools.length} tool failures")
      end

      private

      attr_reader :io

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
