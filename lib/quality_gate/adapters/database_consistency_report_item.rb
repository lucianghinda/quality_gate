# frozen_string_literal: true

module QualityGate
  module Adapters
    # Validates one database_consistency report before mapping it to a finding.
    class DatabaseConsistencyReportItem
      FIELDS = %w[
        checker_name table_or_model_name column_or_attribute_name status error_slug error_message
      ].freeze
      LOCATION = /\A(.+):([0-9]+)\z/
      SEVERITIES = { "fail" => :error, "warning" => :warning }.freeze
      private_constant :FIELDS, :LOCATION, :SEVERITIES

      def initialize(report)
        @report = report
      end

      def finding
        validate!
        return if @report.fetch("status") == "ok"

        Finding.new(**attributes)
      end

      private

      def validate!
        invalid!("report must be an object") unless @report.is_a?(Hash)
        validate_fields!
        validate_values!
      end

      def validate_fields!
        FIELDS.each { invalid!("report must include #{_1}") unless @report.key?(_1) }
      end

      def validate_values!
        validate_names!
        validate_status!
        validate_message!
        validate_location!
      end

      def validate_names!
        string!(@report.fetch("checker_name"), "checker_name")
        nullable_string!(@report.fetch("table_or_model_name"), "table_or_model_name")
        nullable_string!(@report.fetch("column_or_attribute_name"), "column_or_attribute_name")
      end

      def validate_status!
        status = @report.fetch("status")
        return if status == "ok" || SEVERITIES.key?(status)

        invalid!("status must be ok, fail, or warning")
      end

      def validate_message!
        nullable_string!(@report.fetch("error_slug"), "error_slug")
        nullable_string!(@report.fetch("error_message"), "error_message")
        return if @report.fetch("status") == "ok" || usable_message?

        invalid!("finding requires a non-empty error_message or error_slug")
      end

      def usable_message?
        %w[error_message error_slug].any? { !@report.fetch(_1).to_s.strip.empty? }
      end

      def validate_location!
        value = @report.fetch("source_location", nil)
        return if value.nil?
        return if value.is_a?(String) && (match = LOCATION.match(value)) && Integer(match[2], 10).positive?

        invalid!("source_location must be nil or a path followed by a positive line number")
      end

      def attributes
        file, line = location
        {
          tool: "database_consistency", file:, line:, rule: @report.fetch("checker_name"),
          severity: SEVERITIES.fetch(@report.fetch("status")), message: message
        }
      end

      def location
        value = @report.fetch("source_location", nil)
        return ["", 0] unless value

        match = LOCATION.match(value)
        [match[1], Integer(match[2], 10)]
      end

      def message
        context = [@report.fetch("table_or_model_name"), @report.fetch("column_or_attribute_name")]
                  .compact.reject { _1.strip.empty? }
        detail = error_detail
        context.empty? ? detail : "#{context.join(" ")}: #{detail}"
      end

      def error_detail
        message = @report.fetch("error_message")
        return message unless message.nil? || message.strip.empty?

        @report.fetch("error_slug").tr("_", " ").strip
      end

      def string!(value, field)
        invalid!("#{field} must be a non-empty string") unless value.is_a?(String) && !value.strip.empty?
      end

      def nullable_string!(value, field)
        invalid!("#{field} must be a string or nil") unless value.nil? || value.is_a?(String)
      end

      def invalid!(reason)
        raise ParseError.new(tool: "database_consistency", reason: reason)
      end
    end

    private_constant :DatabaseConsistencyReportItem
  end
end
