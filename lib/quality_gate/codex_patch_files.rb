# frozen_string_literal: true

module QualityGate
  # Extracts native apply_patch file operations without interpreting hunk content as paths.
  class CodexPatchFiles
    BEGIN_MARKER = "*** Begin Patch"
    END_MARKER = "*** End Patch"
    OPERATIONS = %w[Add Update Delete].freeze
    private_constant :BEGIN_MARKER, :END_MARKER, :OPERATIONS

    def self.parse(patch)
      new(patch).call
    end

    def initialize(patch)
      @lines = patch.lines(chomp: true).map { _1.delete_suffix("\r") }
      @paths = []
      @section = nil
    end

    def call
      validate_patch!
      lines[1...-1].each { process_line(_1) }
      paths
    end

    private

    attr_reader :lines, :paths, :section

    def validate_patch!
      raise ArgumentError unless lines.length >= 3 && lines.first == BEGIN_MARKER && lines.last == END_MARKER
    end

    def process_line(line)
      process_operation(line) || process_move(line) || process_end_of_file(line) || process_content(line)
    end

    def process_operation(line)
      match = line.match(/\A\*\*\* (#{OPERATIONS.join("|")}) File: (.+)\z/)
      return false unless match

      record_operation(match)
      true
    end

    def record_operation(match)
      @section = { operation: match[1], moved: false, in_hunk: false }
      paths << match[2] unless match[1] == "Delete"
    end

    def process_move(line)
      return false unless line.start_with?("*** Move to: ")

      apply_move(line.delete_prefix("*** Move to: "))
      true
    end

    def apply_move(destination)
      valid_move!(destination)
      paths[-1] = destination
      section[:moved] = true
    end

    def valid_move!(destination)
      valid = section && section.fetch(:operation) == "Update" && !section.fetch(:moved) &&
              !section.fetch(:in_hunk) && !destination.empty?
      raise ArgumentError unless valid
    end

    def process_end_of_file(line)
      return false unless line == "*** End of File"

      valid = section && section.fetch(:operation) == "Update" && section.fetch(:in_hunk)
      raise ArgumentError unless valid

      section[:in_hunk] = true
      true
    end

    def process_content(line)
      raise ArgumentError unless valid_content_line?(line)

      section[:in_hunk] = true
    end

    def valid_content_line?(line)
      section && valid_content?(line)
    end

    def valid_content?(line)
      line.start_with?("+", "-", " ", "@@", "\\ No newline at end of file")
    end
  end
end
