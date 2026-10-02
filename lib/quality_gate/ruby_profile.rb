# frozen_string_literal: true

require "pathname"
require "json"
require "shellwords"

module QualityGate
  module RubyProfileSupport
    DEFAULT_COMMANDS = {
      "minitest" => %w[bundle exec rake test].freeze,
      "rspec" => %w[bundle exec rspec].freeze
    }.freeze
    private_constant :DEFAULT_COMMANDS

    module_function

    def options(value)
      raise ArgumentError, "options must be a mapping" unless value.respond_to?(:to_h)

      value.to_h.transform_keys(&:to_sym)
    rescue NoMethodError
      raise ArgumentError, "option keys must be symbols or strings"
    end

    def destination_root(value)
      path = value.to_s
      raise ArgumentError, "destination_root must be a non-empty directory" if path.empty?

      expanded = File.expand_path(path)
      return expanded if File.directory?(expanded)

      raise ArgumentError, "destination_root must be an existing directory: #{path}"
    end

    def relative_path(root_path, value, name)
      validate_path_value!(value, name)
      raise ArgumentError, "#{name} must be relative to the project" if Pathname.new(value).absolute?

      relative = Pathname.new(File.expand_path(value, root_path)).relative_path_from(Pathname.new(root_path)).to_s
      return relative unless outside_project?(relative)

      raise ArgumentError, "#{name} must stay inside the project"
    end

    def command(value, framework, defaults: DEFAULT_COMMANDS)
      command = value.nil? ? defaults.fetch(framework) : parse_command(value)
      validate_command!(command)
      command.map(&:dup).freeze
    end

    def parse_command(value)
      return value.dup if value.is_a?(Array)
      return parse_shellwords(value) if value.is_a?(String)

      raise ArgumentError, "test_command must be a command string or argv array"
    end

    def parse_shellwords(value)
      Shellwords.split(value)
    rescue ArgumentError => e
      raise ArgumentError, "test_command could not be parsed: #{e.message}"
    end

    def validate_path_value!(value, name)
      return if value.is_a?(String) && !value.empty?

      raise ArgumentError, "#{name} must be a non-empty path"
    end

    def validate_command!(command)
      valid = command.is_a?(Array) && command.any? && command.all? { _1.is_a?(String) && !_1.empty? }
      return if valid

      raise ArgumentError, "test_command must not be empty"
    end

    def outside_project?(relative)
      relative == ".." || relative.start_with?("../")
    end
  end
  private_constant :RubyProfileSupport

  # Resolves the framework, helper, command, and templates for a plain Ruby project.
  class RubyProfile
    DEFAULT_HELPERS = {
      "minitest" => "test/test_helper.rb",
      "rspec" => "spec/spec_helper.rb"
    }.freeze
    TEMPLATE_MAP = {
      "quality_gate.yml.tt" => "ruby_quality_gate.yml.tt",
      "rubocop.yml.tt" => "ruby_rubocop.yml.tt",
      "simplecov.rb.tt" => "ruby_simplecov.rb.tt",
      "agents_section.md.tt" => "ruby_agents_section.md.tt"
    }.freeze
    SUPPORTED_FRAMEWORKS = DEFAULT_HELPERS.keys.freeze
    private_constant :DEFAULT_HELPERS, :TEMPLATE_MAP, :SUPPORTED_FRAMEWORKS

    attr_reader :destination_root, :test_helper, :test_command

    def initialize(destination_root:, options: {})
      @destination_root = RubyProfileSupport.destination_root(destination_root)
      @options = RubyProfileSupport.options(options)
      resolve_settings
    end

    def coverage? = @coverage

    def template_for(name)
      TEMPLATE_MAP.fetch(name, name)
    end

    private

    attr_reader :options, :framework

    def resolve_settings
      validate_profile!
      @coverage = !option(:skip_coverage)
      @framework = resolve_framework
      @test_helper = resolve_test_helper
      @test_command = RubyProfileSupport.command(option(:test_command), framework)
    end

    def option(key)
      options.fetch(key, nil)
    end

    def validate_profile!
      return if (option(:profile) || "ruby").to_s == "ruby"

      raise ArgumentError, "unsupported profile; only ruby is supported"
    end

    def resolve_framework
      explicit = option(:test_framework)
      return validate_framework(explicit) if explicit
      return "minitest" if option(:test_helper)

      detected_framework
    end

    def validate_framework(value)
      framework = value.to_s
      return framework if SUPPORTED_FRAMEWORKS.include?(framework)

      raise ArgumentError, "test_framework must be minitest or rspec"
    end

    def detected_framework
      available = DEFAULT_HELPERS.select { |_framework, helper| helper_present?(helper) }.keys
      return available.first if available.one?
      return "minitest" if available.empty?

      raise ArgumentError, "both test helpers exist; pass --test-framework minitest or rspec"
    end

    def helper_present?(helper)
      File.file?(File.join(destination_root, helper))
    end

    def resolve_test_helper
      helper = option(:test_helper) || DEFAULT_HELPERS.fetch(framework)
      relative = RubyProfileSupport.relative_path(destination_root, helper, "test_helper")
      return relative if !coverage? || helper_present?(relative)

      raise ArgumentError,
            "test helper #{relative.inspect} does not exist; pass --skip-coverage or provide an existing helper"
    end
  end

  # Resolves the Rails test helper and command while sharing the Ruby profile's
  # validation for project-relative paths and shell-free argv.
  class RailsProfile
    DEFAULT_HELPERS = {
      "minitest" => "test/test_helper.rb",
      "rspec" => "spec/rails_helper.rb"
    }.freeze
    DEFAULT_COMMANDS = {
      "minitest" => %w[bin/rails test].freeze,
      "rspec" => %w[bundle exec rspec].freeze
    }.freeze
    TEMPLATE_MAP = { "quality_gate.yml.tt" => "rails_quality_gate.yml.tt" }.freeze
    SUPPORTED_FRAMEWORKS = DEFAULT_HELPERS.keys.freeze

    attr_reader :destination_root, :framework, :test_helper, :test_command

    def initialize(destination_root:, options: {})
      @destination_root = RubyProfileSupport.destination_root(destination_root)
      @options = RubyProfileSupport.options(options)
      resolve_settings
    end

    def coverage? = @coverage

    def missing_default_helper? = !!@missing_default_helper

    def template_for(name)
      TEMPLATE_MAP.fetch(name, name)
    end

    private

    attr_reader :options

    def resolve_settings
      @coverage = !option(:skip_coverage)
      @framework = resolve_framework
      @test_helper = resolve_test_helper
      @test_command = RubyProfileSupport.command(option(:test_command), framework, defaults: DEFAULT_COMMANDS)
    end

    def option(key)
      options.fetch(key, nil)
    end

    def resolve_framework
      explicit = option(:test_framework)
      return validate_framework(explicit) if explicit

      helper = option(:test_helper)
      return framework_for_helper(helper) if helper

      detected_framework
    end

    def detected_framework
      available = DEFAULT_HELPERS.select { |_name, path| helper_present?(path) }.keys
      return available.first if available.one?

      return missing_default_framework if available.empty?

      raise ArgumentError, "both test helpers exist; pass --test-framework minitest or rspec"
    end

    def missing_default_framework
      @missing_default_helper = true
      "minitest"
    end

    def validate_framework(value)
      selected = value.to_s
      return selected if SUPPORTED_FRAMEWORKS.include?(selected)

      raise ArgumentError, "test_framework must be minitest or rspec"
    end

    def framework_for_helper(value)
      relative = RubyProfileSupport.relative_path(destination_root, value, "test_helper")
      relative.start_with?("spec/") || relative == "spec" ? "rspec" : "minitest"
    end

    def resolve_test_helper
      helper = option(:test_helper) || DEFAULT_HELPERS.fetch(framework)
      relative = RubyProfileSupport.relative_path(destination_root, helper, "test_helper")
      return relative unless coverage?

      validate_test_helper!(relative)
      relative
    end

    def validate_test_helper!(relative)
      path = helper_path_without_symlinks(relative)
      raise ArgumentError, "test_helper must not pass through symlinks" unless path
      return if File.file?(path) || missing_default_helper?

      raise ArgumentError,
            "test helper #{relative.inspect} does not exist; pass --skip-coverage or provide an existing helper"
    end

    def helper_present?(helper)
      path = helper_path_without_symlinks(helper)
      path && File.file?(path)
    end

    def helper_path_without_symlinks(helper)
      return if symlink_in_path?(helper)

      File.join(destination_root, helper)
    end

    def symlink_in_path?(helper)
      path = destination_root
      helper.split(File::SEPARATOR).any? do |component|
        path = File.join(path, component)
        File.symlink?(path)
      end
    end
  end
end
