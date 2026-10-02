# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "shellwords"
require "stringio"
require "tmpdir"
require "test_helper"
require "quality_gate/installer"

module QualityGate
  class CIWorkflowTest < Minitest::Test
    GATES = %w[fast verify audit].freeze

    def test_each_generated_gate_step_propagates_a_nonzero_exit_status
      Dir.mktmpdir("quality-gate-ci-workflow") do |root|
        FileUtils.mkdir_p(File.join(root, "test"))
        File.write(File.join(root, "test/test_helper.rb"), "# project helper\n")
        install_ci(root)
        commands = generated_commands(root)
        assert_equal GATES.map { "bundle exec quality_gate #{_1}" }, commands
        fake_bundle = fake_bundle_executable(root)
        commands.each { assert_nonzero_status_propagates(_1, fake_bundle, root) }
      end
    end

    private

    def install_ci(root)
      status = Installer.new(destination_root: root, options: { ci: true }, stdout: StringIO.new).call
      assert_equal 0, status
    end

    def generated_workflow(root)
      File.read(File.join(root, ".github/workflows/quality_gate.yml"))
    end

    def generated_commands(root)
      generated_workflow(root).scan(
        /^\s+run: (bundle exec quality_gate (?:fast|verify|audit))\s*$/
      ).flatten
    end

    def assert_nonzero_status_propagates(command, fake_bundle, root)
      gate = command.split.last
      log = File.join(root, "#{gate}.argv")
      environment = {
        "PATH" => [File.dirname(fake_bundle), ENV.fetch("PATH")].join(File::PATH_SEPARATOR),
        "QUALITY_GATE_ARGUMENT_LOG" => log,
        "QUALITY_GATE_TEST_STATUS" => "1"
      }
      _stdout, _stderr, status = Open3.capture3(environment, *Shellwords.split(command), chdir: root)

      assert_equal 1, status.exitstatus, "#{command} must expose the gate exit status"
      assert_equal ["exec", "quality_gate", gate], File.read(log).split("\0")
    end

    def fake_bundle_executable(root)
      directory = File.join(root, "fake-bin")
      FileUtils.mkdir_p(directory)
      executable = File.join(directory, "bundle")
      File.write(executable, <<~RUBY)
        #!#{RbConfig.ruby}
        File.write(ENV.fetch("QUALITY_GATE_ARGUMENT_LOG"), ARGV.join("\\0"))
        exit Integer(ENV.fetch("QUALITY_GATE_TEST_STATUS"))
      RUBY
      File.chmod(0o755, executable)
      executable
    end
  end
end
