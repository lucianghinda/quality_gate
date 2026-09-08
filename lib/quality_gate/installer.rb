# frozen_string_literal: true

require "fileutils"
require_relative "installation"
require_relative "ruby_profile"

module QualityGate
  # Installs the framework-independent Quality Gate files into a Ruby project.
  class Installer
    include Installation

    VALID_OPTIONS = %i[
      profile
      test_framework
      test_helper
      test_command
      agents
      pretend
      skip_coverage
    ].freeze
    DEFAULT_TEMPLATE_ROOT = File.expand_path("../generators/quality_gate/install/templates", __dir__).freeze
    INSTALL_STEPS = %i[
      create_settings_file
      create_rules_file
      create_initializers
      inject_coverage
      create_agent_integration
    ].freeze

    attr_reader :destination_root, :stdout, :profile

    def initialize(destination_root:, options: {}, stdout: $stdout)
      @options = normalize_options(options)
      @profile = RubyProfile.new(destination_root:, options: @options)
      @destination_root = @profile.destination_root
      @stdout = stdout
      @template_source_root = DEFAULT_TEMPLATE_ROOT
    end

    def options
      @options.merge(skip_initializers: true)
    end

    def call
      INSTALL_STEPS.each { |step| public_send(step) }
      print_summary

      results.fetch(:needs_person, []).empty? ? 0 : 1
    end

    def behavior
      :invoke
    end

    def test_helper_path
      profile.test_helper
    end

    def template_for(name)
      profile.template_for(name)
    end

    private

    attr_reader :template_source_root

    def normalize_options(value)
      normalized = option_pairs(value).to_h
      validate_options!(normalized)
      normalized.freeze
    end

    def option_pairs(value)
      raise ArgumentError, "options must be a mapping" unless value.respond_to?(:to_h)

      value.to_h.map { |key, option_value| [key.to_sym, option_value] }
    rescue TypeError, NoMethodError
      raise ArgumentError, "option keys must be symbols or strings"
    end

    def validate_options!(normalized)
      unknown = normalized.keys - VALID_OPTIONS
      return if unknown.empty?

      raise ArgumentError, "unknown installer option(s): #{unknown.map(&:inspect).join(", ")}"
    end

    def create_new_file(relative_path, content)
      write_new_file(File.join(destination_root, relative_path), content)
    end

    def write_new_file(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|
        file.binmode
        file.write(content)
      end
    end

    def say(message)
      stdout.puts(message)
    end
  end
end
