# frozen_string_literal: true

require "test_helper"
require "rbconfig"
require "stringio"
require "securerandom"
require "tmpdir"

module QualityGate
  class ParseErrorTest < Minitest::Test
    def test_copies_tool_and_names_tool_and_reason_in_message
      tool = String.new("rubocop")

      error = ParseError.new(tool: tool, reason: "stdout was not valid JSON")

      tool.replace("changed")

      assert_equal "rubocop", error.tool
      assert_raises(FrozenError) { error.tool.replace("other") }
      assert_includes error.message, "rubocop"
      assert_includes error.message, "stdout was not valid JSON"
    end
  end

  class AdapterTest < Minitest::Test
    def test_diagnostic_io_is_injected_and_private
      diagnostic_io = StringIO.new
      adapter = build_adapter(command: ruby_command(""), diagnostic_io:)

      assert_same diagnostic_io, adapter.send(:diagnostic_io)
      assert_raises(NoMethodError) { adapter.diagnostic_io }
    end

    def test_files_are_defensively_copied_and_frozen
      source = [String.new("lib/file with spaces.rb")]
      adapter = build_adapter(command: ruby_command(""), files: source)

      source.first.replace("changed elsewhere")
      source << "other.rb"

      assert_equal ["lib/file with spaces.rb"], adapter.files
      assert_raises(FrozenError) { adapter.files << "again.rb" }
      assert_raises(FrozenError) { adapter.files.first.replace("mutated") }
    end

    def test_command_array_keeps_a_file_path_with_spaces_as_one_argument
      Dir.mktmpdir do |dir|
        capture_path = File.join(dir, "captured.txt")
        file_path = File.join(dir, "folder with spaces", "target file.rb")
        command = ruby_command("File.write(ARGV[0], ARGV[1])", capture_path, file_path)
        adapter = build_adapter(command:, files: [file_path])

        findings = adapter.call

        assert_empty findings
        assert_equal file_path, File.read(capture_path)
      end
    end

    def test_capture_merges_environment_over_the_host_environment
      adapter = build_adapter(command: ruby_command(""))
      host_key = "QUALITY_GATE_ADAPTER_HOST_ENV"
      override_key = "QUALITY_GATE_ADAPTER_OVERRIDE_ENV"
      previous_host = ENV[host_key]
      previous_override = ENV[override_key]
      ENV[host_key] = "preserved"
      ENV[override_key] = "host-value"

      stdout, _stderr, status = adapter.send(
        :capture,
        ruby_command('puts [ENV.fetch(ARGV[0]), ENV.fetch(ARGV[1])].join(":")', host_key, override_key),
        120,
        env: { override_key => "adapter-value" }
      )

      assert_predicate status, :success?
      assert_equal "preserved:adapter-value\n", stdout
    ensure
      ENV[host_key] = previous_host
      ENV[override_key] = previous_override
    end

    def test_exit_status_one_with_readable_output_returns_ordinary_findings
      command = ruby_command(<<~RUBY)
        puts "app/models/user.rb:4:warning:Style/RedundantFreeze"
        puts "app/models/user.rb:8:error:Lint/UselessAssignment"
        puts "app/models/user.rb:12:info:Metrics/LineLength"
        exit 1
      RUBY
      adapter = build_adapter(command:, parse_proc: method(:parse_lines))

      findings = adapter.call

      assert_equal 3, findings.length
      assert_equal %i[warning error info], findings.map(&:severity)
      refute findings.any?(&:tool_failure?)
    end

    def test_exit_status_zero_with_readable_output_returns_findings
      command = ruby_command('puts "app/models/user.rb:2:warning:Style/StringLiterals"')
      adapter = build_adapter(command:, parse_proc: method(:parse_lines))

      findings = adapter.call

      assert_equal 1, findings.length
      assert_equal "Style/StringLiterals", findings.first.rule
      refute findings.first.tool_failure?
    end

    def test_missing_program_returns_one_tool_failure
      command = ["missing-tool-#{SecureRandom.hex(6)}"]
      adapter = build_adapter(command:, name: "missing-tool")

      findings = adapter.call

      assert_equal 1, findings.length
      assert findings.first.tool_failure?
      assert_includes findings.first.message, "missing-tool"
    end

    def test_timeout_stops_the_process_group_and_returns_one_tool_failure
      Dir.mktmpdir do |dir|
        pid_path = File.join(dir, "pid.txt")
        command = ruby_command(<<~RUBY, pid_path)
          trap("TERM") { exit! 0 }
          File.write(ARGV[0], Process.pid.to_s)
          sleep 10
        RUBY
        config = Config.new(Config.defaults.merge(timeouts: { default: 120, fake: 1 }))
        adapter = build_adapter(command:, config:)

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        findings = adapter.call
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        pid = Integer(File.read(pid_path))

        assert_operator elapsed, :<, 3
        assert_equal 1, findings.length
        assert findings.first.tool_failure?
        assert_includes findings.first.message, "timeout"
        assert_includes findings.first.message, "1"
        assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
      end
    end

    def test_parse_error_includes_only_the_last_twenty_stderr_lines_on_one_line
      lines = (1..30).map { format("stderr-%02d", _1) }
      command = ruby_command(<<~RUBY, *lines)
        puts "not parseable"
        ARGV.each { |line| warn line }
      RUBY
      adapter = build_adapter(command:) do |_stdout|
        raise ParseError.new(tool: "fake", reason: "unreadable output")
      end

      findings = adapter.call

      assert_equal 1, findings.length
      assert findings.first.tool_failure?
      assert_includes findings.first.message, "unreadable output"
      assert_includes findings.first.message, "stderr-30"
      assert_includes findings.first.message, "stderr-11"
      refute_includes findings.first.message, "stderr-10"
      refute_includes findings.first.message, "stderr-01"
      refute_includes findings.first.message, "\n"
    end

    def test_invalid_command_shape_is_contained
      adapter = build_adapter(command: "bundle exec rubocop")

      findings = adapter.call

      assert_equal 1, findings.length
      assert findings.first.tool_failure?
      assert_includes findings.first.message, "command"
    end

    def test_non_finding_parse_results_are_replaced_with_one_tool_failure
      imposter = Struct.new(:severity).new(:warning)
      adapter = build_adapter(command: ruby_command("")) { |_stdout| [imposter] }

      findings = adapter.call

      assert_equal 1, findings.length
      assert findings.first.tool_failure?
      assert_instance_of Finding, findings.first
      assert_includes findings.first.message, "finding"
    end

    def test_failure_tool_identity_is_sanitized_for_message_and_tool_failure
      unsafe_name = "bad\nname\u0001".dup
      unsafe_name << "\xFF".b.force_encoding(Encoding::UTF_8)
      adapter = build_adapter(name: unsafe_name, command: "bundle exec rubocop")

      findings = adapter.call
      failure = findings.fetch(0)

      assert_equal 1, findings.length
      assert failure.tool_failure?
      assert_equal "bad name ?", failure.tool
      assert_equal Encoding::UTF_8, failure.message.encoding
      assert failure.message.valid_encoding?
      refute_match(/[[:cntrl:]]/, failure.message)
      refute_includes failure.message, "\n"
      assert_includes failure.message, "bad name ?"
    end

    def test_invalid_finding_severity_replaces_the_entire_result_with_one_tool_failure
      adapter = build_adapter(command: ruby_command("")) do |_stdout|
        [
          Finding.new(
            tool: "fake",
            file: "lib/example.rb",
            line: 3,
            rule: "Example/Rule",
            severity: :fatal,
            message: "bad severity"
          )
        ]
      end

      findings = adapter.call

      assert_equal 1, findings.length
      assert findings.first.tool_failure?
      assert_includes findings.first.message, "severity"
    end

    def test_parsed_findings_with_a_spoofed_tool_are_replaced_with_one_tool_failure
      adapter = build_adapter(command: ruby_command("")) do |_stdout|
        [
          Finding.new(
            tool: "other-tool",
            file: "lib/example.rb",
            line: 3,
            rule: "Example/Rule",
            severity: :warning,
            message: "spoofed tool"
          )
        ]
      end

      findings = adapter.call

      assert_equal 1, findings.length
      assert findings.first.tool_failure?
      assert_includes findings.first.message, "tool"
    end

    def test_standard_error_during_parse_is_contained
      adapter = build_adapter(command: ruby_command("")) do |_stdout|
        raise "boom"
      end

      findings = adapter.call

      assert_equal 1, findings.length
      assert findings.first.tool_failure?
      assert_includes findings.first.message, "boom"
    end

    def test_broken_error_message_still_returns_one_tool_failure
      adapter = build_adapter(command: ruby_command("")) do |_stdout|
        raise BrokenMessageError, "ignored"
      end

      findings = adapter.call

      assert_equal 1, findings.length
      assert findings.first.tool_failure?
      assert_instance_of Finding, findings.first
      assert_includes findings.first.message, "adapter failure"
    end

    def test_broken_name_conversion_still_returns_one_tool_failure
      adapter = build_adapter(name: BrokenToolName.new, command: "bundle exec rubocop")

      findings = adapter.call

      assert_equal 1, findings.length
      assert findings.first.tool_failure?
      assert_instance_of Finding, findings.first
      assert_equal "fakeadapter", findings.first.tool
    end

    def test_anonymous_adapter_fallback_uses_literal_adapter_name
      adapter_class = Class.new(Adapter) do
        def name = BrokenToolName.new

        def command = "bundle exec rubocop"

        def parse(_stdout) = []
      end

      findings = adapter_class.new(config: Config.new(Config.defaults), files: []).call

      assert_equal 1, findings.length
      assert findings.first.tool_failure?
      assert_equal "adapter", findings.first.tool
      assert_includes findings.first.message, "adapter"
    end

    def test_non_standard_errors_are_not_contained
      adapter = build_adapter(command: ruby_command("")) do |_stdout|
        raise ScriptError, "do not swallow"
      end

      assert_raises(ScriptError) { adapter.call }
    end

    def test_timeout_prefers_the_tool_specific_value_over_default
      config = Config.new(Config.defaults.merge(timeouts: { default: 120, fake: 5 }))
      adapter = build_adapter(command: ruby_command(""), config:)

      assert_equal 5, adapter.timeout
    end

    def test_timeout_falls_back_to_the_default_value
      adapter = build_adapter(command: ruby_command(""))

      assert_equal 120, adapter.timeout
    end

    def test_invalid_timeout_values_return_one_tool_failure_without_spawning
      Dir.mktmpdir do |dir|
        marker_path = File.join(dir, "spawned.txt")
        command = ruby_command("File.write(ARGV[0], 'spawned')", marker_path)

        invalid_timeout_configs.each do |label, config|
          findings = build_adapter(command:, config:).call

          assert_equal 1, findings.length, label
          assert findings.first.tool_failure?, label
          assert_includes findings.first.message, "timeout", label
          refute File.exist?(marker_path), label
        end
      end
    end

    def test_timeout_kills_a_term_ignoring_descendant_and_avoids_thread_diagnostics
      Dir.mktmpdir do |dir|
        grandchild_path = File.join(dir, "grandchild.pid")
        script_path = File.join(dir, "spawn_grandchild.rb")
        File.write(script_path, timeout_descendant_script)
        command = [RbConfig.ruby, script_path, grandchild_path]
        adapter = build_adapter(command:, config: timeout_config(1))
        stderr, previous_stderr = capture_stderr

        findings = adapter.call
        grandchild_pid = wait_for_pid_file(grandchild_path)

        assert_equal 1, findings.length
        assert findings.first.tool_failure?
        assert_includes findings.first.message, "timeout"
        assert_process_gone(grandchild_pid)
        refute_includes stderr.string, "report_on_exception"
      ensure
        $stderr = previous_stderr if previous_stderr
      end
    end

    def test_timeout_applies_when_direct_child_exits_but_descendant_holds_pipes_open
      Dir.mktmpdir do |dir|
        descendant_path = File.join(dir, "descendant.pid")
        script_path = File.join(dir, "spawn_pipe_holder.rb")
        File.write(script_path, pipe_holding_descendant_script)
        command = [RbConfig.ruby, script_path, descendant_path]
        adapter = build_adapter(command:, config: timeout_config(1))

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        findings = adapter.call
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        descendant_pid = wait_for_pid_file(descendant_path)

        assert_operator elapsed, :<, 3
        assert_equal 1, findings.length
        assert findings.first.tool_failure?
        assert_includes findings.first.message, "timeout"
        assert_process_gone(descendant_pid)
      end
    end

    def test_interrupt_during_capture_propagates_even_when_cleanup_hits_ioerror
      adapter = interrupting_adapter(command: ruby_command("sleep 5"))

      assert_raises(Interrupt) { adapter.call }
    end

    def test_interrupt_propagates_when_group_signal_fails_and_direct_pid_fallback_runs
      Dir.mktmpdir do |dir|
        pid_path = File.join(dir, "pid.txt")
        ready_path = File.join(dir, "ready.txt")
        command = ruby_command(<<~RUBY, pid_path, ready_path)
          trap("TERM") { exit! 0 }
          File.write(ARGV[0], Process.pid.to_s)
          File.write(ARGV[1], "ready")
          sleep 10
        RUBY
        adapter = signal_fallback_interrupting_adapter(command:, ready_path:)

        assert_raises(Interrupt) { adapter.call }

        pid = wait_for_pid_file(pid_path)
        assert_process_gone(pid)
      end
    end

    def test_reader_failure_during_capture_returns_one_tool_failure
      adapter = reader_failure_adapter(command: ruby_command(""))

      findings = adapter.call

      assert_equal 1, findings.length
      assert findings.first.tool_failure?
      assert_includes findings.first.message, "read failed"
    end

    def test_timeout_only_sends_kill_if_the_process_group_is_still_alive_after_term
      adapter = signal_tracking_adapter(command: ruby_command(<<~RUBY), config: timeout_config(1))
        trap("TERM") { exit! 0 }
        sleep 10
      RUBY

      findings = adapter.call

      assert_equal 1, findings.length
      assert findings.first.tool_failure?
      assert_equal ["TERM"], adapter.signals
    end

    def test_adapter_internal_constants_are_private
      constant_getters = {
        STDERR_LINE_LIMIT: -> { QualityGate::Adapter::STDERR_LINE_LIMIT },
        TERMINATE_GRACE_SECONDS: -> { QualityGate::Adapter::TERMINATE_GRACE_SECONDS },
        TimeoutError: -> { QualityGate::Adapter::TimeoutError }
      }

      constant_getters.each_value do |getter|
        error = assert_raises(NameError, &getter)
        assert_includes error.message, "private constant"
      end
    end

    def test_second_reader_creation_failure_cleans_up_child_and_returns_one_tool_failure
      Dir.mktmpdir do |dir|
        pid_path = File.join(dir, "pid.txt")
        ready_path = File.join(dir, "ready.txt")
        command = ruby_command(<<~RUBY, pid_path, ready_path)
          trap("TERM") { exit! 0 }
          File.write(ARGV[0], Process.pid.to_s)
          File.write(ARGV[1], "ready")
          sleep 10
        RUBY
        adapter = second_reader_failure_adapter(command:, ready_path:)
        stderr, previous_stderr = capture_stderr
        child_pid = nil

        findings = adapter.call
        child_pid = wait_for_pid_file(pid_path)

        assert_equal 1, findings.length
        assert findings.first.tool_failure?
        assert_includes findings.first.message, "cannot create second reader"
        assert_process_gone(child_pid)
        assert adapter.reader_pipes.fetch(0).closed?
        assert adapter.reader_threads.fetch(0).join(1)
        refute adapter.reader_threads.fetch(0).alive?
        refute_includes stderr.string, "report_on_exception"
      ensure
        terminate_process(child_pid) if child_pid
        $stderr = previous_stderr if previous_stderr
      end
    end

    private

    # rubocop:disable Metrics/ParameterLists
    def build_adapter(
      command:,
      name: "fake",
      config: Config.new(Config.defaults),
      files: [],
      diagnostic_io: $stderr,
      parse_proc: nil,
      &block
    )
      FakeAdapter.new(
        name:,
        command:,
        parse_proc: parse_proc || block || ->(_stdout) { [] },
        config:,
        files:,
        diagnostic_io:
      )
    end
    # rubocop:enable Metrics/ParameterLists

    def ruby_command(script, *args)
      [RbConfig.ruby, "-e", script, *args]
    end

    def timeout_config(value)
      Config.new(Config.defaults.merge(timeouts: { default: 120, fake: value }))
    end

    def invalid_timeout_configs
      {
        "nil" => Config.new(Config.defaults.merge(timeouts: { default: 120, fake: nil })),
        "zero" => timeout_config(0),
        "negative" => timeout_config(-1),
        "string" => timeout_config("5"),
        "missing default" => Config.new(Config.defaults.merge(timeouts: {})),
        "missing timeouts" => Config.new(Config.defaults.reject { _1 == :timeouts })
      }
    end

    def capture_stderr
      stderr = StringIO.new
      previous_stderr = $stderr
      $stderr = stderr
      [stderr, previous_stderr]
    end

    def wait_for_pid_file(path)
      Integer(wait_for_file(path, "pid file"))
    end

    def wait_for_file(path, label)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      until File.exist?(path)
        raise "timed out waiting for #{label}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.01
      end

      File.read(path)
    end

    def assert_process_gone(pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2

      loop do
        Process.kill(0, pid)
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise "timed out waiting for process #{pid} to exit"
        end

        sleep 0.01
      rescue Errno::ESRCH
        return
      end
    end

    def terminate_process(pid)
      Process.kill("TERM", pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def timeout_descendant_script
      <<~RUBY
        grandchild_path = ARGV.fetch(0)
        fork do
          trap("TERM") { }
          File.write(grandchild_path, Process.pid.to_s)
          sleep 10
        end
        trap("TERM") { exit! 0 }
        sleep 10
      RUBY
    end

    def pipe_holding_descendant_script
      <<~RUBY
        descendant_path = ARGV.fetch(0)
        fork do
          File.write(descendant_path, Process.pid.to_s)
          sleep 10
        end
        exit 0
      RUBY
    end

    def parse_lines(stdout)
      stdout.lines(chomp: true).map do |line|
        file, line_number, severity, rule = line.split(":", 4)

        Finding.new(
          tool: "fake",
          file:,
          line: Integer(line_number),
          rule:,
          severity: severity.to_sym,
          message: rule
        )
      end
    end

    class FakeAdapter < Adapter
      attr_reader :files, :name, :command

      def initialize(name:, command:, parse_proc:, **kwargs)
        @name = name
        @command = command
        @parse_proc = parse_proc
        super(**kwargs)
      end

      def parse(stdout) = @parse_proc.call(stdout)
    end

    class InterruptingAdapter < FakeAdapter
      def initialize(ready_path: nil, **kwargs)
        @ready_path = ready_path
        super(**kwargs)
      end

      private

      def wait_for_process(_wait_thread, _timeout_seconds, _deadline)
        wait_for_ready!
        raise Interrupt, "stop now"
      end

      def close_pipe(_pipe)
        raise IOError, "close failed"
      end

      def join_reader(_reader)
        raise IOError, "join failed"
      end

      def wait_for_ready!
        return unless @ready_path

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2

        until File.exist?(@ready_path)
          raise "timed out waiting for ready file" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.01
        end
      end
    end

    class SignalFallbackInterruptingAdapter < InterruptingAdapter
      private

      def signal_process_group(_signal, _process_group_id)
        raise Errno::EPERM, "group signal failed"
      end
    end

    class ReaderFailureAdapter < FakeAdapter
      private

      def reader_thread(_pipe)
        Thread.new do
          Thread.current.report_on_exception = false
          raise IOError, "read failed"
        end
      end
    end

    class SignalTrackingAdapter < FakeAdapter
      attr_reader :signals

      def initialize(**kwargs)
        @signals = []
        super(**kwargs)
      end

      private

      def signal_process_group(signal, process_group_id)
        @signals << signal
        super
      end
    end

    class SecondReaderFailureAdapter < FakeAdapter
      attr_reader :reader_threads, :reader_pipes

      def initialize(ready_path: nil, **kwargs)
        @reader_attempts = 0
        @reader_threads = []
        @reader_pipes = []
        @ready_path = ready_path
        super(**kwargs)
      end

      private

      def reader_thread(pipe)
        @reader_attempts += 1
        @reader_pipes << pipe
        if @reader_attempts == 2
          wait_for_ready!
          raise ThreadError, "cannot create second reader"
        end

        thread = Thread.new do
          Thread.current.report_on_exception = false
          pipe.read.to_s
        rescue IOError, SystemCallError
          +""
        end
        @reader_threads << thread
        thread
      end

      def wait_for_ready!
        return unless @ready_path

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2

        until File.exist?(@ready_path)
          raise "timed out waiting for ready file" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.01
        end
      end
    end

    def interrupting_adapter(**kwargs)
      InterruptingAdapter.new(
        name: "fake",
        parse_proc: ->(_stdout) { [] },
        config: Config.new(Config.defaults),
        files: [],
        **kwargs
      )
    end

    def signal_fallback_interrupting_adapter(**kwargs)
      SignalFallbackInterruptingAdapter.new(
        name: "fake",
        parse_proc: ->(_stdout) { [] },
        config: Config.new(Config.defaults),
        files: [],
        **kwargs
      )
    end

    def reader_failure_adapter(**kwargs)
      ReaderFailureAdapter.new(
        name: "fake",
        parse_proc: ->(_stdout) { [] },
        config: Config.new(Config.defaults),
        files: [],
        **kwargs
      )
    end

    def signal_tracking_adapter(**kwargs)
      SignalTrackingAdapter.new(
        name: "fake",
        parse_proc: ->(_stdout) { [] },
        files: [],
        **kwargs
      )
    end

    def second_reader_failure_adapter(**kwargs)
      SecondReaderFailureAdapter.new(
        name: "fake",
        parse_proc: ->(_stdout) { [] },
        config: Config.new(Config.defaults),
        files: [],
        **kwargs
      )
    end

    class BrokenMessageError < StandardError
      def message
        raise "message exploded"
      end
    end

    class BrokenToolName
      def to_sym
        raise "cannot convert to symbol"
      end

      def to_s
        raise "cannot convert to string"
      end
    end
  end
end
