# frozen_string_literal: true

require "test_helper"

module Acceptance
  class EvidenceDocumentationTest < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)
    DOCUMENTS = %w[README.md docs/codex.md docs/dogfood-log.md docs/incidents.md docs/releasing.md].freeze
    PRIVATE_DETAILS = %r{
      /(?:Users|home)/[^/\s]+/ |
      /private/var/folders/ |
      \b[\w-]+\.local\b |
      \b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b |
      \bDarwin\s+\d | \bmacOS\s+\d
    }ix

    def test_public_evidence_does_not_disclose_workstation_or_session_identifiers
      DOCUMENTS.each do |path|
        refute_match PRIVATE_DETAILS, File.read(File.join(ROOT, path)), "private details in #{path}"
      end
    end

    def test_validation_instructions_point_to_executable_acceptance_tests
      document = File.read(File.join(ROOT, "docs/dogfood-log.md"))

      %w[incident_catalog_test.rb latency_test.rb].each do |name|
        path = "test/acceptance/#{name}"
        assert_path_exists File.join(ROOT, path)
        assert_includes document, "bundle exec ruby -Itest #{path}"
      end
      assert_includes document, "QUALITY_GATE_ACCEPTANCE_TIMING=1"
    end

    def test_readme_links_public_evidence_and_explains_validation_limits
      document = File.read(File.join(ROOT, "README.md"))

      assert_includes document, "[incident catalogue](docs/incidents.md)"
      assert_includes document, "[validation guide](docs/dogfood-log.md)"
      assert_includes document, "do not guarantee"
    end
  end
end
