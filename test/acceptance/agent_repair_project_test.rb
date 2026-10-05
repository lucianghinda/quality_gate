# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/agent_repair_acceptance"

class AgentRepairProjectTest < Minitest::Test
  def test_default_paths_resolve_from_the_repository_root
    assert_equal File.expand_path("../..", __dir__), AgentRepairAcceptance::ROOT.to_s
    assert File.directory?(AgentRepairAcceptance::FIXTURE)
    assert File.file?(AgentRepairAcceptance::ROOT.join("test/support/agent_repair_acceptance/hook_capture.rb"))
  end

  def test_manifest_records_the_archive_provenance_and_seed_contract
    Dir.mktmpdir do |directory|
      artifact = File.join(directory, "quality_gate.gem")
      build_archive(artifact)
      project = AgentRepairAcceptance::Project.new(
        File.join(directory, "trial"), artifact:, client: "codex", scenario: "fast"
      )

      identity = project.send(:package_identity)

      assert_match(/\A[0-9a-f]{64}\z/, identity.fetch("sha256"))
      assert_equal "1.2.3", identity.fetch("version")
      assert_match(/\A[0-9a-f]{64}\z/, Digest::SHA256.hexdigest(AgentRepairAcceptance::FAST_SEED))
    end
  end

  def test_verify_seed_triggers_the_installed_undercover_gate
    Dir.mktmpdir do |directory|
      artifact = build_repository_archive(File.join(directory, "quality_gate.gem"))
      root = File.join(directory, "verify-trial")
      project = AgentRepairAcceptance::Project.new(root, artifact:, client: "codex", scenario: "verify")
      project.prepare

      assert_verify_seed_gate(project, root)
    end
  end

  def test_host_gemfile_uses_the_fixture_minimal_railties_dependency
    Dir.mktmpdir do |directory|
      artifact = File.join(directory, "quality_gate.gem")
      build_archive(artifact)
      destination = File.join(directory, "trial")
      FileUtils.mkdir_p(destination)
      project = AgentRepairAcceptance::Project.new(destination, artifact:, client: "claude", scenario: "fast")

      project.send(:write_gemfile)

      gemfile = File.read(File.join(destination, "Gemfile"))
      assert_includes gemfile, "gem 'railties', '~> 8.0'"
      refute_includes gemfile, "gem 'rails'"
    end
  end

  def test_prepare_rejects_a_missing_package_before_touching_destination
    Dir.mktmpdir do |directory|
      destination = File.join(directory, "trial")
      project = AgentRepairAcceptance::Project.new(
        destination, artifact: File.join(directory, "missing.gem"), client: "claude", scenario: "fast"
      )

      error = assert_raises(AgentRepairAcceptance::Error) { project.prepare }

      assert_match(/package artifact is not a file/, error.message)
      refute File.exist?(destination)
    end
  end

  def test_prepare_rejects_an_existing_sibling_evidence_directory
    Dir.mktmpdir do |directory|
      destination = File.join(directory, "trial")
      evidence = AgentRepairAcceptance.evidence_root(destination)
      FileUtils.mkdir_p(evidence)
      File.write(evidence.join("keep.json"), "keep")
      project = AgentRepairAcceptance::Project.new(
        destination, artifact: File.join(directory, "missing.gem"), client: "claude", scenario: "fast"
      )

      assert_reused_evidence_rejected(project, evidence, destination)
    end
  end

  def test_manifest_validator_rejects_root_mismatch
    Dir.mktmpdir do |directory|
      AgentRepairAcceptance::Project.new(
        directory, artifact: "unused.gem", client: "claude", scenario: "fast"
      )
      session = AgentRepairAcceptance::Session.new(directory)

      error = assert_raises(AgentRepairAcceptance::Error) do
        session.validate_manifest!(
          { "schema_version" => 1, "root" => "/different", "client" => "claude", "scenario" => "fast" }
        )
      end

      assert_match(/manifest root mismatch/, error.message)
    end
  end

  def test_claude_recorder_wrapper_uses_native_command_and_argument_fields
    Dir.mktmpdir("agent repair ") do |directory|
      root = File.join(directory, "host app")
      settings_path = create_claude_settings(root)
      project = AgentRepairAcceptance::Project.new(root, artifact: "unused", client: "claude", scenario: "fast")

      project.send(:wrap_hooks, ".claude/settings.json", "claude")

      wrapped = JSON.parse(File.read(settings_path)).dig("hooks", "PostToolUse", 0, "hooks", 0)
      assert_claude_wrapper(wrapped, settings_path, root)
    end
  end

  def test_codex_recorder_wrapper_invokes_the_ruby_recorder_explicitly
    Dir.mktmpdir("agent repair ") do |directory|
      root = File.join(directory, "host app")
      settings_path = create_codex_settings(root)
      project = AgentRepairAcceptance::Project.new(root, artifact: "unused", client: "codex", scenario: "fast")

      project.send(:wrap_hooks, ".codex/hooks.json", "codex")

      command = JSON.parse(File.read(settings_path)).dig("hooks", "PostToolUse", 0, "hooks", 0, "command")
      assert_codex_wrapper(command, root)
    end
  end

  def test_installed_package_files_are_protected
    Dir.mktmpdir do |directory|
      gem_file = File.join(directory, ".trial-gems/gems/quality_gate/lib/quality_gate.rb")
      FileUtils.mkdir_p(File.dirname(gem_file))
      File.write(gem_file, "package code")
      manifest = { "protected_files" => { gem_file.delete_prefix("#{directory}/") => Digest::SHA256.file(gem_file).hexdigest } }
      runner = AgentRepairAcceptance::ProjectRunner.new(directory, manifest)

      assert runner.send(:protected_files_unchanged?)
      File.write(gem_file, "changed package code")
      refute runner.send(:protected_files_unchanged?)
    end
  end

  private

  def build_archive(path)
    specification = Gem::Specification.new do |spec|
      spec.name = "quality_gate"
      spec.version = "1.2.3"
      spec.summary = "fixture archive"
      spec.authors = ["test"]
      spec.files = []
    end
    Gem::Package.build(specification, false, false, path)
  end

  def build_repository_archive(path)
    specification = Gem::Specification.load(AgentRepairAcceptance::ROOT.join("quality_gate.gemspec").to_s)
    Gem::Package.build(specification, false, false, path)
    path
  end

  def assert_verify_seed_gate(project, root)
    File.write(File.join(root, AgentRepairAcceptance::SOURCE), AgentRepairAcceptance::VERIFY_SEED)
    result = project.send(:gate, "verify")
    report = result.fetch("report")

    assert_equal 1, result.fetch("status"), report.inspect
    assert_equal "clean", report.fetch("checks").find { _1["tool"] == "test_suite" }.fetch("status")
    assert_uncovered_code_finding(report.fetch("findings"))
  end

  def assert_uncovered_code_finding(findings)
    assert findings.any? { _1["tool"] == "undercover" && _1["rule"] == "uncovered_code" }, findings.inspect
  end

  def create_claude_settings(root)
    FileUtils.mkdir_p(File.join(root, ".claude"))
    path = File.join(root, ".claude/settings.json")
    hook = {
      "type" => "command", "command" => "\${CLAUDE_PROJECT_DIR}/.claude/hooks/quality_gate_fast.rb",
      "args" => ["--flag"], "timeout" => 17
    }
    settings = { "hooks" => { "PostToolUse" => [{ "matcher" => "Edit|Write", "hooks" => [hook] }] } }
    File.write(path, JSON.generate(settings))
    path
  end

  def recorder_arguments(root, client = "claude")
    evidence = AgentRepairAcceptance.evidence_root(root).to_s
    [File.join(evidence, "agent_repair_recorder.rb"), client, "PostToolUse", root,
     File.join(evidence, "hooks.jsonl"), "--",
     File.join(root, ".claude/hooks/quality_gate_fast.rb"), "--flag"]
  end

  def assert_reused_evidence_rejected(project, evidence, destination)
    error = assert_raises(AgentRepairAcceptance::Error) { project.prepare }
    assert_match(/evidence directory already exists/, error.message)
    assert_equal "keep", File.read(evidence.join("keep.json"))
    refute File.exist?(destination)
  end

  def assert_codex_wrapper(command, root)
    evidence = AgentRepairAcceptance.evidence_root(root).to_s
    original = ["ruby", File.join(root, ".codex/hooks/quality_gate_fast.rb"), "--flag"]
    expected = [RbConfig.ruby, File.join(evidence, "agent_repair_recorder.rb"), "codex", "PostToolUse",
                root, File.join(evidence, "hooks.jsonl"), "--", *original]
    assert_equal expected, Shellwords.split(command)
  end

  def create_codex_settings(root)
    FileUtils.mkdir_p(File.join(root, ".codex"))
    path = File.join(root, ".codex/hooks.json")
    settings = { "hooks" => { "PostToolUse" => [{ "matcher" => "Edit|Write", "hooks" => [
      { "command" => Shellwords.join(["ruby", File.join(root, ".codex/hooks/quality_gate_fast.rb"), "--flag"]),
        "timeout" => 17 }
    ] }] } }
    File.write(path, JSON.generate(settings))
    path
  end

  def assert_claude_wrapper(wrapped, settings_path, root)
    settings = JSON.parse(File.read(settings_path))
    assert_equal RbConfig.ruby, wrapped.fetch("command")
    assert_equal 17, wrapped.fetch("timeout")
    assert_equal "Edit|Write", settings.dig("hooks", "PostToolUse", 0, "matcher")
    assert_equal recorder_arguments(root), wrapped.fetch("args")
  end
end
