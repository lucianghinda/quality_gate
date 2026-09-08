# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "stringio"
require "tmpdir"

module QualityGate
  module Adapters
    class SimpleCovTest < Minitest::Test
      class SubprocessGuardSimpleCov < SimpleCov
        private

        def capture(*)
          raise "SimpleCov adapter must not run a subprocess"
        end
      end

      def test_load_wiring
        assert(
          Object.const_defined?("QualityGate::Adapters::SimpleCov"),
          "expected QualityGate::Adapters::SimpleCov to be loaded"
        )
      end

      def test_name
        assert_equal "simplecov", build_adapter.name
      end

      def test_line_coverage_below_minimum_returns_a_contract_shaped_finding
        findings = call_with_record({ "result" => { "line" => 90.0 } }, minimum_line: 95)

        assert_equal [
          Finding.new(
            tool: "simplecov",
            file: "",
            line: 0,
            severity: :error,
            rule: "line_coverage_below_minimum",
            message: "line coverage 90.0% is below configured minimum 95%"
          )
        ], findings
      end

      def test_line_coverage_equal_to_minimum_passes
        assert_empty call_with_record({ "result" => { "line" => 90 } }, minimum_line: 90)
      end

      def test_branch_only_budget_returns_only_a_branch_finding
        findings = call_with_record(
          { "result" => { "line" => 92, "branch" => 80 } },
          minimum_branch: 85
        )

        assert_equal ["branch_coverage_below_minimum"], findings.map(&:rule)
        assert_equal "branch coverage 80% is below configured minimum 85%", findings.first.message
      end

      def test_independent_line_and_branch_budgets_return_both_misses
        findings = call_with_record(
          { "result" => { "line" => 89, "branch" => 79 } },
          minimum_line: 90,
          minimum_branch: 80
        )

        assert_equal %w[line_coverage_below_minimum branch_coverage_below_minimum], findings.map(&:rule)
      end

      def test_missing_branch_data_names_the_required_branch_wiring
        findings = call_with_record({ "result" => { "line" => 95 } }, minimum_branch: 80)

        assert_one_tool_failure(findings)
        assert_includes findings.first.message, "enable_coverage :branch"
      end

      def test_missing_branch_data_retains_an_independent_line_budget_miss
        findings = call_with_record(
          { "result" => { "line" => 89 } },
          minimum_line: 90,
          minimum_branch: 80
        )

        assert_equal ["line_coverage_below_minimum", Finding::TOOL_FAILURE_RULE], findings.map(&:rule)
        assert_includes findings.last.message, "enable_coverage :branch"
      end

      def test_missing_record_returns_one_tool_failure_naming_simplecov_wiring
        Dir.mktmpdir do |dir|
          findings = Dir.chdir(dir) { build_adapter(minimum_line: 90).call }

          assert_simplecov_wiring_failure(findings)
        end
      end

      def test_invalid_json_returns_one_tool_failure_naming_simplecov_wiring
        with_record("{") do
          assert_simplecov_wiring_failure(build_adapter(minimum_line: 90).call)
        end
      end

      def test_unreadable_record_returns_one_tool_failure_naming_simplecov_wiring
        Dir.mktmpdir do |dir|
          record_path = File.join(dir, "coverage", ".last_run.json")
          FileUtils.mkdir_p(record_path)

          findings = Dir.chdir(dir) { build_adapter(minimum_line: 90).call }

          assert_simplecov_wiring_failure(findings)
        end
      end

      def test_structurally_unusable_records_return_one_tool_failure_naming_simplecov_wiring
        invalid_records = [
          [],
          {},
          { "result" => nil },
          { "result" => {} },
          { "result" => { "line" => "90" } },
          { "result" => { "line" => -1 } },
          { "result" => { "line" => 101 } }
        ]

        invalid_records.each do |record|
          call_with_record(record, minimum_line: 90).then do |findings|
            assert_simplecov_wiring_failure(findings)
          end
        end
      end

      private

      def build_adapter(**coverage)
        settings = Config.defaults.merge(coverage: coverage)
        SubprocessGuardSimpleCov.new(
          config: Config.new(settings),
          files: ["ignored.rb"],
          diagnostic_io: StringIO.new
        )
      end

      def call_with_record(record, **coverage)
        with_record(JSON.generate(record)) { build_adapter(**coverage).call }
      end

      def with_record(contents)
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "coverage"))
          File.write(File.join(dir, "coverage", ".last_run.json"), contents)
          Dir.chdir(dir) { return yield }
        end
      end

      def assert_one_tool_failure(findings)
        assert_equal 1, findings.length
        finding = findings.first
        assert finding.tool_failure?
        assert_equal "simplecov", finding.tool
        assert_equal "", finding.file
        assert_equal 0, finding.line
        assert_equal :error, finding.severity
      end

      def assert_simplecov_wiring_failure(findings)
        assert_one_tool_failure(findings)
        assert_includes findings.first.message, "coverage/.last_run.json"
        assert_includes findings.first.message, "SimpleCov.start"
      end
    end
  end
end
