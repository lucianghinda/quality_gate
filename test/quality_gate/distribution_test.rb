# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require "rubygems/package"
require "tmpdir"
require "yaml"
require "zlib"

module QualityGate
  QUALITY_GATE_COMMANDS = [
    "bundle exec quality_gate fast",
    "bundle exec quality_gate verify",
    "bundle exec quality_gate audit"
  ].freeze
  RUNTIME_DEPENDENCY_REQUIREMENTS = {
    "bullet" => "~> 8.2.0",
    "reek" => "~> 6.5",
    "rubocop" => "~> 1.90",
    "rubocop-rails" => "~> 2.37",
    "rubocop-performance" => "~> 1.27",
    "rubocop-minitest" => "~> 0.40",
    "brakeman" => "~> 8.0",
    "bundler-audit" => "~> 0.9.3",
    "simplecov" => "~> 1.1.1",
    "undercover" => "~> 0.8.5",
    "strong_migrations" => "~> 2.5.2"
  }.freeze
  SHIPPED_ARTIFACTS = %w[
    README.md
    llm.txt
    config/37signals.yml
    config/cops.yml
    config/reek.yml
    config/rubocop.yml
    config/ruby.yml
    docs/codex.md
    docs/dogfood-log.md
    docs/releasing.md
    docs/incidents.md
    lib/generators/quality_gate/install/install_generator.rb
    lib/generators/quality_gate/install/templates/agents_section.md.tt
    lib/generators/quality_gate/install/templates/bullet.rb.tt
    lib/generators/quality_gate/install/templates/claude_settings.json.tt
    lib/generators/quality_gate/install/templates/hook_log_filesystem.rb.tt
    lib/generators/quality_gate/install/templates/quality_gate.yml.tt
    lib/generators/quality_gate/install/templates/quality_gate_fast.rb.tt
    lib/generators/quality_gate/install/templates/quality_gate_verify_stop.rb.tt
    lib/generators/quality_gate/install/templates/rubocop.yml.tt
    lib/generators/quality_gate/install/templates/ruby_agents_section.md.tt
    lib/generators/quality_gate/install/templates/ruby_quality_gate.yml.tt
    lib/generators/quality_gate/install/templates/ruby_rubocop.yml.tt
    lib/generators/quality_gate/install/templates/ruby_simplecov.rb.tt
    lib/generators/quality_gate/install/templates/simplecov.rb.tt
    lib/generators/quality_gate/install/templates/strong_migrations.rb.tt
    lib/quality_gate/hook_log.rb
    lib/quality_gate/init_command.rb
    lib/quality_gate/installation.rb
    lib/quality_gate/installer.rb
    lib/quality_gate/ruby_profile.rb
    lib/quality_gate/railtie.rb
    lib/quality_gate/rubocop.rb
    lib/rubocop/cop/quality_gate/association_default_block_value.rb
    lib/rubocop/cop/quality_gate/prefer_after_save_commit.rb
    lib/rubocop/cop/quality_gate/private_only_concern.rb
    lib/rubocop/cop/quality_gate/broadcast_in_controller.rb
    lib/rubocop/cop/quality_gate/controller_instance_variables.rb
    lib/quality_gate/adapters/reek.rb
    lib/quality_gate/adapters/rubocop.rb
    lib/quality_gate/adapters/brakeman.rb
    lib/quality_gate/adapters/bundler_audit.rb
    lib/quality_gate/adapters/simplecov.rb
    lib/quality_gate/adapters/test_suite.rb
    lib/quality_gate/adapters/undercover.rb
    lib/quality_gate/reporters/text.rb
    lib/quality_gate/reporters/json.rb
    sig/quality_gate.rbs
  ].freeze

  class ExecutableTest < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)
    EXECUTABLE = File.join(ROOT, "exe", "quality_gate")

    def test_version_prints_the_version_and_exits_cleanly
      stdout, stderr, status = run_executable("version")

      assert_equal "#{VERSION}\n", stdout
      assert_empty stderr
      assert_predicate status, :success?
    end

    def test_verify_command_prints_a_clean_summary_with_an_empty_adapter_list
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".quality_gate.yml"), "adapters:\n  verify: []\n")
        stdout, stderr, status = run_executable("verify", chdir: dir)

        assert_equal "0 findings, 0 tool failures\n", stdout
        assert_empty stderr
        assert_equal ExitCode::CLEAN, status.exitstatus
      end
    end

    def test_is_marked_executable
      assert File.executable?(EXECUTABLE), "expected exe/quality_gate to have an executable mode"
    end

    private

    def run_executable(command, chdir: ROOT)
      environment = { "RUBYLIB" => File.join(ROOT, "lib") }

      Open3.capture3(environment, RbConfig.ruby, EXECUTABLE, command, chdir:)
    end
  end

  class GemspecTest < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)
    GEMSPEC = File.join(ROOT, "quality_gate.gemspec")
    DOGFOOD_CONFIG = File.join(ROOT, ".quality_gate.yml")
    RATCHET_CONFIG = File.join(ROOT, ".rubocop_todo.yml")
    REPOSITORY_URL = "https://github.com/lucianghinda/quality_gate"

    def setup
      @spec = Gem::Specification.load(GEMSPEC)
    end

    def test_has_release_ready_descriptive_metadata
      refute_match(/TODO|example\.com|public repo URL/, @spec.summary)
      refute_match(/TODO|example\.com|public repo URL/, @spec.description)
      assert_includes @spec.summary.downcase, "quality"
      assert_includes @spec.description, "CLI"
    end

    def test_uses_the_intended_project_urls
      assert_equal REPOSITORY_URL, @spec.homepage
      assert_equal REPOSITORY_URL, @spec.metadata.fetch("homepage_uri")
      assert_equal REPOSITORY_URL, @spec.metadata.fetch("source_code_uri")
      assert_equal "#{REPOSITORY_URL}/blob/main/CHANGELOG.md", @spec.metadata.fetch("changelog_uri")
    end

    def test_requires_mfa_for_rubygems_publishing
      assert_equal "https://rubygems.org", @spec.metadata.fetch("allowed_push_host")
      assert_equal "true", @spec.metadata.fetch("rubygems_mfa_required")
    end

    def test_packages_the_command
      assert_includes @spec.executables, "quality_gate"
    end

    def test_packages_reporters_and_readme_contract
      SHIPPED_ARTIFACTS.each { assert_includes @spec.files, _1 }
    end

    def test_declares_the_supported_runtime_dependencies
      assert_equal RUNTIME_DEPENDENCY_REQUIREMENTS, runtime_dependency_requirements
    end

    def test_built_gem_packages_all_shipped_adapter_artifacts
      built_files = build_gem_file_entries
      data_entries = packaged_data_entries(built_files.fetch("data.tar.gz"))

      assert_includes built_files, "data.tar.gz"
      SHIPPED_ARTIFACTS.each { assert_includes data_entries, _1 }
      refute_includes data_entries, ".quality_gate.yml"
      refute(data_entries.any? { _1.start_with?("test/") })
    end

    def test_repository_dogfood_config_is_explicitly_excluded_from_the_gemspec
      assert_path_exists DOGFOOD_CONFIG
      refute_includes @spec.files, ".quality_gate.yml"
    end

    def test_repository_lint_ratchet_is_not_packaged
      assert_path_exists RATCHET_CONFIG
      refute_includes @spec.files, ".rubocop_todo.yml"
      refute_includes @spec.files, ".rubocop.yml"
    end

    def test_private_development_material_is_not_packaged
      private_prefixes = %w[docs/plans/ docs/specs/ docs/solutions/ docs/feedback/ bin/ .claude/ log/]

      refute(@spec.files.any? { |path| path.start_with?(*private_prefixes) })
      assert_equal ["quality_gate"], @spec.executables
      assert_equal "exe", @spec.bindir
    end

    def test_test_fixtures_are_excluded_from_the_gemspec
      refute(@spec.files.any? { _1.start_with?("test/fixtures/") })
    end

    private

    def runtime_dependency_requirements
      @spec.runtime_dependencies.to_h do |dependency|
        [dependency.name, dependency.requirement.to_s]
      end
    end

    def build_gem_file_entries
      Dir.mktmpdir do |dir|
        gem_path = File.join(dir, "quality_gate.gem")
        _stdout, stderr, status = Open3.capture3(
          RbConfig.ruby,
          "-S",
          "gem",
          "build",
          GEMSPEC,
          "--output",
          gem_path,
          chdir: ROOT
        )
        assert_predicate status, :success?, "expected gem build to succeed, stderr: #{stderr}"

        File.open(gem_path, "rb") do |file|
          return tar_entries(file)
        end
      end
    end

    def packaged_data_entries(data_tar_gz)
      Zlib::GzipReader.wrap(StringIO.new(data_tar_gz)) do |gzip|
        tar_entries(gzip).keys
      end
    end

    def tar_entries(io)
      Gem::Package::TarReader.new(io).each_with_object({}) do |entry, entries|
        next unless entry.file?

        entries[entry.full_name] = entry.read
      end
    end
  end

  class ProjectDocumentationTest < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)
    README = File.join(ROOT, "README.md")
    CODEX = File.join(ROOT, "docs", "codex.md")
    SIGNATURE = File.join(ROOT, "sig", "quality_gate.rbs")
    WORKFLOW = File.join(ROOT, ".github", "workflows", "main.yml")

    def test_ci_covers_the_supported_ruby_floor_and_current_line
      workflow = YAML.safe_load_file(WORKFLOW)
      versions = workflow.fetch("jobs").fetch("build").fetch("strategy").fetch("matrix").fetch("ruby")

      assert_includes versions, "3.2"
      assert_includes versions, "4.0.1"
    end

    # rubocop:disable Metrics/AbcSize
    def test_ci_uses_full_history_and_dogfoods_verify_after_the_default_task
      workflow = YAML.safe_load_file(WORKFLOW)
      steps = workflow.fetch("jobs").fetch("build").fetch("steps")
      checkout = steps.find { _1["uses"] == "actions/checkout@v6" }

      assert_equal 0, checkout.dig("with", "fetch-depth")
      assert_equal false, checkout.dig("with", "persist-credentials")

      default_task_index = steps.index { _1["name"] == "Run the default task" && _1["run"] == "bundle exec rake" }
      verify_index = steps.index do
        _1["name"] == "Run Quality Gate verify" &&
        _1["run"].include?('Open3.capture2("bundle", "exec", "quality_gate", "verify", "--format", "json")')
      end

      refute_nil default_task_index
      refute_nil verify_index
      assert_operator verify_index, :>, default_task_index
      assert_equal "ruby {0}", steps.fetch(verify_index).fetch("shell")
    end
    # rubocop:enable Metrics/AbcSize

    def test_readme_contains_no_generator_placeholders
      readme = File.read(README)

      refute_match(/TODO|UPDATE_WITH_YOUR_GEM_NAME|\[USERNAME\]|Welcome to your new gem/, readme)
    end

    def test_rbs_describes_both_verify_adapters_and_undercover_constants
      signature = File.read(SIGNATURE)

      assert_includes signature, "class TestSuite < Adapter"
      assert_includes signature, "TAIL_LINES: Integer"
      assert_includes signature, "def env:"
      assert_includes signature, "class Undercover < Adapter"
      assert_includes signature, "COVERAGE_PATH: String"
      assert_includes signature, "SKIP_RULE: String"
      assert_includes signature, "def compare_point: () -> String?"
    end

    def test_rbs_describes_the_simplecov_adapter
      signature = File.read(SIGNATURE)

      assert_includes signature, "class SimpleCov < Adapter"
      assert_includes signature, "COVERAGE_PATH: String"
      assert_includes signature, "def call: () -> Array[Finding]"
      assert_includes signature, "def name: () -> String"
    end

    def test_rbs_describes_the_unit_six_railtie_and_install_generator_surface
      signature = File.read(SIGNATURE)

      assert_includes signature, "class Railtie"
      assert_includes signature, "class InstallGenerator"
      assert_includes signature, "FILES: Array[String]"
      assert_includes signature, "MARKER_START: String"
      assert_includes signature, "MARKER_END: String"
      install_methods = %w[
        create_settings_file
        create_rules_file
        create_initializers
        inject_coverage
        create_agent_integration
        print_summary
      ]
      install_methods.each do |method|
        assert_includes signature, "def #{method}: () -> void"
      end
    end

    def test_docs_codex_documents_the_manual_codex_path
      codex = File.read(CODEX)

      QUALITY_GATE_COMMANDS.each { assert_includes codex, _1 }
      assert_match(/Codex/i, codex)
      assert_match(/manual/i, codex)
      assert_match(/exit 0.*clean/i, codex)
      assert_match(/exit 1.*finding/i, codex)
      assert_match(/exit 2.*tool failure/i, codex)
      assert_match(/fix findings before you continue/i, codex)
      assert_match(%r{log/quality_gate_hooks\.jsonl}i, codex)
      assert_match(%r{bin/rails generate quality_gate:install}i, codex)
    end

    def test_rbs_describes_the_hook_log_reader_surface
      signature = File.read(SIGNATURE)

      assert_includes signature, "class HookLog"
      assert_includes signature, "DEFAULT_PATH: String"
      assert_includes signature, "attr_reader path: String"
      assert_includes signature, "def initialize: (path: String) -> void"
      assert_includes signature, "def recent: (?limit: Integer) -> Array[Hash[String, untyped]]"
      assert_includes signature, "def unavailable_count: (?limit: Integer) -> Integer"
      assert_includes signature, "def warning_line: (?limit: Integer) -> String?"
    end

    def test_readme_describes_clean_gate_execution
      readme = File.read(README)

      %w[fast verify audit].each { |command| assert_includes readme, command }
      assert_includes readme, "0 findings, 0 tool failures"
      assert_match(/clean summary/i, readme)
    end

    def test_readme_documents_the_command_and_configuration_contract
      readme = File.read(README)

      assert_includes readme, "quality_gate version"
      assert_includes readme, "--files"
      assert_includes readme, "--format"
      assert_includes readme, ".quality_gate.yml"
      assert_includes readme, "adapters:"
      assert_includes readme, "timeouts:"
      assert_includes readme, "commands:"
      assert_includes readme, "compare_point"
      assert_includes readme, "rubocop_config"
      assert_match(/safe_load|safe YAML/i, readme)
      assert_match(/unknown.*warning/i, readme)
      assert_match(/0.*1.*2/m, readme)
    end

    def test_readme_publishes_the_json_schema_contract
      readme = File.read(README)

      assert_includes readme, "\"findings\""
      assert_includes readme, "\"summary\""
      assert_includes readme, "\"tool_failures\""
      assert_includes readme, "\"failed_tools\""
      assert_includes readme, "\"severity\""
    end

    def test_readme_describes_the_shipped_adapter_defaults
      readme = File.read(README)

      assert_match(/fast.*RuboCop/i, readme)
      assert_match(/verify.*test.*Undercover/i, readme)
      assert_includes readme, "test suite"
      assert_operator readme.index("test suite"), :<, readme.index("Undercover")
      assert_match(/audit.*Brakeman.*bundler.?audit/i, readme)
      assert_operator readme.index("Brakeman"), :<, readme.index("bundler-audit")
      assert_match(/default adapters/i, readme)
      assert_match(/120/i, readme)
      assert_match(/10/i, readme)
    end

    # rubocop:disable Metrics/AbcSize
    def test_readme_documents_the_simplecov_opt_in_without_changing_host_defaults
      readme = File.read(README)
      yaml_blocks = readme.scan(/```yaml\n(.*?)```/m).flatten.map { YAML.safe_load(_1) }
      opt_in = yaml_blocks.find { _1.dig("adapters", "verify")&.include?("simplecov") }

      assert_includes readme, "`coverage.minimum_line`"
      assert_includes readme, "`coverage.minimum_branch`"
      assert_match(/add `simplecov` to `adapters\.verify`/i, readme)
      refute_nil opt_in, "README must include a copyable SimpleCov opt-in YAML example"
      assert_equal %w[test_suite undercover simplecov], opt_in.dig("adapters", "verify")
      assert(opt_in.fetch("coverage").values.any? { _1.is_a?(Numeric) }, "opt-in example must set a real budget")

      assert_match(/registry-known.*not.*default/im, readme)
      assert_match(/default verify adapters.*test suite.*Undercover/im, readme)
      assert_match(/host-facing coverage template.*Undercover-only/im, readme)
      assert_match(/HTML.*self-dogfood.*not.*generated hosts/im, readme)
    end
    # rubocop:enable Metrics/AbcSize

    def test_readme_documents_rubocop_config_selection_and_supported_ranges
      readme = File.read(README)

      assert_match(%r{shipped config|config/rubocop\.yml}i, readme)
      assert_match(/host.*\.rubocop\.yml|host.*RuboCop config/i, readme)
      assert_match(/explicit.*rubocop_config/i, readme)
      assert_match(/rubocop ~> 1\.90/i, readme)
      assert_match(/rubocop-rails ~> 2\.37/i, readme)
      assert_match(/rubocop-performance ~> 1\.27/i, readme)
      assert_match(/rubocop-minitest ~> 0\.40/i, readme)
      assert_match(/conflict/i, readme)
      assert_match(/severity/i, readme)
      assert_match(/missing/i, readme)
    end

    def test_readme_documents_security_adapter_scope_ranges_and_fallback
      readme = File.read(README)

      assert_match(/brakeman ~> 8\.0/i, readme)
      assert_match(/bundler-audit ~> 0\.9\.3/i, readme)
      assert_match(/Brakeman.*whole application/i, readme)
      assert_match(/bundler-audit.*Gemfile\.lock/i, readme)
      assert_match(/ignore.*--files|--files.*ignored/i, readme)
      assert_match(/inherit.*120|120.*inherit/i, readme)
      assert_match(/update.*first/i, readme)
      assert_match(/cached.*database/i, readme)
      assert_match(/standard error|stderr/i, readme)
      assert_match(/no usable.*database.*tool failure|tool failure.*no usable.*database/i, readme)
      assert_match(/never.*clean/i, readme)
    end

    def test_readme_documents_the_coverage_template_contract
      readme = File.read(README)

      assert_match(/simplecov ~> 1\.1\.1/i, readme)
      assert_match(/undercover ~> 0\.8\.5/i, readme)
      assert_match(/Rugged/i, readme)
      assert_match(/CMake|libgit2/i, readme)
      assert_match(/COVERAGE.*1/i, readme)
      assert_match(%r{coverage/coverage\.json}i, readme)
      assert_match(/branch coverage/i, readme)
      assert_match(/filter.*test/i, readme)
      refute_match(/Unit 6.*not implemented|not implemented.*Unit 6/i, readme)
    end

    def test_readme_documents_safe_installation_and_undo # rubocop:disable Metrics/AbcSize
      readme = File.read(README)

      assert_includes readme, "bin/rails generate quality_gate:install"
      assert_includes readme, ".quality_gate.yml"
      assert_includes readme, ".rubocop.yml"
      assert_includes readme, "config/initializers/bullet.rb"
      assert_includes readme, "config/initializers/strong_migrations.rb"
      assert_includes readme, "test/test_helper.rb"
      assert_match(/idempotent/i, readme)
      assert_match(/conflict.*manual|manual.*conflict/i, readme)
      assert_includes readme, "--skip-initializers"
      assert_includes readme, "--skip-coverage"
      assert_includes readme, "--pretend"
      assert_match(%r{missing.*test/test_helper\.rb|test/test_helper\.rb.*missing}i, readme)
      assert_includes readme, "# Generated by Quality Gate."
      assert_match(/provenance.*baseline|baseline.*provenance/i, readme)
      assert_match(/newer migrations.*unchanged|unchanged.*newer migrations/i, readme)
      assert_match(/BOM.*shebang.*blank lines.*ordinary comments.*directives.*=begin.*executable host code/im, readme)
      assert_includes readme, "bundle exec quality_gate fast"
      assert_match(/undo|uninstall/i, readme)
      assert_includes readme, "bin/rails destroy quality_gate:install"
      assert_match(/destroy.*read-only|read-only.*destroy/i, readme)
      assert_match(/automatic removal.*not supported|not support.*automatic removal/i, readme)
      assert_includes readme, "# quality_gate coverage — start"
      assert_includes readme, "# quality_gate coverage — end"
      assert_includes readme, ".claude/hooks/quality_gate_fast.rb"
      assert_includes readme, ".claude/settings.json"
      assert_includes readme, "CLAUDE.md"
      assert_includes readme, "AGENTS.md"
      assert_match(%r{log/quality_gate_hooks\.jsonl}i, readme)
      assert_match(/reinstall|install again/i, readme)
      assert_match(%r{docs/codex\.md}i, readme)
    end

    def test_readme_distinguishes_owned_agent_files_from_marker_owned_context_blocks
      readme = File.read(README)

      assert_match(/wholly owned files.*existing file has different content.*never overwrites or merges/im, readme)
      assert_match(/marker-owned Quality Gate contract section.*CLAUDE\.md/im, readme)
      assert_match(/marker-owned Quality Gate contract section.*AGENTS\.md/im, readme)
      assert_match(/stale.*block.*replaced|replaced.*stale.*block/im, readme)
      assert_match(/surrounding bytes preserved|preserve.*surrounding bytes/im, readme)
    end
  end
end
