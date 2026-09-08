# frozen_string_literal: true

require "rubocop"
require "lint_roller"
require_relative "version"
require_relative "../rubocop/cop/quality_gate/association_default_block_value"
require_relative "../rubocop/cop/quality_gate/prefer_after_save_commit"
require_relative "../rubocop/cop/quality_gate/private_only_concern"
require_relative "../rubocop/cop/quality_gate/broadcast_in_controller"
require_relative "../rubocop/cop/quality_gate/controller_instance_variables"

module QualityGate
  # Loads optional Rails conventions through RuboCop's plugin interface.
  class RuboCopPlugin < LintRoller::Plugin
    def about
      LintRoller::About.new(
        name: "quality_gate", version: VERSION,
        homepage: "https://github.com/lucianghinda/quality_gate",
        description: "Conservative, opt-in Rails convention checks."
      )
    end

    def supported?(context)
      context.engine == :rubocop
    end

    def rules(_context)
      LintRoller::Rules.new(
        type: :path, config_format: :rubocop,
        value: Pathname.new(File.expand_path("../../config/cops.yml", __dir__))
      )
    end
  end
end
