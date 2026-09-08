# frozen_string_literal: true

require "test_helper"
require "yaml"

module QualityGate
  class ShippedRuboCopConfigTest < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)
    CONFIG_PATH = File.join(ROOT, "config", "rubocop.yml")
    EXPECTED_PLUGINS = [
      "rubocop-rails", "rubocop-performance", "rubocop-minitest",
      { "quality_gate/rubocop" => { "plugin_class_name" => "QualityGate::RuboCopPlugin" } }
    ].freeze
    EXPECTED_EXCLUDES = ["db/schema.rb", "bin/**/*", "node_modules/**/*", "vendor/**/*"].freeze
    EXPECTED_LIMITS = {
      "Metrics/CyclomaticComplexity" => 6,
      "Metrics/AbcSize" => 16,
      "Metrics/MethodLength" => 5,
      "Metrics/ClassLength" => 100,
      "Metrics/ParameterLists" => 4
    }.freeze
    EXPECTED_DISABLED_COPS = %w[Metrics/BlockLength Style/Documentation].freeze
    SANDI_METZ_COP = "QualityGate/ControllerInstanceVariables"

    def test_declares_plugins_target_ruby_and_exclusions
      config = YAML.safe_load_file(CONFIG_PATH)

      assert_equal EXPECTED_PLUGINS, config.fetch("plugins")
      assert_equal "3.2", config.fetch("AllCops").fetch("TargetRubyVersion")
      assert_equal EXPECTED_EXCLUDES, config.fetch("AllCops").fetch("Exclude")
    end

    def test_declares_the_expected_structural_budgets
      config = YAML.safe_load_file(CONFIG_PATH)

      EXPECTED_LIMITS.each do |cop_name, max|
        assert_equal max, config.fetch(cop_name).fetch("Max")
      end
    end

    def test_enables_the_sandi_metz_controller_rule
      config = YAML.safe_load_file(CONFIG_PATH)

      assert_equal true, config.fetch(SANDI_METZ_COP).fetch("Enabled")
    end

    # A path in an inherited gem config resolves against the gem directory, so a
    # relative Exclude here would name this gem's files and silently miss the host's.
    def test_no_cop_section_declares_a_relative_path_filter
      config = YAML.safe_load_file(CONFIG_PATH)
      cop_sections = config.except("AllCops", "plugins")

      offenders = cop_sections.select do |_name, settings|
        settings.is_a?(Hash) && (settings.key?("Exclude") || settings.key?("Include"))
      end

      assert_empty offenders.keys, "path filters belong in the host's own .rubocop.yml"
    end

    def test_disables_only_the_expected_noisy_cops
      config = YAML.safe_load_file(CONFIG_PATH)
      disabled_cops = config.each_with_object([]) do |(cop_name, settings), cops|
        cops << cop_name if settings.is_a?(Hash) && settings["Enabled"] == false
      end

      assert_equal EXPECTED_DISABLED_COPS.sort, disabled_cops.sort
    end

    def test_comments_explain_each_budget_limit_and_disabled_cop
      lines = File.readlines(CONFIG_PATH, chomp: true)
      config = YAML.safe_load_file(CONFIG_PATH)

      configured_limits(config).each do |cop_name, max|
        assert_commented_setting(lines, cop_name, "  Max: #{max}")
      end

      EXPECTED_DISABLED_COPS.each do |cop_name|
        assert_commented_setting(lines, cop_name, "  Enabled: false")
      end
    end

    private

    def configured_limits(config)
      config.each_with_object({}) do |(cop_name, settings), limits|
        limits[cop_name] = settings["Max"] if cop_name.start_with?("Metrics/") && settings.key?("Max")
      end
    end

    def assert_commented_setting(lines, cop_name, setting_line)
      section = lines[section_range(lines, cop_name)]
      setting_index = section.index(setting_line)

      refute_nil setting_index, "expected #{cop_name} to include #{setting_line.inspect}"

      comment_line = section[setting_index - 1]
      message = "expected a nearby explanatory comment above #{cop_name} #{setting_line.inspect}"
      assert_match(/\A  #\s+\S/, comment_line, message)
    end

    def section_range(lines, cop_name)
      start_index = lines.index("#{cop_name}:")
      refute_nil start_index, "expected config section for #{cop_name}"

      end_index = lines[(start_index + 1)..].index { |line| line.match?(/\A[^#\s][^:]+:\s*\z/) }
      finish = end_index ? start_index + end_index : lines.length - 1

      start_index..finish
    end
  end
end
