# frozen_string_literal: true

require "optparse"

module QualityGate
  # Parses command-line input and coordinates configured quality gates.
  # rubocop:disable Metrics/ClassLength
  class CLI
    SUBCOMMANDS = %w[fast verify audit version init].map!(&:freeze).freeze
    GATE_SUBCOMMANDS = SUBCOMMANDS.first(3).freeze
    GATE_TOOLS = {
      "fast" => %w[rubocop].freeze,
      "verify" => %w[reek test_suite undercover].freeze,
      "audit" => %w[brakeman bundler_audit].freeze
    }.freeze

    class << self
      def run(argv, stdout: $stdout, stderr: $stderr, dir: Dir.pwd)
        output_format = nil
        arguments = argv.dup
        output_format = requested_format(arguments)
        subcommand = arguments.shift

        early_result = early_command(subcommand, arguments, stdout: stdout, stderr: stderr, dir: dir)
        return early_result unless early_result.nil?

        output_format ||= configured_format(dir)
        execute_command(
          subcommand,
          arguments,
          stdout: stdout,
          stderr: stderr,
          dir: dir,
          format: output_format
        )
      rescue OptionParser::ParseError => e
        report_option_error(e, stdout: stdout, stderr: stderr, format: output_format)
      rescue StandardError => e
        report_error(e, stdout: stdout, stderr: stderr, format: output_format)
      end

      private

      def print_version(stdout, stderr)
        return ExitCode::CLEAN if write_line(stdout, VERSION)

        write_diagnostic(stderr, "Error", "could not write version output")
        ExitCode::TOOL_FAILURE
      end

      def invalid_command(subcommand, stdout:, stderr:, format:)
        return report_json_error("unknown subcommand #{subcommand}", stdout: stdout, stderr: stderr) if format == "json"

        usage(stderr)
        ExitCode::TOOL_FAILURE
      end

      def early_command(subcommand, arguments, stdout:, stderr:, dir:)
        if help_requested?(subcommand, arguments)
          return print_help(stdout, stderr, gate: help_gate(subcommand, arguments))
        end
        return print_version(stdout, stderr) if subcommand == "version" && arguments.empty?
        return run_init(arguments, stdout: stdout, stderr: stderr, dir: dir) if subcommand == "init"

        nil
      end

      def run_init(arguments, stdout:, stderr:, dir:)
        require_relative "init_command" unless defined?(QualityGate::InitCommand)

        InitCommand.run(arguments, stdout: stdout, stderr: stderr, dir: dir)
      end

      def execute_command(subcommand, arguments, stdout:, stderr:, dir:, format:)
        unless GATE_SUBCOMMANDS.include?(subcommand)
          return invalid_command(subcommand, stdout: stdout, stderr: stderr, format: format)
        end

        emit_hook_warning(dir, stderr)
        run_gate(subcommand, arguments, stdout: stdout, stderr: stderr, dir: dir)
      end

      def run_gate(subcommand, arguments, stdout:, stderr:, dir:)
        overrides = parse(arguments)
        config = Config.load(dir: dir)
        return ExitCode::TOOL_FAILURE unless warn_unknown_keys(config, stderr)

        settings = config.to_h.merge(overrides)
        validate_paths!(settings.fetch(:files), dir)
        validate_simplecov_configuration!(subcommand, settings, config.path || File.join(dir, ".quality_gate.yml"))
        dispatch(subcommand, settings, stdout: stdout, stderr: stderr)
      end

      def emit_hook_warning(dir, stderr)
        path = File.join(dir, HookLog::DEFAULT_PATH)
        warning = HookLog.new(path: path).warning_line
        write_line(stderr, warning) if warning
      rescue StandardError
        nil
      end

      def report_option_error(error, stdout:, stderr:, format:)
        return report_json_error(error, stdout: stdout, stderr: stderr) if format == "json"

        write_error(stderr, error)
        usage(stderr)
        ExitCode::TOOL_FAILURE
      end

      def report_error(error, stdout:, stderr:, format:)
        return report_json_error(error, stdout: stdout, stderr: stderr) if format == "json"

        write_error(stderr, error)
        ExitCode::TOOL_FAILURE
      end

      def warn_unknown_keys(config, stderr)
        config.unknown_keys.all? do |key|
          write_diagnostic(stderr, "Warning", "unknown config key #{key}")
        end
      end

      def usage(stderr)
        write_line(stderr, "Usage: quality_gate <#{SUBCOMMANDS.join("|")}> [options]")
      end

      def write_line(io, message)
        io.puts message
        true
      rescue StandardError
        false
      end

      def write_diagnostic(io, prefix, detail)
        write_line(io, "#{prefix}: #{normalize_diagnostic(detail)}")
      end

      def write_error(io, error)
        write_diagnostic(io, "Error", error.message)
      rescue StandardError
        write_diagnostic(io, "Error", "quality_gate failed")
      end

      def normalize_diagnostic(detail)
        detail.to_s
              .encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�")
              .gsub(/(?:[[:cntrl:]]|[\u2028\u2029])+/, " ")
              .strip
      rescue StandardError
        "unavailable diagnostic"
      end

      def parse(arguments)
        overrides = {}
        option_parser(overrides).parse!(arguments)
        append_remaining_files(overrides, arguments)
        validate_files(overrides)

        overrides
      end

      def option_parser(overrides)
        OptionParser.new.tap do |parser|
          parser.on("--files PATH") do |path|
            raise OptionParser::InvalidOption, "--files" if overrides.key?(:files)

            overrides[:files] = [path]
          end
          parser.on("--format FORMAT", %w[text json]) { |format| overrides[:format] = format }
          parser.on("-h", "--help") { overrides[:help] = true }
        end
      end

      def append_remaining_files(overrides, arguments)
        if overrides.key?(:files)
          overrides[:files].concat(arguments)
        elsif arguments.any?
          raise OptionParser::InvalidOption, arguments.join(" ")
        end
      end

      def validate_files(overrides)
        return unless overrides.key?(:files) && overrides[:files].any?(&:empty?)

        raise OptionParser::InvalidArgument, "--files requires a non-empty path"
      end

      def validate_paths!(files, dir)
        missing = files.reject { |path| File.exist?(File.expand_path(path, dir)) }
        return if missing.empty?

        raise ArgumentError, "missing files or directories: #{missing.join(", ")}"
      end

      def validate_simplecov_configuration!(subcommand, settings, path)
        adapters = settings.fetch(:adapters).fetch(subcommand.to_sym)
        return unless adapters.include?("simplecov")

        coverage = settings.fetch(:coverage)
        return if coverage.is_a?(Hash) && %i[minimum_line minimum_branch].any? { coverage.key?(_1) }

        cause = "simplecov adapter requires coverage.minimum_line and/or coverage.minimum_branch"
        raise ConfigError.new(path: path, cause_message: cause)
      end

      def dispatch(subcommand, settings, stdout:, stderr:)
        config = Config.new(settings)
        diagnostic_io = terminal_diagnostic_io(stderr)
        result = Runner.new(
          adapters: adapters_for(subcommand, settings: settings, config: config, diagnostic_io: stderr),
          config: config,
          diagnostic_io: diagnostic_io
        ).call

        begin
          reporter_for(settings.fetch(:format), stdout: stdout).call(result)
        rescue StandardError => e
          write_error(stderr, e)
          return ExitCode::TOOL_FAILURE
        end

        result.exit_code
      end

      def adapters_for(subcommand, settings:, config:, diagnostic_io:)
        settings.fetch(:adapters).fetch(subcommand.to_sym).map do |adapter_name|
          build_adapter(
            adapter_name.to_s,
            config: config,
            files: settings.fetch(:files),
            diagnostic_io: diagnostic_io
          )
        end
      end

      def build_adapter(adapter_name, config:, files:, diagnostic_io:)
        registry.fetch(adapter_name) do
          return UnknownAdapter.new(adapter_name)
        end.new(config: config, files: files, diagnostic_io: diagnostic_io)
      end

      def reporter_for(format, stdout:)
        case format
        when "json"
          Reporters::Json.new(io: stdout)
        else
          Reporters::Text.new(io: stdout)
        end
      end

      def help_requested?(subcommand, arguments)
        return true if %w[-h --help].include?(subcommand)
        return true if subcommand == "help"

        (GATE_SUBCOMMANDS.include?(subcommand) || subcommand == "init") && help_argument?(arguments)
      end

      def help_argument?(arguments)
        arguments.take_while { _1 != "--" }.any? { %w[-h --help].include?(_1) }
      end

      def help_gate(subcommand, arguments)
        return arguments.find { GATE_SUBCOMMANDS.include?(_1) || _1 == "init" } if subcommand == "help"
        return "init" if subcommand == "init"
        return subcommand if GATE_SUBCOMMANDS.include?(subcommand)

        nil
      end

      def print_help(stdout, stderr, gate: nil)
        return write_help_failure(stderr) unless write_line(stdout, help_text(gate))

        ExitCode::CLEAN
      end

      def write_help_failure(stderr)
        write_diagnostic(stderr, "Error", "could not write help output")
        ExitCode::TOOL_FAILURE
      end

      def help_text(gate)
        return init_help_text if gate == "init"
        return gate_help_text(gate) if gate

        <<~TEXT
          Usage: quality_gate <fast|verify|audit|version|init> [options]

          Run one Quality Gate check for the current project.

          Commands:
            fast      RuboCop (quick feedback for selected files)
            verify    Reek, test_suite, and Undercover (tests and coverage)
            audit     Brakeman and bundler_audit (security checks)
            version   Print the Quality Gate version
            init      Install a plain Ruby project configuration

          Options:
            --files PATH [PATH ...]  Replace configured paths for this run; files and directories are allowed
            --format FORMAT         Choose text or json output (also accepts --format=FORMAT)
            -h, --help              Show this help

          Scope:
            Without --files, the configured files are used. With --files, the command-line paths replace them.
            RuboCop and Reek scan selected paths. The test suite runs in full; Undercover checks the Git diff.
            Brakeman scans the application and bundler-audit scans the lockfile.

          Examples:
            quality_gate fast
            quality_gate fast --files app/models/user.rb test/models
            quality_gate verify --format json

          Exit status:
            0  Checks completed cleanly
            1  Checks completed with findings
            2  Quality Gate could not complete (input, config, or tool failure)
        TEXT
      end

      def gate_help_text(gate)
        tools = GATE_TOOLS.fetch(gate).join(", ")

        <<~TEXT
          Usage: quality_gate #{gate} [options]

          Run the #{gate} gate using these default tools: #{tools}.

          Options:
            --files PATH [PATH ...]  Replace configured paths for this run; files and directories are allowed
            --format FORMAT         Choose text or json output (also accepts --format=FORMAT)
            -h, --help              Show this help

          Scope:
            Without --files, the configured files are used. With --files, the command-line paths replace them.
            RuboCop and Reek scan selected paths. The test suite runs in full; Undercover checks the Git diff.
            Brakeman scans the application and bundler-audit scans the lockfile.

          Examples:
            quality_gate #{gate}
            quality_gate #{gate} --files app/models/user.rb test/models
            quality_gate #{gate} --format json

          Exit status:
            0  Checks completed cleanly
            1  Checks completed with findings
            2  Quality Gate could not complete (input, config, or tool failure)
        TEXT
      end

      def init_help_text
        <<~TEXT
          Usage: quality_gate init [options]

          Install a plain Ruby Quality Gate configuration (Ruby is the default profile).

          Options:
            --profile PROFILE       Select the setup profile (ruby)
            --test-framework NAME   Select minitest or rspec
            --test-helper PATH      Use a custom test helper
            --test-command COMMAND  Override the test command
            --skip-coverage         Omit coverage and Undercover setup
            --agents                Install optional agent hooks and contracts
            --pretend               Preview changes without writing them
            -h, --help              Show this help

          Init writes a human-readable summary. Gate commands continue to support text and JSON output.

          Examples:
            quality_gate init
            quality_gate init --test-framework rspec
            quality_gate init --pretend
        TEXT
      end

      def requested_format(arguments)
        format = nil
        explicit = false
        arguments.take_while { _1 != "--" }.each_with_index do |argument, index|
          if argument.start_with?("--format=")
            explicit = true
            format = argument.delete_prefix("--format=")
          elsif argument == "--format"
            explicit = true
            format = arguments[index + 1]
          end
        end

        explicit && format.nil? ? :invalid : format
      end

      def configured_format(dir)
        return unless dir.is_a?(String)

        path = File.join(dir, ".quality_gate.yml")
        return unless File.file?(path)

        contents = File.read(path)
        document = YAML.safe_load(contents)
        format = document.is_a?(Hash) && document["format"]
        return format if %w[text json].include?(format)

        nil
      rescue Psych::Exception, SystemCallError, SystemStackError
        nil
      end

      def terminal_diagnostic_io(io)
        io if io.respond_to?(:tty?) && io.tty?
      rescue StandardError
        nil
      end

      def report_json_error(error, stdout:, stderr:)
        result = Runner::Result.new(
          findings: [Finding.tool_failure(tool: "quality_gate", message: safe_error_message(error))]
        )
        reporter_for("json", stdout: stdout).call(result)
        ExitCode::TOOL_FAILURE
      rescue StandardError => e
        write_error(stderr, e)
        ExitCode::TOOL_FAILURE
      end

      def safe_error_message(error)
        message = error.is_a?(String) ? error : error.message
        message.is_a?(String) ? message : message.to_s
      rescue StandardError
        "quality_gate failed"
      end

      def registry
        {
          "reek" => QualityGate::Adapters::Reek,
          "rubocop" => QualityGate::Adapters::RuboCop,
          "simplecov" => QualityGate::Adapters::SimpleCov,
          "test_suite" => QualityGate::Adapters::TestSuite,
          "undercover" => QualityGate::Adapters::Undercover,
          "brakeman" => QualityGate::Adapters::Brakeman,
          "bundler_audit" => QualityGate::Adapters::BundlerAudit
        }.freeze
      end

      UnknownAdapter = Data.define(:name) do
        def call
          [Finding.tool_failure(tool: name, message: "unknown adapter #{name}")]
        end
      end
      private_constant :UnknownAdapter
    end
  end
  # rubocop:enable Metrics/ClassLength
end
