# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module QualityGate
  class ConfigTest < Minitest::Test
    def test_absent_file_uses_defaults
      Dir.mktmpdir do |dir|
        config = Config.load(dir: dir)

        assert_equal Config.defaults, config.to_h
        assert_nil config.path
        assert_empty config.unknown_keys
      end
    end

    def test_format_override_preserves_other_defaults
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".quality_gate.yml"), "format: json\n")

        config = Config.load(dir: dir)

        assert_equal Config.defaults.merge(format: "json"), config.to_h
      end
    end

    def test_gates_is_an_unknown_key
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".quality_gate.yml"), "gates:\n  - verify\n")

        config = Config.load(dir: dir)

        assert_equal ["gates"], config.unknown_keys
        refute config.to_h.key?(:gates)
      end
    end

    def test_nested_command_override_preserves_other_commands
      Dir.mktmpdir do |dir|
        File.write(
          File.join(dir, ".quality_gate.yml"),
          "commands:\n  fast:\n    lint:\n      - bin/lint\n"
        )

        config = Config.load(dir: dir)

        assert_equal({ lint: ["bin/lint"] }, config.fetch(:commands).fetch(:fast))
        assert_equal({ test_suite: %w[bin/rails test] }, config.fetch(:commands).fetch(:verify))
        assert_equal({}, config.fetch(:commands).fetch(:audit))
      end
    end

    # rubocop:disable Metrics/AbcSize
    def test_defaults_include_adapters_and_timeouts
      Dir.mktmpdir do |dir|
        config = Config.load(dir: dir)

        assert_equal(
          { fast: ["rubocop"], verify: %w[reek test_suite undercover], audit: %w[brakeman bundler_audit] },
          config.fetch(:adapters)
        )
        assert_equal(
          { default: 120, rubocop: 10, test_suite: 120, undercover: 120 },
          config.fetch(:timeouts)
        )
        assert_equal %w[bin/rails test], config.fetch(:commands).fetch(:verify).fetch(:test_suite)
        assert_nil config.fetch(:compare_point)
        assert_nil config.fetch(:rubocop_config)
        assert_nil config.fetch(:coverage)
        assert config.fetch(:adapters).values.all?(&:frozen?)
      end
    end
    # rubocop:enable Metrics/AbcSize

    # rubocop:disable Metrics/AbcSize
    def test_nested_adapter_and_timeout_overrides_preserve_other_defaults
      Dir.mktmpdir do |dir|
        File.write(
          File.join(dir, ".quality_gate.yml"),
          <<~YAML
            adapters:
              fast:
                - rubocop
            timeouts:
              rubocop: 5
          YAML
        )

        config = Config.load(dir: dir)

        assert_equal ["rubocop"], config.fetch(:adapters).fetch(:fast)
        assert_equal %w[reek test_suite undercover], config.fetch(:adapters).fetch(:verify)
        assert_equal %w[brakeman bundler_audit], config.fetch(:adapters).fetch(:audit)
        assert_equal 5, config.fetch(:timeouts).fetch(:rubocop)
        assert_equal 120, config.fetch(:timeouts).fetch(:default)
        assert_nil config.fetch(:rubocop_config)
      end
    end
    # rubocop:enable Metrics/AbcSize

    def test_explicit_rubocop_config_is_a_known_override
      Dir.mktmpdir do |dir|
        config_path = File.join(dir, "config", "rubocop.yml")
        Dir.mkdir(File.join(dir, "config"))
        File.write(File.join(dir, ".quality_gate.yml"), "rubocop_config: #{config_path}\n")

        config = Config.load(dir: dir)

        assert_equal config_path, config.fetch(:rubocop_config)
        assert_empty config.unknown_keys
      end
    end

    def test_malformed_yaml_reports_the_path_and_parser_message
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".quality_gate.yml")
        yaml = "gates: [fast\n"
        File.write(path, yaml)
        parser_error = assert_raises(Psych::SyntaxError) { YAML.safe_load(yaml) }

        error = assert_raises(ConfigError) { Config.load(dir: dir) }

        assert_equal path, error.path
        assert_includes error.message, path
        assert_includes error.message, parser_error.message
      end
    end

    def test_config_error_path_is_copied_and_frozen
      path = String.new("/tmp/.quality_gate.yml")
      error = ConfigError.new(path: path, cause_message: "bad YAML")

      assert_raises(FrozenError) { error.path.replace("elsewhere") }
      refute_same path, error.path
      path.replace("caller changed")
      assert_equal "/tmp/.quality_gate.yml", error.path
      assert_includes error.message, "/tmp/.quality_gate.yml"
    end

    def test_unknown_key_is_reported_and_excluded
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".quality_gate.yml")
        File.write(path, "format: json\nmystery: true\n")

        config = Config.load(dir: dir)

        assert_equal ["mystery"], config.unknown_keys
        refute config.to_h.key?(:mystery)
        assert_equal "json", config.fetch(:format)
        refute Config.defaults.key?(:gates)
      end
    end
  end

  class ConfigImmutabilityTest < Minitest::Test
    def test_to_h_returns_deeply_frozen_settings
      config = load_config(settings_yaml)
      settings = config.to_h

      assert_raises(FrozenError) { settings[:format] = "text" }
      assert_raises(FrozenError) { settings[:commands][:fast][:lint] << "other" }
      assert_equal ["bin/lint"], settings[:commands][:fast][:lint]
    end

    def test_fetch_returns_frozen_arrays_and_strings
      config = load_config(settings_yaml)
      format = config.fetch(:format)

      assert_raises(FrozenError) { format.replace("text") }
      assert_equal "json", format
    end

    def test_default_audit_adapters_are_deeply_frozen
      audit_adapters = Config.defaults.fetch(:adapters).fetch(:audit)

      assert_raises(FrozenError) { audit_adapters << "other" }
      assert_raises(FrozenError) { audit_adapters.first.replace("other") }
      assert_equal %w[brakeman bundler_audit], audit_adapters
    end

    def test_config_metadata_is_frozen
      config = load_config("mystery: true\n")
      original_path = config.path.dup

      assert_raises(FrozenError) { config.unknown_keys << "another" }
      assert_raises(FrozenError) { config.path.replace("elsewhere") }
      assert_equal ["mystery"], config.unknown_keys
      assert_equal original_path, config.path
    end

    private

    def settings_yaml
      <<~YAML
        format: json
        commands:
          fast:
            lint:
              - bin/lint
      YAML
    end

    def load_config(yaml)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".quality_gate.yml"), yaml)
        Config.load(dir: dir)
      end
    end
  end

  class ConfigValidationTest < Minitest::Test
    def test_files_must_be_an_array_of_non_empty_strings
      assert_invalid_config("files: lib/example.rb\n", "files must be an array")
      assert_invalid_config("files:\n  -\n", "files entries must be non-empty strings")
      assert_invalid_config("files:\n  - 1\n", "files entries must be non-empty strings")
      assert_invalid_config("files:\n  - \"\"\n", "files entries must be non-empty strings")
    end

    def test_adapter_layers_constant_is_not_public
      error = assert_raises(NameError) do
        Config::ADAPTER_LAYERS
      end

      assert_includes error.message, "ADAPTER_LAYERS"
    end

    def test_invalid_format_value_is_rejected
      assert_invalid_config("format: xml\n", "format must be text or json")
    end

    def test_adapters_must_be_a_mapping
      assert_invalid_config("adapters: fast\n", "adapters must be a mapping")
    end

    def test_adapters_reject_unknown_layer_keys
      assert_invalid_config("adapters:\n  fasst: []\n", "adapters keys must be fast, verify, or audit")
    end

    def test_adapters_layer_values_must_be_arrays
      assert_invalid_config("adapters:\n  fast: rubocop\n", "adapters.fast must be an array")
      assert_invalid_config("adapters:\n  fast:\n", "adapters.fast must be an array")
    end

    def test_adapters_entries_must_be_non_empty_strings
      assert_invalid_config("adapters:\n  fast:\n    - \"\"\n", "adapters.fast entries must be non-empty strings")
      assert_invalid_config("adapters:\n  fast:\n    -\n", "adapters.fast entries must be non-empty strings")
      assert_invalid_config("adapters:\n  fast:\n    - 1\n", "adapters.fast entries must be non-empty strings")
      assert_invalid_config("adapters:\n  fast:\n    - []\n", "adapters.fast entries must be non-empty strings")
      assert_invalid_config("adapters:\n  fast:\n    - {}\n", "adapters.fast entries must be non-empty strings")
    end

    def test_rubocop_config_accepts_nil_or_a_non_empty_string
      assert_nil load_config("rubocop_config:\n").fetch(:rubocop_config)
      config = load_config("rubocop_config: config/custom-rubocop.yml\n")

      assert_equal "config/custom-rubocop.yml", config.fetch(:rubocop_config)
    end

    def test_rubocop_config_rejects_an_empty_string
      assert_invalid_config("rubocop_config: \"\"\n", "rubocop_config must be nil or a non-empty String")
    end

    def test_rubocop_config_rejects_non_string_values
      assert_invalid_config("rubocop_config: []\n", "rubocop_config must be nil or a non-empty String")
      assert_invalid_config("rubocop_config: 1\n", "rubocop_config must be nil or a non-empty String")
      assert_invalid_config(
        "rubocop_config:\n  path: config/rubocop.yml\n",
        "rubocop_config must be nil or a non-empty String"
      )
    end

    def test_compare_point_accepts_nil_or_a_non_empty_string
      assert_nil load_config("compare_point:\n").fetch(:compare_point)
      config = load_config("compare_point: origin/release\n")

      assert_equal "origin/release", config.fetch(:compare_point)
    end

    def test_compare_point_rejects_empty_or_non_string_values
      assert_invalid_config("compare_point: \"\"\n", "compare_point must be nil or a non-empty String")
      assert_invalid_config("compare_point: []\n", "compare_point must be nil or a non-empty String")
      assert_invalid_config("compare_point: 1\n", "compare_point must be nil or a non-empty String")
    end

    def test_coverage_accepts_numeric_budgets_including_boundaries
      config = load_config(<<~YAML)
        coverage:
          minimum_line: 0
          minimum_branch: 100.0
      YAML

      assert_equal({ minimum_line: 0, minimum_branch: 100.0 }, config.fetch(:coverage))
      assert_empty config.unknown_keys
    end

    def test_coverage_accepts_either_budget_independently
      line_config = load_config("coverage:\n  minimum_line: 90.5\n")
      branch_config = load_config("coverage:\n  minimum_branch: 85\n")

      assert_equal({ minimum_line: 90.5 }, line_config.fetch(:coverage))
      assert_equal({ minimum_branch: 85 }, branch_config.fetch(:coverage))
    end

    def test_coverage_must_be_a_non_empty_mapping_when_present
      assert_invalid_config("coverage:\n", "coverage must be a non-empty mapping")
      assert_invalid_config("coverage: {}\n", "coverage must be a non-empty mapping")
      assert_invalid_config("coverage: []\n", "coverage must be a non-empty mapping")
      assert_invalid_config("coverage: 90\n", "coverage must be a non-empty mapping")
    end

    def test_coverage_rejects_unknown_keys_and_names_them
      assert_invalid_config(
        "coverage:\n  minimum_lines: 90\n",
        "unknown coverage key minimum_lines"
      )
    end

    def test_coverage_values_must_be_numeric
      assert_invalid_config("coverage:\n  minimum_line: \"90\"\n", "coverage.minimum_line must be Numeric")
      assert_invalid_config("coverage:\n  minimum_branch: true\n", "coverage.minimum_branch must be Numeric")
      assert_invalid_config("coverage:\n  minimum_line:\n", "coverage.minimum_line must be Numeric")
    end

    def test_coverage_values_must_be_between_zero_and_one_hundred
      assert_invalid_config("coverage:\n  minimum_line: -0.1\n", "coverage.minimum_line must be within 0..100")
      assert_invalid_config("coverage:\n  minimum_branch: 100.1\n", "coverage.minimum_branch must be within 0..100")
    end

    def test_commands_must_be_a_mapping_with_known_layers
      assert_invalid_config("commands: verify\n", "commands must be a mapping")
      assert_invalid_config("commands:\n  verfy: {}\n", "commands keys must be fast, verify, or audit")
    end

    def test_command_layers_must_be_mappings
      assert_invalid_config("commands:\n  verify: []\n", "commands.verify must be a mapping")
      assert_invalid_config("commands:\n  verify:\n", "commands.verify must be a mapping")
    end

    def test_commands_are_non_empty_argv_arrays_of_non_empty_strings
      assert_invalid_config("commands:\n  verify:\n    test_suite: bin/rails test\n", "must be an argv array")
      assert_invalid_config("commands:\n  verify:\n    test_suite: []\n", "must be an argv array")
      invalid_entries = "entries must be non-empty strings"
      assert_invalid_config("commands:\n  verify:\n    test_suite: [bin/rails, \"\"]\n", invalid_entries)
      assert_invalid_config("commands:\n  verify:\n    test_suite: [bin/rails, 1]\n", invalid_entries)
    end

    def test_excessive_yaml_nesting_is_reported_as_config_error
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".quality_gate.yml")
        File.write(path, deeply_nested_yaml)

        error = assert_raises(ConfigError) { Config.load(dir: dir) }

        assert_equal path, error.path
        assert_includes error.message, path
        assert_match(/stack|nest/i, error.message)
      end
    end

    def test_false_root_is_rejected
      assert_invalid_config("false\n", "expected a mapping")
    end

    def test_sequence_root_is_rejected
      assert_invalid_config("- fast\n- verify\n", "expected a mapping")
    end

    def test_non_string_root_key_is_rejected
      assert_invalid_config("1: value\n", "keys must be strings")
    end

    def test_non_string_nested_key_is_rejected
      assert_invalid_config("commands:\n  fast:\n    1: bin/lint\n", "keys must be strings")
    end

    def test_empty_yaml_uses_defaults
      assert_equal Config.defaults, load_config("").to_h
    end

    def test_yaml_object_tags_are_rejected
      assert_invalid_config("format: !ruby/object:Object {}\n")
    end

    def test_yaml_aliases_are_rejected
      assert_invalid_config("files: &files [lib]\ngates: *files\n")
    end

    private

    def deeply_nested_yaml
      "format: #{"[" * 2_000}text#{"]" * 2_000}\n"
    end

    def load_config(yaml)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".quality_gate.yml"), yaml)
        Config.load(dir: dir)
      end
    end

    def assert_invalid_config(yaml, cause = nil)
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".quality_gate.yml")
        File.write(path, yaml)

        error = assert_raises(ConfigError) { Config.load(dir: dir) }

        assert_equal path, error.path
        assert_includes error.message, path
        assert_includes error.message, cause if cause
      end
    end
  end
end
