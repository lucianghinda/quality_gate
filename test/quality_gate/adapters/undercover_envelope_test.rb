# frozen_string_literal: true

require "test_helper"

require "json"
require "fileutils"
require "rbconfig"
require "tmpdir"

module QualityGate
  module Adapters
    class UndercoverEnvelopeTest < Minitest::Test
      PROCESS_SCRIPT = <<~'RUBY'
        STDOUT.write(ARGV.fetch(0))
        STDERR.write(ARGV.fetch(1))
        STDOUT.flush
        STDERR.flush

        completion = ARGV.fetch(2)
        if completion.start_with?("signal:")
          Process.kill(completion.delete_prefix("signal:"), Process.pid)
          sleep 1
        end

        exit Integer(completion)
      RUBY

      class CommandUndercover < Undercover
        def initialize(command:, **keywords)
          super(**keywords)
          @command = command
        end

        attr_reader :command
      end

      class CapturedUndercover < Undercover
        def initialize(stdout:, stderr:, status:, **keywords)
          super(**keywords)
          @stdout = stdout
          @stderr = stderr
          @status = status
        end

        def command = ["undercover"]

        private

        def capture(_argv, _timeout_seconds, **_options)
          [@stdout, @stderr, @status]
        end
      end

      def test_call_rejects_valid_clean_json_when_undercover_exits_two
        findings = call_adapter(clean_document, completion: 2)

        assert_tool_failure(findings)
      end

      def test_call_rejects_signaled_completion
        findings = call_adapter(clean_document, completion: "signal:TERM")

        assert_tool_failure(findings)
      end

      def test_call_rejects_a_missing_process_status
        findings = with_coverage_record do
          CapturedUndercover.new(
            stdout: cli_output(clean_document),
            stderr: "",
            status: nil,
            config: Config.new(Config.defaults.merge(compare_point: "HEAD~1"))
          ).call
        end

        assert_tool_failure(findings)
      end

      def test_call_rejects_a_missing_footer
        findings = call_output(JSON.generate(clean_document), completion: 0)

        assert_tool_failure(findings)
      end

      def test_call_rejects_a_malformed_footer
        output = cli_output(clean_document, footer: "Undercover finished in fast")

        assert_tool_failure(call_output(output, completion: 0))
      end

      def test_call_rejects_a_nonterminal_footer
        output = "#{cli_output(clean_document)}unexpected trailing output\n"

        assert_tool_failure(call_output(output, completion: 0))
      end

      def test_call_rejects_nonempty_stderr
        findings = call_adapter(clean_document, completion: 0, stderr: "diagnostic\n")

        assert_tool_failure(findings)
      end

      def test_call_rejects_exit_zero_with_warnings
        findings = call_adapter(warning_document, completion: 0)

        assert_tool_failure(findings)
      end

      def test_call_rejects_exit_one_with_a_clean_report
        findings = call_adapter(clean_document, completion: 1)

        assert_tool_failure(findings)
      end

      def test_call_accepts_exit_zero_with_a_clean_report_and_exact_footer
        assert_empty call_adapter(clean_document, completion: 0)
      end

      def test_call_accepts_whitespace_only_stderr
        assert_empty call_adapter(clean_document, completion: 0, stderr: " \n\t")
      end

      def test_call_accepts_exit_one_with_warnings_and_exact_footer
        findings = call_adapter(warning_document, completion: 1)

        assert_equal 2, findings.length
        assert(findings.all? { _1.rule == "uncovered_code" })
        refute findings.any?(&:tool_failure?)
      end

      private

      def call_adapter(document, completion:, stderr: "")
        call_output(cli_output(document), completion:, stderr:)
      end

      def call_output(stdout, completion:, stderr: "")
        with_coverage_record do
          adapter = CommandUndercover.new(
            command: [RbConfig.ruby, "-e", PROCESS_SCRIPT, stdout, stderr, completion.to_s],
            config: Config.new(Config.defaults.merge(compare_point: "HEAD~1"))
          )
          adapter.call
        end
      end

      def cli_output(document, footer: "Undercover finished in 0.0123s")
        "#{JSON.generate(document)}\n#{footer}\n"
      end

      def clean_document
        { "warnings" => [], "summary" => { "total_warnings" => 0, "files_affected" => 0 } }
      end

      def warning_document
        JSON.parse(File.read(File.expand_path("../../fixtures/undercover/warnings_report.json", __dir__)))
      end

      def with_coverage_record(&block)
        Dir.mktmpdir do |dir|
          path = File.join(dir, Undercover::COVERAGE_PATH)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, "{}")
          Dir.chdir(dir, &block)
        end
      end

      def assert_tool_failure(findings, label = nil)
        assert_equal 1, findings.length, label
        finding = findings.fetch(0)
        assert finding.tool_failure?, label
        assert_equal "undercover", finding.tool, label
        assert_equal :error, finding.severity, label
      end
    end
  end
end
