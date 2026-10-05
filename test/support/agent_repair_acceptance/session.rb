# frozen_string_literal: true

module AgentRepairAcceptance
  class Session
    def initialize(root, timeout: 600)
      @root = Pathname(root).expand_path
      @evidence_root = AgentRepairAcceptance.evidence_root(@root)
      @timeout = timeout
    end

    def run
      reject_reused_trial!
      run_once
    end

    def validate_manifest!(manifest)
      validate_manifest_object!(manifest)
      validate_client!(manifest["client"])
      validate_scenario!(manifest["scenario"])
      validate_root!(manifest["root"])
      validate_prompt!(manifest["prompt"])
      validate_package!(manifest["package"])
      validate_timeout!
      unless Evidence.new({}).valid_manifest_for_session?(manifest)
        raise Error, "manifest is incomplete, invalid, or has unclean baselines"
      end

      true
    end

    private

    def run_once
      write_session(capture_session)
    rescue Error, SystemCallError, JSON::ParserError => e
      unavailable(e.message)
    end

    def capture_session
      manifest = JSON.parse(File.read(@evidence_root.join("manifest.json")))
      validate_manifest!(manifest)
      client = manifest.fetch("client")
      started_at = Time.now.utc.iso8601(6)
      command = client_command(client, manifest)
      version = client_version(client)
      result = capture(command, timeout: @timeout)
      session_record(started_at, version, command, result)
    end

    def session_record(started_at, version, command, result)
      {
        "kind" => "native", "client_version" => version, "command" => command,
        "started_at" => started_at, "completed_at" => Time.now.utc.iso8601(6),
        "status" => result.status, "stdout" => result.stdout, "stderr" => result.stderr,
        "timed_out" => result.timed_out, "extra_prompts" => 0
      }
    end

    def reject_reused_trial!
      %w[session.json hooks.jsonl final.json report.json].each do |filename|
        next unless @evidence_root.join(filename).exist?

        raise Error, "trial already has run output (#{filename}); use a fresh directory"
      end
    end

    def validate_manifest_object!(manifest)
      raise Error, "manifest must be a JSON object" unless manifest.is_a?(Hash)
      raise Error, "unsupported manifest schema" unless manifest["schema_version"] == 1
    end

    def validate_client!(client)
      raise Error, "client must be claude or codex" unless %w[claude codex].include?(client)
    end

    def validate_scenario!(scenario)
      return if AgentRepairAcceptance::SCENARIOS.include?(scenario)

      raise Error, "scenario must be fast or verify"
    end

    def validate_root!(root)
      raise Error, "manifest root must be a path string" unless valid_path_string?(root)
      return if File.expand_path(root) == @root.to_s

      raise Error, "manifest root mismatch"
    end

    def validate_prompt!(prompt)
      return if prompt.is_a?(String) && !prompt.empty? && !prompt.include?("\0")

      raise Error, "manifest prompt must be a non-empty string"
    end

    def validate_package!(package)
      return if package.is_a?(Hash) && valid_path_string?(package["resolved_path"])

      raise Error, "manifest package archive is no longer available"
    end

    def valid_path_string?(value)
      value.is_a?(String) && !value.empty? && !value.include?("\0")
    end

    def validate_timeout!
      return if @timeout.is_a?(Integer) && @timeout.positive?

      raise Error, "timeout must be a positive Integer"
    end

    def executable_for(client)
      command = client == "claude" ? "claude" : "codex"
      executable = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { File.join(_1, command) }
                      .find { File.executable?(_1) }
      raise Error, "#{command} executable is unavailable on PATH" unless executable

      executable
    end

    def client_version(client)
      result = capture([executable_for(client), "--version"], timeout: 10)
      raise Error, "#{client} --version failed: #{result.stderr}" unless result.status.zero? && !result.timed_out

      result.stdout.strip
    end

    def client_command(client, manifest)
      executable = executable_for(client)
      prompt = manifest.fetch("prompt")
      if client == "codex"
        [executable, "-c", "sandbox_workspace_write.writable_roots=[]",
         "-c", "sandbox_workspace_write.exclude_slash_tmp=true",
         "-c", "sandbox_workspace_write.exclude_tmpdir_env_var=true",
         "--ask-for-approval", "never", "exec", "--json", "--sandbox", "workspace-write", prompt]
      else
        [executable, "-p", prompt, "--output-format", "stream-json", "--verbose", "--include-hook-events",
         "--max-turns", "12", "--tools", "Read,Edit,Write"]
      end
    end

    def capture(argv, timeout:)
      ProcessCapture.new(argv:, chdir: @root.to_s, env: client_env, timeout:).run
    end

    def client_env
      remove_inherited_overrides.merge(
        "CLAUDE_PROJECT_DIR" => @root.to_s,
        "BUNDLE_GEMFILE" => @root.join("Gemfile").to_s,
        "GEM_HOME" => @root.join(".trial-gems").to_s,
        "GEM_PATH" => [@root.join(".trial-gems"), *Gem.path].join(File::PATH_SEPARATOR),
        "GIT_CONFIG_GLOBAL" => File::NULL,
        "GIT_CONFIG_NOSYSTEM" => "1"
      )
    end

    def remove_inherited_overrides
      ENV.keys.grep(/\A(?:BUNDLE_|RUBYOPT\z|RUBYLIB\z)/).to_h { [_1, nil] }
    end

    def write_session(record)
      File.write(@evidence_root.join("session.json"), "#{JSON.pretty_generate(record)}\n")
      record
    end

    def unavailable(message)
      time = Time.now.utc.iso8601(6)
      return unless @evidence_root.directory?

      write_session(
        "kind" => "native", "client_version" => "unavailable", "command" => [],
        "started_at" => time, "completed_at" => time, "status" => 2,
        "stdout" => "", "stderr" => message, "timed_out" => false, "extra_prompts" => 0
      )
    end
  end
end
