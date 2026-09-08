# frozen_string_literal: true

require "json"
require "pathname"

module QualityGate
  module Adapters
    # Runs RuboCop with project-aware configuration and normalizes its JSON report.
    class RuboCop < Adapter
      SEVERITY_MAP = {
        "info" => :info,
        "refactor" => :info,
        "convention" => :warning,
        "warning" => :warning,
        "error" => :error,
        "fatal" => :error
      }.freeze

      CONFIG_PATH = File.expand_path("../../../config/rubocop.yml", __dir__).freeze

      PROJECT_CONFIG_PATHS = %w[.config/.rubocop.yml .config/rubocop/config.yml].freeze
      PROJECT_ROOT_FILES = %w[Gemfile gems.rb].freeze
      private_constant :PROJECT_CONFIG_PATHS, :PROJECT_ROOT_FILES

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

      def name = "rubocop"

      def command
        argv = ["rubocop", "--format", "json", "--force-exclusion"]
        explicit_config = config.to_h.fetch(:rubocop_config, nil)

        if explicit_config
          argv.concat(["--config", explicit_config])
        elsif !host_config?
          argv.concat(["--config", CONFIG_PATH])
        end

        argv.concat(resolved_paths_for_command)
      end

      def parse(stdout)
        report = parse_report(stdout)
        parse_files(report.fetch("files"))
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError => e
        raise ParseError.new(tool: name, reason: e.message)
      end

      private

      def existing_paths
        files.filter_map { |path| positional_path(path) if File.exist?(path) }.freeze
      end

      def positional_path(path) = path.start_with?("-") ? File.join(".", path) : path

      def host_config?
        project_root = inferred_project_root
        return true if config_search_directories(project_root).any? { |dir| File.file?(dir.join(".rubocop.yml")) }
        return false unless project_root

        PROJECT_CONFIG_PATHS.any? { |path| File.file?(project_root.join(path)) }
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

      def resolved_paths_for_command = @resolved_paths_for_call || existing_paths

      def parse_report(stdout)
        report = JSON.parse(stdout)
        raise TypeError, "report must be a JSON object" unless report.is_a?(Hash)

        report
      end

      def parse_files(entries)
        raise TypeError, "files must be an array" unless entries.is_a?(Array)

        entries.flat_map { |entry| parse_file(entry) }
      end

      def parse_file(entry)
        raise TypeError, "file entry must be an object" unless entry.is_a?(Hash)

        path = entry.fetch("path")
        offenses = entry.fetch("offenses")
        raise TypeError, "file path must be a String" unless path.is_a?(String)
        raise TypeError, "offenses must be an array" unless offenses.is_a?(Array)

        offenses.map { |offense| build_finding(path, offense) }
      end

      def build_finding(path, offense)
        Finding.new(tool: name, file: path, **offense_attributes(offense))
      end

      def offense_attributes(offense)
        raise TypeError, "offense must be an object" unless offense.is_a?(Hash)

        location = offense.fetch("location")
        raise TypeError, "location must be an object" unless location.is_a?(Hash)

        {
          line: location.fetch("start_line"),
          rule: offense.fetch("cop_name"),
          severity: SEVERITY_MAP.fetch(offense.fetch("severity")),
          message: offense.fetch("message")
        }
      end
    end
  end
end
