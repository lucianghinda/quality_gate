# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "timeout"

module QualityGate
  class HookLogTest < Minitest::Test
    def test_default_path_and_instance_path_are_frozen_and_caller_owned
      assert defined?(HookLog), "expected QualityGate::HookLog to load with the gem"

      caller_path = String.new("tmp/hooks.jsonl")
      log = HookLog.new(path: caller_path)

      caller_path.replace("elsewhere")

      assert_equal "log/quality_gate_hooks.jsonl", HookLog::DEFAULT_PATH
      assert_predicate HookLog::DEFAULT_PATH, :frozen?
      assert_equal "tmp/hooks.jsonl", log.path
      assert_predicate log.path, :frozen?
      refute_same caller_path, log.path
      assert_raises(FrozenError) { log.path.replace("changed") }
    end

    def test_recent_returns_the_last_valid_records_not_the_last_physical_lines
      Dir.mktmpdir do |dir|
        path = File.join(dir, "hooks.jsonl")
        lines = 25.times.flat_map do |index|
          [JSON.generate(valid_record(file: "file-#{index}.rb")), "{broken-#{index}"]
        end
        File.write(path, "#{lines.join("\n")}\n")
        log = HookLog.new(path: path)

        assert_respond_to log, :recent
        records = log.recent(limit: 20)

        assert_equal((5...25).map { "file-#{_1}.rb" }, records.map { _1.fetch("file") })
      end
    end

    def test_recent_skips_every_malformed_record_shape_and_keeps_forward_compatible_records
      Dir.mktmpdir do |dir|
        path = File.join(dir, "hooks.jsonl")
        valid = valid_record(file: nil).merge("future" => { "supported" => true })
        lines = [
          "{not-json",
          "\xFF".b,
          JSON.generate([]),
          JSON.generate(nil),
          JSON.generate(valid_record(file: "bad.rb").tap { _1.delete("file") }),
          JSON.generate(valid_record(file: "bad.rb").merge("ts" => 1)),
          JSON.generate(valid_record(file: "bad.rb").merge("file" => 1)),
          JSON.generate(valid_record(file: "bad.rb").merge("outcome" => "unknown")),
          JSON.generate(valid_record(file: "bad.rb").merge("duration_ms" => "12")),
          JSON.generate(valid_record(file: "bad.rb").merge("duration_ms" => -1)),
          JSON.generate(valid)
        ]
        File.binwrite(path, lines.map(&:b).join("\n".b) << "\n".b)

        records = HookLog.new(path: path).recent

        assert_equal [valid], records
      end
    end

    def test_recent_round_trips_every_stop_hook_outcome
      outcomes = %w[
        verify_skipped verify_debounced verify_clean
        verify_blocked verify_unavailable verify_cap
      ]

      with_log_records(outcomes) do |log|
        assert_equal(outcomes, log.recent.map { _1.fetch("outcome") })
      end
    end

    def test_unavailable_count_counts_only_unavailable_records_in_the_valid_window
      with_log_records(%w[unavailable clean unavailable skipped unavailable]) do |log|
        assert_respond_to log, :unavailable_count
        assert_equal 3, log.unavailable_count(limit: 5)
        assert_equal 1, log.unavailable_count(limit: 2)
      end
    end

    def test_warning_line_names_the_count_window_and_concrete_recovery_checks
      with_log_records(%w[unavailable clean unavailable unavailable]) do |log|
        assert_respond_to log, :warning_line
        warning = log.warning_line(limit: 20)

        assert_includes warning, "3"
        assert_includes warning, "last 20"
        assert_match(/bundle/i, warning)
        assert_match(/hook setup/i, warning)
      end
    end

    def test_unavailable_count_includes_stop_failures_within_the_same_window
      outcomes = %w[unavailable verify_unavailable verify_clean verify_unavailable verify_cap]

      with_log_records(outcomes) do |log|
        assert_equal 3, log.unavailable_count(limit: 5)
        assert_equal 1, log.unavailable_count(limit: 2)
        assert_includes log.warning_line, "3 of the last 20 automatic checks could not run"
      end
    end

    def test_warning_line_is_nil_for_missing_and_healthy_logs
      Dir.mktmpdir do |dir|
        assert_nil HookLog.new(path: File.join(dir, "missing.jsonl")).warning_line
      end

      with_log_records(%w[clean skipped findings]) do |log|
        assert_nil log.warning_line
      end
    end

    def test_read_errors_from_a_directory_fail_safe
      Dir.mktmpdir do |dir|
        log = HookLog.new(path: dir)

        assert_equal [], log.recent
        assert_nil log.warning_line
      end
    end

    def test_recent_rejects_a_symlink_to_a_regular_file
      Dir.mktmpdir do |dir|
        target = File.join(dir, "target.jsonl")
        path = File.join(dir, "hooks.jsonl")
        File.write(target, "#{JSON.generate(valid_record(file: "target.rb"))}\n")
        File.symlink(target, path)

        assert_equal [], HookLog.new(path: path).recent
      end
    end

    def test_recent_rejects_a_device_symlink_without_blocking
      Dir.mktmpdir do |dir|
        path = File.join(dir, "hooks.jsonl")
        File.symlink("/dev/zero", path)

        assert_equal [], Timeout.timeout(0.25) { HookLog.new(path: "/dev/zero").recent }
        records = Timeout.timeout(0.25) { HookLog.new(path: path).recent }

        assert_equal [], records
      end
    end

    def test_recent_reads_valid_tail_without_scanning_a_large_malformed_prefix
      Dir.mktmpdir do |dir|
        path = File.join(dir, "hooks.jsonl")
        expected = [
          valid_record(file: "recent-1.rb", outcome: "unavailable"),
          valid_record(file: "recent-2.rb")
        ]
        File.open(path, "wb") do |file|
          file.seek((256 * 1024 * 1024) - 1)
          file.write("x\n")
          expected.each { file.puts(JSON.generate(_1)) }
        end

        records = Timeout.timeout(0.1) { HookLog.new(path: path).recent }

        assert_equal expected, records
      end
    end

    def test_recent_keeps_a_complete_record_at_the_tail_window_boundary
      Dir.mktmpdir do |dir|
        path = File.join(dir, "hooks.jsonl")
        record = valid_record(file: "boundary.rb")
        record_line = JSON.generate(record)
        malformed_line = "x" * ((1024 * 1024) - record_line.bytesize - 2)
        File.binwrite(path, "older\n#{record_line}\n#{malformed_line}\n")

        assert_equal [record], HookLog.new(path: path).recent
      end
    end

    def test_recent_skips_an_oversized_valid_record_without_losing_the_valid_tail
      Dir.mktmpdir do |dir|
        path = File.join(dir, "hooks.jsonl")
        oversized = valid_record(file: "oversized.rb").merge("padding" => "x" * (128 * 1024))
        expected = valid_record(file: "recent.rb")
        File.write(path, "#{JSON.generate(oversized)}\n#{JSON.generate(expected)}\n")

        assert_equal [expected], HookLog.new(path: path).recent
      end
    end

    private

    def valid_record(file:, outcome: "clean", duration_ms: 12)
      {
        "ts" => "2026-08-30T04:00:00Z",
        "file" => file,
        "outcome" => outcome,
        "duration_ms" => duration_ms
      }
    end

    def with_log_records(outcomes)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "hooks.jsonl")
        records = outcomes.each_with_index.map do |outcome, index|
          JSON.generate(valid_record(file: "file-#{index}.rb", outcome: outcome))
        end
        File.write(path, "#{records.join("\n")}\n")

        yield HookLog.new(path: path)
      end
    end
  end
end
