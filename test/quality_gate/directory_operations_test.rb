# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "quality_gate/installation"
require "rbconfig"
require "tmpdir"

module QualityGate
  class DirectoryOperationsTest < Minitest::Test
    def test_bundled_fiddle_uses_the_rubygems_native_extension_directory
      assert_subprocess_success(<<~'RUBY')
        require "fileutils"
        require "tmpdir"

        Dir.mktmpdir("fiddle-runtime") do |runtime_root|
          RbConfig::CONFIG["DLEXT"] = "so"
          RbConfig::CONFIG["prefix"] = runtime_root
          RbConfig::CONFIG["arch"] = "fixture-arch"
          RbConfig::CONFIG["ruby_version"] = "4.0.0"
          gem_name = "fiddle-1.1.8"
          gem_home = File.join(runtime_root, "lib/ruby/gems/4.0.0")
          Gem.singleton_class.define_method(:extension_api_version) { "4.0.0" }
          specification_directory = File.join(gem_home, "specifications")
          FileUtils.mkdir_p(specification_directory)
          gemspec = Gem::Specification.new do |specification|
            specification.name = "fiddle"
            specification.version = "1.1.8"
            specification.summary = "Synthetic Fiddle gem"
            specification.authors = ["Quality Gate"]
          end
          gemspec_path = File.join(specification_directory, "#{gem_name}.gemspec")
          File.write(gemspec_path, gemspec.to_ruby)
          specification = Gem::Specification.load(gemspec_path)
          lib_root = File.join(specification.full_gem_path, "lib")
          extension_root = specification.extension_dir
          FileUtils.mkdir_p([lib_root, extension_root])
          FileUtils.touch(File.join(lib_root, "fiddle.rb"))
          bundled_native_path = File.join(lib_root, "fiddle.so")
          FileUtils.touch(bundled_native_path)
          FileUtils.touch(File.join(extension_root, "fiddle.so"))
          operations = QualityGate::Installation.const_get(:DirectoryOperations, false)
          paths = operations.send(:fiddle_feature_paths)
          native_path = File.join(extension_root, "fiddle.so")
          abort paths.inspect unless paths.fetch("fiddle") == File.join(lib_root, "fiddle.rb")
          abort paths.inspect unless paths.fetch("fiddle.so") == bundled_native_path

          FileUtils.rm(bundled_native_path)
          paths = operations.send(:fiddle_feature_paths)
          abort paths.inspect unless paths.fetch("fiddle.so") == native_path
          abort "RubyGems platform path was not used" if native_path.include?("fixture-arch")

          FileUtils.rm(File.join(lib_root, "fiddle.rb"))
          begin
            operations.send(:fiddle_feature_paths)
            abort "missing Fiddle library was accepted"
          rescue operations::Unsupported => error
            abort error.message unless error.message == "fiddle support is unavailable"
          end
          FileUtils.touch(File.join(lib_root, "fiddle.rb"))

          FileUtils.rm(native_path)
          begin
            operations.send(:fiddle_feature_paths)
            abort "missing native extension was accepted"
          rescue operations::Unsupported => error
            abort error.message unless error.message == "fiddle native extension is unavailable"
          end

          neighboring_extension = File.join(gem_home, "extensions", "aarch64-linux", "4.0.0", "fiddle-9.9.9")
          FileUtils.mkdir_p(neighboring_extension)
          FileUtils.touch(File.join(neighboring_extension, "fiddle.so"))
          begin
            operations.send(:fiddle_feature_paths)
            abort "neighboring fiddle extension was selected"
          rescue operations::Unsupported
            nil
          end
        end
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

    def test_fiddle_roots_report_missing_library_and_extension
      Dir.mktmpdir("fiddle-roots") do |directory|
        gem_root = File.join(directory, "gems", "fiddle-1.2.3")
        library_root = File.join(gem_root, "lib")
        extension_root = File.join(directory, "extensions", "normalized-arch", "fiddle-1.2.3")
        specification = Struct.new(:full_gem_path, :extension_dir).new(gem_root, extension_root)
        operations = QualityGate::Installation.const_get(:DirectoryOperations, false)

        assert_raises(operations::Unsupported) { operations.send(:bundled_fiddle_root, specification) }
        FileUtils.mkdir_p(library_root)
        FileUtils.touch(File.join(library_root, "fiddle.rb"))
        assert_equal library_root, operations.send(:bundled_fiddle_root, specification)

        FileUtils.touch(File.join(library_root, "fiddle.#{RbConfig::CONFIG.fetch("DLEXT")}"))
        assert_equal library_root, operations.send(:bundled_fiddle_extension_root, specification)
        FileUtils.rm(File.join(library_root, "fiddle.#{RbConfig::CONFIG.fetch("DLEXT")}"))
        assert_raises(operations::Unsupported) { operations.send(:bundled_fiddle_extension_root, specification) }
        FileUtils.mkdir_p(extension_root)
        FileUtils.touch(File.join(extension_root, "fiddle.#{RbConfig::CONFIG.fetch("DLEXT")}"))
        assert_equal extension_root, operations.send(:bundled_fiddle_extension_root, specification)
      end
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
