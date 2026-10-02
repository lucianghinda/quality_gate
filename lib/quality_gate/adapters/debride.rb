# frozen_string_literal: true

require_relative "debride_report"

module QualityGate
  module Adapters
    # Runs Debride project-wide and reports possible unused methods as warnings.
    class Debride < Adapter
      DEFAULT_LAUNCHER = ["debride"].freeze
      private_constant :DEFAULT_LAUNCHER

      def name = "debride"

      def command
        launcher = config.fetch(:commands).fetch(:deep, {}).fetch(:debride, DEFAULT_LAUNCHER)
        launcher.dup.concat(["--json", "."])
      end

      def call = run_safely(name)

      def parse(stdout)
        DebrideReport.new(stdout).findings
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError => e
        raise ParseError.new(tool: name, reason: e.message)
      end

      private

      def run_safely(tool)
        stderr = +""
        execute { stderr = _1 }
      rescue StandardError => e
        [failure_finding(tool, e, stderr)]
      end

      def execute
        stdout, stderr, status = capture(validated_command, resolved_timeout(name))
        yield stderr
        validate_process!(status, stderr)
        normalize(stdout)
      end

      def normalize(stdout)
        findings = parse(stdout)
        validate_findings!(findings, expected_tool: name)
        findings
      end

      def validate_process!(status, stderr)
        validate_successful_exit!(status)
        validate_stderr!(stderr)
      end

      def validate_successful_exit!(status)
        return if status&.exited? && status.exitstatus.zero?

        raise ParseError.new(tool: name, reason: "process did not exit normally with status 0")
      end

      def validate_stderr!(stderr)
        return if stderr.strip.empty?

        raise ParseError.new(tool: name, reason: "process wrote diagnostics to stderr")
      end
    end
  end
end
