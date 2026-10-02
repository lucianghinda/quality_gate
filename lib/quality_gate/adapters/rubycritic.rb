# frozen_string_literal: true

require "json"
require "tmpdir"
require_relative "rubycritic_report"

module QualityGate
  module Adapters
    # Runs RubyCritic and normalizes its JSON report into warnings.
    class RubyCritic < Adapter
      DEFAULT_LAUNCHER = ["rubycritic"].freeze
      REPRESENTATIVE_REPORT_DIRECTORY = File.join(Dir.tmpdir, "quality-gate-rubycritic-report").freeze
      private_constant :DEFAULT_LAUNCHER, :REPRESENTATIVE_REPORT_DIRECTORY

      def name = "rubycritic"

      def command = command_for(REPRESENTATIVE_REPORT_DIRECTORY)

      def call
        tool = name
        stderr = +""
        findings_in_temp_directory(tool) { stderr = _1 }
      rescue StandardError => e
        [failure_finding(tool, e, stderr)]
      end

      def parse(json)
        RubyCriticReport.new(json).findings
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError => e
        raise ParseError.new(tool: name, reason: e.message)
      end

      private

      def command_for(report_directory)
        launcher = config.fetch(:commands).fetch(:deep, {}).fetch(:rubycritic, DEFAULT_LAUNCHER)
        launcher.dup.concat(
          ["--format", "json", "--no-browser", "--minimum-score", "0", "--path", report_directory, "."]
        )
      end

      def findings_in_temp_directory(tool, &on_stderr)
        Dir.mktmpdir("quality-gate-rubycritic-") do |directory|
          findings_at(directory, tool, &on_stderr)
        end
      end

      def findings_at(directory, tool)
        stderr, status = capture_report(directory, tool)
        yield stderr
        validate_successful_exit!(status)
        parse(read_report(directory, tool))
      end

      def capture_report(directory, tool)
        _stdout, stderr, status = capture(command_for(directory), resolved_timeout(tool))
        [stderr, status]
      end

      def read_report(directory, tool)
        report_path = File.join(directory, "report.json")
        raise ParseError.new(tool:, reason: "report file is missing") unless File.file?(report_path)

        File.read(report_path)
      end

      def validate_successful_exit!(status)
        return if status&.exited? && status.exitstatus.zero?

        raise ParseError.new(tool: name, reason: "process did not exit normally with status 0")
      end
    end
  end
end
