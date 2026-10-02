# frozen_string_literal: true

require "rbconfig"
require_relative "config"
require_relative "doctor_report"
require_relative "doctor_launchers"
require_relative "doctor_git"
require_relative "doctor_coverage"
require_relative "doctor_hooks"

module QualityGate
  class DoctorRuntimeCheck
    def call
      defined?(Bundler::VERSION) ? bundled_check : unbundled_check
    rescue StandardError
      check("unchecked", "Ruby and Bundler runtime context could not be fully inspected.")
    end

    private

    def bundled_check
      context = ENV["BUNDLE_GEMFILE"] || "default bundle context"
      message = "#{ruby_message} Bundler #{Bundler::VERSION} is loaded (#{context}); no application code was run."
      check("ready", message)
    end

    def unbundled_check
      message = "#{ruby_message} Bundler is not loaded; invoke through bundle exec to inspect bundle context."
      check("unchecked", message)
    end

    def ruby_message = "Ruby #{RUBY_VERSION} at #{RbConfig.ruby}."

    def check(status, message)
      DoctorReport.check(id: "runtime", status:, message:)
    end
  end

  class DoctorConfiguration
    def initialize(config, registry:, dir:)
      @config = config
      @registry = registry
      @dir = dir
    end

    def checks
      [configuration_check, *DoctorAdapterChecks.new(config:, registry:, dir:).call]
    end

    def self.failure_checks
      [blocked_config_check, configured_default_checks]
    end

    private

    attr_reader :config, :registry, :dir

    def configuration_check
      keys = config.unknown_keys
      warning = keys.any?
      status = warning ? "warning" : "ready"
      message = configuration_message(keys, warning)
      DoctorReport.check(id: "configuration", status:, message:)
    end

    def configuration_message(keys, warning)
      return "Configuration loaded; application checks were not run." unless warning

      "Configuration loaded with unknown keys: #{keys.join(", ")}; review .quality_gate.yml."
    end

    def self.blocked_config_check
      message = "Could not load .quality_gate.yml; fix its syntax or values before rerunning Doctor."
      DoctorReport.check(id: "configuration", status: "blocked", message:)
    end

    def self.configured_default_checks
      message = "Configured adapters were not inspected because configuration could not be loaded."
      DoctorReport.check(id: "configured_checks", status: "unchecked", message:)
    end
    private_class_method :blocked_config_check, :configured_default_checks
  end

  class DoctorAdapterChecks
    GATES = %i[fast verify audit].freeze

    def initialize(config:, registry:, dir:)
      @config = config
      @registry = registry
      @launchers = DoctorLaunchers.new(dir:)
    end

    def call
      GATES.flat_map { checks_for_gate(_1) }
    end

    private

    attr_reader :config, :launchers, :registry

    def checks_for_gate(gate)
      names = config.fetch(:adapters).fetch(gate)
      return [empty_gate_check(gate)] if names.empty?

      names.map { adapter_check(gate, _1) }
    end

    def adapter_check(gate, name)
      adapter_class = registry.fetch(name) { return unknown_adapter(gate, name) }
      return simplecov_check(gate) if name == "simplecov"

      inspect_adapter(gate, name, adapter_class)
    rescue StandardError
      blocked_adapter(gate, name, "Could not safely inspect this adapter's timeout or argv configuration.")
    end

    def inspect_adapter(gate, name, adapter_class)
      adapter = adapter_class.new(config:, files: [])
      return invalid_timeout_check(gate, name) unless valid_timeout?(adapter.timeout)

      argv = name == "undercover" ? ["undercover"] : adapter.command
      launchers.check(adapter: name, gate:, argv:)
    end

    def invalid_timeout_check(gate, name)
      blocked_adapter(gate, name, "Adapter timeout must be a positive Integer.")
    end

    def simplecov_check(gate)
      return blocked_adapter(gate, "simplecov", threshold_message) unless coverage_budget?

      ready_simplecov_check(gate)
    end

    def threshold_message
      "SimpleCov requires a configured coverage threshold; add " \
        "coverage.minimum_line and/or coverage.minimum_branch."
    end

    def ready_simplecov_check(gate)
      message = "SimpleCov is internal and has a configured threshold; no external launcher is required."
      DoctorReport.check(id: "command.#{gate}.simplecov", status: "ready", message:)
    end

    def coverage_budget?
      coverage = config.fetch(:coverage)
      coverage.is_a?(Hash) && %i[minimum_line minimum_branch].any? { coverage.key?(_1) }
    end

    def valid_timeout?(timeout)
      timeout.is_a?(Integer) && timeout.positive?
    end

    def empty_gate_check(gate)
      message = "No adapters are configured for this gate."
      DoctorReport.check(id: "command.#{gate}", status: "not_applicable", message:)
    end

    def unknown_adapter(gate, name)
      blocked_adapter(gate, name, "Unknown adapter #{name}; remove it or use a registered adapter.")
    end

    def blocked_adapter(gate, name, message)
      DoctorReport.check(id: "command.#{gate}.#{name}", status: "blocked", message:)
    end
  end

  # Coordinates read-only runtime, configuration, and launch probes.
  class Doctor
    def initialize(dir:, registry:)
      @dir = File.expand_path(dir)
      @registry = registry
    end

    def call
      DoctorReport.new(checks: checks)
    rescue ConfigError
      DoctorReport.new(checks: [runtime_check, *DoctorConfiguration.failure_checks])
    rescue StandardError
      DoctorReport.new(checks: [runtime_check, doctor_failure_check])
    end

    private

    attr_reader :dir, :registry

    def checks
      config = Config.load(dir:)
      configuration_checks = DoctorConfiguration.new(config, registry:, dir:).checks
      [runtime_check, *configuration_checks, *probe_checks(config)]
    end

    def probe_checks(config)
      safe_probe("comparison") { DoctorGit.new(dir:, config:).call } +
        safe_probe("coverage") { DoctorCoverage.new(dir:, config:).call } +
        safe_probe("hooks") { DoctorHooks.new(dir:).call }
    end

    def safe_probe(id)
      yield
    rescue StandardError
      message = "This bounded observation could not be completed; inspect its local setup."
      [DoctorReport.check(id:, status: "unchecked", message:)]
    end

    def runtime_check
      DoctorRuntimeCheck.new.call
    end

    def doctor_failure_check
      message = "Doctor could not complete its bounded preflight checks."
      DoctorReport.check(id: "doctor", status: "blocked", message:)
    end
  end

  private_constant :DoctorRuntimeCheck, :DoctorConfiguration, :DoctorAdapterChecks
end
