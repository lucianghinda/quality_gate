# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

module QualityGate
  class CodexStopLauncherTest < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)
    TEMPLATE = File.join(ROOT, "lib/generators/quality_gate/install/templates/codex_verify_stop.rb.tt")

    def test_launcher_uses_installed_root_from_nested_and_foreign_directories
      Dir.mktmpdir("codex-stop") do |directory|
        root = build_project(directory)
        installed_root = File.realpath(root)
        [File.join(root, "nested/dir"), directory].each do |cwd|
          FileUtils.mkdir_p(cwd)
          assert_equal({}, run_json(root, cwd, JSON.generate(stop_input)))
          assert_equal "#{installed_root}\n#{installed_root}", File.read(File.join(root, "invoked-from.txt"))
        end
      end
    end

    def test_malformed_input_and_missing_bundle_dependency_emit_one_visible_json_message
      Dir.mktmpdir("codex-stop") do |directory|
        root = build_project(directory)
        assert_unavailable(invoke(root, directory, "{"))

        FileUtils.rm(File.join(root, "Gemfile"))
        assert_unavailable(invoke(root, directory, JSON.generate(stop_input)))
      end
    end

    private

    def run_json(root, cwd, input)
      stdout, stderr, status = invoke(root, cwd, input)
      assert status.success?, stderr
      assert_empty stderr
      JSON.parse(stdout)
    end

    def assert_unavailable(result)
      stdout, stderr, status = result
      assert status.success?, stderr
      assert_match(/unavailable/i, stdout)
      assert_equal 1, stdout.lines.length, stdout.inspect
      assert_empty stderr
    end

    def build_project(directory)
      root = File.join(directory, "project")
      hooks = File.join(root, ".codex/hooks")
      gem_root = File.join(root, "vendor/quality_gate")
      FileUtils.mkdir_p([hooks, File.join(gem_root, "lib")])
      write_project_files(root, hooks, gem_root)
      root
    end

    def write_project_files(root, hooks, gem_root)
      gem_lib = File.join(gem_root, "lib/quality_gate")
      File.write(File.join(root, "Gemfile"), gemfile_source)
      File.write(File.join(hooks, "codex_verify_stop.rb"), File.read(TEMPLATE))
      File.write(File.join(gem_root, "quality_gate.gemspec"), fake_gemspec)
      FileUtils.mkdir_p(gem_lib)
      copy_runtime(gem_lib)
      File.write(File.join(gem_root, "lib/quality_gate.rb"), fake_quality_gate)
    end

    def copy_runtime(gem_lib)
      %w[codex_stop_hook finding].each do |filename|
        FileUtils.cp(File.join(ROOT, "lib/quality_gate/#{filename}.rb"), File.join(gem_lib, "#{filename}.rb"))
      end
    end

    def gemfile_source
      "source 'https://rubygems.org'\ngem 'quality_gate', path: 'vendor/quality_gate'\n"
    end

    def invoke(root, cwd, input)
      environment = {
        "BUNDLE_GEMFILE" => nil, "BUNDLE_PATH" => nil, "BUNDLE_BIN_PATH" => nil,
        "BUNDLER_ORIG_BUNDLE_BIN_PATH" => nil, "BUNDLER_ORIG_PATH" => nil,
        "BUNDLER_ORIG_GEM_PATH" => nil, "BUNDLER_VERSION" => nil, "RUBYOPT" => nil,
        "CODEX_EXPECTED_ROOT" => root
      }
      Open3.capture3(environment, RbConfig.ruby, File.join(root, ".codex/hooks/codex_verify_stop.rb"),
                     stdin_data: input, chdir: cwd)
    end

    def fake_gemspec
      <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "quality_gate"
          spec.version = "0.0.1"
          spec.summary = "test fixture"
          spec.authors = ["test"]
          spec.files = %w[lib/quality_gate.rb lib/quality_gate/codex_stop_hook.rb lib/quality_gate/finding.rb]
          spec.require_paths = ["lib"]
        end
      RUBY
    end

    def fake_quality_gate
      <<~'RUBY'
        require "json"
        module QualityGate; end
        require "quality_gate/finding"
        module QualityGate
          class CLI
            def self.run(_argv, stdout:, stderr:, dir:)
              File.write(ENV.fetch("CODEX_EXPECTED_ROOT") + "/invoked-from.txt", "#{Dir.pwd}\n#{dir}")
              stdout.write(JSON.generate("findings" => [], "summary" => { "findings" => 0, "tool_failures" => 0, "failed_tools" => [] }))
              0
            end
          end
        end
      RUBY
    end

    def stop_input = { "hook_event_name" => "Stop", "stop_hook_active" => false }
  end
end
