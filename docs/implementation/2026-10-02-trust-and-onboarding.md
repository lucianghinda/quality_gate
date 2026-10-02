# Trustworthy checks and onboarding implementation plan

> For implementation agents: use the Ruby test-driven-development and subagent-driven-development skills. The orchestrator owns sequencing, integration, review, and final verification. Implementers and reviewers use Luna.

**Goal:** Complete the five workstreams approved on October 2: correctness repairs, publication documentation, Rails/RSpec onboarding, optional GitHub Actions generation, and optional Herb ERB checks.

**Architecture:** Extend the existing adapters and shared installation boundary. Preserve host-owned files, default gates, normalized findings, shell-free execution, and exit meanings. Add opt-in integrations without increasing the mandatory dependency footprint.

**Base:** `8aba3b9c36dd7b60e0ea50cf5ebac18b58dfb910`, published v0.2.2.

## Decisions and boundaries

- The user approved all five proposed items, requested a document before implementation and one or more PRs, and specified Luna subagents with the leader remaining orchestrator.
- Use one feature branch and PR. The plan was written and committed before implementation; at the user's request, consolidate the completed work into one atomic delivery commit after the simplicity review. Do not modify or merge existing PR #4; port its Reek behavior onto current main, retaining the newer Fiddle dependency repair.
- Keep existing configurations and hooks compatible. Do not lower coverage/lint budgets or change default fast adapters to require Herb.
- Use Ruby standard-library utility scripts in temporary directories. New mandatory dependencies, unrelated refactoring, a version bump, gem publication, and PR merging are outside this change.
- Hook feedback can fail open; generated CI invokes the gates directly and enforces their process exit codes.
- Durable application adoption measurement remains follow-up product work. This implementation does not claim production compatibility, improved review time, or retained installations.

## Workstream 1 — repair incorrect clean results

**Files:** `lib/quality_gate/adapters/reek.rb`, `test_suite.rb`, `simplecov.rb`, `bundler_audit.rb`; their focused tests and a verify integration/runner regression where needed.

- [x] Reek: write and run a failing real-Reek temporary-project test with no selected paths and an obvious smell. Make `resolved_paths_for_command` return `["."]` only when both selected/resolved paths are empty; retain explicit selections and empty resolved explicit-selection behavior. Update the old argv assertion.
- [x] Coverage freshness: reproduce `test_suite` plus optional `simplecov` accepting an old 100% `.last_run.json` after an exit-zero command that writes no coverage. Before a test invocation whose verify configuration includes SimpleCov, invalidate only the expected aggregate summary, then require regeneration through the existing missing/unusable-report failure. Preserve `.resultset.json` and intentional host collation. File errors must become tool failures; do not add locks or change standalone summary-only configurations without a demonstrated need.
- [x] Audit completion: reproduce empty JSON with a failing process in both updated and cached bundler-audit paths. Validate normal process completion and the documented status/findings relationship: clean output requires exit 0; vulnerability output requires exit 1. Preserve cached-database fallback for an actual failed update and its warning. Signals, unsupported status, or contradictory valid JSON produce tool failures.
- [x] Run focused regressions, `quality_gate fast`, full verify, and an independent specification review followed by code-quality review. Record the decisions with Lore trailers in the delivery commit.

## Workstream 2 — publication and release documentation

**Files:** `README.md`, `docs/releasing.md`, `CHANGELOG.md` where appropriate, `llm.txt` through the existing generator.

- [x] Replace the stale unpublished/GitHub-only installation instructions with the published development/test dependency. Keep a deliberate GitHub-source alternative. Include Fiddle in the documented mandatory dependency table.
- [x] Document release-record synchronization as a release checklist step, without creating or publishing releases in this implementation.
- [x] Incorporate the final options and behavior of workstreams 3–5 after their implementation; state optional external Herb installation accurately and retain hook/CI distinctions.
- [x] Check documentation/package contracts and regenerate the existing LLM index. Do not add tests that merely assert marketing prose.

## Workstream 3 — Rails/RSpec onboarding

**Files:** `lib/quality_gate/ruby_profile.rb` or a small Rails profile reusing its support; `lib/generators/quality_gate/install/install_generator.rb`; shared installation rendering; Rails coverage/config templates; generator/profile/integration tests.

Public usage:

```sh
bin/rails generate quality_gate:install --test-framework rspec
bin/rails generate quality_gate:install --test-helper spec/rails_helper.rb --test-command 'bundle exec rspec'
```

- [x] Resolve test framework, relative helper path, and argv before any generator write. Reject invalid frameworks, escaping paths, empty commands, and ambiguous test/spec helpers before writes. Preserve the existing Rails missing-default-helper warning/other-artifact behavior for a project with no detected helper.
- [x] Share existing Ruby profile selection/validation where possible while keeping plain Ruby defaults (`bundle exec rake test`) and Rails defaults (`bin/rails test`) distinct. RSpec uses `bundle exec rspec` unless overridden.
- [x] Reflect the chosen argv in generated YAML using existing safe scalar rendering. Keep Rails audit/fast adapters intact; preserve customized config as manual conflicts.
- [x] Start coverage before executable/application loading in the selected helper; exclude both `test` and `spec`; preserve existing SimpleCov wiring, markers, directives, newline conventions, and idempotence.
- [x] Test valid Minitest/RSpec, custom helpers/commands, ambiguity and invalid input before writes, previews, reruns, conflicts, and a real RSpec run that creates coverage and detects an untested changed region. A locally installed RSpec may be used for acceptance without adding a project dependency.
- [x] Run existing Rails/Ruby installer regressions and the gates; complete specification review then code-quality review before committing.

## Workstream 4 — optional GitHub Actions generation

**Files:** `init_command.rb`, `installer.rb`, `installation.rb`, Rails install generator, `cli.rb` help, new `quality_gate_workflow.yml.tt`, installation/distribution/CLI tests.

Public usage:

```sh
bundle exec quality_gate init --ci
bin/rails generate quality_gate:install --ci
```

- [x] Add a boolean `--ci` option to both setup paths. Generate `.github/workflows/quality_gate.yml` only when selected, through the existing template-preservation boundary; reruns without `--ci` neither update nor remove a workflow.
- [x] Include `push` and `pull_request` triggers, `contents: read`, full-history checkout (`fetch-depth: 0`, `persist-credentials: false`), Ruby setup with Bundler caching, and separate direct `fast`, `verify`, and `audit` steps.
- [x] Pin the generated Ruby selector to the installing runtime's `RUBY_VERSION`; explain that projects can customize the workflow for their supported matrix, services, and environment. Do not guess database or application-secret wiring.
- [x] Test default absence, opt-in output on Ruby and Rails setup, preview, identical rerun, preserved differing workflow, preserved unrelated workflows, option help, package inclusion, and fail propagation from each generated gate step. Test full-history comparison with a changed-code PR fixture rather than treating skipped Undercover as clean.
- [x] Check official checkout/setup-ruby documentation for supported options. Review specification compliance and code quality before committing.

## Workstream 5 — optional Herb ERB checks

**Files:** new `lib/quality_gate/adapters/herb.rb`, `lib/quality_gate.rb`, CLI adapter registry, runner scope map, generated fast hook template, adapter/CLI/hook/integration tests and a documented JSON fixture.

Opt-in configuration:

```yaml
adapters:
  fast:
    - rubocop
    - herb
```

- [x] Implement the official `herb-lint --json` process contract, with an argv override under `commands.fast.herb` for hosts using another launcher such as `bundle exec herb lint`. Herb remains absent from all default adapter lists; no mandatory gem/npm dependency is added.
- [x] Scan the project root when no paths are selected. For selected paths, pass ERB files and directories; a selection of only unrelated files must not launch Herb. Honor Herb's own project configuration and exclusions rather than implementing another glob policy.
- [x] Normalize offense `filename`, `location.start.line`, `code`, `severity`, and `message`. Map `hint` to `info`. Validate the JSON object, completed scan, offense fields, and documented exit behavior; incomplete/malformed reports, failed launch, signals, unsupported exit values, and contradictory clean/error results become tool failures. Warning-only reports may legitimately exit 0 but still produce gate findings.
- [x] Account for the verified Herb 0.11.0 excluded-file envelope: an explicitly excluded file can abort even a mixed selection with exit 0, no JSON, and its specific exclusion diagnostic. Only that exact diagnostic, matched to selected ERB files, may remove inputs and retry the remaining selection. Every retry shares one timeout budget. Unknown/partial diagnostics and empty-directory failures remain tool failures. Configured `failLevel: info` or `hint` may legitimately produce exit 1 with info/hint-only findings and `clean: true`.
- [x] Add Herb to selected-file/project scope reporting. Permit ERB edits to reach the generated fast hook when configured checks include Herb; maintain cheap skips and backward-compatible Ruby feedback. Ensure RuboCop does not receive unsupported selected ERB input in a mixed fast gate.
- [x] Exercise real lint detection using the host-installed official CLI if available, plus deterministic CLI fixtures for all failure contracts. Run selected Ruby-only, ERB-only, mixed-path and exclusion tests; retain named timing tests for optional measurement rather than claiming a guarantee.
- [x] Complete specification review, then code-quality review, then the combined verification.

Official contract references: [Herb installation](https://herb-tools.dev/installation), [Herb Linter CLI/JSON](https://herb-tools.dev/projects/linter), [checkout](https://github.com/actions/checkout), [Ruby setup](https://github.com/ruby/setup-ruby).

## Cleanup constraints

No broad cleanup pass is planned. Reuse shared profile, installer, finding, timeout, and reporter boundaries. Where method extraction is needed, protect existing behavior first; make the smallest extraction needed for the new option and keep historical coverage/lint debt visible.

### Requested simplicity review

Review the completed PR changes with independent Luna reviewers for idiomatic Ruby, redundant logic, unnecessary state, and excessive abstraction. Restrict edits to demonstrated improvements in the touched code. Existing adapter, installer, hook, and integration regressions protect the behavior; add a failing regression before changing any unprotected behavior. Preserve public options, strict process/report validation, host-file safety, and existing lint/coverage budgets. Verify focused tests, fast, full verify, signatures, and package contracts after accepted changes. Consolidate delivery into one atomic commit, retaining a local backup of the prior branch and updating the remote with an explicit force-with-lease. Check hosted CI for the resulting PR head.

## Verification and delivery

Every behavioral change starts with a failing regression, then focused green tests. Run fast after Ruby edits and verify before workstream completion. The orchestrator owns final combined lint, full verify, RBS validation, package inspection, real integration smoke tests, and hosted CI for the exact PR head. Do not relax budgets to obtain green results.

Use the installed runtime explicitly because ambient executable selection can choose system Ruby:

```sh
env PATH=/Users/luciang/.rubies/ruby-4.0.1/bin:/Users/luciang/.gem/ruby/4.0.1/bin:/opt/homebrew/bin:/usr/bin:/bin bundle exec quality_gate fast
env PATH=/Users/luciang/.rubies/ruby-4.0.1/bin:/Users/luciang/.gem/ruby/4.0.1/bin:/opt/homebrew/bin:/usr/bin:/bin bundle exec quality_gate verify --format json
```

- [x] Plan committed before implementation.
- [x] Independent spec and code-quality reviews accepted all workstreams.
- [x] Combined lint, tests, diff/aggregate coverage, signatures, and package checks pass.
- [x] PR created with actual validation, changes, and remaining limits recorded.

## Progress

The plan was committed before implementation. The final PR history is consolidated into one atomic commit at the user's request.

- Publication/install/release documentation: independent specification and quality reviews accepted. Distribution and evidence-documentation checks passed.
- Correctness repairs: independent specification and quality reviews accepted. Focused adapter/integration regressions, fast lint, and full verify passed with zero findings and zero tool failures. Review added coverage for unsupported audit statuses and preserved the existing coverage summary when command/timeout validation fails.
- The repaired Bundler Audit adapter also passed a live advisory database refresh with zero findings. Brakeman requires a Rails host; this gem repository is not itself a Rails application.
- Rails/RSpec, CI setup, and optional Herb are included in the same delivery.
- Independent specification and code-quality reviews accepted Rails/RSpec, CI, Herb, and final documentation. Real RSpec verify failed on an untested changed region, then passed with Reek, tests, and Undercover clean after a spec covered it. Real Herb 0.11.0 checks confirmed root/selected/mixed findings, explicit exclusions, strict empty-directory failure, and configured info/hint thresholds.
- Final local fast and full verify passed with zero findings and zero tool failures, including diff coverage and aggregate budgets. Signatures and package checks passed; package tests reported 33 runs and 560 assertions. Missing failure-path regressions were added, and redundant/unreachable guards were deleted without relaxing budgets. Two opt-in timing tests remain intentionally skipped in ordinary runs.
- The requested idiomatic Ruby review removed Herb's mutex and shared stderr state, a parser forwarding method, duplicate count validation, and a one-use installer method/argument. Independent review accepted the simpler boundaries. Added regressions preserve report/status diagnostics, prevent stale exclusion diagnostics on retry timeout, and verify invalid-timeout failure before launch. Separate Ruby and Rails profiles remain because their helper detection and safety rules differ.

Delivery: [PR #6 — Fix gate correctness and add Rails/RSpec, CI, and Herb support](https://github.com/lucianghinda/quality_gate/pull/6). Hosted matrix results are attached to the PR; the orchestrator checks the latest head before handoff. No gem version bump, publication, or merge is part of this delivery.
