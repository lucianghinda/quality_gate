# frozen_string_literal: true

module AgentRepairAcceptance
  class ProjectRunner
    def initialize(root, manifest)
      @root = Pathname(root).expand_path
      @manifest = manifest
    end

    def final_checks
      {
        "fast" => gate("fast"),
        "verify" => gate("verify"),
        "behavior" => behavior,
        "protected_files_unchanged" => protected_files_unchanged?,
        "allowed_mutations_only" => allowed_mutations_only?,
        "head_unchanged" => head_unchanged?
      }
    end

    private

    def gate(name)
      result = ProcessCapture.new(argv: ["bundle", "exec", "quality_gate", name],
                                  chdir: @root.to_s, env: trial_env, timeout: 600).run
      { "status" => result.status, "report" => JSON.parse(result.stdout) }
    rescue JSON::ParserError => e
      { "status" => result&.status || 2, "report" => { "error" => e.message } }
    end

    def behavior
      script = <<~RUBY
        require File.expand_path(#{AgentRepairAcceptance::SOURCE.inspect}, Dir.pwd)
        valid = Calculator.add(2, 3) == 5 && Calculator.add(-4, 9) == 5
        if ENV.fetch("AGENT_REPAIR_SCENARIO") == "verify"
          valid &&= Calculator.subtract(7, 4) == 3 && Calculator.subtract(-2, 5) == -7
        end
        exit(valid ? 0 : 1)
      RUBY
      env = trial_env.merge("AGENT_REPAIR_SCENARIO" => @manifest.fetch("scenario"))
      result = ProcessCapture.new(argv: ["bundle", "exec", RbConfig.ruby, "-e", script],
                                  chdir: @root.to_s, env:, timeout: 120).run
      result.status.zero? && !result.timed_out
    end

    def protected_files_unchanged?
      @manifest.fetch("protected_files").all? do |relative, digest|
        path = @root.join(relative)
        path.file? && Digest::SHA256.file(path).hexdigest == digest
      end
    end

    def head_unchanged?
      out, _err, status = Open3.capture3("git", "rev-parse", "HEAD", chdir: @root.to_s)
      status.success? && out.strip == @manifest.fetch("head")
    end

    def allowed_mutations_only?
      output, _error, status = Open3.capture3("git", "status", "--porcelain", chdir: @root.to_s)
      return false unless status.success?

      output.lines.all? do |line|
        path = line[3..].to_s.strip
        path == AgentRepairAcceptance::SOURCE || path.match?(%r{\Atest/.+_test\.rb\z})
      end
    end

    def trial_env
      cleared = ENV.keys.grep(/\A(?:BUNDLE_|BUNDLER_|GIT_|RUBYOPT\z|RUBYLIB\z)/).to_h { [_1, nil] }
      cleared.merge(
        "BUNDLE_GEMFILE" => @root.join("Gemfile").to_s,
        "GEM_HOME" => @root.join(".trial-gems").to_s,
        "GEM_PATH" => [@root.join(".trial-gems"), *Gem.path].join(File::PATH_SEPARATOR),
        "GIT_CONFIG_GLOBAL" => File::NULL,
        "GIT_CONFIG_NOSYSTEM" => "1"
      )
    end
  end
end
