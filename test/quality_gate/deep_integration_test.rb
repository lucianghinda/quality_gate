# frozen_string_literal: true

require "test_helper"

require "fileutils"
require "json"
require "rbconfig"
require "stringio"
require "tmpdir"
require "yaml"

module QualityGate
  # Exercises the optional deep gate through the real CLI and a RubyCritic-shaped process.
  class DeepIntegrationTest < Minitest::Test
    def test_deep_gate_formats_cover_clean_findings_and_tool_failures
      %w[text json markdown].product(%i[clean findings failure]).each do |format, outcome|
        in_project(format:, outcome:) do |dir|
          status, stdout, stderr = run_deep(dir)

          assert_equal expected_exit_code(outcome), status, "#{format} #{outcome}: #{stdout} #{stderr}"
          assert_empty stderr
          assert_report(format, outcome, stdout)
        end
      end
    end

    def test_deep_gate_ignores_selected_files_and_reports_project_scope
      in_project(format: "json", outcome: :findings) do |dir|
        status, stdout, stderr = run_deep(dir, "--files", "test/selected.rb")
        report = JSON.parse(stdout)

        assert_equal ExitCode::FINDINGS, status
        assert_empty stderr
        assert_project_scope(report)
      end
    end

    def test_deep_default_reports_an_actionable_missing_optional_analyzer
      in_project do |dir|
        FileUtils.rm_f(File.join(dir, ".quality_gate.yml"))
        with_minimal_path do
          status, stdout, stderr = run_deep(dir, "--format", "json")
          finding = JSON.parse(stdout).fetch("findings").first

          assert_missing_analyzer_failure(status, stderr, finding)
        end
      end
    end

    def test_deep_gate_reports_unknown_adapters_as_tool_failures
      in_project do |dir|
        File.write(File.join(dir, ".quality_gate.yml"), "adapters:\n  deep:\n    - missing_critic\n")
        status, stdout, stderr = run_deep(dir)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stderr
        assert_includes stdout, "unknown adapter missing_critic"
      end
    end

    def test_deep_gate_rejects_missing_selected_paths_before_running_analyzer
      in_project do |dir|
        status, stdout, stderr = run_deep(dir, "--files", "test/missing.rb")

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_includes stderr, "missing files or directories: test/missing.rb"
      end
    end

    private

    def in_project(format: "text", outcome: :clean)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        FileUtils.mkdir_p(File.join(dir, "test"))
        File.write(File.join(dir, "lib", "example.rb"), "module Example; end\n")
        File.write(File.join(dir, "test", "selected.rb"), "# selected file\n")
        write_producer(dir, outcome)
        write_config(dir, format)
        yield dir
      end
    end

    def write_producer(dir, outcome)
      exit_status = outcome == :failure ? 7 : 0
      smells = outcome == :findings ? [smell] : []
      score = outcome == :findings ? 80 : 100
      report = { "metadata" => { "rubycritic" => { "version" => "5.0.0" } }, "score" => score,
                 "analysed_modules" => [{ "path" => "lib/example.rb", "smells" => smells }] }
      report_json = JSON.generate(report)
      script = <<~RUBY
        require "json"
        expected = [["--format", "json"], ["--minimum-score", "0"]]
        abort "missing RubyCritic flags" unless expected.all? { |flag, value| ARGV[ARGV.index(flag) + 1] == value }
        abort "missing RubyCritic flags" unless ARGV.include?("--no-browser")
        abort "expected a whole-project scan" unless ARGV.last == "."
        output_path = ARGV.fetch(ARGV.index("--path") + 1)
        File.write(File.join(output_path, "report.json"), #{report_json.dump})
        exit #{exit_status}
      RUBY
      File.write(File.join(dir, "rubycritic.rb"), script)
    end

    def smell
      {
        "type" => "HighComplexity", "context" => "Example#work", "message" => "complex method",
        "locations" => [{ "path" => "lib/example.rb", "line" => 2 }]
      }
    end

    def write_config(dir, format)
      settings = {
        "format" => format,
        "commands" => { "deep" => { "rubycritic" => [RbConfig.ruby, File.join(dir, "rubycritic.rb")] } }
      }
      File.write(File.join(dir, ".quality_gate.yml"), YAML.dump(settings))
    end

    def run_deep(dir, *arguments)
      stdout = StringIO.new
      stderr = StringIO.new
      status = CLI.run(["deep", *arguments], stdout:, stderr:, dir:)

      [status, stdout.string, stderr.string]
    end

    def expected_exit_code(outcome)
      { clean: ExitCode::CLEAN, findings: ExitCode::FINDINGS, failure: ExitCode::TOOL_FAILURE }.fetch(outcome)
    end

    def assert_project_scope(report)
      check = report.fetch("checks").first

      assert_equal "project", check.fetch("scope")
      assert_empty check.fetch("requested_files")
      assert_equal "lib/example.rb", report.fetch("findings").first.fetch("file")
    end

    def assert_missing_analyzer_failure(status, stderr, finding)
      assert_equal ExitCode::TOOL_FAILURE, status
      assert_empty stderr
      assert_equal "rubycritic", finding.fetch("tool")
      assert_equal "tool_failure", finding.fetch("rule")
      assert_match(/RubyCritic|rubycritic/i, finding.fetch("message"))
    end

    def with_minimal_path
      original_path = ENV.fetch("PATH", "")
      ENV["PATH"] = File.dirname(RbConfig.ruby)
      yield
    ensure
      ENV["PATH"] = original_path
    end

    def assert_report(format, outcome, stdout)
      case format
      when "json"
        report = JSON.parse(stdout)
        expected_findings = outcome == :clean ? 0 : 1
        expected_failures = outcome == :failure ? 1 : 0
        assert_equal expected_findings, report.fetch("summary").fetch("findings")
        assert_equal expected_failures, report.fetch("summary").fetch("tool_failures")
      when "markdown"
        assert_includes stdout, "rubycritic"
        fragment = { clean: "0 findings", findings: "complex method", failure: "1 tool failures" }.fetch(outcome)
        assert_includes stdout, fragment
      else
        fragment = { clean: "0 findings", findings: "1 findings", failure: "tool_failure" }.fetch(outcome)
        assert_includes stdout, fragment
      end
    end
  end
end
