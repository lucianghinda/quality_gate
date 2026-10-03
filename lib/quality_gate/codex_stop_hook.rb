# frozen_string_literal: true

require "json"
require "stringio"

module QualityGate
  # Runs the full verification gate at a native Codex Stop boundary.
  class CodexStopHook
    VERIFY_ARGUMENTS = %w[verify --format json].freeze
    STRING_FIELDS = %w[tool file rule severity message].freeze
    private_constant :VERIFY_ARGUMENTS, :STRING_FIELDS

    def initialize(dir:)
      @dir = File.expand_path(dir)
    end

    def call(input)
      return unavailable unless valid_input?(input)

      run_verify(input.fetch("stop_hook_active"))
    rescue StandardError
      unavailable
    end

    private

    attr_reader :dir

    def valid_input?(input)
      input.is_a?(Hash) && input["hook_event_name"] == "Stop" &&
        [true, false].include?(input["stop_hook_active"])
    end

    def run_verify(active)
      stdout = StringIO.new
      status = CLI.run(VERIFY_ARGUMENTS, stdout:, stderr: StringIO.new, dir:)
      respond_to_report(status, parse_report(stdout.string), active)
    end

    def parse_report(output)
      report = JSON.parse(output)
      raise TypeError unless valid_report?(report)

      report
    end

    def valid_report?(report)
      return false unless report.is_a?(Hash) && valid_findings?(report["findings"])

      valid_summary?(report["summary"], report["findings"].length)
    end

    def valid_findings?(findings)
      findings.is_a?(Array) && findings.all? { valid_finding?(_1) }
    end

    def valid_finding?(finding)
      finding.is_a?(Hash) && STRING_FIELDS.all? { finding[_1].is_a?(String) } && finding["line"].is_a?(Integer) &&
        finding["line"] >= 0 && Finding::SEVERITIES.any? { _1.to_s == finding["severity"] } &&
        finding["rule"] != Finding::TOOL_FAILURE_RULE
    end

    def valid_summary?(summary, count)
      return false unless summary.is_a?(Hash)

      findings, failures = summary.values_at("findings", "tool_failures")
      findings.is_a?(Integer) && findings == count && failures.is_a?(Integer) &&
        failures.zero? && summary["failed_tools"] == []
    end

    def respond_to_report(status, report, active)
      findings = report.fetch("findings")
      return {} if status.zero? && findings.empty?
      return unavailable unless status == 1 && findings.any?
      return capped(findings) if active

      { "decision" => "block", "reason" => "Fix these findings before finishing:\n#{format_findings(findings)}" }
    end

    def format_findings(findings)
      findings.map { format_finding(_1) }.join("\n")
    end

    def format_finding(finding)
      file = finding.fetch("file")
      line = finding.fetch("line")
      tool, rule, message = finding.values_at("tool", "rule", "message")
      "#{file}:#{line} [#{tool}/#{rule}] #{message}"
    end

    def capped(findings)
      message = "Quality Gate continuation limit reached; remaining findings:\n#{format_findings(findings)}"
      { "systemMessage" => message }
    end

    def unavailable
      message = "Quality Gate verification unavailable; run " \
        "`bundle exec quality_gate verify --format json` manually."
      { "systemMessage" => message }
    end
  end
end
