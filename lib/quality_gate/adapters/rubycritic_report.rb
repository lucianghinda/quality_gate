# frozen_string_literal: true

require "json"

module QualityGate
  module Adapters
    # Validates RubyCritic's JSON document and converts smells to findings.
    class RubyCriticReport
      def initialize(json)
        @report = JSON.parse(json)
      end

      def findings
        validate_report!
        analysed_modules.flat_map { module_findings(_1) }.uniq
      end

      private

      def validate_report!
        raise TypeError, "report must be a JSON object" unless @report.is_a?(Hash)

        validate_metadata!(@report.fetch("metadata"))
        validate_score!(@report.fetch("score"))
      end

      def validate_metadata!(metadata)
        raise TypeError, "metadata must be a JSON object" unless metadata.is_a?(Hash)

        rubycritic = metadata.fetch("rubycritic")
        raise TypeError, "metadata.rubycritic must be a JSON object" unless rubycritic.is_a?(Hash)

        required_string(rubycritic.fetch("version"), "RubyCritic version")
      end

      def validate_score!(score)
        return if score.is_a?(Numeric) && score.finite? && score.between?(0, 100)

        raise TypeError, "score must be a finite number within 0..100"
      end

      def analysed_modules
        modules = @report.fetch("analysed_modules")
        return modules if modules.is_a?(Array) && !modules.empty?

        raise TypeError, "analysed_modules must be a non-empty array"
      end

      def module_findings(entry)
        raise TypeError, "module must be an object" unless entry.is_a?(Hash)

        required_string(entry.fetch("path"), "module path")
        smells = entry.fetch("smells")
        raise TypeError, "smells must be an array" unless smells.is_a?(Array)

        smells.flat_map { smell_findings(_1) }
      end

      def smell_findings(smell)
        raise TypeError, "smell must be an object" unless smell.is_a?(Hash)

        type, context, message = smell_attributes(smell)
        locations = smell.fetch("locations")
        raise TypeError, "locations must be a non-empty array" unless locations.is_a?(Array) && !locations.empty?

        locations.map { finding_for(_1, type, context, message) }
      end

      def smell_attributes(smell)
        [
          required_string(smell.fetch("type"), "smell type"),
          required_string(smell.fetch("context"), "smell context", allow_empty: true),
          required_string(smell.fetch("message"), "smell message", allow_empty: true)
        ]
      end

      def finding_for(location, type, context, message)
        Finding.new(
          tool: "rubycritic", file: location_path(location), line: location_line(location),
          rule: type, severity: :warning,
          message: "#{context} #{message}".strip
        )
      end

      def location_path(location)
        raise TypeError, "location must be an object" unless location.is_a?(Hash)

        required_string(location.fetch("path"), "location path")
      end

      def location_line(location)
        line = location.fetch("line")
        validate_line!(line)
        line
      end

      def validate_line!(line)
        return if line.is_a?(Integer) && line >= 0

        raise TypeError, "location line must be an Integer greater than or equal to 0"
      end

      def required_string(value, field, allow_empty: false)
        valid = value.is_a?(String) && (allow_empty || !value.empty?)
        raise TypeError, "#{field} must be a #{allow_empty ? "String" : "non-empty String"}" unless valid

        value
      end
    end
    private_constant :RubyCriticReport
  end
end
