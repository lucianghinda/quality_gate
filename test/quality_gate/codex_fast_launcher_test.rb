# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

module QualityGate
  class CodexFastLauncherTest < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)
    TEMPLATE = File.join(ROOT, "lib/generators/quality_gate/install/templates/codex_fast.rb.tt")

    def test_launcher_runs_from_installed_root_with_nested_event_cwd_and_emits_one_json_line
      Dir.mktmpdir("codex-fast-launcher") do |directory|
        root = build_project(directory)
        cwd = File.join(root, "nested/dir")
        FileUtils.mkdir_p(cwd)
        File.write(File.join(cwd, "change.rb"), "puts :ok\n")
        response = run_json(root, cwd, event(cwd, "change.rb"))

        assert_equal({}, response)
        assert_equal "#{File.realpath(root)}\n#{File.realpath(root)}", File.read(File.join(root, "invoked-from.txt"))
      end
    end

    def test_malformed_input_and_missing_gemfile_emit_visible_single_json_response
      Dir.mktmpdir("codex-fast-launcher") do |directory|
        root = build_project(directory)
        assert_unavailable(invoke(root, directory, "{"))

        FileUtils.rm(File.join(root, "Gemfile"))
        assert_unavailable(invoke(root, directory, JSON.generate(event(directory, "change.rb"))))
      end
    end

    private

    def run_json(root, cwd, input)
      stdout, stderr, status = invoke(root, cwd, JSON.generate(input))
      assert status.success?, stderr
      assert_empty stderr
      assert_equal 1, stdout.lines.length, stdout.inspect
      JSON.parse(stdout)
    end

    def assert_unavailable(result)
      stdout, stderr, status = result
      assert status.success?, stderr
      parsed = JSON.parse(stdout)
      assert_match(/unavailable/i, parsed.fetch("systemMessage"))
      assert_includes parsed.fetch("hookSpecificOutput").fetch("additionalContext"), "manual"
      assert_equal 1, stdout.lines.length, stdout.inspect
      assert_empty stderr
    end

    def build_project(directory)
      root = File.join(directory, "project")
      hooks = File.join(root, ".codex/hooks")
      gem_root = File.join(root, "vendor/quality_gate")
      FileUtils.mkdir_p([hooks, File.join(gem_root, "lib/quality_gate")])
      write_gemfile(root)
      write_launcher(hooks)
      File.write(File.join(gem_root, "quality_gate.gemspec"), fake_gemspec)
      copy_runtime(gem_root)
      File.write(File.join(gem_root, "lib/quality_gate.rb"), fake_quality_gate)
      root
    end

    def write_gemfile(root)
      source = "source 'https://rubygems.org'\n"
      source += "gem 'quality_gate', path: 'vendor/quality_gate'\n"
      File.write(File.join(root, "Gemfile"), source)
    end

    def write_launcher(hooks)
      File.write(File.join(hooks, "codex_fast.rb"), File.read(TEMPLATE))
    end

    def copy_runtime(gem_root)
      files = %w[codex_fast_hook codex_patch_files finding]
      files.each { FileUtils.cp(runtime_path(_1), installed_path(gem_root, _1)) }
    end

    def runtime_path(filename)
      File.join(ROOT, "lib/quality_gate/#{filename}.rb")
    end

    def installed_path(gem_root, filename)
      File.join(gem_root, "lib/quality_gate/#{filename}.rb")
    end

    def invoke(root, cwd, input)
      environment = {
        "BUNDLE_GEMFILE" => nil, "BUNDLE_PATH" => nil, "BUNDLE_BIN_PATH" => nil,
        "BUNDLER_ORIG_BUNDLE_BIN_PATH" => nil, "BUNDLER_ORIG_PATH" => nil,
        "BUNDLER_ORIG_GEM_PATH" => nil, "BUNDLER_VERSION" => nil, "RUBYOPT" => nil,
        "CODEX_EXPECTED_ROOT" => root
      }
      Open3.capture3(environment, RbConfig.ruby, File.join(root, ".codex/hooks/codex_fast.rb"),
                     stdin_data: input, chdir: cwd)
    end

    def fake_gemspec
      <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "quality_gate"
          spec.version = "0.0.1"
          spec.summary = "test fixture"
          spec.authors = ["test"]
          spec.files = %w[lib/quality_gate.rb lib/quality_gate/codex_fast_hook.rb lib/quality_gate/finding.rb]
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

    def event(cwd, path)
      { "hook_event_name" => "PostToolUse", "tool_name" => "apply_patch", "cwd" => cwd,
        "tool_input" => { "command" => "*** Begin Patch\n*** Update File: #{path}\n*** End Patch\n" } }
    end
  end
end
