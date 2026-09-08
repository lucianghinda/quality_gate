# frozen_string_literal: true

QualityGate::Finding = Data.define(:tool, :file, :line, :rule, :severity, :message)

QualityGate::Finding::SEVERITIES = %i[error warning info].freeze
QualityGate::Finding::TOOL_FAILURE_RULE = "tool_failure"

QualityGate::Finding.class_eval do
  def initialize(**attributes)
    super(
      **attributes,
      tool: copy_string(:tool, attributes.fetch(:tool)),
      file: copy_string(:file, attributes.fetch(:file)),
      line: validate_line(attributes.fetch(:line)),
      rule: copy_string(:rule, attributes.fetch(:rule)),
      message: copy_string(:message, attributes.fetch(:message))
    )
  end

  def self.tool_failure(tool:, message:)
    new(
      tool: tool,
      file: "",
      line: 0,
      rule: self::TOOL_FAILURE_RULE,
      severity: :error,
      message: message
    )
  end

  def with(**attributes) = self.class.new(**to_h.merge(attributes))

  def tool_failure? = rule == self.class::TOOL_FAILURE_RULE

  private

  def copy_string(member, value)
    raise TypeError, "#{member} must be a String" unless value.is_a?(String)

    value.dup.freeze
  end

  def validate_line(value)
    raise TypeError, "line must be an Integer" unless value.is_a?(Integer)
    raise ArgumentError, "line must be greater than or equal to 0" if value.negative?

    value
  end
end
# rubocop:enable Metrics/BlockLength
