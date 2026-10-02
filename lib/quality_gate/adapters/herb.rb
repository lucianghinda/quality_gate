# frozen_string_literal: true

require "json"

module QualityGate
  module Adapters
    class HerbReport
      SEVERITIES = { "error" => :error, "warning" => :warning, "info" => :info, "hint" => :info }.freeze

      def self.validate_status!(status, findings)
        validate_normal_exit!(status)
        validate_exit_findings!(status, findings)
      end

      def self.validate_normal_exit!(status)
        return if status&.exited? && [0, 1].include?(status.exitstatus)

        raise ParseError.new(tool: "herb", reason: "process did not exit normally with status 0 or 1")
      end

      def self.validate_exit_findings!(status, findings)
        valid = status.exitstatus.zero? ? findings.none? { _1.severity == :error } : findings.any?
        return if valid

        raise ParseError.new(tool: "herb", reason: "exit status #{status.exitstatus} conflicts with the report")
      end

      def initialize(report)
        @report = report
      end

      def parse
        validate_envelope!
        offenses = @report.fetch("offenses")
        findings = build_findings(offenses)
        HerbSummary.validate!(@report.fetch("summary"), offenses, @report.fetch("clean"))
        findings
      end

      private

      def validate_envelope!
        raise TypeError, "report must be a JSON object" unless @report.is_a?(Hash)
        raise TypeError, "completed must be true" unless @report.fetch("completed") == true
        raise TypeError, "clean must be a Boolean" unless [true, false].include?(@report.fetch("clean"))
      end

      def build_findings(offenses)
        raise TypeError, "offenses must be an array" unless offenses.is_a?(Array)

        offenses.map { build_finding(_1) }
      end

      def build_finding(offense)
        raise TypeError, "offense must be an object" unless offense.is_a?(Hash)

        Finding.new(tool: "herb", **finding_attributes(offense))
      end

      def finding_attributes(offense)
        offense_identity(offense).merge(offense_location(offense)).merge(offense_severity(offense))
      end

      def offense_identity(offense)
        { file: required_string(offense.fetch("filename"), "filename"),
          rule: required_string(offense.fetch("code"), "code"),
          message: offense_message(offense.fetch("message")) }
      end

      def offense_location(offense)
        location = offense.fetch("location")
        raise TypeError, "location must be an object" unless location.is_a?(Hash)

        start = location.fetch("start")
        raise TypeError, "location start must be an object" unless start.is_a?(Hash)

        { line: positive_line(start.fetch("line")) }
      end

      def offense_severity(offense)
        { severity: SEVERITIES.fetch(offense.fetch("severity")) }
      end

      def required_string(value, field)
        return value if value.is_a?(String) && !value.empty?

        raise TypeError, "#{field} must be a non-empty String"
      end

      def positive_line(value)
        return value if value.is_a?(Integer) && value.positive?

        raise TypeError, "line must be a positive Integer"
      end

      def offense_message(value)
        return value if value.is_a?(String)

        raise TypeError, "message must be a String"
      end
    end
    private_constant :HerbReport

    class HerbSummary
      def self.validate!(summary, offenses, clean)
        validate_summary_object!(summary)
        counts = offenses.map { _1.fetch("severity") }.tally
        validate_error_counts!(summary, counts)
        validate_other_counts!(summary, counts)
        validate_clean!(counts, clean)
      end

      def self.validate_summary_object!(summary)
        raise TypeError, "summary must be an object" unless summary.is_a?(Hash)
      end

      def self.validate_clean!(counts, clean)
        actionable = counts.fetch("error", 0) + counts.fetch("warning", 0)
        raise TypeError, "clean does not match offense summary" unless clean == actionable.zero?
      end

      def self.validate_error_counts!(summary, counts)
        errors = counts.fetch("error", 0)
        warnings = counts.fetch("warning", 0)
        validate_count!(summary, "totalErrors", errors)
        validate_count!(summary, "totalWarnings", warnings)
        validate_count!(summary, "totalOffenses", errors + warnings)
      end

      def self.validate_other_counts!(summary, counts)
        validate_optional_count!(summary, "totalInfo", counts.fetch("info", 0))
        validate_optional_count!(summary, "totalHints", counts.fetch("hint", 0))
        validate_optional_count!(summary, "totalNotReported", 0)
      end

      def self.validate_count!(summary, key, expected)
        return if valid_count?(summary.fetch(key), expected)

        raise TypeError, "summary #{key} does not match offenses"
      end

      def self.validate_optional_count!(summary, key, expected)
        return unless summary.key?(key)

        validate_count!(summary, key, expected)
      end

      def self.valid_count?(value, expected)
        value.is_a?(Integer) && value >= 0 && value == expected
      end
    end
    private_constant :HerbSummary

    class HerbExcludedSelection
      PREFIX = "⚠️  File "
      SUFFIX = " is excluded by configuration patterns."
      INSTRUCTIONS = "   Use --force to lint it anyway."

      def self.paths(stdout:, stderr:, status:, requested_paths:)
        new(stdout:, stderr:, status:, requested_paths:).paths
      end

      def initialize(stdout:, stderr:, status:, requested_paths:)
        @stdout = stdout
        @stderr = stderr
        @status = status
        @requested_paths = requested_paths
      end

      def paths
        return unless intentional_skip?

        skipped = diagnostic_paths
        return unless skipped.any? && skipped.uniq == skipped && skipped.all? { selected_files.include?(_1) }

        skipped
      end

      private

      def intentional_skip?
        @stdout.empty? && @status&.exited? && @status.exitstatus.zero? && @stderr.end_with?("\n\n")
      end

      def diagnostic_paths
        blocks = @stderr.split("\n\n", -1)
        blocks[0...-1].map { excluded_path(_1) }
      end

      def excluded_path(block)
        lines = block.lines(chomp: true)
        return unless lines.length == 2 && lines.last == INSTRUCTIONS

        first = lines.first
        return unless first.start_with?(PREFIX) && first.end_with?(SUFFIX)

        first.delete_prefix(PREFIX).delete_suffix(SUFFIX)
      end

      def selected_files
        @requested_paths.select { File.file?(_1) && File.extname(_1).downcase == ".erb" }
      end
    end
    private_constant :HerbExcludedSelection

    # Runs the optional Herb CLI and validates its structured ERB lint report.
    class Herb < Adapter
      CLI_FLAGS = %w[--json --no-github --no-timing --log-level hint].freeze
      private_constant :CLI_FLAGS

      def name = "herb"

      def command = command_for(resolved_paths)

      def call
        scan_selected_paths
      rescue StandardError => e
        [failure_finding(name, e, "")]
      end

      def parse(stdout)
        report = JSON.parse(stdout)
        HerbReport.new(report).parse
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError => e
        raise ParseError.new(tool: name, reason: e.message)
      end

      private

      def scan_selected_paths
        paths = resolved_paths.dup
        return [] if files.any? && paths.empty?

        scan(paths)
      end

      def scan(paths)
        deadline = monotonic_deadline(resolved_timeout(name))
        scan_until_complete(paths, deadline)
      end

      def scan_until_complete(paths, deadline)
        loop do
          result = scan_iteration(paths, deadline)
          return result.fetch(:findings) if result.key?(:findings)
          return [] if (paths = result.fetch(:paths)).empty?
        end
      end

      def scan_iteration(paths, deadline)
        stdout, stderr, status = capture_scan(paths, deadline)
        iteration_result(paths, stdout, stderr, status)
      rescue StandardError => e
        { findings: [failure_finding(name, e, stderr)] }
      end

      def iteration_result(paths, stdout, stderr, status)
        excluded = excluded_paths(stdout, stderr, status, paths)
        return { paths: paths - excluded } if excluded

        { findings: findings_for(stdout, status) }
      end

      def capture_scan(paths, deadline)
        remaining = remaining_before(deadline)
        raise ParseError.new(tool: name, reason: "timeout during exclusion retry") unless remaining.positive?

        capture(command_for(paths), remaining)
      end

      def excluded_paths(stdout, stderr, status, paths)
        HerbExcludedSelection.paths(stdout:, stderr:, status:, requested_paths: paths)
      end

      def findings_for(stdout, status)
        findings = parse(stdout)
        validate_findings!(findings, expected_tool: name)
        HerbReport.validate_status!(status, findings)
        findings
      end

      def command_for(paths)
        argv = configured_launcher + CLI_FLAGS
        argv.concat(paths.empty? && files.empty? ? ["."] : paths)
      end

      def configured_launcher
        config.fetch(:commands).fetch(:fast).fetch(:herb, ["herb-lint"])
      end

      def resolved_paths
        files.filter_map { existing_herb_path(_1) }.freeze
      end

      def existing_herb_path(path)
        return unless File.exist?(path)
        return if File.file?(path) && File.extname(path).downcase != ".erb"

        path.start_with?("-") ? File.join(".", path) : path
      end
    end
  end
end
