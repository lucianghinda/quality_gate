# frozen_string_literal: true

require "English"
require "open3"

module QualityGate
  # Raised when adapter output cannot be parsed into findings.
  class ParseError < Error
    attr_reader :tool

    def initialize(tool:, reason:)
      @tool = tool.dup.freeze
      super("Could not parse #{@tool} output: #{reason}")
    end
  end

  # Executes one quality tool without involving a shell and normalizes failures.
  # rubocop:disable Metrics/ClassLength
  class Adapter
    STDERR_LINE_LIMIT = 20
    TERMINATE_GRACE_SECONDS = 0.2

    def initialize(config:, files: [], diagnostic_io: $stderr)
      @config = config
      @files = files.map { copy_string(_1) }.freeze
      @diagnostic_io = diagnostic_io
    end

    def call
      tool = name
      stderr = +""
      stdout, stderr, = capture(validated_command, resolved_timeout(tool))
      findings = parse(stdout)
      validate_findings!(findings, expected_tool: tool)
      findings
    rescue StandardError => e
      [failure_finding(tool, e, stderr)]
    end

    def name
      raise NotImplementedError, "#{self.class} must implement #name"
    end

    def command
      raise NotImplementedError, "#{self.class} must implement #command"
    end

    def parse(_stdout)
      raise NotImplementedError, "#{self.class} must implement #parse"
    end

    def timeout
      resolved_timeout(name)
    end

    private

    attr_reader :config, :diagnostic_io, :files

    def validated_command
      value = command
      return value if value.is_a?(Array) && value.all?(String)

      raise ArgumentError, "command must be an array of strings"
    end

    def validate_findings!(findings, expected_tool:)
      raise TypeError, "parse must return an array of findings" unless findings.is_a?(Array)

      findings.each do |finding|
        raise TypeError, "parse must return finding objects" unless finding.is_a?(Finding)
        unless finding.tool == expected_tool
          raise ArgumentError, "finding tool must match adapter #{expected_tool.inspect}"
        end

        unless Finding::SEVERITIES.include?(finding.severity)
          raise ArgumentError, "invalid finding severity #{finding.severity.inspect}"
        end
      end
    end

    def capture(argv, timeout_seconds, env: {}, combine_output: false)
      stdin, stdout, stderr, wait_thread = open_capture(argv, env, combine_output)
      resources = {
        process_group_id: -wait_thread.pid,
        wait_thread:,
        stdin:,
        stdout:,
        stderr:,
        readers: {}
      }
      deadline = monotonic_deadline(timeout_seconds)

      stdin.close
      register_readers(resources)

      wait_for_process(wait_thread, timeout_seconds, deadline)
      stdout_text = captured_output(resources, :stdout, timeout_seconds, deadline)
      stderr_text = captured_output(resources, :stderr, timeout_seconds, deadline)

      [stdout_text, stderr_text, wait_thread.value]
    ensure
      cleanup_capture(resources, $ERROR_INFO)
    end

    def open_capture(argv, env, combine_output)
      return merged_capture(env, argv) if combine_output

      Open3.popen3(env, *argv, pgroup: true)
    end

    def merged_capture(env, argv)
      stdin, output, wait_thread = Open3.popen2e(env, *argv, pgroup: true)
      [stdin, output, nil, wait_thread]
    end

    def register_readers(resources)
      readers = resources.fetch(:readers)
      readers[:stdout] = reader_thread(resources.fetch(:stdout))
      stderr = resources.fetch(:stderr)
      readers[:stderr] = reader_thread(stderr) if stderr
    end

    def captured_output(resources, stream, timeout_seconds, deadline)
      reader = resources.fetch(:readers).fetch(stream, nil)
      return +"" unless reader

      fetch_reader_output(reader, timeout_seconds, deadline)
    end

    def wait_for_process(wait_thread, timeout_seconds, deadline)
      return if wait_thread.join(remaining_before(deadline))

      raise TimeoutError, "timeout after #{timeout_seconds} seconds"
    end

    def fetch_reader_output(reader, timeout_seconds, deadline)
      return reader.value if reader.join(remaining_before(deadline))

      raise TimeoutError, "timeout after #{timeout_seconds} seconds"
    end

    # rubocop:disable Metrics/AbcSize
    def cleanup_capture(resources, active_exception)
      return unless resources

      terminate_process_group(resources, active_exception) if active_exception
      cleanup_action(active_exception) { close_pipe(resources.fetch(:stdin)) }
      cleanup_action(active_exception) { close_pipe(resources.fetch(:stdout)) }
      cleanup_action(active_exception) { close_pipe(resources.fetch(:stderr)) }
      cleanup_action(active_exception) { join_reader(resources.fetch(:readers)&.fetch(:stdout, nil)) }
      cleanup_action(active_exception) { join_reader(resources.fetch(:readers)&.fetch(:stderr, nil)) }
    end
    # rubocop:enable Metrics/AbcSize

    def terminate_process_group(resources, active_exception)
      process_group_id = resources.fetch(:process_group_id)
      wait_thread = resources.fetch(:wait_thread)
      process_pid = wait_thread.pid

      cleanup_action(active_exception) { signal_with_fallback("TERM", process_group_id, process_pid) }
      wait_thread.join(TERMINATE_GRACE_SECONDS)
      return unless process_group_alive?(process_group_id)

      cleanup_action(active_exception) { signal_with_fallback("KILL", process_group_id, process_pid) }
      wait_thread.join if wait_thread&.alive?
    rescue Errno::ESRCH
      wait_thread.join if wait_thread&.alive?
    end

    def signal_with_fallback(signal, process_group_id, process_pid)
      signal_process_group(signal, process_group_id)
    rescue StandardError
      signal_process(signal, process_pid)
    end

    def signal_process_group(signal, process_group_id)
      return unless process_group_id

      Process.kill(signal, process_group_id)
    end

    def signal_process(signal, process_pid)
      Process.kill(signal, process_pid)
    end

    def process_group_alive?(process_group_id)
      Process.kill(0, process_group_id)
      true
    rescue Errno::EPERM
      true
    rescue Errno::ESRCH
      false
    end

    def cleanup_action(active_exception)
      yield
    rescue StandardError
      raise unless active_exception
    end

    def reader_thread(pipe)
      Thread.new do
        Thread.current.report_on_exception = false
        pipe.read.to_s
      end
    end

    def close_pipe(pipe)
      pipe.close unless pipe.nil? || pipe.closed?
    rescue IOError, SystemCallError
      nil
    end

    def join_reader(reader)
      return unless reader

      reader.join
      reader.value
    end

    def monotonic_deadline(timeout_seconds)
      Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
    end

    def remaining_before(deadline)
      [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
    end

    def failure_message(tool, error, stderr)
      reason = sanitize_fragment(error.message)
      message = "#{tool}: #{reason}"
      stderr_tail = sanitized_stderr_tail(stderr)
      return message if stderr_tail.empty? || !unreadable_output?(error)

      "#{message} stderr: #{stderr_tail}"
    end

    def failure_finding(tool, error, stderr)
      safe_tool = safe_failure_tool(tool)
      Finding.tool_failure(tool: safe_tool, message: safe_failure_message(safe_tool, error, stderr))
    rescue StandardError
      Finding.tool_failure(tool: fallback_tool_name, message: "#{fallback_tool_name}: adapter failure")
    end

    def safe_failure_tool(tool)
      normalized_tool_name(tool || fallback_tool_name)
    rescue StandardError
      fallback_tool_name
    end

    def safe_failure_message(tool, error, stderr)
      failure_message(tool, error, stderr)
    rescue StandardError
      "#{tool}: adapter failure"
    end

    def resolved_timeout(tool)
      tool_timeouts = config.fetch(:timeouts)
      raise ArgumentError, "timeouts config must be a mapping" unless tool_timeouts.is_a?(Hash)

      validate_timeout_value(timeout_value_for(tool_timeouts, tool))
    rescue KeyError
      raise ArgumentError, "timeouts config is missing"
    end

    def timeout_value_for(tool_timeouts, tool)
      return tool_timeouts.fetch(tool.to_sym) if tool_timeouts.key?(tool.to_sym)
      return tool_timeouts.fetch(:default) if tool_timeouts.key?(:default)

      raise ArgumentError, "timeout default is missing"
    end

    def validate_timeout_value(timeout_value)
      return timeout_value if timeout_value.is_a?(Integer) && timeout_value.positive?

      raise ArgumentError, "timeout must be a positive Integer"
    end

    def unreadable_output?(error)
      error.is_a?(ParseError)
    end

    def sanitized_stderr_tail(stderr)
      stderr
        .to_s
        .dup
        .force_encoding(Encoding::UTF_8)
        .scrub("?")
        .lines
        .map { sanitize_fragment(_1) }
        .reject(&:empty?)
        .last(STDERR_LINE_LIMIT)
        .join(" | ")
    end

    def sanitize_fragment(text)
      text
        .to_s
        .dup
        .force_encoding(Encoding::UTF_8)
        .scrub("?")
        .gsub(/[[:cntrl:]]+/, " ")
        .gsub(/\s+/, " ")
        .strip
    end

    def fallback_tool_name
      component = self.class.name.to_s.split("::").last.to_s
      tool_name = sanitize_fragment(component).downcase
      tool_name.empty? ? "adapter" : tool_name
    end

    def normalized_tool_name(tool)
      sanitized = sanitize_fragment(tool)
      sanitized.empty? ? fallback_tool_name : sanitized
    end

    def copy_string(value)
      value.dup.freeze
    end

    class TimeoutError < StandardError; end

    private_constant :STDERR_LINE_LIMIT, :TERMINATE_GRACE_SECONDS, :TimeoutError
  end
  # rubocop:enable Metrics/ClassLength
end
