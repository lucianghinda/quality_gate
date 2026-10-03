# frozen_string_literal: true

module QualityGate
  # Applies one baseline operation to a completed adapter result.
  class BaselineRun
    def initialize(operation:, gate:, tools:)
      @operation = operation
      @gate = gate
      @tools = tools.map(&:to_s).freeze
    end

    def call(result)
      snapshot, match = snapshot_and_match(result)
      apply(result, snapshot, match)
    rescue BaselineError, SystemCallError, IOError => e
      result.with(findings: result.findings + [Finding.tool_failure(tool: "baseline", message: e.message)])
    end

    private

    attr_reader :operation, :gate, :tools

    def snapshot_and_match(result)
      snapshot = snapshot_for(result)
      snapshot.validate_context!(gate:, tools:) unless operation.fetch(:mode) == :create
      [snapshot, snapshot.match(result.findings, root: operation.fetch(:root))]
    end

    def snapshot_for(result)
      return Baseline.read(operation.fetch(:path)) unless operation.fetch(:mode) == :create

      Baseline.capture(gate:, tools:, findings: result.findings, root: operation.fetch(:root))
    end

    def apply(result, snapshot, match)
      mode = operation.fetch(:mode)
      return compare(result, match) if mode == :compare
      return create(result, snapshot, match) if mode == :create
      return ratchet(result, snapshot, match) if mode == :ratchet

      raise BaselineError, "unsupported baseline mode #{mode}"
    end

    def compare(result, match)
      result.with(findings: match.findings, baseline: metadata(:compare, match.accepted))
    end

    def create(result, snapshot, match)
      return blocked(result, :create, match) if match.findings.any?

      snapshot.write(operation.fetch(:path), create: true)
      result.with(findings: match.findings, baseline: metadata(:create, match.accepted, written: true))
    end

    def ratchet(result, snapshot, match)
      return blocked(result, :ratchet, match) if match.findings.any?

      removed = write_reduced_snapshot(result, snapshot)
      result.with(findings: match.findings, baseline: metadata(:ratchet, match.accepted, removed:, written: true))
    end

    def write_reduced_snapshot(result, snapshot)
      reduced = Baseline.capture(gate:, tools:, findings: result.findings, root: operation.fetch(:root))
      reduced.write(operation.fetch(:path), create: false)
      snapshot.count - reduced.count
    end

    def blocked(result, mode, match)
      findings = mode == :ratchet ? match.findings : result.findings
      result.with(findings:, baseline: metadata(mode, match.accepted, status: "blocked"))
    end

    def metadata(mode, accepted, options = {})
      { mode:, status: options.fetch(:status, "applied"), accepted_findings: accepted,
        accepted_count: accepted.length, removed_count: options.fetch(:removed, 0),
        written: options.fetch(:written, false) }
    end
  end
  private_constant :BaselineRun
end
