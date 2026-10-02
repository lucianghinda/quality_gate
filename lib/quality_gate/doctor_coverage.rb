# frozen_string_literal: true

require "json"
require_relative "adapters/simplecov"
require_relative "doctor_bounded_file"
require_relative "doctor_report"

module QualityGate
  # Inspects configured coverage evidence without running coverage tools.
  class DoctorCoverage
    def initialize(dir:, config:)
      @dir = File.expand_path(dir).freeze
      @config = config
    end

    def call
      checks = []
      checks << undercover_check if enabled?("undercover")
      checks << simplecov_check if simplecov_configured?
      return [check("coverage", "not_applicable", "No configured coverage evidence is required.")] if checks.empty?

      checks
    end

    private

    def undercover_check
      inspect_artifact("coverage.undercover", Adapters::Undercover::COVERAGE_PATH,
                       "Undercover coverage evidence", :undercover_shape?)
    end

    def simplecov_check
      inspect_artifact("coverage.simplecov", Adapters::SimpleCov::COVERAGE_PATH,
                       "SimpleCov coverage evidence", :simplecov_shape?)
    end

    def inspect_artifact(id, relative_path, label, shape)
      result = DoctorBoundedFile.read(path: File.join(@dir, relative_path))
      return unreadable_artifact(id, label, result.status) unless result.status == :ok

      parse_artifact(id, label, result.contents, shape)
    end

    def parse_artifact(id, label, contents, shape)
      document = JSON.parse(contents)
      return ready_artifact(id, label) if method(shape).call(document)

      invalid_shape(id, label)
    rescue JSON::ParserError
      malformed_json(id, label)
    end

    def unreadable_artifact(id, label, status)
      message = unreadable_message(status)
      check(id, "unchecked", "#{label} #{message}")
    end

    def unreadable_message(status)
      return "is missing before the initial suite; run quality_gate verify to create it." if status == :missing

      "could not be read safely (#{status}); inspect the regular file and permissions."
    end

    def ready_artifact(id, label)
      message = "#{label} is readable structured evidence only; freshness, wiring, and " \
        "budget compliance were not checked."
      check(id, "ready", message)
    end

    def invalid_shape(id, label)
      message = "#{label} has an unusable JSON shape; rerun the test suite and " \
        "inspect the formatter output."
      check(id, "warning", message)
    end

    def malformed_json(id, label)
      message = "#{label} is malformed JSON; rerun the test suite and inspect the " \
        "coverage formatter output."
      check(id, "warning", message)
    end

    def undercover_shape?(document)
      document.is_a?(Hash) && document["meta"].is_a?(Hash) && document["coverage"].is_a?(Hash)
    end

    def simplecov_shape?(document)
      result = document["result"] if document.is_a?(Hash)
      simplecov_result?(result)
    end

    def simplecov_result?(result)
      return false unless result.is_a?(Hash) && valid_percentage?(result["line"])

      !(@config.fetch(:coverage) || {}).key?(:minimum_branch) || valid_percentage?(result["branch"])
    end

    def simplecov_configured?
      enabled?("simplecov") && (@config.fetch(:coverage) || {}).any?
    end

    def enabled?(name)
      @config.fetch(:adapters).values.any? { _1.include?(name) }
    end

    def valid_percentage?(value)
      value.is_a?(Numeric) && value.finite? && value.between?(0, 100)
    end

    def check(id, status, message)
      DoctorReport.check(id:, status:, message:)
    end
  end
end
