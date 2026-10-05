# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require "rubygems/package"
require "open3"
require "optparse"
require "pathname"
require "rbconfig"
require "time"
require_relative "../../lib/quality_gate"

module AgentRepairAcceptance
  ROOT = Pathname(__dir__).join("../..").expand_path.freeze
  FIXTURE = ROOT.join("test/fixtures/acceptance/base").freeze
  SOURCE = "lib/calculator.rb"
  TESTS = "test"
  FAST_SEED = "# frozen_string_literal: true\n\nmodule Calculator\n  def self.add(left,right) = left + right\nend\n"
  VERIFY_SEED = <<~RUBY
    # frozen_string_literal: true

    module Calculator
      def self.add(left, right) = left + right

      def self.subtract(left, right)
        left - right
      end
    end
  RUBY
  SCENARIOS = %w[fast verify].map!(&:freeze).freeze

  def self.seed_for(scenario)
    scenario == "fast" ? FAST_SEED : VERIFY_SEED
  end

  def self.evidence_root(root)
    Pathname("#{Pathname(root).expand_path}.evidence")
  end

  def self.prompt_for(scenario)
    <<~PROMPT.strip
      First replace lib/calculator.rb with these exact bytes using the native
      edit/write tool:

      ```ruby
      #{seed_for(scenario).strip}
      ```

      Then finish the task. Preserve Calculator behavior, project configuration,
      existing tests, hooks, and git history. A new test file is permitted for the
      verify scenario.
    PROMPT
  end

  class Error < StandardError; end
end

require_relative "agent_repair_acceptance/evidence"
require_relative "agent_repair_acceptance/project"
require_relative "agent_repair_acceptance/process"
require_relative "agent_repair_acceptance/project_runner"
require_relative "agent_repair_acceptance/session"
require_relative "agent_repair_acceptance/command"
