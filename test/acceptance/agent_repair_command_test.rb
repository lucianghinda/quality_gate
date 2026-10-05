# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/agent_repair_acceptance"

class AgentRepairCommandTest < Minitest::Test
  def test_bin_help_is_loadable_without_running_a_session
    output = StringIO.new
    error = StringIO.new
    original_argv = ARGV.dup
    ARGV.replace(["--help"])
    original_stdout = $stdout
    original_stderr = $stderr
    $stdout = output
    $stderr = error

    assert_raises(SystemExit) { load File.expand_path("../../bin/agent_repair_acceptance", __dir__) }
    assert_includes output.string, "prepare DIRECTORY"
    assert_empty error.string
  ensure
    ARGV.replace(original_argv)
    $stdout = original_stdout
    $stderr = original_stderr
  end

  def test_malformed_arguments_fail_with_usage
    error = StringIO.new

    status = AgentRepairAcceptance::Command.new(["prepare"], err: error).call

    assert_equal 2, status
    assert_includes error.string, "prepare requires DIRECTORY"
  end

  def test_existing_directory_is_never_overwritten
    Dir.mktmpdir do |directory|
      marker = File.join(directory, "keep.txt")
      File.write(marker, "keep")
      error = StringIO.new

      status = AgentRepairAcceptance::Command.new(
        ["prepare", directory, "--gem", "missing.gem", "--client", "claude", "--scenario", "fast"], err: error
      ).call

      assert_equal 2, status
      assert_equal "keep", File.read(marker)
      assert_includes error.string, "already exists"
    end
  end

  def test_manifest_change_after_native_run_fails_integrity_check
    Dir.mktmpdir do |root|
      evidence = AgentRepairAcceptance.evidence_root(root)
      FileUtils.mkdir_p(evidence)
      path = evidence.join("manifest.json")
      File.write(path, '{"protected_files":{"config.yml":"original"}}')
      original_sha256 = Digest::SHA256.file(path).hexdigest
      command = AgentRepairAcceptance::Command.new([])

      File.write(path, '{"protected_files":{}}')

      refute command.send(:manifest_unchanged?, evidence, original_sha256)
    end
  end

  def test_run_and_report_round_trip_external_receipts
    Dir.mktmpdir do |root|
      evidence = AgentRepairAcceptance.evidence_root(root)
      FileUtils.mkdir_p(evidence)
      write_manifest(root, minimal_manifest(root, "claude"))

      run_status, report_status, output = run_and_report_with_stubs(root)

      assert_external_receipts(evidence, [run_status, report_status, output])
    end
  end

  def test_run_rejects_malformed_manifests_without_starting_a_client
    invalid_manifests.each do |fields, message|
      assert_invalid_manifest_command(fields, message)
    end
  end

  def test_run_with_missing_client_records_unavailable_without_spawning_a_session
    Dir.mktmpdir do |root|
      manifest = minimal_manifest(root, "claude")
      write_manifest(root, manifest)
      record = with_path("") { AgentRepairAcceptance::Session.new(root, timeout: 1).run }

      assert_equal 2, record.fetch("status")
      assert_includes record.fetch("stderr"), "claude executable is unavailable"
      assert_equal "native", record.fetch("kind")
    end
  end

  def test_session_timeout_kills_only_the_child_process_group
    Dir.mktmpdir do |root|
      record = timed_out_session(root)

      assert_equal true, record.fetch("timed_out")
      assert_equal 124, record.fetch("status")
    end
  end

  private

  def minimal_manifest(root, client)
    {
      "schema_version" => 1, "client" => client, "scenario" => "fast", "root" => root,
      "prepared_at" => "2026-10-05T10:00:00Z", "source_path" => "lib/calculator.rb", "seed_sha256" => "a" * 64,
      "package" => { "version" => "0.3.0", "sha256" => "b" * 64, "resolved_path" => "/fixture/gem" },
      "baseline" => { "fast" => clean_gate(%w[rubocop]), "verify" => clean_gate(%w[test_suite undercover]) },
      "protected_files" => { "test/test_helper.rb" => "c" * 64 }, "head" => "d" * 40,
      "prompt" => "test prompt"
    }
  end

  def clean_gate(tools)
    {
      "status" => 0,
      "report" => {
        "findings" => [], "summary" => { "tool_failures" => 0, "failed_tools" => [] },
        "checks" => tools.map { { "tool" => _1, "status" => "clean" } }
      }
    }
  end

  def write_manifest(root, manifest)
    evidence = AgentRepairAcceptance.evidence_root(root)
    FileUtils.mkdir_p(evidence)
    File.write(evidence.join("manifest.json"), JSON.generate(manifest))
  end

  def timed_out_session(root)
    client = File.join(root, "claude")
    File.write(client, <<~RUBY)
      #!#{RbConfig.ruby}
      if ARGV == ["--version"]
        puts "fake-1"
        exit
      end
      sleep 10
    RUBY
    File.chmod(0o755, client)
    File.write(File.join(root, "Gemfile"), "")
    write_manifest(root, minimal_manifest(root, "claude"))
    with_path(root) { AgentRepairAcceptance::Session.new(root, timeout: 1).run }
  end

  def invalid_manifests
    [
      [{ "client" => "unknown" }, "client must be claude or codex"],
      [{ "scenario" => "unknown" }, "scenario must be fast or verify"],
      [{ "root" => nil }, "manifest root must be a path string"],
      [:missing_root, "manifest root must be a path string"],
      [{ "prompt" => [] }, "manifest prompt must be a non-empty string"],
      [:missing_prompt, "manifest prompt must be a non-empty string"],
      [{ "package" => [] }, "manifest package archive is no longer available"],
      [:missing_package_sha, "manifest is incomplete"],
      [:missing_package_version, "manifest is incomplete"],
      [{ "head" => nil }, "manifest is incomplete"],
      [{ "protected_files" => nil }, "manifest is incomplete"],
      [{ "source_path" => nil }, "manifest is incomplete"],
      [{ "seed_sha256" => "bad" }, "manifest is incomplete"],
      [:invalid_package_sha, "manifest is incomplete"],
      [:missing_baseline, "manifest is incomplete"],
      [:unclean_baseline, "manifest is incomplete"],
      [:not_an_object, "manifest must be a JSON object"]
    ]
  end

  def invalid_manifest(root, fields)
    return [] if fields == :not_an_object

    manifest = minimal_manifest(root, "claude")
    return delete_manifest_field(manifest, fields) if %i[missing_root missing_prompt].include?(fields)

    mutate_special_manifest_field(manifest, fields) || manifest.merge(fields)
  end

  def delete_manifest_field(manifest, field)
    manifest.delete(field.to_s.delete_prefix("missing_"))
    manifest
  end

  def mutate_special_manifest_field(manifest, field)
    case field
    when :missing_package_sha
      manifest.fetch("package").delete("sha256")
      manifest
    when :missing_package_version
      manifest.fetch("package").delete("version")
      manifest
    when :invalid_package_sha
      manifest.fetch("package")["sha256"] = "bad"
      manifest
    when :missing_baseline
      manifest.delete("baseline")
      manifest
    when :unclean_baseline
      manifest.fetch("baseline").fetch("fast")["status"] = 1
      manifest
    end
  end

  def assert_invalid_manifest_command(fields, message)
    Dir.mktmpdir do |root|
      marker = install_client_that_must_not_run(root)
      write_manifest(root, invalid_manifest(root, fields))
      error = StringIO.new
      status = with_path(root) { AgentRepairAcceptance::Command.new(["run", root], err: error).call }

      assert_equal 2, status
      assert_includes error.string, message
      refute File.exist?(marker)
      refute_includes error.string, "NoMethodError"
    end
  end

  def install_client_that_must_not_run(root)
    marker = File.join(root, "invoked")
    File.write(File.join(root, "claude"), <<~RUBY)
      #!#{RbConfig.ruby}
      File.write(#{marker.inspect}, "called")
    RUBY
    File.chmod(0o755, File.join(root, "claude"))
    marker
  end

  def run_and_report_with_stubs(root)
    with_command_stubs do
      run_out = StringIO.new
      run_status = AgentRepairAcceptance::Command.new(["run", root], out: run_out).call
      report_out = StringIO.new
      report_status = AgentRepairAcceptance::Command.new(["report", root], out: report_out).call
      [run_status, report_status, run_out.string + report_out.string]
    end
  end

  def with_command_stubs(&block)
    session_record = stub_session_record
    final_checks = stub_final_checks
    session = Object.new
    session.define_singleton_method(:run) { session_record }
    session.define_singleton_method(:validate_manifest!) { |_manifest| true }
    runner = Object.new
    runner.define_singleton_method(:final_checks) { final_checks }
    AgentRepairAcceptance::Session.stub(:new, session) do
      AgentRepairAcceptance::ProjectRunner.stub(:new, runner, &block)
    end
  end

  def assert_external_receipts(evidence, result)
    run_status, report_status, output = result
    assert_equal 1, run_status
    assert_equal 1, report_status
    assert_includes output, "not_observed"
    session = JSON.parse(File.read(evidence.join("session.json")))
    assert_saved_manifest_digest(evidence, session)
    assert_external_final_receipt(evidence)
  end

  def assert_saved_manifest_digest(evidence, session)
    digest = Digest::SHA256.file(evidence.join("manifest.json")).hexdigest
    assert_equal digest, session.fetch("manifest_sha256")
  end

  def assert_external_final_receipt(evidence)
    final = JSON.parse(File.read(evidence.join("final.json")))
    assert final.fetch("protected_files_unchanged")
    assert File.file?(evidence.join("report.json"))
  end

  def stub_session_record
    { "kind" => "native", "client_version" => "synthetic", "command" => [],
      "started_at" => "2026-10-05T10:00:00Z", "completed_at" => "2026-10-05T10:01:00Z",
      "status" => 0, "stdout" => "", "stderr" => "", "timed_out" => false, "extra_prompts" => 0 }
  end

  def stub_final_checks
    { "fast" => clean_gate(%w[rubocop]), "verify" => clean_gate(%w[test_suite undercover]),
      "behavior" => false, "protected_files_unchanged" => true,
      "allowed_mutations_only" => true, "head_unchanged" => true }
  end

  def with_path(path)
    previous = ENV.fetch("PATH", "")
    ENV["PATH"] = path
    yield
  ensure
    ENV["PATH"] = previous
  end
end
