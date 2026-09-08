# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

module QualityGate
  class CustomCopsIntegrationTest < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)
    COP = "QualityGate/AssociationDefaultBlockValue"
    SANDI_METZ_COP = "QualityGate/ControllerInstanceVariables"
    CONVENTION_COPS = %W[
      #{COP}
      QualityGate/PreferAfterSaveCommit
      QualityGate/PrivateOnlyConcern
      QualityGate/BroadcastInController
    ].freeze
    CONTROLLER = "app/controllers/things_controller.rb"

    def test_optional_preset_reports_custom_cops
      with_config("inherit_from: #{ROOT}/config/37signals.yml\n") do |directory|
        report = inspect_source(directory)

        assert_includes report.fetch("files").flat_map { |file| file.fetch("offenses") }
                              .map { |offense| offense.fetch("cop_name") }, COP
      end
    end

    def test_host_configuration_can_load_and_enable_one_cop
      with_config(<<~YAML) do |directory|
        plugins:
          - quality_gate/rubocop:
              plugin_class_name: QualityGate::RuboCopPlugin
        #{COP}:
          Enabled: true
      YAML
        report = inspect_source(directory)

        assert_equal([COP], report.fetch("files").first.fetch("offenses").map { |offense| offense["cop_name"] })
      end
    end

    def test_shipped_configuration_leaves_the_convention_cops_disabled
      with_config("inherit_from: #{ROOT}/config/rubocop.yml\n") do |directory|
        assert_empty reported_cops(directory) & CONVENTION_COPS
      end
    end

    def test_shipped_configuration_enables_the_sandi_metz_controller_rule
      with_config("inherit_from: #{ROOT}/config/rubocop.yml\n") do |directory|
        assert_includes reported_cops(directory, path: CONTROLLER), SANDI_METZ_COP
      end
    end

    def test_adapter_reports_custom_cop_names_without_tool_failures
      with_config("inherit_from: #{ROOT}/config/37signals.yml\n") do |directory|
        config = Config.new(Config.defaults.merge(rubocop_config: File.join(directory, ".rubocop.yml")))
        findings = Dir.chdir(directory) do
          Adapters::RuboCop.new(config: config, files: ["record.rb"]).call
        end

        assert(findings.any? { |finding| finding.rule == COP }, findings.inspect)
        refute(findings.any? { |finding| finding.rule == Finding::TOOL_FAILURE_RULE })
      end
    end

    private

    def with_config(configuration)
      Dir.mktmpdir do |directory|
        directory = File.realpath(directory)
        File.write(File.join(directory, ".rubocop.yml"),
                   "AllCops:\n  NewCops: disable\n  UseCache: false\n#{configuration}")
        File.write(File.join(directory, "record.rb"), "belongs_to :creator, default: Current.user\n")
        write_controller(directory)
        yield directory
      end
    end

    def write_controller(directory)
      path = File.join(directory, CONTROLLER)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "class ThingsController\n  def show\n    @thing = 1\n    @extra = 2\n  end\nend\n")
    end

    def reported_cops(directory, path: "record.rb")
      report = inspect_source(directory, only: nil, path: path)
      report.fetch("files").flat_map { |file| file.fetch("offenses") }.map { |offense| offense.fetch("cop_name") }
    end

    def inspect_source(directory, only: COP, path: "record.rb")
      command = ["bundle", "exec", "rubocop", "--config", File.join(directory, ".rubocop.yml"),
                 "--cache", "false", "--format", "json"]
      command.concat(["--only", only]) if only
      stdout, stderr, status = Open3.capture3(*command, File.join(directory, path), chdir: ROOT)
      assert_includes [0, 1], status.exitstatus, stderr
      JSON.parse(stdout)
    end
  end
end
