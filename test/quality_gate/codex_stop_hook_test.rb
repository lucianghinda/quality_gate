# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"
require "quality_gate/codex_stop_hook"

module QualityGate
  class CodexStopHookTest < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)

    def test_clean_report_allows_stop_and_runs_full_verify_in_installed_root
      assert_hook_result({}, status: 0, report: clean_report)
    end

    def test_findings_block_once_with_fix_request_and_normalized_report
      response = assert_hook_result(
        { "decision" => "block", "reason" => %r{Fix these findings.*Style/Test}m },
        status: 1,
        report: findings_report
      )
      assert_includes response.fetch("reason"), "app/models/example.rb:3"
    end

    def test_resumed_stop_reruns_verify_but_caps_a_second_block
      response = assert_hook_result(
        { "systemMessage" => /continuation limit.*findings/m },
        status: 1,
        report: findings_report,
        input: stop_input(active: true)
      )
      refute response.key?("decision")
    end

    def test_resumed_stop_allows_clean_report
      assert_hook_result({}, status: 0, report: clean_report, input: stop_input(active: true))
    end

    def test_invalid_input_is_visible_and_does_not_claim_clean
      [nil, [], { "hook_event_name" => "Other", "stop_hook_active" => false }, stop_input(active: 1)].each do |input|
        response = QualityGate::CodexStopHook.new(dir: ROOT).call(input)
        assert_match(/unavailable/i, response.fetch("systemMessage"))
        refute response.key?("decision")
      end
    end

    def test_tool_failures_malformed_reports_and_inconsistent_status_are_unavailable
      [
        [2, clean_report], [0, "not json"], [0, JSON.generate([])], [0, findings_report],
        [1, clean_report], [2, tool_failure_report], [0, mismatched_report]
      ].each do |status, report|
        response = invoke(status:, report:)
        assert_match(/unavailable/i, response.fetch("systemMessage"))
        refute response.key?("decision")
      end
    end

    def test_float_summary_counts_are_unavailable
      [
        { "findings" => 0.0, "tool_failures" => 0, "failed_tools" => [] },
        { "findings" => 0, "tool_failures" => 0.0, "failed_tools" => [] }
      ].each do |summary|
        response = invoke(status: 0, report: JSON.generate("findings" => [], "summary" => summary))
        assert_match(/unavailable/i, response.fetch("systemMessage"))
      end
    end

    def test_nonmapping_summary_is_unavailable
      [nil, []].each do |summary|
        report = JSON.generate("findings" => [], "summary" => summary)
        response = invoke(status: 0, report:)
        assert_match(/unavailable/i, response.fetch("systemMessage"))
        refute response.key?("decision")
      end
    end

    def test_cli_exception_is_visible
      QualityGate::CLI.stub(:run, ->(*) { raise "broken" }) do
        response = QualityGate::CodexStopHook.new(dir: ROOT).call(stop_input)
        assert_match(/unavailable/i, response.fetch("systemMessage"))
      end
    end

    private

    def assert_hook_result(expected, status:, report:, input: stop_input)
      response = invoke(status:, report:, input:)
      expected.each do |key, value|
        value.is_a?(Regexp) ? assert_match(value, response.fetch(key)) : assert_equal(value, response.fetch(key))
      end
      response
    end

    def invoke(status:, report:, input: stop_input)
      QualityGate::CLI.stub(:run, lambda do |argv, stdout:, stderr:, dir:|
        @cli_call = [argv, dir, stdout, stderr]
        stdout.write(report)
        status
      end) do
        result = QualityGate::CodexStopHook.new(dir: ROOT).call(input)
        assert_equal ["verify", "--format", "json"], @cli_call.fetch(0)
        assert_equal ROOT, @cli_call.fetch(1)
        assert_equal report, @cli_call.fetch(2).string
        assert_instance_of StringIO, @cli_call.fetch(3)
        result
      end
    end

    def stop_input(active: false) = { "hook_event_name" => "Stop", "stop_hook_active" => active }

    def clean_report
      JSON.generate("findings" => [], "summary" => { "findings" => 0, "tool_failures" => 0, "failed_tools" => [] })
    end

    def findings_report
      JSON.generate(
        "findings" => [finding],
        "summary" => { "findings" => 1, "tool_failures" => 0, "failed_tools" => [] }
      )
    end

    def finding
      { "tool" => "rubocop", "file" => "app/models/example.rb", "line" => 3, "rule" => "Style/Test",
        "severity" => "warning", "message" => "fix this" }
    end

    def tool_failure_report
      JSON.generate(
        "findings" => [],
        "summary" => { "findings" => 0, "tool_failures" => 1, "failed_tools" => ["reek"] }
      )
    end

    def mismatched_report
      JSON.generate("findings" => [], "summary" => { "findings" => 1, "tool_failures" => 0, "failed_tools" => [] })
    end
  end
end
