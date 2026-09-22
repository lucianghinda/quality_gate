# frozen_string_literal: true

require "active_support"
require "active_support/notifications"
require "open3"
require "test_prof"
require "minitest/test_prof_plugin"

# These methods wait for completion, unlike Open3.popen* without a block.
# Capture the original method instead of prepending: Minitest's stub restores
# methods with alias_method, which would make a prepended wrapper recurse.
%i[capture2 capture2e capture3].each do |name|
  original = Open3.method(name)
  Open3.define_singleton_method(name) do |*args, **kwargs, &block|
    TestProf::EventProf.instrumenter.instrument("subprocess.quality_gate") do
      original.call(*args, **kwargs, &block)
    end
  end
end

Minitest.extensions << "quality_gate_profile"

class QualityGateEventProfReporter < Minitest::TestProf::EventProfReporter
  def report
    # TestProf 1.6.3 assumes at least one test started, even with a name filter.
    super if @current_group
  end
end

def Minitest.plugin_quality_gate_profile_init(options)
  reporter << Minitest::TestProf::TagProfReporter.new(options[:io], options)
  event_options = options.merge(event: "subprocess.quality_gate", per_example: true, top_count: 10)
  reporter << QualityGateEventProfReporter.new(options[:io], event_options)
end
