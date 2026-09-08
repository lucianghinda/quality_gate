# frozen_string_literal: true

require "yaml"

module QualityGate
  # Reports a configuration file that could not be parsed or read.
  class ConfigError < Error
    attr_reader :path

    def initialize(path:, cause_message:)
      @path = path.dup.freeze
      super("Could not load config #{@path}: #{cause_message}")
    end
  end

  # Loads and exposes quality gate settings resolved against shipped defaults.
  # rubocop:disable Metrics/ClassLength
  class Config
    DEFAULTS = {
      format: "text",
      files: [].freeze,
      adapters: {
        fast: ["rubocop"].freeze,
        verify: %w[reek test_suite undercover].map!(&:freeze).freeze,
        audit: %w[brakeman bundler_audit].map!(&:freeze).freeze
      }.freeze,
      commands: {
        fast: {}.freeze,
        verify: { test_suite: %w[bin/rails test].map!(&:freeze).freeze }.freeze,
        audit: {}.freeze
      }.freeze,
      timeouts: { default: 120, rubocop: 10, test_suite: 120, undercover: 120 }.freeze,
      coverage: nil,
      compare_point: nil,
      rubocop_config: nil
    }.freeze
    ADAPTER_LAYERS = %i[fast verify audit].freeze
    COVERAGE_KEYS = %i[minimum_line minimum_branch].freeze
    private_constant :ADAPTER_LAYERS, :COVERAGE_KEYS

    class << self
      def defaults = DEFAULTS

      def load(dir:)
        path = File.join(dir, ".quality_gate.yml")
        return new(DEFAULTS) unless File.exist?(path)

        load_file(path)
      rescue Psych::Exception, SystemCallError, SystemStackError => e
        fail ConfigError.new(path: path, cause_message: e.message) # rubocop:disable Style/SignalException
      end

      private

      def symbolize_keys(value)
        case value
        when Hash
          value.to_h { |key, child| [key.to_sym, symbolize_keys(child)] }
        when Array
          value.map { |child| symbolize_keys(child) }
        else
          value
        end
      end

      def load_file(path)
        document = YAML.safe_load(File.read(path))
        validate_document(document, path)
        overrides = symbolize_keys(document || {})
        validate_known_settings(overrides, path)

        new(
          deep_merge(DEFAULTS, known_overrides(overrides)),
          path: path,
          unknown_keys: unknown_keys(overrides)
        )
      end

      def known_overrides(overrides)
        overrides.select { |key, _value| DEFAULTS.key?(key) }
      end

      def unknown_keys(overrides)
        overrides.keys.reject { |key| DEFAULTS.key?(key) }.map(&:to_s)
      end

      def validate_known_settings(overrides, path) # rubocop:disable Metrics/AbcSize
        validate_format(overrides[:format], path) if overrides.key?(:format)
        validate_files(overrides[:files], path) if overrides.key?(:files)
        validate_adapters(overrides[:adapters], path) if overrides.key?(:adapters)
        validate_commands(overrides[:commands], path) if overrides.key?(:commands)
        validate_coverage(overrides[:coverage], path) if overrides.key?(:coverage)
        validate_compare_point(overrides[:compare_point], path) if overrides.key?(:compare_point)
        validate_rubocop_config(overrides[:rubocop_config], path) if overrides.key?(:rubocop_config)
      end

      def validate_format(format, path)
        return if %w[text json].include?(format)

        fail ConfigError.new(path: path, cause_message: "format must be text or json") # rubocop:disable Style/SignalException
      end

      def validate_files(files, path)
        unless files.is_a?(Array)
          fail ConfigError.new(path: path, cause_message: "files must be an array") # rubocop:disable Style/SignalException
        end

        return if files.all? { |file| file.is_a?(String) && !file.empty? }

        fail ConfigError.new( # rubocop:disable Style/SignalException
          path: path,
          cause_message: "files entries must be non-empty strings"
        )
      end

      def validate_adapters(adapters, path)
        unless adapters.is_a?(Hash)
          fail ConfigError.new(path: path, cause_message: "adapters must be a mapping") # rubocop:disable Style/SignalException
        end

        invalid_keys = adapters.keys - ADAPTER_LAYERS
        if invalid_keys.any?
          fail ConfigError.new(path: path, cause_message: "adapters keys must be fast, verify, or audit") # rubocop:disable Style/SignalException
        end

        adapters.each do |layer, adapter_names|
          validate_adapter_names(layer, adapter_names, path)
        end
      end

      def validate_adapter_names(layer, adapter_names, path)
        unless adapter_names.is_a?(Array)
          fail ConfigError.new(path: path, cause_message: "adapters.#{layer} must be an array") # rubocop:disable Style/SignalException
        end

        return if adapter_names.all? { |name| name.is_a?(String) && !name.empty? }

        fail ConfigError.new(path: path, cause_message: "adapters.#{layer} entries must be non-empty strings") # rubocop:disable Style/SignalException
      end

      def validate_commands(commands, path)
        validate_layer_mapping(commands, "commands", path)

        commands.each do |layer, layer_commands|
          unless layer_commands.is_a?(Hash)
            fail ConfigError.new(path: path, cause_message: "commands.#{layer} must be a mapping") # rubocop:disable Style/SignalException
          end

          layer_commands.each do |command_name, argv|
            validate_command_argv(layer, command_name, argv, path)
          end
        end
      end

      def validate_layer_mapping(value, setting, path)
        unless value.is_a?(Hash)
          fail ConfigError.new(path: path, cause_message: "#{setting} must be a mapping") # rubocop:disable Style/SignalException
        end

        return if (value.keys - ADAPTER_LAYERS).empty?

        cause = "#{setting} keys must be fast, verify, or audit"
        fail ConfigError.new(path: path, cause_message: cause) # rubocop:disable Style/SignalException
      end

      def validate_command_argv(layer, command_name, argv, path)
        unless argv.is_a?(Array) && argv.any?
          cause = "commands.#{layer}.#{command_name} must be an argv array"
          fail ConfigError.new(path: path, cause_message: cause) # rubocop:disable Style/SignalException
        end

        return if argv.all? { _1.is_a?(String) && !_1.empty? }

        cause = "commands.#{layer}.#{command_name} entries must be non-empty strings"
        fail ConfigError.new(path: path, cause_message: cause) # rubocop:disable Style/SignalException
      end

      def validate_compare_point(compare_point, path)
        return if compare_point.nil?
        return if compare_point.is_a?(String) && !compare_point.empty?

        cause = "compare_point must be nil or a non-empty String"
        fail ConfigError.new(path: path, cause_message: cause) # rubocop:disable Style/SignalException
      end

      def validate_coverage(coverage, path)
        unless coverage.is_a?(Hash) && coverage.any?
          cause = "coverage must be a non-empty mapping"
          fail ConfigError.new(path: path, cause_message: cause) # rubocop:disable Style/SignalException
        end

        invalid_key = (coverage.keys - COVERAGE_KEYS).first
        if invalid_key
          cause = "unknown coverage key #{invalid_key}"
          fail ConfigError.new(path: path, cause_message: cause) # rubocop:disable Style/SignalException
        end

        coverage.each do |key, value|
          validate_coverage_value(key, value, path)
        end
      end

      def validate_coverage_value(key, value, path)
        unless value.is_a?(Numeric)
          cause = "coverage.#{key} must be Numeric"
          fail ConfigError.new(path: path, cause_message: cause) # rubocop:disable Style/SignalException
        end

        return if value.finite? && value.between?(0, 100)

        cause = "coverage.#{key} must be within 0..100"
        fail ConfigError.new(path: path, cause_message: cause) # rubocop:disable Style/SignalException
      end

      def validate_rubocop_config(rubocop_config, path)
        return if rubocop_config.nil?
        return if rubocop_config.is_a?(String) && !rubocop_config.empty?

        fail ConfigError.new(path: path, cause_message: "rubocop_config must be nil or a non-empty String") # rubocop:disable Style/SignalException
      end

      def validate_document(document, path)
        unless document.nil? || document.is_a?(Hash)
          cause = "expected a mapping, got #{document.class}"
          fail ConfigError.new(path: path, cause_message: cause) # rubocop:disable Style/SignalException
        end

        validate_keys(document, path)
      end

      def validate_keys(value, path)
        case value
        when Hash
          value.each do |key, child|
            validate_key(key, path)
            validate_keys(child, path)
          end
        when Array
          value.each { |child| validate_keys(child, path) }
        end
      end

      def validate_key(key, path)
        return if key.is_a?(String)

        cause = "configuration keys must be strings, got #{key.class}"
        fail ConfigError.new(path: path, cause_message: cause) # rubocop:disable Style/SignalException
      end

      def deep_merge(defaults, overrides)
        defaults.merge(overrides) do |_key, default, override|
          if default.is_a?(Hash) && override.is_a?(Hash)
            deep_merge(default, override)
          else
            override
          end
        end
      end
    end

    attr_reader :path, :unknown_keys

    def initialize(settings, path: nil, unknown_keys: [])
      @settings = deep_freeze(settings)
      @path = path&.dup&.freeze
      @unknown_keys = deep_freeze(unknown_keys)
    end

    def to_h = @settings

    def fetch(key) = @settings.fetch(key)

    private

    def deep_freeze(value)
      case value
      when Hash
        value.each do |key, child|
          deep_freeze(key)
          deep_freeze(child)
        end
      when Array
        value.each { |child| deep_freeze(child) }
      end

      value.freeze
    end
  end
  # rubocop:enable Metrics/ClassLength
end
