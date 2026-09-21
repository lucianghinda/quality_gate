# frozen_string_literal: true

module QualityGate
  module Reporters
    # Writes Markdown reports that agents and humans can paste into notes and reviews.
    class Markdown
      TABLE_HEADER = ["| Tool | Status | Scope | Duration |", "| --- | --- | --- | --- |"].freeze

      def initialize(io:)
        @io = io
      end

      def call(result)
        io.puts(sections_for(result).join("\n\n"))
      end

      private

      attr_reader :io

      def sections_for(result)
        [summary_heading(result), checks_table(result.checks), findings_section(result.findings)].compact
      end

      def summary_heading(result)
        "## Quality Gate: #{result.findings.length} findings, #{result.failed_tools.length} tool failures"
      end

      def checks_table(checks)
        return if checks.empty?

        [*TABLE_HEADER, *checks.map { render_check(_1) }].join("\n")
      end

      def render_check(check)
        cells = [check[:tool], check[:status], check[:scope]].map { table_cell(_1) }
        "| #{cells.join(" | ")} | #{duration_ms_for(check)}ms |"
      end

      def duration_ms_for(check)
        Integer(check[:duration_ms], exception: false) || 0
      end

      def table_cell(value)
        FieldSanitizer.for_text(value).gsub("|", "\\|")
      end

      def findings_section(findings)
        return if findings.empty?

        ["### Findings", "", *findings.map { render_finding(_1) }].join("\n")
      end

      def render_finding(finding)
        message = FieldSanitizer.for_text_message(finding.message).gsub(/[[:punct:]&&[:ascii:]]/) { "\\#{_1}" }
        lines = message.split("\n", -1)
        ["- #{finding_prefix(finding)}: #{lines.first}", *lines.drop(1).map { "  #{_1}" }].join("\n")
      end

      def finding_prefix(finding)
        tool = "**#{FieldSanitizer.for_text(finding.tool)}**"
        severity = FieldSanitizer.for_text(finding.severity.to_s)
        [tool, severity, finding_location(finding), FieldSanitizer.for_text(finding.rule)].compact.join(" ")
      end

      def finding_location(finding)
        file = FieldSanitizer.for_text(finding.file)
        return if file.empty?

        code_span(finding.line.zero? ? file : "#{file}:#{finding.line}")
      end

      def code_span(text)
        fence = "`" * (longest_backtick_run(text) + 1)
        fence.length == 1 ? "`#{text}`" : "#{fence} #{text} #{fence}"
      end

      def longest_backtick_run(text)
        text.scan(/`+/).map(&:length).max.to_i
      end
    end
  end
end
