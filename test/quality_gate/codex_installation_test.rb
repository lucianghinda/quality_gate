# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "rails/generators"
require "shellwords"
require "stringio"
require "tmpdir"
require "quality_gate/doctor_hooks"
require "quality_gate/init_command"
require "quality_gate/installer"
require "generators/quality_gate/install/install_generator"

module QualityGate
  class CodexInstallationTest < Minitest::Test
    def test_codex_option_installs_native_stop_hook_and_only_the_shared_contract
      with_project do |tmp|
        root = File.join(tmp, "quality gate's project")
        FileUtils.mkdir_p(File.join(root, "test"))
        File.write(File.join(root, "test/test_helper.rb"), "# tests\n")
        assert_equal 0, install_ruby(root, "--codex")
        assert_codex_only_installation(root)
      end
    end

    def test_agents_and_codex_install_both_clients_and_one_agents_contract
      with_project do |root|
        assert_equal 0, install_ruby(root, "--agents", "--codex")
        assert_both_clients_installed(root)
      end
    end

    def test_default_install_does_not_create_codex_artifacts
      with_project do |root|
        status = run_installer(root, {})

        assert_equal 0, status
        refute_path_exists File.join(root, ".codex")
        refute_path_exists File.join(root, "AGENTS.md")
      end
    end

    def test_codex_installation_is_idempotent_and_repairs_script_mode
      with_project do |root|
        assert_equal 0, run_installer(root, { codex: true })
        before = codex_snapshot(root)
        script = File.join(root, ".codex/hooks/quality_gate_verify_stop.rb")
        File.chmod(0o644, script)

        assert_equal 0, run_installer(root, { codex: true })
        assert_equal before, codex_snapshot(root)
        assert_equal 0o755, File.stat(script).mode & 0o777
      end
    end

    def test_codex_pretend_does_not_write_agent_artifacts
      with_project do |root|
        status = run_installer(root, { codex: true, pretend: true })

        assert_equal 0, status
        refute_path_exists File.join(root, ".codex")
        refute_path_exists File.join(root, "AGENTS.md")
      end
    end

    def test_custom_codex_hook_configuration_is_preserved_for_manual_integration
      with_project do |root|
        config = File.join(root, ".codex/hooks.json")
        FileUtils.mkdir_p(File.dirname(config))
        File.write(config, "{\"hooks\": {\"Stop\": []}}\n")
        output = StringIO.new

        status = run_installer(root, { codex: true }, stdout: output)
        assert_manual_codex_proposal(status:, output:, config:, root:)
      end
    end

    def test_codex_symlink_destinations_are_reported_without_following_them
      with_project do |root|
        outside = Dir.mktmpdir("codex-outside")
        File.symlink(outside, File.join(root, ".codex"))
        output = StringIO.new

        status = run_installer(root, { codex: true }, stdout: output)

        assert_equal 1, status
        assert_empty Dir.children(outside)
        assert_includes output.string, ".codex/hooks.json"
        assert_includes output.string, "not a safe path"
      ensure
        FileUtils.remove_entry(outside) if outside && File.exist?(outside)
      end
    end

    def test_codex_file_symlinks_are_preserved_and_reported
      %w[.codex/hooks.json .codex/hooks/quality_gate_verify_stop.rb].each do |path|
        assert_codex_file_symlink(path)
      end
    end

    def test_init_command_accepts_codex_as_an_independent_opt_in
      with_project do |root|
        status = InitCommand.run(["--codex"], stdout: StringIO.new, stderr: StringIO.new, dir: root)

        assert_equal 0, status
        assert_path_exists File.join(root, ".codex/hooks.json")
        refute_path_exists File.join(root, ".claude")
      end
    end

    def test_rails_generator_accepts_codex_as_an_independent_opt_in
      with_project do |root|
        output, error = capture_io do
          InstallGenerator.start(["--codex"], destination_root: root)
        end

        assert_empty error
        assert_includes output, ".codex/hooks.json"
        assert_path_exists File.join(root, ".codex/hooks.json")
        refute_path_exists File.join(root, ".claude")
        assert_codex_hook_config(root)
      end
    end

    def test_rails_generator_composes_both_client_options_once
      with_project do |root|
        output, error = capture_io do
          InstallGenerator.start(["--agents", "--codex"], destination_root: root)
        end

        assert_empty error
        assert_includes output, ".codex/hooks.json"
        assert_both_clients_installed(root)
      end
    end

    def test_doctor_marks_partial_codex_installation_unchecked
      %w[.codex/hooks.json .codex/hooks/quality_gate_verify_stop.rb].each do |relative_path|
        with_project do |root|
          path = File.join(root, relative_path)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, "{}")

          report = DoctorHooks.new(dir: root).call.fetch(0)

          assert_equal "unchecked", report.fetch("status")
          assert_match(/history.*unchecked|unchecked.*history/i, report.fetch("message"))
          refute_match(/trusted|is active|active hook|ready|installed and working/i, report.fetch("message"))
        end
      end
    end

    private

    def install_ruby(root, *arguments)
      InitCommand.run(arguments, stdout: StringIO.new, stderr: StringIO.new, dir: root)
    end

    def run_installer(root, options, stdout: StringIO.new)
      Installer.new(destination_root: root, options:, stdout:).call
    end

    def assert_codex_hook_config(root)
      script = File.join(root, ".codex/hooks/quality_gate_verify_stop.rb")

      assert_equal expected_codex_config(script), JSON.parse(File.read(File.join(root, ".codex/hooks.json")))
      assert_equal 0o644, File.stat(File.join(root, ".codex/hooks.json")).mode & 0o777
    end

    def assert_codex_only_installation(root)
      assert_path_exists File.join(root, ".codex/hooks.json")
      assert_equal 0o755, File.stat(File.join(root, ".codex/hooks/quality_gate_verify_stop.rb")).mode & 0o777
      refute_path_exists File.join(root, ".claude")
      refute_path_exists File.join(root, "CLAUDE.md")
      assert_codex_contract(root)
      assert_codex_hook_config(root)
    end

    def assert_codex_contract(root)
      contract = File.read(File.join(root, "AGENTS.md"))

      assert_equal 1, contract.scan("quality_gate agent contract — start").length
      assert_includes contract, "Codex"
      assert_includes contract, "/hooks"
      assert_includes contract, "after a Quality Gate upgrade that changes"
      refute_includes contract, "After `bundle install`"
    end

    def assert_both_clients_installed(root)
      %w[
        .claude/settings.json
        .claude/hooks/quality_gate_fast.rb
        .claude/hooks/quality_gate_verify_stop.rb
        .codex/hooks.json
        .codex/hooks/quality_gate_verify_stop.rb
        CLAUDE.md
      ].each { assert_path_exists File.join(root, _1) }
      contract = File.read(File.join(root, "AGENTS.md"))
      assert_equal 1, contract.scan("quality_gate agent contract — start").length
      assert_includes contract, "Installed Claude Code hooks"
      assert_includes contract, "optional Codex Stop hook"
    end

    def assert_manual_codex_proposal(status:, output:, config:, root:)
      assert_equal 1, status
      assert_equal "{\"hooks\": {\"Stop\": []}}\n", File.read(config)
      assert_includes output.string, "Use these lines manually for .codex/hooks.json"
      assert_includes output.string, "quality_gate_verify_stop.rb"
      assert_includes output.string, '"timeout": 600'
      assert_includes output.string,
                      Shellwords.join(["ruby", File.join(root, ".codex/hooks/quality_gate_verify_stop.rb")])
    end

    def expected_codex_config(script)
      {
        "hooks" => {
          "Stop" => [
            { "hooks" => [{ "type" => "command", "command" => Shellwords.join(["ruby", script]), "timeout" => 600 }] }
          ]
        }
      }
    end

    def assert_codex_file_symlink(relative_path)
      with_project do |root|
        target = File.join(root, "outside-target")
        File.write(target, "host-owned\n")
        symlink = File.join(root, relative_path)
        FileUtils.mkdir_p(File.dirname(symlink))
        File.symlink(target, symlink)
        output = StringIO.new

        status = run_installer(root, { codex: true }, stdout: output)

        assert_symlink_was_not_followed(root:, relative_path:, status:, output:)
      end
    end

    def assert_symlink_was_not_followed(root:, relative_path:, status:, output:)
      target = File.join(root, "outside-target")
      symlink = File.join(root, relative_path)

      assert_equal 1, status
      assert_equal "host-owned\n", File.read(target)
      assert_includes output.string, "#{relative_path} is not a safe path"
      assert File.symlink?(symlink)
    end

    def codex_snapshot(root)
      %w[.codex/hooks.json .codex/hooks/quality_gate_verify_stop.rb AGENTS.md].to_h do |path|
        [path, File.binread(File.join(root, path))]
      end
    end

    def with_project(name = "codex-install")
      Dir.mktmpdir(name) do |root|
        FileUtils.mkdir_p(File.join(root, "test"))
        File.write(File.join(root, "test/test_helper.rb"), "# tests\n")
        yield root
      end
    end
  end
end
