# frozen_string_literal: true

module AgentRepairAcceptance
  class Command
    USAGE = <<~TEXT
      Usage:
        agent_repair_acceptance prepare DIRECTORY --gem ARTIFACT --client claude|codex --scenario fast|verify
        agent_repair_acceptance run DIRECTORY [--timeout SECONDS]
        agent_repair_acceptance report DIRECTORY
    TEXT

    def initialize(argv, out: $stdout, err: $stderr)
      @argv = argv.dup
      @out = out
      @err = err
    end

    def call
      action = @argv.shift
      return print_help if action.nil? || %w[help --help -h].include?(action)

      handler_for(action).call
    rescue Error, OptionParser::ParseError, JSON::ParserError, SystemCallError => e
      @err.puts "Error: #{e.message}"
      @err.puts USAGE
      2
    end

    private

    def print_help
      @out.write(USAGE)
      0
    end

    def handler_for(action)
      { "prepare" => method(:prepare), "run" => method(:run), "report" => method(:report) }
        .fetch(action) { raise Error, "unknown command #{action.inspect}" }
    end

    def prepare
      options = prepare_options
      directory = required_directory("prepare")
      manifest = Project.new(directory, **options).prepare
      @out.puts "Prepared #{manifest.fetch("client")} #{manifest.fetch("scenario")} trial at #{manifest.fetch("root")}"
      0
    end

    def prepare_options
      options = { artifact: nil, client: nil, scenario: nil }
      parser = OptionParser.new do |opts|
        opts.on("--gem PATH") { options[:artifact] = _1 }
        opts.on("--client NAME") { options[:client] = _1 }
        opts.on("--scenario NAME") { options[:scenario] = _1 }
      end
      parser.parse!(@argv)
      options
    end

    def run
      parse_run_options
      directory = required_directory("run")
      timeout = run_timeout
      receipts = evidence_root(directory)
      manifest, manifest_sha256 = manifest_snapshot(receipts)
      session_runner = Session.new(directory, timeout:)
      session_runner.validate_manifest!(manifest)
      session = session_runner.run
      persist_manifest_digest(receipts, session, manifest_sha256)
      final = final_checks(directory, receipts, manifest, manifest_sha256)
      write_json(receipts, "final.json", final)
      print_result(receipts, { "manifest" => manifest, "session" => session, "final" => final }, persist: true)
    end

    def report
      OptionParser.new.parse!(@argv)
      directory = required_directory("report")
      receipts = evidence_root(directory)
      evidence = {
        "manifest" => read_json(receipts, "manifest.json"),
        "session" => read_json(receipts, "session.json"),
        "final" => read_json(receipts, "final.json")
      }
      evidence.fetch("final")["protected_files_unchanged"] &&=
        manifest_unchanged?(receipts, evidence.dig("session", "manifest_sha256"))
      print_result(receipts, evidence, persist: false)
    end

    def required_directory(action)
      raise Error, "#{action} requires DIRECTORY" unless @argv.length == 1

      @argv.fetch(0)
    end

    def parse_run_options
      @timeout = 600
      OptionParser.new { |opts| opts.on("--timeout SECONDS", Integer) { @timeout = _1 } }.parse!(@argv)
    end

    def run_timeout
      raise Error, "timeout must be positive" unless @timeout.positive?

      @timeout
    end

    def read_json(directory, filename)
      JSON.parse(File.read(File.join(directory, filename)))
    end

    def manifest_unchanged?(directory, expected_sha256)
      expected_sha256 && Digest::SHA256.file(File.join(directory, "manifest.json")).hexdigest == expected_sha256
    end

    def evidence_root(directory)
      path = AgentRepairAcceptance.evidence_root(directory)
      raise Error, "trial evidence directory is missing: #{path}" unless path.directory?

      path
    end

    def manifest_snapshot(directory)
      bytes = File.binread(File.join(directory, "manifest.json"))
      [JSON.parse(bytes), Digest::SHA256.hexdigest(bytes)]
    end

    def persist_manifest_digest(directory, session, digest)
      return unless session

      session["manifest_sha256"] = digest
      write_json(directory, "session.json", session)
    end

    def final_checks(directory, receipts, manifest, manifest_sha256)
      ProjectRunner.new(directory, manifest).final_checks.tap do |final|
        final["protected_files_unchanged"] &&= manifest_unchanged?(receipts, manifest_sha256)
      end
    end

    def write_json(directory, filename, value)
      File.write(File.join(directory, filename), "#{JSON.pretty_generate(value)}\n")
    end

    def print_result(directory, evidence, persist:)
      result = evaluate(directory, evidence)
      write_json(directory, "report.json", result) if persist
      @out.puts JSON.pretty_generate(result)
      Evidence.exit_status(result)
    end

    def evaluate(directory, evidence)
      Evidence.new(evidence.merge("hooks" => read_hooks(directory))).call
    end

    def read_hooks(directory)
      path = File.join(directory, "hooks.jsonl")
      return [] unless File.file?(path)

      File.readlines(path).filter_map { JSON.parse(_1) }
    end
  end
end
