# frozen_string_literal: true

require "test_helper"
require "rubocop"
require "rubocop/cop/quality_gate/broadcast_in_controller"

class BroadcastInControllerTest < Minitest::Test
  def test_reports_explicit_turbo_broadcast_methods
    %w[broadcast_append_to broadcast_replace_later_to broadcast_remove broadcast_refresh_later_to].each do |method|
      assert_equal 1, offenses("class CardsController; def create; @card.#{method}; end; end").size, method
    end
  end

  def test_reports_action_cable_server_and_channel_broadcasts
    ["ActionCable.server.broadcast('cards', {})", "::ActionCable.server.broadcast('cards', {})",
     "CardsChannel.broadcast_to(card, {})", "Turbo::StreamsChannel.broadcast_replace_to(card)",
     "@card&.broadcast_remove_to(card)"].each do |call|
      assert_equal 1, offenses("class CardsController; def create; #{call}; end; end").size, call
    end
  end

  def test_accepts_responses_unrelated_methods_and_noncontrollers
    ["render turbo_stream: turbo_stream.replace(@card)", "publisher.broadcast(message)",
     "publisher.broadcast_to(message)", "@card.broadcast_custom_event"].each do |call|
      assert_empty offenses("class CardsController; def create; #{call}; end; end"), call
    end
    assert_empty offenses("class Card; def save; broadcast_remove; end; end", path: "/project/app/models/card.rb")
  end

  def test_allows_explicit_method_exceptions
    source = "class CardsController; def create; @card.broadcast_remove; end; end"
    assert_empty offenses(source, options: { "AllowedMethods" => ["broadcast_remove"] })
  end

  private

  def offenses(source, options: {}, path: "/project/app/controllers/cards_controller.rb")
    config = RuboCop::Config.new("QualityGate/BroadcastInController" => { "Enabled" => true }.merge(options))
    cop = RuboCop::Cop::QualityGate::BroadcastInController.new(config)
    processed = RuboCop::ProcessedSource.new(source, RUBY_VERSION.to_f, path)
    RuboCop::Cop::Team.new([cop], config, raise_error: true).investigate(processed).offenses
  end
end
