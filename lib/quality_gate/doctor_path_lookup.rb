# frozen_string_literal: true

module QualityGate
  # Resolves executable and script paths using the supplied project directory.
  class DoctorPathLookup
    def initialize(dir:, path: ENV["PATH"])
      @dir = File.expand_path(dir)
      @path = path
    end

    def resolve_executable(name)
      return resolve_explicit(name) if explicit_path?(name)
      return unless @path

      resolve_from_path(name)
    end

    def executable?(name) = !resolve_executable(name).nil?

    def relative_path(name) = File.expand_path(name, @dir)

    def available? = !@path.nil?

    private

    def resolve_from_path(name)
      path_entries.each do |entry|
        candidate = File.expand_path(name, entry)
        return candidate if executable_file?(candidate)
      end
      nil
    end

    def resolve_explicit(name)
      path = relative_path(name)
      path if executable_file?(path)
    end

    def explicit_path?(name) = name.include?(File::SEPARATOR)

    def path_entries
      entries = @path.empty? ? [""] : @path.split(File::PATH_SEPARATOR, -1)
      entries.map { File.expand_path(_1.empty? ? @dir : _1, @dir) }
    end

    def executable_file?(path)
      File.file?(path) && File.executable?(path)
    end
  end

  private_constant :DoctorPathLookup
end
