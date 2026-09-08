# frozen_string_literal: true

module RuboCop
  module Cop
    module QualityGate
      # Uses Rails' shorthand for callbacks after both creation and update commits.
      class PreferAfterSaveCommit < Base
        extend AutoCorrector

        MSG = "Use after_save_commit for callbacks on both create and update."
        RESTRICT_ON_SEND = %i[after_commit].freeze

        def on_send(node)
          return if node.receiver && !node.receiver.self_type?

          pair = save_option(node.last_argument)
          return unless pair

          removal = option_range(node, pair)
          add_offense(node.loc.selector) do |corrector|
            next if commented?(removal)

            corrector.replace(node.loc.selector, "after_save_commit")
            corrector.remove(removal)
          end
        end

        private

        def save_option(options)
          return unless literal_options?(options)

          pairs = options.pairs.select { |pair| pair.key.sym_type? && pair.key.value == :on }
          pairs.first if pairs.one? && save_events?(pairs.first.value)
        end

        def literal_options?(options)
          options&.hash_type? && options.children.all?(&:pair_type?)
        end

        def commented?(range)
          processed_source.comments.any? { |comment| range.overlaps?(comment.loc.expression) }
        end

        def save_events?(node)
          node.array_type? && node.values.all?(&:sym_type?) &&
            node.values.map(&:value).sort == %i[create update]
        end

        def option_range(node, pair)
          options = node.last_argument
          return argument_range(node, options) if options.pairs.one?

          pair_range(options.pairs, pair)
        end

        def pair_range(pairs, pair)
          index = pairs.index(pair)
          following = pairs[index + 1]
          if following
            pair.source_range.with(end_pos: following.source_range.begin_pos)
          else
            pair.source_range.with(begin_pos: pairs[index - 1].source_range.end_pos)
          end
        end

        def argument_range(node, options)
          previous = node.arguments[-2]
          return options.source_range.with(end_pos: node.loc.end.begin_pos) if !previous && node.parenthesized?

          start = argument_start(node, options, previous)
          options.source_range.with(begin_pos: start)
        end

        def argument_start(node, options, previous)
          return previous.source_range.end_pos if previous
          return node.loc.selector.end_pos unless node.parenthesized?

          options.source_range.begin_pos
        end
      end
    end
  end
end
