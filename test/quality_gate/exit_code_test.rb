# frozen_string_literal: true

require "test_helper"

module QualityGate
  class ExitCodeTest < Minitest::Test
    def test_named_codes_and_frozen_collection
      assert_equal 0, ExitCode::CLEAN
      assert_equal 1, ExitCode::FINDINGS
      assert_equal 2, ExitCode::TOOL_FAILURE
      assert_equal %i[CLEAN FINDINGS TOOL_FAILURE].sort, ExitCode.constants(false).sort
      assert_equal [0, 1, 2], ExitCode.all
      assert_predicate ExitCode.all, :frozen?
    end
  end
end
