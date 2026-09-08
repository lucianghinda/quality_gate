#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates a stable index of the gem's public documentation.
class LlmGenerator
  DOCUMENTS = {
    "README.md" => "README",
    "docs/codex.md" => "Codex integration",
    "docs/dogfood-log.md" => "Validation and limitations",
    "docs/incidents.md" => "Incident workflow",
    "docs/releasing.md" => "Releasing"
  }.freeze

  def initialize(root: File.expand_path("..", __dir__), stdout: $stdout, stderr: $stderr)
    @root = root
    @stdout = stdout
    @stderr = stderr
  end

  def call
    DOCUMENTS.each_key do |path|
      next if File.file?(File.join(@root, path))

      @stderr.puts "Missing #{path}"
      return false
    end

    File.write(File.join(@root, "llm.txt"), content)
    @stdout.puts "Updated llm.txt (#{DOCUMENTS.size} links)"
    true
  end

  private

  def content
    links = DOCUMENTS.map { |path, title| "- [#{title}](#{path})" }.join("\n")
    <<~MARKDOWN
      # Quality Gate

      Quality Gate provides staged Ruby code-quality checks through one CLI and
      configuration contract. See the README for installation, gate commands,
      configuration, and optional RuboCop conventions.

      ## Documentation

      #{links}
    MARKDOWN
  end
end

exit(LlmGenerator.new.call ? 0 : 1) if $PROGRAM_NAME == __FILE__
