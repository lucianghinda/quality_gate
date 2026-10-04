# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "test_helper"
require_relative "../../lib/quality_gate/database_consistency_runner"

module QualityGate
  class DatabaseConsistencyBridgeTest < Minitest::Test
    def test_run_sends_boot_chatter_to_diagnostics_and_restores_global_stdout
      with_app do |directory|
        original_stdout = $stdout
        stdout = StringIO.new
        stderr = StringIO.new

        status = run_bridge(directory, stdout:, stderr:)

        assert_equal 0, status
        assert_same original_stdout, $stdout
        assert_chatter(stderr.string)
        assert_equal bridge_envelope([]), JSON.parse(stdout.string)
        refute_includes stdout.string, "chatter"
      end
    end

    def test_run_serializes_public_report_readers_and_optional_source_location
      reports = [
        {
          "checker_name" => "UniqueIndex",
          "table_or_model_name" => "User",
          "column_or_attribute_name" => "email",
          "status" => "fail",
          "error_slug" => "missing_unique_index",
          "error_message" => "email is not unique",
          "source_location" => "app/models/user.rb:23"
        },
        {
          "checker_name" => "ForeignKey",
          "table_or_model_name" => "Membership",
          "column_or_attribute_name" => "user_id",
          "status" => "ok",
          "error_slug" => nil,
          "error_message" => nil
        }
      ]

      with_app(reports:) do |directory|
        stdout = StringIO.new
        stderr = StringIO.new

        status = run_bridge(directory, stdout:, stderr:)

        assert_equal 0, status, stderr.string
        serialized_reports = JSON.parse(stdout.string).fetch("reports")
        assert_equal reports, serialized_reports
        refute(serialized_reports.any? { _1.key?("incorrect_to_h_payload") })
      end
    end

    def test_run_preserves_previously_loaded_application_constants
      previous_constants = application_constants
      rails, database_consistency = install_application_sentinels

      with_app do |directory|
        status = run_bridge(directory, stdout: StringIO.new, stderr: StringIO.new)

        assert_equal 0, status
      end

      assert_application_sentinels(rails, database_consistency)
    ensure
      restore_application_constants(previous_constants)
    end

    def test_run_reports_missing_boot_file_as_an_actionable_load_error
      with_app(boot_file: false) do |directory|
        stdout = StringIO.new
        stderr = StringIO.new

        status = run_bridge(directory, stdout:, stderr:)

        assert_equal 2, status
        assert_empty stdout.string
        assert_includes stderr.string, "LoadError"
        assert_includes stderr.string, "Rails boot file not found"
      end
    end

    def test_run_returns_failure_when_reporting_to_a_broken_diagnostic_stream
      with_app(boot_file: false) do |directory|
        original_stdout = $stdout
        stdout = StringIO.new
        stderr = Object.new
        stderr.define_singleton_method(:puts) { |_message| raise IOError, "closed diagnostic stream" }

        status = run_bridge(directory, stdout:, stderr:)

        assert_equal 2, status
        assert_empty stdout.string
        assert_same original_stdout, $stdout
      end
    end

    def test_run_reports_when_rails_application_is_unavailable
      environment = "module Rails; def self.application = nil; end\n"
      with_app(environment_source: environment) do |directory|
        original_stdout = $stdout
        stdout = StringIO.new
        stderr = StringIO.new

        status = run_bridge(directory, stdout:, stderr:)

        assert_equal 2, status
        assert_empty stdout.string
        assert_includes stderr.string, "Rails.application is unavailable"
        assert_same original_stdout, $stdout
      end
    end

    def test_run_reports_analyzer_load_errors_and_restores_global_stdout
      with_app(analyzer_source: "raise LoadError, 'analyzer dependency missing'\n") do |directory|
        original_stdout = $stdout
        stdout = StringIO.new
        stderr = StringIO.new

        status = run_bridge(directory, stdout:, stderr:)

        assert_equal 2, status
        assert_empty stdout.string
        assert_includes stderr.string, "LoadError: analyzer dependency missing"
        assert_same original_stdout, $stdout
      end
    end

    def test_run_reports_application_errors_and_restores_global_stdout
      with_app(environment_source: "puts 'partial boot chatter'\nraise 'app boot failed'\n") do |directory|
        original_stdout = $stdout
        stdout = StringIO.new
        stderr = StringIO.new

        status = run_bridge(directory, stdout:, stderr:)

        assert_equal 2, status
        assert_empty stdout.string
        assert_includes stderr.string, "RuntimeError: app boot failed"
        assert_includes stderr.string, "partial boot chatter"
        assert_same original_stdout, $stdout
      end
    end

    def test_run_fails_when_the_analyzer_rescued_a_checker_error
      with_app(rescued_error: true) do |directory|
        stdout = StringIO.new
        stderr = StringIO.new

        status = run_bridge(directory, stdout:, stderr:)

        assert_equal 2, status
        assert_empty stdout.string
        assert_includes stderr.string, "rescued a checker error"
      end
    end

    def test_run_rejects_an_unsupported_analyzer_version
      with_app(version: "3.1.0") do |directory|
        stdout = StringIO.new
        stderr = StringIO.new

        status = run_bridge(directory, stdout:, stderr:)

        assert_equal 2, status
        assert_empty stdout.string
        assert_includes stderr.string, "database_consistency 3.1.0 is unsupported"
        assert_includes stderr.string, "install ~> 3.0.14"
      end
    end

    def test_run_requires_a_loaded_analyzer_gemspec
      with_app(register_gemspec: false) do |directory|
        stdout = StringIO.new
        stderr = StringIO.new

        status = run_bridge(directory, stdout:, stderr:)

        assert_equal 2, status
        assert_empty stdout.string
        assert_includes stderr.string, "did not register a loaded gemspec"
      end
    end

    private

    def run_bridge(directory, stdout:, stderr:)
      $LOAD_PATH.unshift(File.join(directory, "fake_gems"))
      Dir.chdir(directory) do
        DatabaseConsistencyRunner.run(stdout:, stderr:, cwd: directory)
      end
    ensure
      $LOAD_PATH.delete(File.join(directory, "fake_gems"))
    end

    def with_app(**options)
      Dir.mktmpdir("quality-gate-database-consistency-") do |directory|
        write_app_files(directory, options)
        with_restored_application_globals(directory) { yield directory }
      end
    end

    def write_app_files(directory, options)
      config_directory = File.join(directory, "config")
      library_directory = File.join(directory, "fake_gems")
      FileUtils.mkdir_p(config_directory)
      FileUtils.mkdir_p(library_directory)
      write_config_files(config_directory, options)
      write_analyzer_file(library_directory, options)
    end

    def write_config_files(config_directory, options)
      boot_file = options.fetch(:boot_file, true)
      boot_source = options.fetch(:boot_source, "puts 'boot chatter'\n")
      environment_source = options[:environment_source]
      File.write(File.join(config_directory, "boot.rb"), boot_source) if boot_file
      File.write(File.join(config_directory, "environment.rb"), environment_source || rails_environment)
    end

    def write_analyzer_file(library_directory, options)
      analyzer_source = options[:analyzer_source]
      File.write(
        File.join(library_directory, "database_consistency.rb"),
        analyzer_source || fake_analyzer(
          reports: options.fetch(:reports, []),
          version: options.fetch(:version, "3.0.14"),
          rescued_error: options.fetch(:rescued_error, false),
          register_gemspec: options.fetch(:register_gemspec, true)
        )
      )
    end

    def with_restored_application_globals(directory)
      previous_constants = application_constants
      previous_gemspec = Gem.loaded_specs["database_consistency"]
      original_features = $LOADED_FEATURES.dup

      clear_application_globals
      yield
    ensure
      restore_application_constants(previous_constants)
      restore_gemspec(previous_gemspec)
      restore_loaded_features(directory, original_features)
    end

    def application_constants
      %i[Rails DatabaseConsistency].to_h do |name|
        [name, (Object.const_get(name) if Object.const_defined?(name, false))]
      end
    end

    def restore_application_constants(constants)
      constants.each do |name, value|
        Object.send(:remove_const, name) if Object.const_defined?(name, false)
        Object.const_set(name, value) if value
      end
    end

    def clear_application_globals
      clear_application_constants
      Gem.loaded_specs.delete("database_consistency")
    end

    def clear_application_constants
      %i[Rails DatabaseConsistency].each do |name|
        Object.send(:remove_const, name) if Object.const_defined?(name, false)
      end
    end

    def install_application_sentinels
      clear_application_constants
      rails = Class.new { def self.sentinel = :original_rails }
      database_consistency = Module.new { def self.sentinel = :original_analyzer }
      Object.const_set(:Rails, rails)
      Object.const_set(:DatabaseConsistency, database_consistency)
      [rails, database_consistency]
    end

    def assert_application_sentinels(rails, database_consistency)
      assert_same rails, Object.const_get(:Rails)
      assert_equal :original_rails, Rails.sentinel
      assert_same database_consistency, Object.const_get(:DatabaseConsistency)
      assert_equal :original_analyzer, DatabaseConsistency.sentinel
    end

    def restore_gemspec(gemspec)
      if gemspec
        Gem.loaded_specs["database_consistency"] = gemspec
      else
        Gem.loaded_specs.delete("database_consistency")
      end
    end

    def restore_loaded_features(directory, original_features)
      $LOADED_FEATURES.delete_if do |feature|
        feature.start_with?(directory) && !original_features.include?(feature)
      end
    end

    def assert_chatter(diagnostics)
      ["boot chatter", "eager load chatter", "analyzer chatter", "configuration chatter"].each do |message|
        assert_includes diagnostics, message
      end
    end

    def bridge_envelope(reports)
      { "version" => 1, "analyzer_version" => "3.0.14", "reports" => reports }
    end

    def rails_environment
      <<~RUBY
        module Rails
          class Application
            def eager_load! = puts("eager load chatter")
          end

          def self.application = Application.new
        end
      RUBY
    end

    def fake_analyzer(reports:, version:, rescued_error:, register_gemspec:)
      <<~RUBY
        require "json"
        require "rubygems"
        puts "analyzer chatter"
        #{gemspec_source(version, register_gemspec)}

        module DatabaseConsistency
          class Configuration
            def initialize = puts("configuration chatter")
          end

          class RescueError
            def self.empty? = #{!rescued_error}
          end

          module Processors
            FIELDS = %i[
              checker_name table_or_model_name column_or_attribute_name status error_slug error_message
            ].freeze

            class Report
              FIELDS.each { |field| attr_reader(field) }

              def initialize(attributes)
              FIELDS.each { |field| instance_variable_set("@\#{field}", attributes[field.to_s]) }
              end

              def to_h = { incorrect_to_h_payload: true }
            end

            class LocatedReport < Report
              attr_reader :source_location

              def initialize(attributes)
                @source_location = attributes["source_location"]
                super
              end
            end

            def self.reports(_configuration)
              JSON.parse(#{JSON.generate(reports).dump}).map do |attributes|
                report_class = attributes.key?("source_location") ? LocatedReport : Report
                report_class.new(attributes)
              end
            end
          end
        end
      RUBY
    end

    def gemspec_source(version, register_gemspec)
      return unless register_gemspec

      %(Gem.loaded_specs["database_consistency"] = Gem::Specification.new("database_consistency", #{version.dump}))
    end
  end
end
