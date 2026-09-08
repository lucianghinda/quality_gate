# frozen_string_literal: true

require "test_helper"
require "rubocop"
require "rubocop/cop/quality_gate/controller_instance_variables"

class ControllerInstanceVariablesTest < Minitest::Test
  def test_reports_an_action_assigning_two_instance_variables
    found = offenses(<<~RUBY)
      class ThingsController < ApplicationController
        def show
          @thing = Thing.find(params[:id])
          @comments = Comment.where(thing: @thing)
        end
      end
    RUBY

    assert_equal 1, found.size
    assert_equal "Action `show` assigns 2 instance variables (@thing, @comments); the limit is 1.",
                 found.first.message
    assert_equal 2, found.first.location.line
  end

  def test_accepts_one_instance_variable_in_each_action
    assert_empty offenses(<<~RUBY)
      class ThingsController < ApplicationController
        def index
          @things = Thing.all
        end

        def show
          @thing = Thing.find(params[:id])
        end
      end
    RUBY
  end

  def test_counts_repeated_assignments_to_one_variable_once
    assert_empty offenses("class ThingsController; def show; @thing = Thing.first; @thing = @thing.decorate; end; end")
  end

  def test_counts_every_assignment_form
    {
      "or-assignment" => "@thing ||= Thing.first; @extra = 1",
      "operator assignment" => "@thing += 1; @extra = 1",
      "multiple assignment" => "@thing, @extra = Thing.pair",
      "assignment inside a block" => "[1].each { |id| @thing = id }; @extra = 1"
    }.each do |form, body|
      assert_equal 1, offenses("class ThingsController; def show; #{body}; end; end").size, form
    end
  end

  def test_ignores_helpers_hidden_behind_a_visibility_section
    %w[private protected].each do |visibility|
      assert_empty offenses(<<~RUBY), visibility
        class ThingsController
          #{visibility}

          def helper
            @thing = 1
            @extra = 2
          end
        end
      RUBY
    end
  end

  def test_ignores_helpers_marked_private_inline
    assert_empty offenses("class ThingsController; private def helper; @thing = 1; @extra = 2; end; end")
    assert_empty offenses("class ThingsController; def helper; @thing = 1; @extra = 2; end; private :helper; end")
  end

  def test_ignores_class_methods
    assert_empty offenses("class ThingsController; def self.build; @thing = 1; @extra = 2; end; end")
    assert_empty offenses("class ThingsController; class << self; def build; @thing = 1; @extra = 2; end; end; end")
  end

  def test_ignores_classes_that_are_not_controllers
    assert_empty offenses("class Thing; def show; @thing = 1; @extra = 2; end; end")
  end

  def test_ignores_definitions_in_a_nested_class
    assert_empty offenses(<<~RUBY)
      class ThingsController
        class Presenter
          def call
            @thing = 1
            @extra = 2
          end
        end
      end
    RUBY
  end

  def test_reports_namespaced_controllers
    source = "class Admin::ThingsController; def show; @thing = 1; @extra = 2; end; end"

    assert_equal 1, offenses(source).size
  end

  def test_respects_a_configured_maximum
    two = "class ThingsController; def show; @thing = 1; @extra = 2; end; end"
    three = "class ThingsController; def show; @thing = 1; @extra = 2; @third = 3; end; end"

    assert_empty offenses(two, "Max" => 2)
    assert_equal 1, offenses(three, "Max" => 2).size
  end

  private

  def offenses(source, options = {})
    settings = { "Enabled" => true, "Max" => 1 }.merge(options)
    config = RuboCop::Config.new("QualityGate/ControllerInstanceVariables" => settings)
    cop = RuboCop::Cop::QualityGate::ControllerInstanceVariables.new(config)
    processed = RuboCop::ProcessedSource.new(source, RUBY_VERSION.to_f,
                                             "/project/app/controllers/things_controller.rb")
    RuboCop::Cop::Team.new([cop], config, raise_error: true).investigate(processed).offenses
  end
end
