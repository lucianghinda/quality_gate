# frozen_string_literal: true

require "test_helper"

require "fileutils"
require "json"
require "tmpdir"

module QualityGate
  module Adapters
    class UndercoverContractTest < Minitest::Test
      class OutputUndercover < Undercover
        def initialize(output:, **keywords)
          super(**keywords)
          @output = output
        end

        private

        def capture(_argv, _timeout_seconds, **_options)
          status = Object.new.tap do |result|
            result.define_singleton_method(:exited?) { true }
            result.define_singleton_method(:exitstatus) { 0 }
          end
          ["#{@output}\nUndercover finished in 0.0123s\n", "", status]
        end
      end

      def test_parse_rejects_stale_validation_and_invalid_summary_contracts
        invalid_documents.each do |label, document|
          error = assert_raises(ParseError, label) { build_adapter.parse(JSON.generate(document)) }

          assert_equal "undercover", error.tool, label
        end
      end

      def test_invalid_documents_become_one_standard_tool_failure_through_call
        Dir.mktmpdir do |dir|
          write_coverage_record(dir)

          invalid_documents.each do |label, document|
            findings = Dir.chdir(dir) { output_adapter(document).call }

            assert_equal 1, findings.length, label
            assert findings.fetch(0).tool_failure?, label
            assert_equal "undercover", findings.fetch(0).tool, label
          end
        end
      end

      private

      def build_adapter
        Undercover.new(config: Config.new(Config.defaults))
      end

      def output_adapter(document)
        OutputUndercover.new(
          output: JSON.generate(document),
          config: Config.new(Config.defaults.merge(compare_point: "HEAD~1"))
        )
      end

      def clean_document
        { "warnings" => [], "summary" => { "total_warnings" => 0, "files_affected" => 0 } }
      end

      def invalid_documents
        warnings = JSON.parse(File.read(File.expand_path("../../fixtures/undercover/warnings_report.json", __dir__)))

        {
          "non-nil validation" => clean_document.merge("validation" => "stale_coverage"),
          "missing summary" => { "warnings" => [] },
          "non-mapping summary" => { "warnings" => [], "summary" => [] },
          "missing total_warnings" => {
            "warnings" => [], "summary" => { "files_affected" => 0 }
          },
          "missing files_affected" => {
            "warnings" => [], "summary" => { "total_warnings" => 0 }
          },
          "non-integer total_warnings" => {
            "warnings" => [], "summary" => { "total_warnings" => "0", "files_affected" => 0 }
          },
          "non-integer files_affected" => {
            "warnings" => [], "summary" => { "total_warnings" => 0, "files_affected" => 0.0 }
          },
          "negative total_warnings" => {
            "warnings" => [], "summary" => { "total_warnings" => -1, "files_affected" => 0 }
          },
          "negative files_affected" => {
            "warnings" => [], "summary" => { "total_warnings" => 0, "files_affected" => -1 }
          },
          "warning count mismatch" => {
            "warnings" => [], "summary" => { "total_warnings" => 1, "files_affected" => 0 }
          },
          "affected file count mismatch" => warnings.merge(
            "summary" => { "total_warnings" => 2, "files_affected" => 1 }
          )
        }
      end

      def write_coverage_record(dir)
        path = File.join(dir, Undercover::COVERAGE_PATH)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "{}")
      end
    end
  end
end
