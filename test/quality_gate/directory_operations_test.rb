# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "quality_gate/installation"
require "rbconfig"
require "tmpdir"

module QualityGate
  class DirectoryOperationsTest < Minitest::Test
    def test_bundled_fiddle_uses_the_platform_native_extension
      assert_subprocess_success(<<~'RUBY')
        require "fileutils"
        require "tmpdir"

        Dir.mktmpdir("fiddle-runtime") do |runtime_root|
          RbConfig::CONFIG["DLEXT"] = "so"
          RbConfig::CONFIG["prefix"] = runtime_root
          RbConfig::CONFIG["arch"] = "aarch64-linux"
          RbConfig::CONFIG["ruby_version"] = "4.0.0"
          gem_name = "fiddle-1.1.8"
          gem_home = File.join(runtime_root, "lib/ruby/gems/4.0.0")
          lib_root = File.join(gem_home, "gems", gem_name, "lib")
          extension_root = File.join(gem_home, "extensions", "aarch64-linux", "4.0.0", gem_name)
          Gem.singleton_class.define_method(:extension_api_version) { "4.0.0" }
          FileUtils.mkdir_p([lib_root, extension_root])
          FileUtils.touch(File.join(extension_root, "fiddle.so"))
          operations = QualityGate::Installation.const_get(:DirectoryOperations, false)
          operations.define_singleton_method(:bundled_fiddle_root) { lib_root }
          paths = operations.send(:fiddle_feature_paths)
          abort paths.inspect unless paths.fetch("fiddle.so").end_with?(
            "/extensions/aarch64-linux/4.0.0/fiddle-1.1.8/fiddle.so"
          )

          FileUtils.rm(File.join(extension_root, "fiddle.so"))
          neighboring_extension = File.join(gem_home, "extensions", "aarch64-linux", "4.0.0", "fiddle-9.9.9")
          FileUtils.mkdir_p(neighboring_extension)
          FileUtils.touch(File.join(neighboring_extension, "fiddle.so"))
          begin
            operations.send(:fiddle_feature_paths)
            abort "neighboring fiddle extension was selected"
          rescue operations::Unsupported
            nil
          end

          RbConfig::CONFIG["DLEXT"] = "bundle"
          FileUtils.touch(File.join(lib_root, "fiddle.bundle"))
          paths = operations.send(:fiddle_feature_paths)
          abort paths.inspect unless paths.fetch("fiddle.so") == File.join(lib_root, "fiddle.bundle")

          native_path = paths.fetch("fiddle.so")
          calls = []
          original_require = Kernel.instance_method(:require)
          Kernel.define_method(:require) do |feature|
            calls << feature
            feature == native_path || original_require.bind_call(self, feature)
          end
          operations.send(:with_bundled_fiddle_require) { require "fiddle.so" }
          abort calls.inspect unless calls == [native_path]
        end
      RUBY
    end

    def test_bundled_fiddle_extension_root_uses_the_exact_runtime_layout
      operations = QualityGate::Installation.const_get(:DirectoryOperations, false)
      singleton = operations.singleton_class
      original_root = singleton.instance_method(:bundled_fiddle_root)

      with_fiddle_fixture do |fixture|
        singleton.define_method(:bundled_fiddle_root) { fixture.fetch(:lib_root) }
        assert_exact_extension_path(operations, fixture)
        assert_ruby_version_fallback(operations, fixture)
        assert_lib_extension_preference(operations, fixture)
        assert_neighboring_extension_rejected(operations, fixture)
      end
    ensure
      if original_root
        singleton.send(:remove_method, :bundled_fiddle_root)
        singleton.define_method(:bundled_fiddle_root, original_root)
        singleton.send(:private, :bundled_fiddle_root)
      end
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

    def assert_exact_extension_path(operations, fixture)
      expected = File.join(fixture.fetch(:extension_root), fixture.fetch(:native_name))
      assert_equal expected, operations.send(:fiddle_feature_paths).fetch("fiddle.so")
    end

    def assert_ruby_version_fallback(operations, fixture)
      with_ruby_version_fallback(fixture) do |native_path|
        with_extension_api_version_unavailable do
          assert_equal native_path, operations.send(:fiddle_feature_paths).fetch("fiddle.so")
        end
      end
    end

    def with_ruby_version_fallback(fixture)
      FileUtils.rm(File.join(fixture.fetch(:extension_root), fixture.fetch(:native_name)))
      fallback_root = File.join(
        fixture.fetch(:gem_home), "extensions", RbConfig::CONFIG.fetch("arch"),
        RbConfig::CONFIG.fetch("ruby_version"), fixture.fetch(:gem_name)
      )
      native_path = File.join(fallback_root, fixture.fetch(:native_name))
      FileUtils.mkdir_p(fallback_root)
      FileUtils.touch(native_path)
      yield native_path
    ensure
      FileUtils.rm_f(native_path) if native_path
    end

    def assert_lib_extension_preference(operations, fixture)
      native_path = File.join(fixture.fetch(:lib_root), fixture.fetch(:native_name))
      FileUtils.touch(native_path)
      assert_equal native_path, operations.send(:fiddle_feature_paths).fetch("fiddle.so")
      FileUtils.rm(native_path)
    end

    def assert_neighboring_extension_rejected(operations, fixture)
      neighboring_root = File.join(
        fixture.fetch(:gem_home), "extensions", RbConfig::CONFIG.fetch("arch"),
        Gem.extension_api_version, "fiddle-9.9.9"
      )
      FileUtils.mkdir_p(neighboring_root)
      FileUtils.touch(File.join(neighboring_root, fixture.fetch(:native_name)))
      assert_raises(operations::Unsupported) { operations.send(:fiddle_feature_paths) }
    end

    def with_extension_api_version_unavailable
      gem_singleton = Gem.singleton_class
      original_respond_to = Gem.method(:respond_to?)
      gem_singleton.define_method(:respond_to?) do |name, *args|
        name == :extension_api_version ? false : original_respond_to.call(name, *args)
      end
      yield
    ensure
      gem_singleton&.send(:remove_method, :respond_to?)
    end

    def with_fiddle_fixture
      Dir.mktmpdir("fiddle-runtime") do |runtime_root|
        gem_home = File.join(runtime_root, "lib/ruby/gems", RbConfig::CONFIG.fetch("ruby_version"))
        gem_name = "fiddle-1.1.8"
        lib_root = File.join(gem_home, "gems", gem_name, "lib")
        extension_root = File.join(
          gem_home,
          "extensions",
          RbConfig::CONFIG.fetch("arch"),
          Gem.extension_api_version,
          gem_name
        )
        native_name = "fiddle.#{RbConfig::CONFIG.fetch("DLEXT")}"
        FileUtils.mkdir_p([lib_root, extension_root])
        FileUtils.touch(File.join(extension_root, native_name))
        yield(gem_home:, gem_name:, lib_root:, extension_root:, native_name:)
      end
    end

    def assert_subprocess_success(source)
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, "-Ilib", "-rquality_gate/installation", "-e", source
      )
      assert status.success?, "stdout: #{stdout}\nstderr: #{stderr}"
    end
  end
end
