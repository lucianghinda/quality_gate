# frozen_string_literal: true

require_relative "doctor_bounded_file"
require_relative "doctor_report"

module QualityGate
  # Summarizes recent automatic-hook history as historical evidence only.
  class DoctorHooks
    HOOK_PATHS = %w[
      .claude/hooks/quality_gate_fast.rb
      .claude/hooks/quality_gate_verify_stop.rb
    ].map!(&:freeze).freeze
    INSTALLED_HOOKS_MESSAGE = "Installed hooks have no history; run a hooked edit and inspect feedback."
    NO_INSTALLED_HOOKS_MESSAGE = "No hook history or installed hook files were found; " \
      "automatic feedback was not checked."

    def initialize(dir:)
      @dir = File.expand_path(dir).freeze
    end

    def call
      path = File.join(@dir, HookLog::DEFAULT_PATH)
      file = DoctorBoundedFile.read(path:, max_bytes: 0)
      summarize_file(file, path)
    end

    private

    def summarize_file(file, path)
      return missing_history if file.status == :missing
      return unreadable_history(file.status) unless %i[ok oversized].include?(file.status)

      summarize_history(path)
    end

    def installed_hooks?
      HOOK_PATHS.any? { File.exist?(File.join(@dir, _1)) || File.symlink?(File.join(@dir, _1)) }
    end

    def missing_history
      return [check("hooks", "unchecked", INSTALLED_HOOKS_MESSAGE)] if installed_hooks?

      [check("hooks", "not_applicable", NO_INSTALLED_HOOKS_MESSAGE)]
    end

    def unreadable_history(status)
      message = "Hook history is unsafe or unreadable (#{status}); inspect the log " \
        "before relying on hook feedback."
      [check("hooks", "unchecked", message)]
    end

    def summarize_history(path)
      records = HookLog.new(path:).recent(limit: 20)
      return empty_history if records.empty?

      unavailable_history(records)
    end

    def unavailable_history(records)
      count = records.count { %w[unavailable verify_unavailable].include?(_1.fetch("outcome")) }
      return warning(count) if count.positive?

      message = "Recent valid history had no unavailable outcomes; this describes " \
        "history, not current hook installation."
      [check("hooks", "ready", message)]
    end

    def empty_history
      [check("hooks", "unchecked", "Hook history has no valid recent records; inspect the log.")]
    end

    def warning(count)
      message = "#{count} of the last 20 checks were unavailable; inspect bundle " \
        "installation and the Quality Gate hook setup."
      [check("hooks", "warning", message)]
    end

    def check(id, status, message)
      DoctorReport.check(id:, status:, message:)
    end
  end
end
