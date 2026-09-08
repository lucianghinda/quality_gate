# frozen_string_literal: true

module RuboCop
  module Cop
    module QualityGate
      # Opt-in convention: concerns should expose behavior to their consumers.
      # Unknown declarations are deliberately exempt because they may add behavior.
      class PrivateOnlyConcern < Base
        MSG = "This concern only defines private instance methods; consider keeping them in its consumer."
        VISIBILITIES = %i[public protected private].freeze

        def on_module(node)
          body = node.body
          return unless body

          statements = body.begin_type? ? body.children : [body]
          return unless concern?(statements)
          return unless private_methods_only?(statements)

          add_offense(node.identifier)
        end

        private

        def concern?(statements)
          statements.any? { |statement| concern_extension?(statement) } ||
            Array(cop_config["ConcernPaths"]).any? do |pattern|
              File.fnmatch?(pattern, processed_source.file_path, File::FNM_PATHNAME | File::FNM_EXTGLOB)
            end
        end

        def concern_extension?(node)
          node.send_type? && node.receiver.nil? && node.method?(:extend) &&
            node.arguments.one? && node.first_argument.const_type? &&
            node.first_argument.const_name == "ActiveSupport::Concern"
        end

        def private_methods_only?(statements)
          methods = {}
          visibility = :public
          statements.each do |statement|
            next if concern_extension?(statement)

            visibility = record_statement(statement, methods, visibility)
            return false unless visibility
          end
          !methods.empty? && methods.values.all?(:private)
        end

        def record_statement(statement, methods, visibility)
          if statement.def_type?
            methods[statement.method_name] = visibility
          elsif visibility_declaration?(statement) && apply_visibility(statement, methods)
            statement.arguments.empty? ? statement.method_name : visibility
          end
        end

        def visibility_declaration?(node)
          node.send_type? && node.receiver.nil? && VISIBILITIES.include?(node.method_name)
        end

        def apply_visibility(node, methods)
          node.arguments.each do |argument|
            if argument.def_type?
              methods[argument.method_name] = node.method_name
            elsif argument.sym_type? && methods.key?(argument.value)
              methods[argument.value] = node.method_name
            else
              return false
            end
          end
          true
        end
      end
    end
  end
end
