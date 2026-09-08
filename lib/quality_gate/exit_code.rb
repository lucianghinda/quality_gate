# frozen_string_literal: true

module QualityGate
  # Provides stable process-independent result codes for command execution.
  module ExitCode
    CLEAN = 0
    FINDINGS = 1
    TOOL_FAILURE = 2

    @all = [CLEAN, FINDINGS, TOOL_FAILURE].freeze

    def self.all = @all
  end
end
