# frozen_string_literal: true

require "json"

module QualityGate
  # Reads the advisory health log written by the automatic hooks.
  class HookLog
    DEFAULT_PATH = "log/quality_gate_hooks.jsonl"
    MAX_SCAN_BYTES = 1024 * 1024
    MAX_LINE_BYTES = 64 * 1024
    OUTCOMES = %w[
      no_file skipped deleted clean findings unavailable
      verify_skipped verify_debounced verify_clean verify_blocked verify_unavailable verify_cap
    ].map!(&:freeze).freeze
    private_constant :MAX_SCAN_BYTES, :MAX_LINE_BYTES, :OUTCOMES

    attr_reader :path

    def initialize(path:)
      @path = path.dup.freeze
    end

    def recent(limit: 20)
      return [] unless limit.positive?

      with_log_file { |io| recent_records(io, limit) }
    end

    def unavailable_count(limit: 20)
      recent(limit: limit).count { %w[unavailable verify_unavailable].include?(_1.fetch("outcome")) }
    end

    def warning_line(limit: 20)
      count = unavailable_count(limit: limit)
      return if count.zero?

      "Warning: #{count} of the last #{limit} automatic checks could not run; " \
        "check bundle install and the Quality Gate hook setup."
    end

    private

    def with_log_file
      expected = File.lstat(path)
      return [] unless expected.file?

      File.open(path, read_flags) do |io|
        return [] unless same_regular_file?(io.stat, expected, File.lstat(path))

        io.binmode
        yield io
      end
    rescue SystemCallError, IOError
      []
    end

    def recent_records(io, limit)
      records = []
      tail_bytes(io).split("\n".b).reverse_each do |line|
        record = parse_line(line)
        records << record if record
        break if records.length >= limit
      end
      records.reverse
    end

    def read_flags
      %i[NONBLOCK NOFOLLOW].reduce(File::RDONLY) do |flags, name|
        File.const_defined?(name) ? flags | File.const_get(name) : flags
      end
    end

    def same_regular_file?(opened, expected, current)
      [opened, expected, current].all?(&:file?) &&
        [opened.dev, opened.ino] == [expected.dev, expected.ino] &&
        [opened.dev, opened.ino] == [current.dev, current.ino]
    end

    def tail_bytes(io)
      size = io.stat.size
      length = [size, MAX_SCAN_BYTES].min
      offset = size - length
      starts_at_boundary = line_boundary?(io, offset)
      io.seek(offset, IO::SEEK_SET)
      bytes = io.read(length) || "".b

      discard_partial_line(bytes, starts_at_boundary)
    end

    def line_boundary?(io, offset)
      return true if offset.zero?

      io.seek(offset - 1, IO::SEEK_SET)
      io.read(1) == "\n".b
    end

    def discard_partial_line(bytes, starts_at_boundary)
      return bytes if starts_at_boundary

      newline = bytes.index("\n".b)
      return "".b unless newline

      bytes.byteslice(newline + 1, bytes.bytesize - newline - 1)
    end

    def parse_line(line)
      return if line.bytesize > MAX_LINE_BYTES

      line = line.dup.force_encoding(Encoding::UTF_8)
      return unless line.valid_encoding?

      record = JSON.parse(line)
      record if valid_record?(record)
    rescue JSON::ParserError
      nil
    end

    def valid_record?(record)
      record.is_a?(Hash) &&
        record["ts"].is_a?(String) &&
        record.key?("file") &&
        (record["file"].nil? || record["file"].is_a?(String)) &&
        OUTCOMES.include?(record["outcome"]) &&
        valid_duration?(record["duration_ms"])
    end

    def valid_duration?(duration)
      duration.is_a?(Numeric) && duration.finite? && duration >= 0
    end
  end
end
