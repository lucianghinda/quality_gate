# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"

require_relative "../test_helper"
require_relative "../support/agent_repair_acceptance/hook_capture"

class AgentRepairHookCaptureTest < Minitest::Test
  def test_recorder_forwards_exact_input_output_and_exit_status
    output, error, status, record = capture_invocation

    assert_equal "{\"systemMessage\":\"feedback\"}\n", output
    assert_equal "err", error
    assert_equal 7, status
    assert_equal "synthetic-session", record.fetch("session_id")
    assert_equal "Edit", record.fetch("tool_name")
    assert record.fetch("synthetic")
  end

  def test_recorder_refuses_to_claim_success_when_capture_cannot_be_written
    status = AgentRepairAcceptance::HookCapture.new(
      argv: [RbConfig.ruby, "-e", "STDIN.read"], streams: [StringIO.new("{}"), StringIO.new, StringIO.new],
      env: { "QUALITY_GATE_HOOK_CAPTURE_PATH" => "/missing/hooks.jsonl", "QUALITY_GATE_HOOK_CLIENT" => "claude" }
    ).call

    assert_equal 2, status
  end

  def test_executable_uses_the_declared_client_event_root_and_original_command
    Dir.mktmpdir("agent repair root ") do |root|
      assert_equal "native-session", run_native_recorder(root).fetch("session_id")
    end
  end

  def test_executable_rejects_a_missing_delimiter_or_original_command
    recorder = File.expand_path("../support/agent_repair_acceptance/hook_capture.rb", __dir__)

    _stdout, _stderr, status = Open3.capture3(RbConfig.ruby, recorder, "claude", "PostToolUse", "/tmp",
                                              "/tmp/capture.jsonl", "command")

    assert_equal 2, status.exitstatus
  end

  def test_original_executable_path_with_spaces_is_spawned_directly
    output, status = capture_spaced_executable

    assert_equal "native hook", output
    assert_equal 0, status
  end

  private

  def capture_invocation
    Dir.mktmpdir do |dir|
      record_path = File.join(dir, "hooks.jsonl")
      output = "{\"systemMessage\":\"feedback\"}\n"
      stdout = StringIO.new
      stderr = StringIO.new
      status = run_capture(output, dir, record_path, [stdout, stderr])
      record = JSON.parse(File.read(record_path))
      [stdout.string, stderr.string, status, record]
    end
  end

  def run_capture(output, dir, record_path, output_streams)
    input = JSON.generate("session_id" => "synthetic-session", "tool_name" => "Edit")
    argv = [RbConfig.ruby, "-e", "STDIN.read; STDOUT.write(ARGV.fetch(0)); STDERR.write('err'); exit 7", output]
    streams = [StringIO.new(input), *output_streams]
    AgentRepairAcceptance::HookCapture.new(argv:, streams:, env: capture_env(record_path, dir)).call
  end

  def capture_env(record_path, root)
    { "QUALITY_GATE_HOOK_CAPTURE_PATH" => record_path, "QUALITY_GATE_HOOK_CLIENT" => "claude",
      "QUALITY_GATE_HOOK_ROOT" => root, "AGENT_REPAIR_ACCEPTANCE_SYNTHETIC" => "1" }
  end

  def run_native_recorder(root)
    prepare_recorder_root(root)
    FileUtils.mkdir_p(capture_directory(root))
    payload = JSON.generate("hook_event_name" => "PostToolUse", "session_id" => "native-session",
                            "tool_name" => "Edit", "tool_use_id" => "edit-1")
    command = recorder_command(root)
    stdout, stderr, status = capture_recorder(command, payload)
    assert_native_invocation(stdout, stderr, status, payload)

    read_recorder_record(root).tap do |record|
      assert_native_record(root, record)
    end
  end

  def assert_native_invocation(stdout, stderr, status, payload)
    raise "recorder did not preserve its command" unless status.success? && stdout == payload && stderr.empty?
  end

  def assert_native_record(root, record)
    raise "recorder identity did not match input" unless record["event"] == "PostToolUse"
    raise "recorder marked native input synthetic" if record.key?("synthetic")
    raise "capture path must stay outside the native workspace" if capture_directory(root).start_with?("#{root}/")
  end

  def capture_spaced_executable
    Dir.mktmpdir("agent repair executable ") do |root|
      executable = File.join(root, "native hook")
      File.write(executable, "#!#{RbConfig.ruby}\nSTDIN.read\nSTDOUT.write('native hook')\n")
      File.chmod(0o755, executable)
      output = StringIO.new
      payload = JSON.generate("session_id" => "spaced-session")
      streams = [StringIO.new(payload), output, StringIO.new]
      env = capture_env(File.join(root, "hooks.jsonl"), root)
      status = AgentRepairAcceptance::HookCapture.new(argv: [executable], streams:, env:).call
      [output.string, status]
    end
  end

  def prepare_recorder_root(root)
    FileUtils.mkdir_p(File.join(root, "lib"))
    File.write(File.join(root, "lib/calculator.rb"), "module Calculator; end\n")
  end

  def capture_recorder(command, payload)
    Open3.capture3(*command, stdin_data: payload)
  end

  def read_recorder_record(root)
    JSON.parse(File.read(File.join(capture_directory(root), "hooks.jsonl")))
  end

  def recorder_command(root)
    recorder = File.expand_path("../support/agent_repair_acceptance/hook_capture.rb", __dir__)
    [RbConfig.ruby, recorder, "claude", "PostToolUse", root, File.join(capture_directory(root), "hooks.jsonl"),
     "--", RbConfig.ruby, "-e", "STDOUT.write(STDIN.read)"]
  end

  def capture_directory(root)
    "#{root}.evidence"
  end
end
