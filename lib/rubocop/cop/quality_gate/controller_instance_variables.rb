# frozen_string_literal: true

module RuboCop
  module Cop
    module QualityGate
      # Sandi Metz rule four: a controller action instantiates one object.
      # Only public instance methods of a *Controller class count as actions.
      class ControllerInstanceVariables < Base
        include VisibilityHelp
        extend ExcludeLimit

        MSG = "Action `%<action>s` assigns %<count>d instance variables (%<names>s); the limit is %<max>d."
        OWNER_TYPES = %i[class sclass module def defs].freeze

        exclude_limit "Max"

        def on_def(node)
          return unless action?(node)

          names = assigned_names(node)
          return if names.size <= max

          add_offense(node.loc.name, message: message_for(node, names)) { self.max = names.size }
        end

        private

        def action?(node) = controller?(node) && node_visibility(node) == :public

        def controller?(node)
          owner = node.each_ancestor(*OWNER_TYPES).first
          return false unless owner&.class_type?

          owner.identifier.const_name.to_s.end_with?("Controller")
        end

        def assigned_names(node) = node.each_descendant(:ivasgn).map { _1.name.to_s }.uniq

        def message_for(node, names)
          format(MSG, action: node.method_name, count: names.size, names: names.join(", "), max: max)
        end

        def max = cop_config.fetch("Max", 1)
      end
    end
  end
end
