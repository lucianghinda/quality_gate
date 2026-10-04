# frozen_string_literal: true

require "json"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require "test_helper"

module QualityGate
  class DatabaseConsistencyIntegrationTest < Minitest::Test
    RUNNER = File.expand_path("../../lib/quality_gate/database_consistency_runner.rb", __dir__)

    def test_normal_require_does_not_load_the_analyzer_or_boot_the_app
      refute($LOADED_FEATURES.any? { _1.include?("/gems/database_consistency-") })
      refute($LOADED_FEATURES.any? { _1.end_with?("/config/boot.rb") })
    end

    def test_missing_rails_boot_is_an_actionable_tool_failure
      Dir.mktmpdir do |dir|
        stdout, stderr, status = run_bridge(dir)

        assert_equal 2, status.exitstatus
        assert_empty stdout
        assert_includes stderr, "config/boot.rb"
      end
    end

    def test_bridge_keeps_boot_and_analyzer_chatter_off_stdout
      with_app do |dir, library|
        stdout, stderr, status = run_bridge(dir, library:)

        assert_equal 0, status.exitstatus
        envelope = JSON.parse(stdout)
        assert_equal 1, envelope.fetch("version")
        assert_equal "3.0.14", envelope.fetch("analyzer_version")
        assert_equal [], envelope.fetch("reports")
        refute_includes stdout, "boot chatter"
        assert_includes stderr, "boot chatter"
        assert_includes stderr, "analyzer chatter"
      end
    end

    def test_bridge_serializes_public_report_readers_instead_of_to_h
      report_json = JSON.dump([
                                {
                                  "checker_name" => "UniqueIndex",
                                  "table_or_model_name" => "User",
                                  "column_or_attribute_name" => "email",
                                  "status" => "fail",
                                  "error_slug" => "missing_unique_index",
                                  "error_message" => nil,
                                  "source_location" => "app/models/user.rb:23"
                                }
                              ])
      with_app do |dir, library|
        stdout, stderr, status = run_bridge(dir, library:, reports: report_json)

        assert_equal 0, status.exitstatus, stderr
        report = JSON.parse(stdout).fetch("reports").first
        assert_equal "UniqueIndex", report.fetch("checker_name")
        assert_equal "app/models/user.rb:23", report.fetch("source_location")
        refute report.key?("incorrect_to_h_payload")
      end
    end

    def test_cli_reports_all_database_consistency_statuses_in_each_format
      reports = [
        report_hash("fail", "missing_unique_index"),
        report_hash("warning", "possible_null"),
        report_hash("ok", nil)
      ]
      with_app do |dir, library|
        assert_cli_formats(dir, library, reports, ExitCode::FINDINGS)
      end
    end

    def test_cli_returns_clean_in_all_formats_for_empty_reports
      with_app do |dir, library|
        assert_cli_formats(dir, library, [], ExitCode::CLEAN)
      end
    end

    def test_cli_returns_tool_failure_in_all_formats_for_rescued_checker_errors
      with_app(rescue_error: true) do |dir, library|
        assert_cli_formats(dir, library, [], ExitCode::TOOL_FAILURE)
      end
    end

    def test_invalid_files_fail_before_the_database_consistency_bridge_runs
      with_app(boot_error: true) do |dir, library|
        with_cli_environment(library:, reports: "[]") do
          Dir.chdir(dir) do
            stdout = StringIO.new
            stderr = StringIO.new
            status = CLI.run(%w[audit --files missing.rb --format json], stdout:, stderr:, dir:)

            assert_equal ExitCode::TOOL_FAILURE, status
            assert_includes JSON.parse(stdout.string).fetch("findings").first.fetch("message"), "missing.rb"
            refute_includes stdout.string, "app boot failed"
          end
        end
      end
    end

    def test_cli_keeps_database_consistency_in_configured_audit_order
      with_app do |dir, library|
        File.write(
          File.join(dir, ".quality_gate.yml"),
          "adapters:\n  audit:\n    - before\n    - database_consistency\n    - after\n"
        )
        with_cli_environment(library:, reports: "[]") do
          Dir.chdir(dir) do
            stdout = StringIO.new
            status = CLI.run(%w[audit --format json], stdout:, stderr: StringIO.new, dir:)
            tools = JSON.parse(stdout.string).fetch("checks").map { _1.fetch("tool") }

            assert_equal ExitCode::TOOL_FAILURE, status
            assert_equal %w[before database_consistency after], tools
          end
        end
      end
    end

    def test_bridge_fails_if_database_consistency_rescued_a_checker_error
      with_app(rescue_error: true) do |dir, library|
        stdout, stderr, status = run_bridge(dir, library:)

        assert_equal 2, status.exitstatus
        assert_empty stdout
        assert_includes stderr, "rescued a checker error"
      end
    end

    def test_bridge_rejects_unsupported_analyzer_versions
      with_app(version: "3.1.0") do |dir, library|
        stdout, stderr, status = run_bridge(dir, library:)

        assert_equal 2, status.exitstatus
        assert_empty stdout
        assert_includes stderr, "install ~> 3.0.14"
      end
    end

    def test_bridge_reports_when_the_optional_analyzer_is_missing
      with_app do |dir, _library|
        stdout, stderr, status = run_bridge(dir)

        assert_equal 2, status.exitstatus
        assert_empty stdout
        assert_includes stderr, "database_consistency"
        assert_includes stderr, "LoadError"
      end
    end

    def test_bridge_turns_app_boot_exceptions_into_actionable_failures
      with_app(boot_error: true) do |dir, library|
        stdout, stderr, status = run_bridge(dir, library:)

        assert_equal 2, status.exitstatus
        assert_empty stdout
        assert_includes stderr, "app boot failed"
      end
    end

    def test_bridge_turns_rails_eager_load_exceptions_into_actionable_failures
      with_app(eager_load_error: true) do |dir, library|
        stdout, stderr, status = run_bridge(dir, library:)

        assert_equal 2, status.exitstatus
        assert_empty stdout
        assert_includes stderr, "eager load failed"
      end
    end

    private

    def with_app(version: "3.0.14", rescue_error: false, boot_error: false, eager_load_error: false)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        library = File.join(dir, "fake_gems")
        FileUtils.mkdir_p(library)
        File.write(File.join(dir, "config", "boot.rb"), "puts 'boot chatter'\n")
        environment = if boot_error
                        "raise 'app boot failed'\n"
                      elsif eager_load_error
                        <<~RUBY
                          module Rails
                            class Application
                              def eager_load!; raise 'eager load failed'; end
                            end
                            def self.application; @application ||= Application.new; end
                          end
                        RUBY
                      else
                        <<~RUBY
                          module Rails
                            class Application
                              def eager_load!; puts 'eager load chatter'; end
                            end
                            def self.application; @application ||= Application.new; end
                          end
                        RUBY
                      end
        File.write(File.join(dir, "config", "environment.rb"), environment)
        File.write(File.join(library, "database_consistency.rb"), fake_analyzer(version, rescue_error))
        File.write(File.join(dir, ".quality_gate.yml"),
                   "adapters:\n  audit:\n    - database_consistency\ntimeouts:\n  default: 5\n")
        yield dir, library
      end
    end

    def fake_analyzer(version, rescue_error)
      <<~RUBY
        require "rubygems"
        puts "analyzer chatter"
        spec = Gem::Specification.new("database_consistency", "#{version}")
        Gem.loaded_specs["database_consistency"] = spec
        module DatabaseConsistency
          class Configuration
            def initialize; puts "configuration chatter"; end
          end
          class RescueError
            def self.empty?; #{!rescue_error}; end
          end
          module Processors
            Report = Struct.new(:checker_name, :table_or_model_name, :column_or_attribute_name, :status,
                                :error_slug, :error_message, :source_location, keyword_init: true) do
              def to_h; { incorrect_to_h_payload: true }; end
            end
            def self.reports(_configuration)
              JSON.parse(ENV.fetch("QUALITY_GATE_FAKE_REPORTS", "[]")).map do |attributes|
                Report.new(**attributes.transform_keys(&:to_sym))
              end
            end
          end
        end
      RUBY
    end

    def run_bridge(dir, library: nil, reports: "[]")
      env = library ? { "RUBYLIB" => library, "QUALITY_GATE_FAKE_REPORTS" => reports } : {}
      Open3.capture3(env, RbConfig.ruby, RUNNER, chdir: dir)
    end

    def assert_cli_formats(dir, library, reports, expected_status)
      with_cli_environment(library:, reports: JSON.dump(reports)) do
        Dir.chdir(dir) do
          %w[text json markdown].each { assert_cli_format(dir, _1, expected_status) }
        end
      end
    end

    def assert_cli_format(dir, format, expected_status)
      stdout = StringIO.new
      stderr = StringIO.new
      status = CLI.run(["audit", "--format", format], stdout:, stderr:, dir:)
      assert_equal expected_status, status, format
      assert_empty stderr.string
      assert_finding_report(stdout.string) if expected_status == ExitCode::FINDINGS
    end

    def assert_finding_report(output)
      assert_includes output, "database_consistency"
      assert_includes output, "missing unique index"
      assert_includes output, "possible null"
    end

    def with_cli_environment(library:, reports:)
      previous_load_path = ENV["RUBYLIB"]
      previous_reports = ENV["QUALITY_GATE_FAKE_REPORTS"]
      ENV["RUBYLIB"] = library
      ENV["QUALITY_GATE_FAKE_REPORTS"] = reports
      yield
    ensure
      ENV["RUBYLIB"] = previous_load_path
      ENV["QUALITY_GATE_FAKE_REPORTS"] = previous_reports
    end

    def report_hash(status, slug)
      {
        "checker_name" => "UniqueIndex",
        "table_or_model_name" => "User",
        "column_or_attribute_name" => "email",
        "status" => status,
        "error_slug" => slug,
        "error_message" => nil,
        "source_location" => nil
      }
    end
  end
end
