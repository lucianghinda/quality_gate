# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

module QualityGate
  # Runs the packaged security tools against dynamically built projects and advisory databases.
  class SecurityAdaptersIntegrationTest < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)
    EXECUTABLE = File.join(ROOT, "exe", "quality_gate")
    FALLBACK_WARNING = "bundler_audit: advisory database update failed; using cached database\n"

    def test_clean_default_audit_has_no_findings_or_tool_failures
      with_project do |project|
        database = create_advisory_database(project, gem_name: "unrelated-gem", cve: "2099-9999")

        stdout, stderr, status = run_audit(project, database)
        report = JSON.parse(stdout)

        assert_equal ExitCode::CLEAN, status.exitstatus, audit_failure_message(stdout, stderr)
        assert_empty report.fetch("findings")
        assert_equal({ "findings" => 0, "tool_failures" => 0, "failed_tools" => [] }, report.fetch("summary"))
        assert_empty stderr
      end
    end

    def test_tool_path_puts_the_active_ruby_before_gem_binstubs_and_the_ambient_path
      path_entries = executable_path.split(File::PATH_SEPARATOR)
      ruby_bin = File.dirname(RbConfig.ruby)
      tool_bins = [
        Gem.bin_path("brakeman", "brakeman", "~> 8.0"),
        Gem.bin_path("bundler-audit", "bundle-audit", "~> 0.9.3")
      ].map { File.dirname(_1) }
      expected_prefix = [ruby_bin] + tool_bins

      assert_equal expected_prefix, path_entries.first(expected_prefix.length)
    end

    # rubocop:disable Metrics/AbcSize
    def test_unsafe_app_and_cached_advisory_are_reported_in_adapter_order
      with_project(unsafe: true) do |project|
        database = create_advisory_database(project, gem_name: "rake", cve: "2099-0001")
        initialize_failing_git_remote(database)

        stdout, stderr, status = run_audit(project, database)
        report = JSON.parse(stdout)
        findings = report.fetch("findings")

        assert_equal ExitCode::FINDINGS, status.exitstatus, audit_failure_message(stdout, stderr)
        assert_equal(%w[brakeman bundler_audit], findings.map { _1.fetch("tool") })
        assert_equal "Command Injection", findings.first.fetch("rule")
        assert_equal "error", findings.first.fetch("severity")
        assert_equal "CVE-2099-0001", findings.last.fetch("rule")
        assert_equal "Gemfile.lock", findings.last.fetch("file")
        assert_equal 0, findings.last.fetch("line")
        assert_equal({ "findings" => 2, "tool_failures" => 0, "failed_tools" => [] }, report.fetch("summary"))
        assert_equal FALLBACK_WARNING, stderr
      end
    end
    # rubocop:enable Metrics/AbcSize

    private

    def with_project(unsafe: false)
      Dir.mktmpdir("quality-gate-security-app") do |project|
        write_project(project, unsafe: unsafe)
        yield project
      end
    end

    def write_project(project, unsafe:)
      write_file(project, "Gemfile", "source \"https://rubygems.org\"\ngem \"rails\", \"~> 8.1\"\n")
      write_file(project, "Gemfile.lock", gemfile_lock)
      write_file(project, "config/application.rb", application_config)
      write_file(project, "config/routes.rb", routes)
      write_file(project, "config/brakeman.yml", "{}\n")
      write_file(project, "app/controllers/application_controller.rb", application_controller)
      write_file(project, "app/controllers/commands_controller.rb", commands_controller(unsafe: unsafe))
    end

    def write_file(root, path, contents)
      absolute_path = File.join(root, path)
      FileUtils.mkdir_p(File.dirname(absolute_path))
      File.write(absolute_path, contents)
    end

    def application_config
      <<~RUBY
        require "rails/all"

        module SecurityFixture
          class Application < Rails::Application
            config.load_defaults 8.1
            config.force_ssl = true
          end
        end
      RUBY
    end

    def application_controller
      <<~RUBY
        class ApplicationController < ActionController::Base
          protect_from_forgery with: :exception
        end
      RUBY
    end

    def routes
      "Rails.application.routes.draw { get \"commands\", to: \"commands#index\" }\n"
    end

    def commands_controller(unsafe:)
      body = unsafe ? "    system(params[:command])\n" : "    head :no_content\n"

      <<~RUBY
        class CommandsController < ApplicationController
          def index
        #{body.rstrip}
          end
        end
      RUBY
    end

    def gemfile_lock
      <<~LOCK
        GEM
          remote: https://rubygems.org/
          specs:
            rake (13.4.2)

        PLATFORMS
          ruby

        DEPENDENCIES
          rake (= 13.4.2)

        BUNDLED WITH
           4.0.16
      LOCK
    end

    def create_advisory_database(project, gem_name:, cve:)
      database = File.join(project, "advisory-db")
      advisory_path = File.join("gems", gem_name, "CVE-#{cve}.yml")
      write_file(database, advisory_path, advisory_yaml(cve))
      database
    end

    def advisory_yaml(cve)
      <<~YAML
        ---
        cve: #{cve}
        url: https://example.invalid/CVE-#{cve}
        title: Test advisory
        date: 2099-01-01
        description: A deterministic integration-test advisory.
        cvss_v3: 9.0
        patched_versions:
          - ">= 99.0.0"
      YAML
    end

    def initialize_failing_git_remote(database)
      run_git(database, "init", "--initial-branch=master", "--quiet")
      run_git(database, "remote", "add", "origin", File.join(database, "missing-origin"))
    end

    def run_git(directory, *arguments)
      _stdout, stderr, status = Open3.capture3("git", *arguments, chdir: directory)
      assert_predicate status, :success?, stderr
    end

    def run_audit(project, database)
      Open3.capture3(
        audit_environment(database),
        RbConfig.ruby,
        EXECUTABLE,
        "audit",
        "--format",
        "json",
        chdir: project
      )
    end

    def audit_environment(database)
      unbundled_environment.merge(
        "BUNDLER_AUDIT_DB" => database,
        "BUNDLE_GEMFILE" => nil,
        "RUBYLIB" => File.join(ROOT, "lib"),
        "RUBYOPT" => nil,
        "PATH" => executable_path
      )
    end

    def audit_failure_message(stdout, stderr)
      "audit subprocess failed\nstdout: #{stdout}\nstderr: #{stderr}"
    end

    def unbundled_environment
      ENV.each_key.grep(/\ABUNDLER?_/).to_h { [_1, nil] }
    end

    def executable_path
      ruby_bin = File.dirname(RbConfig.ruby)
      bins = [
        Gem.bin_path("brakeman", "brakeman", "~> 8.0"),
        Gem.bin_path("bundler-audit", "bundle-audit", "~> 0.9.3")
      ].map { File.dirname(_1) }

      ([ruby_bin] + bins + [ENV.fetch("PATH")]).uniq.join(File::PATH_SEPARATOR)
    end
  end
end
