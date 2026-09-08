# frozen_string_literal: true

module QualityGate
  module RunnerValueCopy
    module_function

    def freeze_copy(value)
      case value
      when Array
        value.map { freeze_copy(_1) }.freeze
      when Hash
        value.each_with_object({}) do |(key, child), copy|
          copy[freeze_copy(key)] = freeze_copy(child)
        end.freeze
      when String
        value.dup.freeze
      else
        value
      end
    end
  end
  private_constant :RunnerValueCopy

  # Runs adapters in order and reduces their findings into one immutable result.
  class Runner
    Result = Data.define(:findings, :failed_tools, :checks) do
      def initialize(findings:, checks: [])
        copied_findings = findings.dup.freeze
        failed_tools = copied_findings.select(&:tool_failure?).map(&:tool).uniq
        copied_checks = RunnerValueCopy.freeze_copy(checks)

        super(
          findings: copied_findings,
          failed_tools: failed_tools.map { _1.dup.freeze }.freeze,
          checks: copied_checks
        )
      end

      # Override Data#with so replacements cannot bypass the derived-state invariant.
      def with(findings: self.findings, checks: self.checks)
        self.class.new(findings: findings, checks: checks)
      end

      def exit_code
        return ExitCode::TOOL_FAILURE if failed_tools.any?
        return ExitCode::FINDINGS if findings.any?

        ExitCode::CLEAN
      end
    end

    CHECK_SCOPES = {
      "rubocop" => "selected_files",
      "reek" => "selected_files",
      "test_suite" => "test_suite",
      "undercover" => "git_diff",
      "simplecov" => "coverage_summary",
      "brakeman" => "project",
      "bundler_audit" => "lockfile"
    }.freeze
    SELECTION_SUPPORTED_TOOLS = %w[rubocop reek].freeze
    private_constant :CHECK_SCOPES, :SELECTION_SUPPORTED_TOOLS

    def initialize(adapters:, config:, diagnostic_io: nil)
      @adapters = adapters.dup.freeze
      @config = config
      @diagnostic_io = diagnostic_io
    end

    def call
      findings = []
      checks = []

      adapters.each do |adapter|
        tool = adapter_name(adapter)
        write_progress(tool, scope_for(tool))
        started_at = monotonic_time
        adapter_findings = adapter.call
        findings.concat(adapter_findings)
        checks << check_for(tool, adapter_findings, elapsed_ms_since(started_at))
      end

      Result.new(findings:, checks:)
    end

    private

    attr_reader :adapters, :config, :diagnostic_io

    def adapter_name(adapter)
      adapter.name.to_s
    end

    def check_for(tool, findings, duration_ms)
      {
        tool: tool,
        status: status_for(findings),
        scope: scope_for(tool),
        requested_files: selection_supported?(tool) ? requested_files : [],
        duration_ms: duration_ms
      }
    end

    def selection_supported?(tool)
      SELECTION_SUPPORTED_TOOLS.include?(tool)
    end

    def scope_for(tool)
      scope = CHECK_SCOPES.fetch(tool, "unknown")
      return "project" if scope == "selected_files" && requested_files.empty?

      scope
    end

    def requested_files
      config.fetch(:files).map(&:to_s)
    end

    def status_for(findings)
      return "tool_failure" if findings.any?(&:tool_failure?)
      return "skipped" if findings.any? { _1.rule == "undercover_skipped" }
      return "findings" if findings.any?

      "clean"
    end

    def elapsed_ms_since(started_at)
      [(monotonic_time - started_at) * 1000, 0].max.round
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def write_progress(tool, scope)
      return unless diagnostic_io

      diagnostic_io.puts("Running #{sanitize_progress(tool)} (scope: #{scope})...")
    rescue StandardError
      nil
    end

    def sanitize_progress(value)
      value.to_s
           .encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�")
           .gsub(/(?:[[:cntrl:]]|[\u2028\u2029])+/, " ")
           .strip
    end
  end
end
