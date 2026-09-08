# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/calculator'

class CalculatorTest < Minitest::Test
  AMBIENT_APPLICATION_VARIABLES = %w[
    DATABASE_URL PIDFILE PORT RAILS_LOG_TO_STDOUT RAILS_MASTER_KEY RAILS_MAX_THREADS
    RAILS_SERVE_STATIC_FILES SECRET_KEY_BASE WEB_CONCURRENCY
  ].freeze

  def test_adds_two_numbers
    assert_equal 3, Calculator.add(1, 2)
  end

  def test_subtracts_two_numbers
    assert_equal 2, Calculator.subtract(5, 3)
  end

  def test_runtime_environment_is_isolated
    assert_equal 'test', ENV.fetch('RAILS_ENV')
    assert_equal 'test', ENV.fetch('RACK_ENV')
    AMBIENT_APPLICATION_VARIABLES.each { assert_nil ENV[_1], "expected #{_1} to be unset" }
  end
end
