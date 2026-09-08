# frozen_string_literal: true

module RuboCop
  module Cop
    module QualityGate
      # Opt-in convention for moving explicit broadcasts into domain behavior.
      class BroadcastInController < Base
        MSG = "Consider moving this broadcast from the controller into model-owned behavior."
        BROADCAST_METHODS = %i[
          broadcast_action broadcast_action_to broadcast_action_later broadcast_action_later_to
          broadcast_append broadcast_append_to broadcast_append_later broadcast_append_later_to
          broadcast_prepend broadcast_prepend_to broadcast_prepend_later broadcast_prepend_later_to
          broadcast_replace broadcast_replace_to broadcast_replace_later broadcast_replace_later_to
          broadcast_update broadcast_update_to broadcast_update_later broadcast_update_later_to
          broadcast_remove broadcast_remove_to
          broadcast_before broadcast_before_to broadcast_before_later broadcast_before_later_to
          broadcast_after broadcast_after_to broadcast_after_later broadcast_after_later_to
          broadcast_render broadcast_render_to broadcast_render_later broadcast_render_later_to
          broadcast_refresh broadcast_refresh_to broadcast_refresh_later broadcast_refresh_later_to
          broadcast_stream_to
        ].freeze

        def on_send(node)
          return unless controller?(node)
          return if Array(cop_config["AllowedMethods"]).include?(node.method_name.to_s)
          return unless broadcast?(node)

          add_offense(node.loc.selector)
        end
        alias on_csend on_send

        private

        def controller?(node)
          enclosing_class = node.each_ancestor(:class).first
          if enclosing_class
            enclosing_class.identifier.const_name.end_with?("Controller")
          else
            processed_source.file_path.include?("/app/controllers/")
          end
        end

        def broadcast?(node)
          BROADCAST_METHODS.include?(node.method_name) || channel_broadcast?(node) || cable_broadcast?(node)
        end

        def channel_broadcast?(node)
          node.method?(:broadcast_to) && node.receiver&.const_type? &&
            node.receiver.const_name.end_with?("Channel")
        end

        def cable_broadcast?(node)
          node.method?(:broadcast) && action_cable_server?(node.receiver)
        end

        def action_cable_server?(receiver)
          receiver&.send_type? && receiver.method?(:server) &&
            receiver.arguments.empty? && receiver.receiver&.const_type? &&
            receiver.receiver.const_name == "ActionCable"
        end
      end
    end
  end
end
