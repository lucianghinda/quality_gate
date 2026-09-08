# frozen_string_literal: true

require_relative "quality_gate/version"
require_relative "quality_gate/exit_code"
require_relative "quality_gate/finding"
require_relative "quality_gate/reporters/field_sanitizer"
require_relative "quality_gate/reporters/json"
require_relative "quality_gate/reporters/text"
require_relative "quality_gate/hook_log"

module QualityGate
  class Error < StandardError; end
  # Your code goes here...
end

require_relative "quality_gate/adapter"
require_relative "quality_gate/adapters/brakeman"
require_relative "quality_gate/adapters/bundler_audit"
require_relative "quality_gate/adapters/reek"
require_relative "quality_gate/adapters/rubocop"
require_relative "quality_gate/adapters/simplecov"
require_relative "quality_gate/adapters/test_suite"
require_relative "quality_gate/adapters/undercover"
require_relative "quality_gate/config"
require_relative "quality_gate/runner"
require_relative "quality_gate/cli"
require_relative "quality_gate/railtie" if defined?(Rails::Railtie)
