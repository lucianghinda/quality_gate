# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "stringio"
require "tmpdir"
require "rbconfig"
require "yaml"
require "quality_gate/doctor_report"
require "quality_gate/reporters/doctor"
require "quality_gate/doctor_command"

module QualityGate
  class DoctorCommandTest < Minitest::Test
    Result = Data.define(:status, :stdout, :stderr)
    SentinelState = Data.define(:marker, :contents, :dir, :cwd)

    def test_rejected_files_option_uses_the_doctor_json_envelope
      assert_json_input_failure(command_result(%w[--format json --files app.rb]))
      assert_json_input_failure(command_result(%w[--format=json --files app.rb]))
    end

    def test_last_format_option_controls_invalid_input_reporting
      result = command_result(%w[--format json --format text --unknown])

      assert_equal ExitCode::TOOL_FAILURE, result.status
      assert_empty result.stdout
      assert_match(/Error:.*unknown/, result.stderr)
    end

    def test_markdown_unknown_options_and_positionals_are_rejected
      [%w[--format markdown], %w[--format j], %w[--unknown]].each do |arguments|
        result = command_result(arguments)
        assert_text_input_failure(result)
      end

      [%w[--format json --unknown], %w[--format json extra]].each do |arguments|
        assert_json_input_failure(command_result(arguments))
      end
    end

    def test_format_after_option_terminator_is_positional_input
      assert_json_input_failure(command_result(%w[--format json -- --format=text]))
    end

    def test_doctor_default_text_ignores_the_configured_gate_format
      in_project do |dir|
        File.write(File.join(dir, ".quality_gate.yml"), project_config(format: "markdown"))
        result = run_cli(%w[doctor], dir:)

        assert_equal ExitCode::CLEAN, result.status, result.stdout
        assert_includes result.stdout, "runtime ready"
        refute_match(/\A\s*\{/, result.stdout)
        assert_empty result.stderr
      end
    end

    def test_doctor_json_is_a_preflight_envelope_without_gate_hook_diagnostics
      in_project do |dir|
        File.write(File.join(dir, ".quality_gate.yml"), project_config(format: "markdown"))
        FileUtils.mkdir_p(File.join(dir, ".quality_gate"))
        File.write(File.join(dir, ".quality_gate/hooks.jsonl"), "{\"outcome\":\"unavailable\"}\n")
        result = run_cli(%w[doctor --format=json], dir:)

        assert_json_success(result)
      end
    end

    def test_malformed_configuration_is_a_doctor_json_report
      in_project do |dir|
        File.write(File.join(dir, ".quality_gate.yml"), "format: [\n")
        result = run_cli(%w[doctor --format json], dir:)

        assert_equal ExitCode::TOOL_FAILURE, result.status
        assert_configuration_blocked(result)
      end
    end

    def test_doctor_inspects_an_explicit_ruby_script_without_running_it_or_writing_files
      in_project do |dir|
        marker = prepare_sentinel_project(dir)
        snapshot = SentinelState.new(marker:, contents: project_contents(dir), dir:, cwd: Dir.pwd)
        result = run_cli(%w[doctor --format json], dir:)

        assert_sentinel_read_only(result, snapshot)
      end
    end

    def test_doctor_uses_project_dir_without_changing_the_process_directory
      in_project do |dir|
        File.write(File.join(dir, ".quality_gate.yml"), project_config)
        Dir.mktmpdir do |other_dir|
          Dir.chdir(other_dir) do
            cwd = Dir.pwd
            result = run_cli(%w[doctor --format json], dir:)

            assert_doctor_success(result)
            assert_equal cwd, Dir.pwd
            assert_json_envelope(result)
          end
        end
      end
    end

    def test_doctor_report_output_failure_returns_tool_failure
      in_project do |dir|
        File.write(File.join(dir, ".quality_gate.yml"), project_config)
        result = run_cli(%w[doctor --format json], dir:, stdout: FailingOutput.new("report sink failed\nred"))

        assert_equal ExitCode::TOOL_FAILURE, result.status
        assert_equal "Error: report sink failed red\n", result.stderr
        refute_match(/[\u0000-\u001F\u007F]/, result.stderr.chomp)
      end
    end

    def test_doctor_stderr_write_failure_still_returns_tool_failure
      result = command_result(%w[--format markdown], stderr: FailingOutput.new)

      assert_equal ExitCode::TOOL_FAILURE, result.status
      assert_empty result.stdout
    end

    def test_doctor_help_write_failure_returns_tool_failure
      stderr = StringIO.new
      status = command.run(%w[--help], stdout: FailingOutput.new, stderr:)

      assert_equal ExitCode::TOOL_FAILURE, status
      assert_match(/Error: report sink failed/, stderr.string)
    end

    def test_doctor_uses_a_safe_fallback_when_error_message_raises
      stdout = StringIO.new
      stderr = StringIO.new
      status = Doctor.stub(:new, ->(**) { RaisingDoctor.new }) do
        command.run(%w[--format=json], stdout:, stderr:)
      end

      assert_safe_fallback_report(status, stdout, stderr)
    end

    private

    def assert_safe_fallback_report(status, stdout, stderr)
      check = JSON.parse(stdout.string).fetch("checks").first
      assert_equal ExitCode::TOOL_FAILURE, status
      assert_empty stderr.string
      assert_equal "doctor", check.fetch("id")
      assert_equal "quality_gate doctor failed", check.fetch("message"), stdout.string
    end

    def command
      DoctorCommand.new(dir: Dir.pwd, registry: {})
    end

    def command_result(arguments, stderr: StringIO.new)
      stdout = StringIO.new
      status = command.run(arguments, stdout:, stderr:)
      Result.new(status:, stdout: output_string(stdout), stderr: output_string(stderr))
    end

    def run_cli(arguments, dir:, stdout: StringIO.new)
      stderr = StringIO.new
      status = CLI.run(arguments, stdout:, stderr:, dir:)
      Result.new(status:, stdout: output_string(stdout), stderr: stderr.string)
    end

    def output_string(output)
      output.respond_to?(:string) ? output.string : ""
    end

    def assert_json_input_failure(result)
      assert_equal ExitCode::TOOL_FAILURE, result.status
      assert_empty result.stderr
      assert_equal "input", JSON.parse(result.stdout).fetch("checks").first.fetch("id")
    end

    def assert_text_input_failure(result)
      assert_equal ExitCode::TOOL_FAILURE, result.status
      assert_empty result.stdout
      assert_match(/Error:/, result.stderr)
    end

    def command_check(output, id)
      JSON.parse(output.stdout).fetch("checks").find { _1.fetch("id") == id }
    end

    def assert_doctor_success(result)
      assert_equal ExitCode::CLEAN, result.status, result.stdout
      assert_empty result.stderr
    end

    def assert_json_envelope(result)
      assert_equal "preflight", JSON.parse(result.stdout).fetch("scope")
    end

    def assert_json_success(result)
      assert_doctor_success(result)
      assert_json_envelope(result)
    end

    def assert_configuration_blocked(result)
      assert_empty result.stderr
      assert_json_envelope(result)
      check = command_check(result, "configuration")
      assert_equal "blocked", check.fetch("status")
    end

    def assert_sentinel_read_only(result, snapshot)
      assert_doctor_success(result)
      refute File.exist?(snapshot.marker)
      assert_equal snapshot.contents, project_contents(snapshot.dir)
      assert_equal snapshot.cwd, Dir.pwd
      assert_equal "ready", command_check(result, "command.verify.test_suite").fetch("status")
    end

    def prepare_sentinel_project(dir)
      script = File.join(dir, "sentinel.rb")
      marker = File.join(dir, "ran")
      File.write(script, "File.write(#{marker.dump}, 'ran')\n")
      write_sentinel_config(dir, script)
      marker
    end

    def write_sentinel_config(dir, script)
      settings = {
        "format" => "markdown",
        "adapters" => { "fast" => [], "verify" => ["test_suite"], "audit" => [] },
        "commands" => { "verify" => { "test_suite" => [RbConfig.ruby, script] } }
      }
      File.write(File.join(dir, ".quality_gate.yml"), YAML.dump(settings))
    end

    def in_project
      Dir.mktmpdir { yield _1 }
    end

    def project_config(format: "text")
      YAML.dump("format" => format, "adapters" => { "fast" => [], "verify" => [], "audit" => [] })
    end

    def project_contents(dir)
      Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).sort.to_h do |relative|
        path = File.join(dir, relative)
        [relative, File.file?(path) ? File.binread(path) : nil]
      end
    end

    class FailingOutput
      def initialize(message = "report sink failed\n\e[31mred")
        @message = message
      end

      def puts(*) = raise IOError, @message
    end

    class UnsafeMessageError < StandardError
      def message(*) = raise IOError, "message unavailable"
    end

    class RaisingDoctor
      def call
        raise UnsafeMessageError, "initial message"
      end
    end
  end
end
