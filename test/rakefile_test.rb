# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require "yaml"
require_relative "support/acceptance_project"

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

  private

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
