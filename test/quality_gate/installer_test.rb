# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "stringio"
require "tmpdir"
require "quality_gate/installer"

module QualityGate
  class InstallerTest < Minitest::Test
    def test_plain_ruby_install_uses_shared_files_without_rails_artifacts
      with_project("test/test_helper.rb") do |root|
        output = StringIO.new

        status = Installer.new(destination_root: root, options: {}, stdout: output).call

        assert_equal 0, status
        assert_plain_install_artifacts(root)
        assert_includes output.string, "Quality Gate install summary:"
      end
    end

    def test_agents_are_opt_in_and_reinstallation_is_idempotent
      with_project("test/test_helper.rb") do |root|
        options = { agents: true }
        run_successful_installer(root, options)
        first = managed_snapshot(root)

        run_successful_installer(root, options)
        assert_equal first, managed_snapshot(root)
        assert_agent_artifacts(root)
      end
    end

    def test_pretend_does_not_write_files
      with_project("test/test_helper.rb") do |root|
        status = Installer.new(destination_root: root, options: { pretend: true }, stdout: StringIO.new).call

        assert_equal 0, status
        refute_path_exists File.join(root, ".quality_gate.yml")
        refute_path_exists File.join(root, ".rubocop.yml")
      end
    end

    def test_invalid_profile_input_is_rejected_before_writes
      Dir.mktmpdir("quality-gate-installer") do |root|
        assert_raises(ArgumentError) do
          Installer.new(destination_root: root, options: { test_framework: "cucumber" })
        end

        refute_path_exists File.join(root, ".quality_gate.yml")
      end
    end

    def test_invalid_option_mappings_and_keys_are_rejected_before_writes
      Dir.mktmpdir("quality-gate-installer") do |root|
        assert_raises(ArgumentError) { Installer.new(destination_root: root, options: Object.new) }
        assert_raises(ArgumentError) { Installer.new(destination_root: root, options: { Object.new => true }) }
        assert_raises(ArgumentError) { Installer.new(destination_root: root, options: { unsupported: true }) }

        refute_path_exists File.join(root, ".quality_gate.yml")
      end
    end

    def test_existing_core_file_conflict_returns_needs_person
      with_project("test/test_helper.rb") do |root|
        path = File.join(root, ".quality_gate.yml")
        File.write(path, "adapters: {}\n")

        status = Installer.new(destination_root: root, options: {}, stdout: StringIO.new).call

        assert_equal 1, status
        assert_equal "adapters: {}\n", File.read(path)
      end
    end

    def test_existing_configs_and_helper_content_are_preserved
      with_project("test/test_helper.rb") do |root|
        files = write_existing_configs(root)
        helper_before = File.read(File.join(root, "test/test_helper.rb"))

        status = run_installer(root, {})

        assert_equal 1, status
        assert_existing_configs(root, files)
        assert_coverage_was_added(root, helper_before)
      end
    end

    def test_rspec_profile_injects_the_rspec_helper_and_command
      with_project("spec/spec_helper.rb") do |root|
        options = {
          profile: "ruby",
          test_framework: "rspec",
          test_command: "bundle exec rspec spec --format progress"
        }

        status = run_installer(root, options)

        assert_equal 0, status
        assert_path_exists File.join(root, "spec/spec_helper.rb")
        refute_path_exists File.join(root, "test/test_helper.rb")
        helper = File.read(File.join(root, "spec/spec_helper.rb"))
        assert_includes helper, "quality_gate coverage"
        config = File.read(File.join(root, ".quality_gate.yml"))
        assert_includes config, '"bundle"'
        assert_includes config, '"--format"'
      end
    end

    def test_custom_helper_path_receives_coverage_injection
      with_project("support/spec_helper.rb") do |root|
        status = run_installer(root, test_framework: "rspec", test_helper: "support/spec_helper.rb")

        assert_equal 0, status
        assert_includes File.read(File.join(root, "support/spec_helper.rb")), "quality_gate coverage"
        refute_path_exists File.join(root, "test/test_helper.rb")
        refute_path_exists File.join(root, "spec/spec_helper.rb")
      end
    end

    def test_skip_coverage_allows_a_project_without_a_test_helper
      Dir.mktmpdir("quality-gate-installer") do |root|
        status = run_installer(root, skip_coverage: true)

        assert_equal 0, status
        assert_path_exists File.join(root, ".quality_gate.yml")
        refute_path_exists File.join(root, "test/test_helper.rb")
        refute_path_exists File.join(root, "spec/spec_helper.rb")
      end
    end

    def test_helper_that_already_starts_simplecov_is_left_untouched
      with_project("test/test_helper.rb") do |root|
        helper_path = File.join(root, "test/test_helper.rb")
        File.write(helper_path, hand_rolled_coverage_helper)
        output = StringIO.new

        status = Installer.new(destination_root: root, options: {}, stdout: output).call

        assert_equal 0, status
        assert_equal hand_rolled_coverage_helper, File.read(helper_path)
        assert_includes output.string, "already calls SimpleCov.start"
      end
    end

    def test_helper_that_already_starts_simplecov_reports_a_skip_not_a_failure
      with_project("test/test_helper.rb") do |root|
        File.write(File.join(root, "test/test_helper.rb"), hand_rolled_coverage_helper)
        output = StringIO.new

        Installer.new(destination_root: root, options: {}, stdout: output).call

        assert_includes output.string, "already starts SimpleCov; coverage wiring skipped"
        assert_includes output.string, "Needs a person:\nSkipped:"
      end
    end

    def test_repeated_installs_never_stack_a_second_coverage_block
      with_project("test/test_helper.rb") do |root|
        helper_path = File.join(root, "test/test_helper.rb")
        run_installer(root, {})
        after_first = File.read(helper_path)

        run_installer(root, {})

        assert_equal after_first, File.read(helper_path)
        assert_equal 1, File.read(helper_path).scan("# quality_gate coverage — start").length
      end
    end

    private

    def run_installer(root, options)
      Installer.new(destination_root: root, options:, stdout: StringIO.new).call
    end

    def hand_rolled_coverage_helper
      <<~HELPER
        # frozen_string_literal: true

        require "simplecov"
        SimpleCov.start do
          enable_coverage :branch
        end
      HELPER
    end

    def run_successful_installer(root, options)
      output = StringIO.new
      status = Installer.new(destination_root: root, options:, stdout: output).call
      assert_equal 0, status, installer_diagnostic(status, output)
    end

    def installer_diagnostic(status, output)
      "installer returned #{status}\nstdout:\n#{output.string}"
    end

    def write_existing_configs(root)
      files = {
        ".quality_gate.yml" => "# project config\nadapters: {}\n",
        ".rubocop.yml" => "# project cops\n",
        ".reek.yml" => "# project smells\n"
      }
      files.each { |relative_path, content| File.write(File.join(root, relative_path), content) }
      files
    end

    def assert_existing_configs(root, files)
      files.each { |relative_path, content| assert_equal content, File.read(File.join(root, relative_path)) }
    end

    def assert_coverage_was_added(root, helper_before)
      helper = File.read(File.join(root, "test/test_helper.rb"))
      assert_includes helper, helper_before
      assert_includes helper, "quality_gate coverage"
    end

    def assert_plain_install_artifacts(root)
      assert_path_exists File.join(root, ".quality_gate.yml")
      assert_path_exists File.join(root, ".rubocop.yml")
      assert_path_exists File.join(root, "test/test_helper.rb")
      refute_path_exists File.join(root, "config/initializers")
      refute_path_exists File.join(root, ".claude")
    end

    def assert_agent_artifacts(root)
      %w[
        .claude/hooks/quality_gate_fast.rb
        .claude/hooks/quality_gate_verify_stop.rb
        .claude/settings.json
        CLAUDE.md
        AGENTS.md
      ].each { assert_path_exists File.join(root, _1) }
    end

    def with_project(*files)
      Dir.mktmpdir("quality-gate-installer") do |root|
        files.each do |relative_path|
          path = File.join(root, relative_path)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, "# helper\n")
        end
        yield root
      end
    end

    def managed_snapshot(root)
      Dir.glob("**/*", File::FNM_DOTMATCH, base: root).sort.filter_map do |relative_path|
        path = File.join(root, relative_path)
        next unless File.file?(path)

        [relative_path, File.binread(path)]
      end
    end
  end
end
