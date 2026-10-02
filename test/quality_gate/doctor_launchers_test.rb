# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "rbconfig"
require "tmpdir"
require "quality_gate/doctor_report"
require "quality_gate/doctor_launchers"

class DoctorLaunchersTest < Minitest::Test
  def test_relative_script_and_path_entries_are_resolved_from_project_dir
    with_project do |dir|
      executable = write_executable(dir, "bin/rubocop")
      launcher = QualityGate::DoctorLaunchers.new(dir:, path: "bin::missing")
      before = Dir.pwd

      check = launcher.check(adapter: "rubocop", argv: ["rubocop", "--format", "json"])

      assert_equal "ready", check.fetch("status")
      assert_equal before, Dir.pwd
      assert File.executable?(executable)
    end
  end

  def test_empty_path_resolves_an_empty_entry_from_project_dir
    with_project do |dir|
      write_executable(dir, "rubocop")
      check = QualityGate::DoctorLaunchers.new(dir:, path: "").check(
        adapter: "rubocop", argv: ["rubocop"]
      )

      assert_equal "ready", check.fetch("status")
    end
  end

  def test_actual_herb_default_launcher_is_recognized
    with_project do |dir|
      write_executable(dir, "bin/herb-lint")
      check = QualityGate::DoctorLaunchers.new(dir:, path: "bin").check(
        adapter: "herb", argv: ["herb-lint"]
      )

      assert_equal "ready", check.fetch("status")
    end
  end

  def test_missing_explicit_path_does_not_fall_through_to_path_lookup
    with_project do |dir|
      write_executable(dir, "other/bin/tool")
      check = QualityGate::DoctorLaunchers.new(dir:, path: "other").check(
        adapter: "test_suite", argv: ["bin/tool"]
      )

      assert_equal "blocked", check.fetch("status")
    end
  end

  def test_missing_direct_executable_is_blocked_and_missing_bundled_target_is_unchecked
    with_project do |dir|
      write_executable(dir, "bin/bundle")
      launcher = QualityGate::DoctorLaunchers.new(dir:, path: "bin")

      direct = launcher.check(adapter: "rubocop", argv: ["rubocop"])
      bundled = launcher.check(adapter: "rubocop", argv: %w[bundle exec rubocop])
      custom_bundled = launcher.check(adapter: "test_suite", argv: %w[bundle exec custom-tool])

      assert_equal "blocked", direct.fetch("status")
      assert_equal "unchecked", bundled.fetch("status")
      assert_equal "unchecked", custom_bundled.fetch("status")
    end
  end

  def test_bundle_requires_an_outer_launcher_before_inspecting_a_reachable_target
    with_project do |dir|
      write_executable(dir, "bin/rubocop")
      launcher = QualityGate::DoctorLaunchers.new(dir:, path: "bin")

      blocked = launcher.check(adapter: "rubocop", argv: %w[bundle exec rubocop])

      assert_equal "blocked", blocked.fetch("status")
      assert_match(/install Bundler|add it to PATH/, blocked.fetch("message"))
    end
  end

  def test_reachable_bundle_and_nested_target_are_ready
    with_project do |dir|
      write_executable(dir, "bin/bundle")
      write_executable(dir, "bin/rubocop")
      check = QualityGate::DoctorLaunchers.new(dir:, path: "bin").check(
        adapter: "rubocop", argv: %w[bundle exec rubocop]
      )

      assert_equal "ready", check.fetch("status")
    end
  end

  def test_bundle_exec_ruby_with_missing_script_is_blocked
    with_project do |dir|
      write_executable(dir, "bin/bundle")
      path = [File.join(dir, "bin"), ENV.fetch("PATH")].join(File::PATH_SEPARATOR)
      check = QualityGate::DoctorLaunchers.new(dir:, path:).check(
        adapter: "test_suite", argv: %w[bundle exec ruby missing.rb]
      )

      assert_equal "blocked", check.fetch("status")
    end
  end

  def test_explicit_bundle_target_is_ready_when_bundle_and_target_exist
    with_project do |dir|
      write_executable(dir, "bin/bundle")
      target = write_executable(dir, "bin/rubocop")
      argv = ["bundle", "exec", target]

      check = QualityGate::DoctorLaunchers.new(dir:, path: "bin").check(
        adapter: "rubocop", argv:
      )

      assert_equal "ready", check.fetch("status")
    end
  end

  def test_explicit_bundle_target_is_unchecked_when_path_is_unavailable
    with_project do |dir|
      target = write_executable(dir, "bin/rubocop")
      check = QualityGate::DoctorLaunchers.new(dir:, path: nil).check(
        adapter: "rubocop", argv: ["bundle", "exec", target]
      )

      assert_equal "unchecked", check.fetch("status")
    end
  end

  def test_explicit_known_launcher_is_ready
    with_project do |dir|
      write_executable(dir, "bin/rubocop")
      check = QualityGate::DoctorLaunchers.new(dir:, path: nil).check(
        adapter: "rubocop", argv: ["./bin/rubocop"]
      )

      assert_equal "ready", check.fetch("status")
    end
  end

  def test_missing_explicit_nested_targets_block_even_without_path
    with_project do |dir|
      launcher = QualityGate::DoctorLaunchers.new(dir:, path: nil)

      bundle_target = launcher.check(adapter: "test_suite", argv: ["bundle", "exec", "#{dir}/missing-exec"])
      bundle_script = launcher.check(adapter: "test_suite", argv: ["bundle", "exec", "ruby", "#{dir}/missing.rb"])
      ruby_script = launcher.check(adapter: "test_suite", argv: ["ruby", "#{dir}/missing.rb"])

      assert_equal "blocked", bundle_target.fetch("status")
      assert_equal "blocked", bundle_script.fetch("status")
      assert_equal "blocked", ruby_script.fetch("status")
    end
  end

  def test_every_non_ready_launcher_message_has_a_next_action
    with_project do |dir|
      checks = [
        QualityGate::DoctorLaunchers.new(dir:, path: nil).check(adapter: "rubocop", argv: ["ruby"]),
        QualityGate::DoctorLaunchers.new(dir:, path: "").check(adapter: "test_suite", argv: ["./missing-wrapper"])
      ]

      assert(checks.all? { |check| check.fetch("message").match?(/install|add|set|update|inspect|verify|supply/i) })
    end
  end

  def test_ruby_script_must_be_readable_and_missing_explicit_script_is_blocked
    with_project do |dir|
      readable_rails_script(dir)
      launcher = QualityGate::DoctorLaunchers.new(dir:, path: ENV.fetch("PATH"))

      ready = launcher.check(adapter: "test_suite", argv: ["ruby", "bin/rails", "test"])
      missing = launcher.check(adapter: "test_suite", argv: ["ruby", "bin/missing", "test"])

      assert_equal "ready", ready.fetch("status")
      assert_equal "blocked", missing.fetch("status")
    end
  end

  def test_unreadable_ruby_script_is_blocked
    with_project do |dir|
      readable_rails_script(dir)
      check = nil
      File.stub(:readable?, false) do
        check = QualityGate::DoctorLaunchers.new(dir:, path: ENV.fetch("PATH")).check(
          adapter: "test_suite", argv: [RbConfig.ruby, "bin/rails", "test"]
        )
      end

      assert_equal "blocked", check.fetch("status")
      assert_match(/permissions/i, check.fetch("message"))
    end
  end

  def test_missing_ruby_launcher_blocks_when_script_exists
    with_project do |dir|
      readable_rails_script(dir)
      check = QualityGate::DoctorLaunchers.new(dir:, path: "").check(
        adapter: "test_suite", argv: ["ruby", "bin/rails", "test"]
      )

      assert_equal "blocked", check.fetch("status")
    end
  end

  def test_ruby_launcher_without_command_is_unchecked
    with_project do |dir|
      check = QualityGate::DoctorLaunchers.new(dir:, path: nil).check(
        adapter: "test_suite", argv: [RbConfig.ruby]
      )

      assert_equal "unchecked", check.fetch("status")
    end
  end

  def test_existing_ruby_script_stays_unchecked_when_ruby_is_unresolved
    with_project do |dir|
      readable_rails_script(dir)
      check = QualityGate::DoctorLaunchers.new(dir:, path: nil).check(
        adapter: "test_suite", argv: ["ruby", "bin/rails", "test"]
      )

      assert_equal "unchecked", check.fetch("status")
    end
  end

  def test_absolute_ruby_launcher_and_project_script_are_checked
    with_project do |dir|
      script = File.join(dir, "sentinel.rb")
      File.write(script, "exit 0\n")
      check = QualityGate::DoctorLaunchers.new(dir:, path: nil).check(
        adapter: "test_suite", argv: [RbConfig.ruby, script]
      )

      assert_equal "ready", check.fetch("status")
    end
  end

  def test_arbitrary_wrapper_stays_unchecked_even_if_it_exists
    with_project do |dir|
      write_executable(dir, "bin/wrapper")
      launcher = QualityGate::DoctorLaunchers.new(dir:, path: "bin")
      check = launcher.check(
        adapter: "test_suite", argv: %w[wrapper run]
      )
      missing = launcher.check(adapter: "test_suite", argv: ["./missing-wrapper", "run"])

      assert_equal "unchecked", check.fetch("status")
      assert_equal "blocked", missing.fetch("status")
    end
  end

  def test_explicit_custom_wrapper_and_non_executable_direct_launcher_are_bounded
    with_project do |dir|
      wrapper = write_executable(dir, "bin/custom-wrapper")
      direct = File.join(dir, "bin", "rubocop")
      File.write(direct, "not executable")
      File.chmod(0o644, direct)
      launcher = QualityGate::DoctorLaunchers.new(dir:, path: "bin")

      explicit_wrapper = launcher.check(adapter: "test_suite", argv: [wrapper, "run"])
      non_executable = launcher.check(adapter: "rubocop", argv: ["rubocop"])

      assert_equal "unchecked", explicit_wrapper.fetch("status")
      assert_equal "blocked", non_executable.fetch("status")
      assert_match(/permissions|install|PATH/, non_executable.fetch("message"))
    end
  end

  def test_missing_direct_and_custom_bare_launchers_are_distinguished_without_path
    with_project do |dir|
      launcher = QualityGate::DoctorLaunchers.new(dir:, path: nil)

      direct = launcher.check(adapter: "rubocop", argv: ["rubocop"])
      custom = launcher.check(adapter: "test_suite", argv: ["custom-wrapper"])

      assert_equal "unchecked", direct.fetch("status")
      assert_equal "unchecked", custom.fetch("status")
    end
  end

  def test_missing_custom_bare_wrapper_is_blocked_when_path_is_inspectable
    with_project do |dir|
      check = QualityGate::DoctorLaunchers.new(dir:, path: "").check(
        adapter: "test_suite", argv: ["custom-wrapper"]
      )

      assert_equal "blocked", check.fetch("status")
    end
  end

  def test_ruby_options_and_eval_forms_remain_unchecked
    with_project do |dir|
      launcher = QualityGate::DoctorLaunchers.new(dir:, path: ENV.fetch("PATH"))

      eval_form = launcher.check(adapter: "test_suite", argv: [RbConfig.ruby, "-e", "exit 0"])
      option_form = launcher.check(adapter: "test_suite", argv: [RbConfig.ruby, "-Ilib", "script.rb"])

      assert_equal "unchecked", eval_form.fetch("status")
      assert_equal "unchecked", option_form.fetch("status")
    end
  end

  def test_ruby_search_checks_known_targets_without_running_them
    with_project do |dir|
      write_executable(dir, "bin/rubocop")
      launcher = QualityGate::DoctorLaunchers.new(dir:, path: "bin")

      ready = launcher.check(adapter: "rubocop", argv: [RbConfig.ruby, "-S", "rubocop"])
      explicit_ready = launcher.check(adapter: "rubocop", argv: [RbConfig.ruby, "-S", "bin/rubocop"])

      assert_equal "ready", ready.fetch("status")
      assert_equal "ready", explicit_ready.fetch("status")
    end
  end

  def test_ruby_search_missing_unknown_and_unavailable_targets_stay_unchecked
    with_project do |dir|
      launcher = QualityGate::DoctorLaunchers.new(dir:, path: "bin")
      missing = launcher.check(adapter: "rubocop", argv: [RbConfig.ruby, "-S", "rspec"])
      unknown = launcher.check(adapter: "test_suite", argv: [RbConfig.ruby, "-S", "custom-tool"])
      unavailable = QualityGate::DoctorLaunchers.new(dir:, path: nil).check(
        adapter: "rubocop", argv: [RbConfig.ruby, "-S", "rubocop"]
      )

      assert_equal "unchecked", missing.fetch("status")
      assert_equal "unchecked", unknown.fetch("status")
      assert_equal "unchecked", unavailable.fetch("status")
    end
  end

  def test_ruby_search_with_missing_explicit_target_is_blocked
    with_project do |dir|
      check = QualityGate::DoctorLaunchers.new(dir:, path: ENV.fetch("PATH")).check(
        adapter: "rubocop", argv: ["ruby", "-S", "bin/missing-rubocop"]
      )

      assert_equal "blocked", check.fetch("status")
    end
  end

  def test_ruby_search_without_target_is_unchecked
    with_project do |dir|
      check = QualityGate::DoctorLaunchers.new(dir:, path: nil).check(
        adapter: "test_suite", argv: [RbConfig.ruby, "-S"]
      )

      assert_equal "unchecked", check.fetch("status")
    end
  end

  def test_filesystem_probe_error_becomes_a_bounded_unchecked_result
    with_project do |dir|
      check = QualityGate::DoctorLaunchers.new(dir:, path: nil).check(
        adapter: "test_suite", argv: ["./bad\0launcher"]
      )

      assert_equal "unchecked", check.fetch("status")
      refute_match(/bad\0launcher/, check.fetch("message"))
      assert_match(/verify|inspect/i, check.fetch("message"))
    end
  end

  private

  def with_project(&block)
    Dir.mktmpdir("quality-gate-launchers", &block)
  end

  def write_executable(dir, path)
    absolute_path = File.join(dir, path)
    FileUtils.mkdir_p(File.dirname(absolute_path))
    File.write(absolute_path, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, absolute_path)
    absolute_path
  end

  def readable_rails_script(dir)
    script = File.join(dir, "bin", "rails")
    FileUtils.mkdir_p(File.dirname(script))
    File.write(script, "puts :sentinel")
    File.chmod(0o644, script)
  end
end
