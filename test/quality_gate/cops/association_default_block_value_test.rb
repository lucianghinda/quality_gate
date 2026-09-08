# frozen_string_literal: true

require "test_helper"
require "rubocop"
require "rubocop/cop/quality_gate/association_default_block_value"

class AssociationDefaultBlockValueTest < Minitest::Test
  def test_reports_eager_current_defaults
    ["Current.user", "::Current.account", "Current.user&.account"].each do |value|
      report = investigate("belongs_to :creator, default: #{value}")
      assert_equal 1, report.offenses.size, value
      assert_equal value, report.offenses.first.location.source
    end
  end

  def test_accepts_callable_and_unknown_defaults
    ["-> { Current.user }", "proc { Current.user }", "Current.method(:user)",
     "DEFAULT_CREATOR", "creator_default", "nil", "User.first"].each do |value|
      assert_empty investigate("belongs_to :creator, default: #{value}").offenses, value
    end
  end

  def test_ignores_other_macros_and_explicit_receivers
    assert_empty investigate("attribute :creator, default: Current.user").offenses
    assert_empty investigate("registry.belongs_to :creator, default: Current.user").offenses
    assert_empty investigate("belongs_to :creator, optional: true").offenses
  end

  def test_does_not_offer_autocorrection
    refute RuboCop::Cop::QualityGate::AssociationDefaultBlockValue.support_autocorrect?
  end

  def test_skips_ambiguous_options
    assert_empty investigate("belongs_to :creator, default: Current.user, **options").offenses
    assert_empty investigate("belongs_to :creator, default: Current.user, default: DEFAULT").offenses
  end

  private

  def investigate(source)
    cop = RuboCop::Cop::QualityGate::AssociationDefaultBlockValue.new(RuboCop::Config.new)
    RuboCop::Cop::Commissioner.new([cop], [], raise_error: true)
                              .investigate(RuboCop::ProcessedSource.new(source, 3.2))
  end
end
