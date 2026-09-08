# frozen_string_literal: true

require "test_helper"

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require "yaml"

module QualityGate
  # Exercises the shipped verify pipeline in a real temporary Git/Minitest host.
  class VerifyIntegrationTest < Minitest::Test
    def test_covered_change_is_clean_and_proves_the_suite_runs_before_undercover
      in_host_project do |dir|
        write_calculator(dir, include_subtract: true)
        write_test(dir, test_subtract: true)

        status, report, stderr = run_verify(dir)

        assert_equal ExitCode::CLEAN, status, "report: #{report.inspect}; stderr: #{stderr.inspect}"
        assert_empty report.fetch("findings")
        assert_empty stderr
        assert File.file?(File.join(dir, Adapters::Undercover::COVERAGE_PATH))
      end
    end

    # rubocop:disable Metrics/AbcSize
    def test_uncovered_changed_method_reports_its_file_and_full_range
      in_host_project do |dir|
        write_calculator(dir, include_subtract: true)

        status, report, stderr = run_verify(dir)

        assert_equal ExitCode::FINDINGS, status, "report: #{report.inspect}; stderr: #{stderr.inspect}"
        assert_empty stderr
        findings = report.fetch("findings")
        assert_equal 1, findings.length
        finding = findings.fetch(0)
        assert_equal "undercover", finding.fetch("tool")
        assert_equal "lib/calculator.rb", finding.fetch("file")
        assert_equal "uncovered_code", finding.fetch("rule")
        assert_equal 6, finding.fetch("line")
        assert_includes finding.fetch("message"), "lines 6-8"
        assert_includes finding.fetch("message"), "uncovered lines"
      end
    end
    # rubocop:enable Metrics/AbcSize

    def test_failing_suite_does_not_hide_the_uncovered_change
      in_host_project do |dir|
        write_calculator(dir, include_subtract: true)
        write_test(dir, failing: true)

        status, report, stderr = run_verify(dir)

        assert_equal ExitCode::FINDINGS, status, "report: #{report.inspect}; stderr: #{stderr.inspect}"
        assert_empty stderr
        findings = report.fetch("findings")
        assert_ordered_finding_types(findings)
        assert_failure_messages(findings)
      end
    end

    def test_missing_record_after_a_passing_suite_is_a_wiring_failure
      in_host_project(coverage: false) do |dir|
        status, report, stderr = run_verify(dir)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stderr
        finding = report.fetch("findings").fetch(0)
        assert_equal "undercover", finding.fetch("tool")
        assert_equal "tool_failure", finding.fetch("rule")
        assert_includes finding.fetch("message"), "SimpleCov"
        assert_includes finding.fetch("message"), "quality_gate:install"
      end
    end

    private

    def in_host_project(coverage: true)
      Dir.mktmpdir do |dir|
        write_config(dir)
        write_test_helper(dir, coverage:)
        write_calculator(dir)
        write_test(dir)
        initialize_repository(dir)
        yield dir
      end
    end

    def write_config(dir)
      settings = {
        "commands" => {
          "verify" => {
            "test_suite" => [RbConfig.ruby, "-Itest", "test/calculator_test.rb"]
          }
        }
      }
      File.write(File.join(dir, ".quality_gate.yml"), YAML.dump(settings))
    end

    def write_test_helper(dir, coverage:)
      FileUtils.mkdir_p(File.join(dir, "test"))
      coverage_setup = if coverage
                         <<~RUBY
                           if ENV["COVERAGE"] == "1"
                             require "simplecov"
                             require "undercover/simplecov_formatter"
                             SimpleCov.formatter = SimpleCov::Formatter::Undercover
                             SimpleCov.start do
                               enable_coverage :branch
                               add_filter "/test/"
                             end
                           end
                         RUBY
                       else
                         ""
                       end
      File.write(
        File.join(dir, "test", "test_helper.rb"),
        "#{coverage_setup}require \"minitest/autorun\"\n"
      )
    end

    def write_calculator(dir, include_subtract: false)
      FileUtils.mkdir_p(File.join(dir, "lib"))
      subtract = if include_subtract
                   <<~RUBY

                     def self.subtract(left, right)
                       left - right
                     end
                   RUBY
                 else
                   ""
                 end
      File.write(
        File.join(dir, "lib", "calculator.rb"),
        <<~RUBY
          module Calculator
            def self.add(left, right)
              left + right
            end
          #{subtract}end
        RUBY
      )
    end

    def write_test(dir, test_subtract: false, failing: false)
      subtract_test = if test_subtract
                        <<~RUBY

                          def test_subtract
                            assert_equal 2, Calculator.subtract(5, 3)
                          end
                        RUBY
                      else
                        ""
                      end
      expected = failing ? 4 : 3
      File.write(
        File.join(dir, "test", "calculator_test.rb"),
        <<~RUBY
          require_relative "test_helper"
          require_relative "../lib/calculator"

          class CalculatorTest < Minitest::Test
            def test_add
              assert_equal #{expected}, Calculator.add(1, 2)
            end
          #{subtract_test}end
        RUBY
      )
    end

    def initialize_repository(dir)
      git(dir, "init", "--initial-branch", "main")
      git(dir, "add", "--all")
      git(
        dir,
        "-c", "user.name=Quality Gate Test",
        "-c", "user.email=quality-gate@example.test",
        "commit", "--quiet", "-m", "base"
      )
      git(dir, "checkout", "--quiet", "-b", "feature")
    end

    def run_verify(dir)
      stdout = StringIO.new
      stderr = StringIO.new
      status = Dir.chdir(dir) do
        CLI.run(%w[verify --format json], stdout:, stderr:, dir:)
      end

      [status, JSON.parse(stdout.string), stderr.string]
    end

    def git(dir, *arguments)
      _stdout, stderr, status = Open3.capture3("git", *arguments, chdir: dir)
      assert_predicate status, :success?, "git #{arguments.join(" ")} failed: #{stderr}"
    end

    def assert_ordered_finding_types(findings)
      assert_equal(%w[test_suite undercover], findings.map { _1.fetch("tool") })
      assert_equal(%w[test_failure uncovered_code], findings.map { _1.fetch("rule") })
    end

    def assert_failure_messages(findings)
      assert_includes findings.fetch(0).fetch("message"), "Failure"
      assert_includes findings.fetch(1).fetch("message"), "lines 6-8"
    end
  end
end
