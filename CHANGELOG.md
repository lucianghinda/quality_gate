## [Unreleased]

- Add opt-in fast/verify warning baselines with comparison, create, and shrink-only ratchet modes; protected findings and tool failures remain enforced.
- Treat RuboCop process errors and Reek source-processing diagnostics as tool failures even when their JSON output is valid and empty.
- Add opt-in Codex patch feedback after native `apply_patch` calls while retaining full Stop verification.
- Add an opt-in native Codex Stop verification hook for plain Ruby and Rails installs.

## [0.3.0] - 2026-10-02

- Add `quality_gate doctor` for read-only setup preflight checks with text or JSON output.
- Add an optional, explicitly invoked RubyCritic-backed `deep` gate for project-wide design analysis. RubyCritic remains a host-project dependency; the gate does not add a score budget or generated hooks/workflows.
- Add optional Debride support to the manual, project-wide `deep` gate for potentially unused method candidates. Debride remains a host-project dependency; the existing RubyCritic default and generated hooks/workflows are unchanged.

## [0.2.3] - 2026-10-02

- Reek scans the project when a bare gate invocation has no selected paths.
- When SimpleCov is enabled in verify, its aggregate summary must come from the current test run.
- bundler-audit treats abnormal process exits and status/report conflicts as tool failures.
- Rails setup can select Minitest or RSpec, a helper, and a test command.
- The optional Herb adapter adds ERB checks without changing fast-gate defaults.
- Ruby and Rails setup can opt in to a full-history GitHub Actions workflow with separate gate steps.

## [0.2.2] - 2026-09-28

- Fiddle is now a runtime dependency, so the installer loads it with a plain `require` on Ruby 4.x under Bundler. This removes the runtime `Kernel#require` patch and the hand-built extension path that missed on hosts where RbConfig and RubyGems spell the platform differently (for example `arm64-darwin25` vs `arm64-darwin-25`).

## [0.2.1] - 2026-09-22

- Undercover reports stale coverage as an actionable `stale_coverage` finding with gate exit 1, telling operators to re-run the test suite before the coverage gate, instead of a parse failure with exit 2. Unknown validation reasons also fail closed and include their value; malformed output and CLI exit-status checks remain strict.

## [0.2.0] - 2026-09-21

- Gate commands accept `--format markdown` and `format: markdown`, printing a heading with the tally, a checks table, and a findings list for agents and pull request comments.
- Undercover falls back to `origin/main` or `origin/master` when `origin/HEAD` and the local default branch are absent, so verify checks the diff on CI pull request checkouts instead of skipping. A missing default branch is now reported as missing rather than as a detached checkout.
- The repository's own `.undercover` keeps Undercover's default test exclusions next to the version file exclusion.

## [0.1.1] - 2026-09-10

- Text gate output now lists each tool that ran with its status, scope, and duration, so a clean run is distinguishable from a run where nothing executed.
- The installer no longer injects a coverage block into a test helper that already calls `SimpleCov.start`; it reports the skip and names what to confirm.

## [0.1.0] - 2026-09-08

- Layered fast, verify, and audit gates with structured findings for Ruby projects.
- RuboCop, Reek, test-suite, coverage, and security-tool integrations.
- Rails installer and agent hooks with host-owned configuration support.
- Plain Ruby setup with Minitest/RSpec detection, command overrides, coverage wiring, preview, and a Ruby RuboCop preset.
- Opt-in Claude hooks and agent contracts for Ruby and Rails projects.
- Command help, structured JSON input errors, and per-check status, scope, and timing metadata.
- Selected-path validation, severity and multiline diagnostics, and complete failed-test output retained in local logs.
- Gradual adoption using existing tool configuration and explicit adapter selection.
- Four optional Rails convention cops and a 37signals RuboCop preset.
- Sandi Metz's four rules in the shipped config: method, class, and parameter budgets, plus a `QualityGate/ControllerInstanceVariables` cop for the one-object controller action.
- The gem lints itself with the config it ships, with pre-existing structural debt frozen in `.rubocop_todo.yml`.
- Local release preparation and generated LLM documentation index.
