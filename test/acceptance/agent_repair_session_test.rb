# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/agent_repair_acceptance"

class AgentRepairSessionTest < Minitest::Test
  def test_claude_prompt_is_immediate_and_tool_availability_is_limited_to_file_edits
    with_client("claude") do |root|
      command = command_for("claude", root)

      assert_claude_command(command)
      refute_includes command, "Bash"
    end
  end

  def test_codex_command_uses_workspace_write_and_excludes_global_temp_roots
    with_client("codex") do |root, executable|
      command = command_for("codex", root)

      assert_equal [
        executable, "-c", "sandbox_workspace_write.writable_roots=[]",
        "-c", "sandbox_workspace_write.exclude_slash_tmp=true",
        "-c", "sandbox_workspace_write.exclude_tmpdir_env_var=true",
        "--ask-for-approval", "never", "exec", "--json", "--sandbox", "workspace-write", "controlled prompt"
      ], command
    end
  end

  def test_executable_selection_uses_path_without_a_private_host_path
    with_client("codex") do |root, executable|
      old_path = ENV["PATH"]
      ENV["PATH"] = root

      assert_equal executable, AgentRepairAcceptance::Session.new(root).send(:executable_for, "codex")
      client_env = AgentRepairAcceptance::Session.new(root).send(:client_env)
      assert_equal root, client_env.fetch("PATH", ENV.fetch("PATH"))
    ensure
      ENV["PATH"] = old_path
    end
  end

  def test_existing_session_record_is_immutable
    with_client("claude") do |root|
      existing = write_prior_session(root)

      error = run_with_path(root) do
        assert_raises(AgentRepairAcceptance::Error) { AgentRepairAcceptance::Session.new(root).run }
      end

      assert_match(/already has run output|fresh directory/i, error.message)
      assert_equal existing, File.read(evidence_path(root, "session.json"))
    end
  end

  def test_client_environment_drops_host_bundle_settings_and_uses_trial_install
    with_client("claude") do |root|
      session = AgentRepairAcceptance::Session.new(root)

      with_host_bundle_environment do
        effective = ENV.to_h.merge(session.send(:client_env))
        assert_trial_environment(root, effective)
      end
    end
  end

  def test_timeout_terminates_the_owned_process_group_and_keeps_timeout_status
    with_client("claude") do |root, executable|
      marker = File.join(root, "child-stopped")
      ready = File.join(root, "child-ready")
      install_timeout_client(root, executable, marker, ready)
      prepare_timeout_trial(root)

      record = run_with_path(root) { AgentRepairAcceptance::Session.new(root, timeout: 1).run }

      assert_timed_out_with_owned_child(record, marker)
    end
  end

  private

  def assert_claude_command(command)
    assert_equal ["-p", "controlled prompt"], command[1, 2]
    tool_flag = command.index("--tools")
    refute_nil tool_flag
    assert_equal "Read,Edit,Write", command[tool_flag + 1]
  end

  def command_for(client, root)
    run_with_path(root) do
      AgentRepairAcceptance::Session.new(root).send(:client_command, client, manifest(root, client))
    end
  end

  def assert_trial_environment(root, env)
    %w[BUNDLE_PATH BUNDLE_BIN_PATH BUNDLE_WITHOUT RUBYOPT RUBYLIB].each { assert_nil env[_1] }
    assert_equal File.join(root, "Gemfile"), env.fetch("BUNDLE_GEMFILE")
    assert_equal File.join(root, ".trial-gems"), env.fetch("GEM_HOME")
    assert_includes env.fetch("GEM_PATH").split(File::PATH_SEPARATOR), File.join(root, ".trial-gems")
  end

  def write_prior_session(root)
    evidence_root = AgentRepairAcceptance.evidence_root(root)
    FileUtils.mkdir_p(evidence_root)
    File.write(evidence_root.join("manifest.json"), JSON.generate(manifest(root, "claude")))
    existing = "prior native run\n"
    File.write(evidence_root.join("session.json"), existing)
    existing
  end

  def prepare_timeout_trial(root)
    File.write(File.join(root, "Gemfile"), "source 'https://rubygems.org'\n")
    evidence_root = AgentRepairAcceptance.evidence_root(root)
    FileUtils.mkdir_p(evidence_root)
    File.write(evidence_root.join("manifest.json"), JSON.generate(manifest(root, "claude")))
  end

  def evidence_path(root, filename)
    AgentRepairAcceptance.evidence_root(root).join(filename)
  end

  def assert_timed_out_with_owned_child(record, marker)
    assert record.fetch("timed_out"), record.inspect
    assert_equal 124, record.fetch("status")
    assert_equal "stopped", File.read(marker)
  end

  def with_host_bundle_environment
    keys = %w[BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_BIN_PATH BUNDLE_WITHOUT]
    original = ENV.to_h.slice(*keys)
    ENV["BUNDLE_GEMFILE"] = "/host/private/Gemfile"
    ENV["BUNDLE_PATH"] = "/host/private/bundle"
    ENV["BUNDLE_BIN_PATH"] = "/host/private/bundle/bin"
    ENV["BUNDLE_WITHOUT"] = "development"
    yield
  ensure
    keys.each { ENV.delete(_1) }
    ENV.update(original) if original
  end

  def run_with_path(path)
    original = ENV["PATH"]
    ENV["PATH"] = path
    yield
  ensure
    ENV["PATH"] = original
  end

  def install_timeout_client(root, executable, marker, ready)
    child = File.join(root, "child.rb")
    File.write(child, <<~RUBY)
      trap("TERM") { File.write(#{marker.dump}, "stopped"); exit }
      File.write(#{ready.dump}, "ready")
      loop { sleep 0.01 }
    RUBY
    File.write(executable, <<~RUBY)
      #!#{RbConfig.ruby}
      if ARGV == ["--version"]
        puts "fixture-client 1"
        exit
      end
      Process.spawn(#{RbConfig.ruby.dump}, #{child.dump}, out: File::NULL, err: File::NULL)
      sleep 0.01 until File.exist?(#{ready.dump})
      sleep 30
    RUBY
    File.chmod(0o755, executable)
  end

  def with_client(client)
    Dir.mktmpdir do |root|
      executable = File.join(root, client)
      File.write(executable, "#!#{RbConfig.ruby}\nputs 'fixture-client 1' if ARGV == ['--version']\n")
      File.chmod(0o755, executable)
      yield root, executable
    ensure
      FileUtils.rm_rf(AgentRepairAcceptance.evidence_root(root))
    end
  end

  def manifest(root, client)
    {
      "schema_version" => 1, "client" => client, "scenario" => "fast", "root" => root,
      "prepared_at" => Time.now.utc.iso8601,
      "source_path" => "lib/calculator.rb", "seed_sha256" => "a" * 64,
      "package" => { "version" => "1.2.3", "sha256" => "b" * 64,
                     "resolved_path" => File.join(root, ".trial-gems/gems/quality_gate-1.2.3") },
      "baseline" => {
        "fast" => clean_gate_report(%w[rubocop]),
        "verify" => clean_gate_report(%w[test_suite undercover])
      },
      "protected_files" => { "test/test_helper.rb" => "c" * 64 },
      "head" => "d" * 40, "prompt" => "controlled prompt"
    }
  end

  def clean_gate_report(tools)
    {
      "status" => 0,
      "report" => {
        "findings" => [],
        "summary" => { "findings" => 0, "tool_failures" => 0, "failed_tools" => [] },
        "checks" => tools.map { { "tool" => _1, "status" => "clean" } }
      }
    }
  end
end
