# frozen_string_literal: true

require "json"
require "pathname"

module QualityGate
  module Adapters
    # Runs Reek with project-aware configuration and normalizes its JSON report.
    class Reek < Adapter
      CONFIG_PATH = File.expand_path("../../../config/reek.yml", __dir__).freeze

      HOST_CONFIG_FILE = ".reek.yml"
      PROJECT_ROOT_FILES = %w[Gemfile gems.rb].freeze
      SMELL_KEYS = %w[context lines message smell_type source].freeze
      private_constant :HOST_CONFIG_FILE, :PROJECT_ROOT_FILES, :SMELL_KEYS

      def initialize(config:, files: [], diagnostic_io: $stderr)
        @call_lock = Mutex.new
        super
      end

      def call
        @call_lock.synchronize do
          resolved_paths = existing_paths
          next [] if files.any? && resolved_paths.empty?

          @resolved_paths_for_call = resolved_paths
          begin
            super()
          ensure
            @resolved_paths_for_call = nil
          end
        end
      end

      def name = "reek"

      def command
        argv = ["reek", "--format", "json"]
        argv.concat(["--config", CONFIG_PATH]) unless host_config?
        argv.concat(resolved_paths_for_command)
      end

      def parse(stdout)
        smells = JSON.parse(stdout)
        raise TypeError, "report must be a JSON array" unless smells.is_a?(Array)

        smells.map { |smell| build_finding(smell) }
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError => e
        raise ParseError.new(tool: name, reason: e.message)
      end

      private

      def existing_paths
        files.filter_map { |path| positional_path(path) if File.exist?(path) }.freeze
      end

      def positional_path(path) = path.start_with?("-") ? File.join(".", path) : path

      def resolved_paths_for_command = @resolved_paths_for_call || existing_paths

      def host_config?
        config_search_directories(inferred_project_root).any? do |dir|
          File.file?(dir.join(HOST_CONFIG_FILE))
        end
      end

      def inferred_project_root
        PROJECT_ROOT_FILES.lazy.filter_map { |file| last_ancestor_containing(file) }.first
      end

      def last_ancestor_containing(file)
        Pathname(Dir.pwd).expand_path.ascend.select { |directory| directory.join(file).exist? }.last
      end

      def config_search_directories(project_root)
        directories = Pathname(Dir.pwd).expand_path.ascend
        return directories.to_a unless project_root

        directories.take_while { |directory| directory != project_root }.push(project_root)
      end

      def build_finding(smell)
        raise TypeError, "smell entry must be an object" unless smell.is_a?(Hash)

        context, lines, message, smell_type, source = smell.values_at(*SMELL_KEYS)
        validate_smell!(context, lines, message, smell_type, source)

        Finding.new(
          tool: name,
          file: source, line: lines.first,
          rule: smell_type,
          severity: :warning,
          message: "#{context} #{message}"
        )
      end

      def validate_smell!(context, lines, message, smell_type, source)
        %w[context message smell_type source].zip([context, message, smell_type, source]) do |key, value|
          raise TypeError, "smell #{key} must be a String" unless value.is_a?(String)
        end
        raise TypeError, "smell lines must be a non-empty array" if !lines.is_a?(Array) || lines.empty?
        raise TypeError, "smell lines must contain Integers" unless lines.first.is_a?(Integer)
      end
    end
  end
end
