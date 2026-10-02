# frozen_string_literal: true

require "json"

module QualityGate
  module Adapters
    # Validates Debride's JSON report before converting candidates into findings.
    class DebrideReport
      LOCATION = /\A(.+):([1-9]\d*)(?:-([1-9]\d*))?\z/
      private_constant :LOCATION

      def initialize(json)
        @report = JSON.parse(json)
      end

      def findings
        validate_report!
        @report.fetch("missing").flat_map { |scope, candidates| scope_findings(scope, candidates) }
      end

      private

      def validate_report!
        raise TypeError, "report must be a JSON object" unless @report.is_a?(Hash)
        raise TypeError, "missing must be a JSON object" unless @report.fetch("missing").is_a?(Hash)
      end

      def scope_findings(scope, candidates)
        require_string!(scope, "scope")
        raise TypeError, "candidates must be an array" unless candidates.is_a?(Array)

        candidates.map { |candidate| candidate_finding(scope, candidate) }
      end

      def candidate_finding(scope, candidate)
        validate_candidate!(candidate)
        method, location = candidate
        file, line = parse_location(location)
        build_finding(scope, method, file, line)
      end

      def validate_candidate!(candidate)
        unless candidate.is_a?(Array) && candidate.length == 2
          raise TypeError, "candidate must be a [name, location] pair"
        end

        require_string!(candidate.fetch(0), "candidate name")
        require_string!(candidate.fetch(1), "candidate location")
      end

      def parse_location(location)
        match = LOCATION.match(location)
        raise ArgumentError, "invalid candidate location #{location.inspect}" unless match

        first = Integer(match[2], 10)
        validate_range!(first, match[3])
        [match[1], first]
      end

      def validate_range!(first, last_text)
        return unless last_text

        raise ArgumentError, "candidate line range is reversed" if Integer(last_text, 10) < first
      end

      def build_finding(scope, method, file, line)
        Finding.new(
          tool: "debride", file:, line:, rule: "potentially_unused_method", severity: :warning,
          message: "#{scope}: #{method} is potentially unused"
        )
      end

      def require_string!(value, label)
        raise TypeError, "#{label} must be a non-empty String" unless value.is_a?(String) && !value.empty?
      end
    end

    private_constant :DebrideReport
  end
end
