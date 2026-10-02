# frozen_string_literal: true

require_relative "adapters/undercover"
require_relative "doctor_report"
require_relative "doctor_path_lookup"

module QualityGate
  # Checks Undercover comparison availability through its bounded Git resolver.
  class DoctorGit < Adapters::Undercover
    GIT_BUDGET_SECONDS = 5

    def initialize(dir:, config:)
      @doctor_dir = File.expand_path(dir).freeze
      @paths = DoctorPathLookup.new(dir: @doctor_dir, path: ENV["PATH"])
      super(config:)
    end

    def call
      perform
    ensure
      clear_call_budget
    end

    private

    def perform
      return status_check("not_applicable", "Undercover is disabled; no comparison is needed.") unless enabled?

      comparison_with_git
    rescue StandardError => e
      failure_check_for(e)
    end

    def comparison_with_git
      return invalid_reference if option_like_reference?
      return path_error unless git_available?

      point = config.fetch(:compare_point)
      point ? explicit_comparison_check(point) : automatic_comparison_check
    end

    def explicit_comparison_check(point)
      start_call_budget(GIT_BUDGET_SECONDS)
      commit = git_output("rev-parse", "--verify", "--quiet", "#{point}^{commit}", expected_exitstatuses: [1])
      comparison_result(commit)
    end

    def automatic_comparison_check
      start_call_budget(GIT_BUDGET_SECONDS)
      point = compare_point
      return no_automatic_point unless point

      [check("comparison", "ready", "Automatic comparison resolves to local commit #{point}.")]
    end

    def enabled?
      config.fetch(:adapters).values.any? { _1.include?("undercover") }
    end

    def git_command(arguments)
      [@git_executable, "-C", @doctor_dir, *arguments]
    end

    def check(id, status, message)
      DoctorReport.check(id:, status:, message:)
    end

    def no_automatic_point
      status_check("unchecked", "No automatic comparison is available; fetch history or configure compare_point.")
    end

    def comparison_result(commit)
      return [check("comparison", "ready", "Configured comparison resolves to commit #{commit}.")] if commit

      [check("comparison", "blocked",
             "Configured comparison does not resolve to a commit; choose an existing commit ref.")]
    end

    def invalid_reference
      status_check("blocked", "The configured comparison ref is option-like and cannot be checked.")
    end

    def git_available?
      @git_executable = @paths.resolve_executable("git")
      @git_executable.is_a?(String)
    end

    def status_check(status, message)
      [check("comparison", status, message)]
    end

    def failure_check_for(error)
      return missing_git if error.is_a?(Errno::ENOENT)
      return timed_out if error.is_a?(TimeoutError)

      status_check("unchecked",
                   "Git comparison could not be inspected; check local history or configure compare_point.")
    end

    def option_like_reference?
      config.fetch(:compare_point)&.start_with?("-")
    end

    def missing_git
      status_check("blocked", "Git is unavailable on project-rooted PATH; install Git or add it to PATH.")
    end

    def timed_out
      status_check("unchecked", "Git lookup exceeded five seconds; inspect local history or configure compare_point.")
    end

    def path_error
      unless @paths.available?
        return status_check("unchecked",
                            "PATH is absent, so Git availability is ambiguous; inspect runtime PATH.")
      end

      missing_git
    end
  end
end
