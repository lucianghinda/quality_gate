# frozen_string_literal: true

require "test_helper"
require "quality_gate/baseline"
require "tmpdir"
require "tempfile"

module QualityGate
  class BaselineTest < Minitest::Test
    def test_capture_groups_eligible_findings_deterministically_and_canonicalizes_paths
      snapshot = Baseline.capture(
        gate: "fast",
        tools: %w[rubocop reek herb brakeman],
        findings: [finding(file: "#{ROOT}/lib/a.rb", line: 9),
                   finding(file: "./lib/a.rb", line: 1)],
        root: ROOT
      )

      assert_equal 2, snapshot.count
      assert_equal [entry(file: "lib/a.rb", count: 2)], snapshot.to_h.fetch("findings")
      assert_equal 1, capture_single_absolute_finding.to_h.fetch("findings").first.fetch("count")
    end

    def test_capture_is_deterministic_across_input_permutations
      first = [finding(file: "lib/z.rb"), finding(tool: "reek", file: "lib/a.rb"), finding]
      second = first.reverse

      assert_equal capture_findings(first).to_h, capture_findings(second).to_h
    end

    def test_capture_excludes_protected_findings_outside_paths_and_unconfigured_tools
      protected = [finding(severity: :error), Finding.tool_failure(tool: "rubocop", message: "failed"),
                   finding(tool: "brakeman"), finding(file: "."), finding(file: "../outside.rb"),
                   finding(file: "#{ROOT}/../outside.rb"), finding(tool: "reek")]

      snapshot = Baseline.capture(gate: "fast", tools: ["rubocop"], findings: protected, root: ROOT)

      assert_empty snapshot.to_h.fetch("findings")
    end

    def test_capture_and_direct_construction_reject_invalid_empty_rule
      invalid_finding = finding(rule: "")

      assert_raises(BaselineError) do
        Baseline.capture(gate: "fast", tools: ["rubocop"], findings: [invalid_finding], root: ROOT)
      end
      assert_raises(BaselineError) do
        Baseline.new(gate: "fast", tools: ["rubocop"], entries: [entry(rule: "")])
      end
    end

    def test_capture_rejects_finding_paths_containing_nul
      error = assert_raises(BaselineError) do
        Baseline.capture(gate: "fast", tools: ["rubocop"], findings: [finding(file: "lib/\0a.rb")], root: ROOT)
      end

      assert_includes error.message, "invalid project root or finding path"
    end

    def test_capture_handles_files_under_filesystem_root
      snapshot = Baseline.capture(
        gate: "fast", tools: ["rubocop"], findings: [finding(file: "/example.rb")], root: "/"
      )

      assert_equal "example.rb", snapshot.to_h.fetch("findings").first.fetch("file")
    end

    def test_capture_rejects_non_array_findings
      assert_raises(BaselineError) do
        Baseline.capture(gate: "fast", tools: ["rubocop"], findings: nil, root: ROOT)
      end
    end

    def test_matching_shrunk_debt_accepts_current_occurrence_and_recapture_shrinks_count
      snapshot = baseline(entries: [entry(count: 2)])
      current = [finding]
      matched = snapshot.match(current, root: ROOT)
      shrunk = Baseline.capture(gate: "fast", tools: %w[rubocop reek], findings: matched.accepted, root: ROOT)

      assert_equal current, matched.accepted
      assert_empty matched.findings
      assert_equal 1, shrunk.to_h.fetch("findings").first.fetch("count")
    end

    def test_match_accepts_only_stored_multiset_count_and_ignores_line_numbers
      snapshot = baseline(entries: [entry(count: 2)])
      current = duplicate_findings + [finding(message: "changed"), finding(file: "lib/b.rb"),
                                      finding(rule: "Other"), finding(severity: :info)]

      result = snapshot.match(current, root: ROOT)

      assert_match_result(result, current)
      assert_equal 2, snapshot.count
    end

    def test_match_does_not_accept_changed_identity_or_protected_findings
      snapshot = baseline(entries: [entry(count: 5)])
      current = [finding(tool: "brakeman"), finding(severity: :error), finding(rule: "Other"),
                 finding(file: "../outside.rb"), finding(file: ""),
                 finding(file: "#{ROOT}/../outside.rb"), Finding.tool_failure(tool: "rubocop", message: "failed")]

      result = snapshot.match(current, root: ROOT)

      assert_empty result.accepted
      assert_equal current, result.findings
    end

    def test_match_does_not_mutate_inputs_or_snapshot
      inputs = [finding(line: 5)]
      snapshot = baseline(entries: [entry(count: 1)])
      before = snapshot.to_h

      snapshot.match(inputs, root: ROOT)

      assert_equal [finding(line: 5)], inputs
      assert_equal before, snapshot.to_h
    end

    def test_capture_rejects_no_eligible_adapter_and_keeps_empty_snapshots_valid
      assert_raises(BaselineError) do
        Baseline.capture(gate: "fast", tools: ["brakeman"], findings: [], root: ROOT)
      end

      snapshot = Baseline.capture(gate: "verify", tools: %w[rubocop brakeman], findings: [], root: ROOT)
      assert_equal 0, snapshot.count
      assert_empty snapshot.to_h.fetch("findings")
    end

    def test_context_must_match_gate_and_tool_order
      snapshot = baseline

      assert_raises(BaselineError) { snapshot.validate_context!(gate: "verify", tools: %w[rubocop reek]) }
      assert_raises(BaselineError) { snapshot.validate_context!(gate: "fast", tools: %w[reek rubocop]) }
      assert_same snapshot, snapshot.validate_context!(gate: "fast", tools: %w[rubocop reek])
    end

    def test_serialization_is_stable_and_round_trips
      snapshot = Baseline.capture(
        gate: "fast", tools: %w[rubocop reek],
        findings: [finding(tool: "reek", file: "b.rb"), finding(file: "a.rb")], root: ROOT
      )

      Dir.mktmpdir do |directory|
        path = File.join(directory, "baseline.json")
        snapshot.write(path, create: true)
        bytes = File.binread(path)

        assert bytes.end_with?("\n")
        assert_equal bytes, serialized(snapshot)
        assert_equal snapshot.to_h, Baseline.read(path).to_h
      end
    end

    def test_atomic_replacement_publishes_serialized_snapshot
      Dir.mktmpdir do |directory|
        path = File.join(directory, "baseline.json")
        File.write(path, "old bytes")
        baseline.write(path, create: false)

        assert_equal serialized(baseline), File.binread(path)
      end
    end

    def test_atomic_replacement_preserves_existing_permission_bits
      Dir.mktmpdir do |directory|
        path = File.join(directory, "baseline.json")
        File.write(path, "old bytes")
        File.chmod(0o640, path)

        baseline.write(path, create: false)

        assert_equal 0o640, File.stat(path).mode & 0o777
      end
    end

    def test_rename_failure_preserves_original_and_cleans_temporary_file
      Dir.mktmpdir do |directory|
        path = File.join(directory, "baseline.json")
        File.write(path, "original")
        assert_failed_rename(path)
        assert_equal "original", File.read(path)
      end
    end

    def test_create_refuses_to_overwrite_even_invalid_existing_file
      Dir.mktmpdir do |directory|
        path = File.join(directory, "baseline.json")
        File.write(path, "broken")

        assert_raises(BaselineError) { baseline.write(path, create: true) }
        assert_equal "broken", File.read(path)
      end
    end

    def test_atomic_replacement_preserves_original_when_temp_write_fails
      Dir.mktmpdir do |directory|
        path = File.join(directory, "baseline.json")
        File.write(path, "original")
        snapshot = baseline
        assert_failed_replace(snapshot, path, directory)
        assert_equal "original", File.read(path)
      end
    end

    def test_read_rejects_malformed_or_noncanonical_documents
      documents = malformed_documents

      Dir.mktmpdir do |directory|
        path = File.join(directory, "baseline.json")
        documents.each do |document|
          File.write(path, document)
          assert_raises(BaselineError, document) { Baseline.read(path) }
        end
      end
    end

    def malformed_documents
      invalid_root_documents + invalid_entry_documents
    end

    def invalid_root_documents
      ["{"] + invalid_root_key_documents + invalid_root_context_documents + invalid_tool_documents
    end

    def invalid_root_key_documents
      [
        JSON.generate("schema_version" => 2, "gate" => "fast", "tools" => ["rubocop"], "findings" => []),
        JSON.generate(baseline.to_h.merge("unexpected" => true)),
        JSON.generate(baseline.to_h.reject { |key, _| key == "gate" }),
        JSON.generate(baseline.to_h.reject { |key, _| key == "findings" }),
        JSON.generate("schema_version" => "1", "gate" => "fast", "tools" => ["rubocop"], "findings" => []),
        JSON.generate("schema_version" => 1.0, "gate" => "fast", "tools" => ["rubocop"], "findings" => [])
      ]
    end

    def invalid_root_context_documents
      [
        JSON.generate(baseline.to_h.merge("gate" => "audit")),
        JSON.generate("schema_version" => 1, "gate" => "fast", "tools" => [], "findings" => [])
      ]
    end

    def invalid_tool_documents
      [
        JSON.generate(baseline.to_h.merge("tools" => %w[rubocop rubocop])),
        JSON.generate(baseline.to_h.merge("tools" => ["rubocop", 2])),
        JSON.generate(baseline.to_h.merge("tools" => "rubocop")),
        JSON.generate(baseline.to_h.merge("findings" => "none"))
      ]
    end

    def invalid_entry_documents
      invalid_entry_counts + invalid_entry_paths + invalid_entry_values + invalid_entry_shapes
    end

    def invalid_entry_counts = [bad_entry(count: 0), bad_entry(count: 1.5), bad_entry(count: -1)]

    def invalid_entry_paths
      [bad_entry(file: "./lib/a.rb"), bad_entry(file: "../a.rb"), bad_entry(file: 12), bad_entry(file: ""),
       bad_entry(file: "/tmp/a.rb"), bad_entry(file: "lib/\0a.rb")]
    end

    def invalid_entry_values
      [
        bad_entry(tool: "brakeman"), bad_entry(rule: ""),
        bad_entry(rule: "tool_failure"), bad_entry(severity: "error"), bad_entry(message: 12),
        missing_configured_tool_entry
      ]
    end

    def invalid_entry_shapes = [non_hash_entry, missing_entry_key, extra_entry_key, duplicate_entry_document]

    def bad_entry(options) = JSON.generate(baseline.to_h.merge("findings" => [entry(options)]))

    def missing_configured_tool_entry
      document = baseline.to_h.merge("tools" => ["rubocop"], "findings" => [entry(tool: "reek")])
      JSON.generate(document)
    end

    def non_hash_entry = JSON.generate(baseline.to_h.merge("findings" => ["not an entry"]))

    def missing_entry_key
      JSON.generate(baseline.to_h.merge("findings" => [entry.reject { |key, _| key == "message" }]))
    end

    def extra_entry_key = JSON.generate(baseline.to_h.merge("findings" => [entry.merge("line" => 3)]))

    def duplicate_entry_document = JSON.generate(baseline.to_h.merge("findings" => [entry, entry]))

    def test_read_reports_missing_file_as_baseline_error
      assert_raises(BaselineError) { Baseline.read("/missing/quality-gate-baseline.json") }
    end

    private

    ROOT = Dir.pwd.freeze

    def finding(options = {})
      attributes = { tool: "rubocop", file: "lib/a.rb", rule: "Style/StringLiterals", severity: :warning,
                     message: "Prefer double quotes", line: 3 }.merge(options)
      Finding.new(**attributes)
    end

    def entry(options = {})
      { "tool" => "rubocop", "file" => "lib/a.rb", "rule" => "Style/StringLiterals", "severity" => "warning",
        "message" => "Prefer double quotes", "count" => 1 }.merge(options.transform_keys(&:to_s))
    end

    def duplicate_findings = [finding(line: 99), finding(line: 1), finding(line: 2)]

    def capture_single_absolute_finding
      Baseline.capture(gate: "fast", tools: %w[rubocop reek],
                       findings: [finding(file: "#{ROOT}/lib/a.rb")], root: ROOT)
    end

    def capture_findings(findings)
      Baseline.capture(gate: "fast", tools: %w[rubocop reek], findings:, root: ROOT)
    end

    def serialized(snapshot) = "#{JSON.pretty_generate(snapshot.to_h, indent: "  ")}\n"

    def assert_match_result(result, current)
      assert_equal current.first(2), result.accepted
      assert_equal current.drop(2), result.findings
      assert result.accepted.frozen?
      assert result.findings.frozen?
    end

    def assert_failed_replace(snapshot, path, directory)
      tempfile = failing_tempfile(directory)
      Tempfile.stub(:create, ->(*, **, &block) { block.call(tempfile) }) do
        assert_raises(BaselineError) { snapshot.write(path, create: false) }
      end
    end

    def failing_tempfile(directory)
      tempfile = Object.new
      tempfile.define_singleton_method(:path) { File.join(directory, "replacement.tmp") }
      tempfile.define_singleton_method(:write) { |_data| raise IOError, "disk full" }
      tempfile.define_singleton_method(:close) {}
      tempfile.define_singleton_method(:unlink) {}
      tempfile
    end

    def assert_failed_rename(path)
      temporary_path = nil
      rename = lambda do |temporary, _destination|
        temporary_path = temporary
        assert_operator File.size(temporary), :>, 0
        raise IOError, "rename failed"
      end
      File.stub(:rename, rename) { assert_raises(BaselineError) { baseline.write(path, create: false) } }
      refute File.exist?(temporary_path)
    end

    def baseline(entries: [entry])
      Baseline.from_h("schema_version" => 1, "gate" => "fast", "tools" => %w[rubocop reek], "findings" => entries)
    end
  end
end
