# frozen_string_literal: true

require "shellwords"
require "yaml"

module AgentRepairAcceptance
  class Project
    attr_reader :root, :manifest

    def initialize(root, artifact:, client:, scenario:)
      @root = Pathname(root).expand_path
      @artifact = Pathname(artifact.to_s).expand_path
      @client = client
      @scenario = scenario
    end

    def prepare
      ensure_destination_available!

      prepare_valid_trial
    rescue StandardError
      cleanup_failed_trial
      raise
    end

    def evidence_root
      AgentRepairAcceptance.evidence_root(root)
    end

    def prepare_valid_trial
      validate_inputs!
      baseline = prepare_baseline
      write_manifest(baseline)
    end

    def prepare_baseline
      create_fixture
      install_dependencies
      install_hooks
      initialize_git
      baseline = capture_baseline
      start_trial_branch
      baseline
    end

    def write_manifest(baseline)
      @manifest = build_manifest(baseline)
      FileUtils.mkdir_p(evidence_root)
      File.write(evidence_root.join("manifest.json"), "#{JSON.pretty_generate(manifest)}\n")
      manifest
    end

    def create_fixture
      FileUtils.mkdir_p(root.dirname)
      @created = true
      FileUtils.cp_r(FIXTURE, root)
      seed_source
    end

    def install_dependencies
      write_gemfile
      install_package
      lock_bundle
    end

    def capture_baseline
      { "fast" => gate("fast"), "verify" => gate("verify") }.tap { ensure_clean_baseline!(_1) }
    end

    def write_json(relative_path, value)
      File.write(root.join(relative_path), "#{JSON.pretty_generate(value)}\n")
    end

    private

    def ensure_destination_available!
      return unless root.exist? || evidence_root.exist?

      raise Error, "destination or evidence directory already exists: #{root}"
    end

    def cleanup_failed_trial
      return unless @created && root.exist? && !evidence_root.join("manifest.json").exist?

      FileUtils.rm_rf(root)
      FileUtils.rm_rf(evidence_root)
    end

    def validate_inputs!
      raise Error, "package artifact is not a file: #{@artifact}" unless @artifact.file?
      raise Error, "client must be claude or codex" unless %w[claude codex].include?(@client)
      raise Error, "scenario must be fast or verify" unless SCENARIOS.include?(@scenario)
    end

    def package_identity
      spec = Gem::Package.new(@artifact.to_s).spec
      { "version" => spec.version.to_s, "sha256" => Digest::SHA256.file(@artifact).hexdigest }
    end

    def write_gemfile
      File.write(root.join("Gemfile"), <<~GEMFILE)
        # frozen_string_literal: true

        source 'https://rubygems.org'
        gem 'quality_gate', '=#{package_identity.fetch("version")}'
        gem 'railties', '~> 8.0'
      GEMFILE
    end

    def isolated_env
      home = root.join(".trial-gems")
      FileUtils.mkdir_p(home)
      cleared = ENV.keys.grep(/\A(?:BUNDLE_|BUNDLER_|GIT_|RUBYOPT\z|RUBYLIB\z)/).to_h { [_1, nil] }
      cleared.merge(
        "GEM_HOME" => home.to_s,
        "GEM_PATH" => [home, *Gem.path].join(File::PATH_SEPARATOR),
        "GIT_CONFIG_GLOBAL" => File::NULL,
        "GIT_CONFIG_NOSYSTEM" => "1"
      )
    end

    def install_package
      run!("gem", "install", "--local", "--ignore-dependencies", "--install-dir", root.join(".trial-gems").to_s,
           @artifact.to_s, env: isolated_env)
      @package_path = resolve_installed_package
    end

    def resolve_installed_package
      loaded_path = loaded_package_path
      gem_home = root.join(".trial-gems/gems")
      package_path = gem_home.join(Gem::Package.new(@artifact.to_s).spec.full_name)
      validate_package_path!(loaded_path, gem_home)
      @package_files = package_files(package_path.to_s)
      loaded_path
    end

    def loaded_package_path
      code = "require 'quality_gate'; puts Gem.loaded_specs.fetch('quality_gate').full_gem_path"
      output, = run!("bundle", "exec", RbConfig.ruby, "-e", code, env: bundle_env)
      File.expand_path(output.strip)
    end

    def validate_package_path!(path, gem_home)
      installed_path = File.realpath(path)
      installed_gem_home = File.realpath(gem_home)
      return if installed_path.start_with?(installed_gem_home + File::SEPARATOR)

      raise Error, "bundle resolved quality_gate outside the isolated installed package: #{path}"
    rescue Errno::ENOENT
      raise Error, "bundle resolved quality_gate outside the isolated installed package: #{path}"
    end

    def package_files(path)
      Dir.glob("**/*", base: path).select { File.file?(File.join(path, _1)) }
         .map { File.join(path.delete_prefix("#{root}/"), _1) }
    end

    def lock_bundle
      run!("bundle", "lock", "--local", env: bundle_env)
    end

    def bundle_env
      isolated_env.merge("BUNDLE_GEMFILE" => root.join("Gemfile").to_s)
    end

    def run!(*argv, env: {}, chdir: root)
      env = isolated_env.merge(env)
      argv = git_command(argv) if argv.first == "git"
      result = ProcessCapture.new(argv:, chdir: chdir.to_s, env:, timeout: 600).run
      validate_process!(result, argv.first)
      [result.stdout, result.stderr, result.status]
    end

    def validate_process!(result, name)
      return if result.status.zero?

      raise Error, "#{name} failed (#{result.status}): #{result.stderr.lines.last(12).join.strip}"
    end

    def git_command(argv)
      FileUtils.mkdir_p(root.join(".trial-git-hooks"))
      ["git", "-c", "commit.gpgSign=false", "-c", "tag.gpgSign=false",
       "-c", "core.hooksPath=.trial-git-hooks", *argv.drop(1)]
    end

    def install_hooks
      run!("bundle", "exec", "bin/rails", *generator_arguments, env: bundle_env)
      configure_quality_gate
      install_recorder
      wrap_enabled_hooks
    end

    def install_recorder
      recorder_source = ROOT.join("test/support/agent_repair_acceptance/hook_capture.rb")
      raise Error, "hook recorder is unavailable" unless recorder_source.file?

      FileUtils.mkdir_p(evidence_root)
      FileUtils.cp(recorder_source, evidence_root.join("agent_repair_recorder.rb"))
      @baseline_tests = Dir.glob("test/**/*.rb", base: root).select { File.file?(root.join(_1)) }
    end

    def wrap_enabled_hooks
      return wrap_hooks(".claude/settings.json", "claude") if @client == "claude"

      wrap_hooks(".codex/hooks.json", "codex")
    end

    def generator_arguments
      ["generate", "quality_gate:install", "--skip-initializers",
       @client == "claude" ? "--agents" : "--codex"]
    end

    def wrap_hooks(relative_path, client)
      path = root.join(relative_path)
      settings = JSON.parse(File.read(path))
      settings.fetch("hooks").each do |event, matchers|
        matchers.each do |matcher|
          matcher.fetch("hooks").each do |hook|
            wrap_hook!(hook, client, event)
          end
        end
      end
      write_json(relative_path, settings)
    end

    def wrap_hook!(hook, client, event)
      if client == "claude"
        wrap_claude_hook!(hook, event)
      else
        hook["command"] = recorder_command(client, event, Shellwords.split(hook.fetch("command")))
      end
    end

    def wrap_claude_hook!(hook, event)
      original = hook.fetch("command").gsub("${CLAUDE_PROJECT_DIR}", root.to_s)
      original_argv = [original, *Array(hook["args"])]
      hook["command"] = RbConfig.ruby
      hook["args"] = recorder_argv("claude", event, original_argv)
    end

    def recorder_command(client, event, original_argv)
      Shellwords.join([RbConfig.ruby, *recorder_argv(client, event, original_argv)])
    end

    def recorder_argv(client, event, original_argv)
      [evidence_root.join("agent_repair_recorder.rb").to_s, client, event, root.to_s,
       evidence_root.join("hooks.jsonl").to_s, "--", *original_argv]
    end

    def seed_source
      seed = @scenario == "fast" ? FAST_SEED : VERIFY_SEED
      @seed_sha256 = Digest::SHA256.hexdigest(seed)
    end

    def configure_quality_gate
      settings = {
        "format" => "json",
        "adapters" => { "fast" => %w[rubocop], "verify" => %w[test_suite undercover] },
        "commands" => { "verify" => { "test_suite" => %w[bin/rails test] } },
        "compare_point" => "main"
      }
      File.write(root.join(".quality_gate.yml"), YAML.dump(settings))
    end

    def initialize_git
      write_ignore
      run!("git", "init", "-b", "main")
      run!("git", "config", "core.hooksPath", ".trial-git-hooks")
      run!("git", "add", "-A")
      run!("git", "-c", "user.name=Acceptance", "-c", "user.email=acceptance@example.invalid", "commit", "-m",
           "baseline")
      @head = run!("git", "rev-parse", "HEAD").first.strip
      @local_main = @head
    end

    def start_trial_branch
      run!("git", "switch", "-c", "agent-repair-trial")
    end

    def gate(name)
      result = ProcessCapture.new(
        argv: ["bundle", "exec", "quality_gate", name],
        chdir: root.to_s, env: bundle_env, timeout: 600
      ).run
      { "status" => result.status, "report" => JSON.parse(result.stdout) }
    end

    def ensure_clean_baseline!(baseline)
      baseline.each do |name, result|
        unless clean_baseline?(name, result)
          raise Error, "#{name} baseline was not clean with expected checks: #{JSON.generate(result)}"
        end
      end
    end

    def clean_baseline?(name, result)
      report = result.fetch("report")
      summary = report["summary"] || {}
      checks = report["checks"]
      expected = name == "fast" ? %w[rubocop] : %w[test_suite undercover]
      result.fetch("status").zero? && clean_summary?(summary) && clean_checks?(checks, expected)
    end

    def clean_summary?(summary)
      summary.fetch("findings", -1).zero? && summary.fetch("tool_failures", -1).zero? &&
        summary.fetch("failed_tools") == []
    end

    def clean_checks?(checks, expected)
      checks.is_a?(Array) && checks.map { _1["tool"] } == expected && checks.all? { _1["status"] == "clean" }
    end

    def protected_files
      protected_paths.to_h { |relative| [relative, Digest::SHA256.file(root.join(relative)).hexdigest] }
    end

    def protected_paths
      paths = Dir.glob("config/**/*", base: root).select { File.file?(root.join(_1)) }
      paths.concat(%w[.gitignore Gemfile Gemfile.lock .quality_gate.yml test/test_helper.rb test/calculator_test.rb
                      .claude/settings.json .claude/hooks/quality_gate_fast.rb .claude/hooks/quality_gate_verify_stop.rb
                      .codex/hooks.json .codex/hooks/quality_gate_fast.rb .codex/hooks/quality_gate_verify_stop.rb])
      paths.concat(@baseline_tests || [])
      paths.concat(@package_files || [])
      paths.uniq.select { File.file?(root.join(_1)) }
    end

    def build_manifest(baseline)
      package = package_identity.merge("resolved_path" => @package_path)
      {
        "schema_version" => 1, "client" => @client, "scenario" => @scenario,
        "root" => root.to_s, "prepared_at" => Time.now.utc.iso8601(6),
        "source_path" => SOURCE, "seed_sha256" => @seed_sha256,
        "package" => package, "baseline" => baseline,
        "protected_files" => protected_files, "head" => @head,
        "prompt" => AgentRepairAcceptance.prompt_for(@scenario), "compare_point" => @local_main
      }
    end

    def write_ignore
      File.open(root.join(".gitignore"), "a") do |file|
        file.puts(
          ".trial-gems/", ".trial-git-hooks/", ".bundle/", "log/", "tmp/", "coverage/"
        )
      end
    end
  end
end
