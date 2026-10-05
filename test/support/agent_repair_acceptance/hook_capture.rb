# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "time"

module AgentRepairAcceptance
  # Captures an installed hook invocation while preserving its process boundary.
  class HookCapture
    def initialize(argv:, streams:, env: ENV, event: nil)
      @argv = argv
      @stdin, @stdout, @stderr = streams
      @env = env
      @event = event
    end

    def call
      return 2 unless valid_configuration?

      input = stdin.read
      before = hook_log_size
      invocation = run_original(input, before)
      forward(invocation)
      record(invocation)
      exit_status(invocation.fetch(:process_status))
    rescue StandardError => e
      stderr.write("Quality Gate hook capture failed: #{e.message}\n")
      2
    end

    private

    attr_reader :argv, :stdin, :stdout, :stderr, :env, :event

    def run_original(input, before)
      { input:, before:, started_at: Time.now.utc.iso8601(6),
        output: nil, error: nil, process_status: nil }.tap do |invocation|
        invocation[:output], invocation[:error], invocation[:process_status] =
          Open3.capture3(*spawn_argv, stdin_data: input)
        invocation[:completed_at] = Time.now.utc.iso8601(6)
      end
    end

    def forward(invocation)
      stdout.write(invocation.fetch(:output))
      stderr.write(invocation.fetch(:error))
    end

    def spawn_argv
      [[argv.first, argv.first], *argv.drop(1)]
    end

    def exit_status(status)
      status.exitstatus || 128 + status.termsig
    end

    def valid_configuration?
      argv.is_a?(Array) && !argv.empty? && argv.all? { _1.is_a?(String) } &&
        env["QUALITY_GATE_HOOK_CAPTURE_PATH"].is_a?(String) &&
        %w[claude codex].include?(env["QUALITY_GATE_HOOK_CLIENT"])
    end

    def record(invocation)
      payload = JSON.parse(invocation.fetch(:input))
      root = env.fetch("QUALITY_GATE_HOOK_ROOT")
      raise ArgumentError, "native hook event does not match wrapper" if event && payload["hook_event_name"] != event

      details = hook_details(payload, invocation, root)
      details["synthetic"] = true if env["AGENT_REPAIR_ACCEPTANCE_SYNTHETIC"] == "1"
      write_record(details)
    end

    def write_record(details)
      File.open(env.fetch("QUALITY_GATE_HOOK_CAPTURE_PATH"), "a") { _1.write(JSON.generate(details), "\n") }
    end

    def hook_details(payload, invocation, root)
      client_metadata(payload).merge(invocation_metadata(invocation)).merge(source_metadata(root, invocation))
    end

    def client_metadata(payload)
      { "client" => env.fetch("QUALITY_GATE_HOOK_CLIENT"), "event" => payload["hook_event_name"],
        "session_id" => payload["session_id"] || payload["thread_id"],
        "tool_name" => payload["tool_name"], "tool_use_id" => payload["tool_use_id"],
        "changed_paths" => changed_paths(payload) }
    end

    def changed_paths(payload)
      return [] unless env["QUALITY_GATE_HOOK_CLIENT"] == "codex"

      command = payload.dig("tool_input", "command")
      return [] unless command.is_a?(String)

      command.scan(/^\*\*\* (?:Update|Add|Delete) File: ([^\n]+)$/).flatten.uniq.filter_map do |path|
        path.delete_prefix("#{env.fetch("QUALITY_GATE_HOOK_ROOT")}/")
      end
    end

    def invocation_metadata(invocation)
      { "started_at" => invocation.fetch(:started_at), "completed_at" => invocation.fetch(:completed_at),
        "status" => exit_status(invocation.fetch(:process_status)),
        "stdout" => invocation.fetch(:output), "stderr" => invocation.fetch(:error) }
    end

    def source_metadata(root, invocation)
      { "source_sha256" => file_digest(root, "lib/calculator.rb"), "test_sha256" => digest_map(root, "test"),
        "hook_log" => appended_hook_log(invocation.fetch(:before)) }
    end

    def file_digest(root, relative)
      path = File.join(root, relative)
      File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil
    end

    def digest_map(root, relative)
      base = File.join(root, relative)
      return {} unless File.directory?(base)

      Dir.glob(File.join(base, "**", "*.rb")).sort.to_h do |path|
        [path.delete_prefix("#{root}/"), Digest::SHA256.file(path).hexdigest]
      end
    end

    def hook_log_path
      File.join(env.fetch("QUALITY_GATE_HOOK_ROOT"), "log/quality_gate_hooks.jsonl")
    end

    def hook_log_size
      File.size?(hook_log_path) || 0
    rescue SystemCallError
      0
    end

    def appended_hook_log(offset)
      return [] unless File.file?(hook_log_path)

      File.binread(hook_log_path, File.size(hook_log_path) - offset, offset).lines.filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  client, event, root, capture_path, delimiter, *command = ARGV
  exit 2 unless %w[claude codex].include?(client) && %w[PostToolUse Stop].include?(event) &&
                root && capture_path && delimiter == "--" && !command.empty?

  ENV["QUALITY_GATE_HOOK_CLIENT"] = client
  ENV["QUALITY_GATE_HOOK_ROOT"] = root
  ENV["QUALITY_GATE_HOOK_CAPTURE_PATH"] = capture_path
  exit AgentRepairAcceptance::HookCapture.new(
    argv: command, streams: [$stdin, $stdout, $stderr], event:
  ).call
end
