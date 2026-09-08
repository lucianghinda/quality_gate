# frozen_string_literal: true

require "test_helper"
require "stringio"
load File.expand_path("../../bin/prepare_release", __dir__)

class ReleasePreparerTest < Minitest::Test
  def test_validates_and_generates_before_building
    events = []
    runner = ->(command, root) { events << [command, root] }
    builder = ->(root) { events << [:build, root] }

    assert ReleasePreparer.new(root: "/project", ruby: "ruby", runner: runner, builder: builder).call
    assert_equal expected_commands.map { |command| [command, "/project"] } + [[:build, "/project"]], events
  end

  def test_each_failed_prerequisite_prevents_building
    expected_commands.each_with_index do |failed_command, index|
      events, preparer, stderr = failing_preparer(failed_command)
      refute preparer.call
      assert_equal expected_commands.first(index + 1), events
      assert_includes stderr.string, "Release preparation failed"
    end
  end

  def test_reports_build_failure
    stderr = StringIO.new

    refute ReleasePreparer.new(runner: ->(*) { true }, builder: ->(*) { false }, stderr: stderr).call
    assert_includes stderr.string, "build quality_gate.gemspec"
  end

  private

  def failing_preparer(failed_command)
    events = []
    stderr = StringIO.new
    runner = lambda { |command, _root|
      events << command
      command != failed_command
    }
    builder = ->(_root) { flunk "must not build after failure" }
    preparer = ReleasePreparer.new(root: "/project", ruby: "ruby", runner: runner,
                                   builder: builder, stderr: stderr)
    [events, preparer, stderr]
  end

  def expected_commands
    [
      %w[ruby -S bundle exec rake test],
      %w[ruby -S bundle exec rake rubocop],
      ["ruby", "/project/bin/generate_llm.rb"]
    ]
  end
end
