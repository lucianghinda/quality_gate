# frozen_string_literal: true

require "test_helper"
require "rbconfig"
require "securerandom"
require "stringio"

module QualityGate
  class RunnerTest < Minitest::Test
    def test_call_continues_after_a_spawn_failure_and_collects_subsequent_findings
      config = Config.new(Config.defaults)
      success_command = ruby_command(<<~RUBY)
        puts "lib/alpha.rb:4:warning:Layout/First"
        puts "lib/beta.rb:8:error:Lint/Second"
      RUBY
      adapters = [
        ProcessBackedAdapter.new(
          name: "missing-tool",
          command: ["missing-tool-#{SecureRandom.hex(6)}"],
          config: config
        ),
        ProcessBackedAdapter.new(
          name: "rubocop",
          command: success_command,
          config: config
        )
      ]

      result = Runner.new(adapters: adapters, config: config).call

      assert_equal 3, result.findings.length
      assert_equal ["missing-tool"], result.failed_tools
      assert result.findings.fetch(0).tool_failure?
      assert_equal %w[tool_failure Layout/First Lint/Second], result.findings.map(&:rule)
      statuses = result.checks.map { _1.fetch(:status) }
      scopes = result.checks.map { _1.fetch(:scope) }
      assert_equal %w[tool_failure findings], statuses
      assert_equal %w[unknown project], scopes
    end

    def test_call_preserves_adapter_order_then_each_tools_order
      config = Config.new(Config.defaults)
      rubocop_command = ruby_command(<<~RUBY)
        puts "lib/a.rb:4:warning:Layout/First"
        puts "lib/b.rb:8:warning:Layout/Second"
      RUBY
      reek_command = ruby_command(<<~RUBY)
        puts "app/a.rb:2:warning:Smell/Third"
        puts "app/b.rb:5:info:Smell/Fourth"
      RUBY
      adapters = [
        ProcessBackedAdapter.new(
          name: "rubocop",
          command: rubocop_command,
          config: config
        ),
        ProcessBackedAdapter.new(
          name: "reek",
          command: reek_command,
          config: config
        )
      ]

      result = Runner.new(adapters: adapters, config: config).call

      assert_equal %w[Layout/First Layout/Second Smell/Third Smell/Fourth], result.findings.map(&:rule)
    end

    def test_call_collects_unique_failed_tools_in_first_seen_order
      config = Config.new(Config.defaults)
      adapters = [
        ReturningFindingsAdapter.new(
          findings: [Finding.tool_failure(tool: "rubocop", message: "failed")],
          config: config
        ),
        ReturningFindingsAdapter.new(
          findings: [Finding.tool_failure(tool: "reek", message: "failed")],
          config: config
        ),
        ReturningFindingsAdapter.new(
          findings: [Finding.tool_failure(tool: "rubocop", message: "failed again")],
          config: config
        )
      ]
      result = Runner.new(adapters: adapters, config: config).call

      assert_equal %w[rubocop reek], result.failed_tools
    end

    def test_runner_copies_the_adapter_list_at_initialization
      config = Config.new(Config.defaults)
      original = [ReturningFindingsAdapter.new(findings: [build_finding(rule: "Only")], config: config)]
      runner = Runner.new(adapters: original, config: config)

      original << ReturningFindingsAdapter.new(findings: [build_finding(rule: "Later")], config: config)

      assert_equal ["Only"], runner.call.findings.map(&:rule)
    end

    def test_result_exit_code_prefers_failed_tools_over_findings
      result = Runner::Result.new(
        findings: [build_finding(rule: "Ordinary"), Finding.tool_failure(tool: "rubocop", message: "failed")]
      )

      assert_equal ExitCode::TOOL_FAILURE, result.exit_code
    end

    def test_result_exit_code_is_findings_when_only_findings_exist
      result = Runner::Result.new(findings: [build_finding(rule: "One"), build_finding(rule: "Two")])

      assert_equal ExitCode::FINDINGS, result.exit_code
    end

    def test_result_exit_code_is_clean_when_empty
      result = Runner::Result.new(findings: [])

      assert_equal ExitCode::CLEAN, result.exit_code
    end

    def test_result_rejects_explicit_failed_tools
      error = assert_raises(ArgumentError) do
        Runner::Result.new(findings: [build_finding(rule: "Ordinary")], failed_tools: [])
      end

      assert_includes error.message, "failed_tools"
    end

    def test_result_derives_unique_failed_tools_in_first_seen_order
      result = Runner::Result.new(
        findings: [
          build_finding(rule: "Ordinary", tool: "other"),
          Finding.tool_failure(tool: "reek", message: "failed"),
          Finding.tool_failure(tool: "rubocop", message: "failed"),
          Finding.tool_failure(tool: "reek", message: "failed again")
        ]
      )

      assert_equal %w[reek rubocop], result.failed_tools
    end

    def test_result_copies_and_freezes_arrays_and_preserves_that_through_with
      finding = Finding.tool_failure(tool: "rubocop", message: "Original")
      findings = [finding]
      result = Runner::Result.new(findings: findings)

      findings << Finding.tool_failure(tool: "reek", message: "Later")

      assert_equal ["tool_failure"], result.findings.map(&:rule)
      assert_equal ["rubocop"], result.failed_tools
      assert result.findings.frozen?
      assert result.failed_tools.frozen?
      assert_raises(FrozenError) { result.findings << build_finding(rule: "Nope") }
      assert_raises(FrozenError) { result.failed_tools.fetch(0).replace("mutated") }

      replacement = String.new("brakeman")
      updated = result.with(
        findings: [Finding.tool_failure(tool: replacement, message: "replacement")]
      )
      replacement.replace("changed elsewhere")

      assert_equal ["brakeman"], updated.failed_tools
      assert_equal ["tool_failure"], updated.findings.map(&:rule)
      assert updated.failed_tools.frozen?
      assert_raises(FrozenError) { updated.failed_tools.fetch(0).replace("mutated") }
      assert_equal ["rubocop"], result.failed_tools
    end

    def test_result_with_rejects_explicit_failed_tools
      result = Runner::Result.new(
        findings: [Finding.tool_failure(tool: "rubocop", message: "failed")]
      )

      error = assert_raises(ArgumentError) do
        result.with(failed_tools: ["rubocop"])
      end

      assert_includes error.message, "failed_tools"
    end

    def test_result_with_recomputes_exit_code_when_failures_are_removed
      result = Runner::Result.new(findings: [Finding.tool_failure(tool: "rubocop", message: "failed")])

      ordinary = result.with(findings: [build_finding(rule: "Ordinary")])
      clean = result.with(findings: [])

      assert_empty ordinary.failed_tools
      assert_equal ExitCode::FINDINGS, ordinary.exit_code
      assert_empty clean.failed_tools
      assert_equal ExitCode::CLEAN, clean.exit_code
      assert_equal ExitCode::TOOL_FAILURE, result.with.exit_code
    end

    def test_result_defaults_to_an_immutable_empty_checks_array_and_preserves_checks_through_with
      result = Runner::Result.new(findings: [])

      assert_empty result.checks
      assert result.checks.frozen?

      checks = [{ tool: String.new("rubocop"), status: "clean", scope: "project", duration_ms: 2 }]
      updated = result.with(checks: checks)
      checks.first[:tool].replace("changed")
      checks << { tool: "reek" }

      assert_equal "rubocop", updated.checks.first.fetch(:tool)
      assert updated.checks.frozen?
      assert updated.checks.first.frozen?
      assert updated.checks.first.fetch(:tool).frozen?
      assert_raises(FrozenError) { updated.checks << { tool: "brakeman" } }
      assert_raises(FrozenError) { updated.checks.first.fetch(:tool).replace("changed") }

      preserved = updated.with(findings: [build_finding(rule: "new")])
      assert_equal updated.checks, preserved.checks
    end

    def test_runner_records_one_check_per_adapter_with_scope_status_and_requested_files
      config = Config.new(Config.defaults.merge(files: ["lib/example.rb"]))
      adapters = [
        ReturningFindingsAdapter.new(
          name: "rubocop",
          findings: [build_finding(rule: "Layout/LineLength")],
          config: config
        ),
        ReturningFindingsAdapter.new(name: "test_suite", findings: [], config: config),
        ReturningFindingsAdapter.new(
          name: "undercover",
          findings: [Finding.new(
            tool: "undercover", file: "", line: 0, rule: "undercover_skipped", severity: :info,
            message: "skipped"
          )],
          config: config
        )
      ]

      diagnostic_io = StringIO.new
      result = Runner.new(adapters: adapters, config: config, diagnostic_io: diagnostic_io).call

      tools = result.checks.map { _1.fetch(:tool) }
      statuses = result.checks.map { _1.fetch(:status) }
      scopes = result.checks.map { _1.fetch(:scope) }
      assert_equal %w[rubocop test_suite undercover], tools
      assert_equal %w[findings clean skipped], statuses
      assert_equal %w[selected_files test_suite git_diff], scopes
      assert_equal ["lib/example.rb"], result.checks.first.fetch(:requested_files)
      assert_empty result.checks.fetch(1).fetch(:requested_files)
      result.checks.each do |check|
        assert_kind_of Numeric, check.fetch(:duration_ms)
        assert_operator check.fetch(:duration_ms), :>=, 0
      end
      assert_equal [
        "Running rubocop (scope: selected_files)...",
        "Running test_suite (scope: test_suite)...",
        "Running undercover (scope: git_diff)..."
      ], diagnostic_io.string.lines(chomp: true)
    end

    def test_runner_reports_project_scope_when_no_files_are_requested
      config = Config.new(Config.defaults)
      adapter = ReturningFindingsAdapter.new(name: "reek", findings: [], config: config)

      result = Runner.new(adapters: [adapter], config: config).call

      assert_equal "project", result.checks.first.fetch(:scope)
      assert_empty result.checks.first.fetch(:requested_files)
    end

    def test_runner_does_not_fail_when_progress_diagnostics_cannot_be_written
      config = Config.new(Config.defaults)
      diagnostic_io = Object.new
      def diagnostic_io.puts(*)
        raise IOError, "closed"
      end

      result = Runner.new(
        adapters: [ReturningFindingsAdapter.new(findings: [], config: config)],
        config: config,
        diagnostic_io: diagnostic_io
      ).call

      assert_empty result.findings
      assert_equal "clean", result.checks.first.fetch(:status)
    end

    private

    def ruby_command(script)
      [RbConfig.ruby, "-e", script]
    end

    def build_finding(rule:, message: nil, **attributes)
      defaults = {
        tool: "rubocop",
        file: "lib/example.rb",
        line: 3,
        severity: :warning
      }

      Finding.new(
        **defaults.merge(attributes).merge(rule: rule, message: message || rule)
      )
    end
  end

  class ProcessBackedAdapter < Adapter
    def initialize(name:, command:, config:)
      super(config: config)
      @name = name
      @command = command
    end

    attr_reader :name, :command

    def parse(stdout)
      stdout.lines(chomp: true).map do |line|
        file, line_number, severity, rule = line.split(":", 4)

        Finding.new(
          tool: name,
          file: file,
          line: Integer(line_number),
          rule: rule,
          severity: severity.to_sym,
          message: rule
        )
      end
    end
  end

  class ReturningFindingsAdapter < Adapter
    attr_reader :name

    def initialize(findings:, config:, name: "returning")
      super(config: config)
      @findings = findings
      @name = name
    end

    def call
      @findings
    end

    def command
      []
    end

    def parse(_stdout)
      []
    end
  end
end
