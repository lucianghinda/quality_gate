# frozen_string_literal: true

require "json"
require "stringio"
require "test_helper"

module QualityGate
  module Adapters
    class DatabaseConsistencyTest < Minitest::Test
      def test_parses_findings_and_source_location_with_colons
        finding = adapter.parse(envelope([report("fail", source_location: "db/schema:backup.rb:17")])).first

        assert_finding_identity(finding)
        assert_equal ["db/schema:backup.rb", 17], [finding.file, finding.line]
      end

      def test_omits_ok_reports_and_maps_warning_reports
        findings = adapter.parse(envelope([report("ok"), warning_report]))

        assert_equal 1, findings.length
        assert_warning_finding(findings.first)
      end

      def test_uses_empty_location_when_upstream_omits_it
        finding = adapter.parse(envelope([report("fail", source_location: nil)])).first

        assert_equal ["", 0], [finding.file, finding.line]
      end

      def test_supported_patch_version_and_extra_report_fields_are_accepted
        finding = adapter.parse(envelope([report("warning", extra: "ignored")], version: "3.0.15")).first

        assert_equal :warning, finding.severity
      end

      def test_missing_context_does_not_add_an_empty_prefix
        report_hash = report(
          "warning",
          table_or_model_name: nil,
          column_or_attribute_name: nil,
          error_message: "Database inconsistent", error_slug: nil
        )
        finding = adapter.parse(envelope([report_hash])).first

        assert_equal "Database inconsistent", finding.message
        refute_includes finding.message, ":"
      end

      def test_parse_rejects_malformed_json_and_non_object_envelopes
        ["{", JSON.dump([])].each { assert_invalid_report(_1) }
      end

      def test_parse_rejects_unsupported_versions
        invalid = [
          JSON.dump("version" => 2, "analyzer_version" => "3.0.14", "reports" => []),
          JSON.dump("version" => 1.0, "analyzer_version" => "3.0.14", "reports" => []),
          JSON.dump("version" => 1, "analyzer_version" => "3.1.0", "reports" => []),
          envelope([], version: "3.0.13"),
          envelope([], version: "invalid")
        ]
        invalid.each { assert_invalid_report(_1) }
      end

      def test_parse_rejects_reports_with_invalid_required_field_types
        invalid = [
          envelope(["not a report"]),
          envelope([report("ok", checker_name: nil)]),
          envelope([report("ok", table_or_model_name: 7)]),
          envelope([report("ok", column_or_attribute_name: [])]),
          envelope([report("ok", error_slug: 7)]),
          envelope([report("ok", error_message: false)])
        ]
        invalid.each { assert_invalid_report(_1) }
      end

      def test_parse_requires_reports_to_be_present_as_an_array
        invalid = [
          JSON.dump("version" => 1, "analyzer_version" => "3.0.14"),
          JSON.dump("version" => 1, "analyzer_version" => "3.0.14", "reports" => {})
        ]

        invalid.each { assert_invalid_report(_1) }
      end

      def test_parse_requires_each_base_report_field_even_for_ok_reports
        %w[checker_name table_or_model_name column_or_attribute_name status error_slug error_message].each do |field|
          report_hash = report("ok")
          report_hash.delete(field)

          assert_invalid_report(envelope([report_hash]))
        end
      end

      def test_parse_rejects_invalid_status_message_and_source_locations
        invalid = [
          envelope([report("nope")]),
          envelope([report("fail", error_message: nil, error_slug: nil)]),
          envelope([report("fail", source_location: "db/users.rb:zero")]),
          envelope([report("fail", source_location: "db/users.rb:0")]),
          envelope([report("fail", source_location: 7)])
        ]
        invalid.each { assert_invalid_report(_1) }
      end

      def test_call_requires_successful_process_and_preserves_stderr
        instance = adapter_with_capture(envelope([report("ok")]), "analyzer crashed", status(2))
        failure = instance.call.first

        assert failure.tool_failure?
        assert_includes failure.message, "analyzer crashed"
      end

      def test_call_fails_closed_for_signal_missing_status_and_unsupported_exit_statuses
        [status(1), status(2), status(0, exited: false), nil].each do |process_status|
          failure = adapter_with_capture(envelope([]), "diagnostic", process_status).call.first
          assert failure.tool_failure?
          assert_includes failure.message, "diagnostic"
        end
      end

      def test_call_fails_closed_when_the_configured_launcher_is_missing
        failure = missing_launcher_adapter.call.first

        assert failure.tool_failure?
        assert_includes failure.message, "No such file"
      end

      def test_call_uses_the_configured_timeout
        config = Config.new(
          Config.defaults.merge(
            commands: { audit: { database_consistency: [RbConfig.ruby, "-e", "sleep 3"] } },
            timeouts: Config.defaults.fetch(:timeouts).merge(database_consistency: 1)
          )
        )
        failure = Adapters::DatabaseConsistency.new(config:).call.first

        assert failure.tool_failure?
        assert_includes failure.message, "timeout after 1 seconds"
      end

      def test_default_command_uses_ruby_and_custom_prefix_gets_the_bridge_path
        assert_equal RbConfig.ruby, adapter.command.first
        assert_equal bridge_path, adapter.command.last
        assert_equal %w[bundle exec ruby] + [bridge_path], configured_adapter.command
      end

      private

      def adapter
        Adapters::DatabaseConsistency.new(config: Config.new(Config.defaults), diagnostic_io: StringIO.new)
      end

      def configured_adapter
        commands = { audit: { database_consistency: %w[bundle exec ruby] } }
        Adapters::DatabaseConsistency.new(config: Config.new(Config.defaults.merge(commands:)))
      end

      def missing_launcher_adapter
        commands = { audit: { database_consistency: ["/no/such/database-consistency-launcher"] } }
        config = Config.new(Config.defaults.merge(commands:))
        Adapters::DatabaseConsistency.new(config:)
      end

      def bridge_path
        File.expand_path("../../../lib/quality_gate/database_consistency_runner.rb", __dir__)
      end

      def assert_finding_identity(finding)
        assert_equal "database_consistency", finding.tool
        assert_equal "ForeignKey", finding.rule
        assert_equal :error, finding.severity
        assert_equal "User profile_email: Email type mismatch", finding.message
      end

      def assert_warning_finding(finding)
        assert_equal :warning, finding.severity
        assert_equal "Index", finding.rule
        assert_equal "User profile_email: missing index", finding.message
      end

      def warning_report
        report("warning", checker_name: "Index", error_slug: "missing_index", error_message: nil)
      end

      def adapter_with_capture(stdout, stderr, process_status)
        instance = adapter
        instance.define_singleton_method(:capture) { |_argv, _timeout| [stdout, stderr, process_status] }
        instance
      end

      def assert_invalid_report(stdout)
        assert_raises(ParseError) { adapter.parse(stdout) }
      end

      def envelope(reports, version: "3.0.14", version_number: 1)
        JSON.dump("version" => version_number, "analyzer_version" => version, "reports" => reports)
      end

      def report(status, **attributes)
        {
          "checker_name" => "ForeignKey",
          "table_or_model_name" => "User",
          "column_or_attribute_name" => "profile_email",
          "status" => status,
          "error_slug" => "type_mismatch",
          "error_message" => "Email type mismatch",
          "source_location" => "app/models/user.rb:8"
        }.merge(attributes.transform_keys(&:to_s))
      end

      def status(exitstatus, exited: true)
        Struct.new(:exitstatus) do
          define_method(:exited?) { exited }
          def success? = exitstatus.zero?
        end.new(exitstatus)
      end
    end
  end
end
