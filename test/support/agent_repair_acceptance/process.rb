# frozen_string_literal: true

require "open3"

module AgentRepairAcceptance
  class ProcessCapture < QualityGate::Adapter
    Result = Data.define(:stdout, :stderr, :status, :timed_out)

    def initialize(argv:, chdir:, env: {}, timeout: 600)
      @argv = argv
      @chdir = chdir
      @env = env
      @timeout = timeout
      super(config: { timeouts: { default: timeout } })
    end

    def run
      stdout, stderr, status = capture_process
      Result.new(stdout:, stderr:, status: status&.exitstatus || 128 + status.termsig, timed_out: false)
    rescue StandardError => e
      return Result.new(stdout: "", stderr: e.message, status: 124, timed_out: true) if timeout_error?(e)

      raise Error, "#{name}: #{e.message}"
    end

    def name
      "acceptance process"
    end

    def command
      @argv
    end

    def parse(stdout)
      stdout
    end

    private

    def capture_process
      send(:capture, @argv, @timeout, env: @env)
    end

    def open_capture(argv, env, _combine_output)
      Open3.popen3(env, *argv, chdir: @chdir, pgroup: true)
    end

    def timeout_error?(error)
      error.instance_of?(QualityGate::Adapter.const_get(:TimeoutError, false))
    end
  end
end
