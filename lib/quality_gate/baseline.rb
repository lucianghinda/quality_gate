# frozen_string_literal: true

require "json"
require "tempfile"

module QualityGate
  class BaselineError < Error; end

  module BaselineSchema
    VERSION = 1
    GATES = %w[fast verify].freeze
    TOOLS = %w[rubocop reek herb].freeze
    ROOT_KEYS = %w[schema_version gate tools findings].freeze
    ENTRY_KEYS = %w[tool file rule severity message count].freeze
    private_constant :VERSION, :GATES, :TOOLS, :ROOT_KEYS, :ENTRY_KEYS

    module_function

    def validate(document)
      validate_root(document)
      validate_entries(document)
    end

    def validate_root(document)
      validate_root_keys(document)
      validate_gate(document["gate"])
      validate_context_tools(document["tools"])
    end

    def validate_root_keys(document)
      valid = document.is_a?(Hash) && keys_match?(document, ROOT_KEYS)
      invalid("document must have exactly the snapshot keys") unless valid
      version = document["schema_version"]
      invalid("unsupported schema version") unless version.is_a?(Integer) && version == VERSION
    end

    def validate_gate(gate)
      invalid("gate must be fast or verify") unless GATES.include?(gate)
    end

    def validate_context_tools(tools)
      validate_tools(tools)
      invalid("at least one eligible analyzer is required") unless analyzer?(tools)
    end

    def validate_entries(document)
      entries = document["findings"]
      invalid("findings must be an array") unless entries.is_a?(Array)
      entries.each { validate_entry(_1, document["tools"]) }
      identities = entries.map { identity(_1) }
      invalid("duplicate finding identity") unless identities.uniq == identities
    end

    def validate_entry(entry, tools)
      valid = entry.is_a?(Hash) && keys_match?(entry, ENTRY_KEYS)
      invalid("finding entry must have exactly the entry keys") unless valid
      invalid("finding tool is invalid") unless TOOLS.include?(entry["tool"]) && tools.include?(entry["tool"])
      invalid("finding file is not canonical") unless BaselinePaths.stored?(entry["file"])
      validate_entry_fields(entry)
    end

    def validate_entry_fields(entry)
      invalid("finding rule must be a non-empty string") unless nonempty_string?(entry["rule"])
      invalid("tool failure findings cannot be stored") if entry["rule"] == "tool_failure"
      invalid("finding severity must be warning or info") unless %w[warning info].include?(entry["severity"])
      invalid("finding message must be a string") unless entry["message"].is_a?(String)
      validate_count(entry["count"])
    end

    def validate_count(count)
      invalid("finding count must be a positive integer") unless count.is_a?(Integer) && count.positive?
    end

    def validate_context(gate, tools)
      validate_gate(gate)
      validate_context_tools(tools)
    end

    def validate_tools(tools)
      valid = tools.is_a?(Array) && tools.all? { nonempty_string?(_1) } && tools.uniq == tools
      invalid("tools must be an array of unique non-empty strings") unless valid
    end

    def identity(entry) = ENTRY_KEYS.first(5).map { entry.fetch(_1) }

    def eligible?(finding)
      TOOLS.include?(finding.tool) && %i[warning info].include?(finding.severity) && !finding.tool_failure?
    end

    def nonempty_string?(value) = value.is_a?(String) && !value.empty?

    def analyzer?(tools) = tools.any? { TOOLS.include?(_1) }

    def keys_match?(hash, keys) = hash.keys.all? { _1.is_a?(String) } && hash.keys.sort == keys.sort

    def invalid(message) = raise(BaselineError, message)
  end

  module BaselinePaths
    module_function

    def canonical(file, root)
      return unless file.is_a?(String) && !file.empty?

      project = File.expand_path(root)
      relative_path(file, project)
    rescue ArgumentError, TypeError => e
      raise BaselineError, "invalid project root or finding path: #{e.message}"
    end

    def relative_path(file, project)
      absolute = File.expand_path(file, project)
      prefix = project.end_with?(File::SEPARATOR) ? project : "#{project}#{File::SEPARATOR}"
      absolute.delete_prefix(prefix) if absolute.start_with?(prefix)
    end

    def stored?(file)
      return false unless file.is_a?(String) && !file.empty?

      !file.start_with?(File::SEPARATOR) && !file.include?("\0") && canonical_segments?(file)
    end

    def canonical_segments?(file)
      segments = file.split(File::SEPARATOR)
      valid = !segments.include?("..") && segments.none? { |part| part.empty? || part == "." }
      valid && segments.join(File::SEPARATOR) == file
    end
  end

  module BaselinePersistence
    module_function

    def read(path)
      Baseline.from_h(JSON.parse(File.read(path)))
    rescue JSON::ParserError, SystemCallError, IOError => e
      raise BaselineError, "cannot read baseline: #{e.message}"
    end

    def write(path, document, create:)
      bytes = serialize(document)
      create ? create_file(path, bytes) : replace_file(path, bytes)
    rescue SystemCallError, IOError, JSON::GeneratorError => e
      raise BaselineError, "cannot write baseline: #{e.message}"
    end

    def serialize(document) = "#{JSON.pretty_generate(document, indent: "  ")}\n"

    def create_file(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL) { _1.write(bytes) }
    end

    def replace_file(path, bytes) = replace_with_mode(path, bytes, file_mode(path))

    def file_mode(path) = File.stat(path).mode & 0o777

    def replace_with_mode(path, bytes, mode)
      Tempfile.create([".quality-gate-baseline-", ".tmp"], File.dirname(path)) do |file|
        write_temp(file, bytes, mode)
        File.rename(file.path, path)
      end
    end

    def write_temp(file, bytes, mode)
      file.write(bytes)
      file.flush
      File.chmod(mode, file.path)
    end
  end

  class Baseline
    Match = Data.define(:findings, :accepted)
    private_constant :Match

    def self.capture(gate:, tools:, findings:, root:)
      BaselineSchema.validate_context(gate, tools)
      new(gate:, tools:, entries: capture_entries(findings, root, tools))
    end

    def self.read(path) = BaselinePersistence.read(path)

    def self.from_h(document)
      BaselineSchema.validate(document)
      new(gate: document.fetch("gate"), tools: document.fetch("tools"), entries: document.fetch("findings"))
    end

    def self.capture_entries(findings, root, tools)
      raise BaselineError, "findings must be an array" unless findings.is_a?(Array)

      counts = Hash.new(0)
      findings.each { increment_count(counts, _1, root, tools) }
      counts.sort.map { entry_from(_1) }
    end

    def self.increment_count(counts, finding, root, tools)
      return unless tools.include?(finding.tool) && BaselineSchema.eligible?(finding)

      file = BaselinePaths.canonical(finding.file, root)
      return unless file

      counts[[finding.tool, file, finding.rule, finding.severity.to_s, finding.message]] += 1
    end

    def self.entry_from(pair)
      key, count = pair
      Hash[%w[tool file rule severity message].zip(key).push(["count", count])]
    end
    private_class_method :capture_entries, :increment_count, :entry_from

    def initialize(gate:, tools:, entries:)
      BaselineSchema.validate(snapshot_document(gate, tools, entries))
      @gate = gate.dup.freeze
      @tools = tools.map { _1.dup.freeze }.freeze
      @entries = entries.sort_by { BaselineSchema.identity(_1) }.map { copy_entry(_1) }.freeze
      freeze
    end

    def validate_context!(gate:, tools:)
      BaselineSchema.validate_context(gate, tools)
      raise BaselineError, "baseline gate does not match configured gate" unless gate == @gate
      raise BaselineError, "baseline tools do not match configured tools" unless tools == @tools

      self
    end

    def match(findings, root:)
      remaining = @entries.to_h { [BaselineSchema.identity(_1), _1.fetch("count")] }
      lists = [[], []]
      findings.each { consume(_1, root, remaining, lists) }
      Match.new(findings: lists.last.freeze, accepted: lists.first.freeze)
    end

    def write(path, create:) = BaselinePersistence.write(path, to_h, create:)
    def count = @entries.sum { _1.fetch("count") }

    def to_h
      { "schema_version" => 1, "gate" => @gate.dup, "tools" => @tools.map(&:dup),
        "findings" => @entries.map { copy_entry(_1, frozen: false) } }
    end

    private

    def snapshot_document(gate, tools, entries)
      { "schema_version" => 1, "gate" => gate, "tools" => tools, "findings" => entries }
    end

    def consume(finding, root, remaining, lists)
      identity = match_identity(finding, root)
      accepted = identity && remaining.fetch(identity, 0).positive?
      list = accepted ? lists.first : lists.last
      remaining[identity] -= 1 if accepted
      list << finding
    end

    def match_identity(finding, root)
      return unless BaselineSchema.eligible?(finding)

      file = BaselinePaths.canonical(finding.file, root)
      [finding.tool, file, finding.rule, finding.severity.to_s, finding.message] if file
    end

    def copy_entry(entry, frozen: true)
      copy = entry.transform_values { _1.is_a?(String) ? _1.dup : _1 }
      copy.each_value(&:freeze) if frozen
      frozen ? copy.freeze : copy
    end
  end

  private_constant :BaselineSchema, :BaselinePaths, :BaselinePersistence
end
