# frozen_string_literal: true

require "json"
require "pathname"
require "stringio"
require_relative "codex_patch_files"

module QualityGate
  # Runs file-scoped fast checks after Codex applies a native patch.
  class CodexFastHook
    FINDING_STRING_FIELDS = %w[tool file rule severity message].freeze
    private_constant :FINDING_STRING_FIELDS

    class Report
      def self.parse(output)
        report = JSON.parse(output)
        raise TypeError unless valid?(report)

        report
      end

      def self.valid?(report)
        report.is_a?(Hash) && valid_findings?(report["findings"]) &&
          valid_summary?(report["summary"], report.fetch("findings").length)
      end

      def self.valid_findings?(findings)
        findings.is_a?(Array) && findings.all? { valid_finding?(_1) }
      end

      def self.valid_finding?(finding)
        return false unless finding.is_a?(Hash) && FINDING_STRING_FIELDS.all? { finding[_1].is_a?(String) }

        line = finding["line"]
        line.is_a?(Integer) && line >= 0 && Finding::SEVERITIES.any? { _1.to_s == finding["severity"] } &&
          finding["rule"] != Finding::TOOL_FAILURE_RULE
      end

      def self.valid_summary?(summary, count)
        return false unless summary.is_a?(Hash)

        findings, failures = summary.values_at("findings", "tool_failures")
        findings.is_a?(Integer) && findings == count && failures.is_a?(Integer) &&
          failures.zero? && summary["failed_tools"] == []
      end
      private_class_method :valid_findings?, :valid_finding?, :valid_summary?
    end
    private_constant :Report

    def initialize(dir:)
      @dir = File.expand_path(dir)
    end

    def call(input)
      return unavailable unless valid_input?(input)

      evaluate(input)
    rescue StandardError
      unavailable
    end

    private

    attr_reader :dir

    def valid_input?(input)
      input.is_a?(Hash) && input["hook_event_name"] == "PostToolUse" && input["tool_name"] == "apply_patch" &&
        input.dig("tool_input", "command").is_a?(String) && absolute_existing_path?(input["cwd"])
    rescue TypeError, NoMethodError
      false
    end

    def evaluate(input)
      root = File.realpath(dir)
      cwd = File.realpath(input.fetch("cwd"))
      return unavailable unless inside?(cwd, root) && File.directory?(cwd)

      files = selected_files(input.fetch("tool_input").fetch("command"), cwd, root)
      files.empty? ? {} : run_fast(files)
    end

    def absolute_existing_path?(path)
      path.is_a?(String) && Pathname.new(path).absolute? && File.directory?(path)
    end

    def inside?(path, root)
      path == root || path.start_with?("#{root}#{File::SEPARATOR}")
    end

    def selected_files(patch, cwd, root)
      paths = CodexPatchFiles.parse(patch)
      ruby_files = resolved_files(paths, ".rb", cwd, root)
      erb_files = resolved_files(paths, ".erb", cwd, root)
      return ruby_files if erb_files.empty? || !herb_enabled?(root)

      ruby_files + erb_files
    end

    def resolved_files(paths, extension, cwd, root)
      paths.filter_map { resolved_file(_1, cwd, root) if File.extname(_1) == extension }.uniq
    end

    def herb_enabled?(root)
      Config.load(dir: root).fetch(:adapters).fetch(:fast).include?("herb")
    end

    def resolved_file(path, cwd, root)
      expanded = File.expand_path(path, cwd)
      return unless File.file?(expanded)

      canonical_file(expanded, root)
    rescue SystemCallError
      nil
    end

    def canonical_file(path, root)
      canonical = File.realpath(path)
      canonical if inside?(canonical, root) && File.file?(canonical)
    end

    def run_fast(files)
      stdout = StringIO.new
      status = CLI.run(["fast", "--format", "json", "--files", *files], stdout:, stderr: StringIO.new, dir:)
      respond_to_report(status, Report.parse(stdout.string))
    end

    def respond_to_report(status, report)
      findings = report.fetch("findings")
      return {} if status.zero? && findings.empty?
      return unavailable unless status == 1 && findings.any?

      additional_context("Fix these Quality Gate findings after this edit:\n#{format_findings(findings)}")
    end

    def format_findings(findings)
      findings.map { format_finding(_1) }.join("\n")
    end

    def format_finding(finding)
      "#{finding.fetch("file")}:#{finding.fetch("line")} " \
        "[#{finding.fetch("tool")}/#{finding.fetch("rule")}] #{finding.fetch("message")}"
    end

    def unavailable
      message = "Quality Gate fast feedback unavailable; run `bundle exec quality_gate fast` manually."
      { "systemMessage" => message }.merge(
        "hookSpecificOutput" => hook_output(unavailable_context)
      )
    end

    def unavailable_context
      "Quality Gate fast feedback is unavailable. Run `bundle exec quality_gate fast` manually."
    end

    def additional_context(context)
      { "hookSpecificOutput" => hook_output(context) }
    end

    def hook_output(context)
      { "hookEventName" => "PostToolUse", "additionalContext" => context }
    end
  end
end
