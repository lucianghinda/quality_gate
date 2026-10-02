# frozen_string_literal: true

module QualityGate
  # Holds bounded preflight observations independently of gate findings.
  class DoctorReport
    STATUSES = %w[ready warning blocked unchecked not_applicable].map!(&:freeze).freeze

    attr_reader :checks, :summary

    def self.check(id:, status:, message:)
      normalized_status = status.to_s
      raise ArgumentError, "unknown Doctor status" unless STATUSES.include?(normalized_status)

      { "id" => id.to_s.dup.freeze, "status" => normalized_status.dup.freeze,
        "message" => message.to_s.dup.freeze }.freeze
    end

    def initialize(checks:)
      @checks = checks.map { normalize_check(_1) }.freeze
      @summary = STATUSES.to_h do |status|
        [status, @checks.count { |check| check.fetch("status") == status }]
      end.freeze
    end

    def exit_code
      return 2 if summary.fetch("blocked").positive?
      return 1 if summary.fetch("warning").positive? || summary.fetch("unchecked").positive?

      0
    end

    private

    def normalize_check(check)
      self.class.check(id: check.fetch("id"), status: check.fetch("status"), message: check.fetch("message"))
    end
  end
end
