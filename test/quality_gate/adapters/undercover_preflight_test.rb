# frozen_string_literal: true

require "test_helper"

require "fileutils"
require "json"
require "rbconfig"
require "tmpdir"

module QualityGate
  module Adapters
    class UndercoverPreflightTest < Minitest::Test
      # rubocop:disable Metrics/AbcSize
      def test_git_probes_and_undercover_share_one_timeout_budget
        with_coverage_record do
          adapter = adapter_capturing(
            [
              response(status: 1),
              response(stdout: "main\n"),
              response(stdout: "head parent\n"),
              response(stdout: "base\n"),
              response(stdout: clean_report)
            ],
            config: config_with_timeout(10)
          )

          findings = with_monotonic_times(100.0, 101.0, 102.0, 103.0, 104.0, 106.0) { adapter.call }

          assert_empty findings
          assert_equal [9.0, 8.0, 7.0, 6.0, 4.0], adapter.captured_timeouts
          assert_equal "git", adapter.captured_commands.first.fetch(0)
          assert_equal "undercover", adapter.captured_commands.last.fetch(0)
        end
      end

      def test_no_later_process_starts_after_git_probes_exhaust_the_budget
        with_coverage_record do
          adapter = adapter_capturing(
            [
              response(status: 1),
              response(stdout: "main\n"),
              response(stdout: "head parent\n")
            ],
            config: config_with_timeout(10)
          )

          findings = with_monotonic_times(100.0, 101.0, 104.0, 109.0, 110.0) { adapter.call }

          assert_tool_failure(findings, "timeout")
          assert_equal [9.0, 6.0, 1.0], adapter.captured_timeouts
          assert_equal 3, adapter.captured_commands.length
          assert(adapter.captured_commands.all? { _1.fetch(0) == "git" })
        end
      end

      def test_git_spawn_and_execution_errors_are_tool_failures
        failures = {
          "spawn failure" => Errno::ENOENT.new("git unavailable"),
          "unexpected status" => response(stderr: "fatal: corrupt repository\n", status: 2),
          "unexpected stderr" => response(stderr: "unexpected diagnostic\n"),
          "diagnostic on semantic status" => response(stderr: "fatal: repository failure\n", status: 1)
        }

        with_coverage_record do
          failures.each do |label, response_or_error|
            adapter = adapter_capturing([response_or_error])

            findings = adapter.call

            assert_tool_failure(findings, nil, label)
            assert_equal 1, adapter.captured_commands.length, label
            assert_equal "git", adapter.captured_commands.fetch(0).fetch(0), label
          end
        end
      end
      # rubocop:enable Metrics/AbcSize

      def test_expected_missing_ref_status_returns_the_missing_branch_skip_note
        with_coverage_record do
          adapter = adapter_capturing(missing_branch_responses)

          findings = adapter.call

          assert_skip_finding(findings, "default branch main is missing locally")
          assert(adapter.captured_commands.all? { _1.fetch(0) == "git" })
          ref_probes = adapter.captured_commands.select { _1.include?("--verify") }
          assert(ref_probes.all? { _1.include?("--quiet") })
        end
      end

      def test_expected_no_merge_base_status_returns_the_no_ancestor_skip_note
        with_coverage_record do
          adapter = adapter_capturing(no_merge_base_responses)

          findings = adapter.call

          assert_skip_finding(findings, "no common ancestor")
          assert(adapter.captured_commands.all? { _1.fetch(0) == "git" })
        end
      end

      def test_command_raises_when_automatic_comparison_cannot_resolve_a_point
        adapter = adapter_capturing(missing_branch_responses)

        error = assert_raises(ArgumentError) { adapter.command }

        assert_includes error.message, "comparison point"
      end

      # rubocop:disable Metrics/AbcSize
      def test_git_probe_timeout_cleans_up_the_process_group_and_starts_nothing_later
        Dir.mktmpdir do |root|
          paths = timeout_probe_paths(root)
          write_timeout_probe_scripts(paths)
          write_coverage_record(paths.fetch(:project))

          findings = with_probe_environment(paths) do
            Dir.chdir(paths.fetch(:project)) do
              timeout_probe_adapter(paths).call
            end
          end

          parent_pid = Integer(File.read(paths.fetch(:parent_pid)))
          assert_tool_failure(findings, "timeout")
          assert_equal 1, File.readlines(paths.fetch(:log), chomp: true).length
          assert_process_stopped(parent_pid)
        ensure
          stop_process_from(paths&.fetch(:parent_pid, nil))
        end
      end
      # rubocop:enable Metrics/AbcSize

      private

      def adapter_capturing(responses, config: config_with_timeout(10))
        Undercover.new(config:).tap do |adapter|
          adapter.define_singleton_method(:captured_commands) { @captured_commands ||= [] }
          adapter.define_singleton_method(:captured_timeouts) { @captured_timeouts ||= [] }
          adapter.define_singleton_method(:capture) do |argv, timeout_seconds, **_options|
            captured_commands << argv
            captured_timeouts << timeout_seconds
            response_or_error = responses.shift || raise("unexpected capture for #{argv.inspect}")
            raise response_or_error if response_or_error.is_a?(Exception)

            response_or_error
          end
        end
      end

      def response(stdout: "", stderr: "", status: 0)
        [stdout, stderr, process_status(status)]
      end

      def process_status(exitstatus)
        Object.new.tap do |result|
          result.define_singleton_method(:success?) { exitstatus.zero? }
          result.define_singleton_method(:exited?) { true }
          result.define_singleton_method(:exitstatus) { exitstatus }
        end
      end

      def config_with_timeout(seconds)
        timeouts = Config.defaults.fetch(:timeouts).merge(undercover: seconds)
        Config.new(Config.defaults.merge(timeouts:))
      end

      def with_coverage_record(&block)
        Dir.mktmpdir do |dir|
          write_coverage_record(dir)
          Dir.chdir(dir, &block)
        end
      end

      def write_coverage_record(dir)
        path = File.join(dir, Undercover::COVERAGE_PATH)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "{}")
      end

      def clean_report
        json = JSON.generate("warnings" => [], "summary" => { "total_warnings" => 0, "files_affected" => 0 })
        "#{json}\nUndercover finished in 0.0123s\n"
      end

      def missing_branch_responses
        [
          response(status: 1),
          response(status: 1),
          response(status: 1),
          response(stdout: "false\n"),
          response(stdout: "feature\n"),
          response(stdout: "head parent\n")
        ]
      end

      def no_merge_base_responses
        [
          response(status: 1),
          response(stdout: "main\n"),
          response(stdout: "head parent\n"),
          response(status: 1),
          response(stdout: "false\n"),
          response(stdout: "feature\n"),
          response(stdout: "head parent\n")
        ]
      end

      def assert_tool_failure(findings, message = nil, label = nil)
        assert_equal 1, findings.length, label
        assert findings.fetch(0).tool_failure?, label
        assert_includes findings.fetch(0).message, message, label if message
      end

      def assert_skip_finding(findings, message)
        assert_equal 1, findings.length
        finding = findings.fetch(0)
        refute finding.tool_failure?
        assert_equal Undercover::SKIP_RULE, finding.rule
        assert_equal :info, finding.severity
        assert_includes finding.message, message
      end

      def with_monotonic_times(*times, &block)
        last = times.last
        clock = ->(_clock) { times.empty? ? last : times.shift }
        Process.stub(:clock_gettime, clock, &block)
      end

      def timeout_probe_paths(root)
        {
          project: File.join(root, "project"),
          log: File.join(root, "commands.log"),
          marker: File.join(root, "first-probe"),
          parent_pid: File.join(root, "parent.pid"),
          git_script: File.join(root, "git_probe.rb"),
          undercover_script: File.join(root, "undercover_probe.rb")
        }.tap { Dir.mkdir(_1.fetch(:project)) }
      end

      def write_timeout_probe_scripts(paths)
        File.write(paths.fetch(:git_script), timeout_git_script)
        File.write(paths.fetch(:undercover_script), <<~RUBY)
          File.open(ENV.fetch("QUALITY_GATE_PROBE_LOG"), "a") { _1.puts "undercover" }
        RUBY
      end

      def timeout_probe_adapter(paths)
        Undercover.new(config: config_with_timeout(1)).tap do |adapter|
          adapter.define_singleton_method(:git_command) do |arguments|
            [RbConfig.ruby, paths.fetch(:git_script), *arguments]
          end
          adapter.define_singleton_method(:command) do
            [RbConfig.ruby, paths.fetch(:undercover_script)]
          end
        end
      end

      def timeout_git_script
        <<~'RUBY'
          log = ENV.fetch("QUALITY_GATE_PROBE_LOG")
          marker = ENV.fetch("QUALITY_GATE_PROBE_MARKER")
          File.open(log, "a") { _1.puts "git #{ARGV.join(" ")}" }
          exit 2 if File.exist?(marker)

          File.write(marker, "started")
          trap("TERM") { exit! 0 }
          File.write(ENV.fetch("QUALITY_GATE_PROBE_PARENT_PID"), Process.pid.to_s)
          sleep 2
          exit 2
        RUBY
      end

      def with_probe_environment(paths)
        values = {
          "QUALITY_GATE_PROBE_LOG" => paths.fetch(:log),
          "QUALITY_GATE_PROBE_MARKER" => paths.fetch(:marker),
          "QUALITY_GATE_PROBE_PARENT_PID" => paths.fetch(:parent_pid)
        }
        previous = values.to_h { |key, _value| [key, ENV[key]] }
        values.each { ENV[_1] = _2 }
        yield
      ensure
        previous&.each { ENV[_1] = _2 }
      end

      def assert_process_stopped(pid)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
        loop do
          Process.kill(0, pid)
          flunk "process #{pid} survived cleanup" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.01
        rescue Errno::ESRCH
          assert true
          return
        end
      end

      def stop_process_from(path)
        return unless path && File.file?(path)

        Process.kill("KILL", Integer(File.read(path)))
      rescue Errno::ESRCH
        nil
      end
    end
  end
end
