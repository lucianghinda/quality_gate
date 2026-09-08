# frozen_string_literal: true

require "json"

module QualityGate
  module Adapters
    # Reports changed Ruby regions that lack coverage.
    # rubocop:disable Metrics/ClassLength
    class Undercover < Adapter
      COVERAGE_PATH = "coverage/coverage.json"
      SKIP_RULE = "undercover_skipped"
      CLI_FOOTER_PATTERN = /\nUndercover finished in \d+(?:\.\d+)?s\n\z/
      private_constant :CLI_FOOTER_PATTERN

      def name = "undercover"

      def command
        point = compare_point
        raise ArgumentError, "Undercover comparison point is unavailable" unless point

        ["undercover", "--compare", point, "--simplecov", COVERAGE_PATH, "--format", "json"]
      end

      def compare_point
        return @compare_point if defined?(@compare_point)

        @compare_point = config.fetch(:compare_point) || automatic_compare_point
      end

      def call # rubocop:disable Metrics/AbcSize
        tool = name
        stderr = +""
        start_call_budget(resolved_timeout(tool))
        return [missing_coverage_finding] unless File.file?(COVERAGE_PATH)
        return [skip_finding] unless compare_point

        stdout, stderr, status = capture_with_remaining_timeout(command)
        validate_cli_envelope!(stdout, stderr, status)
        findings = parse(stdout)
        validate_cli_result!(status.exitstatus, findings)
        validate_findings!(findings, expected_tool: tool)
        findings
      rescue StandardError => e
        [failure_finding(tool, e, stderr)]
      ensure
        clear_call_budget
      end

      def parse(stdout)
        document = parsed_document(stdout)
        warnings, summary = report_parts(document)
        findings = warnings.map { finding_from(_1) }
        validate_summary!(summary, warnings)
        findings
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError => e
        raise ParseError.new(tool: name, reason: e.message)
      end

      private

      def start_call_budget(timeout_seconds)
        @call_timeout_seconds = timeout_seconds
        @call_deadline = monotonic_deadline(timeout_seconds)
      end

      def clear_call_budget
        remove_instance_variable(:@call_timeout_seconds) if defined?(@call_timeout_seconds)
        remove_instance_variable(:@call_deadline) if defined?(@call_deadline)
      end

      def capture_with_remaining_timeout(argv)
        return capture(argv, resolved_timeout(name)) unless defined?(@call_deadline)

        remaining = @call_deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise TimeoutError, "timeout after #{@call_timeout_seconds} seconds" unless remaining.positive?

        capture(argv, remaining)
      end

      def without_timing_footer(stdout)
        stdout.sub(/\nUndercover finished in \d+(?:\.\d+)?s\s*\z/, "")
      end

      def validate_cli_envelope!(stdout, stderr, status)
        cli_contract_error!("Undercover wrote diagnostic stderr") unless stderr.strip.empty?
        cli_contract_error!("Undercover did not exit normally") unless status&.exited?

        exitstatus = status.exitstatus
        unless [0, 1].include?(exitstatus)
          cli_contract_error!("Undercover exited with unsupported status #{exitstatus.inspect}")
        end
        return if CLI_FOOTER_PATTERN.match?(stdout)

        cli_contract_error!("Undercover output is missing its terminal timing footer")
      end

      def validate_cli_result!(exitstatus, findings)
        expected_exitstatus = findings.empty? ? 0 : 1
        return if exitstatus == expected_exitstatus

        cli_contract_error!("Undercover exit status #{exitstatus} disagrees with its warning count")
      end

      def cli_contract_error!(reason)
        raise ParseError.new(tool: name, reason:)
      end

      def parsed_document(stdout)
        document = JSON.parse(without_timing_footer(stdout))
        raise TypeError, "Undercover output must be a mapping" unless document.is_a?(Hash)

        document
      end

      def report_parts(document)
        warnings = document.fetch("warnings")
        summary = document.fetch("summary")
        raise TypeError, "warnings must be an Array" unless warnings.is_a?(Array)
        raise TypeError, "summary must be a mapping" unless summary.is_a?(Hash)
        raise TypeError, "validation must be nil" unless document["validation"].nil?

        [warnings, summary]
      end

      def missing_coverage_finding
        Finding.tool_failure(
          tool: name,
          message: "undercover: #{COVERAGE_PATH} is missing; SimpleCov wiring is absent. " \
                   "Run bin/rails generate quality_gate:install for Rails or " \
                   "bundle exec quality_gate init --profile ruby for plain Ruby."
        )
      end

      def skip_finding
        Finding.new(
          tool: name,
          file: "",
          line: 0,
          rule: SKIP_RULE,
          severity: :info,
          message: skip_reason
        )
      end

      def skip_reason
        return "Undercover skipped: repository is shallow; set compare_point explicitly." if shallow_repository?
        return detached_reason if detached_head?
        return first_commit_reason if first_commit?
        return missing_branch_reason unless default_branch_present?

        "Undercover skipped: HEAD and default branch #{default_branch_name} have no common ancestor."
      end

      def detached_reason
        "Undercover skipped: HEAD is detached from #{default_branch_name} with no shared ancestor."
      end

      def first_commit_reason
        "Undercover skipped: this is the first commit, so there is no earlier commit to compare against."
      end

      def missing_branch_reason
        "Undercover skipped: default branch #{default_branch_name} is missing locally."
      end

      def shallow_repository?
        git_output("rev-parse", "--is-shallow-repository") == "true"
      end

      def detached_head?
        git_output("symbolic-ref", "--quiet", "HEAD", expected_exitstatuses: [1]).nil?
      end

      def first_commit?
        commit_and_parents = git_output("rev-list", "--parents", "-n", "1", "HEAD")
        commit_and_parents&.split&.one?
      end

      def automatic_compare_point
        branch = default_branch_ref
        return unless default_branch_present?
        return if first_commit? && current_branch_name == default_branch_name

        merge_base(branch)
      end

      def current_branch_name
        git_output("symbolic-ref", "--quiet", "--short", "HEAD", expected_exitstatuses: [1])
      end

      def default_branch_present?
        default_branch_ref unless defined?(@default_branch_present)
        @default_branch_present
      end

      def default_branch_name
        default_branch_ref unless defined?(@default_branch_name)
        @default_branch_name
      end

      def default_branch_ref
        return @default_branch_ref if defined?(@default_branch_ref)

        @default_branch_ref = remote_default_branch || local_default_branch
      end

      def remote_default_branch
        branch = git_output(
          "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD",
          expected_exitstatuses: [1]
        )
        return unless branch
        return unless commit_exists?(branch)

        @default_branch_present = true
        @default_branch_name = branch.delete_prefix("refs/remotes/origin/")
        branch
      end

      def local_default_branch
        %w[main master].each do |branch|
          ref = "refs/heads/#{branch}"
          next unless commit_exists?(ref)

          @default_branch_present = true
          @default_branch_name = branch
          return ref
        end

        @default_branch_present = false
        @default_branch_name = "main"
        "refs/heads/main"
      end

      def merge_base(branch)
        git_output("merge-base", "HEAD", branch, expected_exitstatuses: [1])
      end

      def commit_exists?(ref)
        git_output("rev-parse", "--verify", "--quiet", "#{ref}^{commit}", expected_exitstatuses: [1])
      end

      def git_output(*arguments, expected_exitstatuses: [])
        stdout, stderr, status = capture_with_remaining_timeout(git_command(arguments))
        return if expected_git_status?(status, stderr, expected_exitstatuses)

        raise_git_error(arguments, stderr, status) unless status&.success? && stderr.empty?

        value = stdout.strip
        value unless value.empty?
      end

      def expected_git_status?(status, stderr, expected_exitstatuses)
        status && stderr.empty? && expected_exitstatuses.include?(status.exitstatus)
      end

      def git_command(arguments)
        ["git", *arguments]
      end

      def raise_git_error(arguments, stderr, status)
        result = status ? "exit #{status.exitstatus}" : "no exit status"
        diagnostic = stderr.strip
        diagnostic = "; stderr: #{diagnostic}" unless diagnostic.empty?
        raise "git #{arguments.join(" ")} failed (#{result})#{diagnostic}"
      end

      def finding_from(warning)
        validate_warning!(warning)

        Finding.new(
          tool: name,
          file: warning.fetch("file"),
          line: warning.fetch("first_line"),
          rule: "uncovered_code",
          severity: :warning,
          message: warning_message(warning)
        )
      end

      def validate_summary!(summary, warnings)
        total_warnings = summary.fetch("total_warnings")
        files_affected = summary.fetch("files_affected")
        unless non_negative_integer?(total_warnings) && non_negative_integer?(files_affected)
          raise TypeError, "summary counts must be non-negative Integers"
        end
        raise TypeError, "summary total_warnings does not match warnings" unless total_warnings == warnings.length

        unique_files = warnings.map { _1.fetch("file") }.uniq.length
        raise TypeError, "summary files_affected does not match warning files" unless files_affected == unique_files
      end

      def non_negative_integer?(value)
        value.is_a?(Integer) && value >= 0
      end

      def validate_warning!(warning)
        return if warning.is_a?(Hash) && valid_warning?(warning)

        raise TypeError, "warning is malformed"
      end

      def valid_warning?(warning)
        required_strings?(warning) && valid_range?(warning) && warning["coverage"].is_a?(Numeric) &&
          valid_lines?(warning["uncovered_lines"]) && valid_branches?(warning["uncovered_branches"])
      end

      def required_strings?(warning)
        warning.values_at("node", "type", "file").all? { _1.is_a?(String) && !_1.empty? }
      end

      def valid_range?(warning)
        first_line, last_line = warning.values_at("first_line", "last_line")
        first_line.is_a?(Integer) && first_line.positive? && last_line.is_a?(Integer) && last_line >= first_line
      end

      def valid_lines?(lines)
        lines.is_a?(Array) && lines.all? { _1.is_a?(Integer) && _1 >= 0 }
      end

      def valid_branches?(branches)
        branches.is_a?(Array) && branches.all? { valid_branch?(_1) }
      end

      def valid_branch?(branch)
        return false unless branch.is_a?(Hash)

        numbers = branch.values_at("line", "block", "branch")
        description = branch["description"]
        numbers.all? { _1.is_a?(Integer) && _1 >= 0 } && (description.nil? || description.is_a?(String))
      end

      def warning_message(warning)
        "#{warning.fetch("type")} #{warning.fetch("node")} lines " \
          "#{warning.fetch("first_line")}-#{warning.fetch("last_line")}: " \
          "coverage #{warning.fetch("coverage")}; " \
          "uncovered lines #{list_or_none(warning.fetch("uncovered_lines"))}; " \
          "uncovered branches #{branch_list_or_none(warning.fetch("uncovered_branches"))}"
      end

      def list_or_none(values)
        values.empty? ? "none" : values.join(", ")
      end

      def branch_list_or_none(branches)
        return "none" if branches.empty?

        branches.map do |branch|
          label = "line #{branch.fetch("line")} block #{branch.fetch("block")} branch #{branch.fetch("branch")}"
          description = branch["description"]
          description ? "#{label} (#{description})" : label
        end.join(", ")
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
