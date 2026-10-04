# frozen_string_literal: true

require "json"
require "rubygems"
require_relative "database_consistency_report_item"

module QualityGate
  module Adapters
    # Validates the bridge envelope and converts reports into findings.
    class DatabaseConsistencyReport
      VERSION = 1
      VERSION_REQUIREMENT = Gem::Requirement.new("~> 3.0.14")

      def initialize(json)
        @envelope = JSON.parse(json)
      rescue JSON::ParserError => e
        raise ParseError.new(tool: "database_consistency", reason: e.message)
      end

      def findings
        validate_envelope!
        reports.filter_map { DatabaseConsistencyReportItem.new(_1).finding }
      end

      private

      def validate_envelope!
        invalid!("envelope must be an object") unless @envelope.is_a?(Hash)
        validate_version!
        validate_analyzer_version!
        invalid!("reports must be an array") unless reports.is_a?(Array)
      end

      def validate_version!
        value = @envelope.fetch("version", nil)
        invalid!("version must be integer 1") unless value.instance_of?(Integer) && value == VERSION
      end

      def validate_analyzer_version!
        value = @envelope.fetch("analyzer_version", nil)
        return if supported_version?(value)

        invalid!("analyzer_version must be a supported version")
      end

      def supported_version?(value)
        value.is_a?(String) && VERSION_REQUIREMENT.satisfied_by?(Gem::Version.new(value))
      rescue ArgumentError
        false
      end

      def reports = @envelope.fetch("reports", nil)

      def invalid!(reason)
        raise ParseError.new(tool: "database_consistency", reason: reason)
      end
    end

    private_constant :DatabaseConsistencyReport
  end
end
