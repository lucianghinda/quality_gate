# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "rbconfig"
require "stringio"
require "tmpdir"

module QualityGate
  class BaselineIntegrationTest < Minitest::Test
    class StaticAdapter
      class << self
        attr_accessor :findings_by_tool, :calls, :files
      end

      def initialize(name:, findings:, files:)
        @name = name
        @findings = findings
        self.class.calls = self.class.calls.to_i + 1
        self.class.files = files
      end

      attr_reader :name

      def call = @findings
    end

    def setup
      StaticAdapter.findings_by_tool = { "rubocop" => [finding(line: 9)] }
      StaticAdapter.calls = 0
      StaticAdapter.files = nil
    end

    class BaselineCLI < CLI
      class << self
        private

        def adapters_for(subcommand, settings:, **)
          settings.fetch(:adapters).fetch(subcommand.to_sym).map do |name|
            StaticAdapter.new(
              name:, findings: StaticAdapter.findings_by_tool.fetch(name, []), files: settings.fetch(:files)
            )
          end
        end
      end
    end

    class FailedRuboCopStatusCLI < CLI
      class << self
        private

        def adapters_for(subcommand, settings:, config:, diagnostic_io:)
          super.map do |adapter|
            report = JSON.dump("files" => [])
            command = [RbConfig.ruby, "-e", "STDOUT.write(#{report.inspect}); exit 2"]
            adapter.define_singleton_method(:command) { command }
            adapter
          end
        end
      end
    end

    class FailedReekDiagnosticCLI < CLI
      class << self
        private

        def adapters_for(subcommand, **options)
          super.map do |adapter|
            diagnostic = "Source 'broken.rb' cannot be processed by Reek due to a syntax error"
            command = [RbConfig.ruby, "-e", "STDOUT.write('[]'); STDERR.write(#{diagnostic.inspect}); exit 0"]
            adapter.define_singleton_method(:command) { command }
            adapter
          end
        end
      end
    end

    def test_comparison_filters_accepted_findings_from_json_summary
      Dir.mktmpdir do |dir|
        path = File.join(dir, "baseline.json")
        baseline = Baseline.capture(
          gate: "fast",
          tools: ["rubocop"],
          findings: [finding(line: 2)],
          root: dir
        )
        baseline.write(path, create: true)

        status, payload = compare_baseline(path, dir:)

        assert_clean_comparison(status, payload, accepted: 1)
        assert_empty payload.fetch("findings")
        assert_equal "compare", payload.fetch("baseline").fetch("mode")
      end
    end

    def test_unknown_baseline_mode_is_reported_as_a_tool_failure
      Dir.mktmpdir do |dir|
        path = write_baseline(dir, [finding(line: 9)])
        applied = apply_unknown_mode(path, dir)

        assert_equal ["baseline"], applied.failed_tools
        assert_includes applied.findings.last.message, "unsupported baseline mode"
        assert_equal 2, applied.findings.length
      end
    end

    def test_human_reporters_label_baseline_processing
      Dir.mktmpdir do |dir|
        path = write_baseline(dir, [finding(line: 2)])

        labels = { "text" => "Baseline compare: applied, 1 accepted, 0 removed", "markdown" => "Baseline **compare**" }
        labels.each do |format, label|
          status, output, = run_cli(%W[fast --baseline #{path} --format #{format}], dir: dir)

          assert_equal ExitCode::CLEAN, status
          assert_includes output, label
          assert_includes output, "findings"
        end
      end
    end

    def test_comparison_keeps_line_movement_but_accepts_the_same_finding_identity
      Dir.mktmpdir do |dir|
        path = write_baseline(dir, [finding(line: 2)])
        StaticAdapter.findings_by_tool["rubocop"] = [finding(line: 47)]

        status, payload = compare_baseline(path, dir:)

        assert_equal ExitCode::CLEAN, status
        assert_empty payload.fetch("findings")
        assert_equal 1, payload.fetch("baseline").fetch("accepted_count")
      end
    end

    def test_comparison_leaves_new_findings_in_the_enforced_result
      Dir.mktmpdir do |dir|
        path = write_baseline(dir, [finding(line: 2)])
        StaticAdapter.findings_by_tool["rubocop"] = [finding(message: "New message", line: 2)]

        status, payload = compare_baseline(path, dir:)

        assert_equal ExitCode::FINDINGS, status
        assert_equal ["New message"], report_values(payload, "findings", "message")
        assert_equal 1, payload.fetch("summary").fetch("findings")
      end
    end

    def test_comparison_accepts_selected_files_and_keeps_raw_check_status
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib/example.rb"), "# selected\n")
        path = write_baseline(dir, [finding(line: 2)])
        original = File.binread(path)
        File.write(File.join(dir, ".quality_gate.yml"), "baseline:\n  fast: #{File.basename(path)}\n")

        status, payload = run_json(%w[fast --files lib/example.rb --format json], dir:)

        assert_clean_selected_comparison(status, payload)
        assert_equal original, File.binread(path)
      end
    end

    def test_create_baseline_writes_only_eligible_findings
      Dir.mktmpdir do |dir|
        path = File.join(dir, "baseline.json")

        status, output, = run_cli(%W[fast --create-baseline #{path} --format json], dir: dir)
        payload = JSON.parse(output)

        assert_equal ExitCode::CLEAN, status
        assert_equal 1, Baseline.read(path).count
        assert_equal true, payload.fetch("baseline").fetch("written")
        assert_empty payload.fetch("findings")
      end
    end

    def test_ratchet_shrinks_a_clean_baseline_and_reports_removed_count
      Dir.mktmpdir do |dir|
        path = write_baseline(dir, [finding(line: 2), finding(message: "Second", line: 3)])
        StaticAdapter.findings_by_tool["rubocop"] = [finding(line: 9)]

        status, payload = run_json(["fast", "--ratchet-baseline", path, "--format", "json"], dir:)

        assert_ratchet_shrunk(status, payload, path)
      end
    end

    def test_ratchet_refuses_growth_and_preserves_baseline_bytes
      Dir.mktmpdir do |dir|
        path = write_baseline(dir, [finding(line: 2)])
        original = File.binread(path)
        StaticAdapter.findings_by_tool["rubocop"] = [finding(line: 9), finding(message: "New", line: 10)]

        status, payload = run_json(["fast", "--ratchet-baseline", path, "--format", "json"], dir:)
        assert_blocked_ratchet(status, payload, path, original)
      end
    end

    def test_verify_keeps_test_failures_and_coverage_findings_enforced
      Dir.mktmpdir do |dir|
        tools = %w[reek test_suite simplecov]
        matched = finding(tool: "reek", line: 2)
        baseline = Baseline.capture(gate: "verify", tools:, findings: [matched], root: dir)
        path = File.join(dir, "verify-baseline.json")
        baseline.write(path, create: true)
        configure_verify(dir, path)
        StaticAdapter.findings_by_tool = {
          "reek" => [matched],
          "test_suite" => [Finding.tool_failure(tool: "test_suite", message: "test failed")],
          "simplecov" => [coverage_finding]
        }

        status, payload = run_json(%w[verify --format json], dir:)

        assert_protected_verify_report(status, payload)
      end
    end

    def test_create_refuses_protected_verify_findings_and_preserves_them
      Dir.mktmpdir do |dir|
        path = File.join(dir, "verify-baseline.json")
        configure_verify(dir)
        StaticAdapter.findings_by_tool = {
          "reek" => [finding(tool: "reek", line: 2)],
          "test_suite" => [Finding.tool_failure(tool: "test_suite", message: "test failed")],
          "simplecov" => [coverage_finding]
        }

        status, payload = run_json(["verify", "--create-baseline", path, "--format", "json"], dir:)

        assert_equal ExitCode::TOOL_FAILURE, status
        refute_path_exists path
        assert_blocked_create(payload)
      end
    end

    def test_context_drift_fails_without_accepting_findings
      Dir.mktmpdir do |dir|
        path = write_baseline(dir, [finding(line: 2)])
        File.write(File.join(dir, ".quality_gate.yml"), "adapters:\n  fast: [herb]\n")
        StaticAdapter.findings_by_tool = { "herb" => [finding(line: 9)] }

        status, payload = compare_baseline(path, dir:)

        assert_context_failure(status, payload)
      end
    end

    def test_configured_baseline_path_resolves_from_cli_directory
      Dir.mktmpdir do |dir|
        path = write_baseline(dir, [finding(line: 2)])
        File.write(File.join(dir, ".quality_gate.yml"), "baseline:\n  fast: #{File.basename(path)}\n")

        status, output, = run_cli(%w[fast --format json], dir: dir)

        assert_equal ExitCode::CLEAN, status
        assert_empty JSON.parse(output).fetch("findings")
      end
    end

    def test_create_write_failure_reports_baseline_tool_failure
      Dir.mktmpdir do |dir|
        path = File.join(dir, "missing-directory", "baseline.json")

        status, output, = run_cli(["fast", "--create-baseline", path, "--format", "json"], dir: dir)
        payload = JSON.parse(output)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_equal ["baseline"], payload.fetch("summary").fetch("failed_tools")
        assert_equal 2, payload.fetch("findings").length
        refute_path_exists path
      end
    end

    def test_output_failure_does_not_undo_successful_baseline_write
      Dir.mktmpdir do |dir|
        path = File.join(dir, "baseline.json")

        status, = run_cli(["fast", "--create-baseline", path], dir: dir, stdout: BrokenOutput.new)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_equal 1, Baseline.read(path).count
      end
    end

    def test_rubocop_exit_two_with_empty_json_does_not_ratchet_baseline
      Dir.mktmpdir do |dir|
        path = write_baseline(dir, [finding(line: 9)])
        original = File.binread(path)

        status, output, error = run_cli(
          ["fast", "--ratchet-baseline", path, "--format", "json"],
          dir:,
          cli: FailedRuboCopStatusCLI
        )
        payload = JSON.parse(output)

        assert_empty error
        assert_failed_ratchet(status, payload, path, original)
      end
    end

    def test_reek_syntax_diagnostic_blocks_create_and_preserves_ratchet_snapshot
      Dir.mktmpdir do |dir|
        configure_reek_verify(dir)
        create_path = File.join(dir, "created.json")
        status, payload = run_json(
          ["verify", "--create-baseline", create_path, "--format", "json"],
          dir:,
          cli: FailedReekDiagnosticCLI
        )

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_equal ["reek"], payload.fetch("summary").fetch("failed_tools")
        assert_equal false, payload.fetch("baseline").fetch("written")
        refute_path_exists create_path
        assert_reek_ratchet_is_preserved(dir)
      end
    end

    def test_ratchet_keeps_security_and_undercover_findings_enforced
      Dir.mktmpdir do |dir|
        tools = %w[reek undercover brakeman bundler_audit]
        matched = finding(tool: "reek", line: 2)
        path = write_gate_baseline(dir, gate: "verify", tools:, findings: [matched])
        original = File.binread(path)
        prepare_security_findings(dir, tools, matched)

        status, payload = run_json(["verify", "--ratchet-baseline", path, "--format", "json"], dir:)

        assert_blocked_ratchet_findings(status, payload, tools.drop(1))
        assert_equal original, File.binread(path)
      end
    end

    def test_creation_and_ratchet_reject_selected_files_before_running_adapters
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib/example.rb"), "# selected\n")
        %w[--create-baseline --ratchet-baseline].each do |option|
          path = File.join(dir, "baseline-#{option.delete_prefix("--")}.json")
          status, = run_cli(["fast", option, path, "--files", "lib/example.rb"], dir: dir)

          assert_equal ExitCode::TOOL_FAILURE, status
          assert_equal 0, StaticAdapter.calls
        end
      end
    end

    def test_configured_baseline_is_used_and_cli_path_overrides_it
      Dir.mktmpdir do |dir|
        configured = write_baseline(dir, [finding(line: 2)])
        override = write_baseline(dir, [finding(message: "Different", line: 3)])
        File.write(File.join(dir, ".quality_gate.yml"), "baseline:\n  fast: #{configured}\n")

        status, output, = run_cli(%W[fast --baseline #{override} --format json], dir: dir)

        assert_equal ExitCode::FINDINGS, status
        assert_equal 1, JSON.parse(output).fetch("summary").fetch("findings")
      end
    end

    def test_baseline_flags_are_mutually_exclusive_and_limited_to_supported_gates
      Dir.mktmpdir do |dir|
        path = File.join(dir, "baseline.json")
        invalid = [
          %W[fast --baseline #{path} --create-baseline #{path}],
          %W[fast --baseline #{path} --baseline #{path}],
          %W[audit --baseline #{path}],
          %W[deep --create-baseline #{path}]
        ]

        invalid.each do |arguments|
          status, = run_cli(arguments, dir: dir)
          assert_equal ExitCode::TOOL_FAILURE, status
          assert_equal 0, StaticAdapter.calls
        end
      end
    end

    def test_malformed_baseline_is_a_structured_tool_failure
      Dir.mktmpdir do |dir|
        path = File.join(dir, "baseline.json")
        File.write(path, "not json")
        status, output, = run_cli(%W[fast --baseline #{path} --format json], dir: dir)
        payload = JSON.parse(output)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_equal ["baseline"], payload.fetch("summary").fetch("failed_tools")
      end
    end

    def test_missing_baseline_is_a_structured_tool_failure
      Dir.mktmpdir do |dir|
        path = File.join(dir, "missing.json")
        status, output, = run_cli(%W[fast --baseline #{path} --format json], dir: dir)
        payload = JSON.parse(output)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_equal ["baseline"], payload.fetch("summary").fetch("failed_tools")
        assert_equal 2, payload.fetch("findings").length
      end
    end

    private

    def finding(line:, tool: "rubocop", message: "Line is too long")
      Finding.new(
        tool:,
        file: "lib/example.rb",
        line: line,
        rule: "Layout/LineLength",
        severity: :warning,
        message:
      )
    end

    def write_baseline(dir, findings)
      path = File.join(dir, "baseline-#{rand(1_000_000)}.json")
      Baseline.capture(gate: "fast", tools: ["rubocop"], findings:, root: dir).write(path, create: true)
      path
    end

    def write_gate_baseline(dir, gate:, tools:, findings:)
      path = File.join(dir, "#{gate}-baseline.json")
      Baseline.capture(gate:, tools:, findings:, root: dir).write(path, create: true)
      path
    end

    def configure_verify(dir, path = nil)
      baseline = path ? "baseline:\n  verify: #{path}\n" : ""
      File.write(
        File.join(dir, ".quality_gate.yml"),
        "adapters:\n  verify: [reek, test_suite, simplecov]\ncoverage:\n  minimum_line: 90\n#{baseline}"
      )
    end

    def configure_reek_verify(dir)
      File.write(File.join(dir, ".quality_gate.yml"), "adapters:\n  verify: [reek]\n")
    end

    def assert_reek_ratchet_is_preserved(dir)
      path = write_gate_baseline(dir, gate: "verify", tools: ["reek"], findings: [finding(tool: "reek", line: 2)])
      original = File.binread(path)
      status, payload = run_json(
        ["verify", "--ratchet-baseline", path, "--format", "json"], dir:, cli: FailedReekDiagnosticCLI
      )

      assert_equal ExitCode::TOOL_FAILURE, status
      assert_equal ["reek"], payload.fetch("summary").fetch("failed_tools")
      assert_equal false, payload.fetch("baseline").fetch("written")
      assert_equal original, File.binread(path)
    end

    def protected_finding(tool, rule, severity)
      Finding.new(tool:, file: "app/example.rb", line: 5, rule:, severity:, message: "Protected #{rule}")
    end

    def prepare_security_findings(dir, tools, matched)
      File.write(File.join(dir, ".quality_gate.yml"), "adapters:\n  verify: #{tools}\n")
      StaticAdapter.findings_by_tool = {
        "reek" => [matched],
        "undercover" => [protected_finding("undercover", "undercover_skipped", :info)],
        "brakeman" => [protected_finding("brakeman", "Security/Injection", :warning)],
        "bundler_audit" => [protected_finding("bundler_audit", "CVE-2026-0001", :warning)]
      }
    end

    def coverage_finding
      Finding.new(
        tool: "simplecov", file: "", line: 0, rule: "line_coverage_below_minimum",
        severity: :error, message: "Line coverage is below 90%"
      )
    end

    def run_cli(argv, dir:, stdout: StringIO.new, cli: BaselineCLI)
      stderr = StringIO.new
      status = cli.run(argv, stdout:, stderr:, dir:)
      [status, stdout.string, stderr.string]
    end

    def run_json(argv, dir:, cli: BaselineCLI)
      status, output, error = run_cli(argv, dir:, cli:)
      assert_empty error
      [status, JSON.parse(output)]
    end

    def compare_baseline(path, dir:, files: [])
      argv = ["fast", "--baseline", path]
      argv.concat(["--files", *files]) unless files.empty?
      run_json([*argv, "--format", "json"], dir:)
    end

    def report_values(payload, section, key)
      payload.fetch(section).map { _1.fetch(key) }
    end

    def assert_clean_comparison(status, payload, accepted:)
      assert_equal ExitCode::CLEAN, status
      assert_summary_findings(payload, 0)
      assert_equal accepted, payload.fetch("baseline").fetch("accepted_count")
    end

    def assert_blocked_ratchet(status, payload, path, original)
      assert_equal ExitCode::FINDINGS, status
      assert_equal ["New"], report_values(payload, "findings", "message")
      action = payload.fetch("baseline")
      assert_equal [false, "blocked", 1], action.values_at("written", "status", "accepted_count")
      assert_equal original, File.binread(path)
    end

    def assert_clean_selected_comparison(status, payload)
      assert_clean_comparison(status, payload, accepted: 1)
      assert_equal ["lib/example.rb"], StaticAdapter.files
      assert_equal "findings", payload.fetch("checks").first.fetch("status")
      assert_empty payload.fetch("findings")
    end

    def assert_ratchet_shrunk(status, payload, path)
      assert_clean_comparison(status, payload, accepted: 1)
      assert_equal 1, Baseline.read(path).count
      assert_equal [1, true], payload.fetch("baseline").values_at("removed_count", "written")
    end

    def assert_protected_verify_report(status, payload)
      assert_equal ExitCode::TOOL_FAILURE, status
      assert_equal ["test_suite"], payload.fetch("summary").fetch("failed_tools")
      assert_equal %w[test_suite simplecov], report_values(payload, "findings", "tool")
      assert_equal 1, payload.fetch("baseline").fetch("accepted_count")
      assert_equal %w[findings tool_failure findings], report_values(payload, "checks", "status")
    end

    def assert_blocked_create(payload)
      assert_equal 3, payload.fetch("findings").length
      assert_equal false, payload.fetch("baseline").fetch("written")
    end

    def assert_context_failure(status, payload)
      assert_equal ExitCode::TOOL_FAILURE, status
      assert_equal ["baseline"], payload.fetch("summary").fetch("failed_tools")
      assert_equal 2, payload.fetch("findings").length
    end

    def assert_failed_ratchet(status, payload, path, original)
      assert_equal ExitCode::TOOL_FAILURE, status
      assert_equal ["rubocop"], payload.fetch("summary").fetch("failed_tools")
      assert_equal false, payload.fetch("baseline").fetch("written")
      assert_equal original, File.binread(path)
    end

    def assert_blocked_ratchet_findings(status, payload, protected_tools)
      assert_equal ExitCode::FINDINGS, status
      assert_equal protected_tools, report_values(payload, "findings", "tool")
      assert_equal 1, payload.fetch("baseline").fetch("accepted_count")
      assert_equal false, payload.fetch("baseline").fetch("written")
    end

    def assert_summary_findings(payload, count)
      assert_equal count, payload.fetch("summary").fetch("findings")
    end

    def apply_unknown_mode(path, dir)
      run = QualityGate.const_get(:BaselineRun, false).new(
        operation: { mode: :unsupported, path:, root: dir }, gate: "fast", tools: ["rubocop"]
      )
      run.call(Runner::Result.new(findings: [finding(line: 9)]))
    end

    class BrokenOutput < StringIO
      def puts(*) = raise(IOError, "forced output failure")
    end
  end
end
