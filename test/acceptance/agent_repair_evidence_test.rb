# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/agent_repair_acceptance/evidence"

class AgentRepairEvidenceTest < Minitest::Test
  def test_native_feedback_followed_by_repair_and_clean_gates_is_observed
    evidence = valid_evidence

    result = AgentRepairAcceptance::Evidence.new(evidence).call

    assert_equal "automatic_repair_observed", result.fetch("outcome")
    assert_empty result.fetch("reasons")
    assert_equal "claude", result.fetch("client")
    assert_equal "fast", result.fetch("scenario")
  end

  def test_codex_native_patch_and_structured_hook_feedback_are_observed
    evidence = codex_evidence

    assert_equal "automatic_repair_observed", evaluate(evidence).fetch("outcome")
  end

  def test_verify_feedback_repair_and_clean_stop_require_a_new_native_test
    evidence = verify_evidence

    assert_equal "automatic_repair_observed", evaluate(evidence).fetch("outcome")
  end

  def test_actual_claude_capture_shape_with_interleaved_hook_events_is_observed
    evidence = actual_claude_evidence

    assert_equal "automatic_repair_observed", evaluate(evidence).fetch("outcome")
  end

  def test_codex_verify_block_feedback_uses_native_block_decision_and_undercover_finding
    evidence = verify_evidence
    evidence["manifest"]["client"] = "codex"
    evidence["session"]["stdout"] = codex_verify_transcript
    evidence["hooks"] = codex_verify_hooks(evidence.dig("manifest", "seed_sha256"))

    assert_equal "automatic_repair_observed", evaluate(evidence).fetch("outcome")
  end

  def test_verify_write_without_a_recorded_test_digest_does_not_prove_repair
    evidence = verify_evidence
    evidence["hooks"][1]["test_sha256"].delete("test/calculator_repair_test.rb")

    assert_equal "not_observed", evaluate(evidence).fetch("outcome")
  end

  def test_assistant_text_that_mentions_a_finding_is_not_hook_feedback
    evidence = valid_evidence
    evidence["hooks"][0]["stderr"] = "I found a Layout/SpaceAfterComma issue"

    assert_equal "unavailable", evaluate(evidence).fetch("outcome")
  end

  def test_hook_session_must_match_native_session
    evidence = valid_evidence
    evidence["hooks"][0]["session_id"] = "other-session"

    assert_equal "not_observed", evaluate(evidence).fetch("outcome")
  end

  def test_initial_digest_must_match_the_controlled_seed
    evidence = valid_evidence
    evidence["hooks"][0]["source_sha256"] = "different"

    assert_equal "unavailable", evaluate(evidence).fetch("outcome")
  end

  def test_synthetic_hook_capture_cannot_prove_native_repair
    evidence = valid_evidence
    evidence["hooks"][0]["synthetic"] = true

    assert_equal "not_observed", evaluate(evidence).fetch("outcome")
  end

  def test_unavailable_and_capped_hooks_are_unavailable
    %w[verify_unavailable verify_cap].each do |outcome|
      evidence = valid_evidence
      evidence["hooks"][0]["hook_log"] = [{ "outcome" => outcome }]

      assert_equal "unavailable", evaluate(evidence).fetch("outcome")
    end
  end

  def test_manifest_change_invalidates_protected_state_evidence
    evidence = valid_evidence
    evidence["final"]["protected_files_unchanged"] = false

    assert_equal "not_observed", evaluate(evidence).fetch("outcome")
  end

  def test_native_edits_outside_the_fixture_mutation_allowlist_are_not_observed
    evidence = outside_edit_evidence

    assert_equal "not_observed", evaluate(evidence).fetch("outcome")
  end

  def test_native_write_outside_the_fixture_root_is_not_ignored
    evidence = valid_evidence
    evidence["session"]["stdout"] = outside_root_transcript

    assert_equal "not_observed", evaluate(evidence).fetch("outcome")
  end

  def test_codex_multifile_patch_must_check_every_changed_path
    evidence = codex_evidence
    evidence["session"]["stdout"] = codex_multifile_transcript

    assert_equal "not_observed", evaluate(evidence).fetch("outcome")
  end

  def test_incomplete_or_skipped_baseline_checks_fail
    evidence = valid_evidence
    evidence["manifest"]["baseline"]["fast"]["report"]["checks"] = []

    assert_equal "not_observed", evaluate(evidence).fetch("outcome")
  end

  def test_invalid_input_maps_to_exit_two
    result = AgentRepairAcceptance::Evidence.new({}).call

    assert_equal "unavailable", result.fetch("outcome")
    assert_equal 2, AgentRepairAcceptance::Evidence.exit_status(result)
  end

  private

  def evaluate(evidence)
    AgentRepairAcceptance::Evidence.new(evidence).call
  end

  def valid_evidence
    session_id = "session-1"
    seed = "a" * 64
    hooks = evidence_hooks(session_id, seed)
    {
      "manifest" => manifest(seed), "session" => session(session_id), "hooks" => hooks,
      "final" => { "fast" => clean_gate(%w[rubocop]), "verify" => clean_gate(%w[test_suite undercover]),
                   "behavior" => true, "protected_files_unchanged" => true,
                   "allowed_mutations_only" => true, "head_unchanged" => true }
    }
  end

  def actual_claude_evidence
    evidence = valid_evidence
    evidence["session"]["stdout"] = actual_claude_transcript
    evidence["hooks"][0].merge!("stderr" => actual_claude_finding, "tool_name" => "Write",
                                "tool_use_id" => "native-write", "status" => 2)
    evidence["hooks"][1].merge!("tool_name" => "Edit", "tool_use_id" => "native-edit")
    evidence["hooks"][2]["hook_log"] = [{ "outcome" => "verify_skipped" }]
    evidence
  end

  def outside_edit_evidence
    evidence = valid_evidence
    rows = evidence["session"]["stdout"].lines.map { JSON.parse(_1) }
    rows << claude_tool("outside-edit", "Write", "config/quality_gate.yml")
    evidence["session"]["stdout"] = rows.map { JSON.generate(_1) }.join("\n")
    evidence
  end

  def outside_root_transcript
    "#{native_session("session-1")}\n#{JSON.generate(
      claude_tool("outside-edit", "Edit", "/outside/fixture.evidence/hooks.jsonl")
    )}"
  end

  def codex_multifile_transcript
    [
      { "type" => "thread.started", "thread_id" => "session-1" },
      codex_file_edit("file-1", "lib/calculator.rb"),
      { "type" => "item.completed", "item" => { "id" => "file-2", "type" => "file_change",
                                                "changes" => [{ "path" => "lib/calculator.rb" },
                                                              { "path" => "/fixture.evidence/manifest.json" }] } }
    ].map { JSON.generate(_1) }.join("\n")
  end

  def actual_claude_finding
    JSON.generate("checks" => [{ "tool" => "rubocop", "status" => "findings" }],
                  "findings" => [{ "tool" => "rubocop", "file" => "lib/calculator.rb",
                                   "rule" => "Layout/SpaceAfterComma", "severity" => "warning" }],
                  "summary" => { "findings" => 1, "tool_failures" => 0, "failed_tools" => [] })
  end

  def native_session(session_id)
    [
      { "type" => "system", "subtype" => "init", "session_id" => session_id },
      { "type" => "assistant", "message" => { "content" => [
        { "type" => "tool_use", "id" => "use-1", "name" => "Edit", "input" => { "file_path" => "lib/calculator.rb" } }
      ] } },
      { "type" => "assistant", "message" => { "content" => [
        { "type" => "tool_use", "id" => "use-2", "name" => "Edit", "input" => { "file_path" => "lib/calculator.rb" } }
      ] } }
    ].map { JSON.generate(_1) }.join("\n")
  end

  def actual_claude_transcript
    rows = [
      { "type" => "system", "subtype" => "hook_started", "hook_event" => "PostToolUse" },
      { "type" => "system", "subtype" => "hook_response", "hook_event" => "PostToolUse" },
      { "type" => "system", "subtype" => "init", "session_id" => "session-1" },
      claude_tool("native-read", "Read", "lib/calculator.rb"),
      claude_tool("native-write", "Write", "lib/calculator.rb"),
      { "type" => "user", "message" => { "content" => [{ "type" => "tool_result" }] } },
      claude_tool("native-edit", "Edit", "lib/calculator.rb"),
      { "type" => "system", "subtype" => "hook_response", "hook_event" => "Stop" },
      { "type" => "result", "subtype" => "success" }
    ]
    rows.map { JSON.generate(_1) }.join("\n")
  end

  def evidence_hooks(session_id, seed)
    hook = { "client" => "claude", "event" => "PostToolUse", "session_id" => session_id,
             "tool_name" => "Edit", "tool_use_id" => "use-1", **timestamps,
             "status" => 2, "stdout" => "", "stderr" => finding_output, "source_sha256" => seed,
             "test_sha256" => { "test/calculator_test.rb" => "b" * 64 } }
    [hook.merge("hook_log" => [{ "outcome" => "findings" }]),
     hook.merge("tool_use_id" => "use-2", "source_sha256" => "f" * 64, "status" => 0,
                "stderr" => "", "hook_log" => [{ "outcome" => "clean" }]),
     hook.merge("tool_use_id" => nil, "tool_name" => nil, "event" => "Stop", "status" => 0,
                "stdout" => "", "stderr" => "", "hook_log" => [{ "outcome" => "verify_skipped" }])]
  end

  def manifest(seed)
    {
      "schema_version" => 1, "client" => "claude", "scenario" => "fast", "root" => "/fixture",
      "prepared_at" => timestamps.fetch("started_at"), "source_path" => "lib/calculator.rb",
      "seed_sha256" => seed, "package" => { "version" => "0.3.0", "sha256" => "c" * 64,
                                            "resolved_path" => "/gems/quality_gate.gem" },
      "baseline" => { "fast" => clean_gate(%w[rubocop]), "verify" => clean_gate(%w[test_suite undercover]) },
      "protected_files" => { "config/quality_gate.yml" => "d" * 64,
                             "test/calculator_test.rb" => "b" * 64 }, "head" => "e" * 40,
      "prompt" => "Repair one introduced issue"
    }
  end

  def session(session_id)
    { "kind" => "native", "client_version" => "1.0", "command" => ["claude", "-p"], **timestamps, "status" => 0,
      "stdout" => native_session(session_id), "stderr" => "", "timed_out" => false, "extra_prompts" => 0 }
  end

  def timestamps
    { "started_at" => "2026-10-05T10:00:00Z", "completed_at" => "2026-10-05T10:01:00Z" }
  end

  def finding_output
    JSON.generate("findings" => [{ "tool" => "rubocop", "file" => "lib/calculator.rb",
                                   "rule" => "Layout/SpaceAfterComma", "severity" => "warning",
                                   "message" => "missing space", "line" => 1 }],
                  "summary" => { "findings" => 1, "tool_failures" => 0, "failed_tools" => [] })
  end

  def codex_evidence
    evidence = valid_evidence
    evidence["manifest"]["client"] = "codex"
    evidence["session"]["stdout"] = codex_transcript
    evidence["hooks"] = codex_hooks(evidence.dig("manifest", "seed_sha256"))
    evidence
  end

  def codex_transcript
    [
      { "type" => "thread.started", "thread_id" => "session-1" },
      codex_file_edit("file-1", "lib/calculator.rb"),
      codex_file_edit("file-2", "lib/calculator.rb")
    ].map { JSON.generate(_1) }.join("\n")
  end

  def codex_file_edit(id, path)
    { "type" => "item.completed", "item" => { "id" => id, "type" => "file_change",
                                              "changes" => [{ "path" => path }] } }
  end

  def codex_hooks(seed)
    shared = { "client" => "codex", "session_id" => "session-1", **timestamps,
               "test_sha256" => { "test/calculator_test.rb" => "b" * 64 } }
    [
      shared.merge("event" => "PostToolUse", "tool_name" => "apply_patch",
                   "changed_paths" => ["lib/calculator.rb"], "source_sha256" => seed, "status" => 0,
                   "stdout" => codex_finding_output, "stderr" => ""),
      shared.merge("event" => "PostToolUse", "tool_name" => "apply_patch",
                   "changed_paths" => ["lib/calculator.rb"], "source_sha256" => "f" * 64, "status" => 0,
                   "stdout" => "{}", "stderr" => ""),
      shared.merge("event" => "Stop", "status" => 0, "source_sha256" => "f" * 64,
                   "stdout" => "{}", "stderr" => "")
    ]
  end

  def codex_finding_output
    JSON.generate("hookSpecificOutput" => { "hookEventName" => "PostToolUse",
                                            "additionalContext" => "lib/calculator.rb:1 " \
                                              "[rubocop/Layout/SpaceAfterComma] expected space" })
  end

  def verify_evidence
    evidence = valid_evidence
    configure_verify_scenario(evidence)
    evidence
  end

  def configure_verify_scenario(evidence)
    evidence["manifest"]["scenario"] = "verify"
    evidence["session"]["stdout"] = verify_transcript
    evidence["hooks"] = verify_hooks(evidence.dig("manifest", "seed_sha256"))
    evidence["manifest"]["baseline"]["verify"] = clean_gate(%w[test_suite undercover])
    evidence["final"]["verify"] = clean_gate(%w[test_suite undercover])
  end

  def verify_transcript
    [
      { "type" => "system", "subtype" => "init", "session_id" => "session-1" },
      claude_tool("verify-edit-1", "Edit", "lib/calculator.rb"),
      claude_tool("verify-edit-2", "Write", "test/calculator_repair_test.rb")
    ].map { JSON.generate(_1) }.join("\n")
  end

  def codex_verify_transcript
    [
      { "type" => "thread.started", "thread_id" => "session-1" },
      codex_file_edit("verify-source", "lib/calculator.rb"),
      codex_file_edit("verify-test", "test/calculator_repair_test.rb")
    ].map { JSON.generate(_1) }.join("\n")
  end

  def codex_verify_hooks(seed)
    shared = { "client" => "codex", "session_id" => "session-1", **timestamps,
               "test_sha256" => { "test/calculator_test.rb" => "b" * 64,
                                  "test/calculator_repair_test.rb" => "c" * 64 } }
    [
      shared.merge("event" => "Stop", "source_sha256" => seed, "status" => 0, "stderr" => "",
                   "stdout" => JSON.generate("decision" => "block",
                                             "reason" =>
                                               "lib/calculator.rb:2 [undercover/uncovered_code] uncovered")),
      shared.merge("event" => "PostToolUse", "tool_name" => "apply_patch",
                   "changed_paths" => ["test/calculator_repair_test.rb"], "source_sha256" => seed,
                   "status" => 0, "stdout" => "{}", "stderr" => ""),
      shared.merge("event" => "Stop", "source_sha256" => seed, "status" => 0, "stderr" => "", "stdout" => "{}")
    ]
  end

  def claude_tool(id, name, path)
    { "type" => "assistant", "message" => { "content" => [
      { "type" => "tool_use", "id" => id, "name" => name, "input" => { "file_path" => path } }
    ] } }
  end

  def verify_hooks(seed)
    [
      { "client" => "claude", "event" => "Stop", "session_id" => "session-1", "source_sha256" => seed,
        "status" => 2, "stderr" => verify_finding_output, "stdout" => "",
        **timestamps, "test_sha256" => { "test/calculator_test.rb" => "b" * 64 },
        "hook_log" => [{ "outcome" => "verify_blocked" }] },
      { "client" => "claude", "event" => "PostToolUse", "session_id" => "session-1", "tool_name" => "Write",
        "tool_use_id" => "verify-edit-2", "source_sha256" => seed, "status" => 0,
        "stderr" => "", "stdout" => "", **timestamps,
        "test_sha256" => { "test/calculator_test.rb" => "b" * 64,
                           "test/calculator_repair_test.rb" => "c" * 64 },
        "hook_log" => [{ "outcome" => "clean" }] },
      { "client" => "claude", "event" => "Stop", "session_id" => "session-1", "source_sha256" => seed,
        "status" => 0, "stderr" => "", "stdout" => "", **timestamps,
        "test_sha256" => { "test/calculator_test.rb" => "b" * 64,
                           "test/calculator_repair_test.rb" => "c" * 64 },
        "hook_log" => [{ "outcome" => "verify_clean" }] }
    ]
  end

  def verify_finding_output
    JSON.generate("findings" => [{ "tool" => "undercover", "file" => "lib/calculator.rb",
                                   "rule" => "uncovered_code", "severity" => "warning",
                                   "message" => "not covered", "line" => 2 }])
  end

  def clean_gate(tools)
    { "status" => 0, "report" => { "findings" => [], "summary" => {
      "findings" => 0, "tool_failures" => 0, "failed_tools" => []
    }, "checks" => tools.map { { "tool" => _1, "status" => "clean" } } } }
  end
end
