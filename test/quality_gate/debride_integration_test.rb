# frozen_string_literal: true

require "test_helper"
require "json"
require "fileutils"
require "rbconfig"
require "stringio"
require "tmpdir"

module QualityGate
  class DebrideIntegrationTest < Minitest::Test
    def test_all_reporters_cover_clean_findings_and_diagnostics
      Dir.mktmpdir do |dir|
        producer = debride_producer(dir)
        reports = {
          clean: { "missing" => {} },
          findings: { "missing" => { "Example" => [["unused", "lib/example.rb:7-9"]] } },
          diagnostics: { "missing" => {} }
        }
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib/example.rb"), "")

        %w[text json markdown].product(reports.keys).each do |format, outcome|
          assert_report_case(dir, producer, { report: reports.fetch(outcome), format:, outcome: })
        end
      end
    end

    def test_rejects_invalid_selected_paths_before_running_the_analyzer
      Dir.mktmpdir do |dir|
        producer = debride_producer(dir, sentinel: File.join(dir, "called"))
        configure(dir, producer:)
        status, _stdout, stderr = run_deep(dir, %w[--files missing.rb])

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_includes stderr, "missing files or directories"
        refute_path_exists File.join(dir, "called")
      end
    end

    def test_missing_optional_executable_has_an_actionable_failure
      Dir.mktmpdir do |dir|
        configure(dir, producer: ["debride-quality-gate-missing"])
        status, stdout, _stderr = run_deep(dir, %w[--format json])

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_includes JSON.parse(stdout).fetch("findings").first.fetch("message"), "debride"
      end
    end

    def test_debride_command_and_timeout_overrides_are_loaded
      Dir.mktmpdir do |dir|
        producer = debride_producer(dir)
        configure(dir, producer:, options: { timeout: 2 })
        adapter = Adapters::Debride.new(config: Config.load(dir:))

        assert_equal [*producer, "--json", "."], adapter.command
        assert_equal 2, adapter.timeout
      end
    end

    def test_both_deep_analyzers_dispatch_in_configured_order
      Dir.mktmpdir do |dir|
        debride = debride_producer(dir)
        rubycritic = rubycritic_producer(dir)
        settings = {
          "adapters" => { "deep" => %w[rubycritic debride] },
          "commands" => { "deep" => { "rubycritic" => rubycritic, "debride" => debride } }
        }
        File.write(File.join(dir, ".quality_gate.yml"), JSON.generate(settings))
        status, stdout, stderr = run_deep(dir, %w[--format json])

        assert_equal ExitCode::CLEAN, status, "#{stdout}\n#{stderr}"
        tools = JSON.parse(stdout).fetch("checks").map { _1.fetch("tool") }
        assert_equal %w[rubycritic debride], tools
      end
    end

    private

    def assert_report_case(dir, producer, options)
      report = options.fetch(:report)
      format = options.fetch(:format)
      outcome = options.fetch(:outcome)
      warning = outcome == :diagnostics
      configure(dir, producer:, options: { format:, files: ["lib/example.rb"] })
      with_env("DEBRIDE_WARNING", warning ? "1" : nil) do
        with_env("DEBRIDE_REPORT", JSON.generate(report)) do
          status, stdout, stderr = run_deep(dir, %w[--files lib/example.rb])
          assert_equal expected_status(outcome), status, stderr
          assert_report_output(stdout, format, outcome)
          assert_includes stdout, "warning" if warning
          assert_empty stderr
        end
      end
    end

    def assert_report_output(stdout, format, outcome)
      unless format == "json"
        assert_includes stdout, "debride"
        assert_includes stdout, "project"
        return
      end

      payload = JSON.parse(stdout)
      assert_equal "project", payload.fetch("checks").first.fetch("scope")
      assert_empty payload.fetch("checks").first.fetch("requested_files")
      return unless outcome == :findings

      assert_equal "potentially_unused_method", payload.fetch("findings").first.fetch("rule")
    end

    def expected_status(outcome)
      { clean: 0, findings: 1, diagnostics: 2 }.fetch(outcome)
    end

    def run_deep(dir, arguments = [])
      stdout = StringIO.new
      stderr = StringIO.new
      status = CLI.run(["deep", *arguments], stdout:, stderr:, dir:)
      [status, stdout.string, stderr.string]
    end

    def debride_producer(dir, sentinel: nil)
      path = File.join(dir, "debride-producer.rb")
      source = <<~RUBY
        # frozen_string_literal: true
        File.write(#{sentinel.inspect}, "called") if #{sentinel ? "true" : "false"}
        abort("unexpected argv: #{ARGV.inspect}") unless ARGV == ["--json", "."]
        $stderr.write("warning\n") if ENV["DEBRIDE_WARNING"] == "1"
        puts ENV.fetch("DEBRIDE_REPORT", %({"missing":{}}))
      RUBY
      File.write(path, source)
      [RbConfig.ruby, path]
    end

    def rubycritic_producer(dir)
      path = File.join(dir, "rubycritic-producer.rb")
      File.write(path, <<~RUBY)
        # frozen_string_literal: true
        require "json"
        report_dir = ARGV.fetch(ARGV.index("--path") + 1)
        File.write(File.join(report_dir, "report.json"), JSON.generate(
          "metadata" => { "rubycritic" => { "version" => "5.0.0" } },
          "score" => 100.0,
          "analysed_modules" => [{ "path" => "lib/example.rb", "smells" => [] }]
        ))
      RUBY
      [RbConfig.ruby, path]
    end

    def configure(dir, producer:, options: {})
      settings = {
        "adapters" => { "deep" => ["debride"] },
        "commands" => { "deep" => { "debride" => producer } },
        "files" => options.fetch(:files, []),
        "format" => options.fetch(:format, "text")
      }
      timeout = options.fetch(:timeout, nil)
      settings["timeouts"] = { "debride" => timeout } if timeout
      File.write(File.join(dir, ".quality_gate.yml"), JSON.generate(settings))
    end

    def with_env(key, value)
      previous = ENV[key]
      ENV[key] = value
      yield
    ensure
      ENV[key] = previous
    end
  end
end
