# frozen_string_literal: true

require "json"
require "rubygems"

module QualityGate
  # Runs database_consistency inside the target application's Bundler/Rails context.
  class DatabaseConsistencyRunner
    ENVELOPE_VERSION = 1
    SUPPORTED_ANALYZER_VERSION = Gem::Requirement.new("~> 3.0.14")
    REPORT_FIELDS = %i[
      checker_name table_or_model_name column_or_attribute_name status error_slug error_message
    ].freeze
    private_constant :REPORT_FIELDS

    class << self
      def run(stdout: $stdout, stderr: $stderr, cwd: Dir.pwd)
        with_redirected_stdout(stderr) { execute(stdout, cwd) }
      rescue StandardError, LoadError => e
        diagnostic(stderr, e)
        2
      end

      private

      def load_project!(cwd)
        require "bundler/setup"
        require_project_files(cwd)
        rails_application.eager_load!
      end

      def require_project_files(cwd)
        require_project_file(cwd, "boot")
        require_project_file(cwd, "environment")
      end

      def load_analyzer!
        require "database_consistency"
        spec = Gem.loaded_specs["database_consistency"]
        validate_analyzer_version!(spec)
        spec.version.to_s
      end

      def collect_reports
        configuration = DatabaseConsistency::Configuration.new
        reports = DatabaseConsistency::Processors.reports(configuration)
        ensure_no_rescued_checker_errors!
        serialize_reports(reports)
      end

      def serialize_report(report)
        report_fields(report).merge(report_source_location(report))
      end

      def report_fields(report)
        REPORT_FIELDS.to_h { |field| [field, report.public_send(field)] }
      end

      def report_source_location(report)
        return {} unless report.respond_to?(:source_location)

        { source_location: report.source_location }
      end

      def write_envelope(stdout, analyzer_version, reports)
        stdout.puts(JSON.generate(version: ENVELOPE_VERSION, analyzer_version:, reports:))
      end

      def diagnostic(stderr, error)
        stderr.puts("database_consistency: #{error.class}: #{error.message}")
      rescue StandardError
        nil
      end

      def with_redirected_stdout(stderr)
        previous_stdout = $stdout
        $stdout = stderr
        yield
      ensure
        $stdout = previous_stdout
      end

      def execute(stdout, cwd)
        load_project!(cwd)
        analyzer_version = load_analyzer!
        write_envelope(stdout, analyzer_version, collect_reports)
        0
      end

      def require_project_file(cwd, section)
        path = File.join(cwd, "config", "#{section}.rb")
        raise LoadError, "Rails #{section} file not found at #{path}" unless File.file?(path)

        require path
      end

      def rails_application
        return Rails.application if defined?(Rails) && Rails.respond_to?(:application) && Rails.application

        raise LoadError, "Rails.application is unavailable after loading config/environment.rb"
      end

      def validate_analyzer_version!(spec)
        raise LoadError, "database_consistency gem did not register a loaded gemspec" unless spec
        return if SUPPORTED_ANALYZER_VERSION.satisfied_by?(spec.version)

        raise LoadError,
              "database_consistency #{spec.version} is unsupported; install ~> 3.0.14 (>= 3.0.14, < 3.1)"
      end

      def ensure_no_rescued_checker_errors!
        return if DatabaseConsistency::RescueError.empty?

        raise "database_consistency rescued a checker error; see its diagnostic file in the project root"
      end

      def serialize_reports(reports)
        reports.map { serialize_report(_1) }
      end
    end
  end
end

exit QualityGate::DatabaseConsistencyRunner.run if $PROGRAM_NAME == __FILE__
