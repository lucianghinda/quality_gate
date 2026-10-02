# frozen_string_literal: true

require_relative "quality_gate/version"
require_relative "quality_gate/exit_code"
require_relative "quality_gate/finding"
require_relative "quality_gate/reporters/field_sanitizer"
require_relative "quality_gate/reporters/json"
require_relative "quality_gate/reporters/markdown"
require_relative "quality_gate/reporters/text"
require_relative "quality_gate/hook_log"

module QualityGate
  class Error < StandardError; end
  # Your code goes here...
end

require_relative "quality_gate/adapter"
require_relative "quality_gate/adapters/brakeman"
require_relative "quality_gate/adapters/bundler_audit"
require_relative "quality_gate/adapters/herb"
require_relative "quality_gate/adapters/reek"
require_relative "quality_gate/adapters/rubocop"
require_relative "quality_gate/adapters/simplecov"
require_relative "quality_gate/adapters/test_suite"
require_relative "quality_gate/adapters/undercover"
require_relative "quality_gate/config"
require_relative "quality_gate/runner"
require_relative "quality_gate/doctor_report"
require_relative "quality_gate/reporters/doctor"
require_relative "quality_gate/doctor_bounded_file"
require_relative "quality_gate/doctor_launchers"
require_relative "quality_gate/doctor_git"
require_relative "quality_gate/doctor_coverage"
require_relative "quality_gate/doctor_hooks"
require_relative "quality_gate/doctor"
require_relative "quality_gate/doctor_command"
require_relative "quality_gate/cli"
require_relative "quality_gate/railtie" if defined?(Rails::Railtie)
