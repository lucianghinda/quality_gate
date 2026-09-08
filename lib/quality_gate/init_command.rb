# frozen_string_literal: true

require "optparse"

module QualityGate
  # Parses and executes the framework-independent project initializer.
  class InitCommand
    class << self
      def run(arguments, stdout:, stderr:, dir:)
        installer(parse(arguments), dir: dir, stdout: stdout).call
      rescue OptionParser::ParseError, ArgumentError => e
        report_failure(e, stderr)
      end

      private

      def parse(arguments)
        reject_format!(arguments)
        options = { profile: "ruby", skip_coverage: false, agents: false, pretend: false }
        option_parser(options).parse!(arguments)
        raise OptionParser::InvalidOption, arguments.join(" ") if arguments.any?

        options
      end

      def installer(options, dir:, stdout:)
        require_relative "installer"

        Installer.new(destination_root: dir, options: options, stdout: stdout)
      end

      def reject_format!(arguments = nil)
        return unless arguments.nil? || arguments.any? { _1 == "--format" || _1.start_with?("--format=") }

        raise OptionParser::InvalidArgument, "init does not support --format; init output is text only"
      end

      def option_parser(options)
        OptionParser.new.tap { |parser| parser_definitions(parser, options) }
      end

      def parser_definitions(parser, options)
        profile_options(parser, options)
        test_options(parser, options)
        boolean_options(parser, options)
        parser.on("--format FORMAT") { reject_format! }
        parser.on("-h", "--help") { options[:help] = true }
      end

      def profile_options(parser, options)
        parser.on("--profile PROFILE", %w[ruby]) { |profile| options[:profile] = profile }
        parser.on("--test-framework FRAMEWORK", %w[minitest rspec]) do |framework|
          options[:test_framework] = framework
        end
      end

      def test_options(parser, options)
        parser.on("--test-helper PATH") { |path| options[:test_helper] = path }
        parser.on("--test-command COMMAND") { |command| options[:test_command] = command }
      end

      def boolean_options(parser, options)
        parser.on("--skip-coverage") { options[:skip_coverage] = true }
        parser.on("--agents") { options[:agents] = true }
        parser.on("--pretend") { options[:pretend] = true }
      end

      def report_failure(error, stderr)
        report_error(error, stderr)
        write_line(stderr, "Usage: quality_gate init [options]") if error.is_a?(OptionParser::ParseError)
        ExitCode::TOOL_FAILURE
      end

      def report_error(error, stderr)
        write_line(stderr, "Error: #{error.message}")
        ExitCode::TOOL_FAILURE
      rescue StandardError
        write_line(stderr, "Error: quality_gate init failed")
        ExitCode::TOOL_FAILURE
      end

      def write_line(io, message)
        io.puts(message)
        true
      rescue StandardError
        false
      end
    end
  end
end
