# frozen_string_literal: true

require "json"
require "pathname"
require "rbconfig"
require "tmpdir"
require "test_helper"

module QualityGate
  module Adapters
    class RuboCopTest < Minitest::Test
      ROOT = File.expand_path("../../..", __dir__)
      FIXTURES = File.join(ROOT, "test", "fixtures", "rubocop")

      def test_load_wiring_constants_and_visibility # rubocop:disable Metrics/AbcSize
        assert_equal QualityGate::Adapters::RuboCop, QualityGate::Adapters::RuboCop
        assert_equal "rubocop", build_adapter.name
        assert_equal expected_severity_map, QualityGate::Adapters::RuboCop::SEVERITY_MAP
        assert_predicate QualityGate::Adapters::RuboCop::SEVERITY_MAP, :frozen?
        assert_equal File.join(ROOT, "config", "rubocop.yml"), QualityGate::Adapters::RuboCop::CONFIG_PATH
        assert_predicate QualityGate::Adapters::RuboCop::CONFIG_PATH, :frozen?
        assert Pathname(QualityGate::Adapters::RuboCop::CONFIG_PATH).absolute?

        adapter = build_adapter

        assert_raises(NoMethodError) { adapter.existing_paths }
        assert_raises(NoMethodError) { adapter.host_config? }
      end

      def test_command_uses_the_shipped_config_when_the_project_has_no_host_config
        Dir.mktmpdir do |dir|
          Dir.chdir(dir) do
            assert_equal(
              [
                "rubocop",
                "--format",
                "json",
                "--force-exclusion",
                "--config",
                QualityGate::Adapters::RuboCop::CONFIG_PATH
              ],
              build_adapter.command
            )
          end
        end
      end

      def test_command_does_not_pass_config_when_the_project_has_dot_rubocop_yml
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, ".rubocop.yml"), "AllCops:\n  NewCops: disable\n")

          Dir.chdir(dir) do
            refute_includes build_adapter.command, "--config"
          end
        end
      end

      def test_command_does_not_pass_config_when_the_project_has_official_config_directory_file
        Dir.mktmpdir do |dir|
          config_dir = File.join(dir, ".config", "rubocop")
          Dir.mkdir(File.join(dir, ".config"))
          Dir.mkdir(config_dir)
          File.write(File.join(dir, "Gemfile"), "source \"https://rubygems.org\"\n")
          File.write(File.join(config_dir, "config.yml"), "AllCops:\n  NewCops: disable\n")

          Dir.chdir(dir) do
            refute_includes build_adapter.command, "--config"
          end
        end
      end

      def test_command_does_not_use_a_config_above_the_project_root
        Dir.mktmpdir do |dir|
          project = File.join(dir, "project")
          nested = File.join(project, "lib")
          Dir.mkdir(project)
          Dir.mkdir(nested)
          File.write(File.join(dir, ".rubocop.yml"), "AllCops:\n  NewCops: disable\n")
          File.write(File.join(project, "Gemfile"), "source \"https://rubygems.org\"\n")

          Dir.chdir(nested) do
            assert_includes build_adapter.command, QualityGate::Adapters::RuboCop::CONFIG_PATH
          end
        end
      end

      def test_command_finds_a_host_config_above_the_current_directory
        Dir.mktmpdir do |dir|
          nested = File.join(dir, "lib", "quality_gate")
          Dir.mkdir(File.join(dir, "lib"))
          Dir.mkdir(nested)
          File.write(File.join(dir, ".rubocop.yml"), "AllCops:\n  NewCops: disable\n")

          Dir.chdir(nested) do
            refute_includes build_adapter.command, "--config"
          end
        end
      end

      def test_explicit_config_wins_even_when_the_project_has_a_host_config
        Dir.mktmpdir do |dir|
          explicit_config = File.join(dir, "custom-rubocop.yml")
          File.write(File.join(dir, ".rubocop.yml"), "AllCops:\n  NewCops: disable\n")
          File.write(explicit_config, "AllCops:\n  NewCops: disable\n")

          Dir.chdir(dir) do
            command = build_adapter(config: config_with(rubocop_config: explicit_config)).command

            assert_equal(
              %w[rubocop --format json --force-exclusion] + ["--config", explicit_config],
              command
            )
            assert_equal 1, command.count("--config")
          end
        end
      end

      def test_empty_original_file_list_means_full_project_scan_without_path_arguments
        Dir.mktmpdir do |dir|
          Dir.chdir(dir) do
            command = build_adapter.command

            assert_equal(
              %w[rubocop --format json --force-exclusion] +
                ["--config", QualityGate::Adapters::RuboCop::CONFIG_PATH],
              command
            )
          end
        end
      end

      def test_command_appends_only_existing_requested_paths
        Dir.mktmpdir do |dir|
          existing = File.join(dir, "lib", "example.rb")
          missing = File.join(dir, "lib", "gone.rb")
          Dir.mkdir(File.join(dir, "lib"))
          File.write(existing, "# frozen_string_literal: true\n")

          Dir.chdir(dir) do
            command = build_adapter(files: [existing, missing]).command

            assert_equal(
              %w[rubocop --format json --force-exclusion] +
                ["--config", QualityGate::Adapters::RuboCop::CONFIG_PATH, existing],
              command
            )
            refute_includes command, missing
          end
        end
      end

      def test_command_keeps_a_leading_dash_path_positional
        Dir.mktmpdir do |dir|
          path = "--autocorrect-all"
          File.write(File.join(dir, path), "# frozen_string_literal: true\n")

          Dir.chdir(dir) do
            command = build_adapter(files: [path]).command

            assert_equal "./#{path}", command.last
            refute_includes command, path
          end
        end
      end

      def test_call_returns_empty_without_spawning_when_every_requested_path_is_missing
        Dir.mktmpdir do |dir|
          missing_one = File.join(dir, "missing-one.rb")
          missing_two = File.join(dir, "missing-two.rb")

          Dir.chdir(dir) do
            adapter = build_adapter(files: [missing_one, missing_two])

            adapter.define_singleton_method(:capture) do |_argv, _timeout|
              flunk "capture should not be called when every requested path is missing"
            end

            assert_equal [], adapter.call
          end
        end
      end

      def test_parse_turns_recorded_offenses_into_findings_with_cop_names
        findings = build_adapter.parse(fixture("offenses_report.json"))

        assert_equal expected_findings, findings
      end

      def test_parse_maps_all_rubocop_severities
        findings = build_adapter.parse(fixture("severity_report.json"))

        assert_equal %i[info info warning warning error error], findings.map(&:severity)
      end

      def test_parse_returns_empty_when_the_report_has_no_offenses
        report = JSON.dump({ "files" => [{ "path" => "app/models/user.rb", "offenses" => [] }] })

        assert_equal [], build_adapter.parse(report)
      end

      def test_parse_raises_parse_error_for_invalid_json
        error = assert_raises(ParseError) { build_adapter.parse("{") }

        assert_equal "rubocop", error.tool
      end

      def test_parse_raises_parse_error_for_invalid_report_shapes
        invalid_reports = {
          "missing files" => {},
          "files not array" => { "files" => {} },
          "file entry not hash" => { "files" => ["bad"] },
          "missing file path" => { "files" => [{ "offenses" => [] }] },
          "offenses not array" => { "files" => [{ "path" => "app/models/user.rb", "offenses" => {} }] },
          "offense entry not hash" => { "files" => [{ "path" => "app/models/user.rb", "offenses" => ["bad"] }] },
          "missing location" => report_with(offense_without("location")),
          "start line not integer" => report_with(valid_offense.merge("location" => { "start_line" => "2" })),
          "missing cop name" => report_with(offense_without("cop_name")),
          "missing message" => report_with(offense_without("message"))
        }

        invalid_reports.each_value do |report|
          assert_raises(ParseError) { build_adapter.parse(JSON.dump(report)) }
        end
      end

      def test_parse_raises_parse_error_for_unknown_severity
        report = JSON.dump(
          "files" => [
            {
              "path" => "app/models/user.rb",
              "offenses" => [
                {
                  "location" => { "start_line" => 2 },
                  "cop_name" => "Style/StringLiterals",
                  "severity" => "unknown",
                  "message" => "bad"
                }
              ]
            }
          ]
        )

        assert_raises(ParseError) { build_adapter.parse(report) }
      end

      def test_parse_does_not_hide_adapter_programming_errors
        adapter = build_adapter
        adapter.define_singleton_method(:parse_files) { |_files| raise "adapter bug" }

        error = assert_raises(RuntimeError) { adapter.parse('{"files":[]}') }

        assert_equal "adapter bug", error.message
      end

      private

      def build_adapter(config: Config.new(Config.defaults), files: [])
        QualityGate::Adapters::RuboCop.new(config:, files:)
      end

      def config_with(**settings)
        Config.new(Config.defaults.merge(settings))
      end

      def expected_severity_map
        {
          "info" => :info,
          "refactor" => :info,
          "convention" => :warning,
          "warning" => :warning,
          "error" => :error,
          "fatal" => :error
        }
      end

      def expected_findings
        [
          Finding.new(
            tool: "rubocop",
            file: "app/models/user.rb",
            line: 2,
            rule: "Style/StringLiterals",
            severity: :warning,
            message: "Prefer single-quoted strings when you don't need string interpolation."
          ),
          Finding.new(
            tool: "rubocop",
            file: "app/models/user.rb",
            line: 8,
            rule: "Lint/UselessAssignment",
            severity: :error,
            message: "Useless assignment to variable - value."
          ),
          Finding.new(
            tool: "rubocop",
            file: "app/services/report_builder.rb",
            line: 14,
            rule: "Metrics/MethodLength",
            severity: :warning,
            message: "Method has too many lines. [14/12]"
          )
        ]
      end

      def report_with(offense)
        { "files" => [{ "path" => "app/models/user.rb", "offenses" => [offense] }] }
      end

      def offense_without(key)
        valid_offense.tap { |offense| offense.delete(key) }
      end

      def valid_offense
        {
          "location" => { "start_line" => 2 },
          "cop_name" => "Style/StringLiterals",
          "severity" => "warning",
          "message" => "bad"
        }
      end

      def fixture(name)
        File.read(File.join(FIXTURES, name))
      end
    end
  end
end
