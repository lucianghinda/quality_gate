# frozen_string_literal: true

module QualityGate
  # Reads a small regular file without following links or blocking on special files.
  class DoctorBoundedFile
    Result = Data.define(:status, :contents)
    MAX_BYTES = 1024 * 1024

    def self.read(path:, max_bytes: MAX_BYTES)
      new(path:, max_bytes:).read
    end

    def initialize(path:, max_bytes:)
      @path = path
      @max_bytes = max_bytes
    end

    def read
      read_expected_file
    rescue SystemCallError, IOError => e
      read_error(e)
    end

    private

    def read_expected_file
      expected = File.lstat(@path)
      return Result.new(:unsafe, nil) unless expected.file?

      read_open_file(expected)
    end

    def read_error(error)
      status = error.is_a?(Errno::ENOENT) ? :missing : :unreadable
      Result.new(status, nil)
    end

    def read_flags
      %i[NONBLOCK NOFOLLOW].reduce(File::RDONLY) do |flags, name|
        File.const_defined?(name) ? flags | File.const_get(name) : flags
      end
    end

    def read_open_file(expected)
      File.open(@path, read_flags) { |io| read_checked_io(io, expected) }
    end

    def read_checked_io(io, expected)
      return Result.new(:unsafe, nil) unless same_file?(io.stat, expected, File.lstat(@path))
      return Result.new(:oversized, nil) if io.stat.size > @max_bytes

      read_contents(io, expected)
    end

    def read_contents(io, expected)
      bytes = io.read(@max_bytes) || "".b
      validate_contents(io, expected, bytes)
    end

    def validate_contents(io, expected, bytes)
      opened = io.stat
      return Result.new(:unsafe, nil) unless same_file?(opened, expected, File.lstat(@path))
      return Result.new(:oversized, nil) if opened.size > @max_bytes || bytes.bytesize > @max_bytes

      Result.new(:ok, bytes.force_encoding(Encoding::UTF_8).freeze)
    end

    def same_file?(opened, expected, current)
      [opened, expected, current].all?(&:file?) &&
        [opened.dev, opened.ino] == [expected.dev, expected.ino] &&
        [opened.dev, opened.ino] == [current.dev, current.ino]
    end
  end
end
