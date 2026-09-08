# frozen_string_literal: true

module RuboCop
  module Cop
    module QualityGate
      # Defers recognizable request-context defaults until association initialization.
      class AssociationDefaultBlockValue < Base
        MSG = "Wrap the association default in a lambda so Current is read when the record is initialized."
        RESTRICT_ON_SEND = %i[belongs_to].freeze

        def on_send(node)
          return if node.receiver && !node.receiver.self_type?

          value = default_value(node.last_argument)
          return unless value && current_read?(value)

          add_offense(value)
        end

        private

        def default_value(options)
          return unless literal_options?(options)

          defaults = options.pairs.select { |pair| pair.key.sym_type? && pair.key.value == :default }
          defaults.first.value if defaults.one?
        end

        def literal_options?(options)
          options&.hash_type? && options.children.all?(&:pair_type?)
        end

        def current_read?(node)
          return false unless node.send_type? || node.csend_type?
          return false if %i[method public_method to_proc].include?(node.method_name)

          receiver = node.receiver
          return false unless receiver
          return receiver.const_name == "Current" if receiver.const_type?

          current_read?(receiver)
        end
      end
    end
  end
end
