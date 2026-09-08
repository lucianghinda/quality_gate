# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

module QualityGate
  # Materializes and runs the framework-free Ruby acceptance host.
  class RubyAcceptanceProject
    Run = Data.define(:status, :report, :stdout, :stderr)
    InitRun = Data.define(:status, :stdout, :stderr)

    ADVISORY_DATABASE = ".acceptance-advisory-db"
    CACHE_DIRECTORY = ".acceptance-cache"
    BUNDLE_EXECUTABLE = Gem.bin_path("bundler", "bundle")
    APPLICATION_ENVIRONMENT_KEYS = %w[
      DATABASE_URL PIDFILE PORT SECRET_KEY_BASE WEB_CONCURRENCY
    ].freeze
    GIT_CONFIG = [
      "-c", "commit.gpgSign=false",
      "-c", "tag.gpgSign=false"
    ].freeze

    class << self
      def open(repository_root:)
        Dir.mktmpdir("quality-gate-ruby-acceptance") do |directory|
          project = new(directory:, repository_root:)
          project.install
          yield project
        end
      end

      private :new
    end

    attr_reader :root

    def initialize(directory:, repository_root:)
      @root = directory
      @repository_root = File.expand_path(repository_root)
      @advisory_database = File.join(directory, ADVISORY_DATABASE)
      @cache_directory = File.join(directory, CACHE_DIRECTORY)
    end

    def install
      copy_fixture
      write_gemfile
      FileUtils.mkdir_p(@cache_directory)
      bundle_lock
      seed_advisory_database
      initialize_repository
    end

    def init(*arguments)
      stdout, stderr, status = capture(*quality_gate_command("init", *arguments))
      InitRun.new(status: status.exitstatus, stdout:, stderr:)
    end

    def run(command, *arguments)
      stdout, stderr, status = capture(*quality_gate_command(command, *arguments, "--format", "json"))
      Run.new(status: status.exitstatus, report: JSON.parse(stdout), stdout:, stderr:)
    end

    private

    def copy_fixture
      FileUtils.cp_r(File.join(ruby_fixture_root, "."), @root)
    end

    def write_gemfile
      File.write(File.join(@root, "Gemfile"), <<~RUBY)
        # frozen_string_literal: true

        source 'https://rubygems.org'

        gem 'minitest', '~> 5.16'
        gem 'quality_gate', path: #{ruby_string_literal(@repository_root)}
        gem 'rake', '~> 13.0'
      RUBY
    end

    def ruby_string_literal(value)
      "'#{value.gsub(/['\\]/) { "\\#{_1}" }}'"
    end

    def bundle_lock
      capture!(RbConfig.ruby, BUNDLE_EXECUTABLE, "lock", "--local", label: "bundle lock --local")
    end

    def seed_advisory_database
      FileUtils.cp_r(File.join(fixtures_root, "advisory_db"), @advisory_database)
      git!("init", "--initial-branch=main", "--quiet", chdir: @advisory_database, label: "advisory git init")
      git!(
        "remote", "add", "origin", File.join(@advisory_database, "unavailable-origin"),
        chdir: @advisory_database,
        label: "advisory remote add"
      )
    end

    def initialize_repository
      git!("init", "--initial-branch=main", "--quiet", label: "project git init")
      File.write(
        File.join(@root, ".git/info/exclude"),
        "/#{ADVISORY_DATABASE}/\n/#{CACHE_DIRECTORY}/\n/coverage/\n/log/\n"
      )
      git!("add", "--all", label: "project git add")
      git!(
        "-c", "user.name=Quality Gate Ruby Acceptance",
        "-c", "user.email=quality-gate@example.test",
        "commit", "--quiet", "-m", "Generated Ruby acceptance baseline",
        label: "project git commit"
      )
      git!("checkout", "--quiet", "-b", "feature", label: "project feature branch")
    end

    def quality_gate_command(command, *arguments)
      [RbConfig.ruby, BUNDLE_EXECUTABLE, "exec", "quality_gate", command, *arguments]
    end

    def capture(*argv)
      Open3.capture3(environment, *argv, chdir: @root)
    end

    def capture!(*argv, label:, chdir: @root)
      stdout, stderr, status = Open3.capture3(environment, *argv, chdir:)
      return [stdout, stderr, status] if status.success?

      raise "#{label} failed with status #{status.exitstatus}\nstdout: #{stdout.inspect}\nstderr: #{stderr.inspect}"
    end

    def git!(*arguments, label:, chdir: @root)
      capture!("git", *GIT_CONFIG, *arguments, chdir:, label:)
    end

    def environment
      cleared_environment.merge(
        "BUNDLE_GEMFILE" => File.join(@root, "Gemfile"),
        "BUNDLER_AUDIT_DB" => @advisory_database,
        "GIT_CONFIG_GLOBAL" => File::NULL,
        "GIT_CONFIG_NOSYSTEM" => "1",
        "PATH" => executable_path,
        "RAILS_ENV" => nil,
        "RACK_ENV" => nil,
        "RUBYOPT" => nil,
        "XDG_CACHE_HOME" => @cache_directory
      )
    end

    def cleared_environment
      keys = ENV.each_key.grep(/\A(?:BUNDLE_|BUNDLER_|GIT_|RACK_|RAILS_|RUBOCOP(?:_|$))/)
      (keys | APPLICATION_ENVIRONMENT_KEYS).to_h { [_1, nil] }
    end

    def executable_path
      [File.dirname(RbConfig.ruby), Gem.bindir, ENV.fetch("PATH")].uniq.join(File::PATH_SEPARATOR)
    end

    def fixtures_root
      File.join(@repository_root, "test/fixtures/acceptance")
    end

    def ruby_fixture_root
      File.join(fixtures_root, "ruby")
    end
  end
end
