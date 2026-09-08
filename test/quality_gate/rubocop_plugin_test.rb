# frozen_string_literal: true

require "test_helper"
require "quality_gate/rubocop"
require "yaml"

module QualityGate
  class RuboCopPluginTest < Minitest::Test
    def test_plugin_identifies_the_gem_and_supports_only_rubocop
      plugin = RuboCopPlugin.new

      assert_equal "quality_gate", plugin.about.name
      assert_equal VERSION, plugin.about.version
      assert plugin.supported?(Struct.new(:engine).new(:rubocop))
      refute plugin.supported?(Struct.new(:engine).new(:other))
    end

    CONVENTION_COPS = %w[
      QualityGate/AssociationDefaultBlockValue
      QualityGate/PreferAfterSaveCommit
      QualityGate/PrivateOnlyConcern
      QualityGate/BroadcastInController
    ].freeze
    SANDI_METZ_COP = "QualityGate/ControllerInstanceVariables"

    def test_plugin_registers_every_cop_disabled_by_default
      rules = RuboCopPlugin.new.rules(nil)
      configuration = YAML.safe_load_file(rules.value)

      assert_equal :rubocop, rules.config_format
      assert_equal :path, rules.type
      assert_equal CONVENTION_COPS + [SANDI_METZ_COP], configuration.keys
      assert(configuration.values.all? { |settings| settings["Enabled"] == false })
    end

    # The Sandi Metz rule is a shipped default, not a 37signals convention.
    def test_preset_enables_the_convention_cops_and_claims_no_others
      preset = YAML.safe_load_file(RuboCopPlugin.new.rules(nil).value.dirname.join("37signals.yml"))

      CONVENTION_COPS.each { |name| assert_equal true, preset.fetch(name).fetch("Enabled"), name }
      refute_includes preset.keys, SANDI_METZ_COP
    end
  end
end
