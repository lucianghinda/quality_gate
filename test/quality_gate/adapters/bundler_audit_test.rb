# frozen_string_literal: true

require "json"
require "fileutils"
require "stringio"
require "tmpdir"
require "test_helper"

module QualityGate
  module Adapters
    class BundlerAuditTest < Minitest::Test
      ROOT = File.expand_path("../../..", __dir__)
      FIXTURES = File.join(ROOT, "test", "fixtures", "bundler_audit")
      FALLBACK_WARNING = "bundler_audit: advisory database update failed; using cached database\n"

      def test_load_wiring_name_lock_file_and_update_command
        adapter = build_adapter(files: ["other.lock"])

        assert defined?(QualityGate::Adapters::BundlerAudit)
        assert_equal "bundler_audit", adapter.name
        assert_equal "Gemfile.lock", QualityGate::Adapters::BundlerAudit::LOCK_FILE
        assert_predicate QualityGate::Adapters::BundlerAudit::LOCK_FILE, :frozen?
        assert_equal %w[bundle-audit check --update --format json --quiet], adapter.command
      end

      def test_parse_turns_recorded_advisories_into_findings_in_report_order
        findings = build_adapter.parse(fixture("advisories_report.json"))

        assert_equal expected_recorded_findings, findings
      end

      def test_parse_returns_empty_for_a_clean_report
        assert_equal [], build_adapter.parse(JSON.dump("results" => []))
      end

      def test_parse_prefers_cve_then_ghsa_then_advisory_id
        report = report_with(
          advisory_identifiers(cve: "CVE-2026-1000", ghsa: "GHSA-first-one"),
          advisory_identifiers(id: "OSVDB-22", cve: nil, ghsa: "second-one"),
          advisory_identifiers(id: "RUBYSEC-2026-3", cve: nil, ghsa: nil)
        )
        findings = build_adapter.parse(report)

        assert_equal %w[CVE-2026-1000 GHSA-second-one RUBYSEC-2026-3], findings.map(&:rule)
      end

      # rubocop:disable Metrics/AbcSize
      def test_parse_names_the_first_patch_or_absence_of_a_patch
        report = report_with(
          advisory_with_patches([">= 4.2.1", ">= 5.0"]),
          advisory_with_patches([], id: "RUBYSEC-2", cve: nil)
        )
        findings = build_adapter.parse(report)

        assert_includes findings.fetch(0).message, "demo 4.2.0"
        assert_includes findings.fetch(0).message, ">= 4.2.1"
        assert_includes findings.fetch(1).message, "demo 4.2.0"
        assert_includes findings.fetch(1).message, "no patched version exists"
      end
      # rubocop:enable Metrics/AbcSize

      def test_parse_raises_parse_error_for_invalid_json
        error = assert_raises(ParseError) { build_adapter.parse("{") }

        assert_equal "bundler_audit", error.tool
      end

      # rubocop:disable Metrics/AbcSize
      def test_parse_raises_parse_error_for_invalid_report_shapes
        missing_advisory_id = valid_advisory.tap { _1.delete("id") }
        invalid_patches = valid_advisory.merge("patched_versions" => {})
        invalid_reports = {
          "report not object" => [],
          "missing results" => {},
          "results not array" => { "results" => {} },
          "result not object" => { "results" => ["bad"] },
          "missing type" => report_hash(advisory_without_result_field("type")),
          "type not string" => report_hash(advisory({ "type" => 7 })),
          "unknown result type" => report_hash(advisory({ "type" => "insecure_source" })),
          "gem not object" => report_hash(advisory({ "gem" => "demo" })),
          "missing gem name" => report_hash(advisory({ "gem" => { "version" => "4.2.0" } })),
          "empty gem name" => report_hash(advisory({ "gem" => { "name" => "", "version" => "4.2.0" } })),
          "gem version not string" => report_hash(advisory({ "gem" => { "name" => "demo", "version" => 42 } })),
          "advisory not object" => report_hash(advisory({ "advisory" => [] })),
          "missing advisory id" => report_hash(advisory("advisory" => missing_advisory_id)),
          "empty advisory id" => report_hash(advisory({ "advisory" => valid_advisory.merge("id" => "") })),
          "cve not string or nil" => report_hash(advisory({ "advisory" => valid_advisory.merge("cve" => 7) })),
          "empty cve" => report_hash(advisory({ "advisory" => valid_advisory.merge("cve" => "") })),
          "ghsa not string or nil" => report_hash(advisory({ "advisory" => valid_advisory.merge("ghsa" => []) })),
          "empty ghsa" => report_hash(advisory({ "advisory" => valid_advisory.merge("ghsa" => "") })),
          "patches not array" => report_hash(advisory("advisory" => invalid_patches)),
          "patch not string" => report_hash(advisory({ "advisory" => valid_advisory.merge("patched_versions" => [7]) }))
        }

        invalid_reports.each do |description, report|
          assert_raises(ParseError, description) { build_adapter.parse(JSON.dump(report)) }
        end
      end
      # rubocop:enable Metrics/AbcSize

      def test_parse_does_not_hide_type_errors_from_parser_collaborators
        adapter = build_adapter
        adapter.define_singleton_method(:parse_results) { |_results| raise TypeError, "adapter type bug" }

        error = assert_raises(TypeError) { adapter.parse('{"results":[]}') }

        assert_equal "adapter type bug", error.message
      end

      def test_parse_does_not_hide_argument_errors_from_parser_collaborators
        adapter = build_adapter
        adapter.define_singleton_method(:parse_results) { |_results| raise ArgumentError, "adapter argument bug" }

        error = assert_raises(ArgumentError) { adapter.parse('{"results":[]}') }

        assert_equal "adapter argument bug", error.message
      end

      def test_call_accepts_exit_one_when_stdout_is_valid_advisory_json
        with_database(populated: true) do |database|
          adapter = adapter_capturing(
            [[fixture("advisories_report.json"), "", status(success: false)]]
          )

          findings = with_database_env(database) { adapter.call }

          assert_equal 2, findings.length
          refute findings.any?(&:tool_failure?)
          assert_equal [%w[bundle-audit check --update --format json --quiet]], adapter.captured_commands
        end
      end

      def test_call_returns_clean_for_valid_empty_json_from_a_successful_process
        with_database(populated: true) do |database|
          adapter = adapter_capturing([[JSON.dump("results" => []), "", status(success: true)]])

          assert_equal [], with_database_env(database) { adapter.call }
        end
      end

      def test_call_fails_closed_for_valid_empty_json_without_a_usable_database
        with_database(populated: false) do |database|
          File.write(File.join(database, "README.md"), "not an advisory database")
          adapter = adapter_capturing([[JSON.dump("results" => []), "", status(success: true)]])

          findings = with_database_env(database) { adapter.call }

          assert_one_tool_failure(findings)
          assert_equal 1, adapter.captured_commands.length
        end
      end

      def test_call_fails_closed_without_fallback_for_malformed_successful_output
        with_database(populated: true) do |database|
          adapter = adapter_capturing([["not json", "", status(success: true)]])

          findings = with_database_env(database) { adapter.call }

          assert_one_tool_failure(findings)
          assert_equal 1, adapter.captured_commands.length
        end
      end

      def test_call_retries_against_cached_database_after_update_failure
        with_database(populated: true) do |database|
          diagnostic_io = StringIO.new
          adapter = adapter_capturing(
            [
              ["update failed", "network unavailable", status(success: false)],
              [fixture("advisories_report.json"), "", status(success: false)]
            ],
            diagnostic_io:
          )

          findings = with_database_env(database) { adapter.call }

          assert_fallback_success(findings, diagnostic_io.string, adapter)
        end
      end

      def test_cached_retry_receives_only_the_remaining_timeout_budget
        with_database(populated: true) do |database|
          adapter = adapter_capturing(
            [
              ["update failed", "", status(success: false)],
              [fixture("advisories_report.json"), "", status(success: false)]
            ],
            config: config_with_timeout(10)
          )

          findings = with_monotonic_times(100.0, 101.0, 106.0) do
            with_database_env(database) { adapter.call }
          end

          assert_equal 2, findings.length
          assert_equal [9.0, 4.0], adapter.captured_timeouts
        end
      end

      def test_cached_retry_does_not_start_when_update_consumes_the_timeout_budget
        with_database(populated: true) do |database|
          adapter = adapter_capturing(
            [
              ["update failed", "", status(success: false)],
              [fixture("advisories_report.json"), "", status(success: false)]
            ],
            config: config_with_timeout(10)
          )

          findings = with_monotonic_times(100.0, 101.0, 110.0) do
            with_database_env(database) { adapter.call }
          end

          assert_one_tool_failure(findings)
          assert_equal [%w[bundle-audit check --update --format json --quiet]], adapter.captured_commands
          assert_equal [9.0], adapter.captured_timeouts
        end
      end

      def test_call_retries_cached_database_after_update_timeout
        with_database(populated: true) do |database|
          diagnostic_io = StringIO.new
          adapter = adapter_capturing(
            [timeout_error("update timed out"), [fixture("advisories_report.json"), "", status(success: false)]],
            diagnostic_io:
          )

          findings = with_database_env(database) { adapter.call }

          assert_fallback_success(findings, diagnostic_io.string, adapter)
        end
      end

      def test_call_returns_one_tool_failure_after_update_timeout_without_cache
        with_database(populated: false) do |database|
          adapter = adapter_capturing([timeout_error("update timed out")])

          findings = with_database_env(database) { adapter.call }

          assert_one_tool_failure(findings)
          assert_equal 1, adapter.captured_commands.length
        end
      end

      def test_call_does_not_fallback_for_programming_errors
        with_database(populated: true) do |database|
          adapter = adapter_capturing([RuntimeError.new("adapter bug")])

          findings = with_database_env(database) { adapter.call }

          assert_one_tool_failure(findings)
          assert_includes findings.first.message, "adapter bug"
          assert_equal 1, adapter.captured_commands.length
        end
      end

      def test_call_returns_one_tool_failure_when_database_path_is_missing
        Dir.mktmpdir do |dir|
          missing_database = File.join(dir, "missing")
          adapter = adapter_capturing([["", "network unavailable", status(success: false)]])

          findings = with_database_env(missing_database) { adapter.call }

          assert_one_tool_failure(findings)
          assert_equal 1, adapter.captured_commands.length
        end
      end

      def test_call_returns_one_tool_failure_when_database_directory_is_empty
        with_database(populated: false) do |database|
          adapter = adapter_capturing([["", "network unavailable", status(success: false)]])

          findings = with_database_env(database) { adapter.call }

          assert_one_tool_failure(findings)
          assert_equal 1, adapter.captured_commands.length
        end
      end

      def test_call_returns_one_tool_failure_when_cached_check_is_unreadable
        with_database(populated: true) do |database|
          adapter = adapter_capturing(
            [
              ["", "update-stage-only", status(success: false)],
              ["also not json", "", status(success: false)]
            ]
          )

          findings = with_database_env(database) { adapter.call }

          assert_fallback_failure(findings, adapter)
          refute_includes findings.first.message, "update-stage-only"
        end
      end

      def test_call_fails_closed_when_fallback_warning_cannot_be_written
        with_database(populated: true) do |database|
          diagnostic_io = StringIO.new
          diagnostic_io.close
          adapter = adapter_capturing(
            [
              ["", "update failed", status(success: false)],
              [fixture("advisories_report.json"), "", status(success: false)]
            ],
            diagnostic_io:
          )

          findings = with_database_env(database) { adapter.call }

          assert_one_tool_failure(findings)
        end
      end

      def test_call_normalizes_capture_errors_to_one_tool_failure
        adapter = build_adapter
        adapter.define_singleton_method(:capture) { |_argv, _timeout| raise Errno::ENOENT, "bundle-audit" }

        assert_one_tool_failure(adapter.call)
      end

      def test_local_database_uses_environment_path_dynamically
        with_database(populated: true) do |database|
          adapter = build_adapter

          assert with_database_env(database) { adapter.send(:local_database?) }
          refute with_database_env(File.join(database, "missing")) { adapter.send(:local_database?) }
        end
      end

      def test_local_database_uses_gem_user_home_when_environment_is_unset
        Dir.mktmpdir do |home|
          database = File.join(home, ".local", "share", "ruby-advisory-db")
          populate_database(database)

          Gem.stub(:user_home, home) do
            with_database_env(nil) { assert build_adapter.send(:local_database?) }
          end
        end
      end

      def test_local_database_rejects_readme_only_and_unrelated_yaml_layouts
        Dir.mktmpdir do |database|
          File.write(File.join(database, "README.md"), "not enough")
          FileUtils.mkdir_p(File.join(database, "unrelated"))
          File.write(File.join(database, "unrelated", "CVE-2099-1.yml"), "not in gems layout")

          with_database_env(database) { refute build_adapter.send(:local_database?) }
        end
      end

      def test_local_database_treats_filesystem_errors_as_absent
        with_database(populated: true) do |database|
          Dir.stub(:children, ->(_path) { raise Errno::EACCES, database }) do
            with_database_env(database) { refute build_adapter.send(:local_database?) }
          end
        end
      end

      private

      def build_adapter(files: [], config: Config.new(Config.defaults), diagnostic_io: StringIO.new)
        QualityGate::Adapters::BundlerAudit.new(config:, files:, diagnostic_io:)
      end

      def adapter_capturing(responses, **adapter_options)
        build_adapter(**adapter_options).tap do |adapter|
          adapter.define_singleton_method(:captured_commands) { @captured_commands ||= [] }
          adapter.define_singleton_method(:captured_timeouts) { @captured_timeouts ||= [] }
          adapter.define_singleton_method(:capture) do |argv, timeout_seconds|
            captured_commands << argv
            captured_timeouts << timeout_seconds
            response = responses.shift || flunk("unexpected capture")
            raise response if response.is_a?(Exception)

            response
          end
        end
      end

      def timeout_error(message)
        Adapter.const_get(:TimeoutError, false).new(message)
      end

      def config_with_timeout(seconds)
        settings = Config.defaults.merge(timeouts: { default: 120, bundler_audit: seconds })
        Config.new(settings)
      end

      def with_monotonic_times(*times, &block)
        clock = ->(_clock) { times.empty? ? flunk("unexpected monotonic clock read") : times.shift }
        Process.stub(:clock_gettime, clock, &block)
      end

      def status(success:)
        Object.new.tap { _1.define_singleton_method(:success?) { success } }
      end

      def fixture(name)
        File.read(File.join(FIXTURES, name))
      end

      def report_with(*results)
        JSON.dump("results" => results)
      end

      def report_hash(result)
        { "results" => [result] }
      end

      def advisory(overrides = {})
        { "type" => "unpatched_gem", "gem" => valid_gem, "advisory" => valid_advisory }.merge(overrides)
      end

      def advisory_identifiers(id: "CVE-2026-1000", cve: "2026-1000", ghsa: nil)
        advisory("advisory" => valid_advisory.merge("id" => id, "cve" => cve, "ghsa" => ghsa))
      end

      def advisory_with_patches(patches, id: "CVE-2026-1000", cve: "2026-1000")
        attributes = valid_advisory.merge("id" => id, "cve" => cve, "patched_versions" => patches)
        advisory("advisory" => attributes)
      end

      def advisory_without_result_field(field)
        advisory.tap { _1.delete(field) }
      end

      def valid_gem
        { "name" => "demo", "version" => "4.2.0" }
      end

      def valid_advisory
        {
          "id" => "CVE-2026-1000",
          "cve" => "2026-1000",
          "ghsa" => nil,
          "patched_versions" => [">= 4.2.1"]
        }
      end

      def expected_recorded_findings
        [
          Finding.new(
            tool: "bundler_audit",
            file: "Gemfile.lock",
            line: 0,
            rule: "CVE-2025-24293",
            severity: :error,
            message: "actionpack 7.1.5.1 is vulnerable; update to >= 7.1.5.2"
          ),
          Finding.new(
            tool: "bundler_audit",
            file: "Gemfile.lock",
            line: 0,
            rule: "GHSA-cj83-2ww7-mg7c",
            severity: :error,
            message: "rack 3.0.10 is vulnerable; update to >= 3.0.11"
          )
        ]
      end

      def expected_update_and_cached_commands
        [
          %w[bundle-audit check --update --format json --quiet],
          %w[bundle-audit check --no-update --format json --quiet]
        ]
      end

      def assert_one_tool_failure(findings)
        assert_equal 1, findings.length
        assert findings.first.tool_failure?
        assert_equal "bundler_audit", findings.first.tool
        assert_equal :error, findings.first.severity
      end

      def assert_fallback_success(findings, stderr, adapter)
        assert_equal 2, findings.length
        refute findings.any?(&:tool_failure?)
        assert_equal FALLBACK_WARNING, stderr
        assert_equal expected_update_and_cached_commands, adapter.captured_commands
      end

      def assert_fallback_failure(findings, adapter)
        assert_one_tool_failure(findings)
        assert_equal expected_update_and_cached_commands, adapter.captured_commands
      end

      def with_database(populated:)
        Dir.mktmpdir do |database|
          populate_database(database) if populated
          yield database
        end
      end

      def populate_database(database)
        advisory_directory = File.join(database, "gems", "demo")
        FileUtils.mkdir_p(advisory_directory)
        File.write(File.join(advisory_directory, "CVE-2099-0001.yml"), "---\ngem: demo\n")
      end

      def with_database_env(path)
        original = ENV["BUNDLER_AUDIT_DB"]
        path ? ENV["BUNDLER_AUDIT_DB"] = path : ENV.delete("BUNDLER_AUDIT_DB")
        yield
      ensure
        original ? ENV["BUNDLER_AUDIT_DB"] = original : ENV.delete("BUNDLER_AUDIT_DB")
      end
    end
  end
end
