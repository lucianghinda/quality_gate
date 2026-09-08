# frozen_string_literal: true

require "fileutils"
require "tempfile"

module QualityGate
  module Adapters
    # Runs the project's full test suite with coverage recording enabled.
    class TestSuite < Adapter
      TAIL_LINES = 20
      LOG_DIRECTORY = File.join("log", "quality_gate").freeze

      DEFAULT_COMMAND = %w[bin/rails test].map!(&:freeze).freeze
      ENVIRONMENT = { "COVERAGE" => "1" }.freeze
      private_constant :DEFAULT_COMMAND, :ENVIRONMENT, :LOG_DIRECTORY

      def name = "test_suite"

      def command
        config.fetch(:commands).fetch(:verify).fetch(:test_suite, DEFAULT_COMMAND)
      end

      def env = ENVIRONMENT

      def call
        tool = name
        stderr = +""
        argv = validated_command
        stdout, stderr, status = capture(argv, resolved_timeout(tool), env:, combine_output: true)
        return [] if status.success?

        [failed_test_finding(stdout, stderr)]
      # capture raises on a timeout before returning buffered output, so those
      # failures retain the standard adapter diagnostic without a test log.
      rescue StandardError => e
        [failure_finding(tool, e, stderr)]
      end

      private

      def failed_test_finding(stdout, stderr)
        test_failure(stdout, stderr, log_path: write_failure_log(stdout, stderr))
      rescue StandardError => e
        test_failure(stdout, stderr, log_error: e)
      end

      def test_failure(stdout, stderr, log_path: nil, log_error: nil)
        message = output_tail(stdout, stderr)
        message = "#{message}\nFull test output: #{log_path}" if log_path
        if log_error
          message = "#{message}\nCould not write full test output log: " \
                    "#{log_error.class}: #{log_error.message}"
        end

        Finding.new(
          tool: name,
          file: "",
          line: 0,
          rule: "test_failure",
          severity: :error,
          message:
        )
      end

      def write_failure_log(stdout, stderr)
        FileUtils.mkdir_p(LOG_DIRECTORY)
        log = Tempfile.create(["test-suite-", ".log"], LOG_DIRECTORY)
        log.write(stdout.to_s)
        log.write(stderr.to_s)
        log.flush
        log.path
      ensure
        log&.close
      end

      def output_tail(*streams)
        streams.flat_map(&:lines).last(TAIL_LINES).join.chomp
      end
    end
  end
end
