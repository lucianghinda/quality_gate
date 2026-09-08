# frozen_string_literal: true

require_relative "../../../quality_gate/installation"

if defined?(Rails::Generators::Base)
  module QualityGate
    # Defines the ordered command shell for installing Quality Gate into a Rails application.
    class InstallGenerator < Rails::Generators::Base
      include Installation

      FILES = Installation::FILES
      MARKER_START = Installation::MARKER_START
      MARKER_END = Installation::MARKER_END
      AGENT_TEMPLATE_PATHS = Installation.const_get(:AGENT_TEMPLATE_PATHS, false)
      AGENT_CONTRACT_PATHS = Installation.const_get(:AGENT_CONTRACT_PATHS, false)
      PRIOR_CLAUDE_SETTINGS = Installation.const_get(:PRIOR_CLAUDE_SETTINGS, false)
      STRONG_MIGRATIONS_PROVENANCE = Installation.const_get(:STRONG_MIGRATIONS_PROVENANCE, false)
      HOOK_MODE = Installation.const_get(:HOOK_MODE, false)
      DEFAULT_AGENT_ARTIFACT_MODE = Installation.const_get(:DEFAULT_AGENT_ARTIFACT_MODE, false)
      TEMPFILE_MODE = Installation.const_get(:TEMPFILE_MODE, false)
      AGENT_CONTRACT_START = Installation.const_get(:AGENT_CONTRACT_START, false)
      AGENT_CONTRACT_END = Installation.const_get(:AGENT_CONTRACT_END, false)
      DirectoryOperations = Installation.const_get(:DirectoryOperations, false)

      private_constant :AGENT_TEMPLATE_PATHS, :AGENT_CONTRACT_PATHS
      private_constant :PRIOR_CLAUDE_SETTINGS
      private_constant :STRONG_MIGRATIONS_PROVENANCE, :HOOK_MODE, :DEFAULT_AGENT_ARTIFACT_MODE, :TEMPFILE_MODE
      private_constant :AGENT_CONTRACT_START, :AGENT_CONTRACT_END, :DirectoryOperations

      source_root File.expand_path("templates", __dir__)

      class_option :skip_initializers, type: :boolean, default: false
      class_option :skip_coverage, type: :boolean, default: false
      class_option :agents, type: :boolean, default: false

      # Rails discovers generator tasks from methods declared on this class.
      # Keep these forwarding methods so the shared module remains framework-neutral.
      # rubocop:disable Lint/UselessMethodDefinition
      def create_settings_file = super
      def create_rules_file = super
      def create_initializers = super
      def inject_coverage = super
      def create_agent_integration = super
      def print_summary = super
      # rubocop:enable Lint/UselessMethodDefinition

      private

      def create_new_file(relative_path, content)
        create_file(relative_path, content, verbose: false)
      end

      def template_source_root
        self.class.source_root
      end

      def template_for(name)
        name
      end

      def test_helper_path
        "test/test_helper.rb"
      end
    end
  end
end
