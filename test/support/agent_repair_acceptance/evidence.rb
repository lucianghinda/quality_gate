# frozen_string_literal: true

require "json"
require "time"

module AgentRepairAcceptance
  # Classifies a single native repair trial without treating configuration or text as proof.
  class Evidence
    def self.exit_status(result)
      { "automatic_repair_observed" => 0, "not_observed" => 1, "unavailable" => 2 }.fetch(result.fetch("outcome"), 2)
    end

    def initialize(evidence)
      @evidence = evidence
    end

    def call
      return result("unavailable", ["invalid evidence schema"]) unless valid_schema?

      failures = failure_reasons
      result(outcome_for(failures), failures)
    rescue StandardError => e
      warn "Evidence evaluation failed: #{e.class}: #{e.message}" if ENV["AGENT_REPAIR_DEBUG"] == "1"
      result("unavailable", ["evidence could not be evaluated"])
    end

    def valid_manifest_for_session?(manifest)
      valid_manifest?(manifest) && %w[fast verify].all? do |name|
        clean_gate?(manifest.dig("baseline", name), name)
      end
    end

    private

    attr_reader :evidence

    def valid_schema?
      return false unless evidence.is_a?(Hash)

      valid_manifest?(evidence["manifest"]) && valid_session?(evidence["session"]) &&
        valid_hooks?(evidence["hooks"]) &&
        valid_final?(evidence["final"])
    end

    def valid_hooks?(hooks)
      hooks.is_a?(Array) && hooks.all? { valid_hook?(_1) }
    end

    def valid_manifest?(manifest)
      return false unless manifest.is_a?(Hash)

      manifest["schema_version"] == 1 && valid_manifest_identity?(manifest) && valid_manifest_files?(manifest)
    end

    def valid_manifest_identity?(manifest)
      valid_client_scenario?(manifest) && valid_source_seed?(manifest) && valid_head?(manifest["head"])
    end

    def valid_manifest_files?(manifest)
      valid_package?(manifest["package"]) && valid_manifest_metadata?(manifest)
    end

    def valid_client_scenario?(manifest)
      %w[claude codex].include?(manifest["client"]) && %w[fast verify].include?(manifest["scenario"])
    end

    def valid_package?(package)
      package.is_a?(Hash) && package["version"].is_a?(String) && digest?(package["sha256"]) &&
        package["resolved_path"].is_a?(String)
    end

    def valid_source_seed?(manifest)
      manifest["source_path"] == "lib/calculator.rb" && digest?(manifest["seed_sha256"])
    end

    def valid_manifest_metadata?(manifest)
      valid_baseline_shape?(manifest["baseline"]) && valid_protected_files?(manifest["protected_files"]) &&
        manifest["head"].is_a?(String) && valid_time?(manifest["prepared_at"]) && manifest["root"].is_a?(String) &&
        manifest["prompt"].is_a?(String)
    end

    def valid_baseline_shape?(baseline)
      baseline.is_a?(Hash) && %w[fast verify].all? { baseline[_1].is_a?(Hash) }
    end

    def valid_head?(head)
      head.is_a?(String) && head.match?(/\A[0-9a-f]{40,64}\z/)
    end

    def valid_protected_files?(files)
      files.is_a?(Hash) && !files.empty? && files.all? { |path, hash| path.is_a?(String) && digest?(hash) }
    end

    def valid_final?(final)
      return false unless final.is_a?(Hash)

      keys = %w[behavior protected_files_unchanged allowed_mutations_only head_unchanged]
      keys.all? { [true, false].include?(final[_1]) } && %w[fast verify].all? { final[_1].is_a?(Hash) }
    end

    def valid_hook?(hook)
      return false unless hook.is_a?(Hash)

      valid_hook_identity?(hook) && valid_hook_payload?(hook)
    end

    def valid_hook_identity?(hook)
      %w[client event session_id started_at completed_at stdout stderr].all? { hook[_1].is_a?(String) } &&
        %w[claude codex].include?(hook["client"]) && %w[PostToolUse Stop].include?(hook["event"]) &&
        valid_hook_action?(hook) && valid_hook_times?(hook)
    end

    def valid_hook_times?(hook)
      valid_time?(hook["started_at"]) && valid_time?(hook["completed_at"]) &&
        Time.iso8601(hook["started_at"]) <= Time.iso8601(hook["completed_at"])
    rescue ArgumentError
      false
    end

    def valid_hook_payload?(hook)
      hook["status"].is_a?(Integer) && digest?(hook["source_sha256"]) && valid_test_digests?(hook["test_sha256"]) &&
        (hook["hook_log"].nil? || hook["hook_log"].is_a?(Array))
    end

    def valid_hook_action?(hook)
      optional_string?(hook["tool_name"]) && optional_string?(hook["tool_use_id"])
    end

    def optional_string?(value)
      value.nil? || value.is_a?(String)
    end

    def valid_test_digests?(files)
      files.is_a?(Hash) && files.all? { |path, hash| path.is_a?(String) && digest?(hash) }
    end

    def valid_session?(session)
      session.is_a?(Hash) && session["kind"] == "native" && valid_session_metadata?(session) &&
        valid_session_times?(session) && session["status"].is_a?(Integer) && valid_session_result?(session)
    end

    def valid_session_metadata?(session)
      session["client_version"].is_a?(String) && session["command"].is_a?(Array) &&
        session["command"].all? { _1.is_a?(String) } && session["stdout"].is_a?(String) &&
        session["stderr"].is_a?(String)
    end

    def valid_session_result?(session)
      [true, false].include?(session["timed_out"]) && session["extra_prompts"].is_a?(Integer)
    end

    def valid_session_times?(session)
      valid_time?(session["started_at"]) && valid_time?(session["completed_at"]) &&
        Time.iso8601(session["started_at"]) <= Time.iso8601(session["completed_at"])
    rescue ArgumentError
      false
    end

    def failure_reasons
      checks = [
        [session_clean?, "trial timed out or did not complete cleanly"],
        [baseline_clean?, "baseline gates were not clean with expected checks"],
        [native_edits_valid?, "native transcript does not prove the required edit sequence"],
        [feedback_valid?, "hook feedback is missing, unmatched, or does not contain a finding"],
        [final_hook_clean?, "hook verification did not finish cleanly after repair"],
        [final_clean?, "final gates, behavior, or protected state changed"]
      ]
      checks.filter_map { |passed, reason| reason unless passed }
    end

    def outcome_for(failures)
      return "unavailable" if unavailable?

      failures.empty? ? "automatic_repair_observed" : "not_observed"
    end

    def session_clean?
      session = evidence.fetch("session")
      session.fetch("status").zero? && !session.fetch("timed_out") && session.fetch("extra_prompts").zero?
    end

    def baseline_clean?
      %w[fast verify].all? { clean_gate?(evidence.dig("manifest", "baseline", _1), _1) }
    end

    def final_clean?
      final = evidence.fetch("final")
      %w[fast verify].all? { clean_gate?(final[_1], _1) } && final["behavior"] == true &&
        final["protected_files_unchanged"] == true && final["allowed_mutations_only"] == true &&
        final["head_unchanged"] == true
    end

    def clean_gate?(gate, name)
      return false unless gate.is_a?(Hash) && gate["status"].is_a?(Integer) && gate["status"].zero?

      clean_report?(gate["report"], name)
    end

    def clean_report?(report, name)
      return false unless report.is_a?(Hash) && report["findings"] == []
      return false unless clean_summary?(report["summary"])

      checks = report["checks"]
      expected_tools = name == "fast" ? %w[rubocop] : %w[test_suite undercover]
      checks_match?(checks, expected_tools)
    end

    def checks_match?(checks, expected_tools)
      return false unless checks.is_a?(Array) && checks.all? { _1.is_a?(Hash) }

      checks.map { _1["tool"] }.sort == expected_tools.sort && checks.all? { _1["status"] == "clean" }
    end

    def clean_summary?(summary)
      summary.is_a?(Hash) && summary["tool_failures"].is_a?(Integer) && summary["tool_failures"].zero? &&
        summary["failed_tools"] == []
    end

    def native_edits_valid?
      edits = native_edits
      edits && mutation_scope_valid?(edits) && scenario_sequence?(edits)
    end

    def mutation_scope_valid?(edits)
      paths = edits.map { _1.fetch("path") }.uniq
      return paths.all? { _1 == "lib/calculator.rb" } if evidence.dig("manifest", "scenario") == "fast"

      paths.all? do |path|
        path == "lib/calculator.rb" ||
          (test_source?(path) && File.basename(path).end_with?("_test.rb"))
      end
    end

    def scenario_sequence?(edits)
      evidence.dig("manifest", "scenario") == "fast" ? fast_repair_sequence?(edits) : verify_repair_sequence?(edits)
    end

    def fast_repair_sequence?(edits)
      source_edits = edits.select { _1.fetch("path") == "lib/calculator.rb" }
      return false unless source_edits.length >= 2

      initial = seeded_feedback_hook(source_edits.first, "PostToolUse")
      repair = repaired_edit_hook(source_edits.last)
      initial && repair && evidence.fetch("hooks").index(initial) < evidence.fetch("hooks").index(repair) &&
        clean_fast_hook?(repair)
    end

    def verify_repair_sequence?(edits)
      first_source = edits.find { _1["path"] == "lib/calculator.rb" }
      test_edit = edits.find { test_source?(_1["path"]) }
      return false unless first_source && test_edit

      initial = seeded_feedback_hook(first_source, "Stop")
      repair = repaired_edit_hook(test_edit)
      initial && repair && ordered_hooks?(initial, repair)
    end

    def test_source?(path)
      path.start_with?("test/") && path.end_with?(".rb") && !evidence.dig("manifest", "protected_files").key?(path)
    end

    def seeded_feedback_hook(edit, expected_event)
      evidence.fetch("hooks").find { seed_feedback_hook?(_1, edit, expected_event) }
    end

    def seed_feedback_hook?(hook, edit, expected_event)
      return false unless hook_for_action?(hook, edit, expected_event)
      return false unless hook["source_sha256"] == evidence.dig("manifest", "seed_sha256")
      return false unless hook["synthetic"] != true && hook["client"] == evidence.dig("manifest", "client")

      finding_feedback?(hook)
    end

    def hook_for_action?(hook, edit, event)
      hook.is_a?(Hash) && hook["event"] == event && hook["session_id"] == edit["session_id"] &&
        (event == "Stop" || action_matches?(hook, edit, event))
    end

    def finding_feedback?(hook)
      scenario = evidence.dig("manifest", "scenario")
      tool, rule = scenario == "fast" ? %w[rubocop Layout/SpaceAfterComma] : %w[undercover uncovered_code]
      expected_finding?(hook, tool, rule) && (scenario == "fast" || verify_blocked?(hook))
    end

    def verify_blocked?(hook)
      if evidence.dig("manifest", "client") == "codex"
        codex_stop_blocked?(hook)
      else
        hook_logs(hook).any? { _1["outcome"] == "verify_blocked" }
      end
    end

    def codex_stop_blocked?(hook)
      return false unless hook["event"] == "Stop"

      response = JSON.parse(hook["stdout"])
      response.is_a?(Hash) && response["decision"] == "block"
    rescue JSON::ParserError, TypeError
      false
    end

    def repaired_edit_hook(edit)
      evidence.fetch("hooks").find do |hook|
        next false unless native_repair_record?(hook, edit)

        repair_digest?(hook, edit)
      end
    end

    def native_repair_record?(hook, edit)
      hook.is_a?(Hash) && hook["session_id"] == edit["session_id"] && hook["synthetic"] != true &&
        hook["client"] == evidence.dig("manifest", "client") && action_matches?(hook, edit, "PostToolUse")
    end

    def repair_digest?(hook, edit)
      if evidence.dig("manifest", "scenario") == "verify"
        digest?(hook.dig("test_sha256",
                         edit["path"])) && !evidence.dig("manifest", "protected_files").key?(edit["path"])
      else
        hook["source_sha256"] != evidence.dig("manifest", "seed_sha256")
      end
    end

    def ordered_hooks?(initial, repair)
      return false unless initial && repair

      initial_index = evidence.fetch("hooks").index(initial)
      repair_index = evidence.fetch("hooks").index(repair)
      stop_index = evidence.fetch("hooks").index { clean_stop_hook?(_1) }
      initial_index < repair_index && repair_index < stop_index
    end

    def clean_fast_hook?(hook)
      return false unless hook["status"].is_a?(Integer) && hook["status"].zero? &&
                          clean_hook_output?(client_hook_output(hook))

      evidence.dig("manifest", "client") == "codex" || hook_logs(hook).any? { _1["outcome"] == "clean" }
    end

    def client_hook_output(hook)
      evidence.dig("manifest", "client") == "claude" ? hook["stderr"] : hook["stdout"]
    end

    def action_matches?(hook, edit, event)
      return false unless hook["event"] == event

      native_tool_matches?(hook, edit)
    end

    def native_tool_matches?(hook, edit)
      return hook_matches_edit?(hook, edit) if evidence.dig("manifest", "client") == "claude"

      hook["tool_name"] == "apply_patch" && codex_patch_observes?(hook, edit["path"])
    end

    def codex_patch_observes?(hook, path)
      Array(hook["changed_paths"]).include?(path)
    end

    def native_edits
      client = evidence.dig("manifest", "client")
      rows = parse_jsonl(evidence.dig("session", "stdout"))
      return unless rows

      client == "claude" ? claude_edits(rows) : codex_edits(rows)
    end

    def claude_edits(rows)
      session_id = claude_session_id(rows)
      return unless session_id

      rows.flat_map do |row|
        claude_row_edits(row, session_id)
      end
    end

    def claude_session_id(rows)
      ids = rows.filter_map { _1["session_id"] if _1["type"] == "system" && _1["subtype"] == "init" }.uniq
      ids.first if ids.one?
    end

    def claude_row_edits(row, session_id)
      return [] unless row["type"] == "assistant" && row.dig("message", "content").is_a?(Array)

      row.dig("message", "content").filter_map { claude_tool_edit(_1, session_id) }
    end

    def claude_tool_edit(item, session_id)
      return unless item["type"] == "tool_use" && %w[Edit Write].include?(item["name"])

      path = normalized_native_path(item.dig("input", "file_path"))
      { "path" => path, "session_id" => session_id, "tool_name" => item["name"],
        "tool_use_id" => item["id"] }
    end

    def codex_edits(rows)
      thread_id = codex_thread_id(rows)
      return unless thread_id

      rows.flat_map do |row|
        codex_row_edits(row, thread_id)
      end
    end

    def codex_thread_id(rows)
      ids = rows.filter_map { _1["thread_id"] if _1["type"] == "thread.started" }.uniq
      ids.first if ids.one?
    end

    def codex_row_edits(row, thread_id)
      return [] unless row["type"] == "item.completed" && row.dig("item", "type") == "file_change"

      changes = Array(row.dig("item", "changes"))
      changes = [nil] if changes.empty?
      changes.map do |change|
        path = normalized_native_path(change.is_a?(Hash) ? change["path"] : nil)
        { "path" => path, "session_id" => thread_id, "tool_name" => "file_change",
          "tool_use_id" => row.dig("item", "id") }
      end
    end

    def normalized_native_path(path)
      return unless path.is_a?(String)

      root = File.expand_path(evidence.dig("manifest", "root"))
      absolute = File.expand_path(path, root)
      prefix = "#{root}#{File::SEPARATOR}"
      absolute.start_with?(prefix) ? absolute.delete_prefix(prefix) : absolute
    end

    def feedback_valid?
      native_edits_valid?
    end

    def final_hook_clean?
      return false if unavailable_hook_log?

      evidence.dig("manifest", "scenario") == "fast" ? fast_hook_seen_cleanly? : successful_stop_hook?
    end

    def fast_hook_seen_cleanly?
      edits = native_edits
      source_edit = edits&.select { _1["path"] == "lib/calculator.rb" }&.last
      source_edit && repaired_edit_hook(source_edit)&.then { clean_fast_hook?(_1) }
    end

    def unavailable_hook_log?
      evidence.fetch("hooks").flat_map { hook_logs(_1) }.any? do |log|
        %w[verify_unavailable verify_cap verify_debounced unavailable].include?(log["outcome"])
      end
    end

    def successful_stop_hook?
      session_id = native_edits&.first&.fetch("session_id")
      evidence.fetch("hooks").any? { stop_hook_for_session?(_1, session_id) }
    end

    def stop_hook_for_session?(hook, session_id)
      return false unless clean_stop_candidate?(hook, session_id)

      evidence.dig("manifest", "client") == "codex" || hook_logs(hook).any? { _1["outcome"] == "verify_clean" }
    end

    def clean_stop_candidate?(hook, session_id)
      trusted_stop_hook?(hook, session_id) && clean_hook_output?(hook["stdout"])
    end

    def trusted_stop_hook?(hook, session_id)
      stop_event_success?(hook) && hook_trusted_for_session?(hook, session_id)
    end

    def stop_event_success?(hook)
      hook.is_a?(Hash) && hook["event"] == "Stop" && hook["status"].is_a?(Integer) && hook["status"].zero?
    end

    def hook_trusted_for_session?(hook, session_id)
      hook["synthetic"] != true && hook["client"] == evidence.dig("manifest", "client") &&
        hook["session_id"] == session_id
    end

    def clean_stop_hook?(hook)
      stop_hook_for_session?(hook, native_edits&.first&.fetch("session_id"))
    end

    def hook_logs(hook)
      return [] unless hook.is_a?(Hash)

      Array(hook["hook_log"]).select { _1.is_a?(Hash) }
    end

    def hook_matches_edit?(hook, edit)
      hook["tool_name"] == edit["tool_name"] &&
        (edit["tool_use_id"].nil? || hook["tool_use_id"] == edit["tool_use_id"])
    end

    def expected_finding?(hook, tool, rule)
      output = evidence.dig("manifest", "client") == "claude" ? hook["stderr"] : hook["stdout"]
      return false unless output.is_a?(String)

      report_finding?(output, tool, rule) || formatted_finding?(output, tool, rule)
    end

    def report_finding?(output, tool, rule)
      report = JSON.parse(output)
      Array(report["findings"]).any? do |finding|
        finding.is_a?(Hash) && finding["tool"] == tool && finding["rule"] == rule &&
          finding["file"].to_s.end_with?(evidence.dig("manifest", "source_path"))
      end
    rescue JSON::ParserError, TypeError
      false
    end

    def formatted_finding?(output, tool, rule)
      response = JSON.parse(output)
      text = response["hookSpecificOutput"]&.fetch("additionalContext", nil) || response["reason"]
      return false unless text.is_a?(String)

      text.lines.any? { formatted_line_matches?(_1, tool, rule) }
    rescue JSON::ParserError, TypeError
      false
    end

    def formatted_line_matches?(line, tool, rule)
      match = line.match(%r{\A(.+?):\d+ \[([^/]+)/([^\]]+)\] .+\z})
      match && match[1].end_with?(evidence.dig("manifest", "source_path")) && match[2..] == [tool, rule]
    end

    def clean_hook_output?(output)
      return true if output.empty?

      value = JSON.parse(output)
      value.is_a?(Hash) && !value.key?("systemMessage") && !value.key?("decision") &&
        !value.dig("hookSpecificOutput", "additionalContext").to_s.include?("unavailable")
    rescue JSON::ParserError, TypeError
      false
    end

    def parse_jsonl(output)
      return unless output.is_a?(String) && !output.empty?

      output.lines.map { JSON.parse(_1) }
    rescue JSON::ParserError
      nil
    end

    def unavailable?
      session = evidence.fetch("session")
      session["timed_out"] || !session["status"].zero? || hooks_unavailable?
    end

    def hooks_unavailable?
      evidence.fetch("hooks").any? { unavailable_hook?(_1) }
    end

    def unavailable_hook?(hook)
      return false unless hook.is_a?(Hash)

      invalid_hook_status?(hook) || unavailable_output?(hook["stdout"]) || unavailable_output?(hook["stderr"]) ||
        hook_log_unavailable?(hook)
    end

    def invalid_hook_status?(hook)
      return false if hook["status"].is_a?(Integer) && hook["status"].zero?

      !valid_claude_feedback_status?(hook)
    end

    def valid_claude_feedback_status?(hook)
      evidence.dig("manifest", "client") == "claude" && hook["status"] == 2 && finding_feedback?(hook)
    end

    def hook_log_unavailable?(hook)
      Array(hook["hook_log"]).any? do |log|
        log.is_a?(Hash) && %w[verify_unavailable verify_cap verify_debounced unavailable].include?(log["outcome"])
      end
    end

    def unavailable_output?(output)
      output.to_s.match?(/unavailable|continuation limit|retry limit/i)
    end

    def digest?(value)
      value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
    end

    def valid_time?(value)
      value.is_a?(String) && !value.empty? && Time.iso8601(value)
    rescue ArgumentError
      false
    end

    def result(outcome, reasons)
      { "outcome" => outcome, "reasons" => reasons, **result_metadata,
        "observations" => observations, "recorded_at" => Time.now.utc.iso8601 }
    end

    def result_metadata
      manifest = evidence.is_a?(Hash) ? evidence["manifest"] : nil
      manifest = {} unless manifest.is_a?(Hash)
      { "client" => manifest["client"], "scenario" => manifest["scenario"] }
    end

    def observations
      { "hook_count" => hook_count, **session_observations, **seed_observations }
    end

    def hook_count
      evidence.is_a?(Hash) ? Array(evidence["hooks"]).length : 0
    end

    def session_observations
      session = evidence_value("session")
      session = {} unless session.is_a?(Hash)
      { "session_status" => session["status"], **session_dates(session) }
    end

    def session_dates(session)
      { "session_started_at" => session["started_at"], "session_completed_at" => session["completed_at"] }
    end

    def source_digests(manifest)
      { "seed_sha256" => manifest["seed_sha256"] }
    end

    def seed_observations
      manifest = evidence_value("manifest")
      manifest = {} unless manifest.is_a?(Hash)
      source_digests(manifest)
    end

    def evidence_value(key)
      evidence.is_a?(Hash) ? evidence[key] : nil
    end
  end
end
