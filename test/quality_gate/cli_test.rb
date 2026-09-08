# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "stringio"
require "tmpdir"

module QualityGate
  class CLITest < Minitest::Test
    def test_subcommands_are_exact_and_frozen
      assert_equal %w[fast verify audit version init], CLI::SUBCOMMANDS
      assert_predicate CLI::SUBCOMMANDS, :frozen?
    end

    def test_parse_usage_and_dispatch_are_private
      private_methods = CLI.singleton_class.private_instance_methods(false)

      assert_includes private_methods, :parse
      assert_includes private_methods, :usage
      assert_includes private_methods, :dispatch
    end

    def test_version_returns_clean_without_loading_malformed_config
      in_directory_with_config("gates: [fast\n") do |dir|
        status, stdout, stderr = run_cli(%w[version], dir: dir)

        assert_equal ExitCode::CLEAN, status
        assert_equal "#{VERSION}\n", stdout
        assert_empty stderr
      end
    end

    def test_empty_arguments_print_usage_without_loading_malformed_config
      in_directory_with_config("gates: [fast\n") do |dir|
        status, stdout, stderr = run_cli([], dir: dir)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_includes stderr, "Usage:"
        CLI::SUBCOMMANDS.each { |subcommand| assert_includes stderr, subcommand }
      end
    end

    def test_unknown_subcommand_prints_usage_without_loading_malformed_config
      in_directory_with_config("gates: [fast\n") do |dir|
        status, stdout, stderr = run_cli(%w[unknown], dir: dir)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_includes stderr, "Usage:"
        CLI::SUBCOMMANDS.each { |subcommand| assert_includes stderr, subcommand }
      end
    end

    def test_top_level_help_is_successful_and_does_not_load_config
      in_directory_with_config("gates: [fast\n") do |dir|
        status, stdout, stderr = run_cli(%w[--help], dir: dir)

        assert_equal ExitCode::CLEAN, status
        assert_empty stderr
        assert_includes stdout, "--files PATH [PATH ...]"
        assert_includes stdout, "fast      RuboCop"
        assert_includes stdout, "RuboCop and Reek scan selected paths"
        assert_includes stdout, "0  Checks completed cleanly"
        assert_includes stdout, "1  Checks completed with findings"
        assert_includes stdout, "2  Quality Gate could not complete"
        assert_includes stdout, "init      Install a plain Ruby project configuration"
      end
    end

    def test_gate_help_is_successful_and_lists_that_gate_tools
      in_directory_with_config("format: invalid\n") do |dir|
        status, stdout, stderr = run_cli(%w[verify --help], dir: dir)

        assert_equal ExitCode::CLEAN, status
        assert_empty stderr
        assert_includes stdout, "Usage: quality_gate verify [options]"
        assert_includes stdout, "reek, test_suite, undercover"
        assert_includes stdout, "quality_gate verify --files"
        assert_includes stdout, "--format=FORMAT"
      end
    end

    def test_help_aliases_are_successful
      %w[-h help].each do |argument|
        status, stdout, stderr = run_cli([argument], dir: Dir.pwd)

        assert_equal ExitCode::CLEAN, status
        assert_includes stdout, "Usage: quality_gate"
        assert_empty stderr
      end
    end

    def test_json_invalid_subcommand_is_reported_as_a_quality_gate_failure
      status, stdout, stderr = run_cli(%w[unknown --format=json], dir: Dir.pwd)

      assert_equal ExitCode::TOOL_FAILURE, status
      assert_empty stderr
      payload = JSON.parse(stdout)
      assert_equal ["quality_gate"], payload.fetch("summary").fetch("failed_tools")
      assert_includes payload.fetch("findings").first.fetch("message"), "unknown subcommand unknown"
    end

    def test_gate_with_no_configured_adapters_prints_a_clean_text_summary
      in_directory_with_config("adapters:\n  verify: []\n") do |dir|
        status, stdout, stderr = run_cli(%w[verify], dir: dir)

        assert_equal ExitCode::CLEAN, status
        assert_equal "0 findings, 0 tool failures\n", stdout
        assert_empty stderr
      end
    end

    def test_gate_command_writes_a_clean_json_report_when_requested
      in_directory_with_config("adapters:\n  verify: []\n") do |dir|
        status, stdout, stderr = run_cli(%w[verify --format json], dir: dir)

        assert_equal ExitCode::CLEAN, status
        assert_equal(
          {
            "checks" => [],
            "findings" => [],
            "summary" => {
              "findings" => 0,
              "tool_failures" => 0,
              "failed_tools" => []
            }
          },
          JSON.parse(stdout)
        )
        assert_empty stderr
      end
    end

    def test_gate_command_reports_malformed_config_path
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".quality_gate.yml")
        File.write(path, "gates: [fast\n")

        status, stdout, stderr = run_cli(%w[verify], dir: dir)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_equal 1, stderr.lines.length
        assert_includes stderr, path
      end
    end

    def test_gate_command_reports_excessive_config_nesting_without_a_traceback
      in_directory_with_config(deeply_nested_yaml) do |dir|
        path = File.join(dir, ".quality_gate.yml")
        status, stdout, stderr = run_cli(%w[fast], dir: dir)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_equal 1, stderr.lines.length
        assert_includes stderr, path
        refute_match(/[\u0000-\u001F\u007F]/, stderr.chomp)
        refute_includes stderr, "config.rb:"
      end
    end

    def test_gate_command_reports_invalid_configured_format_before_dispatch
      in_directory_with_config("format: xml\n") do |dir|
        path = File.join(dir, ".quality_gate.yml")
        status, stdout, stderr = run_cli(%w[fast], dir: dir)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_equal 1, stderr.lines.length
        assert_includes stderr, path
        assert_includes stderr, "format must be text or json"
      end
    end

    def test_gate_command_reports_invalid_adapters_schema_before_dispatch
      in_directory_with_config("adapters:\n  fasst: []\n") do |dir|
        path = File.join(dir, ".quality_gate.yml")
        status, stdout, stderr = run_cli(%w[fast], dir: dir)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_equal 1, stderr.lines.length
        assert_includes stderr, path
        assert_includes stderr, "adapters keys must be fast, verify, or audit"
      end
    end

    def test_invalid_format_reports_value_without_loading_malformed_config
      in_directory_with_config("gates: [fast\n") do |dir|
        status, stdout, stderr = run_cli(%w[fast --format xml], dir: dir)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_includes stderr, "--format"
        assert_includes stderr, "xml"
        assert_includes stderr, "Usage:"
      end
    end

    def test_json_malformed_config_is_reported_using_the_json_envelope
      in_directory_with_config("gates: [fast\n") do |dir|
        status, stdout, stderr = run_cli(%w[fast --format=json], dir: dir)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stderr
        payload = JSON.parse(stdout)
        assert_equal ["quality_gate"], payload.fetch("summary").fetch("failed_tools")
        assert_includes payload.fetch("findings").first.fetch("message"), ".quality_gate.yml"
      end
    end

    private

    def deeply_nested_yaml
      "format: #{"[" * 2_000}text#{"]" * 2_000}\n"
    end

    def run_cli(argv, dir:, cli: CLI)
      stdout = StringIO.new
      stderr = StringIO.new
      status = cli.run(argv, stdout: stdout, stderr: stderr, dir: dir)

      [status, stdout.string, stderr.string]
    end

    def in_directory_with_config(contents)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".quality_gate.yml"), contents)
        yield dir
      end
    end

    def touch_files(dir, paths)
      paths.each do |path|
        absolute_path = File.join(dir, path)
        FileUtils.mkdir_p(File.dirname(absolute_path))
        FileUtils.touch(absolute_path)
      end
    end
  end

  class CLIInitTest < Minitest::Test
    class BrokenMessageError < ArgumentError
      def message
        raise "message extraction failed"
      end
    end

    class FakeInstaller
      class << self
        attr_accessor :calls, :result, :error

        def reset
          self.calls = []
          self.result = ExitCode::CLEAN
          self.error = nil
        end
      end

      def initialize(destination_root:, options:, stdout:)
        self.class.calls << { destination_root:, options:, stdout: }
      end

      def call
        raise self.class.error if self.class.error

        self.class.result
      end
    end

    def setup
      FakeInstaller.reset
    end

    def test_init_defaults_to_ruby_and_runs_before_loading_config
      with_fake_installer do
        in_directory_with_config("format: [malformed\n") do |dir|
          status, _stdout, stderr, stdout_io = run_cli(%w[init], dir: dir)

          assert_equal ExitCode::CLEAN, status
          assert_equal [{ destination_root: dir, options: {
            profile: "ruby", skip_coverage: false, agents: false, pretend: false
          }, stdout: stdout_io }], FakeInstaller.calls
          assert_empty stderr
        end
      end
    end

    def test_init_passes_profile_options_to_installer
      with_fake_installer do
        Dir.mktmpdir do |dir|
          status, _stdout, stderr, stdout_io = run_cli(
            ["init", "--profile", "ruby", "--test-framework", "rspec", "--test-helper", "spec/spec_helper.rb",
             "--test-command", "bundle exec rspec", "--skip-coverage", "--agents", "--pretend"],
            dir: dir
          )

          assert_equal ExitCode::CLEAN, status
          options = FakeInstaller.calls.fetch(0).fetch(:options)
          assert_equal "ruby", options.fetch(:profile)
          assert_equal "rspec", options.fetch(:test_framework)
          assert_equal "spec/spec_helper.rb", options.fetch(:test_helper)
          assert_equal "bundle exec rspec", options.fetch(:test_command)
          assert options.fetch(:skip_coverage)
          assert options.fetch(:agents)
          assert options.fetch(:pretend)
          assert_same stdout_io, FakeInstaller.calls.fetch(0).fetch(:stdout)
          assert_empty stderr
        end
      end
    end

    def test_init_returns_installer_conflict_status_and_keeps_human_output
      with_fake_installer do
        FakeInstaller.result = ExitCode::FINDINGS
        Dir.mktmpdir do |dir|
          status, stdout, stderr = run_cli(%w[init], dir: dir)

          assert_equal ExitCode::FINDINGS, status
          assert_empty stdout
          assert_empty stderr
        end
      end
    end

    def test_init_rejects_invalid_options_before_instantiating_installer
      with_fake_installer do
        Dir.mktmpdir do |dir|
          status, stdout, stderr = run_cli(%w[init --test-framework cucumber], dir: dir)

          assert_equal ExitCode::TOOL_FAILURE, status
          assert_empty stdout
          assert_empty FakeInstaller.calls
          assert_includes stderr, "test-framework"
          refute_path_exists File.join(dir, ".quality_gate.yml")
        end
      end
    end

    def test_init_rejects_unexpected_positional_argument_before_instantiating_installer
      with_fake_installer do
        Dir.mktmpdir do |dir|
          status, stdout, stderr = run_cli(%w[init unexpected-positional], dir: dir)

          assert_equal ExitCode::TOOL_FAILURE, status
          assert_empty stdout
          assert_empty FakeInstaller.calls
          assert_includes stderr, "unexpected-positional"
        end
      end
    end

    def test_init_rejects_format_before_writes
      with_fake_installer do
        Dir.mktmpdir do |dir|
          status, stdout, stderr = run_cli(%w[init --format=json], dir: dir)

          assert_equal ExitCode::TOOL_FAILURE, status
          assert_empty stdout
          assert_empty FakeInstaller.calls
          assert_includes stderr, "does not support --format"
        end
      end
    end

    def test_init_help_does_not_load_installer_or_config
      in_directory_with_config("format: [malformed\n") do |dir|
        status, stdout, stderr = run_cli(%w[init --help], dir: dir)

        assert_equal ExitCode::CLEAN, status
        assert_includes stdout, "--test-framework NAME"
        assert_includes stdout, "--skip-coverage"
        assert_empty stderr
      end
    end

    def test_init_reports_installer_argument_errors_as_text
      with_fake_installer do
        FakeInstaller.error = ArgumentError.new("RSpec helper is missing")
        Dir.mktmpdir do |dir|
          status, stdout, stderr = run_cli(%w[init], dir: dir)

          assert_equal ExitCode::TOOL_FAILURE, status
          assert_empty stdout
          assert_includes stderr, "Error: RSpec helper is missing"
        end
      end
    end

    def test_init_uses_a_fallback_when_installer_error_message_fails
      with_fake_installer do
        FakeInstaller.error = BrokenMessageError.new
        Dir.mktmpdir do |dir|
          status, stdout, stderr = run_cli(%w[init], dir: dir)

          assert_equal ExitCode::TOOL_FAILURE, status
          assert_empty stdout
          assert_equal "Error: quality_gate init failed\n", stderr
        end
      end
    end

    def test_init_handles_closed_stderr_without_raising
      with_fake_installer do
        stderr = StringIO.new
        stderr.close

        status, error = capture_error do
          CLI.run(%w[init --test-framework cucumber], stdout: StringIO.new, stderr: stderr, dir: Dir.pwd)
        end

        assert_nil error
        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty FakeInstaller.calls
      end
    end

    private

    def with_fake_installer(&block)
      require "quality_gate/installer"
      with_installer(FakeInstaller, &block)
    end

    def with_installer(installer)
      had_installer = QualityGate.const_defined?(:Installer, false)
      previous_installer = QualityGate.const_get(:Installer, false) if had_installer
      QualityGate.send(:remove_const, :Installer) if had_installer
      QualityGate.const_set(:Installer, installer) if installer
      yield
    ensure
      QualityGate.send(:remove_const, :Installer) if QualityGate.const_defined?(:Installer, false)
      QualityGate.const_set(:Installer, previous_installer) if had_installer
    end

    def capture_error
      [yield, nil]
    rescue StandardError => e
      [nil, e]
    end

    def run_cli(argv, dir:)
      stdout = StringIO.new
      stderr = StringIO.new
      status = CLI.run(argv, stdout:, stderr:, dir:)

      [status, stdout.string, stderr.string, stdout]
    end

    def in_directory_with_config(contents)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".quality_gate.yml"), contents)
        yield dir
      end
    end
  end

  class CLIOptionsTest < Minitest::Test
    class RecordingCLI < CLI
      class << self
        attr_reader :subcommand, :settings

        def reset
          @subcommand = nil
          @settings = nil
        end

        private

        def dispatch(subcommand, settings, stdout:, stderr:)
          @subcommand = subcommand
          @settings = settings
          @stdout = stdout
          @stderr = stderr
          ExitCode::TOOL_FAILURE
        end
      end
    end

    def test_files_option_passes_space_separated_paths_to_dispatch_in_order
      in_directory_with_config("files:\n  - configured.rb\n") do |dir|
        touch_files(dir, %w[lib/one.rb test/two.rb])
        argv = %w[fast --files lib/one.rb test/two.rb]
        status, stdout, stderr = run_cli(argv, dir: dir, cli: RecordingCLI)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_empty stderr
        assert_equal "fast", RecordingCLI.subcommand
        assert_equal %w[lib/one.rb test/two.rb], RecordingCLI.settings.fetch(:files)
      end
    end

    def test_files_option_preserves_a_comma_in_the_first_path
      Dir.mktmpdir do |dir|
        touch_files(dir, ["lib/a,b.rb"])
        RecordingCLI.reset
        status, = run_cli(["fast", "--files", "lib/a,b.rb"], dir: dir, cli: RecordingCLI)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_equal ["lib/a,b.rb"], RecordingCLI.settings.fetch(:files)
      end
    end

    def test_unexpected_positional_argument_fails_before_dispatch
      Dir.mktmpdir do |dir|
        RecordingCLI.reset
        status, stdout, stderr = run_cli(%w[fast unexpected-positional], dir: dir, cli: RecordingCLI)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_nil RecordingCLI.settings
        assert_includes stderr, "unexpected-positional"
      end
    end

    def test_files_option_rejects_an_empty_first_path_before_loading_config
      in_directory_with_config("gates: [fast\n") do |dir|
        RecordingCLI.reset
        status, stdout, stderr = run_cli(["fast", "--files", ""], dir: dir, cli: RecordingCLI)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_nil RecordingCLI.settings
        assert_includes stderr, "--files"
        assert_includes stderr, "path"
        refute_includes stderr, File.join(dir, ".quality_gate.yml")
      end
    end

    def test_repeated_files_option_is_rejected_before_dispatch
      Dir.mktmpdir do |dir|
        RecordingCLI.reset
        argv = %w[fast --files a.rb b.rb --files c.rb d.rb]
        status, stdout, stderr = run_cli(argv, dir: dir, cli: RecordingCLI)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_nil RecordingCLI.settings
        assert_includes stderr, "--files"
        assert_includes stderr, "Usage:"
      end
    end

    def test_repeated_files_option_does_not_load_config
      in_directory_with_config("gates: [fast\n") do |dir|
        RecordingCLI.reset
        argv = %w[fast --files a.rb b.rb --files c.rb d.rb]
        status, stdout, stderr = run_cli(argv, dir: dir, cli: RecordingCLI)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_nil RecordingCLI.settings
        assert_includes stderr, "--files"
        refute_includes stderr, File.join(dir, ".quality_gate.yml")
      end
    end

    def test_files_option_requires_at_least_one_path_before_loading_config
      in_directory_with_config("gates: [fast\n") do |dir|
        status, stdout, stderr = run_cli(%w[fast --files], dir: dir)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_includes stderr, "--files"
        assert_includes stderr, "Usage:"
      end
    end

    def test_double_dash_keeps_a_following_help_token_out_of_help_dispatch
      Dir.mktmpdir do |dir|
        RecordingCLI.reset
        status, stdout, stderr = run_cli(%w[fast --files -- --help], dir: dir, cli: RecordingCLI)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_nil RecordingCLI.settings
        refute_includes stderr, "Checks completed cleanly"
      end
    end

    def test_missing_explicit_paths_fail_before_dispatch_even_when_another_path_exists
      Dir.mktmpdir do |dir|
        touch_files(dir, ["present.rb"])
        RecordingCLI.reset

        status, stdout, stderr = run_cli(
          %w[fast --files present.rb missing.rb other_missing/],
          dir: dir,
          cli: RecordingCLI
        )

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_nil RecordingCLI.settings
        assert_includes stderr, "missing.rb"
        assert_includes stderr, "other_missing/"
      end
    end

    def test_missing_configured_paths_fail_before_dispatch
      in_directory_with_config("files:\n  - missing.rb\nadapters:\n  fast: []\n") do |dir|
        RecordingCLI.reset
        status, stdout, stderr = run_cli(%w[fast], dir: dir, cli: RecordingCLI)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_nil RecordingCLI.settings
        assert_includes stderr, "missing.rb"
      end
    end

    def test_existing_directories_are_valid_file_scope_paths
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        RecordingCLI.reset

        status, stdout, stderr = run_cli(%w[fast --files app/models], dir: dir, cli: RecordingCLI)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_empty stderr
        assert_equal ["app/models"], RecordingCLI.settings.fetch(:files)
      end
    end

    def test_json_option_errors_are_reported_using_the_json_envelope
      Dir.mktmpdir do |dir|
        status, stdout, stderr = run_cli(%w[fast --format=json --unknown], dir: dir)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stderr
        payload = JSON.parse(stdout)
        assert_equal ["quality_gate"], payload.fetch("summary").fetch("failed_tools")
        assert_includes payload.fetch("findings").first.fetch("message"), "unknown"
      end
    end

    private

    def run_cli(argv, dir:, cli: CLI)
      stdout = StringIO.new
      stderr = StringIO.new
      status = cli.run(argv, stdout: stdout, stderr: stderr, dir: dir)

      [status, stdout.string, stderr.string]
    end

    def in_directory_with_config(contents)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".quality_gate.yml"), contents)
        yield dir
      end
    end

    def touch_files(dir, paths)
      paths.each do |path|
        absolute_path = File.join(dir, path)
        FileUtils.mkdir_p(File.dirname(absolute_path))
        FileUtils.touch(absolute_path)
      end
    end
  end

  class CLIConfigDispatchTest < Minitest::Test
    RecordingCLI = CLIOptionsTest::RecordingCLI

    def test_format_option_overrides_config_and_reaches_dispatch
      yaml = "format: text\nfiles:\n  - configured.rb\n"
      in_directory_with_config(yaml) do |dir|
        touch_files(dir, ["configured.rb"])
        status, stdout, stderr = run_cli(%w[verify --format json], dir: dir)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_empty stderr
        assert_equal "json", RecordingCLI.settings.fetch(:format)
        assert_equal ["configured.rb"], RecordingCLI.settings.fetch(:files)
      end
    end

    def test_explicit_text_format_overrides_configured_json
      in_directory_with_config("format: json\n") do |dir|
        RecordingCLI.reset
        status, stdout, stderr = run_cli(%w[verify --format=text], dir: dir)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_empty stderr
        assert_equal "text", RecordingCLI.settings.fetch(:format)
      end
    end

    def test_explicit_invalid_format_keeps_text_error_behavior_over_configured_json
      in_directory_with_config("format: json\n") do |dir|
        status, stdout, stderr = run_cli(%w[verify --format=xml], dir: dir)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_includes stderr, "--format"
        assert_includes stderr, "Usage:"
      end
    end

    def test_explicit_missing_format_keeps_text_error_behavior_over_configured_json
      in_directory_with_config("format: json\n") do |dir|
        status, stdout, stderr = run_cli(%w[verify --format], dir: dir)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_includes stderr, "--format"
        assert_includes stderr, "Usage:"
      end
    end

    def test_config_values_reach_dispatch_when_options_are_absent
      yaml = "format: json\nfiles:\n  - configured.rb\n"
      in_directory_with_config(yaml) do |dir|
        touch_files(dir, ["configured.rb"])
        status, stdout, stderr = run_cli(%w[audit], dir: dir)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_empty stderr
        assert_equal "json", RecordingCLI.settings.fetch(:format)
        assert_equal ["configured.rb"], RecordingCLI.settings.fetch(:files)
      end
    end

    def test_unknown_config_key_warns_and_defaults_reach_dispatch
      in_directory_with_config("mystery: true\n") do |dir|
        RecordingCLI.reset
        status, stdout, stderr = run_cli(%w[audit], dir: dir)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_equal "audit", RecordingCLI.subcommand
        assert_equal Config.defaults, RecordingCLI.settings
        assert_equal ["Warning: unknown config key mystery\n"], stderr.lines
      end
    end

    def test_unexpected_standard_error_is_reported_as_tool_failure
      status, stdout, stderr = run_cli(%w[fast], dir: nil)

      assert_equal ExitCode::TOOL_FAILURE, status
      assert_empty stdout
      assert_equal 1, stderr.lines.length
      assert_includes stderr, "Error:"
    end

    def test_configured_json_format_reports_pre_dispatch_errors_as_json
      in_directory_with_config("format: json\nfiles:\n  - missing.rb\n") do |dir|
        status, stdout, stderr = run_cli(%w[fast], dir: dir)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stderr
        payload = JSON.parse(stdout)
        assert_equal ["quality_gate"], payload.fetch("summary").fetch("failed_tools")
        assert_includes payload.fetch("findings").first.fetch("message"), "missing.rb"
      end
    end

    private

    def run_cli(argv, dir:)
      stdout = StringIO.new
      stderr = StringIO.new
      status = RecordingCLI.run(argv, stdout: stdout, stderr: stderr, dir: dir)

      [status, stdout.string, stderr.string]
    end

    def in_directory_with_config(contents)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".quality_gate.yml"), contents)
        yield dir
      end
    end

    def touch_files(dir, paths)
      paths.each do |path|
        absolute_path = File.join(dir, path)
        FileUtils.mkdir_p(File.dirname(absolute_path))
        FileUtils.touch(absolute_path)
      end
    end
  end

  class CLIExecutionTest < Minitest::Test
    class TTYStringIO < StringIO
      def tty? = true
    end

    class RegistryBackedCLI < CLI
      class << self
        def reset
          RecordingRegistryAdapter.reset
        end

        private

        def registry
          { "rubocop" => RecordingRegistryAdapter }
        end
      end
    end

    class SimpleCovRegistryCLI < CLI
      class << self
        private

        def registry
          {
            "rubocop" => RecordingSimpleCovAdapter,
            "simplecov" => RecordingSimpleCovAdapter
          }
        end
      end
    end

    class SecurityRegistryCLI < CLI
      class << self
        def audit_adapters(config:, diagnostic_io:)
          adapters_for(
            "audit",
            settings: config.to_h,
            config: config,
            diagnostic_io: diagnostic_io
          )
        end

        def registered_adapters = registry

        def verify_adapters(config:, diagnostic_io:)
          adapters_for(
            "verify",
            settings: config.to_h,
            config: config,
            diagnostic_io: diagnostic_io
          )
        end
      end
    end

    class InjectedAdaptersCLI < CLI
      class << self
        def reset
          @adapters_by_gate = {}
        end

        def use_adapters(subcommand, adapters)
          @adapters_by_gate ||= {}
          @adapters_by_gate[subcommand] = adapters
        end

        private

        def adapters_for(subcommand, settings:, config:, diagnostic_io:)
          (@adapters_by_gate ||= {}).fetch(subcommand) { super }
        end
      end
    end

    StaticAdapter = Struct.new(:findings) do
      def call = findings

      def name = "static"
    end

    class RecordingRegistryAdapter
      class << self
        attr_reader :config, :diagnostic_io, :files

        def reset
          @config = nil
          @diagnostic_io = nil
          @files = nil
        end
      end

      def initialize(config:, files:, diagnostic_io:)
        self.class.instance_variable_set(:@config, config)
        self.class.instance_variable_set(:@files, files)
        self.class.instance_variable_set(:@diagnostic_io, diagnostic_io)
      end

      def call
        [
          Finding.new(
            tool: "rubocop",
            file: "lib/example.rb",
            line: 7,
            rule: "Layout/LineLength",
            severity: :warning,
            message: "Line is too long"
          )
        ]
      end

      def name = "rubocop"
    end

    class RecordingSimpleCovAdapter
      class << self
        attr_reader :constructions, :calls

        def reset
          @constructions = 0
          @calls = 0
        end
      end

      def initialize(**)
        self.class.instance_variable_set(:@constructions, self.class.constructions + 1)
      end

      def call
        self.class.instance_variable_set(:@calls, self.class.calls + 1)
        []
      end
    end

    def setup
      InjectedAdaptersCLI.reset
      RegistryBackedCLI.reset
      RecordingSimpleCovAdapter.reset
    end

    def test_injected_findings_use_the_text_reporter_and_exit_with_findings
      finding = Finding.new(
        tool: "rubocop",
        file: "lib/example.rb",
        line: 7,
        rule: "Layout/LineLength",
        severity: :warning,
        message: "Line is too long"
      )
      InjectedAdaptersCLI.use_adapters("fast", [StaticAdapter.new([finding])])

      status, stdout, stderr = run_cli(%w[fast], cli: InjectedAdaptersCLI)

      assert_equal ExitCode::FINDINGS, status
      assert_equal [
        "rubocop warning lib/example.rb:7 Layout/LineLength Line is too long",
        "1 findings, 0 tool failures"
      ], stdout.lines(chomp: true)
      assert_empty stderr
    end

    def test_injected_tool_failure_uses_the_json_reporter_and_exit_code_two
      findings = [
        Finding.new(
          tool: "rubocop",
          file: "lib/example.rb",
          line: 7,
          rule: "Layout/LineLength",
          severity: :warning,
          message: "Line is too long"
        ),
        Finding.tool_failure(tool: "reek", message: "timed out")
      ]
      InjectedAdaptersCLI.use_adapters("verify", [StaticAdapter.new(findings)])

      status, stdout, stderr = run_cli(%w[verify --format json], cli: InjectedAdaptersCLI)

      assert_equal ExitCode::TOOL_FAILURE, status
      assert_equal ["reek"], JSON.parse(stdout).fetch("summary").fetch("failed_tools")
      assert_empty stderr
    end

    def test_unknown_config_key_warning_stays_on_stderr_during_clean_run
      in_directory_with_config("mystery: true\nadapters:\n  audit: []\n") do |dir|
        status, stdout, stderr = run_cli(%w[audit], dir: dir)

        assert_equal ExitCode::CLEAN, status
        assert_equal "0 findings, 0 tool failures\n", stdout
        assert_equal ["Warning: unknown config key mystery\n"], stderr.lines
      end
    end

    def test_progress_is_written_only_to_tty_stderr_and_json_stdout_stays_parseable
      in_directory_with_config("adapters:\n  fast:\n    - unknown_adapter\n") do |dir|
        [StringIO.new, TTYStringIO.new].each do |stderr|
          stdout = StringIO.new
          status = CLI.run(%w[fast --format=json], stdout:, stderr:, dir:)

          assert_equal ExitCode::TOOL_FAILURE, status
          assert_kind_of Hash, JSON.parse(stdout.string)
          if stderr.tty?
            assert_includes stderr.string, "Running unknown_adapter"
          else
            refute_includes stderr.string, "Running unknown_adapter"
          end
        end
      end
    end

    def test_registry_maps_all_shipped_adapters_to_their_classes
      assert_equal(
        {
          "reek" => QualityGate::Adapters::Reek,
          "rubocop" => QualityGate::Adapters::RuboCop,
          "simplecov" => QualityGate::Adapters::SimpleCov,
          "test_suite" => QualityGate::Adapters::TestSuite,
          "undercover" => QualityGate::Adapters::Undercover,
          "brakeman" => QualityGate::Adapters::Brakeman,
          "bundler_audit" => QualityGate::Adapters::BundlerAudit
        },
        SecurityRegistryCLI.registered_adapters
      )
    end

    def test_simplecov_without_a_coverage_budget_fails_before_any_adapter_is_constructed
      yaml = <<~YAML
        adapters:
          fast:
            - rubocop
            - simplecov
      YAML

      in_directory_with_config(yaml) do |dir|
        status, stdout, stderr = run_cli(%w[fast], dir: dir, cli: SimpleCovRegistryCLI)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_equal 1, stderr.lines.length
        assert_match(/\AError:/, stderr)
        assert_includes stderr, "simplecov"
        assert_includes stderr, "coverage.minimum_line"
        assert_equal 0, RecordingSimpleCovAdapter.constructions
        assert_equal 0, RecordingSimpleCovAdapter.calls
      end
    end

    def test_simplecov_without_a_budget_on_an_unselected_gate_is_inert
      yaml = <<~YAML
        adapters:
          fast: []
          verify:
            - simplecov
      YAML

      in_directory_with_config(yaml) do |dir|
        status, stdout, stderr = run_cli(%w[fast], dir: dir, cli: SimpleCovRegistryCLI)

        assert_equal ExitCode::CLEAN, status
        assert_equal "0 findings, 0 tool failures\n", stdout
        assert_empty stderr
        assert_equal 0, RecordingSimpleCovAdapter.constructions
      end
    end

    def test_valid_coverage_without_simplecov_has_no_gate_effect
      yaml = <<~YAML
        coverage:
          minimum_line: 100
        adapters:
          fast: []
      YAML

      in_directory_with_config(yaml) do |dir|
        status, stdout, stderr = run_cli(%w[fast], dir: dir)

        assert_equal ExitCode::CLEAN, status
        assert_equal "0 findings, 0 tool failures\n", stdout
        assert_empty stderr
      end
    end

    def test_default_verify_builds_reek_then_test_suite_then_undercover
      config = Config.new(Config.defaults)
      diagnostic_io = StringIO.new

      adapters = SecurityRegistryCLI.verify_adapters(config:, diagnostic_io:)

      assert_equal [Adapters::Reek, Adapters::TestSuite, Adapters::Undercover], adapters.map(&:class)
      adapters.each do |adapter|
        assert_same config, adapter.send(:config)
        assert_equal [], adapter.send(:files)
        assert_same diagnostic_io, adapter.send(:diagnostic_io)
      end
    end

    def test_default_audit_builds_security_adapters_in_order_with_the_cli_diagnostic_io
      config = Config.new(Config.defaults)
      diagnostic_io = StringIO.new

      adapters = SecurityRegistryCLI.audit_adapters(config: config, diagnostic_io: diagnostic_io)

      assert_equal [QualityGate::Adapters::Brakeman, QualityGate::Adapters::BundlerAudit], adapters.map(&:class)
      adapters.each do |adapter|
        assert_same config, adapter.send(:config)
        assert_equal [], adapter.send(:files)
        assert_same diagnostic_io, adapter.send(:diagnostic_io)
      end
    end

    def test_unknown_adapter_name_becomes_a_reported_tool_failure
      yaml = <<~YAML
        adapters:
          fast:
            - unknown_adapter
      YAML

      in_directory_with_config(yaml) do |dir|
        status, stdout, stderr = run_cli(%w[fast], dir: dir)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_equal [
          "unknown_adapter error tool_failure unknown adapter unknown_adapter",
          "1 findings, 1 tool failures"
        ], stdout.lines(chomp: true)
        assert_empty stderr
      end
    end

    def test_unknown_adapter_name_is_sanitized_in_text_output
      yaml = <<~YAML
        adapters:
          fast:
            - "bad\\n\\t\\e[31mtool"
      YAML

      in_directory_with_config(yaml) do |dir|
        status, stdout, stderr = run_cli(%w[fast], dir: dir)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_equal [
          "bad   [31mtool error tool_failure unknown adapter bad",
          "   [31mtool",
          "1 findings, 1 tool failures"
        ], stdout.lines(chomp: true)
        assert_empty stderr
      end
    end

    def test_registry_adapter_receives_resolved_config_and_files
      yaml = <<~YAML
        adapters:
          fast:
            - rubocop
        files:
          - configured.rb
      YAML

      in_directory_with_config(yaml) do |dir|
        touch_files(dir, ["app/models/user.rb"])
        status, stdout, stderr, diagnostic_io = run_cli(
          %w[fast --files app/models/user.rb],
          dir: dir,
          cli: RegistryBackedCLI
        )

        assert_equal ExitCode::FINDINGS, status
        assert_equal [
          "rubocop warning lib/example.rb:7 Layout/LineLength Line is too long",
          "1 findings, 0 tool failures"
        ], stdout.lines(chomp: true)
        assert_empty stderr
        assert_equal ["app/models/user.rb"], RecordingRegistryAdapter.files
        assert_same diagnostic_io, RecordingRegistryAdapter.diagnostic_io
        assert_instance_of Config, RecordingRegistryAdapter.config
        assert_equal ["app/models/user.rb"], RecordingRegistryAdapter.config.fetch(:files)
        assert_equal ["rubocop"], RecordingRegistryAdapter.config.fetch(:adapters).fetch(:fast)
      end
    end

    def test_each_gate_warns_on_stderr_without_changing_json_or_exit_status
      finding = Finding.new(
        tool: "rubocop",
        file: "lib/example.rb",
        line: 7,
        rule: "Layout/LineLength",
        severity: :warning,
        message: "Line is too long"
      )
      InjectedAdaptersCLI.use_adapters("fast", [])
      InjectedAdaptersCLI.use_adapters("verify", [StaticAdapter.new([finding])])
      InjectedAdaptersCLI.use_adapters(
        "audit",
        [StaticAdapter.new([Finding.tool_failure(tool: "brakeman", message: "failed")])]
      )

      Dir.mktmpdir do |dir|
        write_hook_log(dir, %w[unavailable clean verify_unavailable verify_unavailable])
        expected_statuses = {
          "fast" => ExitCode::CLEAN,
          "verify" => ExitCode::FINDINGS,
          "audit" => ExitCode::TOOL_FAILURE
        }

        expected_statuses.each do |subcommand, expected_status|
          status, stdout, stderr = run_cli(
            [subcommand, "--format", "json"],
            dir: dir,
            cli: InjectedAdaptersCLI
          )

          assert_equal expected_status, status
          assert_kind_of Hash, JSON.parse(stdout)
          assert_equal 1, stderr.lines.length
          assert_includes stderr, "3"
          assert_includes stderr, "last 20"
        end
      end
    end

    def test_hook_log_is_resolved_under_injected_directory_not_process_directory
      InjectedAdaptersCLI.use_adapters("fast", [])

      with_two_temp_dirs do |project_dir, process_dir|
        write_hook_log(project_dir, ["unavailable"])

        status, _stdout, stderr = Dir.chdir(process_dir) do
          run_cli(%w[fast], dir: project_dir, cli: InjectedAdaptersCLI)
        end

        assert_equal ExitCode::CLEAN, status
        assert_includes stderr, "1"
        assert_includes stderr, "last 20"
        refute_path_exists File.join(process_dir, HookLog::DEFAULT_PATH)
      end
    end

    def test_version_and_invalid_commands_never_emit_hook_health_warnings
      Dir.mktmpdir do |dir|
        write_hook_log(dir, ["unavailable"])

        version_status, _version_stdout, version_stderr = run_cli(%w[version], dir: dir)
        invalid_status, _invalid_stdout, invalid_stderr = run_cli(%w[unknown], dir: dir)

        assert_equal ExitCode::CLEAN, version_status
        assert_empty version_stderr
        assert_equal ExitCode::TOOL_FAILURE, invalid_status
        assert_includes invalid_stderr, "Usage:"
        refute_includes invalid_stderr, "automatic checks"
      end
    end

    def test_hook_health_warning_precedes_gate_diagnostics
      in_directory_with_config("mystery: true\nadapters:\n  fast: []\n") do |dir|
        write_hook_log(dir, ["unavailable"])

        status, stdout, stderr = run_cli(%w[fast], dir: dir)

        assert_equal ExitCode::CLEAN, status
        assert_equal "0 findings, 0 tool failures\n", stdout
        assert_match(/automatic checks/, stderr.lines.first)
        assert_equal "Warning: unknown config key mystery\n", stderr.lines.last
      end
    end

    def test_hook_warning_write_failure_is_advisory
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".quality_gate.yml"), "adapters:\n  fast: []\n")
        write_hook_log(dir, ["unavailable"])
        stdout = StringIO.new
        stderr = StringIO.new
        stderr.close

        status = CLI.run(%w[fast], stdout: stdout, stderr: stderr, dir: dir)

        assert_equal ExitCode::CLEAN, status
        assert_equal "0 findings, 0 tool failures\n", stdout.string
      end
    end

    def test_malformed_hook_log_is_advisory_for_a_json_gate
      with_clean_fast_project do |dir, path|
        File.write(path, "{not-json\n")

        assert_damaged_hook_log_is_advisory(dir)
      end
    end

    def test_invalid_encoding_hook_log_is_advisory_for_a_json_gate
      with_clean_fast_project do |dir, path|
        File.binwrite(path, "\xFF\n".b)

        assert_damaged_hook_log_is_advisory(dir)
      end
    end

    def test_hook_log_directory_is_advisory_for_a_json_gate
      with_clean_fast_project do |dir, path|
        FileUtils.mkdir_p(path)

        assert_damaged_hook_log_is_advisory(dir)
      end
    end

    def test_permission_denied_hook_log_is_advisory_for_a_json_gate
      with_clean_fast_project do |dir, path|
        write_hook_log(dir, ["unavailable"])
        original_open = File.method(:open)
        denied_read = lambda do |candidate, *args, **keywords, &block|
          raise Errno::EACCES, candidate if candidate == path

          original_open.call(candidate, *args, **keywords, &block)
        end

        File.stub(:open, denied_read) { assert_damaged_hook_log_is_advisory(dir) }
      end
    end

    private

    def assert_damaged_hook_log_is_advisory(dir)
      status, stdout, stderr = run_cli(%w[fast --format json], dir: dir)

      assert_equal ExitCode::CLEAN, status
      assert_kind_of Hash, JSON.parse(stdout)
      assert_empty stderr
    end

    def run_cli(argv, dir: nil, cli: CLI)
      return Dir.mktmpdir { run_cli(argv, dir: _1, cli: cli) } unless dir

      stdout = StringIO.new
      stderr = StringIO.new
      status = cli.run(argv, stdout: stdout, stderr: stderr, dir: dir)

      [status, stdout.string, stderr.string, stderr]
    end

    def in_directory_with_config(contents)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".quality_gate.yml"), contents)
        yield dir
      end
    end

    def touch_files(dir, paths)
      paths.each do |path|
        absolute_path = File.join(dir, path)
        FileUtils.mkdir_p(File.dirname(absolute_path))
        FileUtils.touch(absolute_path)
      end
    end

    def write_hook_log(dir, outcomes)
      path = File.join(dir, HookLog::DEFAULT_PATH)
      FileUtils.mkdir_p(File.dirname(path))
      lines = outcomes.map { JSON.generate(hook_record(_1)) }
      File.write(path, "#{lines.join("\n")}\n")
    end

    def hook_record(outcome)
      {
        "ts" => "2026-08-30T04:00:00Z",
        "file" => "lib/example.rb",
        "outcome" => outcome,
        "duration_ms" => 12
      }
    end

    def with_clean_fast_project
      Dir.mktmpdir do |dir|
        path = File.join(dir, HookLog::DEFAULT_PATH)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(File.join(dir, ".quality_gate.yml"), "adapters:\n  fast: []\n")
        yield dir, path
      end
    end

    def with_two_temp_dirs
      Dir.mktmpdir do |first|
        Dir.mktmpdir { |second| yield first, second }
      end
    end
  end

  class CLIOutputTest < Minitest::Test
    class ExplodingMessageError < StandardError
      def message
        fail "message extraction failed" # rubocop:disable Style/SignalException
      end
    end

    class FailingArguments
      def dup
        fail ExplodingMessageError # rubocop:disable Style/SignalException
      end
    end

    class CountingFailingIO
      attr_reader :writes

      def initialize
        @writes = 0
      end

      def puts(*)
        @writes += 1
        raise IOError, "output closed"
      end
    end

    class RaisingTTYIO < StringIO
      def tty?
        raise IOError, "tty unavailable"
      end
    end

    class NonStringMessageError < StandardError
      def message = 123
    end

    class BrokenMessageCLI < CLI
      class << self
        private

        def run_gate(*)
          raise ExplodingMessageError
        end
      end
    end

    class NonStringMessageCLI < CLI
      class << self
        private

        def run_gate(*)
          raise NonStringMessageError
        end
      end
    end

    def test_unknown_command_with_closed_stderr_returns_tool_failure
      stderr = StringIO.new
      stderr.close

      status, error = capture_error do
        CLI.run(%w[unknown], stdout: StringIO.new, stderr: stderr)
      end

      assert_nil error
      assert_equal ExitCode::TOOL_FAILURE, status
    end

    def test_version_with_closed_stdout_returns_tool_failure
      stdout = StringIO.new
      stdout.close
      stderr = StringIO.new

      status, error = capture_error do
        CLI.run(%w[version], stdout: stdout, stderr: stderr)
      end

      assert_nil error
      assert_equal ExitCode::TOOL_FAILURE, status
      assert_includes stderr.string, "Error:"
    end

    def test_help_with_closed_stdout_returns_tool_failure
      stdout = StringIO.new
      stdout.close
      stderr = StringIO.new

      status, error = capture_error do
        CLI.run(%w[--help], stdout: stdout, stderr: stderr)
      end

      assert_nil error
      assert_equal ExitCode::TOOL_FAILURE, status
      assert_equal "Error: could not write help output\n", stderr.string
    end

    def test_gate_command_with_closed_stdout_returns_tool_failure
      Dir.mktmpdir do |dir|
        stdout = StringIO.new
        stdout.close
        stderr = StringIO.new

        status, error = capture_error do
          CLI.run(%w[fast], stdout: stdout, stderr: stderr, dir: dir)
        end

        assert_nil error
        assert_equal ExitCode::TOOL_FAILURE, status
        assert_includes stderr.string, "Error:"
      end
    end

    def test_json_gate_with_closed_stdout_reports_one_text_output_error
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".quality_gate.yml"), "adapters:\n  fast: []\n")
        stdout = StringIO.new
        stdout.close
        stderr = StringIO.new

        status, error = capture_error do
          CLI.run(%w[fast --format=json], stdout: stdout, stderr: stderr, dir: dir)
        end

        assert_nil error
        assert_equal ExitCode::TOOL_FAILURE, status
        assert_equal 1, stderr.string.lines.length
        assert_match(/\AError:/, stderr.string)
        refute_includes stderr.string, "{\"findings\""
      end
    end

    def test_json_config_error_attempts_one_report_write_when_stdout_fails
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".quality_gate.yml"), "format: [json\n")
        stdout = CountingFailingIO.new
        stderr = StringIO.new

        status, error = capture_error do
          CLI.run(%w[fast --format=json], stdout: stdout, stderr: stderr, dir: dir)
        end

        assert_nil error
        assert_equal ExitCode::TOOL_FAILURE, status
        assert_equal 1, stdout.writes
        assert_match(/\AError:/, stderr.string)
      end
    end

    def test_json_error_falls_back_when_error_message_raises
      Dir.mktmpdir do |dir|
        stdout = StringIO.new
        stderr = StringIO.new

        status, error = capture_error do
          BrokenMessageCLI.run(%w[fast --format=json], stdout: stdout, stderr: stderr, dir: dir)
        end

        assert_nil error
        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stderr.string
        message = JSON.parse(stdout.string).fetch("findings").first.fetch("message")
        assert_equal "quality_gate failed", message
      end
    end

    def test_json_error_converts_a_non_string_error_message
      Dir.mktmpdir do |dir|
        stdout = StringIO.new
        stderr = StringIO.new

        status, error = capture_error do
          NonStringMessageCLI.run(%w[fast --format=json], stdout: stdout, stderr: stderr, dir: dir)
        end

        assert_nil error
        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stderr.string
        message = JSON.parse(stdout.string).fetch("findings").first.fetch("message")
        assert_equal "123", message
      end
    end

    def test_tty_detection_failure_disables_progress_without_affecting_json
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".quality_gate.yml"), "adapters:\n  fast: []\n")
        stdout = StringIO.new
        stderr = RaisingTTYIO.new

        status, error = capture_error do
          CLI.run(%w[fast --format=json], stdout: stdout, stderr: stderr, dir: dir)
        end

        assert_nil error
        assert_equal ExitCode::CLEAN, status
        assert_equal [], JSON.parse(stdout.string).fetch("findings")
        assert_empty stderr.string
      end
    end

    def test_exception_with_broken_message_returns_tool_failure
      stderr = StringIO.new

      status, error = capture_error do
        CLI.run(FailingArguments.new, stdout: StringIO.new, stderr: stderr)
      end

      assert_nil error
      assert_equal ExitCode::TOOL_FAILURE, status
      assert_equal "Error: quality_gate failed\n", stderr.string
    end

    private

    def capture_error
      [yield, nil]
    rescue StandardError => e
      [nil, e]
    end
  end

  class CLIDiagnosticTest < Minitest::Test
    def test_unknown_adapter_helper_constant_is_not_public
      error = assert_raises(NameError) do
        CLI.singleton_class::UnknownAdapter
      end

      assert_includes error.message, "UnknownAdapter"
    end

    def test_invalid_format_diagnostic_sanitizes_control_characters
      bad_format = "xml\n\t\e[31m"
      status, stdout, stderr = run_cli(["fast", "--format", bad_format])

      assert_equal ExitCode::TOOL_FAILURE, status
      assert_empty stdout
      assert_equal 2, stderr.lines.length
      assert_equal "Usage: quality_gate <fast|verify|audit|version|init> [options]\n", stderr.lines.last
      assert_includes stderr.lines.first, "xml"
      refute_match(/[\u0000-\u001F\u007F]/, stderr.lines.first.chomp)
    end

    def test_invalid_format_diagnostic_scrubs_invalid_encoding
      bad_format = "xml\xFF".dup.force_encoding(Encoding::UTF_8)
      status, stdout, stderr = run_cli(["fast", "--format", bad_format])

      assert_equal ExitCode::TOOL_FAILURE, status
      assert_empty stdout
      assert_predicate stderr, :valid_encoding?
      assert_equal 1, stderr.lines.length
      assert_includes stderr, "Error:"
      refute_match(/[\u0000-\u001F\u007F]/, stderr.chomp)
    end

    def test_invalid_format_diagnostic_sanitizes_unicode_line_separators
      bad_format = "xml\u2028middle\u2029end"
      status, stdout, stderr = run_cli(["fast", "--format", bad_format])

      assert_equal ExitCode::TOOL_FAILURE, status
      assert_empty stdout
      assert_equal [
        "Error: invalid argument: --format xml middle end\n",
        "Usage: quality_gate <fast|verify|audit|version|init> [options]\n"
      ], stderr.lines
    end

    def test_unknown_key_warning_sanitizes_control_characters
      yaml = "\"mystery\\n\\t\\e[31m\": true\n"
      in_directory_with_config(yaml) do |dir|
        cli = CLIOptionsTest::RecordingCLI
        cli.reset
        status, stdout, stderr = run_cli(%w[audit], dir: dir, cli: cli)

        assert_equal ExitCode::TOOL_FAILURE, status
        assert_empty stdout
        assert_equal Config.defaults, cli.settings
        assert_equal "Warning: unknown config key mystery [31m\n", stderr
      end
    end

    private

    def run_cli(argv, dir: nil, cli: CLI)
      return Dir.mktmpdir { run_cli(argv, dir: _1, cli: cli) } unless dir

      stdout = StringIO.new
      stderr = StringIO.new
      status = cli.run(argv, stdout: stdout, stderr: stderr, dir: dir)

      [status, stdout.string, stderr.string]
    end

    def in_directory_with_config(contents)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".quality_gate.yml"), contents)
        yield dir
      end
    end
  end
end
