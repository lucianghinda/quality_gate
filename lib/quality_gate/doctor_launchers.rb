# frozen_string_literal: true

require_relative "doctor_report"
require_relative "doctor_path_lookup"

module QualityGate
  class DoctorExplicitTargetCheck
    def initialize(paths:)
      @paths = paths
    end

    def check(argv)
      command = argv.first(2) == %w[bundle exec] ? argv.drop(2) : argv
      return ruby_target_problem(command) if ruby_command?(command)

      bundle_target_problem(argv, command)
    end

    private

    attr_reader :paths

    def ruby_target_problem(command)
      return search_target_problem(command[2]) if command[1] == "-S" && explicit_path?(command[2])
      return unless script_argument?(command[1])

      script_problem(command[1])
    end

    def script_problem(target)
      path = paths.relative_path(target)
      return missing_script(target) unless File.file?(path)
      return unreadable_script(target) unless File.readable?(path)

      nil
    end

    def bundle_target_problem(argv, command)
      return unless argv.first(2) == %w[bundle exec] && explicit_path?(command.first)
      return if paths.executable?(command.first)

      ["blocked", "Explicit bundle target #{command.first} is missing; update the command path or install it."]
    end

    def search_target_problem(target)
      return if paths.executable?(target)

      ["blocked", "Ruby -S target #{target} is missing; update its path or install the launcher."]
    end

    def ruby_command?(command) = File.basename(command.first.to_s) == "ruby"
    def explicit_path?(target) = target&.include?(File::SEPARATOR)
    def script_argument?(target) = target && !target.start_with?("-")

    def missing_script(target)
      ["blocked", "Ruby script #{target} is missing; add the file or update commands.* argv."]
    end

    def unreadable_script(target)
      ["blocked", "Ruby script #{target} is unreadable; update its file permissions."]
    end
  end

  class DoctorRubySearchTarget
    def initialize(paths:, known_launchers:)
      @paths = paths
      @known_launchers = known_launchers
    end

    def check(target)
      return missing_target unless target
      return explicit_target(target) if target.include?(File::SEPARATOR)

      named_target(target)
    end

    private

    attr_reader :paths, :known_launchers

    def explicit_target(target)
      ["ready", "Ruby and explicit target #{target} are present; command behavior was not run."]
    end

    def named_target(target)
      return unknown_target unless known_launchers.include?(File.basename(target))
      return path_unavailable unless paths.available?
      return ready_target(target) if paths.executable?(target)

      unchecked_target(target)
    end

    def missing_target = ["unchecked", "ruby -S target was not provided; supply a launcher name."]
    def unknown_target = ["unchecked", "Ruby -S target is not recognized; inspect or simplify the configured command."]
    def path_unavailable = ["unchecked", "PATH is unavailable; set PATH to inspect the ruby -S target."]

    def ready_target(target)
      ["ready", "Ruby and #{target} launchers are present; command behavior was not run."]
    end

    def unchecked_target(target)
      ["unchecked", "Ruby -S target #{target} was not found; add it to PATH or inspect bundle paths."]
    end
  end

  class DoctorLauncherWrapper
    def initialize(paths:)
      @paths = paths
    end

    def check(launcher, known:)
      return explicit_launcher(launcher, known) if launcher.include?(File::SEPARATOR)
      return named_launcher(launcher) if known

      custom_launcher(launcher)
    end

    private

    attr_reader :paths

    def explicit_launcher(launcher, known)
      return missing_explicit(launcher) unless paths.executable?(launcher)
      return ready_launcher(launcher) if known

      unchecked_custom
    end

    def named_launcher(launcher)
      return direct_availability(launcher) unless paths.available?
      return missing_direct(launcher) unless paths.executable?(launcher)

      ready_launcher(launcher)
    end

    def custom_launcher(launcher)
      return unavailable_custom unless paths.available?
      return missing_custom(launcher) unless paths.executable?(launcher)

      unchecked_custom
    end

    def direct_availability(launcher)
      ["unchecked", "PATH is unavailable; set PATH to inspect #{launcher} availability."]
    end

    def missing_direct(launcher)
      message = "Executable launcher #{launcher} is missing or not executable; " \
        "install it, update permissions, or add it to PATH."
      ["blocked", message]
    end

    def missing_explicit(launcher)
      message = "Explicit launcher #{launcher} is missing or not executable; " \
        "update permissions, its command path, or install it."
      ["blocked", message]
    end

    def missing_custom(launcher)
      ["blocked", "Custom wrapper #{launcher} is missing; install it or add it to PATH."]
    end

    def unavailable_custom
      ["unchecked", "PATH is unavailable; set PATH to inspect the custom wrapper."]
    end

    def ready_launcher(launcher)
      ["ready", "Executable #{launcher} is present; tool version and command behavior were not checked."]
    end

    def unchecked_custom
      ["unchecked", "Custom wrapper is present but uninspected; verify its target or use a supported launcher."]
    end
  end

  # Checks launch paths without starting analyzers or project commands.
  class DoctorLaunchers
    KNOWN_LAUNCHERS = %w[
      bundle-audit brakeman herb herb-lint rails rake reek rspec rubocop undercover
    ].map!(&:freeze).freeze

    def initialize(dir:, path: ENV["PATH"])
      @paths = DoctorPathLookup.new(dir:, path:)
      @wrapper = DoctorLauncherWrapper.new(paths: @paths)
      @explicit_targets = DoctorExplicitTargetCheck.new(paths: @paths)
    end

    def check(adapter:, argv:, gate: nil)
      report(adapter, gate, *assess(argv))
    rescue SystemCallError, ArgumentError
      inspection_error(adapter, gate)
    end

    private

    attr_reader :paths, :wrapper, :explicit_targets

    def assess(argv)
      return invalid_argv unless valid_argv?(argv)

      explicit_targets.check(argv) || launch_assessment(argv)
    end

    def launch_assessment(argv)
      return assess_bundle(argv.drop(2)) if argv.first(2) == %w[bundle exec]
      return assess_ruby(argv) if ruby_launcher?(argv.first)

      wrapper.check(argv.first, known: known_launcher?(argv.first))
    end

    def invalid_argv
      ["blocked", "Command argv is invalid; provide a non-empty string array in commands.*."]
    end

    def valid_argv?(argv)
      argv.is_a?(Array) && argv.any? && argv.all? { _1.is_a?(String) && !_1.empty? }
    end

    def assess_bundle(command)
      return ["unchecked", "PATH is unavailable; set PATH to inspect the bundle launcher."] unless paths.available?
      return missing_bundle_launcher unless paths.executable?("bundle")

      return missing_bundle_target(command.first) if missing_bare_bundle_target?(command.first)

      status, message = assess(command)
      [status, "bundle is available; #{message}"]
    end

    def missing_bundle_launcher
      ["blocked", "The bundle launcher is missing; install Bundler or add it to PATH."]
    end

    def missing_bare_bundle_target?(target)
      target && !target.include?(File::SEPARATOR) && !paths.executable?(target)
    end

    def missing_bundle_target(target)
      ["unchecked", "Bundle target #{target} was not found; install it or add it to the bundle PATH."]
    end

    def assess_ruby(argv)
      return missing_ruby_path unless ruby_path_available?(argv.first)
      return missing_ruby_launcher unless paths.executable?(argv.first)

      assess_ruby_arguments(argv.drop(1))
    end

    def assess_ruby_arguments(arguments)
      return unsupported_ruby_form if arguments.empty?
      return assess_ruby_script(arguments) unless arguments.first.start_with?("-")
      return assess_ruby_search(arguments.drop(1)) if arguments.first == "-S"

      unsupported_ruby_form
    end

    def missing_ruby_launcher
      ["blocked", "The ruby launcher is missing; install Ruby or add it to PATH."]
    end

    def unsupported_ruby_form
      ["unchecked", "Ruby options are not inspected; use a simple ruby script command or inspect it manually."]
    end

    def ruby_path_available?(launcher)
      launcher.include?(File::SEPARATOR) || paths.available?
    end

    def missing_ruby_path
      ["unchecked", "Ruby launcher is unresolved; set PATH or configure its explicit path."]
    end

    def assess_ruby_script(arguments)
      script = arguments.first
      ["ready", "Ruby launcher and readable script #{script} are present; command behavior was not run."]
    end

    def assess_ruby_search(arguments)
      DoctorRubySearchTarget.new(paths:, known_launchers: KNOWN_LAUNCHERS).check(arguments.first)
    end

    def known_launcher?(value)
      KNOWN_LAUNCHERS.include?(File.basename(value))
    end

    def ruby_launcher?(value)
      File.basename(value) == "ruby"
    end

    def report(adapter, gate, status, message)
      id = gate ? "command.#{gate}.#{adapter}" : "command.#{adapter}"
      DoctorReport.check(id:, status:, message:)
    end

    def inspection_error(adapter, gate)
      message = "Could not inspect the launcher; verify its command path and argv."
      report(adapter, gate, "unchecked", message)
    end
  end
  private_constant :DoctorExplicitTargetCheck, :DoctorLauncherWrapper, :DoctorRubySearchTarget
end
