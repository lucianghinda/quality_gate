# frozen_string_literal: true

require "test_helper"
require "erb"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

module QualityGate
  class CoverageTemplateTest < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)
    TEMPLATE = File.join(ROOT, "lib/generators/quality_gate/install/templates/simplecov.rb.tt")
    NONMATCHING_COVERAGE_VALUES = [nil, "", "0", "true"].freeze
    EXPECTED_TEMPLATE = <<~RUBY
      if ENV['COVERAGE'] == '1'
        require 'simplecov'
        require 'undercover/simplecov_formatter'

        SimpleCov.formatter = SimpleCov::Formatter::Undercover
        SimpleCov.start do
          enable_coverage :branch
          add_filter '/test/'
        end
      end
    RUBY

    def test_rendered_template_matches_the_shipped_string_literal_style
      assert_equal EXPECTED_TEMPLATE, rendered_template
    end

    def test_stays_inactive_for_representative_nonmatching_coverage_values
      Dir.mktmpdir do |dir|
        probe = File.join(dir, "probe.rb")
        File.write(probe, <<~RUBY)
          #{rendered_template}
          abort "SimpleCov unexpectedly loaded" if defined?(SimpleCov)
          puts "inactive"
        RUBY

        NONMATCHING_COVERAGE_VALUES.each do |coverage|
          stdout, stderr, status = run_ruby(probe, chdir: dir, coverage: coverage)

          assert_predicate status, :success?, "COVERAGE=#{coverage.inspect}: #{stderr}"
          assert_equal "inactive\n", stdout, "COVERAGE=#{coverage.inspect}"
        end
        refute_path_exists File.join(dir, "coverage")
      end
    end

    def test_starts_branch_coverage_before_host_code_and_writes_the_undercover_record
      Dir.mktmpdir do |dir|
        host_files = write_minimal_host(dir)
        probe = File.join(dir, "test", "probe.rb")
        record = run_covered_host(probe, dir)

        assert_record_paths(record, dir, host_files)
        assert_branch_coverage(record)
      end
    end

    private

    def rendered_template
      assert File.file?(TEMPLATE), "expected coverage template at #{TEMPLATE}"

      ERB.new(File.read(TEMPLATE), trim_mode: "-").result
    end

    def run_ruby(script, chdir:, coverage:)
      environment = {
        "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"),
        "COVERAGE" => coverage
      }

      Open3.capture3(environment, RbConfig.ruby, "-rbundler/setup", script, chdir: chdir)
    end

    def run_covered_host(probe, dir)
      stdout, stderr, status = run_ruby(probe, chdir: dir, coverage: "1")
      assert_predicate status, :success?, "stdout: #{stdout}\nstderr: #{stderr}"

      record_path = File.join(dir, "coverage", "coverage.json")
      assert_path_exists record_path
      JSON.parse(File.read(record_path))
    end

    def assert_record_paths(record, dir, host_files)
      assert_equal File.realpath(dir), record.dig("meta", "simplecov_root")

      coverage = record.fetch("coverage")
      assert_includes coverage.keys, relative_path(host_files.fetch(:source), dir)
      refute_includes coverage.keys, relative_path(host_files.fetch(:filtered_test), dir)
      refute(coverage.keys.any? { _1.start_with?("test/") }, "expected test files to be filtered")
    end

    def relative_path(path, dir)
      path.delete_prefix("#{dir}/")
    end

    def assert_branch_coverage(record)
      branch_data = record.dig("coverage", "lib/example.rb", "branches")

      refute_nil branch_data
      refute_empty branch_data
    end

    def write_minimal_host(dir)
      lib_dir = File.join(dir, "lib")
      test_dir = File.join(dir, "test")
      FileUtils.mkdir_p([lib_dir, test_dir])
      File.write(File.join(dir, ".simplecov"), <<~RUBY)
        SimpleCov.remove_filter %r{\\A(test|features|spec|autotest)/}
      RUBY

      source = File.join(lib_dir, "example.rb")
      File.write(source, <<~RUBY)
        require "coverage"

        raise "coverage was not started before host code" unless Coverage.running?
        raise "Undercover is not the configured formatter" unless SimpleCov.formatter == SimpleCov::Formatter::Undercover

        module Example
          def self.classify(value)
            if value
              :present
            else
              :absent
            end
          end
        end
      RUBY

      filtered_test = File.join(test_dir, "loaded_after_coverage.rb")
      File.write(filtered_test, <<~RUBY)
        module LoadedAfterCoverage
          def self.classify(value)
            value ? :covered : :uncovered
          end
        end
      RUBY

      File.write(File.join(test_dir, "test_helper.rb"), <<~RUBY)
        #{rendered_template}
        require_relative "../lib/example"
        require_relative "loaded_after_coverage"
      RUBY
      File.write(File.join(test_dir, "probe.rb"), <<~RUBY)
        require_relative "test_helper"
        raise "test helper was not loaded after coverage started" unless Coverage.peek_result.key?(#{File.realpath(filtered_test).inspect})
        raise "unexpected result" unless Example.classify(true) == :present
        raise "unexpected test helper result" unless LoadedAfterCoverage.classify(true) == :covered
      RUBY

      { source: source, filtered_test: filtered_test }
    end
  end
end
