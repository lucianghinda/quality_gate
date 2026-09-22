# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

class ProfilingTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PROBE = <<~'RUBY'
    require ARGV.fetch(0)
    require "open3"
    require "rbconfig"
    require "minitest/mock"

    class ProfileProbe < Minitest::Test
      def test_capture_contracts_and_environment_isolation
        Open3.stub(:capture3, ["stubbed", "", nil]) do
          assert_equal "stubbed", Open3.capture3("unused").first
        end
        output, error, status = Open3.capture3(
          { "PROBE_VALUE" => "example" }, RbConfig.ruby, "-e",
          'print ENV.fetch("PROBE_VALUE"); warn STDIN.read; exit 3', stdin_data: "input"
        )
        assert_equal "example", output
        assert_equal "input\n", error
        assert_equal 3, status.exitstatus

        output, status = Open3.capture2(RbConfig.ruby, "-e", 'print ENV["QUALITY_GATE_PROFILE"].inspect')
        assert_equal "nil", output
        assert_predicate status, :success?

        output, status = Open3.capture2e(RbConfig.ruby, "-e", 'warn "combined"')
        assert_equal "combined\n", output
        assert_predicate status, :success?
      end
    end
  RUBY

  def test_ordinary_runs_do_not_emit_profiling_reports
    output, status = run_probe

    assert_predicate status, :success?, output
    refute_includes output, "TagProf report"
    refute_includes output, "EventProf results"
  end

  def test_opt_in_profiles_subprocess_calls_without_changing_their_contract
    output, status = run_probe(profile: "1")

    assert_predicate status, :success?, output
    assert_includes output, "TagProf report for type"
    assert_includes output, "EventProf results for subprocess.quality_gate"
    assert_includes output, "Total events: 3"
  end

  def test_profile_with_no_matching_tests_preserves_minitest_result
    _ordinary_output, ordinary_status = run_probe(filter: "/does_not_exist/")
    output, status = run_probe(profile: "1", filter: "/does_not_exist/")

    assert_equal ordinary_status.exitstatus, status.exitstatus, output
    assert_includes output, "0 runs"
    refute_includes output, "TypeError"
  end

  private

  def run_probe(profile: nil, filter: nil)
    environment = { "COVERAGE" => nil, "QUALITY_GATE_PROFILE" => profile }
    helper = File.join(ROOT, "test/test_helper.rb")
    arguments = [helper]
    arguments.concat(["--name", filter]) if filter
    Open3.capture2e(environment, RbConfig.ruby, "-rbundler/setup", "-e", PROBE, *arguments, chdir: ROOT)
  end
end
