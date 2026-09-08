# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/mock"
require "open3"
require "rbconfig"
require "test_helper"
require "tmpdir"

module QualityGate
  class RuboCopIntegrationTest < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)
    EXECUTABLE = File.join(ROOT, "exe", "quality_gate")
    FIXTURES = File.join(ROOT, "test", "fixtures", "rubocop_integration")
    METRIC_RULES = %w[
      Metrics/AbcSize
      Metrics/ClassLength
      Metrics/CyclomaticComplexity
      Metrics/MethodLength
    ].freeze

    # rubocop:disable Metrics/AbcSize
    def test_syntax_error_file_returns_an_error_finding_not_a_tool_failure
      with_project("syntax_error.rb") do |project|
        status, report, stderr = run_fast(project, "--format", "json", "--files", "syntax_error.rb")

        assert_equal ExitCode::FINDINGS, status
        assert_empty stderr
        assert_operator report.fetch("findings").length, :>=, 1
        assert report.fetch("findings").any? { |finding| finding.fetch("severity") == "error" }, report.inspect
        has_tool_failure = report.fetch("findings").any? do |finding|
          finding.fetch("rule") == Finding::TOOL_FAILURE_RULE
        end

        refute has_tool_failure, report.inspect
      end
    end
    # rubocop:enable Metrics/AbcSize

    def test_complex_fixture_trips_one_of_the_shipped_metric_limits
      with_project("complex_method.rb") do |project|
        status, report, stderr = run_fast(project, "--format", "json", "--files", "complex_method.rb")

        assert_equal ExitCode::FINDINGS, status
        assert_empty stderr
        assert report.fetch("findings").any? { |finding| METRIC_RULES.include?(finding.fetch("rule")) }, report.inspect
      end
    end

    def test_cli_fast_uses_the_builtin_rubocop_registry_and_reports_findings
      with_project("complex_method.rb") do |project|
        status, stdout, stderr = run_fast_text(project, "--files", "complex_method.rb")

        assert_equal ExitCode::FINDINGS, status
        assert_empty stderr
        assert_includes stdout, "rubocop warning complex_method.rb:"
        assert METRIC_RULES.any? { |rule| stdout.include?(rule) }, stdout
        assert_includes stdout, "tool failures"
      end
    end

    # rubocop:disable Metrics/AbcSize
    def test_cli_bundle_uses_the_temporary_project_gemfile
      with_project("single_file_target.rb") do |project|
        captured_environment = nil
        process_status = Minitest::Mock.new.expect(:exitstatus, ExitCode::CLEAN)
        capture = lambda do |environment, *, chdir:|
          captured_environment = environment
          assert_equal project, chdir
          ["", "", process_status]
        end

        Open3.stub(:capture3, capture) do
          status, = run_fast_text(project, "--files", "single_file_target.rb")

          assert_equal ExitCode::CLEAN, status
        end

        process_status.verify
        assert_equal File.join(project, "Gemfile"), captured_environment.fetch("BUNDLE_GEMFILE")
        assert_includes File.read(File.join(project, "Gemfile")), %(gem "quality_gate", path: #{ROOT.inspect})
      end
    end
    # rubocop:enable Metrics/AbcSize

    def test_invalid_explicit_rubocop_config_becomes_one_tool_failure
      with_project("single_file_target.rb", quality_gate_yaml: "rubocop_config: missing-rubocop.yml\n") do |project|
        status, report, stderr = run_fast(project, "--format", "json", "--files", "single_file_target.rb")

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stderr
        assert_equal 1, report.fetch("summary").fetch("tool_failures")
        assert_equal ["rubocop"], report.fetch("summary").fetch("failed_tools")
        finding_rules = report.fetch("findings").map { |finding| finding.fetch("rule") }

        assert_equal ["tool_failure"], finding_rules
      end
    end

    private

    def with_project(*fixture_names, quality_gate_yaml: nil)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Gemfile"), temporary_project_gemfile)
        File.write(File.join(dir, ".quality_gate.yml"), quality_gate_yaml) if quality_gate_yaml

        fixture_names.each do |fixture_name|
          FileUtils.cp(File.join(FIXTURES, fixture_name), File.join(dir, fixture_name))
        end

        yield dir
      end
    end

    def temporary_project_gemfile
      "source \"https://rubygems.org\"\n\ngem \"quality_gate\", path: #{ROOT.inspect}\n"
    end

    def run_fast(project_dir, *arguments, cache_dir: nil)
      status, stdout, stderr = run_command(project_dir, *arguments, cache_dir:)
      [status, parse_report(stdout, status:, stderr:), stderr]
    end

    def run_fast_text(project_dir, *arguments, cache_dir: nil)
      run_command(project_dir, *arguments, cache_dir:)
    end

    def run_command(project_dir, *arguments, cache_dir: nil)
      return run_command_with_cache(project_dir, *arguments, cache_dir:) if cache_dir

      Dir.mktmpdir do |temporary_cache_dir|
        run_command_with_cache(project_dir, *arguments, cache_dir: temporary_cache_dir)
      end
    end

    def run_command_with_cache(project_dir, *arguments, cache_dir:)
      environment = {
        "BUNDLE_GEMFILE" => File.join(project_dir, "Gemfile"),
        "PATH" => [File.dirname(RbConfig.ruby), ENV.fetch("PATH")].join(File::PATH_SEPARATOR),
        "RUBOCOP_OPTS" => nil,
        "XDG_CACHE_HOME" => cache_dir
      }
      command = [
        RbConfig.ruby,
        Gem.bin_path("bundler", "bundle"),
        "exec",
        RbConfig.ruby,
        EXECUTABLE,
        "fast",
        *arguments
      ]

      stdout, stderr, status = Open3.capture3(environment, *command, chdir: project_dir)

      [status.exitstatus, stdout, stderr]
    end

    def parse_report(stdout, status:, stderr:)
      JSON.parse(stdout)
    rescue JSON::ParserError => e
      flunk(
        "expected valid JSON report, got #{e.message}\n" \
        "status: #{status}\nstdout: #{stdout.inspect}\nstderr: #{stderr.inspect}"
      )
    end
  end
end
