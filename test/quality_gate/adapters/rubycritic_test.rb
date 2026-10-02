# frozen_string_literal: true

require "json"
require "rbconfig"
require "tmpdir"
require "test_helper"
require_relative "../../../lib/quality_gate/adapters/rubycritic"

module QualityGate
  module Adapters
    class RubyCriticTest < Minitest::Test
      def test_name_and_default_command_use_a_report_path_without_creating_it
        adapter = build_adapter

        assert_equal "rubycritic", adapter.name
        command = adapter.command
        output_directory = command.fetch(command.index("--path") + 1)

        assert_equal %w[rubycritic --format json --no-browser --minimum-score 0 --path], command.first(7)
        assert_equal ".", command.last
        assert_equal File.expand_path(output_directory), output_directory
        refute_path_exists output_directory
      end

      def test_command_uses_configured_launcher_prefix
        adapter = build_adapter(launcher: [RbConfig.ruby, "-e", "exit 0"])

        assert_equal [RbConfig.ruby, "-e", "exit 0"], adapter.command.first(3)
        assert_includes adapter.command, "--format"
      end

      def test_parse_returns_no_findings_for_a_clean_report
        assert_empty build_adapter.parse(JSON.generate(valid_report))
      end

      def test_parse_accepts_empty_context_and_message_strings
        report = report_with_smell
        smell = report.fetch("analysed_modules").first.fetch("smells").first
        smell["context"] = ""
        smell["message"] = ""

        finding = build_adapter.parse(JSON.generate(report)).first

        assert_equal "", finding.message
      end

      def test_parse_builds_one_warning_finding_for_each_reported_location
        findings = build_adapter.parse(JSON.generate(report_with_smell))

        assert_equal [
          Finding.new(
            tool: "rubycritic",
            file: "app/models/user.rb",
            line: 12,
            rule: "TooManyStatements",
            severity: :warning,
            message: "User#active? has too many statements"
          ),
          Finding.new(
            tool: "rubycritic",
            file: "app/models/user.rb",
            line: 18,
            rule: "TooManyStatements",
            severity: :warning,
            message: "User#active? has too many statements"
          )
        ], findings
      end

      def test_parse_coalesces_identical_findings_reported_by_multiple_modules
        duplicated_modules = Array.new(2) { report_with_smell.fetch("analysed_modules").first }
        report = valid_report.merge("analysed_modules" => duplicated_modules)

        findings = build_adapter.parse(JSON.generate(report))

        assert_equal 2, findings.length
        assert_equal findings.uniq, findings
      end

      def test_parse_rejects_empty_analysed_modules
        error = assert_raises(ParseError) do
          build_adapter.parse(JSON.generate(valid_report.merge("analysed_modules" => [])))
        end

        assert_equal "rubycritic", error.tool
      end

      def test_parse_rejects_any_malformed_report_entry
        invalid_reports.each do |report|
          assert_raises(ParseError) { build_adapter.parse(JSON.generate(report)) }
        end
      end

      def test_call_rejects_nonzero_exit_even_when_report_is_valid
        adapter = build_adapter(launcher: ruby_script(<<~RUBY))
          report = File.join(ARGV.fetch(ARGV.index("--path") + 1), "report.json")
          File.write(report, JSON.generate(#{valid_report.inspect}))
          warn "RubyCritic failed"
          exit 2
        RUBY

        finding = adapter.call.fetch(0)

        assert finding.tool_failure?
        assert_equal :error, finding.severity
        assert_includes finding.message, "rubycritic"
        assert_includes finding.message, "RubyCritic failed"
      end

      def test_call_reports_missing_and_malformed_report_files
        missing = build_adapter(launcher: ruby_script("exit 0"))
        assert missing.call.fetch(0).tool_failure?

        malformed = build_adapter(launcher: ruby_script(malformed_report_script))
        assert malformed.call.fetch(0).tool_failure?
      end

      def test_call_cleans_report_directory_after_malformed_output
        Dir.mktmpdir do |parent|
          directory_file = File.join(parent, "report-directory")
          adapter = build_adapter(launcher: ruby_script(malformed_report_script(directory_file)))

          assert adapter.call.fetch(0).tool_failure?
          refute_path_exists File.read(directory_file)
        end
      end

      def test_call_reports_a_timed_out_process
        adapter = build_adapter(launcher: ruby_script("sleep 3"), timeout: 1)

        finding = adapter.call.fetch(0)

        assert finding.tool_failure?
        assert_includes finding.message, "timeout"
      end

      def test_call_rejects_a_signaled_process_even_if_it_writes_valid_json
        adapter = build_adapter(launcher: ruby_script(<<~RUBY))
          report = File.join(ARGV.fetch(ARGV.index("--path") + 1), "report.json")
          File.write(report, JSON.generate(#{valid_report.inspect}))
          Process.kill("TERM", Process.pid)
        RUBY

        assert adapter.call.fetch(0).tool_failure?
      end

      def test_call_fails_and_cleans_up_when_process_status_is_missing
        Dir.mktmpdir do |parent|
          directory_file = File.join(parent, "report-directory")
          adapter = adapter_without_status(directory_file)

          finding = adapter.call.fetch(0)

          assert finding.tool_failure?
          assert_includes finding.message, "process status unavailable"
          refute_path_exists File.read(directory_file)
        end
      end

      def test_call_uses_a_fresh_report_path_for_each_invocation
        Dir.mktmpdir do |dir|
          paths_file = File.join(dir, "paths")
          adapter = recording_adapter(paths_file)

          assert_empty adapter.call
          assert_empty adapter.call
          assert_fresh_report_paths(paths_file)
        end
      end

      private

      def invalid_reports
        invalid_root_reports + invalid_score_reports + invalid_module_reports + invalid_smell_reports
      end

      def invalid_root_reports
        [
          [],
          valid_report.except("metadata"),
          valid_report.merge("metadata" => nil),
          valid_report.merge("metadata" => {}),
          valid_report.merge("metadata" => { "rubycritic" => nil }),
          valid_report.merge("metadata" => { "rubycritic" => { "version" => "" } })
        ]
      end

      def invalid_score_reports
        [
          valid_report.merge("score" => "100"),
          valid_report.merge("score" => -1),
          valid_report.merge("score" => 101)
        ]
      end

      def invalid_module_reports
        [
          valid_report.merge("analysed_modules" => ["bad"]),
          valid_report.merge("analysed_modules" => [{ "path" => "", "smells" => [] }]),
          valid_report.merge("analysed_modules" => [{ "path" => "file.rb", "smells" => {} }]),
          report_with_smell.merge("analysed_modules" => [{ "path" => "file.rb", "smells" => ["bad"] }])
        ]
      end

      def invalid_smell_reports
        malformed_smell_reports + invalid_location_reports
      end

      def malformed_smell_reports
        [
          malformed_smell("type" => 7),
          malformed_smell("context" => nil),
          malformed_smell("message" => 7),
          malformed_smell("locations" => []),
          malformed_smell("locations" => ["bad"])
        ]
      end

      def invalid_location_reports
        [
          malformed_smell("locations" => [{ "path" => "", "line" => 1 }]),
          malformed_smell("locations" => [{ "pathname" => "file.rb", "line" => 1 }]),
          malformed_smell("locations" => [{ "path" => "file.rb", "line" => -1 }]),
          malformed_smell("locations" => [{ "path" => "file.rb", "line" => "1" }])
        ]
      end

      def build_adapter(launcher: nil, timeout: 5)
        commands = { deep: {} }
        commands.fetch(:deep)[:rubycritic] = launcher if launcher
        settings = Config.defaults.merge(
          commands: Config.defaults.fetch(:commands).merge(commands),
          timeouts: Config.defaults.fetch(:timeouts).merge(rubycritic: timeout)
        )
        RubyCritic.new(config: Config.new(settings))
      end

      def adapter_without_status(directory_file)
        build_adapter.tap do |adapter|
          adapter.define_singleton_method(:capture) do |argv, _timeout|
            directory = argv.fetch(argv.index("--path") + 1)
            File.write(directory_file, directory)
            ["", "process status unavailable", nil]
          end
        end
      end

      def valid_report
        {
          "metadata" => { "rubycritic" => { "version" => "5.0.0" } },
          "score" => 100.0,
          "analysed_modules" => [{ "path" => "app/models/user.rb", "smells" => [] }]
        }
      end

      def report_with_smell
        valid_report.merge(
          "analysed_modules" => [
            {
              "path" => "app/models/user.rb",
              "smells" => [{
                "type" => "TooManyStatements",
                "context" => "User#active?",
                "message" => "has too many statements",
                "locations" => [
                  { "path" => "app/models/user.rb", "line" => 12 },
                  { "path" => "app/models/user.rb", "line" => 18 }
                ]
              }]
            }
          ]
        )
      end

      def malformed_smell(overrides)
        JSON.parse(JSON.generate(report_with_smell)).tap do |report|
          report.fetch("analysed_modules").first.fetch("smells").first.merge!(overrides)
        end
      end

      def malformed_report_script(directory_file = nil)
        <<~RUBY
          directory = ARGV.fetch(ARGV.index("--path") + 1)
          report = File.join(directory, "report.json")
          File.write(report, "not json")
          File.write(#{directory_file.inspect}, directory) unless #{directory_file.nil?}
        RUBY
      end

      def recording_adapter(paths_file)
        script = <<~RUBY
          require "json"
          directory = ARGV.fetch(ARGV.index("--path") + 1)
          report = File.join(directory, "report.json")
          File.write(report, JSON.generate(#{valid_report.inspect}))
          File.open(#{paths_file.inspect}, "a") { |file| file.puts(directory) }
          puts "human score output is ignored"
        RUBY
        build_adapter(launcher: [RbConfig.ruby, "-e", script, "--"])
      end

      def assert_fresh_report_paths(paths_file)
        paths = File.readlines(paths_file, chomp: true)
        assert_equal 2, paths.uniq.length
        paths.each { refute_path_exists _1 }
      end

      def ruby_script(script) = [RbConfig.ruby, "-rjson", "-e", script, "--"]
    end
  end
end
