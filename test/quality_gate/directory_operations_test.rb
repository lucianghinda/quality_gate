# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

module QualityGate
  class DirectoryOperationsTest < Minitest::Test
    def test_bundled_fiddle_uses_the_platform_native_extension
      assert_subprocess_success(<<~'RUBY')
        RbConfig::CONFIG["DLEXT"] = "so"
        operations = QualityGate::Installation.const_get(:DirectoryOperations, false)
        operations.define_singleton_method(:bundled_fiddle_root) { "/runtime/fiddle/lib" }
        paths = operations.send(:fiddle_feature_paths)
        abort paths.inspect unless paths.fetch("fiddle.so").end_with?("/fiddle.so")

        native_path = paths.fetch("fiddle.so")
        calls = []
        original_require = Kernel.instance_method(:require)
        Kernel.define_method(:require) do |feature|
          calls << feature
          feature == native_path || original_require.bind_call(self, feature)
        end
        operations.send(:with_bundled_fiddle_require) { require "fiddle.so" }
        abort calls.inspect unless calls == [native_path]
      RUBY
    end

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

    private

    def assert_subprocess_success(source)
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, "-Ilib", "-rquality_gate/installation", "-e", source
      )
      assert status.success?, "stdout: #{stdout}\nstderr: #{stderr}"
    end
  end
end
