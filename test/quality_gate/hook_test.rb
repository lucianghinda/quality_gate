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
  # Assertion-heavy behavioral tests are clearer when each outcome stays visible.
  # rubocop:disable Metrics/AbcSize
  class HookTest < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)
    TEMPLATE = File.join(ROOT, "lib/generators/quality_gate/install/templates/quality_gate_fast.rb.tt")
    UNAVAILABLE_NOTICE = "quality_gate fast could not run; " \
                         "run `bundle exec quality_gate fast` and check log/quality_gate_hooks.jsonl\n"
    MAX_LOG_SCAN_BYTES = 1024 * 1024
    MAX_LOG_LINE_BYTES = 64 * 1024

    def test_template_is_static_executable_ruby_with_only_the_allowed_standard_libraries
      source = rendered_template

      assert source.start_with?("#!/usr/bin/env ruby\n")
      refute_includes source, "<%"
      assert_equal %w[fiddle/import json open3 time], source.scan(/^\s*require "([^"]+)"$/).flatten.sort
      assert_predicate RubyVM::InstructionSequence.compile(source), :itself
    end

    def test_missing_file_input_is_a_logged_no_file_without_starting_quality_gate
      ["", "{", "\xFF".b, JSON.generate("tool_input" => "not an object")].each do |input|
        with_workspace do |workspace|
          result = invoke_hook(workspace, input)

          assert_predicate result.fetch(:status), :success?
          assert_empty result.fetch(:stdout)
          assert_empty result.fetch(:stderr)
          assert_empty invocations(workspace)
          assert_log_entry(workspace, file: nil, outcome: "no_file", root: :process)
        end
      end

      with_workspace do |workspace|
        input = { "cwd" => workspace.fetch(:project), "tool_input" => {} }
        result = invoke_hook(workspace, input)

        assert_predicate result.fetch(:status), :success?
        assert_empty result.fetch(:stdout)
        assert_empty result.fetch(:stderr)
        assert_empty invocations(workspace)
        assert_log_entry(workspace, file: nil, outcome: "no_file")
      end
    end

    def test_non_ruby_file_is_skipped_without_starting_quality_gate
      with_workspace do |workspace|
        file = File.join(workspace.fetch(:project), "README.md")
        File.write(file, "documentation")

        result = invoke_hook(workspace, hook_input(workspace, file))

        assert_predicate result.fetch(:status), :success?
        assert_empty result.fetch(:stdout)
        assert_empty result.fetch(:stderr)
        assert_empty invocations(workspace)
        assert_log_entry(workspace, file:, outcome: "skipped")
      end
    end

    def test_missing_ruby_file_is_deleted_without_starting_quality_gate
      with_workspace do |workspace|
        file = File.join(workspace.fetch(:project), "removed.rb")

        result = invoke_hook(workspace, hook_input(workspace, file))

        assert_predicate result.fetch(:status), :success?
        assert_empty result.fetch(:stdout)
        assert_empty result.fetch(:stderr)
        assert_empty invocations(workspace)
        assert_log_entry(workspace, file:, outcome: "deleted")
      end
    end

    def test_valid_clean_result_runs_in_input_cwd_with_the_expected_argv
      with_workspace do |workspace|
        file = ruby_file(workspace)

        result = invoke_hook(workspace, hook_input(workspace, file))

        assert_predicate result.fetch(:status), :success?
        assert_empty result.fetch(:stdout)
        assert_empty result.fetch(:stderr)
        assert_equal [expected_invocation(workspace, file)], invocations(workspace)
        assert_log_entry(workspace, file:, outcome: "clean")
        refute_path_exists File.join(workspace.fetch(:process), "log")
      end
    end

    def test_valid_findings_result_returns_json_feedback_on_standard_error
      with_workspace do |workspace|
        file = ruby_file(workspace)
        report = findings_report

        result = invoke_hook(
          workspace,
          hook_input(workspace, file),
          "FAKE_EXIT" => "1",
          "FAKE_STDOUT" => report
        )

        assert_equal 2, result.fetch(:status).exitstatus
        assert_empty result.fetch(:stdout)
        assert_equal report, result.fetch(:stderr)
        assert_equal [expected_invocation(workspace, file)], invocations(workspace)
        assert_log_entry(workspace, file:, outcome: "findings")
      end
    end

    def test_first_failed_fast_check_notifies_and_keeps_the_edit
      with_workspace do |workspace|
        file = ruby_file(workspace)
        append_log_entry(workspace, file:, outcome: "clean")

        result = invoke_hook(workspace, hook_input(workspace, file), "FAKE_STDOUT" => "not json")

        assert_equal 2, result.fetch(:status).exitstatus
        assert_empty result.fetch(:stdout)
        assert_equal UNAVAILABLE_NOTICE, result.fetch(:stderr)
        assert_equal "class Example; end\n", File.read(file)
        assert_equal %w[clean unavailable], log_outcomes(workspace)
      end
    end

    def test_failed_fast_check_without_a_prior_log_notifies
      with_workspace do |workspace|
        file = ruby_file(workspace)

        result = invoke_hook(workspace, hook_input(workspace, file), "FAKE_STDOUT" => "not json")

        assert_equal 2, result.fetch(:status).exitstatus
        assert_empty result.fetch(:stdout)
        assert_equal UNAVAILABLE_NOTICE, result.fetch(:stderr)
        assert_log_entry(workspace, file:, outcome: "unavailable")
      end
    end

    def test_repeated_failed_fast_check_stays_silent
      with_workspace do |workspace|
        file = ruby_file(workspace)
        append_log_entry(workspace, file:, outcome: "unavailable")

        result = invoke_hook(workspace, hook_input(workspace, file), "FAKE_STDOUT" => "not json")

        assert_predicate result.fetch(:status), :success?
        assert_empty result.fetch(:stdout)
        assert_empty result.fetch(:stderr)
        assert_equal %w[unavailable unavailable], log_outcomes(workspace)
      end
    end

    def test_invalid_trailing_log_records_do_not_suppress_the_first_notice
      cases = {
        "malformed JSON" => "{not-json\n".b,
        "invalid UTF-8" => "\xFF\n".b
      }

      cases.each do |label, bytes|
        with_workspace do |workspace|
          file = ruby_file(workspace)
          write_hook_log(workspace, bytes)

          result = unavailable_hook_result(workspace, file)

          assert_first_unavailable_notice(result, label)
          assert_equal "unavailable", JSON.parse(File.binread(hook_log_path(workspace)).lines.last).fetch("outcome")
        end
      end
    end

    def test_oversized_valid_looking_log_record_does_not_suppress_the_first_notice
      with_workspace do |workspace|
        file = ruby_file(workspace)
        oversized = encoded_log_entry(file:, outcome: "unavailable", padding: "x" * MAX_LOG_LINE_BYTES)
        write_hook_log(workspace, "#{oversized}\n".b)

        result = unavailable_hook_result(workspace, file)

        assert_first_unavailable_notice(result)
      end
    end

    def test_unavailable_outcome_before_the_tail_window_does_not_suppress_the_first_notice
      with_workspace do |workspace|
        file = ruby_file(workspace)
        unavailable = encoded_log_entry(file:, outcome: "unavailable")
        outside_window = "x" * (MAX_LOG_SCAN_BYTES + 1)
        write_hook_log(workspace, "#{unavailable}\n#{outside_window}\n".b)

        result = unavailable_hook_result(workspace, file)

        assert_first_unavailable_notice(result)
      end
    end

    def test_complete_unavailable_outcome_at_the_tail_window_boundary_suppresses_the_notice
      with_workspace do |workspace|
        file = ruby_file(workspace)
        unavailable = encoded_log_entry(file:, outcome: "unavailable")
        filler = "x" * (MAX_LOG_SCAN_BYTES - unavailable.bytesize - 2)
        write_hook_log(workspace, "outside\n#{unavailable}\n#{filler}\n".b)

        result = unavailable_hook_result(workspace, file)

        assert_predicate result.fetch(:status), :success?
        assert_empty result.fetch(:stdout)
        assert_empty result.fetch(:stderr)
      end
    end

    def test_malformed_finding_objects_fail_open_as_unavailable
      cases = {
        "missing fields" => {},
        "wrong field type" => valid_finding.merge("tool" => 7),
        "negative line" => valid_finding.merge("line" => -1),
        "unknown severity" => valid_finding.merge("severity" => "critical"),
        "tool failure under a clean summary" => valid_finding.merge("rule" => "tool_failure")
      }

      cases.each do |label, finding|
        with_workspace do |workspace|
          file = ruby_file(workspace)
          append_log_entry(workspace, file:, outcome: "unavailable")
          result = invoke_hook(
            workspace,
            hook_input(workspace, file),
            "FAKE_EXIT" => "1",
            "FAKE_STDOUT" => report_with(finding)
          )

          assert_predicate result.fetch(:status), :success?, label
          assert_empty result.fetch(:stdout), label
          assert_empty result.fetch(:stderr), label
          assert_equal [expected_invocation(workspace, file)], invocations(workspace), label
          assert_equal %w[unavailable unavailable], log_outcomes(workspace)
        end
      end
    end

    def test_invalid_fast_check_results_fail_open_as_unavailable
      cases = {
        "invalid JSON" => { "FAKE_STDOUT" => "not json" },
        "wrong JSON shape" => { "FAKE_STDOUT" => JSON.generate("findings" => {}, "summary" => {}) },
        "tool-failure exit" => { "FAKE_EXIT" => "2" },
        "unexpected exit" => { "FAKE_EXIT" => "3" },
        "findings on a clean exit" => { "FAKE_STDOUT" => findings_report },
        "no findings on a findings exit" => { "FAKE_EXIT" => "1" },
        "summary count mismatch" => { "FAKE_STDOUT" => mismatched_report },
        "summary tool failure" => { "FAKE_STDOUT" => tool_failure_report },
        "signal" => { "FAKE_SIGNAL" => "TERM" }
      }

      cases.each do |label, environment|
        with_workspace do |workspace|
          file = ruby_file(workspace)
          append_log_entry(workspace, file:, outcome: "unavailable")
          result = invoke_hook(
            workspace,
            hook_input(workspace, file),
            { "FAKE_STDERR" => "internal failure" }.merge(environment)
          )

          assert_predicate result.fetch(:status), :success?, label
          assert_empty result.fetch(:stdout), label
          assert_empty result.fetch(:stderr), label
          assert_equal [expected_invocation(workspace, file)], invocations(workspace), label
          assert_equal %w[unavailable unavailable], log_outcomes(workspace)
        end
      end
    end

    def test_valid_tool_failure_report_on_exit_two_fails_open_as_unavailable
      with_workspace do |workspace|
        file = ruby_file(workspace)
        append_log_entry(workspace, file:, outcome: "unavailable")

        result = invoke_hook(
          workspace,
          hook_input(workspace, file),
          "FAKE_EXIT" => "2",
          "FAKE_STDOUT" => tool_failure_report
        )

        assert_predicate result.fetch(:status), :success?
        assert_empty result.fetch(:stdout)
        assert_empty result.fetch(:stderr)
        assert_equal [expected_invocation(workspace, file)], invocations(workspace)
        assert_equal %w[unavailable unavailable], log_outcomes(workspace)
      end
    end

    def test_bundler_style_exit_one_without_json_fails_open_as_unavailable
      with_workspace do |workspace|
        file = ruby_file(workspace)
        append_log_entry(workspace, file:, outcome: "unavailable")

        result = invoke_hook(
          workspace,
          hook_input(workspace, file),
          "FAKE_EXIT" => "1",
          "FAKE_STDOUT" => "",
          "FAKE_STDERR" => "Could not find gem 'missing' in locally installed gems."
        )

        assert_predicate result.fetch(:status), :success?
        assert_empty result.fetch(:stdout)
        assert_empty result.fetch(:stderr)
        assert_equal [expected_invocation(workspace, file)], invocations(workspace)
        assert_equal %w[unavailable unavailable], log_outcomes(workspace)
      end
    end

    def test_spawn_error_fails_open_as_unavailable
      with_workspace do |workspace|
        file = ruby_file(workspace)
        append_log_entry(workspace, file:, outcome: "unavailable")

        result = invoke_hook(
          workspace,
          hook_input(workspace, file),
          "PATH" => workspace.fetch(:process)
        )

        assert_predicate result.fetch(:status), :success?
        assert_empty result.fetch(:stdout)
        assert_empty result.fetch(:stderr)
        assert_empty invocations(workspace)
        assert_equal %w[unavailable unavailable], log_outcomes(workspace)
      end
    end

    def test_each_invocation_appends_one_complete_log_line
      with_workspace do |workspace|
        file = ruby_file(workspace)
        input = hook_input(workspace, file)

        2.times do
          result = invoke_hook(workspace, input)
          assert_predicate result.fetch(:status), :success?
        end

        assert_equal 2, invocations(workspace).length
        outcomes = log_entries(workspace).map { _1.fetch("outcome") }
        assert_equal %w[clean clean], outcomes
      end
    end

    def test_new_log_file_respects_a_restrictive_umask
      with_workspace do |workspace|
        result = invoke_hook(
          workspace,
          hook_input(workspace, ruby_file(workspace)),
          {},
          umask: 0o077
        )

        assert_predicate result.fetch(:status), :success?
        log = File.join(workspace.fetch(:project), "log/quality_gate_hooks.jsonl")
        assert_equal 0o600, File.stat(log).mode & 0o777
      end
    end

    def test_missing_fiddle_preserves_findings_feedback_and_skips_logging
      with_workspace do |workspace|
        ruby_lib = File.join(workspace.fetch(:root), "ruby-lib")
        FileUtils.mkdir_p(File.join(ruby_lib, "fiddle"))
        File.write(File.join(ruby_lib, "fiddle/import.rb"), "raise LoadError, \"fiddle unavailable\"\n")
        report = findings_report

        result = invoke_hook(
          workspace,
          hook_input(workspace, ruby_file(workspace)),
          "FAKE_EXIT" => "1",
          "FAKE_STDOUT" => report,
          "RUBYLIB" => ruby_lib
        )

        assert_equal 2, result.fetch(:status).exitstatus
        assert_empty result.fetch(:stdout)
        assert_equal report, result.fetch(:stderr)
        refute_path_exists File.join(workspace.fetch(:project), "log")
      end
    end

    def test_log_descriptor_close_errors_preserve_findings_feedback
      with_workspace do |workspace|
        helper = File.join(workspace.fetch(:root), "raise-on-hook-log-close.rb")
        File.write(helper, raise_on_hook_log_close)
        report = findings_report

        result = invoke_hook(
          workspace,
          hook_input(workspace, ruby_file(workspace)),
          "FAKE_EXIT" => "1",
          "FAKE_STDOUT" => report,
          "RUBYOPT" => "-r#{helper}"
        )

        assert_equal 2, result.fetch(:status).exitstatus
        assert_empty result.fetch(:stdout)
        assert_equal report, result.fetch(:stderr)
      end
    end

    def test_symlinked_log_directory_does_not_append_outside_the_project
      with_workspace do |workspace|
        outside = File.join(workspace.fetch(:process), "outside-log")
        sentinel = File.join(outside, "quality_gate_hooks.jsonl")
        FileUtils.mkdir_p(outside)
        File.write(sentinel, "outside sentinel\n")
        File.symlink(outside, File.join(workspace.fetch(:project), "log"))
        file = ruby_file(workspace)
        report = findings_report

        result = invoke_hook(
          workspace,
          hook_input(workspace, file),
          "FAKE_EXIT" => "1",
          "FAKE_STDOUT" => report
        )

        assert_equal 2, result.fetch(:status).exitstatus
        assert_equal report, result.fetch(:stderr)
        assert_equal "outside sentinel\n", File.read(sentinel)
        assert_path_exists File.join(workspace.fetch(:project), "log")
        assert File.symlink?(File.join(workspace.fetch(:project), "log"))
      end
    end

    def test_symlinked_log_directory_cannot_suppress_the_first_unavailable_notice
      with_workspace do |workspace|
        file = ruby_file(workspace)
        outside = File.join(workspace.fetch(:process), "outside-log")
        target = File.join(outside, "quality_gate_hooks.jsonl")
        FileUtils.mkdir_p(outside)
        original = "#{encoded_log_entry(file:, outcome: "unavailable")}\n"
        File.binwrite(target, original)
        File.symlink(outside, File.join(workspace.fetch(:project), "log"))

        result = unavailable_hook_result(workspace, file)

        assert_first_unavailable_notice(result)
        assert_equal original, File.binread(target)
      end
    end

    def test_symlinked_log_leaf_does_not_append_to_its_target
      with_workspace do |workspace|
        outside = File.join(workspace.fetch(:process), "outside.jsonl")
        leaf = File.join(workspace.fetch(:project), "log/quality_gate_hooks.jsonl")
        FileUtils.mkdir_p(File.dirname(leaf))
        File.write(outside, "outside sentinel\n")
        File.symlink(outside, leaf)

        result = invoke_hook(workspace, hook_input(workspace, ruby_file(workspace)))

        assert_predicate result.fetch(:status), :success?
        assert_empty result.fetch(:stdout)
        assert_empty result.fetch(:stderr)
        assert_equal "outside sentinel\n", File.read(outside)
        assert File.symlink?(leaf)
      end
    end

    def test_symlinked_log_leaf_cannot_suppress_the_first_unavailable_notice
      with_workspace do |workspace|
        file = ruby_file(workspace)
        outside = File.join(workspace.fetch(:process), "outside.jsonl")
        leaf = hook_log_path(workspace)
        FileUtils.mkdir_p(File.dirname(leaf))
        original = "#{encoded_log_entry(file:, outcome: "unavailable")}\n"
        File.binwrite(outside, original)
        File.symlink(outside, leaf)

        result = unavailable_hook_result(workspace, file)

        assert_first_unavailable_notice(result)
        assert_equal original, File.binread(outside)
      end
    end

    def test_hard_linked_log_leaf_does_not_append_to_its_other_name
      with_workspace do |workspace|
        outside = File.join(workspace.fetch(:process), "outside.jsonl")
        leaf = File.join(workspace.fetch(:project), "log/quality_gate_hooks.jsonl")
        FileUtils.mkdir_p(File.dirname(leaf))
        File.write(outside, "outside sentinel\n")
        File.link(outside, leaf)

        result = invoke_hook(workspace, hook_input(workspace, ruby_file(workspace)))

        assert_predicate result.fetch(:status), :success?
        assert_empty result.fetch(:stdout)
        assert_empty result.fetch(:stderr)
        assert_equal "outside sentinel\n", File.read(outside)
        assert_equal File.stat(outside).ino, File.stat(leaf).ino
      end
    end

    def test_multiply_linked_log_leaf_cannot_suppress_the_first_unavailable_notice
      with_workspace do |workspace|
        file = ruby_file(workspace)
        outside = File.join(workspace.fetch(:process), "outside.jsonl")
        leaf = hook_log_path(workspace)
        FileUtils.mkdir_p(File.dirname(leaf))
        original = "#{encoded_log_entry(file:, outcome: "unavailable")}\n"
        File.binwrite(outside, original)
        File.link(outside, leaf)

        result = unavailable_hook_result(workspace, file)

        assert_first_unavailable_notice(result)
        assert_equal original, File.binread(outside)
      end
    end

    def test_log_write_failure_preserves_findings_feedback
      with_workspace do |workspace|
        File.write(File.join(workspace.fetch(:project), "log"), "blocks the log directory")
        file = ruby_file(workspace)
        report = findings_report

        result = invoke_hook(
          workspace,
          hook_input(workspace, file),
          "FAKE_EXIT" => "1",
          "FAKE_STDOUT" => report
        )

        assert_equal 2, result.fetch(:status).exitstatus
        assert_empty result.fetch(:stdout)
        assert_equal report, result.fetch(:stderr)
        assert_equal [expected_invocation(workspace, file)], invocations(workspace)
        assert_equal "blocks the log directory", File.read(File.join(workspace.fetch(:project), "log"))
      end
    end

    def test_non_system_log_path_error_still_fails_open
      with_workspace do |workspace|
        file = ruby_file(workspace)
        input = { "cwd" => "invalid\0cwd", "tool_input" => { "file_path" => file } }

        result = invoke_hook(workspace, input)

        assert_equal 2, result.fetch(:status).exitstatus
        assert_empty result.fetch(:stdout)
        assert_equal UNAVAILABLE_NOTICE, result.fetch(:stderr)
      end
    end

    private

    def with_workspace
      Dir.mktmpdir("quality-gate-hook") do |root|
        project = File.join(root, "project")
        process = File.join(root, "process")
        bin = File.join(root, "bin")
        FileUtils.mkdir_p([project, process, bin])

        hook = File.join(process, "quality_gate_fast.rb")
        File.write(hook, rendered_template)
        File.write(File.join(bin, "bundle"), fake_bundle)
        FileUtils.chmod(0o755, File.join(bin, "bundle"))

        yield({ root:, project:, process:, bin:, hook:, invocation_log: File.join(root, "invocations.jsonl") })
      end
    end

    def invoke_hook(workspace, input, environment = {}, spawn_options = {})
      stdin_data = input.is_a?(String) ? input : JSON.generate(input)
      default_environment = {
        "PATH" => [workspace.fetch(:bin), ENV.fetch("PATH")].join(File::PATH_SEPARATOR),
        "BUNDLE_BIN_PATH" => nil,
        "BUNDLE_GEMFILE" => nil,
        # Exercise the standalone hook with Ruby's bundled gems, outside CI's bundle path.
        "GEM_HOME" => Gem.default_dir,
        "GEM_PATH" => Gem.default_dir,
        "RUBYLIB" => nil,
        "RUBYOPT" => nil,
        "INVOCATION_LOG" => workspace.fetch(:invocation_log),
        "FAKE_EXIT" => "0",
        "FAKE_STDOUT" => clean_report
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

    def hook_input(workspace, file)
      { "cwd" => workspace.fetch(:project), "tool_input" => { "file_path" => file } }
    end

    def ruby_file(workspace)
      File.join(workspace.fetch(:project), "app/models/example.rb").tap do |file|
        FileUtils.mkdir_p(File.dirname(file))
        File.write(file, "class Example; end\n")
      end
    end

    def expected_invocation(workspace, file)
      {
        "cwd" => File.realpath(workspace.fetch(:project)),
        "args" => ["exec", "quality_gate", "fast", "--files", file, "--format", "json"]
      }
    end

    def rendered_template
      assert File.file?(TEMPLATE), "expected hook template at #{TEMPLATE}"

      InstallGenerator.new.send(:rendered_template, File.basename(TEMPLATE))
    end

    def fake_bundle
      <<~RUBY
        #!#{RbConfig.ruby}
        require "json"

        File.open(ENV.fetch("INVOCATION_LOG"), "a") do |io|
          io.puts(JSON.generate("cwd" => Dir.pwd, "args" => ARGV))
        end
        Process.kill(ENV.fetch("FAKE_SIGNAL"), Process.pid) if ENV["FAKE_SIGNAL"]
        $stdout.write(ENV.fetch("FAKE_STDOUT", ""))
        $stderr.write(ENV.fetch("FAKE_STDERR", ""))
        exit(Integer(ENV.fetch("FAKE_EXIT", "0")))
      RUBY
    end

    def raise_on_hook_log_close
      <<~RUBY
        File.singleton_class.prepend(Module.new do
          def for_fd(...)
            super.tap { _1.instance_variable_set(:@raise_on_hook_log_close, true) }
          end
        end)

        File.prepend(Module.new do
          def close
            raise_on_close = instance_variable_defined?(:@raise_on_hook_log_close)
            super
            raise IOError, "forced hook log close failure" if raise_on_close
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

    def invocations(workspace)
      path = workspace.fetch(:invocation_log)
      return [] unless File.file?(path)

      File.readlines(path, chomp: true).map { JSON.parse(_1) }
    end

    def append_log_entry(workspace, file:, outcome:)
      path = hook_log_path(workspace)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "a") { _1.puts(encoded_log_entry(file:, outcome:)) }
    end

    def encoded_log_entry(file:, outcome:, padding: nil)
      entry = {
        "ts" => "2026-09-01T00:00:00.000000Z",
        "file" => file,
        "outcome" => outcome,
        "duration_ms" => 1
      }
      entry["padding"] = padding if padding
      JSON.generate(entry)
    end

    def write_hook_log(workspace, bytes)
      path = hook_log_path(workspace)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, bytes)
    end

    def hook_log_path(workspace)
      File.join(workspace.fetch(:project), "log/quality_gate_hooks.jsonl")
    end

    def unavailable_hook_result(workspace, file)
      invoke_hook(workspace, hook_input(workspace, file), "FAKE_STDOUT" => "not json")
    end

    def assert_first_unavailable_notice(result, message = nil)
      assert_equal 2, result.fetch(:status).exitstatus, message
      assert_empty result.fetch(:stdout), message
      assert_equal UNAVAILABLE_NOTICE, result.fetch(:stderr), message
    end

    def log_outcomes(workspace)
      log_entries(workspace).map { _1.fetch("outcome") }
    end

    def log_entries(workspace, root: :project)
      path = File.join(workspace.fetch(root), "log/quality_gate_hooks.jsonl")
      return [] unless File.file?(path)

      File.readlines(path, chomp: true).map { JSON.parse(_1) }
    end

    def assert_log_entry(workspace, file:, outcome:, root: :project)
      entries = log_entries(workspace, root:)
      assert_equal 1, entries.length

      entry = entries.first
      assert_equal %w[duration_ms file outcome ts], entry.keys.sort
      file.nil? ? assert_nil(entry.fetch("file")) : assert_equal(file, entry.fetch("file"))
      assert_equal outcome, entry.fetch("outcome")
      assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\z/, entry.fetch("ts"))
      assert_kind_of Numeric, entry.fetch("duration_ms")
      assert_operator entry.fetch("duration_ms"), :>=, 0
    end
  end
  # rubocop:enable Metrics/AbcSize
end
