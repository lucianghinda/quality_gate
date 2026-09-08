# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "stringio"
require "tmpdir"
require_relative "../../bin/generate_llm"

class LlmGeneratorTest < Minitest::Test
  def test_generates_only_curated_relative_links
    with_documents do |root|
      generator = LlmGenerator.new(root: root, stdout: StringIO.new)

      assert generator.call
      content = File.read(File.join(root, "llm.txt"))
      assert_documentation_index(content)
      refute_includes content, root
      refute_includes content, "private"
    end
  end

  def test_generation_is_idempotent
    with_documents do |root|
      generator = LlmGenerator.new(root: root, stdout: StringIO.new)
      assert generator.call
      content = File.read(File.join(root, "llm.txt"))
      assert generator.call
      assert_equal content, File.read(File.join(root, "llm.txt"))
    end
  end

  def test_missing_document_preserves_existing_output
    with_documents do |root|
      File.delete(File.join(root, "docs/incidents.md"))
      File.write(File.join(root, "llm.txt"), "previous output")
      stderr = StringIO.new

      refute LlmGenerator.new(root: root, stderr: stderr).call
      assert_includes stderr.string, "Missing docs/incidents.md"
      assert_equal "previous output", File.read(File.join(root, "llm.txt"))
    end
  end

  private

  def assert_documentation_index(content)
    assert_includes content, "# Quality Gate"
    assert_includes content, "[README](README.md)"
    assert_includes content, "[Releasing](docs/releasing.md)"
    assert_equal 5, content.scan(/^- \[/).size
  end

  def with_documents
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "docs"))
      %w[README.md docs/codex.md docs/incidents.md docs/dogfood-log.md docs/releasing.md].each do |path|
        File.write(File.join(root, path), "# Public documentation\n")
      end
      File.write(File.join(root, "docs/private.md"), "Private material")
      yield root
    end
  end
end
