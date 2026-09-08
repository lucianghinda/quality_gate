# frozen_string_literal: true

require "test_helper"
require "rubocop"
require "rubocop/cop/quality_gate/private_only_concern"

class PrivateOnlyConcernTest < Minitest::Test
  def test_reports_private_only_active_support_concern
    assert_equal 1, offenses("module Helpers; extend ActiveSupport::Concern; private; def helper; end; end").size
  end

  def test_reports_inline_and_named_private_methods
    assert_equal 1, offenses("module Helpers; extend ::ActiveSupport::Concern; private def helper; end; end").size
    source = "module Helpers; extend ActiveSupport::Concern; def helper; end; private :helper; end"
    assert_equal 1, offenses(source).size
  end

  def test_recognizes_configured_domain_concern_paths
    source = "module Helpers; private; def helper; end; end"
    assert_empty offenses(source)
    assert_equal 1, offenses(source, "ConcernPaths" => ["**/app/models/card/*.rb"]).size
  end

  def test_accepts_public_behavior_and_inclusion_hooks
    [
      "def helper; end",
      "private; def helper; end; public; def call; end",
      "protected; def helper; end",
      "private; def helper; end; included do; before_save :helper; end",
      "private; def helper; end; def self.included(base); end",
      "private; def helper; end; class_methods do; def call; end; end"
    ].each do |body|
      assert_empty offenses("module Helpers; extend ActiveSupport::Concern; #{body}; end"), body
    end
  end

  def test_accepts_uncertain_module_contents_and_empty_concerns
    [
      "private; def helper; end; include SharedBehavior",
      "private; def helper; end; attr_reader :name",
      "private; def helper; end; public :helper",
      "private; def helper; end; private(*method_names)",
      ""
    ].each do |body|
      assert_empty offenses("module Helpers; extend ActiveSupport::Concern; #{body}; end"), body
    end
  end

  private

  def offenses(source, options = {})
    config = RuboCop::Config.new("QualityGate/PrivateOnlyConcern" => { "Enabled" => true }.merge(options))
    cop = RuboCop::Cop::QualityGate::PrivateOnlyConcern.new(config)
    processed = RuboCop::ProcessedSource.new(source, RUBY_VERSION.to_f, "/project/app/models/card/helpers.rb")
    RuboCop::Cop::Team.new([cop], config, raise_error: true).investigate(processed).offenses
  end
end
