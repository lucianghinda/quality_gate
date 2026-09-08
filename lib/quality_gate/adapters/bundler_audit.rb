# frozen_string_literal: true

require "json"
require "rubygems"

module QualityGate
  module Adapters
    # Runs bundler-audit and falls back to a usable local advisory database.
    # rubocop:disable Metrics/ClassLength
    class BundlerAudit < Adapter
      class InvalidReport < StandardError; end
      class UnavailableDatabase < StandardError; end
      private_constant :InvalidReport, :UnavailableDatabase

      LOCK_FILE = "Gemfile.lock".freeze # rubocop:disable Style/RedundantFreeze
      FALLBACK_WARNING = "bundler_audit: advisory database update failed; using cached database"
      private_constant :FALLBACK_WARNING

      def call
        tool = name
        argv = validated_command
        timeout_seconds = resolved_timeout(tool)
        deadline = monotonic_deadline(timeout_seconds)
        updated_findings(tool, argv, deadline, timeout_seconds)
      rescue StandardError => e
        [failure_finding(tool, e, "")]
      end

      def name = "bundler_audit"

      def command = %w[bundle-audit check --update --format json --quiet]

      def parse(stdout)
        report = parse_report(stdout)
        results = report.fetch("results") { invalid_report!("report must include results") }
        parse_results(results)
      rescue JSON::ParserError, InvalidReport => e
        raise ParseError.new(tool: name, reason: e.message)
      end

      private

      def updated_findings(tool, argv, deadline, timeout_seconds)
        stderr = +""
        stdout, stderr, status = capture(argv, remaining_timeout(deadline, timeout_seconds))
        findings = parse_and_validate(stdout, tool)
        return findings if local_database?

        unavailable_database_failure(tool, stderr)
      rescue ParseError => e
        return [failure_finding(tool, e, stderr)] if status&.success?

        fallback_findings(tool, e, stderr, deadline, timeout_seconds)
      rescue TimeoutError, SystemCallError, IOError, ThreadError => e
        fallback_findings(tool, e, stderr, deadline, timeout_seconds)
      end

      def parse_and_validate(stdout, tool)
        findings = parse(stdout)
        validate_findings!(findings, expected_tool: tool)
        findings
      end

      def fallback_findings(tool, update_error, update_stderr, deadline, timeout_seconds)
        return [failure_finding(tool, update_error, update_stderr)] unless local_database?

        cached_findings(tool, deadline, timeout_seconds)
      end

      def cached_findings(tool, deadline, timeout_seconds)
        cached_stderr = +""
        stdout, cached_stderr, = capture(cached_command, remaining_timeout(deadline, timeout_seconds))
        findings = parse_and_validate(stdout, tool)
        emit_fallback_warning(tool, findings, cached_stderr)
      rescue ParseError, TimeoutError, SystemCallError, IOError, ThreadError => e
        [failure_finding(tool, e, cached_stderr)]
      end

      def cached_command = %w[bundle-audit check --no-update --format json --quiet]

      def remaining_timeout(deadline, timeout_seconds)
        remaining = remaining_before(deadline)
        return remaining if remaining.positive?

        raise TimeoutError, "timeout after #{timeout_seconds} seconds"
      end

      def unavailable_database_failure(tool, stderr)
        error = UnavailableDatabase.new("no usable advisory database is available")
        [failure_finding(tool, error, stderr)]
      end

      def emit_fallback_warning(tool, findings, cached_stderr)
        diagnostic_io.puts FALLBACK_WARNING
        findings
      rescue StandardError => e
        [failure_finding(tool, e, cached_stderr)]
      end

      def parse_report(stdout)
        report = JSON.parse(stdout)
        invalid_report!("report must be a JSON object") unless report.is_a?(Hash)

        report
      end

      def parse_results(results)
        invalid_report!("results must be an array") unless results.is_a?(Array)

        results.map { build_finding(_1) }
      end

      def build_finding(result)
        invalid_report!("result must be an object") unless result.is_a?(Hash)
        validate_result_type(result)

        gem = object_field(result, "gem", owner: "result")
        advisory = object_field(result, "advisory", owner: "result")
        Finding.new(tool: name, **finding_attributes(gem, advisory))
      end

      def validate_result_type(result)
        type = string_field(result, "type", owner: "result")
        return if type == "unpatched_gem"

        invalid_report!("unsupported result type #{type.inspect}")
      end

      def finding_attributes(gem, advisory)
        gem_name = nonempty_string_field(gem, "name", owner: "gem")
        installed_version = nonempty_string_field(gem, "version", owner: "gem")
        patches = patched_versions(advisory)

        {
          file: LOCK_FILE,
          line: 0,
          rule: advisory_rule(advisory),
          severity: :error,
          message: advisory_message(gem_name, installed_version, patches.first)
        }
      end

      def advisory_rule(advisory)
        cve = optional_identifier(advisory, "cve")
        ghsa = optional_identifier(advisory, "ghsa")
        advisory_id = nonempty_string_field(advisory, "id", owner: "advisory")

        return prefixed_identifier(cve, "CVE-") if cve
        return prefixed_identifier(ghsa, "GHSA-") if ghsa

        advisory_id
      end

      def advisory_message(gem_name, installed_version, patched_version)
        subject = "#{gem_name} #{installed_version} is vulnerable"
        return "#{subject}; update to #{patched_version}" if patched_version

        "#{subject}; no patched version exists"
      end

      def patched_versions(advisory)
        patches = advisory.fetch("patched_versions") do
          invalid_report!("advisory must include patched_versions")
        end
        unless patches.is_a?(Array) && patches.all?(String)
          invalid_report!("patched_versions must be an array of strings")
        end

        patches
      end

      def prefixed_identifier(identifier, prefix)
        identifier.start_with?(prefix) ? identifier : "#{prefix}#{identifier}"
      end

      def optional_identifier(advisory, field)
        value = advisory.fetch(field, nil)
        return if value.nil?

        invalid_report!("#{field} must be nil or a non-empty String") unless value.is_a?(String) && !value.empty?

        value
      end

      def object_field(object, field, owner:)
        value = object.fetch(field) { invalid_report!("#{owner} must include #{field}") }
        invalid_report!("#{field} must be an object") unless value.is_a?(Hash)

        value
      end

      def string_field(object, field, owner:)
        value = object.fetch(field) { invalid_report!("#{owner} must include #{field}") }
        invalid_report!("#{field} must be a String") unless value.is_a?(String)

        value
      end

      def nonempty_string_field(object, field, owner:)
        value = string_field(object, field, owner:)
        invalid_report!("#{field} must not be empty") if value.empty?

        value
      end

      def local_database?
        gems_path = File.join(advisory_database_path, "gems")
        return false unless File.directory?(gems_path)

        Dir.children(gems_path).any? { advisory_directory?(File.join(gems_path, _1)) }
      rescue SystemCallError
        false
      end

      def advisory_directory?(path)
        return false unless File.directory?(path)

        Dir.children(path).any? do |entry|
          File.extname(entry) == ".yml" && File.file?(File.join(path, entry))
        end
      end

      def advisory_database_path
        ENV.fetch("BUNDLER_AUDIT_DB") do
          File.join(Gem.user_home, ".local", "share", "ruby-advisory-db")
        end
      end

      def invalid_report!(reason)
        raise InvalidReport, reason
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
