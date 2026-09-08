# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/calculator'

class CalculatorTest < Minitest::Test
  def test_adds_two_numbers
    assert_equal 3, Calculator.add(1, 2)
  end
end
