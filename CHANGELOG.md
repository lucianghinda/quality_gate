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
