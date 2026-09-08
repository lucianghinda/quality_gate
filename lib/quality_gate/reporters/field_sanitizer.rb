# frozen_string_literal: true

module QualityGate
  module Reporters
    # Normalizes reporter string fields without mutating source findings.
    module FieldSanitizer
      REPLACEMENT_CHARACTER = "\uFFFD"

      module_function

      def for_text(value)
        sanitize_text(scrub_utf8(value), preserve_newlines: false)
      end

      def for_text_message(value)
        sanitize_text(scrub_utf8(value), preserve_newlines: true)
      end

      def for_json(value)
        scrub_utf8(value)
      end

      def scrub_utf8(value)
        value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: REPLACEMENT_CHARACTER)
      end

      def sanitize_text(value, preserve_newlines:)
        value.each_char.map { sanitize_character(_1, preserve_newlines) }.join.strip
      end

      def sanitize_character(character, preserve_newlines)
        return character if preserve_newlines && character == "\n"
        return "" if preserve_newlines && character == "\e"
        return character unless character.match?(/[[:cntrl:]\u2028\u2029]/)

        " "
      end
    end

    private_constant :FieldSanitizer
  end
end
