# frozen_string_literal: true

require "json"
require "pathname"
require "tmpdir"
require "test_helper"

module QualityGate
  module Adapters
    class ReekTest < Minitest::Test
      ROOT = File.expand_path("../../..", __dir__)
      FIXTURES = File.join(ROOT, "test", "fixtures", "reek")

      def test_load_wiring_constants_and_visibility
        assert_equal "reek", build_adapter.name
        assert_equal File.join(ROOT, "config", "reek.yml"), QualityGate::Adapters::Reek::CONFIG_PATH
        assert_predicate QualityGate::Adapters::Reek::CONFIG_PATH, :frozen?
        assert Pathname(QualityGate::Adapters::Reek::CONFIG_PATH).absolute?
        assert_path_exists QualityGate::Adapters::Reek::CONFIG_PATH

        adapter = build_adapter

        assert_raises(NoMethodError) { adapter.existing_paths }
        assert_raises(NoMethodError) { adapter.host_config? }
      end

      def test_command_uses_the_shipped_config_when_the_project_has_no_host_config
        Dir.mktmpdir do |dir|
          Dir.chdir(dir) do
            assert_equal(
              ["reek", "--format", "json", "--config", QualityGate::Adapters::Reek::CONFIG_PATH],
              build_adapter.command
            )
          end
        end
      end

      def test_command_does_not_pass_config_when_the_project_has_dot_reek_yml
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, ".reek.yml"), "detectors: {}\n")

          Dir.chdir(dir) do
            refute_includes build_adapter.command, "--config"
          end
        end
      end

      def test_command_finds_a_host_config_above_the_current_directory
        Dir.mktmpdir do |dir|
          nested = File.join(dir, "lib", "quality_gate")
          Dir.mkdir(File.join(dir, "lib"))
          Dir.mkdir(nested)
          File.write(File.join(dir, ".reek.yml"), "detectors: {}\n")

          Dir.chdir(nested) do
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
          File.write(File.join(dir, ".reek.yml"), "detectors: {}\n")
          File.write(File.join(project, "Gemfile"), "source \"https://rubygems.org\"\n")

          Dir.chdir(nested) do
            assert_includes build_adapter.command, QualityGate::Adapters::Reek::CONFIG_PATH
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
              ["reek", "--format", "json", "--config", QualityGate::Adapters::Reek::CONFIG_PATH, existing],
              command
            )
            refute_includes command, missing
          end
        end
      end

      def test_command_keeps_a_leading_dash_path_positional
        Dir.mktmpdir do |dir|
          path = "--no-progress"
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

      def test_parse_turns_recorded_smells_into_findings_with_context_prefixed_messages
        findings = build_adapter.parse(fixture("smells_report.json"))

        assert_equal expected_findings, findings
      end

      def test_parse_returns_empty_when_the_report_has_no_smells
        assert_equal [], build_adapter.parse("[]")
      end

      def test_parse_raises_parse_error_for_invalid_json
        error = assert_raises(ParseError) { build_adapter.parse("[") }

        assert_equal "reek", error.tool
      end

      def test_parse_raises_parse_error_for_invalid_report_shapes
        invalid_reports = [
          {},
          ["bad"],
          *%w[source smell_type message context lines].map { |key| [valid_smell.except(key)] },
          [valid_smell.merge("lines" => [])],
          [valid_smell.merge("lines" => "5")],
          [valid_smell.merge("lines" => ["5"])],
          [valid_smell.merge("source" => 7)]
        ]

        invalid_reports.each do |report|
          assert_raises(ParseError) { build_adapter.parse(JSON.dump(report)) }
        end
      end

      private

      def build_adapter(config: Config.new(Config.defaults), files: [])
        QualityGate::Adapters::Reek.new(config:, files:)
      end

      def expected_findings
        [
          Finding.new(
            tool: "reek",
            file: "app/models/user_importer.rb",
            line: 5,
            rule: "ControlParameter",
            severity: :warning,
            message: "UserImporter#call is controlled by argument 'flag'"
          ),
          Finding.new(
            tool: "reek",
            file: "app/models/user_importer.rb",
            line: 2,
            rule: "LongParameterList",
            severity: :warning,
            message: "UserImporter#call has 5 parameters"
          ),
          Finding.new(
            tool: "reek",
            file: "app/services/report_builder.rb",
            line: 1,
            rule: "IrresponsibleModule",
            severity: :warning,
            message: "ReportBuilder has no descriptive comment"
          )
        ]
      end

      def valid_smell
        {
          "context" => "UserImporter#call",
          "lines" => [5],
          "message" => "has 5 parameters",
          "smell_type" => "LongParameterList",
          "source" => "app/models/user_importer.rb"
        }
      end

      def fixture(name)
        File.read(File.join(FIXTURES, name))
      end
    end
  end
end
