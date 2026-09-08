# frozen_string_literal: true

require "test_helper"

require "json"
require_relative "../support/acceptance_project"

module Acceptance
  class LatencyTest < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)
    WARM_FAST_BUDGET = 2.0
    HOOK_BUDGET = 3.0

    def test_warm_file_scoped_fast_stays_under_two_seconds
      require_named_timing_run!

      QualityGate::AcceptanceProject.open(fixture: "clean", repository_root: ROOT) do |project|
        arguments = ["--files", "lib/calculator.rb"]
        warmup = project.run("fast", *arguments)
        measured = project.run("fast", *arguments)

        assert_clean_run warmup
        assert_clean_run measured
        puts format(
          "warm file-scoped fast: %<measured>.3fs (budget %<budget>.1fs)",
          measured: measured.elapsed_seconds,
          budget: WARM_FAST_BUDGET
        )
        assert_operator measured.elapsed_seconds, :<, WARM_FAST_BUDGET,
                        timing_failure("warm file-scoped fast", measured.elapsed_seconds, WARM_FAST_BUDGET)
      end
    end

    # rubocop:disable Metrics/AbcSize
    def test_installed_hook_round_trip_stays_under_three_seconds
      require_named_timing_run!

      QualityGate::AcceptanceProject.open(fixture: "clean", repository_root: ROOT) do |project|
        file = File.join(project.root, "lib/calculator.rb")
        log = File.join(project.root, "log/quality_gate_hooks.jsonl")
        previous_records = hook_records(log)

        measured = project.invoke_hook(file:)
        new_records = hook_records(log).drop(previous_records.length)

        assert_equal 0, measured.status, run_diagnostic(measured)
        assert_empty measured.stderr
        assert_equal 1, new_records.length, "expected one new hook log record, got #{new_records.inspect}"
        assert_equal "clean", new_records.fetch(0).fetch("outcome")
        assert_equal file, new_records.fetch(0).fetch("file")
        puts format(
          "installed hook round trip: %<measured>.3fs (budget %<budget>.1fs)",
          measured: measured.elapsed_seconds,
          budget: HOOK_BUDGET
        )
        assert_operator measured.elapsed_seconds, :<, HOOK_BUDGET,
                        timing_failure("installed hook round trip", measured.elapsed_seconds, HOOK_BUDGET)
      end
    end
    # rubocop:enable Metrics/AbcSize

    private

    def require_named_timing_run!
      return if ENV["QUALITY_GATE_ACCEPTANCE_TIMING"] == "1"

      skip "set QUALITY_GATE_ACCEPTANCE_TIMING=1 to run the named-machine latency budget"
    end

    def assert_clean_run(run)
      assert_equal 0, run.status, run_diagnostic(run)
      assert_empty run.stderr
      assert_empty run.report.fetch("findings")
      assert_equal 0, run.report.fetch("summary").fetch("tool_failures")
    end

    def hook_records(path)
      return [] unless File.file?(path)

      File.readlines(path, chomp: true).map { JSON.parse(_1) }
    end

    def timing_failure(label, measured, budget)
      format(
        "%<label>s measured %<measured>.3fs against a %<budget>.1fs budget; " \
        "enable RuboCop server mode before relaxing the budget",
        label:,
        measured:,
        budget:
      )
    end

    def run_diagnostic(run)
      "status=#{run.status}; stdout=#{run.stdout.inspect}; stderr=#{run.stderr.inspect}; report=#{run.report.inspect}"
    end
  end
end
