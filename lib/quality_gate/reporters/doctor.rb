# frozen_string_literal: true

require "json"
require_relative "../doctor_report"

module QualityGate
  module Reporters
    # Renders Doctor's preflight checks as text or a stable JSON envelope.
    class Doctor
      def initialize(io:)
        @io = io
      end

      def call(report, format:)
        case format
        when "json" then io.puts(JSON.generate(json_payload(report)))
        when "text" then print_text(report)
        else raise ArgumentError, "Doctor format must be text or json"
        end
      end

      private

      attr_reader :io

      def json_payload(report)
        {
          "scope" => "preflight",
          "checks" => sanitized_checks(report),
          "summary" => report.summary
        }
      end

      def sanitized_checks(report)
        report.checks.map do |check|
          check.transform_values { |value| FieldSanitizer.for_json(value) }
        end
      end

      def print_text(report)
        report.checks.each do |check|
          io.puts [check.fetch("id"), check.fetch("status"), check.fetch("message")]
            .map { FieldSanitizer.for_text(_1) }.join(" ")
        end

        io.puts "Preflight: #{summary_text(report.summary)}"
      end

      def summary_text(summary)
        DoctorReport::STATUSES.map do |status|
          label = status == "not_applicable" ? "not applicable" : status
          "#{summary.fetch(status)} #{label}"
        end.join(", ")
      end
    end
  end
end
