# frozen_string_literal: true

require "test_helper"
require "erb"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"
require "quality_gate/ruby_profile"

module QualityGate
  class RubyProfileTest < Minitest::Test
    def test_defaults_to_minitest_when_test_helper_is_present
      with_project("test/test_helper.rb") do |root|
        profile = RubyProfile.new(destination_root: root, options: {})

        assert_equal "test/test_helper.rb", profile.test_helper
        assert_equal %w[bundle exec rake test], profile.test_command
        assert profile.coverage?
        assert_equal "ruby_quality_gate.yml.tt", profile.template_for("quality_gate.yml.tt")
        assert_equal "ruby_rubocop.yml.tt", profile.template_for("rubocop.yml.tt")
        assert_equal "unrelated.tt", profile.template_for("unrelated.tt")
      end
    end

    def test_detects_rspec_and_uses_its_default_command
      with_project("spec/spec_helper.rb") do |root|
        profile = RubyProfile.new(destination_root: root, options: {})

        assert_equal "spec/spec_helper.rb", profile.test_helper
        assert_equal %w[bundle exec rspec], profile.test_command
      end
    end

    def test_requires_explicit_framework_when_both_helpers_exist
      with_project("test/test_helper.rb", "spec/spec_helper.rb") do |root|
        error = assert_raises(ArgumentError) do
          RubyProfile.new(destination_root: root, options: {})
        end

        assert_includes error.message, "test-framework"

        profile = RubyProfile.new(destination_root: root, options: { test_framework: "rspec" })
        assert_equal "spec/spec_helper.rb", profile.test_helper
      end
    end

    def test_custom_helper_defaults_to_minitest_and_shellwords_parses_command
      with_project("support/helper.rb") do |root|
        profile = RubyProfile.new(
          destination_root: root,
          options: { test_helper: "support/helper.rb", test_command: "bundle exec rake test -- --verbose" }
        )

        assert_equal "support/helper.rb", profile.test_helper
        assert_equal %w[bundle exec rake test -- --verbose], profile.test_command
      end
    end

    def test_template_round_trips_special_command_arguments_as_yaml
      with_project("test/test_helper.rb") do |root|
        profile = RubyProfile.new(destination_root: root, options: { test_command: special_command })
        rendered = render_template(profile)
        parsed = YAML.safe_load(rendered, permitted_classes: [], aliases: false)

        assert_equal special_command, parsed.fetch("commands").fetch("verify").fetch("test_suite")
      end
    end

    def test_missing_helper_requires_skip_coverage_or_an_existing_custom_helper
      with_project do |root|
        error = assert_raises(ArgumentError) do
          RubyProfile.new(destination_root: root, options: {})
        end
        assert_match(/test_helper|skip-coverage/, error.message)

        profile = RubyProfile.new(destination_root: root, options: { skip_coverage: true })
        assert_equal "test/test_helper.rb", profile.test_helper
        refute profile.coverage?

        profile = RubyProfile.new(
          destination_root: root,
          options: { test_helper: "support/missing_helper.rb", skip_coverage: true }
        )
        assert_equal "support/missing_helper.rb", profile.test_helper
      end
    end

    def test_rejects_invalid_profile_and_framework
      with_project("test/test_helper.rb") do |root|
        profile_error = assert_raises(ArgumentError) do
          RubyProfile.new(destination_root: root, options: { profile: "rails" })
        end
        assert_includes profile_error.message, "profile"

        assert_raises(ArgumentError) { RubyProfile.new(destination_root: root, options: { test_framework: "wat" }) }
      end
    end

    def test_rejects_non_mapping_options_and_invalid_option_keys
      with_project("test/test_helper.rb") do |root|
        assert_raises(ArgumentError) { RubyProfile.new(destination_root: root, options: Object.new) }
        assert_raises(ArgumentError) { RubyProfile.new(destination_root: root, options: { 1 => true }) }
      end
    end

    def test_rejects_empty_and_nonexistent_destination_roots
      with_project("test/test_helper.rb") do |root|
        assert_raises(ArgumentError) { RubyProfile.new(destination_root: "", options: {}) }
        missing = File.join(root, "missing-project")
        assert_raises(ArgumentError) { RubyProfile.new(destination_root: missing, options: {}) }
      end
    end

    def test_rejects_empty_or_malformed_commands_and_invalid_argv
      with_project("test/test_helper.rb") do |root|
        assert_raises(ArgumentError) { RubyProfile.new(destination_root: root, options: { test_command: "  " }) }
        assert_raises(ArgumentError) do
          RubyProfile.new(destination_root: root, options: { test_command: 123 })
        end
        assert_raises(ArgumentError) do
          RubyProfile.new(destination_root: root, options: { test_command: "bundle exec 'rake" })
        end
        assert_raises(ArgumentError) do
          RubyProfile.new(destination_root: root, options: { test_command: ["bundle", 12] })
        end
        assert_raises(ArgumentError) do
          RubyProfile.new(destination_root: root, options: { test_command: ["bundle", ""] })
        end
      end
    end

    def test_rejects_nonstring_and_empty_custom_helpers
      with_project("test/test_helper.rb") do |root|
        assert_raises(ArgumentError) do
          RubyProfile.new(destination_root: root, options: { test_helper: 123 })
        end
        assert_raises(ArgumentError) do
          RubyProfile.new(destination_root: root, options: { test_helper: "" })
        end
      end
    end

    def test_rejects_helper_paths_outside_the_project
      with_project("test/test_helper.rb") do |root|
        assert_raises(ArgumentError) do
          RubyProfile.new(destination_root: root, options: { test_helper: "../outside.rb" })
        end
        assert_raises(ArgumentError) do
          RubyProfile.new(destination_root: root, options: { test_helper: "/tmp/outside.rb" })
        end
      end
    end

    def test_ruby_templates_define_plain_ruby_defaults_and_coverage_filters
      assert_template_contains("ruby_quality_gate.yml.tt", "@profile.test_command")
      assert_template_contains("ruby_quality_gate.yml.tt", "undercover")
      assert_template_contains("ruby_simplecov.rb.tt", "add_filter '/test/'")
      assert_template_contains("ruby_simplecov.rb.tt", "add_filter '/spec/'")
      assert_template_contains("ruby_agents_section.md.tt", "bundle exec quality_gate init --profile ruby --agents")
      assert_ruby_config_contains("inherit_from: rubocop.yml")
      assert_ruby_config_contains("QualityGate/ControllerInstanceVariables")
    end

    def test_ruby_config_disables_rails_and_controller_cops_when_resolved_by_rubocop
      with_project("test/test_helper.rb") do |root|
        source_path = File.join(root, "example_controller.rb")
        File.write(source_path, <<~RUBY)
          class ExampleController < ApplicationController
            def index
              @first = 1
              @second = 2
            end
          end
        RUBY

        output, error, status = Open3.capture3(
          { "RUBOCOP_CACHE_ROOT" => File.join(root, ".rubocop-cache") },
          RbConfig.ruby,
          "-S", "bundle", "exec", "rubocop",
          "--config", File.expand_path("../../config/ruby.yml", __dir__),
          "--only", "Rails/ActionControllerTestCase,QualityGate/ControllerInstanceVariables",
          source_path
        )

        assert_predicate status, :success?, "stdout=#{output}\nstderr=#{error}"
        assert_includes output, "file inspected, no offenses detected"
      end
    end

    private

    def with_project(*files)
      Dir.mktmpdir("quality_gate-ruby-profile") do |root|
        files.each do |relative_path|
          path = File.join(root, relative_path)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, "# helper\n")
        end
        yield root
      end
    end

    def template_path(name)
      File.expand_path("../../lib/generators/quality_gate/install/templates/#{name}", __dir__)
    end

    def assert_template_contains(name, expected)
      assert_includes File.read(template_path(name)), expected
    end

    def special_command
      ["ruby", "puts \"\#{name}\"", "path\\to\\file", "quote: 'value'", "control\u0001"]
    end

    def render_template(profile)
      context = Object.new
      context.instance_variable_set(:@profile, profile)
      template = ERB.new(File.read(template_path("ruby_quality_gate.yml.tt")), trim_mode: "-")
      template.result(context.instance_eval { binding })
    end

    def assert_ruby_config_contains(expected)
      assert_includes File.read(File.expand_path("../../config/ruby.yml", __dir__)), expected
    end
  end
end
