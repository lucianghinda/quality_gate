# frozen_string_literal: true

require "test_helper"

require "json"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

module QualityGate
  module Adapters
    class UndercoverTest < Minitest::Test
      class ProcessGuardUndercover < Undercover
        attr_reader :command_started

        def command
          @command_started = true
          raise "Undercover process must not start"
        end
      end

      class CommandUndercover < Undercover
        def initialize(command:, **keywords)
          super(**keywords)
          @command = command
        end

        attr_reader :command
      end

      def test_adapter_is_available_through_the_top_level_require
        assert defined?(Undercover), "expected QualityGate::Adapters::Undercover to be loaded"
      end

      def test_public_identity_and_constants
        adapter = build_adapter

        assert_equal "undercover", adapter.name
        assert_equal "coverage/coverage.json", Undercover::COVERAGE_PATH
        assert_equal "undercover_skipped", Undercover::SKIP_RULE
        assert_predicate Undercover::COVERAGE_PATH, :frozen?
        assert_predicate Undercover::SKIP_RULE, :frozen?
      end

      # rubocop:disable Metrics/AbcSize
      def test_parse_turns_each_warning_into_one_actionable_finding
        findings = build_adapter.parse(fixture("warnings_report.json"))

        assert_equal 2, findings.length
        first = findings.fetch(0)
        assert_equal "undercover", first.tool
        assert_equal "app/models/user.rb", first.file
        assert_equal 12, first.line
        assert_equal "uncovered_code", first.rule
        assert_equal :warning, first.severity
        assert_includes first.message, "instance method"
        assert_includes first.message, "User#active?"
        assert_includes first.message, "lines 12-18"
        assert_includes first.message, "coverage 0.5"
        assert_includes first.message, "uncovered lines 15, 16"
        assert_includes first.message, "line 14"
        assert_includes first.message, "else"

        second = findings.fetch(1)
        assert_equal "app/services/reports.rb", second.file
        assert_equal 4, second.line
        assert_includes second.message, "lines 4-6"
        assert_includes second.message, "uncovered branches none"
      end
      # rubocop:enable Metrics/AbcSize

      def test_parse_returns_no_findings_for_a_clean_report
        json = JSON.generate("warnings" => [], "summary" => { "total_warnings" => 0, "files_affected" => 0 })

        assert_equal [], build_adapter.parse(json)
      end

      def test_parse_accepts_the_pinned_cli_timing_footer_after_json
        json = JSON.generate("warnings" => [], "summary" => { "total_warnings" => 0, "files_affected" => 0 })
        output = "#{json}\nUndercover finished in 0.0123s\n"

        assert_equal [], build_adapter.parse(output)
      end

      def test_parse_rejects_non_exact_content_after_the_pinned_cli_footer
        json = JSON.generate("warnings" => [], "summary" => { "total_warnings" => 0, "files_affected" => 0 })
        output = "#{json}\nUndercover finished in 0.0123s unexpected\n"

        assert_raises(ParseError) { build_adapter.parse(output) }
      end

      def test_parse_wraps_invalid_json_as_a_standard_parse_error
        error = assert_raises(ParseError) { build_adapter.parse("not JSON") }

        assert_equal "undercover", error.tool
        assert_includes error.message, "undercover"
      end

      def test_parse_wraps_a_non_mapping_json_root_as_a_standard_parse_error
        error = assert_raises(ParseError) { build_adapter.parse("null") }

        assert_equal "undercover", error.tool
      end

      def test_parse_rejects_a_malformed_warning_shape
        json = JSON.generate("warnings" => [{ "file" => "app/models/user.rb" }], "summary" => {})

        error = assert_raises(ParseError) { build_adapter.parse(json) }

        assert_equal "undercover", error.tool
      end

      def test_configured_compare_point_is_used_verbatim_in_the_argv
        adapter = build_adapter(config: config_with_point("release-base"))

        assert_equal "release-base", adapter.compare_point
        assert_equal(
          %w[undercover --compare release-base --simplecov coverage/coverage.json --format json],
          adapter.command
        )
      end

      def test_compare_point_is_the_common_ancestor_with_local_main
        in_repository(initial_branch: "main") do |dir, base_commit|
          git(dir, "checkout", "-b", "feature")
          commit_file(dir, "feature.rb", "feature\n", "feature")

          Dir.chdir(dir) do
            adapter = build_adapter

            assert_equal base_commit, adapter.compare_point
            assert_equal base_commit, adapter.command.fetch(2)
          end
        end
      end

      def test_origin_head_is_preferred_over_a_local_main_branch
        in_repository(initial_branch: "main") do |dir, base_commit|
          default_commit = commit_file(dir, "default.rb", "remote default\n", "remote default")
          git(dir, "update-ref", "refs/remotes/origin/trunk", default_commit)
          git(dir, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk")
          git(dir, "checkout", "-b", "feature")
          commit_file(dir, "feature.rb", "feature\n", "feature")
          git(dir, "branch", "-f", "main", base_commit)

          actual_commit = Dir.chdir(dir) { build_adapter.compare_point }

          assert_equal default_commit, actual_commit
        end
      end

      def test_master_is_used_when_origin_head_and_main_are_absent
        in_repository(initial_branch: "master") do |dir, base_commit|
          git(dir, "checkout", "-b", "feature")
          commit_file(dir, "feature.rb", "feature\n", "feature")

          Dir.chdir(dir) do
            assert_equal base_commit, build_adapter.compare_point
          end
        end
      end

      # rubocop:disable Metrics/AbcSize
      def test_missing_coverage_is_checked_before_comparison_and_does_not_start_undercover
        Dir.mktmpdir do |dir|
          Dir.chdir(dir) do
            adapter = ProcessGuardUndercover.new(config: Config.new(Config.defaults))

            findings = adapter.call

            assert_equal 1, findings.length
            finding = findings.fetch(0)
            assert finding.tool_failure?
            assert_equal "undercover", finding.tool
            assert_equal :error, finding.severity
            assert_includes finding.message, "coverage/coverage.json"
            assert_includes finding.message, "SimpleCov"
            assert_includes finding.message, "bin/rails generate quality_gate:install"
            assert_includes finding.message, "bundle exec quality_gate init --profile ruby"
            refute adapter.command_started
          end
        end
      end
      # rubocop:enable Metrics/AbcSize

      def test_exit_one_with_valid_warning_json_returns_coverage_findings
        Dir.mktmpdir do |dir|
          write_coverage_record(dir)
          adapter = command_adapter("puts ARGV.fetch(0); exit 1", cli_output(fixture("warnings_report.json")))

          Dir.chdir(dir) do
            findings = adapter.call

            assert_equal 2, findings.length
            assert(findings.all? { _1.rule == "uncovered_code" })
            refute findings.any?(&:tool_failure?)
          end
        end
      end

      def test_malformed_process_output_becomes_one_standard_tool_failure
        Dir.mktmpdir do |dir|
          write_coverage_record(dir)
          adapter = command_adapter("puts 'not JSON'; puts 'Undercover finished in 0.0123s'; exit 1")

          Dir.chdir(dir) do
            findings = adapter.call

            assert_equal 1, findings.length
            assert findings.fetch(0).tool_failure?
            assert_includes findings.fetch(0).message, "parse"
          end
        end
      end

      def test_shallow_repository_returns_an_explicit_skip_note
        in_shallow_feature_clone do |dir|
          finding, adapter = skip_finding_in(dir)

          assert_includes finding.message, "shallow"
          assert_includes finding.message, "compare_point"
          refute adapter.command_started
        end
      end

      def test_missing_default_branch_returns_an_explicit_skip_note
        in_repository(initial_branch: "feature") do |dir, _base_commit|
          commit_file(dir, "second.rb", "second\n", "second")
          finding, adapter = skip_finding_in(dir)

          assert_includes finding.message, "default branch"
          assert_includes finding.message, "main"
          assert_includes finding.message, "missing"
          refute adapter.command_started
        end
      end

      def test_first_commit_returns_an_explicit_skip_note
        in_repository(initial_branch: "feature") do |dir, _base_commit|
          finding, adapter = skip_finding_in(dir)

          assert_includes finding.message, "no earlier commit"
          refute adapter.command_started
        end
      end

      def test_root_commit_on_main_returns_an_explicit_skip_note
        in_repository(initial_branch: "main") do |dir, _base_commit|
          finding, adapter = skip_finding_in(dir)

          assert_includes finding.message, "no earlier commit"
          refute adapter.command_started
        end
      end

      def test_configured_compare_point_still_wins_on_a_root_commit
        in_repository(initial_branch: "main") do |dir, _base_commit|
          actual = Dir.chdir(dir) { build_adapter(config: config_with_point("release-base")).compare_point }

          assert_equal "release-base", actual
        end
      end

      def test_detached_unrelated_checkout_returns_an_explicit_skip_note
        in_repository(initial_branch: "main") do |dir, _base_commit|
          detach_unrelated_commit(dir)

          finding, adapter = skip_finding_in(dir)

          assert_includes finding.message, "detached"
          assert_includes finding.message, "no shared ancestor"
          refute adapter.command_started
        end
      end

      private

      def build_adapter(config: Config.new(Config.defaults))
        Undercover.new(config:)
      end

      def config_with_point(point)
        Config.new(Config.defaults.merge(compare_point: point))
      end

      def fixture(name)
        File.read(File.expand_path("../../fixtures/undercover/#{name}", __dir__))
      end

      def cli_output(json)
        "#{json.rstrip}\nUndercover finished in 0.0123s"
      end

      def in_repository(initial_branch:)
        Dir.mktmpdir do |dir|
          git(dir, "init", "--initial-branch", initial_branch)
          base_commit = commit_file(dir, "base.rb", "base\n", "base")
          yield dir, base_commit
        end
      end

      def commit_file(dir, file, contents, message)
        File.write(File.join(dir, file), contents)
        git(dir, "add", file)
        git(
          dir,
          "-c", "user.name=Quality Gate Test",
          "-c", "user.email=quality-gate@example.test",
          "commit", "--quiet", "-m", message
        )
        git(dir, "rev-parse", "HEAD").strip
      end

      def git(dir, *arguments)
        stdout, stderr, status = Open3.capture3("git", *arguments, chdir: dir)
        assert_predicate status, :success?, "git #{arguments.join(" ")} failed: #{stderr}"
        stdout
      end

      def detach_unrelated_commit(dir)
        git(dir, "checkout", "--orphan", "unrelated")
        File.write(File.join(dir, "unrelated.rb"), "unrelated\n")
        git(dir, "add", "--all")
        git_commit(dir, "unrelated")
        git(dir, "checkout", "--detach")
      end

      def git_commit(dir, message)
        git(
          dir,
          "-c", "user.name=Quality Gate Test",
          "-c", "user.email=quality-gate@example.test",
          "commit", "--quiet", "-m", message
        )
      end

      def in_shallow_feature_clone
        Dir.mktmpdir do |root|
          source = build_source_repository(root)
          clone = File.join(root, "clone")
          clone_shallow_feature(root, source, clone)
          git(clone, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
          yield clone
        end
      end

      def build_source_repository(root)
        source = File.join(root, "source")
        Dir.mkdir(source)
        git(source, "init", "--initial-branch", "main")
        commit_file(source, "base.rb", "base\n", "base")
        git(source, "checkout", "-b", "feature")
        commit_file(source, "feature.rb", "feature\n", "feature")
        source
      end

      def clone_shallow_feature(root, source, clone)
        git(
          root, "clone", "--quiet", "--depth", "1", "--branch", "feature",
          "--single-branch", "file://#{source}", clone
        )
      end

      def skip_finding_in(dir)
        write_coverage_record(dir)

        Dir.chdir(dir) do
          adapter = ProcessGuardUndercover.new(config: Config.new(Config.defaults))
          findings = adapter.call

          assert_equal 1, findings.length
          finding = findings.fetch(0)
          assert_skip_finding(finding)
          return finding, adapter
        end
      end

      def assert_skip_finding(finding)
        refute finding.tool_failure?
        assert_equal "undercover", finding.tool
        assert_equal Undercover::SKIP_RULE, finding.rule
        assert_equal :info, finding.severity
      end

      def write_coverage_record(dir)
        FileUtils.mkdir_p(File.join(dir, "coverage"))
        File.write(File.join(dir, Undercover::COVERAGE_PATH), "{}")
      end

      def ruby_command(script, *arguments)
        [RbConfig.ruby, "-e", script, *arguments]
      end

      def command_adapter(script, *arguments)
        CommandUndercover.new(
          command: ruby_command(script, *arguments),
          config: config_with_point("HEAD~1")
        )
      end
    end
  end
end
