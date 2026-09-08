# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

module QualityGate
  class RailsIntegrationTest < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)
    GENERATOR_TASKS = %w[
      create_settings_file
      create_rules_file
      create_initializers
      inject_coverage
      create_agent_integration
      print_summary
    ].freeze
    EXPECTED_INSTRUMENTOR_PRESENCE = {
      "before_initialization" => { "bullet" => false, "strong_migrations" => false },
      "after_initialization" => { "bullet" => true, "strong_migrations" => true }
    }.freeze

    def test_plain_ruby_require_does_not_load_rails_or_the_generator
      script = <<~'RUBY'
        require "quality_gate"
        require "quality_gate/railtie"
        require "generators/quality_gate/install/install_generator"

        abort "Rails was loaded" if defined?(Rails)
        abort "railtie was defined" if defined?(QualityGate::Railtie)
        abort "generator was defined" if defined?(QualityGate::InstallGenerator)
      RUBY

      _stdout, stderr, status = run_ruby(script, isolated: true)

      assert_predicate status, :success?, stderr
    end

    def test_railties_loads_and_registers_the_install_generator_shell
      stdout, stderr, status = run_ruby(rails_probe)
      assert_predicate status, :success?, stderr

      result = JSON.parse(stdout)
      assert_rails_types(result)
      assert_railtie_hooks(result)
      assert_generator_registration(result)
      assert_generator_options(result)
    end

    def test_generated_host_initializers_boot_bullet_and_strong_migrations
      Dir.mktmpdir("quality-gate-generated-host") do |host|
        stdout, stderr, status = run_ruby(generated_host_boot_probe(host))

        assert_predicate status, :success?, stderr
        assert_equal EXPECTED_INSTRUMENTOR_PRESENCE, JSON.parse(stdout.lines.last)
      end
    end

    private

    def assert_rails_types(result)
      assert result.fetch("railtie")
      assert result.fetch("generator")
    end

    def assert_generator_registration(result)
      assert result.fetch("discoverable")
      assert_equal File.join(ROOT, "lib/generators/quality_gate/install/templates"), result.fetch("source_root")
      assert_equal GENERATOR_TASKS, result.fetch("tasks")
    end

    def assert_railtie_hooks(result)
      assert_operator result.fetch("rake_task_callbacks"), :>=, 1
    end

    def assert_generator_options(result)
      assert_equal({ "type" => "boolean", "default" => false }, result.dig("options", "skip_initializers"))
      assert_equal({ "type" => "boolean", "default" => false }, result.dig("options", "skip_coverage"))
      assert_equal({ "type" => "boolean", "default" => false }, result.dig("options", "agents"))
    end

    def run_ruby(script, isolated: false)
      environment = isolated ? { "BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil } : {}

      Open3.capture3(environment, RbConfig.ruby, "-I", File.join(ROOT, "lib"), "-e", script)
    end

    def rails_probe
      <<~'RUBY'
        require "json"
        require "rails"
        require "quality_gate"

        application = Class.new(Rails::Application).instance
        application.load_generators
        generator = QualityGate::InstallGenerator
        options = %i[skip_initializers skip_coverage agents].to_h do |name|
          option = generator.class_options.fetch(name)
          [name, { type: option.type, default: option.default }]
        end

        puts JSON.generate(
          railtie: QualityGate::Railtie < Rails::Railtie,
          rake_task_callbacks: QualityGate::Railtie.rake_tasks.length,
          generator: generator < Rails::Generators::Base,
          discoverable: Rails::Generators.find_by_namespace("quality_gate:install") == generator,
          source_root: generator.source_root,
          tasks: generator.tasks.keys,
          options: options
        )
      RUBY
    end

    def generated_host_boot_probe(host)
      <<~RUBY
        ENV["RAILS_ENV"] = "production"

        require "json"
        require "rails"
        require "rails/generators"
        require "quality_gate"
        require "generators/quality_gate/install/install_generator"

        root = #{host.dump}
        QualityGate::InstallGenerator.start([], destination_root: root)
        instrumentors = -> {
          {
            bullet: Object.const_defined?(:Bullet),
            strong_migrations: Object.const_defined?(:StrongMigrations)
          }
        }
        instrumentor_presence = {}

        Dir.chdir(root) do
          application_class = Class.new(Rails::Application)
          application_class.config.root = root
          application_class.config.eager_load = false
          application_class.config.secret_key_base = "quality-gate-generated-host"
          instrumentor_presence[:before_initialization] = instrumentors.call
          application_class.initialize!
          instrumentor_presence[:after_initialization] = instrumentors.call
        end

        puts JSON.generate(instrumentor_presence)
      RUBY
    end
  end
end
