# frozen_string_literal: true

require "rbconfig"
require_relative "database_consistency_report"

module QualityGate
  module Adapters
    # Runs the optional project-wide database consistency bridge.
    class DatabaseConsistency < Adapter
      TOOL_NAME = "database_consistency"
      BRIDGE_PATH = File.expand_path("../database_consistency_runner.rb", __dir__).freeze

      def name = TOOL_NAME

      def command
        prefix = config.fetch(:commands).fetch(:audit).fetch(:database_consistency, nil)
        return [RbConfig.ruby, BRIDGE_PATH] unless prefix

        prefix + [BRIDGE_PATH]
      end

      def parse(stdout)
        DatabaseConsistencyReport.new(stdout).findings
      end

      def call = capture_findings

      private

      def capture_findings
        stderr = +""
        execute(stderr).tap { validate_findings!(_1, expected_tool: name) }
      rescue StandardError => e
        [failure_finding(name, e, stderr)]
      end

      def execute(stderr)
        stdout, captured_stderr, status = capture(validated_command, resolved_timeout(name))
        stderr.replace(captured_stderr)
        validate_process_status!(status)
        parse(stdout)
      end

      def validate_process_status!(status)
        return if status&.exited? && status.exitstatus.zero?

        raise ParseError.new(tool: name, reason: "process did not exit normally with status 0")
      end
    end
  end
end
