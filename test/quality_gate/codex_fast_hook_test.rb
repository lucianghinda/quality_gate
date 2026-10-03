# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "quality_gate/codex_fast_hook"

module QualityGate
  class CodexFastHookTest < Minitest::Test
    def setup
      @directory = Dir.mktmpdir("codex-fast")
      @root = File.join(@directory, "project")
      FileUtils.mkdir_p(File.join(@root, "nested/deep"))
      @cwd = File.join(@root, "nested/deep")
      @cli_call_count = 0
    end

    def teardown
      FileUtils.remove_entry(@directory)
    end

    def test_runs_one_fast_gate_for_added_and_updated_ruby_files_from_nested_cwd
      first = write("nested/deep/one.rb")
      second = write("nested/two.rb")
      patch = <<~PATCH
        *** Begin Patch
        *** Add File: one.rb
        +puts :one
        *** Update File: ../two.rb
        @@
        -puts :old
        +puts :new
        *** End Patch
      PATCH

      response = invoke(patch)

      assert_equal({}, response)
      assert_equal ["fast", "--format", "json", "--files", first, second], @cli_call.fetch(0)
      assert_equal @root, @cli_call.fetch(3)
      assert_instance_of StringIO, @cli_call.fetch(1)
      assert_instance_of StringIO, @cli_call.fetch(2)
      assert_equal 1, @cli_call_count
    end

    def test_move_uses_destination_and_deleted_or_missing_files_are_skipped
      destination = write("nested/deep/moved.rb")
      patch = <<~PATCH
        *** Begin Patch
        *** Update File: old.rb
        *** Move to: moved.rb
        *** Delete File: removed.rb
        *** End Patch
      PATCH

      invoke(patch)

      assert_equal ["fast", "--format", "json", "--files", destination], @cli_call.fetch(0)
    end

    def test_mixed_ruby_and_erb_only_selects_erb_when_herb_is_configured
      ruby = write("nested/deep/change.rb")
      erb = write("nested/deep/view.erb")
      File.write(File.join(@root, ".quality_gate.yml"), "adapters:\n  fast: [rubocop, herb]\n")
      patch = <<~PATCH
        *** Begin Patch
        *** Update File: change.rb
        @@
        +puts :ok
        *** Update File: view.erb
        @@
        +<p>ok</p>
        *** End Patch
      PATCH

      invoke(patch)

      assert_equal ["fast", "--format", "json", "--files", ruby, erb], @cli_call.fetch(0)
    end

    def test_mixed_ruby_and_erb_without_herb_checks_only_ruby
      ruby = write("nested/deep/change.rb")
      write("nested/deep/view.erb")
      patch = <<~PATCH
        *** Begin Patch
        *** Update File: change.rb
        *** Update File: view.erb
        *** End Patch
      PATCH

      invoke(patch)

      assert_equal ["fast", "--format", "json", "--files", ruby], @cli_call.fetch(0)
    end

    def test_erb_without_herb_is_an_irrelevant_edit_without_loading_gate
      write("nested/deep/view.erb")

      response = invoke(patch_for("view.erb"))

      assert_equal({}, response)
      refute defined?(@cli_call)
    end

    def test_missing_or_outside_erb_does_not_load_invalid_configuration
      File.write(File.join(@root, ".quality_gate.yml"), "adapters: [invalid\n")
      outside_erb = File.join(@directory, "outside.erb")

      assert_equal({}, invoke(patch_for("deleted.erb")))
      assert_equal({}, invoke(patch_for(outside_erb)))
      refute defined?(@cli_call)
    end

    def test_duplicate_leading_dash_and_spaced_paths_are_passed_as_absolute_arguments
      spaced = write("nested/deep/a space.rb")
      leading_dash = write("nested/deep/-strange.rb")
      patch = <<~PATCH
        *** Begin Patch
        *** Update File: a space.rb
        *** Update File: a space.rb
        *** Update File: -strange.rb
        *** End Patch
      PATCH

      invoke(patch)

      assert_equal ["fast", "--format", "json", "--files", spaced, leading_dash], @cli_call.fetch(0)
    end

    def test_hunk_content_that_looks_like_a_path_header_is_not_selected
      actual = write("nested/deep/change.rb")
      patch = <<~PATCH
        *** Begin Patch
        *** Update File: change.rb
        @@
        +*** Add File: bogus.rb
        *** End Patch
      PATCH

      invoke(patch)

      assert_equal ["fast", "--format", "json", "--files", actual], @cli_call.fetch(0)
    end

    def test_update_patch_with_native_end_of_file_marker_is_accepted
      actual = write("nested/deep/change.rb")
      patch = "*** Begin Patch\n*** Update File: change.rb\n@@\n puts :ok\n*** End of File\n*** End Patch\n"

      invoke(patch)

      assert_equal ["fast", "--format", "json", "--files", actual], @cli_call.fetch(0)
    end

    def test_detached_or_too_late_move_header_is_unavailable
      write("nested/deep/change.rb")
      [
        "*** Begin Patch\n*** Move to: moved.rb\n*** Update File: change.rb\n*** End Patch\n",
        "*** Begin Patch\n*** Update File: change.rb\n@@\n+puts :changed\n*** Move to: moved.rb\n*** End Patch\n"
      ].each do |patch|
        response = invoke(patch)
        assert_match(/unavailable/i, response.fetch("systemMessage"))
        refute response.key?("decision")
        refute response.key?("continue")
      end
    end

    def test_unknown_structural_header_and_detached_content_are_unavailable
      write("nested/deep/change.rb")
      patches = [
        "*** Begin Patch\n*** Update File: change.rb\n*** Surprise: data\n*** End Patch\n",
        "*** Begin Patch\nputs :detached\n*** Update File: change.rb\n*** End Patch\n"
      ]

      patches.each do |patch|
        assert_unavailable_input(event(patch))
      end
    end

    def test_end_of_file_marker_outside_update_hunk_is_unavailable
      patches = [
        "*** Begin Patch\n*** End of File\n*** Update File: change.rb\n*** End Patch\n",
        "*** Begin Patch\n*** Update File: change.rb\n*** End of File\n*** End Patch\n",
        "*** Begin Patch\n*** Add File: change.rb\n*** End of File\n*** End Patch\n"
      ]

      patches.each { assert_unavailable_input(event(_1)) }
    end

    def test_empty_patch_is_unavailable
      assert_unavailable_input(event("*** Begin Patch\n*** End Patch\n"))
    end

    def test_event_cwd_outside_project_is_unavailable
      input = event(patch_for("change.rb")).merge("cwd" => @directory)
      assert_unavailable_response(QualityGate::CodexFastHook.new(dir: @root).call(input))
      assert_equal 0, @cli_call_count
    end

    def test_file_removed_during_resolution_is_skipped
      file = write("nested/deep/change.rb")
      realpath = File.method(:realpath)
      resolver = lambda do |path, *arguments|
        raise Errno::ENOENT if path == file

        realpath.call(path, *arguments)
      end

      response = File.stub(:realpath, resolver) do
        QualityGate::CodexFastHook.new(dir: @root).call(event(patch_for("change.rb")))
      end

      assert_equal({}, response)
      assert_equal 0, @cli_call_count
    end

    def test_outside_paths_and_symlinks_escaping_project_are_ignored
      outside = File.join(@directory, "outside.rb")
      File.write(outside, "puts :outside")
      File.symlink(outside, File.join(@root, "nested/deep/escape.rb"))
      patch = <<~PATCH
        *** Begin Patch
        *** Update File: #{outside}
        *** Update File: escape.rb
        *** End Patch
      PATCH

      assert_equal({}, invoke(patch))
      refute defined?(@cli_call)
    end

    def test_irrelevant_and_missing_files_do_not_invoke_gate
      write("nested/deep/readme.md")

      assert_equal({}, invoke(patch_for("readme.md")))
      refute defined?(@cli_call)
      assert_equal({}, invoke(patch_for("deleted.rb")))
      refute defined?(@cli_call)
    end

    def test_invalid_event_payload_and_malformed_patch_are_visible_unavailable
      invalid_inputs.each { assert_unavailable_input(_1) }
    end

    def test_findings_missing_required_fields_or_wrong_type_are_unavailable
      write("nested/deep/change.rb")
      [report([{}]), report([nil])].each do |output|
        assert_unavailable_response(invoke(patch_for("change.rb"), report: output))
      end
    end

    def test_missing_or_nonmapping_summary_is_unavailable
      write("nested/deep/change.rb")
      [nil, []].each do |summary|
        output = JSON.generate("findings" => [], "summary" => summary)
        assert_unavailable_response(invoke(patch_for("change.rb"), report: output))
      end
    end

    def test_findings_are_actionable_and_do_not_block_or_continue
      write("nested/deep/change.rb")
      response = invoke(patch_for("change.rb"), status: 1, report: report([finding]))
      context = response.fetch("hookSpecificOutput").fetch("additionalContext")
      assert_equal "PostToolUse", response.fetch("hookSpecificOutput").fetch("hookEventName")
      assert_includes context, "nested/deep/change.rb:4 [rubocop/Style/Test] fix this"
      refute response.key?("decision")
      refute response.key?("continue")
    end

    def test_clean_report_returns_empty_response
      write("nested/deep/change.rb")
      assert_equal({}, invoke(patch_for("change.rb"), status: 0, report: report([])))
    end

    def test_tool_failure_report_is_unavailable
      write("nested/deep/change.rb")
      unavailable = invoke(patch_for("change.rb"), status: 2, report: report([]))
      assert_unavailable_response(unavailable)
    end

    def test_cli_exception_is_unavailable
      write("nested/deep/change.rb")
      QualityGate::CLI.stub(:run, proc { raise "broken" }) do
        assert_unavailable_response(QualityGate::CodexFastHook.new(dir: @root).call(event(patch_for("change.rb"))))
      end
    end

    def test_malformed_or_inconsistent_gate_report_is_unavailable
      write("nested/deep/change.rb")
      ["not json", JSON.generate([]), report([], count: 1), report([], failures: 1)].each do |output|
        response = invoke(patch_for("change.rb"), report: output)
        assert_unavailable_response(response)
      end
    end

    def test_exit_status_must_match_report
      write("nested/deep/change.rb")
      assert_unavailable_response(invoke(patch_for("change.rb"), status: 0, report: report([finding])))
      assert_unavailable_response(invoke(patch_for("change.rb"), status: 1, report: report([])))
    end

    private

    def write(relative)
      path = File.join(@root, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "puts :ok\n")
      File.realpath(path)
    end

    def patch_for(path)
      "*** Begin Patch\n*** Update File: #{path}\n*** End Patch\n"
    end

    def event(patch, name: "PostToolUse")
      { "hook_event_name" => name, "tool_name" => "apply_patch",
        "tool_input" => { "command" => patch }, "cwd" => @cwd }
    end

    def invoke(patch, status: 0, report: report([]))
      QualityGate::CLI.stub(:run, lambda do |argv, stdout:, stderr:, dir:|
        @cli_call_count += 1
        @cli_call = [argv, stdout, stderr, dir]
        stdout.write(report)
        status
      end) do
        QualityGate::CodexFastHook.new(dir: @root).call(event(patch))
      end
    end

    def report(findings, count: findings.length, failures: 0)
      JSON.generate(
        "findings" => findings,
        "summary" => { "findings" => count, "tool_failures" => failures, "failed_tools" => [] }
      )
    end

    def invalid_inputs
      malformed_patch = "*** Begin Patch\n*** Delete File: bad.rb\n"
      patch = patch_for("change.rb")
      [
        event("", name: "Other"), event(malformed_patch), event(patch).merge("cwd" => "relative"),
        event(patch).merge("tool_input" => { "command" => 7 }), event(patch).merge("tool_input" => []),
        event(patch).merge("tool_input" => "malformed")
      ]
    end

    def assert_unavailable_input(input)
      response = QualityGate::CodexFastHook.new(dir: @root).call(input)
      assert_unavailable_response(response)
    end

    def assert_unavailable_response(response)
      assert_match(/unavailable/i, response.fetch("systemMessage"))
      assert_includes response.fetch("hookSpecificOutput").fetch("additionalContext"), "manual"
      refute response.key?("decision")
      refute response.key?("continue")
    end

    def finding
      { "tool" => "rubocop", "file" => "nested/deep/change.rb", "line" => 4,
        "rule" => "Style/Test", "severity" => "warning", "message" => "fix this" }
    end
  end
end
