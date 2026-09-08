# frozen_string_literal: true

require "test_helper"

require "fileutils"
require "json"
require "open3"
require "tmpdir"

module Acceptance
  # Proves the acceptance catalogue and its disposable clean host stay executable.
  class IncidentCatalogTest < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)
    CATALOGUE = File.join(ROOT, "docs/incidents.md")
    FIXTURES = File.join(ROOT, "test/fixtures/acceptance")
    GEMSPEC = File.join(ROOT, "quality_gate.gemspec")
    SUPPORT = File.join(ROOT, "test/support/acceptance_project.rb")
    INCIDENT_IDS = %w[n_plus_one unsafe_migration complexity_creep untested_change].freeze
    EXPECTED_FINDINGS = {
      "n_plus_one" => {
        tool: "test_suite",
        rule: "test_failure",
        cause: ["USE eager loading", "AcceptanceRecord => [:comments]"].freeze,
        file: "",
        line: 0
      },
      "unsafe_migration" => {
        tool: "test_suite",
        rule: "test_failure",
        cause: "Dangerous operation detected #strong_migrations",
        file: "",
        line: 0
      },
      "complexity_creep" => {
        tool: "rubocop",
        rule: "Metrics/*",
        cause: "matching emitted metric name"
      },
      "untested_change" => {
        tool: "undercover",
        rule: "uncovered_code",
        cause: "lines 6-8",
        file: "lib/calculator.rb",
        line: 6
      }
    }.freeze
    FALLBACK_WARNING = "bundler_audit: advisory database update failed; using cached database\n"
    HOSTILE_RAILS_ENVIRONMENT = {
      "DATABASE_URL" => "postgres://hostile.invalid/production",
      "PIDFILE" => "/tmp/hostile-quality-gate.pid",
      "PORT" => "65_535",
      "RACK_ENV" => "production",
      "RAILS_ENV" => "production",
      "RAILS_LOG_TO_STDOUT" => "1",
      "RAILS_MASTER_KEY" => "hostile-master-key",
      "RAILS_MAX_THREADS" => "99",
      "RAILS_SERVE_STATIC_FILES" => "1",
      "SECRET_KEY_BASE" => "hostile-secret-key-base",
      "WEB_CONCURRENCY" => "8"
    }.freeze

    def test_catalogue_has_the_four_sourced_executable_contracts
      rows = catalogue_rows

      assert_equal INCIDENT_IDS.sort, rows.map { _1.fetch("id") }.sort
      assert_equal INCIDENT_IDS.length, rows.length
      rows.each do |row|
        %w[source example command tool rule cause].each do |column|
          refute_empty row.fetch(column), "#{row.fetch("id")} must include #{column}"
        end
      end
    end

    def test_each_incident_has_a_matching_fixture_directory
      catalogue_rows.each do |row|
        identifier = row.fetch("id")
        expected = File.join(FIXTURES, identifier)

        assert File.directory?(expected), "#{identifier} must have fixture directory #{expected}"
        assert_includes row.fetch("example"), "test/fixtures/acceptance/#{identifier}"
      end
    end

    def test_catalogue_source_links_resolve_to_packaged_documents
      targets = catalogue_rows.flat_map { markdown_link_targets(_1.fetch("source")) }.uniq
      packaged_files = Gem::Specification.load(GEMSPEC).files

      refute_empty targets, "incident sources must contain Markdown links"
      targets.each { assert_packaged_catalogue_source(_1, packaged_files) }
    end

    def test_fixture_tree_contains_no_project_settings_file
      settings = Dir.glob(File.join(FIXTURES, "**/.quality_gate.yml"), File::FNM_DOTMATCH)

      assert_empty settings, "acceptance fixtures must use shipped defaults: #{settings.join(", ")}"
    end

    def test_catalogue_explains_how_to_capture_the_next_escaped_class
      procedure = catalogue_document.split(/^## Capture the next escaped class\s*$/, 2).fetch(1, "")

      assert_match(/written source/i, procedure)
      assert_match(/minimal fixture/i, procedure)
      assert_match(/failing expected-finding assertion/i, procedure)
    end

    def test_expected_finding_diagnostic_includes_the_contract_when_no_findings_appear
      error = expected_finding_failure(id: "untested_change", findings: [])

      assert_expected_diagnostic(error, id: "untested_change")
      assert_includes error.message, "observed findings: none"
    end

    def test_expected_finding_diagnostic_lists_every_wrong_tool_and_rule
      findings = [
        finding(tool: "test_suite", rule: "test_failure", message: "an unrelated test failed"),
        finding(tool: "rubocop", rule: "Metrics/CyclomaticComplexity", message: "Cyclomatic complexity")
      ]

      error = expected_finding_failure(id: "untested_change", findings:)

      assert_expected_diagnostic(error, id: "untested_change")
      assert_observed_finding_diagnostics(error, findings)
    end

    def test_expected_finding_diagnostic_rejects_the_right_tool_and_rule_with_the_wrong_cause
      observed = finding(
        tool: "undercover",
        rule: "uncovered_code",
        message: "lib/calculator.rb has uncovered lines 6-80"
      )

      error = expected_finding_failure(id: "untested_change", findings: [observed])

      assert_expected_diagnostic(error, id: "untested_change")
      assert_includes error.message, observed.fetch("message")
    end

    def test_expected_finding_rejects_the_same_range_from_the_wrong_location
      findings = [
        undercover_finding(file: "lib/unrelated.rb", line: 6),
        undercover_finding(file: "lib/calculator.rb", line: 12)
      ]

      error = expected_finding_failure(id: "untested_change", findings:)

      assert_expected_diagnostic(error, id: "untested_change")
      assert_includes error.message, 'file="lib/calculator.rb", line=6'
      assert_observed_finding_diagnostics(error, findings)
    end

    def test_untested_exemplar_cannot_satisfy_the_complexity_contract
      observed = finding(tool: "undercover", rule: "uncovered_code", message: "uncovered lines 6-8")
      error = expected_finding_failure(id: "complexity_creep", findings: [observed])

      assert_expected_diagnostic(error, id: "complexity_creep")
      assert_observed_finding_diagnostics(error, [observed])
    end

    def test_real_generator_materializes_the_acceptance_host
      acceptance_project.open(fixture: "clean", repository_root: ROOT) do |project|
        assert_includes project.install, "Quality Gate install summary:"

        run = project.run("fast", "--files", "lib/calculator.rb")

        assert_equal 0, run.status, run_diagnostic(run)
        assert_empty run.report.fetch("findings")
        assert_empty run.stderr
      end
    end

    def test_complexity_creep_reports_the_emitted_metric_and_its_name
      acceptance_project.open(fixture: "complexity_creep", repository_root: ROOT) do |project|
        run = project.run("fast", "--files", "complex_method.rb")

        assert_expected_finding(id: "complexity_creep", report: run.report)
      end
    end

    def test_n_plus_one_reports_bullets_eager_loading_notification
      acceptance_project.open(fixture: "n_plus_one", repository_root: ROOT) do |project|
        run = project.run("verify")

        assert_expected_finding(id: "n_plus_one", report: run.report)
        assert_rejects_expected_finding(id: "unsafe_migration", report: run.report)
      end
    end

    def test_unsafe_migration_reports_strong_migrations_dangerous_operation
      acceptance_project.open(fixture: "unsafe_migration", repository_root: ROOT) do |project|
        run = project.run("verify")

        assert_expected_finding(id: "unsafe_migration", report: run.report)
        assert_rejects_expected_finding(id: "n_plus_one", report: run.report)
      end
    end

    def test_untested_change_reports_the_exact_changed_line_range
      acceptance_project.open(fixture: "untested_change", repository_root: ROOT) do |project|
        run = project.run("verify")

        assert_expected_finding(id: "untested_change", report: run.report)
      end
    end

    def test_malformed_cli_report_fails_with_complete_subprocess_diagnostics
      acceptance_project.open(fixture: "clean", repository_root: ROOT) do |project|
        process_status = Data.define(:exitstatus).new(2)
        capture = ->(*) { ["not-json", "broken stderr", process_status] }

        error = Open3.stub(:capture3, capture) do
          assert_raises(JSON::ParserError) { project.run("fast") }
        end

        assert_includes error.message, "status: 2"
        assert_includes error.message, "stdout: \"not-json\""
        assert_includes error.message, "stderr: \"broken stderr\""
      end
    end

    def test_clean_fixture_passes_every_shipped_gate
      with_environment(HOSTILE_RAILS_ENVIRONMENT) do
        acceptance_project.open(fixture: "clean", repository_root: ROOT) do |project|
          runs = %w[fast verify audit].to_h { [_1, project.run(_1)] }
          failures = runs.filter_map do |command, run|
            "#{command}: #{run_diagnostic(run)}" unless clean_run?(command, run)
          end

          assert_empty failures, failures.join("\n")
        end
      end
    end

    def test_hostile_git_environment_cannot_redirect_or_block_fixture_commits
      Dir.mktmpdir("quality-gate-hostile-git") do |directory|
        with_environment(write_hostile_git_environment(directory)) do
          assert_project_materializes_cleanly(
            repository_root: ROOT,
            command: "verify",
            failure: "hostile Git environment escaped isolation"
          )
        end
      end
    end

    def test_default_global_git_config_cannot_hide_fixture_changes
      Dir.mktmpdir("quality-gate-hostile-home") do |directory|
        write_hostile_default_git_config(directory)

        with_environment("HOME" => directory) do
          acceptance_project.open(fixture: "untested_change", repository_root: ROOT) do |project|
            assert_expected_finding(id: "untested_change", report: project.run("verify").report)
          end
        end
      end
    end

    def test_repository_path_is_serialized_as_a_ruby_string_literal
      Dir.mktmpdir("quality-gate-repository-path") do |directory|
        aliased_root = File.join(directory, "quality'gate\\repository")
        File.symlink(ROOT, aliased_root)
        assert_project_materializes_cleanly(
          repository_root: aliased_root,
          command: "fast",
          arguments: %w[--files lib/calculator.rb],
          failure: "escaped repository path could not materialize"
        )
      end
    end

    private

    def acceptance_project
      assert File.file?(SUPPORT), "acceptance support must exist at #{SUPPORT}"
      require SUPPORT
      QualityGate::AcceptanceProject
    end

    def catalogue_document
      assert File.file?(CATALOGUE), "incident catalogue must exist at #{CATALOGUE}"
      File.read(CATALOGUE)
    end

    def catalogue_rows
      lines = catalogue_document.lines.grep(/^\|/)
      headings = table_cells(lines.fetch(0, ""))

      lines.drop(2).map { headings.zip(table_cells(_1)).to_h }
    end

    def table_cells(line)
      line.strip.split("|", -1)[1...-1].to_a.map(&:strip)
    end

    def markdown_link_targets(text)
      text.scan(/\[[^\]]+\]\(([^)]+)\)/).flatten
    end

    def assert_packaged_catalogue_source(target, packaged_files)
      relative_target = target.split("#", 2).first
      source = File.expand_path(relative_target, File.dirname(CATALOGUE))
      packaged_path = source.delete_prefix("#{ROOT}/")

      assert_path_exists source, "incident source link does not resolve: #{target}"
      assert_includes packaged_files, packaged_path, "incident source is not packaged: #{target}"
    end

    def run_diagnostic(run)
      "status=#{run.status}; report=#{run.report.inspect}; stdout=#{run.stdout.inspect}; stderr=#{run.stderr.inspect}"
    end

    def assert_expected_finding(id:, report:)
      expected = EXPECTED_FINDINGS.fetch(id)
      findings = report.fetch("findings")

      assert findings.any? { expected_finding?(_1, expected) }, expected_finding_diagnostic(id, expected, findings)
    end

    def expected_finding?(finding, expected)
      finding.fetch("tool") == expected.fetch(:tool) &&
        expected_location?(finding, expected) &&
        expected_rule?(finding.fetch("rule"), expected.fetch(:rule)) &&
        expected_cause?(finding, expected.fetch(:cause))
    end

    def expected_location?(finding, expected)
      return true unless expected.key?(:file)

      finding.fetch("file") == expected.fetch(:file) && finding.fetch("line") == expected.fetch(:line)
    end

    def expected_rule?(rule, expected)
      return rule.match?(%r{\AMetrics/[^/]+\z}) if expected == "Metrics/*"

      rule == expected
    end

    def expected_cause?(finding, expected)
      return expected.all? { finding.fetch("message").include?(_1) } if expected.is_a?(Array)
      return expected_metric_cause?(finding) if expected == "matching emitted metric name"
      return expected_line_range?(finding.fetch("message"), expected) if expected.match?(/\Alines \d+-\d+\z/)

      finding.fetch("message").include?(expected)
    end

    def expected_line_range?(message, expected)
      message.match?(/\b#{Regexp.escape(expected)}\b/)
    end

    def expected_metric_cause?(finding)
      metric = Regexp.escape(metric_name(finding.fetch("rule")))
      finding.fetch("message").match?(/\b#{metric}\b/i)
    end

    def metric_name(rule)
      rule.delete_prefix("Metrics/").gsub(/([a-z\d])([A-Z])/, "\\1 \\2")
    end

    def expected_finding_diagnostic(id, expected, findings)
      "exemplar #{id.inspect}: #{expected_contract(expected)}; " \
        "observed findings: #{observed_findings(findings)}"
    end

    def expected_contract(expected)
      "expected tool=#{expected.fetch(:tool).inspect}, rule=#{expected.fetch(:rule).inspect}, " \
        "cause=#{expected.fetch(:cause).inspect}#{expected_location_contract(expected)}"
    end

    def expected_location_contract(expected)
      return "" unless expected.key?(:file)

      ", file=#{expected.fetch(:file).inspect}, line=#{expected.fetch(:line).inspect}"
    end

    def observed_findings(findings)
      return "none" if findings.empty?

      findings.map.with_index(1) { observed_finding(_1, _2) }.join("; ")
    end

    def observed_finding(finding, index)
      "#{index}. tool=#{finding.fetch("tool").inspect}, file=#{finding.fetch("file").inspect}, " \
        "line=#{finding.fetch("line").inspect}, rule=#{finding.fetch("rule").inspect}, " \
        "message=#{finding.fetch("message").inspect}"
    end

    def assert_expected_diagnostic(error, id:)
      expected = EXPECTED_FINDINGS.fetch(id)

      assert_includes error.message, id
      expected.each_value { assert_includes error.message, _1.to_s }
    end

    def assert_observed_finding_diagnostics(error, findings)
      findings.each do |observed|
        observed.values_at("tool", "file", "line", "rule", "message").each do |value|
          assert_includes error.message, value.inspect
        end
      end
    end

    def finding(tool:, rule:, message:, file: "lib/example.rb", line: 1)
      { "tool" => tool, "file" => file, "line" => line, "rule" => rule, "message" => message }
    end

    def undercover_finding(file:, line:)
      finding(tool: "undercover", file:, line:, rule: "uncovered_code", message: "uncovered lines 6-8")
    end

    def expected_finding_failure(id:, findings:)
      assert_raises(Minitest::Assertion) do
        assert_expected_finding(id:, report: { "findings" => findings })
      end
    end

    def assert_rejects_expected_finding(id:, report:)
      error = expected_finding_failure(id:, findings: report.fetch("findings"))

      assert_expected_diagnostic(error, id:)
      assert_observed_finding_diagnostics(error, report.fetch("findings"))
    end

    def clean_run?(command, run)
      expected_stderr = command == "audit" ? FALLBACK_WARNING : ""
      run.status.zero? &&
        run.report.fetch("findings").empty? &&
        run.report.fetch("summary").fetch("tool_failures").zero? &&
        run.stderr == expected_stderr
    end

    def with_environment(overrides)
      original = ENV.to_h
      ENV.update(overrides)
      yield
    ensure
      ENV.replace(original)
    end

    def assert_project_materializes_cleanly(repository_root:, command:, failure:, arguments: [])
      acceptance_project.open(fixture: "clean", repository_root:) do |project|
        run = project.run(command, *arguments)
        assert_equal 0, run.status, run_diagnostic(run)
        assert_empty run.report.fetch("findings")
      end
    rescue StandardError => e
      flunk "#{failure}: #{e.message}"
    end

    def write_hostile_git_environment(directory)
      hooks = File.join(directory, "hooks")
      FileUtils.mkdir_p(hooks)
      write_failure_hook(hooks)
      config = write_hostile_git_config(directory, hooks)

      hostile_git_environment(directory, config)
    end

    def write_hostile_default_git_config(directory)
      excludes = File.join(directory, "global-excludes")
      File.write(excludes, "lib/calculator.rb\n")
      File.write(File.join(directory, ".gitconfig"), <<~CONFIG)
        [core]
          excludesFile = #{excludes}
      CONFIG
    end

    def write_failure_hook(hooks)
      hook = File.join(hooks, "pre-commit")
      File.write(hook, "#!/usr/bin/env ruby\nexit 91\n")
      FileUtils.chmod(0o755, hook)
    end

    def write_hostile_git_config(directory, hooks)
      File.join(directory, "gitconfig").tap do |config|
        File.write(config, <<~CONFIG)
          [commit]
            gpgSign = true
          [core]
            hooksPath = #{hooks}
        CONFIG
      end
    end

    def hostile_git_environment(directory, config)
      {
        "GIT_CONFIG_GLOBAL" => config,
        "GIT_CONFIG_SYSTEM" => config,
        "GIT_DIR" => File.join(directory, "redirected.git"),
        "GIT_WORK_TREE" => directory
      }
    end
  end
end
