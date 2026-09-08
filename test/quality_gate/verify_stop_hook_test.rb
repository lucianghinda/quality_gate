# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "rails/generators"
require "generators/quality_gate/install/install_generator"

module QualityGate
  # The hook is a standalone process, so these tests exercise its full boundary.
  # rubocop:disable Metrics/AbcSize
  # rubocop:disable Naming/MethodParameterName
  class VerifyStopHookTest < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)
    TEMPLATE = File.join(
      ROOT,
      "lib/generators/quality_gate/install/templates/quality_gate_verify_stop.rb.tt"
    )
    MAX_LOG_SCAN_BYTES = 1024 * 1024
    MAX_LOG_LINE_BYTES = 64 * 1024
    SESSION_ID = "session-current"

    def test_template_is_static_executable_ruby_with_only_allowed_standard_libraries
      source = rendered_template

      assert source.start_with?("#!/usr/bin/env ruby\n")
      refute_includes source, "<%"
      assert_equal %w[fiddle/import json open3 time], source.scan(/^\s*require "([^"]+)"$/).flatten.sort
      assert_predicate RubyVM::InstructionSequence.compile(source), :itself
    end

    def test_c1_no_ruby_status_path_skips_verify_and_logs_the_session
      ["", " M README.md\n?? config/settings.yml\n"].each do |status_output|
        with_workspace do |workspace|
          result = invoke_hook(workspace, stop_input(workspace), "FAKE_GIT_STDOUT" => status_output)

          assert_success_without_output(result)
          assert_equal [expected_git_invocation(workspace)], invocations(workspace)
          assert_stop_record(workspace, outcome: "verify_skipped")
        end
      end
    end

    def test_non_ruby_type_changes_are_proven_safe_to_skip
      [" T README.md\n", "T  README.md\n"].each do |status_output|
        with_workspace do |workspace|
          result = invoke_hook(workspace, stop_input(workspace), "FAKE_GIT_STDOUT" => status_output)

          assert_success_without_output(result)
          assert_equal [expected_git_invocation(workspace)], invocations(workspace)
          assert_stop_record(workspace, outcome: "verify_skipped")
        end
      end
    end

    def test_malformed_input_and_root_session_fallbacks
      ["", "{", JSON.generate([])].each do |input|
        with_workspace do |workspace|
          result = invoke_hook(workspace, input, "FAKE_GIT_STDOUT" => "")

          assert_success_without_output(result)
          assert_equal [expected_git_invocation(workspace)], invocations(workspace)
          assert_stop_record(workspace, outcome: "verify_skipped", session_id: "unknown")
        end
      end

      with_workspace do |workspace|
        input = { "cwd" => "", "session_id" => "" }
        result = invoke_hook(workspace, input, "FAKE_GIT_STDOUT" => "")

        assert_success_without_output(result)
        assert_stop_record(workspace, outcome: "verify_skipped", session_id: "unknown")
      end

      with_workspace do |workspace|
        result = invoke_hook(
          workspace,
          {},
          "CLAUDE_PROJECT_DIR" => "",
          "FAKE_GIT_STDOUT" => ""
        )

        assert_success_without_output(result)
        assert_equal [expected_git_invocation(workspace, root: :process)], invocations(workspace)
        assert_stop_record(workspace, outcome: "verify_skipped", root: :process, session_id: "unknown")
      end
    end

    def test_c2_dirty_ruby_with_a_clean_report_allows_stop
      with_workspace do |workspace|
        result = invoke_hook(workspace, stop_input(workspace))

        assert_success_without_output(result)
        assert_equal expected_verify_invocations(workspace), invocations(workspace)
        assert_stop_record(workspace, outcome: "verify_clean")
      end
    end

    def test_c3_dirty_ruby_with_findings_blocks_with_exact_json_on_stderr
      with_workspace do |workspace|
        report = findings_report
        result = invoke_hook(
          workspace,
          stop_input(workspace),
          "FAKE_BUNDLE_EXIT" => "1",
          "FAKE_BUNDLE_STDOUT" => report
        )

        assert_equal 2, result.fetch(:status).exitstatus
        assert_empty result.fetch(:stdout)
        assert_equal report, result.fetch(:stderr)
        assert_equal expected_verify_invocations(workspace), invocations(workspace)
        assert_stop_record(workspace, outcome: "verify_blocked")
      end
    end

    def test_c4_three_trailing_same_session_blocks_reach_the_cap
      with_workspace do |workspace|
        append_log_entry(workspace, outcome: "verify_blocked", session_id: SESSION_ID)
        append_log_entry(workspace, outcome: "clean", file: "app/one.rb")
        append_log_entry(workspace, outcome: "verify_clean", session_id: "another-session")
        append_log_entry(workspace, outcome: "verify_blocked", session_id: SESSION_ID)
        append_log_entry(workspace, outcome: "findings", file: "app/two.rb")
        append_log_entry(workspace, outcome: "verify_blocked", session_id: SESSION_ID)

        result = invoke_hook(workspace, stop_input(workspace))

        assert_success_without_output(result)
        assert_equal [expected_git_invocation(workspace)], invocations(workspace)
        assert_equal "verify_cap", log_entries(workspace).last.fetch("outcome")
      end
    end

    def test_c5_invalid_or_missing_verify_reports_fail_open
      cases = {
        "invalid JSON" => { "FAKE_BUNDLE_STDOUT" => "not json" },
        "wrong JSON shape" => { "FAKE_BUNDLE_STDOUT" => JSON.generate("findings" => {}, "summary" => {}) },
        "tool failure exit" => { "FAKE_BUNDLE_EXIT" => "2" },
        "unexpected exit" => { "FAKE_BUNDLE_EXIT" => "3" },
        "findings on clean exit" => { "FAKE_BUNDLE_STDOUT" => findings_report },
        "clean report on findings exit" => { "FAKE_BUNDLE_EXIT" => "1" },
        "summary mismatch" => { "FAKE_BUNDLE_STDOUT" => mismatched_report },
        "reported tool failure" => { "FAKE_BUNDLE_STDOUT" => tool_failure_report },
        "signal" => { "FAKE_BUNDLE_SIGNAL" => "TERM" }
      }

      cases.each do |label, environment|
        with_workspace do |workspace|
          result = invoke_hook(
            workspace,
            stop_input(workspace),
            { "FAKE_BUNDLE_STDERR" => "internal failure" }.merge(environment)
          )

          assert_success_without_output(result, label)
          assert_equal expected_verify_invocations(workspace), invocations(workspace), label
          assert_stop_record(workspace, outcome: "verify_unavailable", message: label)
        end
      end
    end

    def test_malformed_finding_objects_fail_open
      cases = {
        "missing fields" => {},
        "wrong field type" => valid_finding.merge("tool" => 7),
        "negative line" => valid_finding.merge("line" => -1),
        "unknown severity" => valid_finding.merge("severity" => "critical"),
        "tool failure finding" => valid_finding.merge("rule" => "tool_failure")
      }

      cases.each do |label, finding|
        with_workspace do |workspace|
          result = invoke_hook(
            workspace,
            stop_input(workspace),
            "FAKE_BUNDLE_EXIT" => "1",
            "FAKE_BUNDLE_STDOUT" => report_with(finding)
          )

          assert_success_without_output(result, label)
          assert_stop_record(workspace, outcome: "verify_unavailable", message: label)
        end
      end
    end

    def test_spawn_error_fails_open
      with_workspace do |workspace|
        FileUtils.rm(File.join(workspace.fetch(:bin), "bundle"))

        result = invoke_hook(workspace, stop_input(workspace))

        assert_success_without_output(result)
        assert_equal [expected_git_invocation(workspace)], invocations(workspace)
        assert_stop_record(workspace, outcome: "verify_unavailable")
      end
    end

    def test_c13_git_failure_errs_toward_running_verify
      with_workspace do |workspace|
        result = invoke_hook(
          workspace,
          stop_input(workspace),
          "FAKE_GIT_EXIT" => "128",
          "FAKE_GIT_STDERR" => "not a repository"
        )

        assert_success_without_output(result)
        assert_equal expected_verify_invocations(workspace), invocations(workspace)
        assert_stop_record(workspace, outcome: "verify_clean")
      end
    end

    def test_git_spawn_error_errs_toward_running_verify
      with_workspace do |workspace|
        FileUtils.rm(File.join(workspace.fetch(:bin), "git"))

        result = invoke_hook(
          workspace,
          stop_input(workspace),
          "PATH" => workspace.fetch(:bin)
        )

        assert_success_without_output(result)
        assert_equal [expected_bundle_invocation(workspace)], invocations(workspace)
        assert_stop_record(workspace, outcome: "verify_clean")
      end
    end

    def test_ambiguous_git_output_errs_toward_running_verify
      with_workspace do |workspace|
        result = invoke_hook(workspace, stop_input(workspace), "FAKE_GIT_STDOUT" => "not porcelain\n")

        assert_success_without_output(result)
        assert_equal expected_verify_invocations(workspace), invocations(workspace)
        assert_stop_record(workspace, outcome: "verify_clean")
      end
    end

    def test_created_modified_deleted_renamed_and_quoted_ruby_paths_run_verify
      statuses = {
        "created" => "A  app/new.rb\n",
        "modified" => " M app/changed.rb\n",
        "deleted" => " D app/deleted.rb\n",
        "renamed from Ruby" => "R  app/old.rb -> app/new.txt\n",
        "renamed to Ruby" => "R  app/old.txt -> app/new.rb\n",
        "quoted" => "?? \"app/quoted\\040name.rb\"\n"
      }

      statuses.each do |label, status_output|
        with_workspace do |workspace|
          result = invoke_hook(workspace, stop_input(workspace), "FAKE_GIT_STDOUT" => status_output)

          assert_success_without_output(result, label)
          assert_equal expected_verify_invocations(workspace), invocations(workspace), label
          assert_stop_record(workspace, outcome: "verify_clean", message: label)
        end
      end
    end

    def test_real_git_finds_ruby_inside_a_wholly_untracked_directory
      with_workspace do |workspace|
        FileUtils.rm(File.join(workspace.fetch(:bin), "git"))
        initialize_git_repository(workspace, show_untracked_files: "no")
        file = File.join(workspace.fetch(:project), "app/new_area/example.rb")
        FileUtils.mkdir_p(File.dirname(file))
        File.write(file, "class Example; end\n")

        result = invoke_hook(workspace, stop_input(workspace))

        assert_success_without_output(result)
        assert_equal [expected_bundle_invocation(workspace)], invocations(workspace)
        assert_stop_record(workspace, outcome: "verify_clean")
      end
    end

    def test_c14_two_trailing_blocks_do_not_reach_the_cap
      with_workspace do |workspace|
        3.times { append_log_entry(workspace, outcome: "verify_blocked", session_id: SESSION_ID) }
        append_log_entry(workspace, outcome: "verify_unavailable", session_id: SESSION_ID)
        append_log_entry(workspace, outcome: "verify_blocked", session_id: SESSION_ID)
        append_log_entry(workspace, outcome: "clean", file: "app/edit.rb")
        append_log_entry(workspace, outcome: "verify_blocked", session_id: SESSION_ID)
        report = findings_report

        result = invoke_hook(
          workspace,
          stop_input(workspace),
          "FAKE_BUNDLE_EXIT" => "1",
          "FAKE_BUNDLE_STDOUT" => report
        )

        assert_equal 2, result.fetch(:status).exitstatus
        assert_empty result.fetch(:stdout)
        assert_equal report, result.fetch(:stderr)
        assert_equal expected_verify_invocations(workspace), invocations(workspace)
        assert_equal "verify_blocked", log_entries(workspace).last.fetch("outcome")
      end
    end

    def test_c15_clean_verify_without_a_later_ruby_edit_is_debounced
      with_workspace do |workspace|
        clean_ts = "2026-09-04T10:00:00.000000Z"
        append_log_entry(workspace, outcome: "clean", file: "app/older.rb", ts: "2026-09-04T09:59:59Z")
        append_log_entry(workspace, outcome: "verify_clean", session_id: SESSION_ID, ts: clean_ts)
        append_log_entry(workspace, outcome: "verify_blocked", session_id: "another-session", ts: clean_ts)
        append_log_entry(workspace, outcome: "clean", file: "README.md", ts: "2026-09-04T10:00:01Z")

        result = invoke_hook(workspace, stop_input(workspace))

        assert_success_without_output(result)
        assert_equal [expected_git_invocation(workspace)], invocations(workspace)
        assert_equal "verify_debounced", log_entries(workspace).last.fetch("outcome")
      end
    end

    def test_repeated_unchanged_stops_remain_debounced_after_one_clean_verify
      with_workspace do |workspace|
        results = Array.new(3) { invoke_hook(workspace, stop_input(workspace)) }

        results.each { assert_success_without_output(_1) }
        outcomes = log_entries(workspace).map { _1["outcome"] }
        assert_equal %w[verify_clean verify_debounced verify_debounced], outcomes
        assert_equal(
          [
            expected_git_invocation(workspace),
            expected_bundle_invocation(workspace),
            expected_git_invocation(workspace),
            expected_git_invocation(workspace)
          ],
          invocations(workspace)
        )
      end
    end

    def test_c16_a_newer_blocked_verify_cannot_debounce
      with_workspace do |workspace|
        append_log_entry(
          workspace,
          outcome: "verify_clean",
          session_id: SESSION_ID,
          ts: "2026-09-04T10:00:00Z"
        )
        append_log_entry(
          workspace,
          outcome: "verify_clean",
          session_id: "another-session",
          ts: "2026-09-04T10:00:01Z"
        )
        append_log_entry(
          workspace,
          outcome: "verify_blocked",
          session_id: SESSION_ID,
          ts: "2026-09-04T10:00:02Z"
        )
        report = findings_report

        result = invoke_hook(
          workspace,
          stop_input(workspace),
          "FAKE_BUNDLE_EXIT" => "1",
          "FAKE_BUNDLE_STDOUT" => report
        )

        assert_equal 2, result.fetch(:status).exitstatus
        assert_empty result.fetch(:stdout)
        assert_equal report, result.fetch(:stderr)
        assert_equal expected_verify_invocations(workspace), invocations(workspace)
        assert_equal "verify_blocked", log_entries(workspace).last.fetch("outcome")
      end
    end

    def test_unavailable_and_cap_outcomes_cannot_debounce_from_an_older_clean
      %w[verify_unavailable verify_cap].each do |latest_outcome|
        with_workspace do |workspace|
          append_log_entry(
            workspace,
            outcome: "verify_clean",
            session_id: SESSION_ID,
            ts: "2026-09-04T10:00:00Z"
          )
          append_log_entry(
            workspace,
            outcome: latest_outcome,
            session_id: SESSION_ID,
            ts: "2026-09-04T10:00:01Z"
          )

          result = invoke_hook(workspace, stop_input(workspace))

          assert_success_without_output(result, latest_outcome)
          assert_equal expected_verify_invocations(workspace), invocations(workspace), latest_outcome
          assert_equal "verify_clean", log_entries(workspace).last.fetch("outcome"), latest_outcome
        end
      end
    end

    def test_c17_ruby_edit_at_the_clean_verify_timestamp_counts_as_new
      with_workspace do |workspace|
        timestamp = "2026-09-04T10:00:00.000000Z"
        append_log_entry(workspace, outcome: "verify_clean", session_id: SESSION_ID, ts: timestamp)
        append_log_entry(workspace, outcome: "clean", file: "app/exact.rb", ts: timestamp)

        result = invoke_hook(workspace, stop_input(workspace))

        assert_success_without_output(result)
        assert_equal expected_verify_invocations(workspace), invocations(workspace)
        assert_equal "verify_clean", log_entries(workspace).last.fetch("outcome")
      end
    end

    def test_symlinked_log_directory_is_neither_read_nor_written
      with_workspace do |workspace|
        outside = File.join(workspace.fetch(:process), "outside-log")
        target = File.join(outside, "quality_gate_hooks.jsonl")
        FileUtils.mkdir_p(outside)
        original = blocked_history
        File.binwrite(target, original)
        File.symlink(outside, File.join(workspace.fetch(:project), "log"))

        result = invoke_hook(workspace, stop_input(workspace))

        assert_success_without_output(result)
        assert_equal expected_verify_invocations(workspace), invocations(workspace)
        assert_equal original, File.binread(target)
      end
    end

    def test_symlinked_log_leaf_is_neither_read_nor_written
      with_workspace do |workspace|
        outside = File.join(workspace.fetch(:process), "outside.jsonl")
        FileUtils.mkdir_p(File.dirname(hook_log_path(workspace)))
        original = blocked_history
        File.binwrite(outside, original)
        File.symlink(outside, hook_log_path(workspace))

        result = invoke_hook(workspace, stop_input(workspace))

        assert_success_without_output(result)
        assert_equal expected_verify_invocations(workspace), invocations(workspace)
        assert_equal original, File.binread(outside)
      end
    end

    def test_multiply_linked_log_leaf_is_neither_read_nor_written
      with_workspace do |workspace|
        outside = File.join(workspace.fetch(:process), "outside.jsonl")
        FileUtils.mkdir_p(File.dirname(hook_log_path(workspace)))
        original = blocked_history
        File.binwrite(outside, original)
        File.link(outside, hook_log_path(workspace))

        result = invoke_hook(workspace, stop_input(workspace))

        assert_success_without_output(result)
        assert_equal expected_verify_invocations(workspace), invocations(workspace)
        assert_equal original, File.binread(outside)
      end
    end

    def test_invalid_and_oversized_tail_records_do_not_hide_valid_block_history
      oversized_record = encoded_log_entry(
        outcome: "verify_clean",
        session_id: SESSION_ID,
        padding: "x" * MAX_LOG_LINE_BYTES
      )
      invalid_tails = {
        "malformed JSON" => "{not-json\n".b,
        "invalid UTF-8" => "\xFF\n".b,
        "oversized record" => "#{oversized_record}\n".b
      }

      invalid_tails.each do |label, tail|
        with_workspace do |workspace|
          write_hook_log(workspace, blocked_history + tail)

          result = invoke_hook(workspace, stop_input(workspace))

          assert_success_without_output(result, label)
          assert_equal [expected_git_invocation(workspace)], invocations(workspace), label
          assert_equal "verify_cap", valid_log_entries(workspace).last.fetch("outcome"), label
        end
      end
    end

    def test_history_before_the_bounded_tail_is_unavailable
      with_workspace do |workspace|
        outside_window = "x" * (MAX_LOG_SCAN_BYTES + 1)
        write_hook_log(workspace, "#{blocked_history}#{outside_window}\n")

        result = invoke_hook(workspace, stop_input(workspace))

        assert_success_without_output(result)
        assert_equal expected_verify_invocations(workspace), invocations(workspace)
        assert_equal "verify_clean", valid_log_entries(workspace).last.fetch("outcome")
      end
    end

    def test_complete_history_at_the_tail_window_boundary_is_read
      with_workspace do |workspace|
        history = blocked_history
        filler = "x" * (MAX_LOG_SCAN_BYTES - history.bytesize - 1)
        write_hook_log(workspace, "outside\n#{history}#{filler}\n")

        result = invoke_hook(workspace, stop_input(workspace))

        assert_success_without_output(result)
        assert_equal [expected_git_invocation(workspace)], invocations(workspace)
        assert_equal "verify_cap", valid_log_entries(workspace).last.fetch("outcome")
      end
    end

    def test_unwritable_log_fails_open_for_repeated_findings
      with_workspace do |workspace|
        log_blocker = File.join(workspace.fetch(:project), "log")
        File.write(log_blocker, "blocks log directory")
        report = findings_report

        results = Array.new(4) do
          invoke_hook(
            workspace,
            stop_input(workspace),
            "FAKE_BUNDLE_EXIT" => "1",
            "FAKE_BUNDLE_STDOUT" => report
          )
        end

        results.each { assert_success_without_output(_1) }
        assert_equal expected_verify_invocations(workspace) * 4, invocations(workspace)
        assert_equal "blocks log directory", File.read(log_blocker)
      end
    end

    def test_appendable_but_unreadable_history_fails_open_for_repeated_findings
      with_workspace do |workspace|
        append_log_entry(workspace, outcome: "clean", file: "app/older.rb")
        helper = File.join(workspace.fetch(:root), "unreadable-hook-log.rb")
        File.write(helper, force_hook_log_read_failure)
        report = findings_report

        fail_open_results = Array.new(4) do
          invoke_hook(
            workspace,
            stop_input(workspace),
            "FAKE_BUNDLE_EXIT" => "1",
            "FAKE_BUNDLE_STDOUT" => report,
            "RUBYOPT" => "-r#{helper}"
          )
        end
        recovered_result = invoke_hook(
          workspace,
          stop_input(workspace),
          "FAKE_BUNDLE_EXIT" => "1",
          "FAKE_BUNDLE_STDOUT" => report
        )

        fail_open_results.each { assert_success_without_output(_1) }
        assert_equal 2, recovered_result.fetch(:status).exitstatus
        assert_empty recovered_result.fetch(:stdout)
        assert_equal report, recovered_result.fetch(:stderr)
        assert_equal expected_verify_invocations(workspace) * 5, invocations(workspace)
        expected_outcomes = %w[
          clean verify_unavailable verify_unavailable verify_unavailable verify_unavailable verify_blocked
        ]
        assert_equal expected_outcomes, log_outcomes(workspace)
      end
    end

    def test_new_log_file_respects_a_restrictive_umask
      with_workspace do |workspace|
        result = invoke_hook(workspace, stop_input(workspace), {}, umask: 0o077)

        assert_success_without_output(result)
        assert_equal 0o600, File.stat(hook_log_path(workspace)).mode & 0o777
      end
    end

    private

    def with_workspace
      Dir.mktmpdir("quality-gate-verify-stop") do |root|
        project = File.join(root, "project")
        process = File.join(root, "process")
        bin = File.join(root, "bin")
        FileUtils.mkdir_p([project, process, bin])

        workspace = {
          root:,
          project:,
          process:,
          bin:,
          hook: File.join(process, "quality_gate_verify_stop.rb"),
          invocation_log: File.join(root, "invocations.jsonl")
        }
        File.write(workspace.fetch(:hook), rendered_template)
        write_fake_executable(workspace, "git")
        write_fake_executable(workspace, "bundle")
        yield workspace
      end
    end

    def write_fake_executable(workspace, command)
      path = File.join(workspace.fetch(:bin), command)
      File.write(path, fake_command(command))
      FileUtils.chmod(0o755, path)
    end

    def invoke_hook(workspace, input, environment = {}, spawn_options = {})
      stdin_data = input.is_a?(String) ? input : JSON.generate(input)
      default_environment = {
        "PATH" => [workspace.fetch(:bin), ENV.fetch("PATH")].join(File::PATH_SEPARATOR),
        "BUNDLE_BIN_PATH" => nil,
        "BUNDLE_GEMFILE" => nil,
        "CLAUDE_PROJECT_DIR" => workspace.fetch(:project),
        "INVOCATION_LOG" => workspace.fetch(:invocation_log),
        "FAKE_GIT_EXIT" => "0",
        "FAKE_GIT_STDOUT" => " M app/models/example.rb\n",
        "FAKE_BUNDLE_EXIT" => "0",
        "FAKE_BUNDLE_STDOUT" => clean_report
      }

      stdout, stderr, status = Open3.capture3(
        default_environment.merge(environment),
        RbConfig.ruby,
        workspace.fetch(:hook),
        stdin_data:,
        chdir: workspace.fetch(:process),
        **spawn_options
      )
      { stdout:, stderr:, status: }
    end

    def stop_input(workspace, session_id: SESSION_ID)
      { "cwd" => workspace.fetch(:project), "session_id" => session_id }
    end

    def expected_git_invocation(workspace, root: :project)
      {
        "command" => "git",
        "cwd" => File.realpath(workspace.fetch(root)),
        "args" => ["status", "--porcelain", "--untracked-files=all"]
      }
    end

    def expected_bundle_invocation(workspace)
      {
        "command" => "bundle",
        "cwd" => File.realpath(workspace.fetch(:project)),
        "args" => ["exec", "quality_gate", "verify", "--format", "json"]
      }
    end

    def expected_verify_invocations(workspace)
      [expected_git_invocation(workspace), expected_bundle_invocation(workspace)]
    end

    def initialize_git_repository(workspace, show_untracked_files:)
      git_command(workspace, "init", "--quiet")
      git_command(workspace, "config", "status.showUntrackedFiles", show_untracked_files)
    end

    def git_command(workspace, *arguments)
      _stdout, stderr, status = Open3.capture3("git", *arguments, chdir: workspace.fetch(:project))
      assert_predicate status, :success?, stderr
    end

    def rendered_template
      assert File.file?(TEMPLATE), "expected hook template at #{TEMPLATE}"

      InstallGenerator.new.send(:rendered_template, File.basename(TEMPLATE))
    end

    def fake_command(command)
      prefix = command.upcase
      <<~RUBY
        #!#{RbConfig.ruby}
        require "json"

        File.open(ENV.fetch("INVOCATION_LOG"), "a") do |io|
          io.puts(JSON.generate("command" => #{command.inspect}, "cwd" => Dir.pwd, "args" => ARGV))
        end
        Process.kill(ENV.fetch("FAKE_#{prefix}_SIGNAL"), Process.pid) if ENV["FAKE_#{prefix}_SIGNAL"]
        $stdout.write(ENV.fetch("FAKE_#{prefix}_STDOUT", ""))
        $stderr.write(ENV.fetch("FAKE_#{prefix}_STDERR", ""))
        exit(Integer(ENV.fetch("FAKE_#{prefix}_EXIT", "0")))
      RUBY
    end

    def force_hook_log_read_failure
      <<~RUBY
        require "fcntl"

        File.singleton_class.prepend(Module.new do
          def for_fd(...)
            super.tap do |io|
              next unless io.stat.file?

              flags = io.fcntl(Fcntl::F_GETFL)
              next unless (flags & Fcntl::O_ACCMODE) == Fcntl::O_RDONLY

              io.close
              raise Errno::EACCES, "forced hook log read failure"
            end
          end
        end)
      RUBY
    end

    def clean_report
      JSON.generate(
        "findings" => [],
        "summary" => { "findings" => 0, "tool_failures" => 0, "failed_tools" => [] }
      )
    end

    def findings_report
      report_with(valid_finding.merge("future_field" => true))
    end

    def valid_finding
      {
        "tool" => "rubocop",
        "file" => "app/models/example.rb",
        "line" => 1,
        "rule" => "Style/Test",
        "severity" => "warning",
        "message" => "fix this"
      }
    end

    def report_with(finding)
      JSON.generate(
        "findings" => [finding],
        "summary" => { "findings" => 1, "tool_failures" => 0, "failed_tools" => [] }
      )
    end

    def mismatched_report
      JSON.generate(
        "findings" => [],
        "summary" => { "findings" => 1, "tool_failures" => 0, "failed_tools" => [] }
      )
    end

    def tool_failure_report
      JSON.generate(
        "findings" => [],
        "summary" => { "findings" => 0, "tool_failures" => 1, "failed_tools" => ["rubocop"] }
      )
    end

    def blocked_history
      Array.new(3) do |index|
        encoded_log_entry(
          outcome: "verify_blocked",
          session_id: SESSION_ID,
          ts: "2026-09-04T10:00:0#{index}Z"
        )
      end.join("\n") << "\n"
    end

    def append_log_entry(
      workspace,
      outcome:,
      file: nil,
      session_id: :omitted,
      ts: "2026-09-04T10:00:00Z"
    )
      FileUtils.mkdir_p(File.dirname(hook_log_path(workspace)))
      File.open(hook_log_path(workspace), "a") do |io|
        io.puts(encoded_log_entry(outcome:, file:, session_id:, ts:))
      end
    end

    def encoded_log_entry(outcome:, file: nil, session_id: :omitted, ts: "2026-09-04T10:00:00Z", padding: nil)
      entry = {
        "ts" => ts,
        "file" => file,
        "outcome" => outcome,
        "duration_ms" => 1
      }
      entry["session_id"] = session_id unless session_id == :omitted
      entry["padding"] = padding if padding
      JSON.generate(entry)
    end

    def write_hook_log(workspace, bytes)
      FileUtils.mkdir_p(File.dirname(hook_log_path(workspace)))
      File.binwrite(hook_log_path(workspace), bytes)
    end

    def hook_log_path(workspace, root: :project)
      File.join(workspace.fetch(root), "log/quality_gate_hooks.jsonl")
    end

    def invocations(workspace)
      path = workspace.fetch(:invocation_log)
      return [] unless File.file?(path)

      File.readlines(path, chomp: true).map { JSON.parse(_1) }
    end

    def log_outcomes(workspace)
      log_entries(workspace).map { _1.fetch("outcome") }
    end

    def log_entries(workspace, root: :project)
      File.readlines(hook_log_path(workspace, root:), chomp: true).map { JSON.parse(_1) }
    end

    def valid_log_entries(workspace)
      File.binread(hook_log_path(workspace)).split("\n".b).filter_map do |line|
        line = line.dup.force_encoding(Encoding::UTF_8)
        JSON.parse(line) if line.valid_encoding? && line.bytesize <= MAX_LOG_LINE_BYTES
      rescue JSON::ParserError
        nil
      end
    end

    def assert_success_without_output(result, message = nil)
      assert_predicate result.fetch(:status), :success?, message
      assert_empty result.fetch(:stdout), message
      assert_empty result.fetch(:stderr), message
    end

    def assert_stop_record(
      workspace,
      outcome:,
      root: :project,
      session_id: SESSION_ID,
      message: nil
    )
      entries = log_entries(workspace, root:)
      assert_equal 1, entries.length, message

      entry = entries.first
      assert_equal %w[duration_ms file outcome session_id ts], entry.keys.sort, message
      assert_nil entry.fetch("file"), message
      assert_equal outcome, entry.fetch("outcome"), message
      assert_equal session_id, entry.fetch("session_id"), message
      assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\z/, entry.fetch("ts"), message)
      assert_kind_of Numeric, entry.fetch("duration_ms"), message
      assert_operator entry.fetch("duration_ms"), :>=, 0, message
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/BlockLength
  # rubocop:enable Naming/MethodParameterName
end
