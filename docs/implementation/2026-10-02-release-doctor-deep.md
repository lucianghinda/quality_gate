# Doctor and deep adapters release preparation plan

Date: October 2, 2026. Base: `dbba472ff4cbd9e0c27458a189fa29c54e8467ea`.
Worktree: `.worktrees/release-doctor-deep`; branch: `codex/release-doctor-deep`.

**Goal:** prepare the next release containing read-only Doctor and the optional RubyCritic/Debride deep adapters, with a verified local package and one review PR.

**Target:** proposed 0.3.0, following 0.2.3. The version preference was requested; absent a different preference, the new public commands warrant this minor increment. The dated changelog is a release-preparation record, not a claim of RubyGems publication.

**Architecture:** reuse the existing release scripts, curated Markdown index, gemspec packaging and acceptance suite. Change release records/documentation rather than runtime behavior. Keep optional analyzer dependencies, gate defaults, generated hooks/workflows, coverage and lint policy unchanged.

**Tech stack:** existing Ruby >= 3.2 tooling, standard-library release/package scripts and installed development dependencies. No YARD, new gems or release pipeline changes.

## Scope and decisions

The merged source includes Doctor (PR #8), RubyCritic (PR #9) and Debride (PR #10). Latest GitHub release remains v0.2.3. User authorized release preparation, with Luna subagents and leader integration carried forward. Stop delivery at an atomic preparation PR and local artifact; tags, GitHub release creation and RubyGems publication are separate maintainer actions.

The generic gem-release-ready audit flags missing YARD configuration, doc gems/tasks and `llms.txt` packaging. This repository deliberately uses curated Markdown and `llm.txt`, and already has tested `bin/prepare_release` / `bin/generate_llm.rb`. Reuse that contract instead of expanding dependencies. The existing release script runs tests, RuboCop, regenerates the index and builds the gem; separately run QualityGate verify for Undercover and aggregate budgets.

The tracked LLM index contains hand-written deep/unreleased prose that its generator does not emit. Regenerate it using the unchanged script; retain the five public links and keep feature guidance in README. Correct the README's stale 0.2.2/Rails/RSpec/CI/Herb unreleased paragraph as well as Doctor/deep status. Do not claim the candidate is published.

Public-distribution check: the RubyGems API still reports 0.2.2, while GitHub's latest release is v0.2.3. Keep these distribution statuses distinct. The candidate also includes the v0.2.3 Rails/RSpec/CI/Herb changes, which remain unavailable from the current RubyGems artifact.

## Task 1 — Release records and documentation

Owner: Luna author. Files: `lib/quality_gate/version.rb`, `CHANGELOG.md`, `README.md`, generated `llm.txt`.

- [x] Set `QualityGate::VERSION = "0.3.0"`; gemspec already derives this value.
- [x] Move the existing approved Doctor/RubyCritic/Debride changelog bullets into `## [0.3.0] - 2026-10-02`; preserve historical entries and an empty Unreleased heading.
- [x] Make Doctor/deep version availability explicit, remove upcoming/unreleased labels for this candidate's functionality, and retain optional installation, manual scope, failure semantics and analyzer limitations. Distinguish earlier features' GitHub v0.2.3 availability from RubyGems 0.2.2 without claiming 0.3.0 is live.
- [x] Run unchanged `bin/generate_llm.rb`, inspect the removal of hand-written stale status text, and check deterministic regeneration.
- [x] Use existing version/release/distribution/documentation tests; no new tests for simple version or prose changes. Run focused tests/lint, then freeze. No commits/full coverage from authors.

## Task 2 — Independent review and package verification

Owner: leader, with independent read-only Luna specification and simplicity reviews.

- [x] Isolated baseline full verify passed: tests, Undercover, SimpleCov clean; zero findings/tool failures. Local dependencies resolved only from installed gems using `bundle lock --local`.
- [x] Confirm version/changelog/gemspec/package agreement and publication wording; review minimality and generated content.
- [x] Run `bin/prepare_release` through the existing real pipeline. Stop on failure, fix the observed issue, rerun the affected prerequisite; record any justified follow-up.
- [x] After sources freeze, stage new files and run fast, RBS validation and full verify. Preserve 96% line / 83% branch budgets and lint ratchet.
- [x] Inspect the actual built archive for Doctor, both adapters/helpers, executable, signatures, public docs/config, and absence of private plans/logs/local paths.
- [x] Install the actual package locally into a unique temporary GEM_HOME, without fetching/installing dependencies. Use only already installed runtime gems; verify installed version/help, Doctor read-only output and structured deep missing-tool/candidate behavior in temporary fixtures. Report that this is local-artifact acceptance rather than public-distribution evidence.

## Delivery protocol

One atomic Lore commit and separate PR against main. Verify hosted Ruby 3.2/4.0.1/4.0.6 checks on the exact head. Preserve the ignored local package with a SHA256 receipt tied to the source commit; after source commit, confirm the built payload's bytes match the committed file contents. Update the workspace roadmap and remove temporary scripts/install fixtures. PR review provides the concrete changelog for maintainer approval. This task creates no tag, hosted release or RubyGems publication.

Post-commit PR/CI and artifact receipt evidence belongs in the PR and workspace roadmap; local verification evidence will be recorded here before committing.

## Local verification notes

Luna focused tests passed: distribution 33 runs / 616 assertions, LLM generator 3 / 19, release preparer 3 / 17. Scoped RuboCop and deterministic index regeneration passed. No dedicated release-record test exists; existing tests already cover version-derived packaging and release behavior. Independent specification review approved the final publication wording; the simplicity review found no additional abstraction or Ruby changes needed.

The real preparation pipeline passed 966 tests / 7,452 assertions, with no failures/errors and two existing skips, followed by clean RuboCop on 120 files, index generation and a local 0.3.0 build. Fast and RBS validation passed. The gemspec emitted its existing shared homepage/source URI warning; no packaging error occurred.

The first post-edit verify run passed tests and aggregate coverage but Undercover rejected a stale index/worktree diff (`file changed before we could read it`) after documentation was updated during verification. Restaging and freezing the final documentation resolved it. The final full verify passed test suite, Undercover and SimpleCov with zero findings or tool failures; budgets and policies are unchanged.

After the final publication wording correction, the unchanged release builder rebuilt `pkg/quality_gate-0.3.0.gem`. Archive inspection found 78 public files, including Doctor and both adapter/parser pairs, with no internal plans, tests, development scripts or local configuration. Isolated local installation passed version and Doctor/deep help, unchanged project files after Doctor, both optional analyzers' missing-launcher exit 2 and normalized synthetic candidate exit 1. Doctor returned exit 1 with one ready and one unchecked check (bundle context unavailable in the temporary fixture), no blockers/warnings, and six inapplicable checks. This does not establish application readiness or public-distribution acceptance. No dependencies were fetched or installed beyond the local QualityGate artifact.

Local artifact SHA256: `dd2b83e745d5cfcc8b8e959b0df832f0e3bc198cbf2488664fc0d68c4f190e3b`. The ignored post-commit receipt will bind this artifact to the reviewed source commit after comparing every payload file's bytes to Git. Independent Luna specification and simplicity reviews approved the final source diff. No runtime behavior changed; simplification removes the hand-written index paragraph and preserves the unchanged generator as its source.
