# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "quality_gate/doctor_report"
require "quality_gate/doctor_launchers"
require "quality_gate/doctor"

class DoctorTest < Minitest::Test
  class UnlaunchableAdapter
    def initialize(**)
      nil
    end

    def timeout = 5
    def command = ["./unlisted-wrapper"]
    def call = flunk "Doctor must not execute adapters"
  end

  class ExplodingAdapter
    def initialize(**)
      raise "adapter should not be inspected"
    end

    def timeout = flunk "Malformed configuration must stop before adapter inspection"
  end

  class InvalidArgvAdapter < UnlaunchableAdapter
    def command = ["rubocop", nil]
  end

  class BrokenMetadataAdapter
    def initialize(**)
      nil
    end

    def timeout
      raise "metadata sentinel"
    end
  end

  def test_reports_runtime_configuration_and_a_custom_wrapper_as_unchecked
    with_project(config_for(fast: ["custom"])) do |dir|
      report = custom_wrapper_report(dir)

      assert_equal "ready", check(report, "configuration").fetch("status")
      assert_equal "unchecked", check(report, "command.fast.custom").fetch("status")
      assert_match(/custom wrapper/i, check(report, "command.fast.custom").fetch("message"))
      assert_includes %w[ready unchecked], check(report, "runtime").fetch("status")
    end
  end

  def test_malformed_configuration_blocks_and_marks_configured_checks_unchecked_without_probing
    with_project("adapters: [broken\n") do |dir|
      report = doctor(dir, "rubocop" => ExplodingAdapter).call

      assert_equal "blocked", check(report, "configuration").fetch("status")
      assert_equal "unchecked", check(report, "configured_checks").fetch("status")
      assert_equal 2, report.exit_code
    end
  end

  def test_unknown_adapter_is_blocked_and_unknown_config_keys_are_warnings
    yaml = "unknown_setting: true\nadapters:\n  fast:\n    - ghost\n"
    with_project(yaml) do |dir|
      report = doctor(dir).call

      assert_equal "warning", check(report, "configuration").fetch("status")
      assert_equal "blocked", check(report, "command.fast.ghost").fetch("status")
      assert_match(/unknown adapter/i, check(report, "command.fast.ghost").fetch("message"))
    end
  end

  def test_empty_adapter_layer_and_simplecov_without_budget_are_reported
    yaml = "adapters:\n  fast: []\n  verify:\n    - simplecov\n"
    with_project(yaml) do |dir|
      report = doctor(dir).call

      assert_equal "not_applicable", check(report, "command.fast").fetch("status")
      assert_equal "blocked", check(report, "command.verify.simplecov").fetch("status")
      assert_match(/coverage threshold/i, check(report, "command.verify.simplecov").fetch("message"))
    end
  end

  def test_database_consistency_doctor_check_inspects_launcher_without_booting_app
    with_project("adapters:\n  audit:\n    - database_consistency\n") do |dir|
      marker = boot_marker(dir)
      assert_database_consistency_launcher_ready(doctor_database_check(dir))
      refute File.exist?(marker)
    end
  end

  def boot_marker(dir)
    marker = File.join(dir, "booted")
    FileUtils.mkdir_p(File.join(dir, "config"))
    File.write(File.join(dir, "config", "boot.rb"), "File.write(#{marker.inspect}, 'yes')\n")
    marker
  end

  def doctor_database_check(dir)
    stdout = StringIO.new
    stderr = StringIO.new
    QualityGate::CLI.run(%w[doctor --format json], stdout:, stderr:, dir:)
    assert_empty stderr.string
    JSON.parse(stdout.string).fetch("checks").find { _1.fetch("id") == "command.audit.database_consistency" }
  end

  def assert_database_consistency_launcher_ready(check)
    assert_equal "ready", check.fetch("status")
    assert_includes check.fetch("message"), "command behavior was not run"
  end

  def test_invalid_timeout_blocks_without_calling_command
    adapter = Class.new(UnlaunchableAdapter) do
      def timeout = 0
      def command = flunk "An invalid timeout must stop before command inspection"
    end
    with_project(config_for(fast: ["custom"])) do |dir|
      report = doctor(dir, "custom" => adapter).call

      assert_equal "blocked", check(report, "command.fast.custom").fetch("status")
      assert_match(/timeout/i, check(report, "command.fast.custom").fetch("message"))
    end
  end

  def test_disabled_adapter_is_not_inspected
    yaml = "adapters:\n  fast: []\n  verify: []\n  audit: []\n"
    with_project(yaml) do |dir|
      report = doctor(dir, "rubocop" => ExplodingAdapter).call
      command_checks = report.checks.select { _1.fetch("id").start_with?("command.") }

      assert_equal 3, command_checks.length
      assert(command_checks.all? { _1.fetch("status") == "not_applicable" })
    end
  end

  def test_invalid_adapter_argv_is_blocked
    with_project(config_for(fast: ["custom"])) do |dir|
      report = doctor(dir, "custom" => InvalidArgvAdapter).call

      assert_equal "blocked", check(report, "command.fast.custom").fetch("status")
      assert_match(/argv/i, check(report, "command.fast.custom").fetch("message"))
    end
  end

  def test_unbundled_runtime_is_explicitly_unchecked
    with_project(empty_configuration) do |dir|
      report = without_bundler { doctor(dir).call }

      assert_equal "unchecked", check(report, "runtime").fetch("status")
      assert_match(/bundle exec/, check(report, "runtime").fetch("message"))
    end
  end

  def test_runtime_inspection_exception_is_unchecked_without_leaking_exception_text
    with_project(empty_configuration) do |dir|
      report = RbConfig.stub(:ruby, -> { raise "runtime sentinel" }) { doctor(dir).call }

      assert_equal "unchecked", check(report, "runtime").fetch("status")
      refute_includes check(report, "runtime").fetch("message"), "runtime sentinel"
    end
  end

  def test_adapter_metadata_exception_is_blocked_without_leaking_exception_text
    with_project(config_for(fast: ["broken"])) do |dir|
      report = doctor(dir, "broken" => BrokenMetadataAdapter).call

      assert_equal "blocked", check(report, "command.fast.broken").fetch("status")
      refute_includes check(report, "command.fast.broken").fetch("message"), "metadata sentinel"
    end
  end

  def test_simplecov_with_a_coverage_threshold_is_ready
    yaml = <<~YAML
      adapters:
        fast: []
        verify:
          - simplecov
        audit: []
      coverage:
        minimum_line: 80
    YAML
    with_project(yaml) do |dir|
      report = doctor(dir, "simplecov" => ExplodingAdapter).call

      assert_equal "ready", check(report, "command.verify.simplecov").fetch("status")
    end
  end

  def test_unexpected_coordinator_failure_returns_a_blocker_without_traceback
    with_project(config_for(fast: ["rubocop"])) do |dir|
      report = QualityGate::Config.stub(:load, ->(**) { raise "coordinator sentinel" }) do
        doctor(dir).call
      end

      assert_equal 2, report.exit_code
      failure = check(report, "doctor")
      assert_equal "blocked", failure.fetch("status")
      refute_includes failure.fetch("message"), "coordinator sentinel"
    end
  end

  def test_probe_failure_keeps_other_probe_results
    with_project(empty_configuration) do |dir|
      report = QualityGate::DoctorCoverage.stub(:new, ->(**) { raise "coverage sentinel" }) do
        doctor(dir).call
      end

      assert_statuses(report, %w[
                        coverage unchecked comparison not_applicable hooks not_applicable
                      ])
      refute_includes check(report, "coverage").fetch("message"), "coverage sentinel"
    end
  end

  private

  def doctor(dir, custom = {})
    registry = QualityGate::CLI.send(:registry).merge(custom)
    QualityGate::Doctor.new(dir:, registry:)
  end

  def custom_wrapper_report(dir)
    path = File.join(dir, "unlisted-wrapper")
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, path)
    doctor(dir, "custom" => UnlaunchableAdapter).call
  end

  def check(report, id)
    report.checks.find { _1.fetch("id") == id } || flunk("Missing check #{id}")
  end

  def assert_statuses(report, statuses)
    statuses.each_slice(2) { |id, status| assert_equal status, check(report, id).fetch("status") }
  end

  def config_for(fast: [])
    "adapters:\n  fast:\n#{fast.map { "    - #{_1}\n" }.join}"
  end

  def with_project(config)
    Dir.mktmpdir("quality-gate-doctor") do |dir|
      File.write(File.join(dir, ".quality_gate.yml"), config)
      yield dir
    end
  end

  def empty_configuration
    "adapters:\n  fast: []\n  verify: []\n  audit: []\n"
  end

  def without_bundler
    previous = Object.send(:remove_const, :Bundler) if Object.const_defined?(:Bundler, false)
    yield
  ensure
    Object.const_set(:Bundler, previous) if previous
  end
end
