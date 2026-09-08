# frozen_string_literal: true

require "test_helper"
require "rubocop"
require "rubocop/cop/quality_gate/prefer_after_save_commit"

class PreferAfterSaveCommitTest < Minitest::Test
  CORRECTIONS = {
    "after_commit :notify, on: %i[create update]" => "after_save_commit :notify",
    "after_commit(:notify, on: [:update, :create])" => "after_save_commit(:notify)",
    "after_commit :notify, on: %i[create update], if: :ready?" => "after_save_commit :notify, if: :ready?",
    "after_commit :notify, if: :ready?, on: %i[create update]" => "after_save_commit :notify, if: :ready?",
    "self.after_commit :notify, :log, on: %i[create update]" => "self.after_save_commit :notify, :log",
    "after_commit on: %i[create update] do\n  notify\nend" => "after_save_commit do\n  notify\nend",
    "after_commit(:notify, { on: %i[create update] })" => "after_save_commit(:notify)",
    "after_commit(:notify, { on: %i[create update], },)" => "after_save_commit(:notify,)",
    "after_commit(:notify, { if: :ready?, on: %i[create update], })" => "after_save_commit(:notify, { if: :ready?, })",
    "after_commit(on: %i[create update]) { notify }" => "after_save_commit() { notify }",
    "after_commit(on: %i[create update],) { notify }" => "after_save_commit() { notify }",
    "after_commit({ on: %i[create update] },) { notify }" => "after_save_commit() { notify }",
    "after_commit({ on: %i[create update] }) { notify }" => "after_save_commit() { notify }"
  }.freeze

  def test_corrects_literal_create_update_callbacks
    CORRECTIONS.each do |source, corrected|
      report = investigate(source)
      assert_equal 1, report.offenses.size, source
      assert_equal corrected, report.correctors.first.rewrite
      assert RuboCop::ProcessedSource.new(corrected, 3.2).valid_syntax?
    end
  end

  def test_preserves_comments_by_leaving_declaration_uncorrected
    source = "after_commit :notify, # explanation\n  on: %i[create update]"
    report = investigate(source)

    assert_equal 1, report.offenses.size
    assert_nil report.correctors.first
  end

  def test_skips_nonliteral_and_ambiguous_options
    [
      "after_commit :notify, on: :create",
      "after_commit :notify, on: %i[create update destroy]",
      "after_commit :notify, on: events",
      "after_commit :notify, on: %i[create create]"
    ].each do |source|
      assert_empty investigate(source).offenses, source
    end
  end

  def test_skips_overridden_options_and_foreign_receivers
    [
      "after_commit :notify, on: %i[create update], **options",
      "after_commit :notify, **options, on: %i[create update]",
      "after_commit :notify, on: %i[create update], on: :destroy",
      "callbacks.after_commit :notify, on: %i[create update]"
    ].each do |source|
      assert_empty investigate(source).offenses, source
    end
  end

  private

  def investigate(source)
    cop = RuboCop::Cop::QualityGate::PreferAfterSaveCommit.new(RuboCop::Config.new, autocorrect: true)
    RuboCop::Cop::Commissioner.new([cop], [], raise_error: true)
                              .investigate(RuboCop::ProcessedSource.new(source, 3.2))
  end
end
