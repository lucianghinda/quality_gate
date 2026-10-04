# frozen_string_literal: true

require "test_helper"

module QualityGate
  class DatabaseConsistencyRunnerTest < Minitest::Test
    def test_project_runner_records_project_scope_and_finding_status
      config = Config.new(Config.defaults.merge(files: ["app/models/user.rb"]))
      adapter = StaticAdapter.new([
                                    Finding.new(
                                      tool: "database_consistency", file: "", line: 0, rule: "ForeignKey",
                                      severity: :error, message: "invalid reference"
                                    )
                                  ])

      result = Runner.new(adapters: [adapter], config: config).call

      assert_equal "project", result.checks.first.fetch(:scope)
      assert_equal "findings", result.checks.first.fetch(:status)
    end

    class StaticAdapter
      def initialize(findings) = (@findings = findings)
      def name = "database_consistency"
      def call = @findings
    end
  end
end
