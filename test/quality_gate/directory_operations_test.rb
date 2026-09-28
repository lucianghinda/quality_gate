# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

module QualityGate
  class DirectoryOperationsTest < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)

    def test_missing_fiddle_preserves_the_unsupported_error
      assert_subprocess_success(<<~'RUBY')
        abort "Fiddle already loaded" if defined?(Fiddle)
        operations = QualityGate::Installation.const_get(:DirectoryOperations, false)
        operations.define_singleton_method(:load_fiddle_importer!) do
          raise self::Unsupported, "fiddle unavailable"
        end
        begin
          operations.open_directory(STDIN, ".", File::RDONLY)
          abort "expected unsupported operation"
        rescue operations::Unsupported => error
          abort error.message unless error.message == "fiddle unavailable"
        end
      RUBY
    end

    def test_fiddle_loads_under_bundler_and_leaves_kernel_require_untouched
      assert_bundled_subprocess_success(<<~'RUBY')
        require "tmpdir"

        operations = QualityGate::Installation.const_get(:DirectoryOperations, false)
        original_owner = Kernel.instance_method(:require).owner

        Dir.mktmpdir("directory-operations") do |dir|
          File.open(dir, File::RDONLY) do |root|
            directory_io = operations.open_directory(root, ".", File::RDONLY)
            begin
              operations.mkdir(directory_io, "nested", 0o755)
              nested_io = operations.open_directory(directory_io, "nested", File::RDONLY)
              begin
                create_flags = File::WRONLY | File::CREAT | File::EXCL
                file = operations.open_file(nested_io, "source.txt", create_flags, 0o600)
                file.write("hello")
                file.flush
                operations.fsync(file)
                operations.fchmod(file, 0o600)
                file.close

                operations.link(nested_io, "source.txt", "linked.txt")
                operations.rename_noreplace(nested_io, "linked.txt", "renamed.txt")

                operations.open_file(nested_io, "blocked.txt", create_flags, 0o600).close

                begin
                  operations.rename_noreplace(nested_io, "renamed.txt", "blocked.txt")
                  abort "expected Errno::EEXIST"
                rescue Errno::EEXIST
                  nil
                end

                operations.unlink(nested_io, "source.txt")
                operations.unlink(nested_io, "renamed.txt")
                operations.unlink(nested_io, "blocked.txt")
                operations.fsync(nested_io)
              ensure
                nested_io.close
              end
            ensure
              directory_io.close
            end
          end
        end

        abort "Fiddle did not load" unless defined?(Fiddle::Importer)
        abort "Kernel#require was patched" unless Kernel.instance_method(:require).owner == original_owner
      RUBY
    end

    private

    def assert_subprocess_success(source)
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, "-Ilib", "-rquality_gate/installation", "-e", source
      )
      assert status.success?, "stdout: #{stdout}\nstderr: #{stderr}"
    end

    def assert_bundled_subprocess_success(source)
      environment = { "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile") }
      stdout, stderr, status = Open3.capture3(
        environment, RbConfig.ruby, "-rbundler/setup", "-Ilib", "-rquality_gate/installation", "-e", source
      )
      assert status.success?, "stdout: #{stdout}\nstderr: #{stderr}"
    end
  end
end
