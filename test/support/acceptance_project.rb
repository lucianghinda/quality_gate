# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

module QualityGate
  Run = Data.define(:status, :report, :stdout, :stderr, :elapsed_seconds)

  # Materializes a generated Rails host and runs the shipped command paths inside it.
  class AcceptanceProject
    attr_reader :root

    class InvalidReport < StandardError; end
    private_constant :InvalidReport

    ADVISORY_DATABASE = ".acceptance-advisory-db"
    CACHE_DIRECTORY = ".acceptance-cache"
    BUNDLE_EXECUTABLE = Gem.bin_path("bundler", "bundle")
    EXECUTABLE = "exe/quality_gate"
    APPLICATION_ENVIRONMENT_KEYS = %w[
      DATABASE_URL PIDFILE PORT SECRET_KEY_BASE WEB_CONCURRENCY
    ].freeze
    DISABLED_HOOKS_DIRECTORY = "quality-gate-disabled-hooks"
    GIT_CONFIG = [
      "-c", "commit.gpgSign=false",
      "-c", "tag.gpgSign=false"
    ].freeze
    GIT_IDENTITY = [
      "-c", "user.name=Quality Gate Acceptance",
      "-c", "user.email=quality-gate@example.test"
    ].freeze
    GIT_ENVIRONMENT = {
      "GIT_CONFIG_GLOBAL" => File::NULL,
      "GIT_CONFIG_NOSYSTEM" => "1"
    }.freeze
    private_constant :ADVISORY_DATABASE, :CACHE_DIRECTORY, :BUNDLE_EXECUTABLE,
                     :EXECUTABLE, :APPLICATION_ENVIRONMENT_KEYS, :DISABLED_HOOKS_DIRECTORY,
                     :GIT_CONFIG, :GIT_IDENTITY, :GIT_ENVIRONMENT

    def self.open(fixture:, repository_root:)
      Dir.mktmpdir("quality-gate-acceptance") do |directory|
        project = new(directory:, fixture:, repository_root:)
        project.install
        yield project
      end
    end

    def initialize(directory:, fixture:, repository_root:)
      @directory = directory
      @root = directory
      @fixture = fixture
      @repository_root = File.expand_path(repository_root)
      @advisory_database = File.join(directory, ADVISORY_DATABASE)
      @cache_directory = File.join(directory, CACHE_DIRECTORY)
    end
    private_class_method :new

    def install
      return @install if defined?(@install)

      @install = materialize
    end

    def materialize
      copy_base
      write_gemfile
      FileUtils.mkdir_p(@cache_directory)
      lock_bundle
      generator_output = run_generator
      FileUtils.rm_f(File.join(@directory, ".quality_gate.yml"))
      seed_advisory_database
      commit_base
      apply_overlay
      generator_output
    end
    private :materialize

    def run(command, *arguments)
      started_at = monotonic_time
      stdout, stderr, status = Open3.capture3(
        environment,
        *quality_gate_command(command, arguments),
        chdir: @directory
      )
      elapsed_seconds = monotonic_time - started_at
      report = parse_report(stdout, status:, stderr:)

      Run.new(status: status.exitstatus, report:, stdout:, stderr:, elapsed_seconds:)
    end

    def invoke_hook(file:)
      file = File.expand_path(file, @directory)
      started_at = monotonic_time
      stdout, stderr, status = Open3.capture3(
        environment,
        RbConfig.ruby,
        File.join(@directory, ".claude/hooks/quality_gate_fast.rb"),
        chdir: @directory,
        stdin_data: JSON.generate("cwd" => @directory, "tool_input" => { "file_path" => file })
      )

      Run.new(
        status: status.exitstatus,
        report: nil,
        stdout:,
        stderr:,
        elapsed_seconds: monotonic_time - started_at
      )
    end

    private

    def copy_base
      FileUtils.cp_r(File.join(fixtures_root, "base", "."), @directory)
    end

    def write_gemfile
      File.write(
        File.join(@directory, "Gemfile"),
        <<~RUBY
          # frozen_string_literal: true

          source 'https://rubygems.org'

          gem 'quality_gate', path: #{ruby_string_literal(@repository_root)}
          gem 'railties', '~> 8.0'
        RUBY
      )
    end

    def ruby_string_literal(value)
      "'#{value.gsub(/['\\]/) { "\\#{_1}" }}'"
    end

    def lock_bundle
      capture!(RbConfig.ruby, BUNDLE_EXECUTABLE, "lock", "--local", label: "bundle lock --local")
    end

    def run_generator
      stdout, = capture!(*generator_command, label: "quality_gate:install")
      stdout
    end

    def generator_command
      [RbConfig.ruby, BUNDLE_EXECUTABLE, "exec", RbConfig.ruby,
       File.join(@directory, "bin/rails"), "generate", "quality_gate:install", "--agents"]
    end

    def seed_advisory_database
      FileUtils.cp_r(File.join(fixtures_root, "advisory_db"), @advisory_database)
      git!("init", "--initial-branch=main", "--quiet", chdir: @advisory_database, label: "advisory git init")
      git!(
        "remote", "add", "origin", File.join(@advisory_database, "unavailable-origin"),
        chdir: @advisory_database,
        label: "advisory unavailable origin"
      )
    end

    def commit_base
      git!("init", "--initial-branch=main", "--quiet", label: "project git init")
      exclude_runtime_directories
      git!("add", "--all", label: "project git add")
      git!(
        *GIT_IDENTITY, "commit", "--quiet", "-m", "Generated acceptance baseline",
        label: "baseline commit"
      )
      git!("checkout", "--quiet", "-b", "feature", label: "feature branch")
    end

    def exclude_runtime_directories
      File.write(
        File.join(@directory, ".git/info/exclude"),
        "/#{ADVISORY_DATABASE}/\n/#{CACHE_DIRECTORY}/\n/coverage/\n/log/\n"
      )
    end

    def apply_overlay
      overlay = File.join(fixtures_root, @fixture)
      raise ArgumentError, "unknown acceptance fixture #{@fixture.inspect}" unless File.directory?(overlay)

      FileUtils.cp_r(File.join(overlay, "."), @directory)
    end

    def quality_gate_command(command, arguments)
      [
        RbConfig.ruby,
        BUNDLE_EXECUTABLE,
        "exec",
        RbConfig.ruby,
        File.join(@repository_root, EXECUTABLE),
        command,
        *arguments,
        "--format",
        "json"
      ]
    end

    def parse_report(stdout, status:, stderr:)
      report = JSON.parse(stdout)
      validate_report!(report)
      report
    rescue JSON::ParserError, InvalidReport => e
      raise JSON::ParserError,
            "expected valid JSON report, got #{e.message}\n" \
            "status: #{status.exitstatus}\nstdout: #{stdout.inspect}\nstderr: #{stderr.inspect}"
    end

    def validate_report!(report)
      raise InvalidReport, "report must be an object" unless report.is_a?(Hash)
      raise InvalidReport, "findings must be an array" unless report["findings"].is_a?(Array)
      raise InvalidReport, "summary must be an object" unless report["summary"].is_a?(Hash)
    end

    def capture!(*argv, label:, chdir: @directory)
      stdout, stderr, status = Open3.capture3(environment, *argv, chdir:)
      return [stdout, stderr, status] if status.success?

      raise "#{label} failed with status #{status.exitstatus}\nstdout: #{stdout.inspect}\nstderr: #{stderr.inspect}"
    end

    def git!(*arguments, label:, chdir: @directory)
      result = capture!("git", *GIT_CONFIG, "-c", "core.hooksPath=#{git_hooks_path(chdir)}", *arguments, chdir:, label:)
      FileUtils.mkdir_p(git_hooks_path(chdir))
      result
    end

    def git_hooks_path(directory)
      File.join(directory, ".git", DISABLED_HOOKS_DIRECTORY)
    end

    def environment
      cleared_environment.merge(GIT_ENVIRONMENT, runtime_environment)
    end

    def runtime_environment
      {
        "BUNDLE_GEMFILE" => File.join(@directory, "Gemfile"),
        "BUNDLER_AUDIT_DB" => @advisory_database,
        "PATH" => executable_path,
        "RACK_ENV" => "test",
        "RAILS_ENV" => "test",
        "RUBYOPT" => nil,
        "XDG_CACHE_HOME" => @cache_directory
      }
    end

    def cleared_environment
      keys = ENV.each_key.grep(/\A(?:BUNDLE_|BUNDLER_|GIT_|RACK_|RAILS_|RUBOCOP(?:_|$))/)
      (keys | APPLICATION_ENVIRONMENT_KEYS).to_h { [_1, nil] }
    end

    def executable_path
      [File.dirname(RbConfig.ruby), Gem.bindir, ENV.fetch("PATH")].uniq.join(File::PATH_SEPARATOR)
    end

    def fixtures_root = File.join(@repository_root, "test/fixtures/acceptance")

    def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
