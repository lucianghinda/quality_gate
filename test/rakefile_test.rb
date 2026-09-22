# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require "yaml"
require "rake"
require "minitest/mock"
require_relative "support/acceptance_project"
require_relative "support/parallel_runner"

class RakefileTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  RUBOCOP_CONFIG = File.join(ROOT, ".rubocop.yml")

  def test_test_task_excludes_embedded_acceptance_project_tests
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-S", "rake", "test:cmd", chdir: ROOT)

    assert_predicate status, :success?, stderr
    assert_includes stdout, "test/acceptance/incident_catalog_test.rb"
    assert_includes stdout, "test/test_quality_gate.rb"
    refute_includes stdout, "test/fixtures/acceptance/"
  end

  def test_acceptance_support_loads_without_ruby_warnings
    stdout, stderr, status = load_acceptance_support

    assert_predicate status, :success?, stderr
    assert_empty stdout
    assert_empty stderr
  end

  def test_acceptance_project_escapes_repository_paths_as_ruby_strings
    path = "project's\\repository"
    literal = QualityGate::AcceptanceProject.allocate.send(:ruby_string_literal, path)

    assert_equal path, RubyVM::InstructionSequence.compile(literal).eval
  end

  def test_lint_task_excludes_embedded_acceptance_projects
    exclusions = YAML.safe_load_file(RUBOCOP_CONFIG).fetch("AllCops").fetch("Exclude")

    assert_includes exclusions, "test/fixtures/acceptance/**/*"
  end

  def test_parallel_task_propagates_success_and_failure
    with_loaded_rakefile do
      assert_silent { invoke_parallel_task(success: true) }
      # Re-loading the Rakefile resets Ruby's coverage counters for its other outcome.
      Rake::Task["test:parallel"].reenable
      _stdout, stderr = capture_io do
        error = assert_raises(SystemExit) { invoke_parallel_task(success: false) }
        assert_equal 1, error.status
      end

      assert_includes stderr, "Parallel tests failed"
    end
  end

  private

  def with_loaded_rakefile
    Rake.with_application do
      load File.join(ROOT, "Rakefile")
      yield
    end
  end

  def invoke_parallel_task(success:)
    factory = lambda do |task|
      assert_instance_of Minitest::TestTask, task
      -> { success }
    end
    ParallelTestRunner.stub(:new, factory) { Rake::Task["test:parallel"].invoke }
  end

  def load_acceptance_support
    Open3.capture3(
      unbundled_environment,
      RbConfig.ruby,
      "-w", "-I.", "-e", 'require "test/support/acceptance_project"',
      chdir: ROOT
    )
  end

  def unbundled_environment
    ENV.each_key.grep(/\ABUNDLER?_/).to_h { [_1, nil] }.merge("RUBYLIB" => nil, "RUBYOPT" => nil)
  end
end
