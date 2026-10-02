# frozen_string_literal: true

require "json"
require "tmpdir"
require "test_helper"

module QualityGate
  module Adapters
    class HerbTest < Minitest::Test
      FIXTURE = File.expand_path("../../fixtures/herb/lint_report.json", __dir__)
      FRAMEWORK_MESSAGE = <<~MESSAGE.chomp
        No `framework` is set in `.herb.yml`, so Herb assumes plain `ruby` templates. Set `framework` to one of `ruby`, `actionview`, `hanami`, or `sinatra` so Herb can tailor its assumptions, rules, and optimizations to your framework.
      MESSAGE
      ALT_MESSAGE = <<~MESSAGE.chomp
        Missing required `alt` attribute on `<img>` tag. Add `alt=""` for decorative images or `alt="description"` for informative images.
      MESSAGE

      def test_command_scans_the_project_root_when_no_paths_are_selected
        Dir.mktmpdir do |dir|
          Dir.chdir(dir) do
            assert_equal(
              %w[herb-lint --json --no-github --no-timing --log-level hint .],
              build_adapter.command
            )
          end
        end
      end

      def test_command_uses_the_configured_launcher_and_only_selected_erb_files_and_directories
        Dir.mktmpdir do |dir|
          erb_file = File.join(dir, "view.html.erb")
          ruby_file = File.join(dir, "view.rb")
          views = File.join(dir, "views")
          File.write(erb_file, "<p>view</p>\n")
          File.write(ruby_file, "# Ruby file\n")
          Dir.mkdir(views)

          adapter = build_adapter(
            files: [erb_file, ruby_file, views],
            config: config_with_herb_launcher(%w[bundle exec herb lint])
          )

          assert_equal(
            %w[bundle exec herb lint --json --no-github --no-timing --log-level hint] + [erb_file, views],
            adapter.command
          )
        end
      end

      def test_command_ignores_missing_inputs_and_prefixes_leading_dash_paths
        Dir.mktmpdir do |dir|
          Dir.chdir(dir) do
            File.write("-view.html.erb", "<p>view</p>\n")
            adapter = build_adapter(files: ["missing.html.erb", "-view.html.erb"])

            assert_equal "./-view.html.erb", adapter.command.last
          end
        end
      end

      def test_parse_normalizes_offenses_and_maps_hint_to_info
        findings = build_adapter.parse(File.read(FIXTURE))

        assert_equal(
          [
            Finding.new(
              tool: "herb", file: "app/views/users/show.html.erb", line: 1,
              rule: "herb-config-framework-option", severity: :info,
              message: FRAMEWORK_MESSAGE
            ),
            Finding.new(
              tool: "herb", file: "app/views/users/show.html.erb", line: 1,
              rule: "html-img-require-alt", severity: :warning,
              message: ALT_MESSAGE
            )
          ],
          findings
        )
      end

      def test_parse_rejects_incomplete_or_malformed_reports
        valid = report(offenses: [])
        (malformed_reports(valid) + optional_count_reports).each { assert_invalid_report(_1) }
      end

      def test_parse_maps_hint_severity_to_info
        hint = valid_offense.merge("severity" => "hint")

        assert_equal :info, build_adapter.parse(JSON.dump(report(offenses: [hint]))).first.severity
      end

      def test_call_accepts_clean_and_warning_reports_on_exit_zero_or_one
        warning = valid_offense.merge("severity" => "warning")

        assert_empty call_with(report(offenses: []), exitstatus: 0)
        [0, 1].each { assert_warning_finding(warning, _1) }
      end

      def test_call_accepts_info_and_hint_findings_when_the_threshold_fails
        %w[info hint].each do |severity|
          offense = valid_offense.merge("severity" => severity)
          assert_equal [:info], call_with(report(offenses: [offense]), exitstatus: 1).map(&:severity)
        end
      end

      def test_call_accepts_error_findings_on_exit_one
        error = valid_offense.merge("severity" => "error")

        assert_equal ["html-img-require-alt"], call_with(report(offenses: [error]), exitstatus: 1).map(&:rule)
      end

      def test_call_fails_closed_for_process_or_report_contract_violations
        warning = valid_offense.merge("severity" => "warning")
        invalid_call_cases(warning).each do |payload, exitstatus, exited|
          assert_equal ["tool_failure"], call_with(payload, exitstatus:, exited:).map(&:rule)
        end
      end

      def test_call_includes_subprocess_stderr_when_a_report_or_exit_contract_fails
        responses = [
          ["not json", "malformed report diagnostic\n", fake_status(0)],
          [JSON.dump(report(offenses: [])), "exit status diagnostic\n", fake_status(1)]
        ]

        responses.each do |response|
          failure = adapter_for_response([], response).call.fetch(0)

          assert_predicate failure, :tool_failure?
          assert_includes failure.message, response.fetch(1).strip
        end
      end

      def test_call_does_not_launch_for_an_explicit_unrelated_file_selection
        Dir.mktmpdir do |dir|
          ruby_file = File.join(dir, "example.rb")
          File.write(ruby_file, "puts :hello\n")
          adapter = build_adapter(files: [ruby_file])
          adapter.define_singleton_method(:capture) { |*| flunk "Herb must skip Ruby-only selections" }

          assert_empty adapter.call
        end
      end

      def test_call_returns_a_tool_failure_without_launching_for_an_invalid_timeout
        timeouts = Config.defaults.fetch(:timeouts).merge(herb: 0)
        adapter = build_adapter(config: Config.new(Config.defaults.merge(timeouts:)))
        adapter.define_singleton_method(:capture) { |*| flunk "Herb must not launch with an invalid timeout" }

        failure = adapter.call.fetch(0)

        assert_predicate failure, :tool_failure?
        assert_includes failure.message, "timeout must be a positive Integer"
      end

      def test_call_skips_an_explicit_file_only_when_herb_reports_its_exact_configured_exclusion
        Dir.mktmpdir do |dir|
          excluded_file = write_erb(dir, "excluded.html.erb")
          diagnostic = excluded_diagnostic(excluded_file)
          status = fake_status(0)
          adapter = build_adapter(files: [excluded_file])
          adapter.define_singleton_method(:capture) do |_argv, _timeout|
            ["", diagnostic, status]
          end

          assert_empty adapter.call
        end
      end

      def test_call_processes_a_json_report_instead_of_accepting_an_exclusion_diagnostic_with_stdout
        Dir.mktmpdir do |dir|
          excluded_file = write_erb(dir, "excluded.html.erb")
          warning = valid_offense.merge("severity" => "warning")
          response = [JSON.dump(report(offenses: [warning])), excluded_diagnostic(excluded_file), fake_status(0)]
          adapter = adapter_for_response([excluded_file], response)

          assert_equal ["html-img-require-alt"], adapter.call.map(&:rule)
        end
      end

      def test_call_fails_closed_when_exclusion_diagnostics_claim_unselected_files
        Dir.mktmpdir do |dir|
          selected_file = write_erb(dir, "selected.html.erb")
          adapter = adapter_for_response([selected_file], exclusion_response("other.html.erb"))

          assert_predicate adapter.call.first, :tool_failure?
        end
      end

      def test_call_fails_closed_when_exclusion_diagnostics_mix_recognized_and_unknown_patterns
        Dir.mktmpdir do |dir|
          selected_file = write_erb(dir, "selected.html.erb")
          unknown = excluded_diagnostic("unknown").sub(" is excluded by configuration patterns.", " is excluded.")
          response = exclusion_response(selected_file, unknown)
          adapter = adapter_for_response([selected_file], response)

          assert_predicate adapter.call.first, :tool_failure?
        end
      end

      def test_call_fails_closed_for_malformed_exclusion_trailer_and_non_erb_claim
        Dir.mktmpdir do |dir|
          selected_file = write_erb(dir, "selected.html.erb")
          ruby_file = File.join(dir, "selected.rb")
          File.write(ruby_file, "puts :hello\n")
          malformed = excluded_diagnostic(selected_file).sub("--force to lint it anyway.", "--force to lint it anyway!")
          [malformed, excluded_diagnostic(ruby_file)].each do |diagnostic|
            adapter = adapter_for_response([selected_file, ruby_file], ["", diagnostic, fake_status(0)])
            assert_predicate adapter.call.first, :tool_failure?
          end
        end
      end

      def test_call_returns_a_tool_failure_when_the_process_status_is_missing
        findings = call_with_status(report(offenses: []), nil)

        assert_equal ["tool_failure"], findings.map(&:rule)
      end

      def test_call_does_not_accept_an_exclusion_diagnostic_without_a_process_status
        Dir.mktmpdir do |dir|
          selected_file = write_erb(dir, "selected.html.erb")
          response = ["", excluded_diagnostic(selected_file), nil]
          adapter = adapter_for_response([selected_file], response)

          assert_predicate adapter.call.first, :tool_failure?
        end
      end

      def test_call_retries_remaining_inputs_after_herb_identifies_an_excluded_selection
        Dir.mktmpdir do |dir|
          excluded_file = write_erb(dir, "excluded.html.erb")
          included_file = write_erb(dir, "included.html.erb")
          adapter = build_adapter(files: [excluded_file, included_file])
          assert_retry_result(
            adapter, exclusion_responses(excluded_file, [included_file]),
            [[excluded_file, included_file], [included_file]], [included_file]
          )
        end
      end

      def test_call_continues_removing_each_exactly_excluded_file_until_remaining_files_are_scanned
        Dir.mktmpdir do |dir|
          excluded_files = [write_erb(dir, "excluded-one.html.erb"), write_erb(dir, "excluded-two.html.erb")]
          included_file = write_erb(dir, "included.html.erb")
          adapter = build_adapter(files: excluded_files + [included_file])
          paths = [excluded_files + [included_file], [excluded_files.last, included_file], [included_file]]
          responses = excluded_file_responses(excluded_files) + [success_response(included_file)]
          assert_retry_result(adapter, responses, paths, [included_file])
        end
      end

      def test_call_fails_closed_for_unrecognized_or_contradictory_exclusion_diagnostics
        Dir.mktmpdir do |dir|
          excluded_file = write_erb(dir, "excluded.html.erb")
          invalid_exclusion_responses(excluded_file).each do |response|
            adapter = build_adapter(files: [excluded_file])
            adapter.define_singleton_method(:capture) { |_argv, _timeout| response }

            assert_predicate adapter.call.first, :tool_failure?
          end
        end
      end

      def test_call_uses_one_timeout_budget_across_exclusion_retries
        Dir.mktmpdir do |dir|
          excluded_file = write_erb(dir, "excluded.html.erb")
          adapter = build_adapter(files: [excluded_file, write_erb(dir, "included.html.erb")])
          queried_remaining = probe_timeout_retries(adapter, excluded_file)
          assert_predicate adapter.call.first, :tool_failure?
          assert_equal 1, queried_remaining.length
        end
      end

      def test_timeout_before_an_exclusion_retry_does_not_reuse_prior_stderr
        Dir.mktmpdir do |dir|
          excluded_file = write_erb(dir, "excluded.html.erb")
          adapter = build_adapter(files: [excluded_file, write_erb(dir, "included.html.erb")])
          failure = timeout_after_exclusion_retry(adapter, excluded_file)

          assert_predicate failure, :tool_failure?
          assert_includes failure.message, "timeout during exclusion retry"
          refute_includes failure.message, "excluded by configuration patterns"
        end
      end

      private

      def malformed_reports(valid)
        invalid_envelopes(valid) + invalid_offenses
      end

      def invalid_envelopes(valid)
        [[], valid.except("completed"), valid.merge("completed" => false),
         valid.merge("clean" => false), valid.merge("clean" => nil),
         valid.merge("offenses" => {}), valid.merge("summary" => nil),
         valid.merge("summary" => valid.fetch("summary").merge("totalErrors" => 1))]
      end

      def invalid_offenses
        invalid_identity_offenses + invalid_location_offenses + invalid_metadata_offenses
      end

      def invalid_identity_offenses
        [report(offenses: [valid_offense.except("filename")]),
         report(offenses: [valid_offense.merge("message" => nil)]),
         malformed_offense_report, report(offenses: [valid_offense.merge("code" => nil)])]
      end

      def invalid_location_offenses
        [report(offenses: [valid_offense.merge("location" => {})]),
         report(offenses: [valid_offense.merge("location" => nil)]),
         report(offenses: [valid_offense.merge("location" => { "start" => [] })]),
         report(offenses: [valid_offense.merge("location" => { "start" => { "line" => 0 } })])]
      end

      def invalid_metadata_offenses
        [report(offenses: [valid_offense.merge("severity" => "critical")])]
      end

      def optional_count_reports
        info = valid_offense.merge("severity" => "info")
        [nil, 0].map do |total_info|
          payload = report(offenses: [info])
          payload.merge("summary" => payload.fetch("summary").merge("totalInfo" => total_info))
        end
      end

      def malformed_offense_report
        report(offenses: []).merge("offenses" => [nil])
      end

      def assert_invalid_report(invalid_report)
        assert_raises(ParseError) { build_adapter.parse(JSON.dump(invalid_report)) }
      end

      def assert_warning_finding(warning, status)
        findings = call_with(report(offenses: [warning]), exitstatus: status)
        assert_equal ["html-img-require-alt"], findings.map(&:rule)
      end

      def assert_retry_result(adapter, responses, expected_paths, expected_files)
        commands = []
        queue_captures(adapter, responses, commands)
        assert_equal expected_files, adapter.call.map(&:file)
        assert_equal expected_paths, command_paths(commands)
      end

      def command_paths(commands) = commands.map { _1.drop(6) }

      def probe_timeout_retries(adapter, excluded_file)
        remaining = [0]
        queried_remaining = []
        diagnostic = excluded_diagnostic(excluded_file)
        adapter.define_singleton_method(:capture) { |_argv, _timeout| ["", diagnostic, fake_status(0)] }
        adapter.define_singleton_method(:remaining_before) do |deadline|
          queried_remaining << deadline
          remaining.shift
        end
        queried_remaining
      end

      def timeout_after_exclusion_retry(adapter, excluded_file)
        remaining = [1, 0]
        response = exclusion_response(excluded_file)
        adapter.define_singleton_method(:capture) { |_argv, _timeout| response }
        adapter.define_singleton_method(:remaining_before) { |_deadline| remaining.shift }
        adapter.call.fetch(0)
      end

      def invalid_call_cases(warning)
        [
          [report(offenses: []), 1, true], [report(offenses: [warning]), 0, false],
          [report(offenses: [warning]).merge("clean" => true), 0, true],
          [report(offenses: [valid_offense.merge("severity" => "error")]), 0, true],
          [report(offenses: [warning]), 2, true], [report(offenses: []), 0, false]
        ]
      end

      def exclusion_responses(excluded_file, included_files)
        [["", excluded_diagnostic(excluded_file), fake_status(0)]] + included_files.map { success_response(_1) }
      end

      def excluded_file_responses(files)
        files.map { ["", excluded_diagnostic(_1), fake_status(0)] }
      end

      def success_response(file)
        [JSON.dump(report(offenses: [valid_offense.merge("filename" => file)])), "", fake_status(0)]
      end

      def invalid_exclusion_responses(file)
        [
          ["", excluded_diagnostic(file).sub(file, "another.html.erb"), fake_status(0)],
          ["", "#{excluded_diagnostic(file)}extra output\n", fake_status(0)],
          ["", excluded_diagnostic(file), fake_status(1)], ["", "not an exclusion\n", fake_status(0)]
        ]
      end

      def queue_captures(adapter, responses, commands)
        adapter.define_singleton_method(:capture) do |argv, _timeout|
          commands << argv
          responses.shift
        end
      end

      def build_adapter(config: Config.new(Config.defaults), files: [])
        Herb.new(config:, files:)
      end

      def config_with_herb_launcher(argv)
        defaults = Config.defaults
        commands = defaults.fetch(:commands).merge(fast: { herb: argv })
        Config.new(defaults.merge(commands:))
      end

      def call_with(payload, exitstatus:, exited: true)
        call_with_status(payload, fake_status(exitstatus, exited:))
      end

      def call_with_status(payload, status)
        adapter = build_adapter
        adapter.define_singleton_method(:capture) do |_argv, _timeout|
          [JSON.dump(payload), "", status]
        end
        adapter.call
      end

      def adapter_for_response(files, response)
        adapter = build_adapter(files:)
        adapter.define_singleton_method(:capture) { |_argv, _timeout| response }
        adapter
      end

      def exclusion_response(path, extra_stderr = "")
        ["", excluded_diagnostic(path) + extra_stderr, fake_status(0)]
      end

      def write_erb(dir, filename)
        path = File.join(dir, filename)
        File.write(path, "<p>template</p>\n")
        path
      end

      def excluded_diagnostic(path)
        "⚠️  File #{path} is excluded by configuration patterns.\n   Use --force to lint it anyway.\n\n"
      end

      def fake_status(exitstatus, exited: true)
        Struct.new(:exited?, :exitstatus).new(exited, exitstatus)
      end

      def report(offenses:)
        {
          "offenses" => offenses,
          "summary" => {
            "totalErrors" => offenses.count { _1["severity"] == "error" },
            "totalWarnings" => offenses.count { _1["severity"] == "warning" },
            "totalInfo" => offenses.count { _1["severity"] == "info" },
            "totalHints" => offenses.count { _1["severity"] == "hint" },
            "totalOffenses" => offenses.count { %w[error warning].include?(_1["severity"]) }
          },
          "completed" => true,
          "clean" => offenses.none? { %w[error warning].include?(_1["severity"]) }
        }
      end

      def valid_offense
        {
          "filename" => "app/views/users/show.html.erb",
          "message" => "Missing required alt attribute.",
          "location" => { "start" => { "line" => 4, "column" => 0 } },
          "severity" => "warning",
          "code" => "html-img-require-alt"
        }
      end
    end
  end
end
