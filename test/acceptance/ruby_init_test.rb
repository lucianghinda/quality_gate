# frozen_string_literal: true

require "test_helper"

require "json"
require "tmpdir"
require "yaml"
require_relative "../support/ruby_acceptance_project"

module Acceptance
  class RubyInitTest < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)
    EXPECTED_CHECKS = {
      "fast" => ["rubocop"],
      "verify" => %w[reek test_suite undercover],
      "audit" => ["bundler_audit"]
    }.freeze
    AUDIT_FALLBACK_WARNING = "bundler_audit: advisory database update failed; using cached database\n"

    def test_init_detects_minitest_and_all_gates_run_without_rails
      ruby_project.open(repository_root: ROOT) do |project|
        init = project.init

        assert_successful_init init
        assert_ruby_profile(project)

        assert_clean_gates project
      end
    end

    def test_repeated_init_is_idempotent
      ruby_project.open(repository_root: ROOT) do |project|
        first = project.init
        before = snapshot(project.root)
        second = project.init

        assert_successful_init first
        assert_successful_init second
        assert_equal before, snapshot(project.root)
      end
    end

    def test_pretend_init_does_not_write_files
      ruby_project.open(repository_root: ROOT) do |project|
        before = snapshot(project.root)

        result = project.init("--pretend")

        assert_successful_init result
        assert_equal before, snapshot(project.root)
      end
    end

    def test_skip_coverage_omits_undercover_and_preserves_the_test_helper
      ruby_project.open(repository_root: ROOT) do |project|
        helper_path = File.join(project.root, "test/test_helper.rb")
        before = File.binread(helper_path)

        result = project.init("--skip-coverage")

        assert_successful_init result
        assert_skip_coverage_profile project, helper_path:, before:
      end
    end

    def test_fast_gate_catches_a_defect_introduced_after_init
      ruby_project.open(repository_root: ROOT) do |project|
        assert_successful_init project.init

        append_to_calculator(project, "\n  def self.unused\n    value = 1\n  end\n")

        run = project.run("fast", "--files", "lib/calculator.rb")

        assert_equal 1, run.status, run_diagnostic(run)
        assert rubocop_finding?(run.report.fetch("findings"))
      end
    end

    def test_verify_catches_an_uncovered_method_introduced_after_init
      ruby_project.open(repository_root: ROOT) do |project|
        assert_successful_init project.init

        append_to_calculator(project, "\n  def self.subtract(left, right)\n    left - right\n  end\n")

        run = project.run("verify")

        assert_equal 1, run.status, run_diagnostic(run)
        assert undercover_finding?(run.report.fetch("findings")), run_diagnostic(run)
      end
    end

    private

    def ruby_project
      QualityGate::RubyAcceptanceProject
    end

    def assert_successful_init(result)
      assert_equal 0, result.status, init_diagnostic(result)
    end

    def assert_ruby_profile(project)
      config = configuration(project)
      assert_equal %w[bundle exec rake test], config.dig("commands", "verify", "test_suite")
      assert_no_rails_host project
    end

    def assert_no_rails_host(project)
      assert_empty Dir.glob(File.join(project.root, "config/initializers/**/*"))
      refute_path_exists File.join(project.root, "config/application.rb")
      refute_includes File.read(File.join(project.root, "Gemfile")), "railties"
      refute_includes File.read(File.join(project.root, "Gemfile.lock")), "railties ("
    end

    def assert_skip_coverage_profile(project, helper_path:, before:)
      assert_equal %w[reek test_suite], configuration(project).dig("adapters", "verify")
      assert_equal before, File.binread(helper_path)
    end

    def assert_clean_gates(project)
      EXPECTED_CHECKS.each do |command, expected_tools|
        run = project.run(command)
        actual_tools = run.report.fetch("checks").map { _1.fetch("tool") }
        assert_equal expected_tools, actual_tools
        assert_clean_run run, command:
      end
    end

    def configuration(project)
      YAML.safe_load_file(File.join(project.root, ".quality_gate.yml"))
    end

    def append_to_calculator(project, content)
      File.open(File.join(project.root, "lib/calculator.rb"), "a") { _1.write(content) }
    end

    def rubocop_finding?(findings)
      findings.any? { _1.fetch("tool") == "rubocop" }
    end

    def undercover_finding?(findings)
      findings.any? { _1.fetch("tool") == "undercover" }
    end

    def snapshot(root)
      files = Dir.glob(File.join(root, "**/*"), File::FNM_DOTMATCH)
      files.reject! { |path| path.include?(File.join(root, ".git")) }
      files.select! { |path| File.file?(path) }
      files.to_h { |path| [path.delete_prefix("#{root}/"), File.binread(path)] }
    end

    def assert_clean_run(run, command:)
      assert_equal 0, run.status, run_diagnostic(run)
      assert_empty run.report.fetch("findings"), run_diagnostic(run)
      assert_equal 0, run.report.fetch("summary").fetch("tool_failures"), run_diagnostic(run)
      expected_stderr = command == "audit" ? AUDIT_FALLBACK_WARNING : ""
      assert_equal expected_stderr, run.stderr
    end

    def run_diagnostic(run)
      "status=#{run.status}; report=#{run.report.inspect}; stdout=#{run.stdout.inspect}; stderr=#{run.stderr.inspect}"
    end

    def init_diagnostic(result)
      "status=#{result.status}; stdout=#{result.stdout.inspect}; stderr=#{result.stderr.inspect}"
    end
  end
end
