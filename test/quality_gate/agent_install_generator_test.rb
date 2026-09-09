# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "rails/generators"
require "timeout"
require "tmpdir"
require "generators/quality_gate/install/install_generator"

module QualityGate
  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  class AgentInstallGeneratorTest < Minitest::Test
    AGENT_HOOKS = {
      ".claude/hooks/quality_gate_fast.rb" => "quality_gate_fast.rb.tt",
      ".claude/hooks/quality_gate_verify_stop.rb" => "quality_gate_verify_stop.rb.tt"
    }.freeze
    AGENT_FILES = %w[
      .claude/hooks/quality_gate_fast.rb
      .claude/hooks/quality_gate_verify_stop.rb
      .claude/settings.json
      CLAUDE.md
      AGENTS.md
    ].freeze
    MANAGED_FILES = [
      ".quality_gate.yml",
      ".rubocop.yml",
      "config/initializers/bullet.rb",
      "config/initializers/strong_migrations.rb",
      "test/test_helper.rb",
      *AGENT_FILES
    ].freeze
    PRE_STOP_CLAUDE_SETTINGS = <<~'JSON'.b.freeze
      {
        "hooks": {
          "PostToolUse": [
            {
              "matcher": "Edit|Write",
              "hooks": [
                {
                  "type": "command",
                  "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/quality_gate_fast.rb",
                  "args": [],
                  "timeout": 30
                }
              ]
            }
          ]
        }
      }
    JSON
    GENERATOR_TASKS = %w[
      create_settings_file
      create_rules_file
      create_initializers
      inject_coverage
      create_agent_integration
      print_summary
    ].freeze

    def test_exposes_the_agent_managed_paths_and_ordered_public_step
      assert_equal MANAGED_FILES, InstallGenerator::FILES
      assert_equal GENERATOR_TASKS, InstallGenerator.tasks.keys
    end

    def test_clean_host_installs_the_agent_hook_settings_and_contract_files
      with_host do |host|
        stdout, stderr = run_generator(host)

        assert_empty stderr, generator_diagnostic(stdout, stderr)
        AGENT_FILES.each do |relative_path|
          assert_path_exists File.join(host, relative_path), generator_diagnostic(stdout, stderr)
        end
        AGENT_HOOKS.each do |relative_path, template_name|
          assert_equal expected_template(template_name), read(host, relative_path)
          assert_equal 0o755, File.stat(File.join(host, relative_path)).mode & 0o777
        end
        assert_equal expected_template("claude_settings.json.tt"), read(host, ".claude/settings.json")
        assert_equal expected_template("agents_section.md.tt"), read(host, "CLAUDE.md")
        assert_equal expected_template("agents_section.md.tt"), read(host, "AGENTS.md")
        assert_equal MANAGED_FILES, summary_entries(stdout, "Written")
        assert_equal "Next: bundle exec quality_gate fast", stdout.lines.last.chomp
      end
    end

    def test_exact_agent_files_are_inert_on_second_run
      with_host do |host|
        run_generator(host)
        managed = AGENT_FILES
        managed.each_with_index do |relative_path, index|
          timestamp = Time.at(1_700_100_000 + index)
          File.utime(timestamp, timestamp, File.join(host, relative_path))
        end
        before = snapshot_for(host, managed)

        stdout, stderr = run_generator(host)

        assert_empty stderr
        assert_equal before, snapshot_for(host, managed)
        managed.each { assert_includes summary_entries(stdout, "Unchanged"), _1 }
      end
    end

    def test_exact_hook_content_repairs_a_non_executable_mode
      AGENT_HOOKS.each do |relative_path, template_name|
        with_host do |host|
          hook_path = File.join(host, relative_path)
          FileUtils.mkdir_p(File.dirname(hook_path))
          File.binwrite(hook_path, expected_template(template_name))
          File.chmod(0o644, hook_path)
          before = File.binread(hook_path)

          stdout, stderr = run_generator(host)

          assert_empty stderr, relative_path
          assert_equal before, File.binread(hook_path), relative_path
          assert_equal 0o755, File.stat(hook_path).mode & 0o777, relative_path
          assert_includes summary_entries(stdout, "Written"), relative_path
        end
      end
    end

    def test_divergent_agent_files_are_left_untouched_and_printed_for_manual_action
      with_host do |host|
        hook_paths = AGENT_HOOKS.keys.to_h { [_1, File.join(host, _1)] }
        settings_path = File.join(host, ".claude/settings.json")
        developer_settings = <<~JSON.b
          {
            "hooks": {
              "Notification": [
                { "hooks": [{ "type": "command", "command": "bin/developer-hook" }] }
              ]
            }
          }
        JSON
        FileUtils.mkdir_p(File.dirname(hook_paths.values.first))
        hook_paths.each_value { File.binwrite(_1, "#!/usr/bin/env ruby\nwarn 'custom hook'\n") }
        File.binwrite(settings_path, developer_settings)
        hook_times = hook_paths.keys.each_with_index.to_h { |path, index| [path, Time.at(1_700_100_100 + index)] }
        settings_time = Time.at(1_700_100_101)
        hook_paths.each do |relative_path, path|
          timestamp = hook_times.fetch(relative_path)
          File.utime(timestamp, timestamp, path)
        end
        File.utime(settings_time, settings_time, settings_path)

        stdout, stderr = run_generator(host)

        assert_empty stderr
        hook_paths.each do |relative_path, path|
          assert_equal "#!/usr/bin/env ruby\nwarn 'custom hook'\n", File.binread(path), relative_path
          assert_equal hook_times.fetch(relative_path), File.mtime(path), relative_path
          assert_includes stdout, manual_instructions(relative_path, AGENT_HOOKS.fetch(relative_path))
          assert_includes summary_entries(stdout, "Needs a person"), relative_path
        end
        assert_equal developer_settings, File.binread(settings_path)
        assert_equal settings_time, File.mtime(settings_path)
        assert_includes stdout, manual_instructions(".claude/settings.json", "claude_settings.json.tt")
        assert_includes summary_entries(stdout, "Needs a person"), ".claude/settings.json"
      end
    end

    def test_prior_settings_versions_are_private_frozen_binary_bytes
      prior_settings = InstallGenerator.const_get(:PRIOR_CLAUDE_SETTINGS, false)

      assert_equal [PRE_STOP_CLAUDE_SETTINGS], prior_settings
      assert_equal 17, prior_settings.first.lines.length
      assert prior_settings.first.end_with?("\n".b)
      assert_predicate prior_settings, :frozen?
      prior_settings.each do |settings|
        assert_predicate settings, :frozen?
        assert_equal Encoding::BINARY, settings.encoding
      end
      assert_raises(NameError) { InstallGenerator::PRIOR_CLAUDE_SETTINGS }
    end

    def test_prior_settings_template_is_safely_upgraded
      with_host do |host|
        settings_path = File.join(host, ".claude/settings.json")
        FileUtils.mkdir_p(File.dirname(settings_path))
        File.binwrite(settings_path, PRE_STOP_CLAUDE_SETTINGS)
        File.chmod(0o640, settings_path)

        stdout, stderr = run_generator(host)

        assert_empty stderr
        assert_equal expected_template("claude_settings.json.tt"), File.binread(settings_path)
        assert_equal 0o640, File.stat(settings_path).mode & 0o777
        assert_includes summary_entries(stdout, "Written"), ".claude/settings.json"
        refute_includes summary_entries(stdout, "Needs a person"), ".claude/settings.json"
      end
    end

    def test_prior_settings_template_is_skipped_under_pretend
      with_host do |host|
        settings_path = File.join(host, ".claude/settings.json")
        FileUtils.mkdir_p(File.dirname(settings_path))
        File.binwrite(settings_path, PRE_STOP_CLAUDE_SETTINGS)
        timestamp = Time.at(1_700_100_150)
        File.utime(timestamp, timestamp, settings_path)

        stdout, stderr = run_generator(host, "--pretend")

        assert_empty stderr
        assert_equal [PRE_STOP_CLAUDE_SETTINGS, timestamp], [File.binread(settings_path), File.mtime(settings_path)]
        assert_includes summary_entries(stdout, "Skipped"), ".claude/settings.json (pretend)"
        refute_includes summary_entries(stdout, "Written"), ".claude/settings.json"
        refute_includes summary_entries(stdout, "Needs a person"), ".claude/settings.json"
      end
    end

    def test_prior_settings_upgrade_preserves_a_concurrent_developer_edit
      developer_settings = "{\n  \"hooks\": {\"Stop\": [\"developer owned\"]}\n}\n".b

      with_before_replace_content(".claude/settings.json", lambda do |path|
        File.binwrite(path, developer_settings)
      end) do
        with_host do |host|
          settings_path = File.join(host, ".claude/settings.json")
          FileUtils.mkdir_p(File.dirname(settings_path))
          File.binwrite(settings_path, PRE_STOP_CLAUDE_SETTINGS)

          stdout, stderr = run_generator(host)

          assert_empty stderr
          assert_equal developer_settings, File.binread(settings_path)
          refute_temp_artifacts(host)
          assert_includes stdout.b, manual_instructions(".claude/settings.json", "claude_settings.json.tt").b
          assert_includes summary_entries(stdout, "Needs a person"), ".claude/settings.json"
          refute_includes summary_entries(stdout, "Written"), ".claude/settings.json"
        end
      end
    end

    def test_context_files_are_created_appended_replaced_and_then_become_inert
      template = expected_template("agents_section.md.tt")

      {
        "missing" => nil,
        "append" => "# Project notes\n",
        "replace stale block" => <<~MARKDOWN,
          # Project notes

          <!-- quality_gate agent contract — start -->
          stale
          <!-- quality_gate agent contract — end -->
          after
        MARKDOWN
        "current block" => template
      }.each do |label, original|
        with_host do |host|
          %w[CLAUDE.md AGENTS.md].each do |relative_path|
            path = File.join(host, relative_path)
            if original
              File.binwrite(path, original)
              File.chmod(0o640, path)
            end
          end

          stdout, stderr = run_generator(host)

          assert_empty stderr, label
          assert_includes(summary_entries(stdout, original == template ? "Unchanged" : "Written"), "CLAUDE.md", label)
          assert_includes(summary_entries(stdout, original == template ? "Unchanged" : "Written"), "AGENTS.md", label)
          expected = case label
                     when "missing", "current block"
                       template
                     when "append"
                       "# Project notes\n\n#{template}"
                     else
                       "# Project notes\n\n#{template}after\n"
                     end
          %w[CLAUDE.md AGENTS.md].each do |relative_path|
            path = File.join(host, relative_path)
            assert_equal expected, File.binread(path), "#{label} #{relative_path}"
            assert_equal 0o640, File.stat(path).mode & 0o777 if original
          end
          assert_match(/Claude Code hooks.*verify.*automatically.*session end/i, expected, label)
          assert_match(/other clients.*Codex.*verify.*manually/i, expected, label)

          next unless label == "append"

          before = snapshot_for(host, %w[CLAUDE.md AGENTS.md])
          rerun_stdout, rerun_stderr = run_generator(host)

          assert_empty rerun_stderr
          assert_equal before, snapshot_for(host, %w[CLAUDE.md AGENTS.md])
          assert_includes summary_entries(rerun_stdout, "Unchanged"), "CLAUDE.md"
          assert_includes summary_entries(rerun_stdout, "Unchanged"), "AGENTS.md"
        end
      end
    end

    def test_conflicted_or_unsafe_context_targets_are_preserved_and_reported
      with_host do |host, parent|
        outside = File.join(parent, "outside")
        FileUtils.mkdir_p(outside)
        File.symlink(outside, File.join(host, "CLAUDE.md"))
        agents_path = File.join(host, "AGENTS.md")
        original = <<~MARKDOWN.b
          <!-- quality_gate agent contract — start -->
          old
          <!-- quality_gate agent contract — end -->
          middle
          <!-- quality_gate agent contract — start -->
          old again
          <!-- quality_gate agent contract — end -->
        MARKDOWN
        File.binwrite(agents_path, original)
        timestamp = Time.at(1_700_100_200)
        File.utime(timestamp, timestamp, agents_path)

        stdout, stderr = run_generator(host)

        assert_empty stderr
        assert_equal original, File.binread(agents_path)
        assert_equal timestamp, File.mtime(agents_path)
        assert_includes stdout.b, manual_instructions("AGENTS.md", "agents_section.md.tt").b
        assert_includes summary_entries(stdout, "Needs a person"), "CLAUDE.md"
        assert_includes summary_entries(stdout, "Needs a person"), "AGENTS.md"
      end
    end

    def test_unmatched_lone_start_and_lone_end_markers_preserve_both_context_files
      contexts = {
        "lone start" => "<!-- quality_gate agent contract — start -->\nleft open\n".b,
        "lone end" => "orphaned\n<!-- quality_gate agent contract — end -->\n".b
      }

      contexts.each_value do |content|
        with_host do |host|
          write_context_files(host, content)
          before = snapshot_for(host, %w[CLAUDE.md AGENTS.md])

          stdout, stderr = run_generator(host)

          assert_empty stderr
          assert_equal before, snapshot_for(host, %w[CLAUDE.md AGENTS.md])
          assert_includes stdout.b, manual_instructions("CLAUDE.md", "agents_section.md.tt").b
          assert_includes stdout.b, manual_instructions("AGENTS.md", "agents_section.md.tt").b
          assert_includes summary_entries(stdout, "Needs a person"), "CLAUDE.md"
          assert_includes summary_entries(stdout, "Needs a person"), "AGENTS.md"
        end
      end
    end

    def test_atomic_replace_failure_on_append_preserves_context_file_and_prints_manual_contract
      with_forced_atomic_replace_failure("CLAUDE.md") do
        with_host do |host|
          write_context_file(host, "CLAUDE.md", "# Notes\n".b)
          before = snapshot_for(host, ["CLAUDE.md"])

          stdout, stderr = run_generator(host)

          assert_empty stderr
          assert_equal before, snapshot_for(host, ["CLAUDE.md"])
          refute_temp_artifacts(host)
          assert_includes stdout.b, manual_instructions("CLAUDE.md", "agents_section.md.tt").b
          assert_includes summary_entries(stdout, "Needs a person"), "CLAUDE.md"
        end
      end
    end

    def test_atomic_replace_failure_on_stale_replacement_preserves_context_file_and_prints_manual_contract
      stale = <<~MARKDOWN.b
        # Notes

        <!-- quality_gate agent contract — start -->
        stale
        <!-- quality_gate agent contract — end -->
        after
      MARKDOWN

      with_forced_atomic_replace_failure("AGENTS.md") do
        with_host do |host|
          write_context_file(host, "AGENTS.md", stale)
          before = snapshot_for(host, ["AGENTS.md"])

          stdout, stderr = run_generator(host)

          assert_empty stderr
          assert_equal before, snapshot_for(host, ["AGENTS.md"])
          refute_temp_artifacts(host)
          assert_includes stdout.b, manual_instructions("AGENTS.md", "agents_section.md.tt").b
          assert_includes summary_entries(stdout, "Needs a person"), "AGENTS.md"
        end
      end
    end

    def test_crlf_context_files_preserve_newlines_for_append_replace_and_exact_rerun
      template = expected_template("agents_section.md.tt").gsub("\n", "\r\n")
      cases = {
        "append" => ["# Notes\r\n".b, "# Notes\r\n\r\n#{template}".b, "Written"],
        "replace stale block" => [
          [
            "# Notes\r\n\r\n",
            "<!-- quality_gate agent contract — start -->\r\n",
            "stale\r\n",
            "<!-- quality_gate agent contract — end -->\r\n",
            "after\r\n"
          ].join.b,
          "# Notes\r\n\r\n#{template}after\r\n".b,
          "Written"
        ],
        "current block" => [template.b, template.b, "Unchanged"]
      }

      cases.each do |label, (original, expected, heading)|
        with_host do |host|
          write_context_files(host, original)
          before = snapshot_for(host, %w[CLAUDE.md AGENTS.md])
          stdout, stderr = run_generator(host)

          assert_empty stderr, label
          %w[CLAUDE.md AGENTS.md].each do |relative_path|
            path = File.join(host, relative_path)
            assert_equal expected, File.binread(path), "#{label} #{relative_path}"
            assert_equal 0o640, File.stat(path).mode & 0o777
          end
          assert_includes summary_entries(stdout, heading), "CLAUDE.md"
          assert_includes summary_entries(stdout, heading), "AGENTS.md"

          next unless label == "current block"

          assert_equal before, snapshot_for(host, %w[CLAUDE.md AGENTS.md])
        end
      end
    end

    def test_inline_quoted_and_indented_marker_prose_is_preserved_and_appends_the_contract
      original = [
        "This prose mentions <!-- quality_gate agent contract — start --> inline.\n",
        "\"<!-- quality_gate agent contract — end -->\" stays quoted.\n",
        "  <!-- quality_gate agent contract — start --> stays indented.\n"
      ].join.b
      expected = "#{original}\n#{expected_template("agents_section.md.tt")}".b

      with_host do |host|
        write_context_files(host, original)

        stdout, stderr = run_generator(host)

        assert_empty stderr
        %w[CLAUDE.md AGENTS.md].each do |relative_path|
          path = File.join(host, relative_path)
          assert_equal expected, File.binread(path), relative_path
          assert_equal 0o640, File.stat(path).mode & 0o777
        end
        assert_includes summary_entries(stdout, "Written"), "CLAUDE.md"
        assert_includes summary_entries(stdout, "Written"), "AGENTS.md"
      end
    end

    def test_concurrent_context_edit_before_append_preserves_newer_bytes_and_reports_manual_action
      with_before_replace_content("CLAUDE.md", lambda do |path|
        File.binwrite(path, "# Developer changed this file first.\n".b)
      end) do
        with_host do |host|
          write_context_file(host, "CLAUDE.md", "# Notes\n".b)
          before = snapshot_for(host, ["CLAUDE.md"])

          stdout, stderr = run_generator(host)

          assert_empty stderr
          refute_equal before, snapshot_for(host, ["CLAUDE.md"])
          assert_equal "# Developer changed this file first.\n".b, File.binread(File.join(host, "CLAUDE.md"))
          refute_temp_artifacts(host)
          assert_includes stdout.b, manual_instructions("CLAUDE.md", "agents_section.md.tt").b
          assert_includes summary_entries(stdout, "Needs a person"), "CLAUDE.md"
        end
      end
    end

    def test_context_replace_revalidates_at_atomic_replace_entry_and_preserves_newer_bytes
      stale = <<~MARKDOWN.b
        # Notes

        <!-- quality_gate agent contract — start -->
        stale
        <!-- quality_gate agent contract — end -->
        after
      MARKDOWN

      with_before_atomic_replace("CLAUDE.md", lambda do |path|
        File.binwrite(path, "# Changed during atomic replace.\n".b)
      end) do
        with_host do |host|
          write_context_file(host, "CLAUDE.md", stale)

          stdout, stderr = run_generator(host)

          assert_empty stderr
          assert_equal "# Changed during atomic replace.\n".b, File.binread(File.join(host, "CLAUDE.md"))
          refute_temp_artifacts(host)
          assert_includes stdout.b, manual_instructions("CLAUDE.md", "agents_section.md.tt").b
          assert_includes summary_entries(stdout, "Needs a person"), "CLAUDE.md"
        end
      end
    end

    def test_context_replace_revalidates_at_final_claim_boundary_for_in_place_edits
      stale = <<~MARKDOWN.b
        # Notes

        <!-- quality_gate agent contract — start -->
        stale
        <!-- quality_gate agent contract — end -->
        after
      MARKDOWN

      with_after_verified_existing_file("CLAUDE.md", lambda do |path|
        File.binwrite(path, "# Final developer edit.\n".b)
      end) do
        with_host do |host|
          write_context_file(host, "CLAUDE.md", stale)

          stdout, stderr = run_generator(host)

          assert_empty stderr
          assert_equal "# Final developer edit.\n".b, File.binread(File.join(host, "CLAUDE.md"))
          refute_temp_artifacts(host)
          assert_includes stdout.b, manual_instructions("CLAUDE.md", "agents_section.md.tt").b
          assert_includes summary_entries(stdout, "Needs a person"), "CLAUDE.md"
        end
      end
    end

    def test_context_replace_revalidates_at_final_claim_boundary_for_path_replacements
      stale = <<~MARKDOWN.b
        # Notes

        <!-- quality_gate agent contract — start -->
        stale
        <!-- quality_gate agent contract — end -->
        after
      MARKDOWN

      with_after_verified_existing_file("AGENTS.md", lambda do |path|
        File.delete(path)
        File.binwrite(path, "# Replaced at claim boundary.\n".b)
      end) do
        with_host do |host|
          write_context_file(host, "AGENTS.md", stale)

          stdout, stderr = run_generator(host)

          assert_empty stderr
          assert_equal "# Replaced at claim boundary.\n".b, File.binread(File.join(host, "AGENTS.md"))
          refute_temp_artifacts(host)
          assert_includes stdout.b, manual_instructions("AGENTS.md", "agents_section.md.tt").b
          assert_includes summary_entries(stdout, "Needs a person"), "AGENTS.md"
        end
      end
    end

    def test_claim_rollback_keeps_a_new_destination_and_retains_recovery_copy_on_publish_failure
      stale = <<~MARKDOWN.b
        # Notes

        <!-- quality_gate agent contract — start -->
        stale
        <!-- quality_gate agent contract — end -->
        after
      MARKDOWN

      with_after_claim_current_leaf("AGENTS.md", lambda do |path|
        File.binwrite(path, "# Developer replacement at destination.\n".b)
        File.chmod(0o640, path)
      end) do
        with_before_publish_new_tempfile("AGENTS.md", lambda do |_path|
          raise Errno::EIO, "simulated publish failure"
        end) do
          with_host do |host|
            write_context_file(host, "AGENTS.md", stale)

            stdout, stderr = run_generator(host)

            assert_empty stderr
            assert_equal "# Developer replacement at destination.\n".b, File.binread(File.join(host, "AGENTS.md"))
            assert_predicate Dir.glob(File.join(host, ".quality_gate-*.claim")), :any?
            assert_includes stdout, "Warning: recovery copy for AGENTS.md was retained"
            assert_includes stdout.b, manual_instructions("AGENTS.md", "agents_section.md.tt").b
            assert_includes summary_entries(stdout, "Needs a person"), "AGENTS.md"
          end
        end
      end
    end

    def test_claim_rollback_keeps_the_visible_parent_swap_and_retains_recovery_copy
      stale = <<~MARKDOWN.b
        # Notes

        <!-- quality_gate agent contract — start -->
        stale
        <!-- quality_gate agent contract — end -->
        after
      MARKDOWN

      moved_host = nil

      with_after_claim_current_leaf("AGENTS.md", lambda do |path|
        host = File.dirname(path)
        moved_host = "#{host}.moved"
        external = "#{host}.external"
        FileUtils.mkdir_p(external)
        File.rename(host, moved_host)
        File.symlink(external, host)
        File.binwrite(File.join(external, "AGENTS.md"), "# Visible developer file.\n".b)
        File.chmod(0o640, File.join(external, "AGENTS.md"))
      end) do
        with_before_publish_new_tempfile("AGENTS.md", lambda do |_path|
          raise Errno::EIO, "simulated publish failure"
        end) do
          with_host do |host|
            write_context_file(host, "AGENTS.md", stale)

            stdout, stderr = run_generator(host)

            assert_empty stderr
            assert_equal "# Visible developer file.\n".b, File.binread(File.join(host, "AGENTS.md"))
            refute_path_exists File.join(moved_host, "AGENTS.md")
            assert_predicate Dir.glob(File.join(moved_host, ".quality_gate-*.claim")), :any?
            assert_includes stdout, "Warning: recovery copy for AGENTS.md was retained"
            assert_includes stdout.b, manual_instructions("AGENTS.md", "agents_section.md.tt").b
            assert_includes summary_entries(stdout, "Needs a person"), "AGENTS.md"
          end
        end
      end
    end

    def test_rollback_claim_refuses_a_swapped_claim_and_retains_quarantine
      stale = <<~MARKDOWN.b
        # Notes

        <!-- quality_gate agent contract — start -->
        stale
        <!-- quality_gate agent contract — end -->
        after
      MARKDOWN

      with_before_publish_new_tempfile("AGENTS.md", lambda do |path|
        claim_path = Dir.glob(File.join(File.dirname(path), ".quality_gate-*.claim")).fetch(0)
        File.binwrite(claim_path, "# swapped quarantine content\n".b)
        File.chmod(0o640, claim_path)
        File.utime(Time.at(1_700_300_000), Time.at(1_700_300_000), claim_path)
        raise Errno::EIO, "simulated publish failure"
      end) do
        with_host do |host|
          write_context_file(host, "AGENTS.md", stale)

          stdout, stderr = run_generator(host)

          assert_empty stderr
          refute_path_exists File.join(host, "AGENTS.md")
          assert_predicate Dir.glob(File.join(host, ".quality_gate-*")), :any?
          assert_match(/recovery copy|quarantine/i, stdout)
          assert_includes summary_entries(stdout, "Needs a person"), "AGENTS.md"
        end
      end
    end

    def test_claim_fsync_failure_after_rename_restores_visible_file_and_reports_manual_action
      stale = <<~MARKDOWN.b
        # Notes

        <!-- quality_gate agent contract — start -->
        stale
        <!-- quality_gate agent contract — end -->
        after
      MARKDOWN

      with_directory_operation_failure(
        "AGENTS.md",
        :fsync,
        Errno::EIO.new("AGENTS.md"),
        predicate: lambda { |_event|
          remaining = Thread.current[:quality_gate_fail_claim_fsync].to_i
          if remaining.positive?
            Thread.current[:quality_gate_fail_claim_fsync] = remaining - 1
            true
          else
            false
          end
        }
      ) do
        with_after_claim_current_leaf("AGENTS.md", lambda do |_path|
          Thread.current[:quality_gate_fail_claim_fsync] = 1
        end) do
          with_host do |host|
            write_context_file(host, "AGENTS.md", stale)

            stdout, stderr = run_generator(host)

            assert_empty stderr
            assert_equal stale, File.binread(File.join(host, "AGENTS.md"))
            refute_predicate Dir.glob(File.join(host, ".quality_gate-*.claim")), :any?
            refute_temp_artifacts(host)
            assert_includes stdout.b, manual_instructions("AGENTS.md", "agents_section.md.tt").b
            assert_includes summary_entries(stdout, "Needs a person"), "AGENTS.md"
          ensure
            Thread.current[:quality_gate_fail_claim_fsync] = nil
          end
        end
      end
    end

    def test_quarantine_fsync_failure_reports_the_actual_retained_quarantine_path
      stale = <<~MARKDOWN.b
        # Notes

        <!-- quality_gate agent contract — start -->
        stale
        <!-- quality_gate agent contract — end -->
        after
      MARKDOWN

      with_directory_operation_failure(
        "AGENTS.md",
        :fsync,
        Errno::EIO.new("AGENTS.md"),
        predicate: lambda { |event|
          event[:phase] == :after_rename &&
            event[:source_name]&.end_with?(".claim") &&
            event[:destination_name]&.end_with?(".quarantine")
        }
      ) do
        with_before_publish_new_tempfile("AGENTS.md", lambda do |_path|
          raise Errno::EIO, "simulated publish failure"
        end) do
          with_host do |host|
            write_context_file(host, "AGENTS.md", stale)

            stdout, stderr = run_generator(host)

            assert_empty stderr
            refute_path_exists File.join(host, "AGENTS.md")
            claim_artifacts = Dir.glob(File.join(host, ".quality_gate-*.claim"))
            assert_empty claim_artifacts
            quarantine_artifacts = Dir.glob(File.join(host, ".quality_gate-*.quarantine"))
            assert_equal 1, quarantine_artifacts.length
            retained_name = File.basename(quarantine_artifacts.fetch(0))
            assert_equal stale, File.binread(quarantine_artifacts.fetch(0))
            assert_includes stdout, "retained as #{retained_name}"
            assert_includes summary_entries(stdout, "Needs a person"), "AGENTS.md"
          end
        end
      end
    end

    def test_successful_replacement_claim_cleanup_fsync_failure_retains_actual_quarantine_and_avoids_written
      stale = <<~MARKDOWN.b
        # Notes

        <!-- quality_gate agent contract — start -->
        stale
        <!-- quality_gate agent contract — end -->
        after
      MARKDOWN

      with_directory_operation_failure(
        "AGENTS.md",
        :fsync,
        Errno::EIO.new("AGENTS.md"),
        predicate: lambda { |event|
          event[:phase] == :after_rename &&
            event[:source_name]&.end_with?(".claim") &&
            event[:destination_name]&.end_with?(".quarantine")
        }
      ) do
        with_host do |host|
          write_context_file(host, "AGENTS.md", stale)
          expected = "# Notes\n\n#{expected_template("agents_section.md.tt")}after\n".b

          stdout, stderr = run_generator(host)

          assert_empty stderr
          assert_equal expected, File.binread(File.join(host, "AGENTS.md"))
          quarantine_artifacts = Dir.glob(File.join(host, ".quality_gate-*.quarantine"))
          assert_equal 1, quarantine_artifacts.length
          assert_equal stale, File.binread(quarantine_artifacts.fetch(0))
          assert_includes stdout, "retained as #{File.basename(quarantine_artifacts.fetch(0))}"
          refute_includes summary_entries(stdout, "Written"), "AGENTS.md"
          assert_includes summary_entries(stdout, "Needs a person"), "AGENTS.md"
        end
      end
    end

    def test_restore_fsync_failure_reports_the_actual_visible_path
      stale = <<~MARKDOWN.b
        # Notes

        <!-- quality_gate agent contract — start -->
        stale
        <!-- quality_gate agent contract — end -->
        after
      MARKDOWN

      with_directory_operation_failure(
        "AGENTS.md",
        :fsync,
        Errno::EIO.new("AGENTS.md"),
        predicate: lambda { |event|
          event[:phase] == :after_rename &&
            event[:source_name]&.end_with?(".quarantine") &&
            event[:destination_name] == "AGENTS.md"
        }
      ) do
        with_before_publish_new_tempfile("AGENTS.md", lambda do |_path|
          raise Errno::EIO, "simulated publish failure"
        end) do
          with_host do |host|
            write_context_file(host, "AGENTS.md", stale)

            stdout, stderr = run_generator(host)

            assert_empty stderr
            assert_equal stale, File.binread(File.join(host, "AGENTS.md"))
            assert_empty Dir.glob(File.join(host, ".quality_gate-*.quarantine"))
            assert_includes stdout, "retained as AGENTS.md"
            refute_match(/retained as .*\.quarantine\b/, stdout)
            assert_includes summary_entries(stdout, "Needs a person"), "AGENTS.md"
          end
        end
      end
    end

    def test_restore_claimed_current_leaf_fsync_failure_reports_the_actual_visible_path_and_avoids_written
      stale = <<~MARKDOWN.b
        # Notes

        <!-- quality_gate agent contract — start -->
        stale
        <!-- quality_gate agent contract — end -->
        after
      MARKDOWN
      mutated_claim = "# claim mutated after rename\n".b

      with_directory_operation_failure(
        "AGENTS.md",
        :fsync,
        Errno::EIO.new("AGENTS.md"),
        predicate: lambda { |event|
          event[:phase] == :after_rename &&
            event[:source_name]&.end_with?(".claim") &&
            event[:destination_name] == "AGENTS.md"
        }
      ) do
        with_after_claim_current_leaf("AGENTS.md", lambda do |path|
          claim_path = Dir.glob(File.join(File.dirname(path), ".quality_gate-*.claim")).fetch(0)
          File.binwrite(claim_path, mutated_claim)
          File.chmod(0o640, claim_path)
        end) do
          with_host do |host|
            write_context_file(host, "AGENTS.md", stale)

            stdout, stderr = run_generator(host)

            assert_empty stderr
            assert_equal mutated_claim, File.binread(File.join(host, "AGENTS.md"))
            assert_empty Dir.glob(File.join(host, ".quality_gate-*.claim"))
            assert_includes stdout, "retained as AGENTS.md"
            refute_includes summary_entries(stdout, "Written"), "AGENTS.md"
            assert_includes summary_entries(stdout, "Needs a person"), "AGENTS.md"
          end
        end
      end
    end

    def test_concurrent_context_path_swap_before_stale_replacement_preserves_the_swapped_file
      stale = <<~MARKDOWN.b
        # Notes

        <!-- quality_gate agent contract — start -->
        stale
        <!-- quality_gate agent contract — end -->
        after
      MARKDOWN

      with_before_replace_content("AGENTS.md", lambda do |path|
        File.delete(path)
        File.binwrite(path, "# Swapped in newer developer file.\n".b)
      end) do
        with_host do |host|
          write_context_file(host, "AGENTS.md", stale)

          stdout, stderr = run_generator(host)

          assert_empty stderr
          assert_equal "# Swapped in newer developer file.\n".b, File.binread(File.join(host, "AGENTS.md"))
          refute_temp_artifacts(host)
          assert_includes stdout.b, manual_instructions("AGENTS.md", "agents_section.md.tt").b
          assert_includes summary_entries(stdout, "Needs a person"), "AGENTS.md"
        end
      end
    end

    def test_new_hook_publish_rejects_a_symlink_swap_without_changing_the_external_target_mode
      with_before_record_template_postcondition(".claude/hooks/quality_gate_fast.rb", lambda do |path|
        external = "#{path}.external"
        File.binwrite(external, "# external target\n".b)
        File.chmod(0o600, external)
        File.delete(path)
        File.symlink(external, path)
      end) do
        with_host do |host|
          hook_path = File.join(host, ".claude/hooks/quality_gate_fast.rb")

          stdout, stderr = run_generator(host)

          assert_empty stderr
          assert_predicate File.lstat(hook_path), :symlink?
          assert_equal 0o600, File.stat("#{hook_path}.external").mode & 0o777
          refute_temp_artifacts(host)
          assert_includes stdout.b,
                          manual_instructions(".claude/hooks/quality_gate_fast.rb", "quality_gate_fast.rb.tt").b
          assert_includes summary_entries(stdout, "Needs a person"), ".claude/hooks/quality_gate_fast.rb"
        end
      end
    end

    def test_missing_claude_directory_swap_before_temp_create_reports_manual_and_leaves_external_untouched
      external = nil

      with_before_prepared_tempfile(".claude/hooks/quality_gate_fast.rb", lambda do |path|
        root = File.dirname(File.dirname(path))
        external = File.join(File.dirname(root), "external-claude")
        FileUtils.mkdir_p(external)
        File.symlink(external, root)
      end) do
        with_host do |host|
          hook_path = File.join(host, ".claude/hooks/quality_gate_fast.rb")

          stdout, stderr = run_generator(host)

          assert_empty stderr
          assert_predicate File.lstat(File.join(host, ".claude")), :symlink?
          refute_path_exists hook_path
          refute_path_exists File.join(external, "hooks/quality_gate_fast.rb")
          assert_empty(
            Dir.glob(File.join(external, "**/*"), File::FNM_DOTMATCH) - [external, "#{external}/.", "#{external}/.."]
          )
          assert_includes stdout.b,
                          manual_instructions(".claude/hooks/quality_gate_fast.rb", "quality_gate_fast.rb.tt").b
          assert_includes summary_entries(stdout, "Needs a person"), ".claude/hooks/quality_gate_fast.rb"
        end
      end
    end

    def test_parent_directory_swap_after_temp_create_stays_in_original_inode_and_reports_manual_action
      displaced_hooks = nil
      external = nil

      with_before_publish_new_tempfile(".claude/hooks/quality_gate_fast.rb", lambda do |path|
        hooks_dir = File.dirname(path)
        displaced_hooks = "#{hooks_dir}.moved"
        external = File.join(File.dirname(File.dirname(hooks_dir)), "external-hooks")
        FileUtils.mkdir_p(external)
        File.rename(hooks_dir, displaced_hooks)
        File.symlink(external, hooks_dir)
      end) do
        with_host do |host|
          hook_path = File.join(host, ".claude/hooks/quality_gate_fast.rb")

          stdout, stderr = run_generator(host)

          assert_empty stderr
          assert_predicate File.lstat(File.dirname(hook_path)), :symlink?
          refute_path_exists hook_path
          refute_path_exists File.join(external, "quality_gate_fast.rb")
          refute Dir.glob(File.join(displaced_hooks, ".quality_gate-*")).any?
          assert_includes stdout.b,
                          manual_instructions(".claude/hooks/quality_gate_fast.rb", "quality_gate_fast.rb.tt").b
          assert_includes summary_entries(stdout, "Needs a person"), ".claude/hooks/quality_gate_fast.rb"
        end
      end
    end

    def test_post_publish_parent_swap_cleans_the_displaced_hook_leaf_and_preserves_visible_topology
      displaced_hooks = nil
      external = nil

      with_after_publish_new_tempfile(".claude/hooks/quality_gate_fast.rb", lambda do |path|
        hooks_dir = File.dirname(path)
        displaced_hooks = "#{hooks_dir}.moved"
        external = File.join(File.dirname(File.dirname(hooks_dir)), "external-hooks-after-publish")
        FileUtils.mkdir_p(external)
        File.rename(hooks_dir, displaced_hooks)
        File.symlink(external, hooks_dir)
      end) do
        with_host do |host|
          hook_path = File.join(host, ".claude/hooks/quality_gate_fast.rb")

          stdout, stderr = run_generator(host)

          assert_empty stderr
          assert_predicate File.lstat(File.dirname(hook_path)), :symlink?
          refute_path_exists hook_path
          refute_path_exists File.join(external, "quality_gate_fast.rb")
          refute_path_exists File.join(displaced_hooks, "quality_gate_fast.rb")
          assert_includes stdout.b,
                          manual_instructions(".claude/hooks/quality_gate_fast.rb", "quality_gate_fast.rb.tt").b
          assert_includes summary_entries(stdout, "Needs a person"), ".claude/hooks/quality_gate_fast.rb"
        end
      end
    end

    def test_visible_parent_identity_mismatch_rejects_a_real_directory_swap_even_when_visible_bytes_match
      displaced_hooks = nil

      with_after_publish_new_tempfile(".claude/hooks/quality_gate_fast.rb", lambda do |path|
        hooks_dir = File.dirname(path)
        displaced_hooks = "#{hooks_dir}.moved"
        replacement_hooks = "#{hooks_dir}.replacement"
        FileUtils.mkdir_p(replacement_hooks)
        replacement_path = File.join(replacement_hooks, "quality_gate_fast.rb")
        File.binwrite(replacement_path, expected_template("quality_gate_fast.rb.tt"))
        File.chmod(0o755, replacement_path)
        File.rename(hooks_dir, displaced_hooks)
        File.rename(replacement_hooks, hooks_dir)
      end) do
        with_host do |host|
          hook_path = File.join(host, ".claude/hooks/quality_gate_fast.rb")

          stdout, stderr = run_generator(host)

          assert_empty stderr
          assert_equal expected_template("quality_gate_fast.rb.tt"), File.binread(hook_path)
          refute_path_exists File.join(displaced_hooks, "quality_gate_fast.rb")
          assert_includes stdout.b,
                          manual_instructions(".claude/hooks/quality_gate_fast.rb", "quality_gate_fast.rb.tt").b
          assert_includes summary_entries(stdout, "Needs a person"), ".claude/hooks/quality_gate_fast.rb"
        end
      end
    end

    def test_exact_nonexec_hook_repair_rejects_a_symlink_swap_without_changing_the_external_target_mode
      with_before_record_existing_template(".claude/hooks/quality_gate_fast.rb", lambda do |path|
        original = File.binread(path)
        external = "#{path}.external"
        File.binwrite(external, original)
        File.chmod(0o600, external)
        File.delete(path)
        File.symlink(external, path)
      end) do
        with_host do |host|
          hook_path = File.join(host, ".claude/hooks/quality_gate_fast.rb")
          FileUtils.mkdir_p(File.dirname(hook_path))
          File.binwrite(hook_path, expected_template("quality_gate_fast.rb.tt"))
          File.chmod(0o644, hook_path)

          stdout, stderr = run_generator(host)

          assert_empty stderr
          assert_predicate File.lstat(hook_path), :symlink?
          assert_equal 0o600, File.stat("#{hook_path}.external").mode & 0o777
          assert_includes stdout.b,
                          manual_instructions(".claude/hooks/quality_gate_fast.rb", "quality_gate_fast.rb.tt").b
          assert_includes summary_entries(stdout, "Needs a person"), ".claude/hooks/quality_gate_fast.rb"
        end
      end
    end

    def test_new_settings_partial_write_failure_leaves_no_partial_destination
      with_create_file_partial_failure(".claude/settings.json", "{\n".b) do
        with_host do |host|
          settings_path = File.join(host, ".claude/settings.json")

          stdout, stderr = run_generator(host)

          assert_empty stderr
          refute_path_exists settings_path
          refute_temp_artifacts(host)
          assert_includes stdout.b, manual_instructions(".claude/settings.json", "claude_settings.json.tt").b
          assert_includes summary_entries(stdout, "Needs a person"), ".claude/settings.json"
        end
      end
    end

    def test_temp_cleanup_does_not_unlink_a_replaced_temp_entry
      with_create_file_partial_failure(".claude/settings.json", "{\n".b) do
        with_before_cleanup_unlink(".claude/settings.json", :temp, lambda do |entry_path|
          File.binwrite(entry_path, "# developer temp survives\n".b)
          File.chmod(0o600, entry_path)
        end) do
          with_host do |host|
            stdout, stderr = run_generator(host)

            assert_empty stderr
            refute_path_exists File.join(host, ".claude/settings.json")
            temp_artifacts = Dir.glob(File.join(host, ".claude/.quality_gate-*.tmp"))
            assert_predicate temp_artifacts, :any?
            assert_equal "# developer temp survives\n".b, File.binread(temp_artifacts.fetch(0))
            assert_includes summary_entries(stdout, "Needs a person"), ".claude/settings.json"
          end
        end
      end
    end

    def test_claim_cleanup_does_not_unlink_a_replaced_claim_entry
      stale = <<~MARKDOWN.b
        # Notes

        <!-- quality_gate agent contract — start -->
        stale
        <!-- quality_gate agent contract — end -->
        after
      MARKDOWN

      with_before_cleanup_unlink("AGENTS.md", :claim, lambda do |entry_path|
        File.binwrite(entry_path, "# developer claim survives\n".b)
        File.chmod(0o600, entry_path)
      end) do
        with_host do |host|
          write_context_file(host, "AGENTS.md", stale)
          expected = "# Notes\n\n#{expected_template("agents_section.md.tt")}after\n".b

          _stdout, stderr = run_generator(host)

          assert_empty stderr
          assert_equal expected, File.binread(File.join(host, "AGENTS.md"))
          claim_artifacts = Dir.glob(File.join(host, ".quality_gate-*.claim"))
          assert_predicate claim_artifacts, :any?
          assert_equal "# developer claim survives\n".b, File.binread(claim_artifacts.fetch(0))
        end
      end
    end

    def test_claim_cleanup_state_mismatch_retains_the_mutated_claim_and_avoids_written
      stale = <<~MARKDOWN.b
        # Notes

        <!-- quality_gate agent contract — start -->
        stale
        <!-- quality_gate agent contract — end -->
        after
      MARKDOWN

      with_after_publish_new_tempfile("AGENTS.md", lambda do |path|
        claim_path = Dir.glob(File.join(File.dirname(path), ".quality_gate-*.claim")).fetch(0)
        File.open(claim_path, File::RDWR) do |claim|
          claim.binmode
          claim.rewind
          claim.write("# developer claim mutated\n".b)
          claim.flush
          claim.truncate(claim.pos)
        end
      end) do
        with_host do |host|
          write_context_file(host, "AGENTS.md", stale)
          expected = "# Notes\n\n#{expected_template("agents_section.md.tt")}after\n".b

          stdout, stderr = run_generator(host)

          assert_empty stderr
          assert_equal expected, File.binread(File.join(host, "AGENTS.md"))
          claim_artifacts = Dir.glob(File.join(host, ".quality_gate-*.claim"))
          assert_predicate claim_artifacts, :any?
          assert_equal "# developer claim mutated\n".b, File.binread(claim_artifacts.fetch(0))
          assert_includes summary_entries(stdout, "Needs a person"), "AGENTS.md"
          refute_includes summary_entries(stdout, "Written"), "AGENTS.md"
          assert_equal 1, summary_entries(stdout, "Needs a person").count("AGENTS.md")
        end
      end
    end

    def test_published_leaf_cleanup_does_not_unlink_a_replaced_visible_entry
      displaced_hooks = nil

      with_after_publish_new_tempfile(".claude/hooks/quality_gate_fast.rb", lambda do |path|
        hooks_dir = File.dirname(path)
        displaced_hooks = "#{hooks_dir}.moved"
        File.rename(hooks_dir, displaced_hooks)
        FileUtils.mkdir_p(hooks_dir)
      end) do
        with_before_cleanup_unlink(".claude/hooks/quality_gate_fast.rb", :published, lambda do |entry_path|
          File.binwrite(entry_path, "# developer hook survives\n".b)
          File.chmod(0o755, entry_path)
        end) do
          with_host do |host|
            hook_path = File.join(host, ".claude/hooks/quality_gate_fast.rb")

            stdout, stderr = run_generator(host)

            assert_empty stderr
            assert_path_exists hook_path
            assert_equal "# developer hook survives\n".b, File.binread(hook_path)
            refute_path_exists File.join(displaced_hooks, "quality_gate_fast.rb")
            assert_includes summary_entries(stdout, "Needs a person"), ".claude/hooks/quality_gate_fast.rb"
          end
        end
      end
    end

    def test_publish_verification_rejects_a_visible_replacement_before_status_capture
      with_before_verify_published_leaf(".claude/hooks/quality_gate_fast.rb", lambda do |path|
        File.delete(path)
        File.binwrite(path, "# developer replacement\n".b)
        File.chmod(0o755, path)
      end) do
        with_host do |host|
          hook_path = File.join(host, ".claude/hooks/quality_gate_fast.rb")

          stdout, stderr = run_generator(host)

          assert_empty stderr
          assert_equal "# developer replacement\n".b, File.binread(hook_path)
          assert_includes stdout.b,
                          manual_instructions(".claude/hooks/quality_gate_fast.rb", "quality_gate_fast.rb.tt").b
          assert_includes summary_entries(stdout, "Needs a person"), ".claude/hooks/quality_gate_fast.rb"
          refute_includes summary_entries(stdout, "Written"), ".claude/hooks/quality_gate_fast.rb"
        end
      end
    end

    def test_published_leaf_cleanup_preserves_in_place_developer_edits
      with_directory_operation_failure(
        ".claude/hooks/quality_gate_fast.rb",
        :fsync,
        Errno::EIO.new(".claude/hooks/quality_gate_fast.rb"),
        predicate: ->(event) { event[:phase] == :after_link }
      ) do
        with_before_cleanup_unlink(".claude/hooks/quality_gate_fast.rb", :published, lambda do |entry_path|
          File.binwrite(entry_path, "# developer mutated in place\n".b)
          File.chmod(0o755, entry_path)
        end) do
          with_host do |host|
            hook_path = File.join(host, ".claude/hooks/quality_gate_fast.rb")

            stdout, stderr = run_generator(host)

            assert_empty stderr
            assert_equal "# developer mutated in place\n".b, File.binread(hook_path)
            assert_includes stdout.b,
                            manual_instructions(".claude/hooks/quality_gate_fast.rb", "quality_gate_fast.rb.tt").b
            assert_includes summary_entries(stdout, "Needs a person"), ".claude/hooks/quality_gate_fast.rb"
            refute_includes summary_entries(stdout, "Written"), ".claude/hooks/quality_gate_fast.rb"
          end
        end
      end
    end

    def test_post_link_metadata_failure_reconciles_without_leaving_a_visible_settings_file
      with_directory_operation_failure(
        ".claude/settings.json",
        :open_file,
        Errno::EIO.new(".claude/settings.json"),
        predicate: ->(event) { event[:phase] == :after_link && event[:entry_name] == "settings.json" }
      ) do
        with_host do |host|
          settings_path = File.join(host, ".claude/settings.json")

          stdout, stderr = run_generator(host)

          assert_empty stderr
          refute_path_exists settings_path
          refute_temp_artifacts(host)
          assert_includes stdout.b, manual_instructions(".claude/settings.json", "claude_settings.json.tt").b
          assert_includes summary_entries(stdout, "Needs a person"), ".claude/settings.json"
          refute_includes summary_entries(stdout, "Written"), ".claude/settings.json"
        end
      end
    end

    def test_new_context_destination_appearing_during_create_is_not_clobbered
      with_before_create_file_write("CLAUDE.md", lambda do |path|
        File.binwrite(path, "# Developer arrived first.\n".b)
        File.chmod(0o640, path)
      end) do
        with_host do |host|
          stdout, stderr = run_generator(host)

          assert_empty stderr
          assert_equal "# Developer arrived first.\n".b, File.binread(File.join(host, "CLAUDE.md"))
          refute_temp_artifacts(host)
          assert_includes stdout.b, manual_instructions("CLAUDE.md", "agents_section.md.tt").b
          assert_includes summary_entries(stdout, "Needs a person"), "CLAUDE.md"
        end
      end
    end

    def test_unsupported_directory_operations_report_manual_and_continue
      with_inside_anchored_directory(".claude/settings.json", lambda do
        raise NotImplementedError, "openat unavailable"
      end) do
        with_host do |host|
          stdout, stderr = run_generator(host)

          assert_empty stderr
          refute_path_exists File.join(host, ".claude/settings.json")
          assert_includes stdout.b, manual_instructions(".claude/settings.json", "claude_settings.json.tt").b
          assert_includes summary_entries(stdout, "Needs a person"), ".claude/settings.json"
          assert_includes summary_entries(stdout, "Written"), ".claude/hooks/quality_gate_fast.rb"
          assert_includes summary_entries(stdout, "Written"), "CLAUDE.md"
          assert_includes summary_entries(stdout, "Written"), "AGENTS.md"
        end
      end
    end

    def test_fifo_cleanup_metadata_probe_completes_without_blocking
      with_host do |host|
        result = run_in_child(timeout_seconds: 3) do |writer|
          with_create_file_partial_failure(".claude/settings.json", "{\n".b) do
            with_before_temp_cleanup(".claude/settings.json", lambda do |entry_path|
              File.delete(entry_path)
              system("mkfifo", entry_path, exception: true)
            end) do
              stdout, stderr = run_generator(host)
              Marshal.dump({ stdout:, stderr: }, writer)
            end
          end
        end

        assert_empty result.fetch(:stderr)
        assert_includes summary_entries(result.fetch(:stdout), "Needs a person"), ".claude/settings.json"
      end
    end

    def test_concurrent_relative_io_never_observes_a_cwd_change
      observed = Queue.new
      trigger = Queue.new
      observer = Thread.new do
        trigger.pop
        observed << Dir.pwd
      end

      Dir.mktmpdir("quality-gate-stable-cwd") do |stable_cwd|
        Dir.chdir(stable_cwd) do
          with_inside_anchored_directory(".claude/settings.json", lambda do
            trigger << true
            observer.join
          end) do
            with_host do |host|
              stdout, stderr = run_generator(host)

              assert_empty stderr, generator_diagnostic(stdout, stderr)
              assert_includes summary_entries(stdout, "Written"), ".claude/settings.json",
                              generator_diagnostic(stdout, stderr)
            end
          end
        end

        assert(
          File.identical?(stable_cwd, observed.pop),
          "expected generator work to leave cwd at #{stable_cwd.inspect}"
        )
      end
    ensure
      trigger&.close
      observer&.join
    end

    def test_initial_temp_fchmod_failure_cleans_up_owned_entries
      with_directory_operation_failure(
        ".claude/settings.json",
        :fchmod,
        Errno::EIO.new(".claude/settings.json"),
        predicate: ->(event) { event.fetch(:mode) == 0o600 }
      ) do
        with_host do |host|
          settings_path = File.join(host, ".claude/settings.json")

          stdout, stderr = run_generator(host)

          assert_empty stderr
          refute_path_exists settings_path
          refute_temp_artifacts(host)
          assert_includes stdout.b, manual_instructions(".claude/settings.json", "claude_settings.json.tt").b
          assert_includes summary_entries(stdout, "Needs a person"), ".claude/settings.json"
        end
      end
    end

    def test_tempfile_stat_failure_closes_the_fd_and_cleans_owned_temp_without_manual_status
      prepared = {}

      with_prepared_tempfile_callback(".claude/settings.json", lambda do |tempfile|
        prepared[:file] = tempfile.file
        stat_calls = 0
        tempfile.file.singleton_class.prepend(
          Module.new do
            define_method(:stat) do
              stat_calls += 1
              return super() if stat_calls == 1

              raise Errno::EIO, ".claude/settings.json"
            end
          end
        )
      end) do
        with_host do |host|
          stdout, stderr = run_generator(host)

          assert_empty stderr
          assert prepared.fetch(:file).closed?
          assert_equal expected_template("claude_settings.json.tt"), read(host, ".claude/settings.json")
          refute_temp_artifacts(host)
          assert_includes summary_entries(stdout, "Written"), ".claude/settings.json"
          refute_includes summary_entries(stdout, "Needs a person"), ".claude/settings.json"
        end
      end
    end

    def test_tempfile_stat_failure_with_cleanup_failure_reports_one_manual_status_without_written
      with_prepared_tempfile_callback(".claude/settings.json", lambda do |tempfile|
        stat_calls = 0
        tempfile.file.singleton_class.prepend(
          Module.new do
            define_method(:stat) do
              stat_calls += 1
              return super() if stat_calls == 1

              raise Errno::EIO, ".claude/settings.json"
            end
          end
        )
      end) do
        with_directory_operation_failure(
          ".claude/settings.json",
          :rename_noreplace,
          Errno::EIO.new(".claude/settings.json"),
          predicate: ->(_event) { Thread.current[:quality_gate_fail_temp_cleanup] }
        ) do
          with_before_temp_cleanup(".claude/settings.json", lambda do |_path|
            Thread.current[:quality_gate_fail_temp_cleanup] = true
          end) do
            with_host do |host|
              stdout, stderr = run_generator(host)

              assert_empty stderr
              assert_equal expected_template("claude_settings.json.tt"), read(host, ".claude/settings.json")
              assert_predicate Dir.glob(File.join(host, ".claude/.quality_gate-*")), :any?
              refute_includes summary_entries(stdout, "Written"), ".claude/settings.json"
              assert_includes summary_entries(stdout, "Needs a person"), ".claude/settings.json"
              settings_manual = manual_instructions(".claude/settings.json", "claude_settings.json.tt")
              assert_equal 1, stdout.scan(settings_manual).length
            ensure
              Thread.current[:quality_gate_fail_temp_cleanup] = nil
            end
          end
        end
      end
    end

    def test_post_link_fsync_failure_rolls_back_the_published_leaf
      with_directory_operation_failure(
        ".claude/settings.json",
        :fsync,
        Errno::EIO.new(".claude/settings.json"),
        predicate: ->(event) { event[:phase] == :after_link }
      ) do
        with_host do |host|
          settings_path = File.join(host, ".claude/settings.json")

          stdout, stderr = run_generator(host)

          assert_empty stderr
          refute_path_exists settings_path
          refute_temp_artifacts(host)
          assert_includes stdout.b, manual_instructions(".claude/settings.json", "claude_settings.json.tt").b
          assert_includes summary_entries(stdout, "Needs a person"), ".claude/settings.json"
        end
      end
    end

    def test_temp_publication_fsyncs_after_final_mode_before_linking
      with_host do |host|
        log = capture_directory_operation_log do
          stdout, stderr = run_generator(host)
          assert_empty stderr
          assert_includes summary_entries(stdout, "Written"), ".claude/settings.json"
        end

        filtered = operation_names_for(log, ".claude/settings.json", only: %i[fchmod fsync link])
        assert_operation_subsequence %i[fchmod fsync fchmod fsync link], filtered
      end
    end

    def test_openat_uses_close_on_exec_safe_descriptors_for_directory_and_tempfile
      observed = {}

      with_anchored_directory_context(".claude/settings.json", lambda do |context|
        observed[:directory_close_on_exec] = context.fetch(:directory_io).close_on_exec?
      end) do
        with_prepared_tempfile_callback(".claude/settings.json", lambda do |tempfile|
          observed[:tempfile_close_on_exec] = tempfile.file.close_on_exec?
        end) do
          with_host do |host|
            log = capture_directory_operation_log do
              stdout, stderr = run_generator(host)
              assert_empty stderr
              assert_includes summary_entries(stdout, "Written"), ".claude/settings.json"
            end

            if File.const_defined?(:CLOEXEC)
              cloexec = File.const_get(:CLOEXEC)
              settings_open_calls = log.select do
                _1[:relative_path] == ".claude/settings.json" && _1[:operation] == :open_file
              end
              flags = settings_open_calls.map { _1[:flags] }
              assert flags.all? { (_1 & cloexec) == cloexec }, "expected O_CLOEXEC on all openat calls"
            end
          end
        end
      end

      assert_equal true, observed[:directory_close_on_exec]
      assert_equal true, observed[:tempfile_close_on_exec]
    end

    def test_overlapping_bundled_fiddle_require_restores_kernel_require_and_verbose
      skip unless RUBY_VERSION.start_with?("4.") && defined?(Bundler)

      original_require = Kernel.instance_method(:require)
      original_verbose = $VERBOSE
      entered = Queue.new
      release = Queue.new
      operations = InstallGenerator.const_get(:DirectoryOperations, false)

      workers = Array.new(2) do
        Thread.new do
          operations.send(:with_bundled_fiddle_require) do
            entered << true
            release.pop
          end
        end
      end

      entered.pop
      release << true
      entered.pop
      release << true
      workers.each(&:join)

      restored_require = Kernel.instance_method(:require)
      assert_equal original_require.owner, restored_require.owner
      assert_equal original_require.source_location, restored_require.source_location
      assert_equal original_verbose, $VERBOSE
    ensure
      $VERBOSE = original_verbose
    end

    def test_bundled_fiddle_feature_discovery_failure_restores_false_verbose_and_require
      skip unless RUBY_VERSION.start_with?("4.") && defined?(Bundler)

      operations = InstallGenerator.const_get(:DirectoryOperations, false)
      singleton = operations.singleton_class
      original_require = Kernel.instance_method(:require)
      original_verbose = $VERBOSE
      original_method = singleton.instance_method(:fiddle_feature_paths)
      $VERBOSE = false

      singleton.define_method(:fiddle_feature_paths) do
        raise InstallGenerator.const_get(:DirectoryOperations, false)::Unsupported, "fiddle support is unavailable"
      end

      error = assert_raises(InstallGenerator.const_get(:DirectoryOperations, false)::Unsupported) do
        operations.send(:with_bundled_fiddle_require) { flunk("unexpected yield") }
      end

      assert_equal "fiddle support is unavailable", error.message
      assert_equal false, $VERBOSE
      restored_require = Kernel.instance_method(:require)
      assert_equal original_require.owner, restored_require.owner
      assert_equal original_require.source_location, restored_require.source_location
    ensure
      singleton.define_method(:fiddle_feature_paths, original_method) if original_method
      $VERBOSE = original_verbose
    end

    def test_unsupported_claim_acquisition_does_not_report_a_fake_recovery_copy
      stale = <<~MARKDOWN.b
        # Notes

        <!-- quality_gate agent contract — start -->
        stale
        <!-- quality_gate agent contract — end -->
        after
      MARKDOWN

      with_directory_operation_failure(
        "AGENTS.md",
        :rename_noreplace,
        InstallGenerator.const_get(:DirectoryOperations, false)::Unsupported.new("exclusive rename unavailable"),
        predicate: ->(event) { event[:source_name] == "AGENTS.md" }
      ) do
        with_host do |host|
          write_context_file(host, "AGENTS.md", stale)
          before = snapshot_for(host, ["AGENTS.md"])

          stdout, stderr = run_generator(host)

          assert_empty stderr
          assert_equal before, snapshot_for(host, ["AGENTS.md"])
          refute_match(/recovery copy for AGENTS\.md/i, stdout)
          refute_predicate Dir.glob(File.join(host, ".quality_gate-*.claim")), :any?
          assert_includes stdout.b, manual_instructions("AGENTS.md", "agents_section.md.tt").b
          assert_includes summary_entries(stdout, "Needs a person"), "AGENTS.md"
        end
      end
    end

    def test_agent_artifact_read_failures_report_manual_actions_and_continue
      with_compare_existing_failure(".claude/hooks/quality_gate_fast.rb") do
        with_compare_existing_failure(".claude/settings.json") do
          with_update_agent_contract_failure("CLAUDE.md") do
            with_host do |host|
              hook_path = File.join(host, ".claude/hooks/quality_gate_fast.rb")
              settings_path = File.join(host, ".claude/settings.json")
              FileUtils.mkdir_p(File.dirname(hook_path))
              File.binwrite(hook_path, expected_template("quality_gate_fast.rb.tt"))
              File.binwrite(settings_path, expected_template("claude_settings.json.tt"))
              write_context_file(host, "CLAUDE.md", expected_template("agents_section.md.tt"))

              stdout, stderr = run_generator(host)

              assert_empty stderr
              assert_includes stdout.b,
                              manual_instructions(".claude/hooks/quality_gate_fast.rb", "quality_gate_fast.rb.tt").b
              assert_includes stdout.b, manual_instructions(".claude/settings.json", "claude_settings.json.tt").b
              assert_includes stdout.b, manual_instructions("CLAUDE.md", "agents_section.md.tt").b
              assert_includes summary_entries(stdout, "Needs a person"), ".claude/hooks/quality_gate_fast.rb"
              assert_includes summary_entries(stdout, "Needs a person"), ".claude/settings.json"
              assert_includes summary_entries(stdout, "Needs a person"), "CLAUDE.md"
              assert_includes summary_entries(stdout, "Written"), "AGENTS.md"
            end
          end
        end
      end
    end

    def test_existing_agent_reads_reject_regular_replacements_before_descriptor_read
      {
        ".claude/hooks/quality_gate_fast.rb" => "quality_gate_fast.rb.tt",
        ".claude/hooks/quality_gate_verify_stop.rb" => "quality_gate_verify_stop.rb.tt",
        ".claude/settings.json" => "claude_settings.json.tt",
        "CLAUDE.md" => "agents_section.md.tt"
      }.each do |relative_path, template_name|
        with_before_read_existing_agent_artifact(relative_path, lambda do |path|
          File.delete(path)
          File.binwrite(path, "# developer replacement\n".b)
          File.chmod(0o640, path)
        end) do
          with_host do |host|
            write_existing_agent_fixture(host, relative_path, template_name)

            stdout, stderr = run_generator(host)

            assert_empty stderr, relative_path
            assert_equal "# developer replacement\n".b, File.binread(File.join(host, relative_path)), relative_path
            assert_includes stdout.b, manual_instructions(relative_path, template_name).b
            assert_includes summary_entries(stdout, "Needs a person"), relative_path
            refute_includes summary_entries(stdout, "Unchanged"), relative_path
            refute_includes summary_entries(stdout, "Written"), relative_path
          end
        end
      end
    end

    def test_existing_agent_reads_reject_symlink_swaps_before_descriptor_read
      {
        ".claude/hooks/quality_gate_fast.rb" => "quality_gate_fast.rb.tt",
        ".claude/hooks/quality_gate_verify_stop.rb" => "quality_gate_verify_stop.rb.tt",
        ".claude/settings.json" => "claude_settings.json.tt",
        "AGENTS.md" => "agents_section.md.tt"
      }.each do |relative_path, template_name|
        with_before_read_existing_agent_artifact(relative_path, lambda do |path|
          external = "#{path}.external"
          File.binwrite(external, "# external target\n".b)
          File.chmod(0o600, external)
          File.delete(path)
          File.symlink(external, path)
        end) do
          with_host do |host|
            write_existing_agent_fixture(host, relative_path, template_name)

            stdout, stderr = run_generator(host)

            assert_empty stderr, relative_path
            swapped = File.join(host, relative_path)
            assert_predicate File.lstat(swapped), :symlink?, relative_path
            assert_equal "# external target\n".b, File.binread("#{swapped}.external"), relative_path
            assert_includes stdout.b, manual_instructions(relative_path, template_name).b
            assert_includes summary_entries(stdout, "Needs a person"), relative_path
            refute_includes summary_entries(stdout, "Unchanged"), relative_path
            refute_includes summary_entries(stdout, "Written"), relative_path
          end
        end
      end
    end

    def test_existing_agent_reads_reject_fifo_swaps_without_blocking
      {
        ".claude/hooks/quality_gate_fast.rb" => "quality_gate_fast.rb.tt",
        ".claude/hooks/quality_gate_verify_stop.rb" => "quality_gate_verify_stop.rb.tt",
        ".claude/settings.json" => "claude_settings.json.tt",
        "CLAUDE.md" => "agents_section.md.tt"
      }.each do |relative_path, template_name|
        with_host do |host|
          result = run_in_child(timeout_seconds: 3) do |writer|
            write_existing_agent_fixture(host, relative_path, template_name)

            with_before_read_existing_agent_artifact(relative_path, lambda do |path|
              File.delete(path)
              system("mkfifo", path, exception: true)
            end) do
              stdout, stderr = run_generator(host)
              Marshal.dump({ stdout:, stderr:, relative_path: }, writer)
            end
          end

          assert_empty result.fetch(:stderr), relative_path
          swapped = File.join(host, relative_path)
          assert_predicate File.lstat(swapped), :pipe?, relative_path
          assert_includes result.fetch(:stdout).b, manual_instructions(relative_path, template_name).b
          assert_includes summary_entries(result.fetch(:stdout), "Needs a person"), relative_path
          refute_includes summary_entries(result.fetch(:stdout), "Unchanged"), relative_path
          refute_includes summary_entries(result.fetch(:stdout), "Written"), relative_path
        end
      end
    end

    def test_existing_agent_reads_reject_visible_leaf_swaps_after_read_and_before_final_validation
      {
        ".claude/hooks/quality_gate_fast.rb" => ["quality_gate_fast.rb.tt", 0o755],
        ".claude/hooks/quality_gate_verify_stop.rb" => ["quality_gate_verify_stop.rb.tt", 0o755],
        ".claude/settings.json" => ["claude_settings.json.tt", 0o640],
        "CLAUDE.md" => ["agents_section.md.tt", 0o640]
      }.each do |relative_path, (template_name, mode)|
        with_before_finalize_existing_agent_artifact(relative_path, lambda do |path|
          File.delete(path)
          File.binwrite(path, "# visible developer replacement\n".b)
          File.chmod(mode, path)
        end) do
          with_host do |host|
            write_existing_agent_fixture(host, relative_path, template_name)

            stdout, stderr = run_generator(host)
            current_path = File.join(host, relative_path)

            assert_empty stderr, relative_path
            assert_equal "# visible developer replacement\n".b, File.binread(current_path), relative_path
            assert_includes stdout.b, manual_instructions(relative_path, template_name).b
            assert_includes summary_entries(stdout, "Needs a person"), relative_path
            refute_includes summary_entries(stdout, "Unchanged"), relative_path
            refute_includes summary_entries(stdout, "Written"), relative_path
          end
        end
      end
    end

    def test_existing_agent_reads_reject_real_parent_swaps_after_read_and_before_final_validation
      {
        ".claude/hooks/quality_gate_fast.rb" => ["quality_gate_fast.rb.tt", 0o755],
        ".claude/hooks/quality_gate_verify_stop.rb" => ["quality_gate_verify_stop.rb.tt", 0o755],
        ".claude/settings.json" => ["claude_settings.json.tt", 0o640],
        "CLAUDE.md" => ["agents_section.md.tt", 0o640]
      }.each do |relative_path, (template_name, mode)|
        displaced_parent = nil

        with_before_finalize_existing_agent_artifact(relative_path, lambda do |path|
          parent_path = File.dirname(path)
          leaf_path = File.join(parent_path, File.basename(path))
          displaced_parent = "#{parent_path}.moved"
          File.rename(parent_path, displaced_parent)
          FileUtils.mkdir_p(parent_path)
          File.binwrite(leaf_path, "# visible developer replacement\n".b)
          File.chmod(mode, leaf_path)
        end) do
          with_host do |host|
            write_existing_agent_fixture(host, relative_path, template_name)

            stdout, stderr = run_generator(host)
            current_path = File.join(host, relative_path)
            displaced_leaf = File.join(displaced_parent, File.basename(relative_path))

            assert_empty stderr, relative_path
            assert_equal "# visible developer replacement\n".b, File.binread(current_path), relative_path
            assert_equal expected_template(template_name), File.binread(displaced_leaf)
            assert_includes stdout.b, manual_instructions(relative_path, template_name).b
            assert_includes summary_entries(stdout, "Needs a person"), relative_path
            refute_includes summary_entries(stdout, "Unchanged"), relative_path
            refute_includes summary_entries(stdout, "Written"), relative_path
          end
        end
      end
    end

    def test_agent_artifact_postcondition_failures_report_manual_actions_and_continue
      with_postcondition_failure(".claude/settings.json") do
        with_postcondition_failure("AGENTS.md") do
          with_host do |host|
            write_context_file(host, "AGENTS.md", "# Notes\n".b)

            stdout, stderr = run_generator(host)

            assert_empty stderr
            assert_includes stdout.b, manual_instructions(".claude/settings.json", "claude_settings.json.tt").b
            assert_includes stdout.b, manual_instructions("AGENTS.md", "agents_section.md.tt").b
            assert_includes summary_entries(stdout, "Needs a person"), ".claude/settings.json"
            assert_includes summary_entries(stdout, "Needs a person"), "AGENTS.md"
            assert_includes summary_entries(stdout, "Written"), ".claude/hooks/quality_gate_fast.rb"
          end
        end
      end
    end

    def test_agent_artifact_postcondition_mismatches_print_manual_actions_and_continue
      with_before_record_template_postcondition(".claude/hooks/quality_gate_fast.rb", lambda do |path|
        File.chmod(0o644, path)
      end) do
        with_before_record_template_postcondition(".claude/settings.json", lambda do |path|
          File.binwrite(path, "{}\n".b)
        end) do
          with_before_record_template_postcondition("CLAUDE.md", lambda do |path|
            File.binwrite(path, "# Changed after publish.\n".b)
          end) do
            with_host do |host|
              stdout, stderr = run_generator(host)

              assert_empty stderr
              assert_includes stdout.b,
                              manual_instructions(".claude/hooks/quality_gate_fast.rb", "quality_gate_fast.rb.tt").b
              assert_includes stdout.b, manual_instructions(".claude/settings.json", "claude_settings.json.tt").b
              assert_includes stdout.b, manual_instructions("CLAUDE.md", "agents_section.md.tt").b
              assert_includes summary_entries(stdout, "Needs a person"), ".claude/hooks/quality_gate_fast.rb"
              assert_includes summary_entries(stdout, "Needs a person"), ".claude/settings.json"
              assert_includes summary_entries(stdout, "Needs a person"), "CLAUDE.md"
              assert_includes summary_entries(stdout, "Written"), "AGENTS.md"
            end
          end
        end
      end
    end

    def test_pretend_reports_pending_agent_writes_without_touching_the_host
      with_host do |host|
        pretend_stdout, pretend_stderr = run_generator(host, "--pretend")

        assert_empty pretend_stderr
        AGENT_FILES.each do |relative_path|
          refute_path_exists File.join(host, relative_path)
          assert_includes summary_entries(pretend_stdout, "Skipped"), "#{relative_path} (pretend)"
        end
      end
    end

    def test_private_generator_surface_hides_agent_contract_markers_and_directory_operations
      assert_raises(NameError) { InstallGenerator::AGENT_CONTRACT_START }
      assert_raises(NameError) { InstallGenerator::AGENT_CONTRACT_END }
      assert_raises(NameError) { InstallGenerator::DirectoryOperations }
    end

    def test_revoke_leaves_agent_integration_paths_untouched
      with_host do |host|
        run_generator(host)
        before = agent_snapshot(host)

        revoke_stdout, revoke_stderr = run_generator(host, behavior: :revoke)

        assert_empty revoke_stderr
        assert_equal before, agent_snapshot(host)
        refute_includes revoke_stdout, ".claude/hooks/quality_gate_fast.rb"
        refute_includes revoke_stdout, ".claude/settings.json"
      end
    end

    private

    def with_host
      Dir.mktmpdir("quality-gate-agent-install") do |parent|
        host = File.join(parent, "host")
        FileUtils.mkdir_p(File.join(host, "db/migrate"))
        FileUtils.mkdir_p(File.join(host, "test"))
        File.binwrite(File.join(host, "test/test_helper.rb"), <<~RUBY)
          require_relative "../config/environment"
          require "rails/test_help"
        RUBY
        File.binwrite(File.join(host, "db/migrate/20260829010101_create_accounts.rb"), "# fixture\n")
        yield host, parent
      end
    end

    def write_context_files(host, content)
      %w[CLAUDE.md AGENTS.md].each { write_context_file(host, _1, content) }
    end

    def write_context_file(host, relative_path, content)
      path = File.join(host, relative_path)
      File.binwrite(path, content)
      File.chmod(0o640, path)
      timestamp = Time.at(1_700_200_000)
      File.utime(timestamp, timestamp, path)
    end

    def with_forced_atomic_replace_failure(relative_path)
      InstallGenerator.atomic_replace_failure = relative_path
      yield
    ensure
      InstallGenerator.atomic_replace_failure = nil
    end

    def with_before_atomic_replace(relative_path, callback)
      previous = Array(InstallGenerator.before_atomic_replace)
      InstallGenerator.before_atomic_replace = previous + [[relative_path, callback]]
      yield
    ensure
      InstallGenerator.before_atomic_replace = previous
    end

    def with_after_verified_existing_file(relative_path, callback)
      previous = Array(InstallGenerator.after_verified_existing_file)
      InstallGenerator.after_verified_existing_file = previous + [[relative_path, callback]]
      yield
    ensure
      InstallGenerator.after_verified_existing_file = previous
    end

    def with_before_prepared_tempfile(relative_path, callback)
      previous = Array(InstallGenerator.before_prepared_tempfile)
      InstallGenerator.before_prepared_tempfile = previous + [[relative_path, callback]]
      yield
    ensure
      InstallGenerator.before_prepared_tempfile = previous
    end

    def with_before_publish_new_tempfile(relative_path, callback)
      previous = Array(InstallGenerator.before_publish_new_tempfile)
      InstallGenerator.before_publish_new_tempfile = previous + [[relative_path, callback]]
      yield
    ensure
      InstallGenerator.before_publish_new_tempfile = previous
    end

    def with_after_publish_new_tempfile(relative_path, callback)
      previous = Array(InstallGenerator.after_publish_new_tempfile)
      InstallGenerator.after_publish_new_tempfile = previous + [[relative_path, callback]]
      yield
    ensure
      InstallGenerator.after_publish_new_tempfile = previous
    end

    def with_before_verify_published_leaf(relative_path, callback)
      previous = Array(InstallGenerator.before_verify_published_leaf)
      InstallGenerator.before_verify_published_leaf = previous + [[relative_path, callback]]
      yield
    ensure
      InstallGenerator.before_verify_published_leaf = previous
    end

    def with_before_create_file_write(relative_path, callback)
      generator_previous = Array(InstallGenerator.before_publish_new_tempfile)
      previous = Array(Thor::Actions::CreateFile.before_destination_write)
      InstallGenerator.before_publish_new_tempfile = generator_previous + [[relative_path, callback]]
      Thor::Actions::CreateFile.before_destination_write = previous + [[relative_path, callback]]
      yield
    ensure
      InstallGenerator.before_publish_new_tempfile = generator_previous
      Thor::Actions::CreateFile.before_destination_write = previous
    end

    def with_create_file_partial_failure(relative_path, content)
      generator_previous = Array(InstallGenerator.partial_tempfile_write_failures)
      previous = Array(Thor::Actions::CreateFile.partial_write_failures)
      InstallGenerator.partial_tempfile_write_failures = generator_previous + [[relative_path, content]]
      Thor::Actions::CreateFile.partial_write_failures = previous + [[relative_path, content]]
      yield
    ensure
      InstallGenerator.partial_tempfile_write_failures = generator_previous
      Thor::Actions::CreateFile.partial_write_failures = previous
    end

    def with_before_replace_content(relative_path, callback)
      previous = Array(InstallGenerator.before_replace_content)
      InstallGenerator.before_replace_content = previous + [[relative_path, callback]]
      yield
    ensure
      InstallGenerator.before_replace_content = previous
    end

    def with_before_record_existing_template(relative_path, callback)
      previous = Array(InstallGenerator.before_record_existing_template)
      InstallGenerator.before_record_existing_template = previous + [[relative_path, callback]]
      yield
    ensure
      InstallGenerator.before_record_existing_template = previous
    end

    def with_after_claim_current_leaf(relative_path, callback)
      previous = Array(InstallGenerator.after_claim_current_leaf)
      InstallGenerator.after_claim_current_leaf = previous + [[relative_path, callback]]
      yield
    ensure
      InstallGenerator.after_claim_current_leaf = previous
    end

    def with_before_record_template_postcondition(relative_path, callback)
      previous = Array(InstallGenerator.before_record_template_postcondition)
      InstallGenerator.before_record_template_postcondition = previous + [[relative_path, callback]]
      yield
    ensure
      InstallGenerator.before_record_template_postcondition = previous
    end

    def with_compare_existing_failure(relative_path)
      previous = Array(InstallGenerator.compare_existing_failure)
      InstallGenerator.compare_existing_failure = previous + [relative_path]
      yield
    ensure
      InstallGenerator.compare_existing_failure = previous
    end

    def with_before_read_existing_agent_artifact(relative_path, callback)
      previous = Array(InstallGenerator.before_read_existing_agent_artifact)
      InstallGenerator.before_read_existing_agent_artifact = previous + [[relative_path, callback]]
      yield
    ensure
      InstallGenerator.before_read_existing_agent_artifact = previous
    end

    def with_before_finalize_existing_agent_artifact(relative_path, callback)
      previous = Array(InstallGenerator.before_finalize_existing_agent_artifact)
      InstallGenerator.before_finalize_existing_agent_artifact = previous + [[relative_path, callback]]
      yield
    ensure
      InstallGenerator.before_finalize_existing_agent_artifact = previous
    end

    def with_update_agent_contract_failure(relative_path)
      previous = Array(InstallGenerator.update_agent_contract_failure)
      InstallGenerator.update_agent_contract_failure = previous + [relative_path]
      yield
    ensure
      InstallGenerator.update_agent_contract_failure = previous
    end

    def with_postcondition_failure(relative_path)
      previous = Array(InstallGenerator.postcondition_failure)
      InstallGenerator.postcondition_failure = previous + [relative_path]
      yield
    ensure
      InstallGenerator.postcondition_failure = previous
    end

    def with_inside_anchored_directory(relative_path, callback)
      previous = Array(InstallGenerator.inside_anchored_directory_callbacks)
      InstallGenerator.inside_anchored_directory_callbacks = previous + [[relative_path, callback]]
      yield
    ensure
      InstallGenerator.inside_anchored_directory_callbacks = previous
    end

    def with_anchored_directory_context(relative_path, callback)
      previous = Array(InstallGenerator.anchored_directory_context_callbacks)
      InstallGenerator.anchored_directory_context_callbacks = previous + [[relative_path, callback]]
      yield
    ensure
      InstallGenerator.anchored_directory_context_callbacks = previous
    end

    def with_prepared_tempfile_callback(relative_path, callback)
      previous = Array(InstallGenerator.prepared_tempfile_callbacks)
      InstallGenerator.prepared_tempfile_callbacks = previous + [[relative_path, callback]]
      yield
    ensure
      InstallGenerator.prepared_tempfile_callbacks = previous
    end

    def with_before_temp_cleanup(relative_path, callback)
      previous = Array(InstallGenerator.before_temp_cleanup)
      InstallGenerator.before_temp_cleanup = previous + [[relative_path, callback]]
      yield
    ensure
      InstallGenerator.before_temp_cleanup = previous
    end

    def with_before_cleanup_unlink(relative_path, kind, callback)
      previous = Array(InstallGenerator.before_cleanup_unlink)
      InstallGenerator.before_cleanup_unlink = previous + [{ relative_path:, kind:, callback: }]
      yield
    ensure
      InstallGenerator.before_cleanup_unlink = previous
    end

    def with_directory_operation_failure(relative_path, operation, error, predicate: nil)
      previous = Array(InstallGenerator.directory_operation_failures)
      InstallGenerator.directory_operation_failures = previous + [
        { relative_path:, operation:, error:, predicate: }
      ]
      yield
    ensure
      InstallGenerator.directory_operation_failures = previous
    end

    def capture_directory_operation_log
      previous = InstallGenerator.directory_operation_log
      log = []
      InstallGenerator.directory_operation_log = log
      yield
      log
    ensure
      InstallGenerator.directory_operation_log = previous
    end

    def run_generator(host, *arguments, behavior: :invoke)
      # Agent integration tests explicitly opt in to the generator's agent surface.
      capture_io { InstallGenerator.start(["--agents", *arguments], destination_root: host, behavior:) }
    end

    def generator_diagnostic(stdout, stderr)
      "generator stdout:\n#{stdout}\ngenerator stderr:\n#{stderr}"
    end

    def expected_template(name)
      InstallGenerator.new.send(:rendered_template, name)
    end

    def read(host, relative_path)
      File.binread(File.join(host, relative_path))
    end

    def agent_snapshot(host)
      snapshot_for(host, AGENT_FILES)
    end

    def write_existing_agent_fixture(host, relative_path, template_name)
      path = File.join(host, relative_path)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, expected_template(template_name))
      File.chmod(relative_path.start_with?(".claude/hooks/") ? 0o755 : 0o640, path)
    end

    def snapshot_for(host, relative_paths)
      relative_paths.to_h do |relative_path|
        path = File.join(host, relative_path)
        [relative_path, [File.binread(path), File.mtime(path), File.stat(path).mode & 0o777]]
      end
    end

    def manual_instructions(relative_path, template_name)
      "Use these lines manually for #{relative_path}:\n#{expected_template(template_name)}"
    end

    def summary_entries(stdout, heading)
      lines = stdout.lines.map(&:chomp)
      start = lines.index("#{heading}:")
      return [] unless start

      lines.drop(start + 1).take_while { _1.start_with?("  - ") }.map { _1.delete_prefix("  - ") }
    end

    def refute_temp_artifacts(host)
      refute Dir.glob(File.join(host, "**/.quality_gate-*"), File::FNM_DOTMATCH).any?
    end

    def operation_names_for(log, relative_path, only:)
      log.filter_map do |entry|
        next unless entry[:relative_path] == relative_path
        next unless only.include?(entry[:operation])

        entry[:operation]
      end
    end

    def assert_operation_subsequence(expected, actual)
      start = 0
      matched = expected.all? do |operation|
        relative_index = actual.drop(start).index(operation)
        index = relative_index && relative_index + start
        next false unless index

        start = index + 1
        true
      end

      assert matched, "expected #{expected.inspect} inside #{actual.inspect}"
    end

    def run_in_child(timeout_seconds:)
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        yield writer
      rescue StandardError => e
        Marshal.dump({ child_error: [e.class.name, e.message] }, writer)
      ensure
        writer.close
        exit! 0
      end
      writer.close

      result = nil
      Timeout.timeout(timeout_seconds) do
        Process.wait(pid)
        result = Marshal.load(reader) unless reader.eof? # rubocop:disable Security/MarshalLoad
      end

      if result&.key?(:child_error)
        error_class, error_message = result.fetch(:child_error)
        flunk("child failed with #{error_class}: #{error_message}")
      end

      result
    rescue Timeout::Error
      Process.kill("KILL", pid)
      Process.wait(pid)
      flunk("child process did not complete within #{timeout_seconds} seconds")
    ensure
      reader.close unless reader.closed?
    end
  end
  # rubocop:enable Metrics/BlockLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  module AtomicReplaceFailureHarness # rubocop:disable Metrics/ModuleLength
    ACCESSORS = %i[
      atomic_replace_failure
      before_atomic_replace
      after_verified_existing_file
      before_prepared_tempfile
      before_publish_new_tempfile
      after_publish_new_tempfile
      before_replace_content
      before_record_existing_template
      after_claim_current_leaf
      before_record_template_postcondition
      compare_existing_failure
      inside_anchored_directory_callbacks
      anchored_directory_context_callbacks
      prepared_tempfile_callbacks
      before_temp_cleanup
      before_cleanup_unlink
      directory_operation_failures
      directory_operation_log
      partial_tempfile_write_failures
      update_agent_contract_failure
      postcondition_failure
      before_verify_published_leaf
      before_read_existing_agent_artifact
      before_finalize_existing_agent_artifact
    ].freeze

    def self.prepended(base)
      ACCESSORS.each { base.singleton_class.attr_accessor(_1) }
    end

    private

    def atomic_replace(path, content, mode: nil, expected: nil)
      mutate_path(self.class.before_atomic_replace, path, File.basename(path))
      failure_target = self.class.atomic_replace_failure
      raise Errno::EIO, path if failure_target && path.end_with?(failure_target)

      super
    end

    def replace_content(path, content, relative_path, manual_content: content, expected: nil)
      mutate_path(self.class.before_replace_content, path, relative_path)
      super
    end

    def record_existing_template(path, relative_path, mode: nil, existing: nil, status: nil)
      mutate_path(self.class.before_record_existing_template, path, relative_path)
      super
    end

    def compare_existing_template(path, content, relative_path, existing_file:, mode: nil)
      maybe_raise(self.class.compare_existing_failure, relative_path)
      super
    end

    def read_existing_agent_artifact(path, relative_path, status, manual_content)
      mutate_path(self.class.before_read_existing_agent_artifact, path, relative_path)
      super
    end

    def final_existing_agent_artifact_snapshot_valid?(context, io, content, status, parent_status)
      relative_path = [
        context.fetch(:directory_relative_path),
        context.fetch(:leaf_name)
      ].reject(&:empty?).join(File::SEPARATOR)
      path = File.join(destination_root, relative_path)
      mutate_path(self.class.before_finalize_existing_agent_artifact, path, relative_path)
      super
    end

    def update_agent_contract(path, relative_path, existing_file:)
      maybe_raise(self.class.update_agent_contract_failure, relative_path)
      super
    end

    def record_template_postcondition(path, content, relative_path, mode: nil, manual_content: content)
      mutate_path(self.class.before_record_template_postcondition, path, relative_path)
      maybe_raise(self.class.postcondition_failure, relative_path)
      super
    end

    def with_prepared_tempfile(path, content, relative_path, mode)
      mutate_path(self.class.before_prepared_tempfile, path, relative_path)
      super
    end

    def write_tempfile_content(tempfile, content, relative_path)
      failure = Array(self.class.partial_tempfile_write_failures).find { relative_path == _1.first }
      if failure
        tempfile.write(failure.last)
        raise Errno::EIO, relative_path
      end

      super
    end

    def publish_new_tempfile(path, tempfile, relative_path, content)
      mutate_path(self.class.before_publish_new_tempfile, path, relative_path)
      super.tap do
        mutate_path(self.class.after_publish_new_tempfile, path, relative_path)
      end
    end

    def verify_published_leaf!(tempfile, expected)
      path = File.join(destination_root, tempfile.relative_path)
      mutate_path(self.class.before_verify_published_leaf, path, tempfile.relative_path)
      super
    end

    def claim_current_leaf(tempfile, claim_name)
      super.tap do
        mutate_path(
          self.class.after_claim_current_leaf,
          File.join(destination_root, tempfile.relative_path),
          tempfile.relative_path
        )
      end
    end

    def verified_existing_file?(context, io, expected_content, expected_status)
      matched = super
      relative_path = [
        context.fetch(:directory_relative_path),
        context.fetch(:leaf_name)
      ].reject(&:empty?).join(File::SEPARATOR)
      path = File.join(destination_root, relative_path)
      mutate_path(self.class.after_verified_existing_file, path, relative_path)
      matched
    end

    def with_anchored_parent_directory(relative_path, create_missing:, &block)
      current = Thread.current[:quality_gate_relative_path_stack] ||= []
      current.push(relative_path)
      current_anchored_directory_callback&.call
      super do |context|
        mutate_context(self.class.anchored_directory_context_callbacks, relative_path, context)
        yield(context)
      end
    ensure
      current.pop
    end

    def create_anchored_tempfile(context, relative_path)
      super.tap do |tempfile|
        mutate_context(self.class.prepared_tempfile_callbacks, relative_path, tempfile)
      end
    end

    def safe_unlink_tempfile(tempfile, expected_status)
      mutate_path(self.class.before_temp_cleanup, tempfile.path, tempfile.relative_path)
      with_cleanup_context(tempfile.relative_path, :temp, tempfile.path) { super }
    end

    def cleanup_claim(tempfile, claim_name, expected_status, result)
      claim_path = File.join(parent_directory_path(tempfile.directory_relative_path), claim_name)
      with_cleanup_context(tempfile.relative_path, :claim, claim_path) { super }
    end

    def cleanup_published_leaf(tempfile, expected_status)
      with_cleanup_context(
        tempfile.relative_path,
        :published,
        File.join(destination_root, tempfile.relative_path)
      ) { super }
    end

    def mutate_path(configuration, path, relative_path)
      Array(configuration).each do |entry|
        expected_path, callback = entry
        callback.call(path) if expected_path == relative_path
      end
    end

    def mutate_context(configuration, relative_path, object)
      Array(configuration).each do |entry|
        expected_path, callback = entry
        callback.call(object) if expected_path == relative_path
      end
    end

    def with_cleanup_context(relative_path, kind, entry_path)
      previous = Thread.current[:quality_gate_cleanup_context]
      Thread.current[:quality_gate_cleanup_context] = { relative_path:, kind:, entry_path: }
      yield
    ensure
      Thread.current[:quality_gate_cleanup_context] = previous
    end

    def current_anchored_directory_callback
      relative_path = Array(Thread.current[:quality_gate_relative_path_stack]).last
      return unless relative_path

      Array(self.class.inside_anchored_directory_callbacks).find do |expected_path, callback|
        break callback if expected_path == relative_path
      end
    end

    def maybe_raise(expected_paths, relative_path)
      raise Errno::EACCES, relative_path if Array(expected_paths).include?(relative_path)
    end
  end

  module DirectoryOperationsHarness # rubocop:disable Metrics/ModuleLength
    def open_file(directory_io, entry_name, flags, mode = 0)
      phase = Thread.current[:quality_gate_fsync_phase]
      record_directory_operation(:open_file, entry_name:, flags:, mode:, phase:)
      maybe_fail_directory_operation(:open_file, entry_name:, flags:, mode:, phase:)
      super.tap do |io|
        record_directory_operation(:opened_file, entry_name:, close_on_exec: io.close_on_exec?)
      end
    end

    def open_directory(directory_io, entry_name, flags)
      record_directory_operation(:open_directory, entry_name:, flags:)
      maybe_fail_directory_operation(:open_directory, entry_name:, flags:)
      super
    end

    def mkdir(directory_io, entry_name, mode)
      record_directory_operation(:mkdir, entry_name:, mode:)
      maybe_fail_directory_operation(:mkdir, entry_name:, mode:)
      super
    end

    def link(directory_io, source_name, destination_name)
      previous = Thread.current[:quality_gate_fsync_phase]
      Thread.current[:quality_gate_fsync_phase] = :after_link
      record_directory_operation(:link, source_name:, destination_name:)
      maybe_fail_directory_operation(:link, source_name:, destination_name:)
      super
    rescue StandardError
      Thread.current[:quality_gate_fsync_phase] = previous
      raise
    end

    def rename_noreplace(directory_io, source_name, destination_name)
      previous = Thread.current[:quality_gate_fsync_phase]
      previous_context = Thread.current[:quality_gate_fsync_context]
      Thread.current[:quality_gate_fsync_phase] = :after_rename
      Thread.current[:quality_gate_fsync_context] = { source_name:, destination_name: }
      record_directory_operation(:rename_noreplace, source_name:, destination_name:)
      maybe_fail_directory_operation(:rename_noreplace, source_name:, destination_name:)
      super
    rescue StandardError
      Thread.current[:quality_gate_fsync_phase] = previous
      Thread.current[:quality_gate_fsync_context] = previous_context
      raise
    end

    def unlink(directory_io, entry_name)
      mutate_cleanup_entry(entry_name)
      record_directory_operation(:unlink, entry_name:, cleanup_kind: current_cleanup_context&.fetch(:kind, nil))
      maybe_fail_directory_operation(:unlink, entry_name:, cleanup_kind: current_cleanup_context&.fetch(:kind, nil))
      super
    end

    def fsync(io)
      phase = Thread.current[:quality_gate_fsync_phase]
      rename_context = Thread.current[:quality_gate_fsync_context] || {}
      record_directory_operation(:fsync, fileno: io.fileno, phase:, **rename_context)
      maybe_fail_directory_operation(:fsync, fileno: io.fileno, phase:, **rename_context)
      super
    ensure
      if %i[after_link after_rename].include?(phase)
        Thread.current[:quality_gate_fsync_phase] = nil
        Thread.current[:quality_gate_fsync_context] = nil
      end
    end

    def fchmod(io, mode)
      record_directory_operation(:fchmod, fileno: io.fileno, mode:)
      maybe_fail_directory_operation(:fchmod, fileno: io.fileno, mode:)
      super
    end

    private

    def record_directory_operation(operation, details = {})
      log = QualityGate::InstallGenerator.directory_operation_log
      return unless log

      log << details.merge(
        operation:,
        relative_path: current_relative_path,
        call_index: next_directory_operation_index(operation)
      )
    end

    def maybe_fail_directory_operation(operation, details = {})
      failure = Array(QualityGate::InstallGenerator.directory_operation_failures).find do |entry|
        next false unless entry.fetch(:operation) == operation
        next false unless entry.fetch(:relative_path) == current_relative_path

        predicate = entry[:predicate]
        predicate.nil? || predicate.call(
          details.merge(relative_path: current_relative_path, call_index: current_call_index(operation))
        )
      end
      raise failure.fetch(:error) if failure
    end

    def next_directory_operation_index(operation)
      counters = Thread.current[:quality_gate_directory_operation_counts] ||= Hash.new(0)
      counters[operation] += 1
    end

    def current_call_index(operation)
      counters = Thread.current[:quality_gate_directory_operation_counts] ||= Hash.new(0)
      counters[operation]
    end

    def current_relative_path
      Array(Thread.current[:quality_gate_relative_path_stack]).last
    end

    def current_cleanup_context
      Thread.current[:quality_gate_cleanup_context]
    end

    def mutate_cleanup_entry(_entry_name)
      context = current_cleanup_context
      return unless context

      Array(QualityGate::InstallGenerator.before_cleanup_unlink).each do |entry|
        next unless entry.fetch(:relative_path) == context.fetch(:relative_path)
        next unless entry.fetch(:kind) == context.fetch(:kind)

        entry.fetch(:callback).call(context.fetch(:entry_path))
      end
    end
  end

  module CreateFileFailureHarness
    def self.prepended(base)
      base.singleton_class.attr_accessor :before_destination_write
      base.singleton_class.attr_accessor :partial_write_failures
    end

    def invoke!
      invoke_with_conflict_check do
        require "fileutils"
        FileUtils.mkdir_p(File.dirname(destination))
        mutate_destination
        File.open(destination, "wb", config[:perm]) do |file|
          maybe_raise_after_partial_write(file)
          file.write(render)
        end
      end
      given_destination
    end

    private

    def mutate_destination
      Array(self.class.before_destination_write).each do |entry|
        expected_path, callback = entry
        callback.call(destination) if destination.end_with?(expected_path)
      end
    end

    def maybe_raise_after_partial_write(file)
      failure = Array(self.class.partial_write_failures).find { destination.end_with?(_1.first) }
      return unless failure

      file.write(failure.last)
      raise Errno::EIO, destination
    end
  end

  InstallGenerator.prepend(AtomicReplaceFailureHarness)
  InstallGenerator.const_get(:DirectoryOperations, false).singleton_class.prepend(DirectoryOperationsHarness)
  Thor::Actions::CreateFile.prepend(CreateFileFailureHarness)
end
