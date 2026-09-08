# frozen_string_literal: true

require "test_helper"
require "yaml"

module QualityGate
  # The gem is linted by the configuration it ships. Structural debt that predates
  # the Sandi Metz budgets is frozen per file in .rubocop_todo.yml so new code has
  # to meet them. The ratchet may only shrink; these tests keep it that shape.
  class DogfoodRatchetTest < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)
    RATCHET = File.join(ROOT, ".rubocop_todo.yml")
    PROJECT_CONFIG = File.join(ROOT, ".rubocop.yml")

    def setup
      @ratchet = YAML.safe_load_file(RATCHET)
    end

    def test_the_project_inherits_the_shipped_budgets_and_then_the_ratchet
      config = YAML.safe_load_file(PROJECT_CONFIG)

      assert_equal ["config/rubocop.yml", ".rubocop_todo.yml"], config.fetch("inherit_from")
    end

    # Without merged Exclude the project config would replace the ratchet's file
    # lists instead of adding to them, silently unfreezing every entry.
    def test_exclude_lists_merge_across_the_inherited_files
      config = YAML.safe_load_file(PROJECT_CONFIG)

      assert_includes config.fetch("inherit_mode").fetch("merge"), "Exclude"
    end

    def test_the_ratchet_freezes_nothing_but_structural_budgets
      non_metrics = @ratchet.keys.reject { |cop| cop.start_with?("Metrics/") }

      assert_empty non_metrics, "fix these rather than freezing them"
    end

    # A raised Max would relax the budget for every file at once.
    def test_the_ratchet_excludes_files_and_never_raises_a_budget
      @ratchet.each { |cop, settings| assert_equal ["Exclude"], settings.keys, cop }
    end

    def test_every_frozen_path_still_exists
      missing = frozen_paths.reject { |path| File.exist?(File.join(ROOT, path)) }

      assert_empty missing, "stale entries; regenerate .rubocop_todo.yml"
    end

    def test_the_gem_ships_no_frozen_paths_it_does_not_own
      strays = frozen_paths.reject { |path| path.start_with?("lib/", "test/") }

      assert_empty strays
    end

    private

    def frozen_paths = @ratchet.values.flat_map { |settings| settings.fetch("Exclude") }.uniq
  end
end
