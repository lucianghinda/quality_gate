# frozen_string_literal: true

require "optparse"

module QualityGate
  # Parses Doctor-specific options and renders a read-only preflight report.
  class DoctorCommand
    HELP = "Usage: quality_gate doctor [--format text|json] [--help]\n" \
      "Read-only preflight; configured gates and application code are not run.\n" \
      "Exit status: 0 ready, 1 warning or unchecked, 2 blocked or input/output failure."

    def initialize(dir:, registry:)
      @dir = dir
      @registry = registry
    end

    def run(arguments, stdout:, stderr:)
      run_options(parse(arguments), stdout:, stderr:)
    rescue StandardError => e
      render_failure(failure_check("input", e), requested_format(arguments), stdout:, stderr:)
    end

    private

    attr_reader :dir, :registry

    def parse(arguments)
      options = { format: "text", help: false }
      remaining = arguments.dup
      parser(options).parse!(remaining)
      reject_positionals(remaining)
      options
    end

    def reject_positionals(arguments)
      raise OptionParser::InvalidOption, arguments.join(" ") unless arguments.empty?
    end

    def run_options(options, stdout:, stderr:)
      return print_help(stdout, stderr) if options.fetch(:help)

      run_report(options, stdout)
    rescue StandardError => e
      render_failure(failure_check("doctor", e), options.fetch(:format), stdout:, stderr:)
    end

    def run_report(options, stdout)
      report = Doctor.new(dir:, registry:).call
      Reporters::Doctor.new(io: stdout).call(report, format: options.fetch(:format))
      report.exit_code
    end

    def parser(options)
      OptionParser.new(HELP) { register_options(_1, options) }
    end

    def register_options(parser, options)
      parser.on("--format FORMAT") { |format| select_format(format, options) }
      parser.on("-h", "--help") { options[:help] = true }
    end

    def select_format(format, options)
      raise OptionParser::InvalidArgument, format unless %w[text json].include?(format)

      options[:format] = format
    end

    def requested_format(arguments)
      arguments.take_while { _1 != "--" }.each_with_index.filter_map do |argument, index|
        format_option(argument, arguments[index + 1])
      end.last || "text"
    end

    def format_option(argument, next_argument)
      return next_argument if argument == "--format"

      argument.delete_prefix("--format=") if argument.start_with?("--format=")
    end

    def failure_check(id, error)
      DoctorReport.check(id:, status: "blocked", message: safe_message(error))
    end

    def render_failure(check, format, stdout:, stderr:)
      return report_json_failure(check, stdout, stderr) if format == "json"

      write_error(stderr, check.fetch("message"))
      ExitCode::TOOL_FAILURE
    end

    def report_json_failure(check, stdout, stderr)
      write_json_failure(check, stdout)
    rescue StandardError => e
      write_error(stderr, e)
      ExitCode::TOOL_FAILURE
    end

    def write_json_failure(check, stdout)
      report = DoctorReport.new(checks: [check])
      Reporters::Doctor.new(io: stdout).call(report, format: "json")
      ExitCode::TOOL_FAILURE
    end

    def safe_message(error)
      message = error.is_a?(String) ? error : error.message
      sanitize_message(message)
    rescue StandardError
      "quality_gate doctor failed"
    end

    def sanitize_message(message)
      message.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�")
             .gsub(/[[:cntrl:]\u2028\u2029]+/, " ").strip
    end

    def write_error(io, error)
      io.puts "Error: #{safe_message(error)}"
    rescue StandardError
      false
    end

    def print_help(stdout, stderr)
      stdout.puts parser({}).to_s
      ExitCode::CLEAN
    rescue StandardError => e
      write_error(stderr, e)
      ExitCode::TOOL_FAILURE
    end
  end
end
