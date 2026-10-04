# Optional database consistency audit implementation plan

> Use Luna subagents for implementation, then independent specification and Ruby simplicity reviews. The orchestrator owns integration and final verification. Keep one atomic Lore commit and one PR.

**Goal:** Add opt-in Active Record/database consistency findings to `quality_gate audit`, without adding a dependency to quality_gate or enabling application/database checks in default hooks.

**Architecture:** Run a bundled Ruby bridge in a separate process using the existing adapter capture/timeout boundary. Boot the Rails application and collect the released analyzer's structured reports; normalize them through the existing Finding/reporters/exit-code contract. Keep configuration in the existing `adapters.audit`, `commands.audit`, `timeouts`, and upstream `.database_consistency.yml` contracts.

**Tech stack:** Ruby standard library, existing quality_gate infrastructure, project-provided `database_consistency ~> 3.0.14`. Acceptance uses real 3.0.14, Rails/Active Record and SQLite in an isolated temporary fixture.

## Verified upstream contract and decisions

- RubyGems metadata identifies 3.0.14 as the current released analyzer on October 3, 2026. Its only runtime dependency is Active Record. The exact unpacked release was inspected before implementation.
- The [CLI](https://github.com/djezzzl/database_consistency/blob/master/bin/database_consistency) has no JSON option. Do not invent `--json` or parse human text that mixes findings and boot diagnostics.
- Use `DatabaseConsistency::Configuration.new` and `DatabaseConsistency::Processors.reports(configuration)`, then read the six named public report attributes explicitly, plus `source_location` when the report responds to that reader. Real 3.0.14 acceptance exposed an upstream `ReportBuilder#to_h` defect: it uses attribute values as keys instead of field names. Do not use `to_h`, inspect instance variables, or patch upstream. Support the tested release line `>= 3.0.14, < 3.1`; fail visibly outside that range because this is an internal upstream API.
- Report keys include `checker_name`, `table_or_model_name`, `column_or_attribute_name`, `status`, `error_slug`, `error_message`; subclasses add fields. Status is `ok`, `warning`, or `fail`. Discard `ok` after validating its status/shape; normalize `fail` as error and `warning` as warning. quality_gate enforces warning findings even though upstream's ordinary exit code ignores them.
- Most reports have no source location. Use file `""`, line `0`; do not infer a model filename. Upstream 3.0.14's `source_location` is a `"path:line"` String, not a pair. Parse the final colon using an anchored pattern, validate nonempty path and positive integer line, and preserve the supplied path (including embedded colons).
- A finding's rule is its checker name. Its message retains model/table and column/attribute context and upstream error text, falling back to the human-readable error slug when the upstream message is nil. Do not duplicate upstream checker logic or maintain a message-template registry.
- Processors/checkers swallow some exceptions and call `RescueError`; check `RescueError.empty?` before publishing reports. A swallowed exception must produce tool failure, never a clean empty scan. Upstream may write a timestamped diagnostics file on these errors; the adapter does not call autofix, migration generation or TODO writers. Application boot and custom checkers retain their normal side effects.
- Redirect Ruby application/analyzer stdout to stderr while collecting reports, then emit one JSON envelope on the original output stream. Valid report + normal exit 0 is the bridge success contract, regardless of whether reports contain findings. Bridge errors exit 2. Parent validates process completion and report structure; human stdout cannot substitute for a structured completed report. Normal boot/configuration diagnostics on stderr are permitted.
- The default command uses `RbConfig.ruby` and the packaged absolute bridge path. `commands.audit.database_consistency` overrides the Ruby launcher prefix, to which the bridge path is appended; it is not an upstream CLI override. Honor the current project bundle and environment; do not choose a different database or change `RAILS_ENV`.
- Ignore `--files` after normal CLI input validation; this is a project-wide check. Runner metadata reports project scope and no requested-file selection. No baseline support, default adapter changes, installer flags, trust changes, version bump, new dependencies, or active_record_doctor adapter.
- Doctor may inspect the Ruby launcher/bridge without booting application code; launcher readiness is not proof of analyzer installation, a usable database, or successful checks. State this limitation in docs.

Primary references: [release](https://rubygems.org/gems/database_consistency/versions/3.0.14), [report API](https://github.com/djezzzl/database_consistency/blob/master/lib/database_consistency/report.rb), [processor API](https://github.com/djezzzl/database_consistency/blob/master/lib/database_consistency/processors/base_processor.rb), [rescued errors](https://github.com/djezzzl/database_consistency/blob/master/lib/database_consistency/rescue_error.rb).

Bridge envelope example (normal process exit 0):

```json
{"version":1,"analyzer_version":"3.0.14","reports":[{"checker_name":"MissingUniqueIndexChecker","table_or_model_name":"User","column_or_attribute_name":"email","status":"fail","error_slug":"missing_unique_index","error_message":null}]}
```

This becomes an error finding with rule `MissingUniqueIndexChecker`, empty file, line 0, and message `User email: missing unique index`. `reports: []` is valid if collection completed without rescued errors. Reject unknown envelope versions, malformed report arrays/entries, unsupported analyzer versions and missing required report members; tolerate checker-specific extra members. Nullable context fields remain nullable rather than becoming fabricated source locations.

## Tasks and ownership

### 1. Bridge and adapter (Luna implementation)

Create `lib/quality_gate/database_consistency_runner.rb`, `lib/quality_gate/adapters/database_consistency.rb` and a small report normalizer if needed to meet existing method/class budgets. Add focused tests in `test/quality_gate/database_consistency_runner_test.rb` and `test/quality_gate/adapters/database_consistency_test.rb`. Extend `sig/quality_gate.rbs` for the new public surface. Do not add lint exceptions or relax budgets.

A separate Luna test agent owns `test/quality_gate/database_consistency_bridge_test.rb` only: direct public bridge-run tests protect report serialization, output restoration and error handling in the coverage-collecting process, complementing subprocess integration tests. It does not edit implementation or other tests.

- [x] Write and run failing tests for clean/fail/warning reports, missing locations, real locations, malformed envelopes/statuses/fields, unsupported version, missing executable, signal/nonzero exit, timeout and diagnostics retention.
- [x] Implement the bridge with Bundler setup, Rails `config/boot` and `config/environment` loading, `Rails.application.eager_load!`, version check, configuration/report collection, explicit named-reader serialization and rescued-error rejection. Do not eager-load unrelated registered Zeitwerk loaders; nonstandard loaders need application wiring. Keep optional analyzer loading out of ordinary `require "quality_gate"`.
- [x] Test bridge entry point in real subprocesses with controlled fake app/analyzer fixtures: missing app/analyzer, boot failure, report collection, swallowed scan error, unsupported version, and chatter separation. Avoid test-only production methods.
- [x] Run focused tests and `bundle exec quality_gate fast`; report red/green evidence and remaining concerns. Do not commit.

### 2. Dispatch, reporting and documentation (Luna integration)

Modify `lib/quality_gate.rb`, `lib/quality_gate/cli.rb`, `lib/quality_gate/runner.rb`, `README.md` and generated `llm.txt`. Add `test/quality_gate/database_consistency_integration_test.rb`; update the exact shipped registry expectation in `test/quality_gate/cli_test.rb`, the public-file contract in `test/quality_gate/distribution_test.rb`, and relevant Doctor tests if needed. Defaults and dependency files remain unchanged.

- [x] Test CLI audit clean/findings/tool failure through text/JSON/Markdown; assert project scope, ignored valid file selection, configured adapter order, missing optional analyzer diagnostics, launcher/timeout overrides and unchanged defaults.
- [x] Register the adapter and add project scope. Document optional project Gemfile entry `gem "database_consistency", "~> 3.0.14", group: :development, require: false` and audit configuration retaining existing security adapters. Explain boot/database prerequisites, stdout protocol, command override prefix and Doctor limitations.
- [x] Regenerate `llm.txt` using the existing docs generator and run focused integration/documentation tests and fast. Do not commit.

### 3. Reviews and completion (orchestrator + independent Luna reviews)

- [x] Independent specification review against this plan; fix findings before independent Ruby simplicity review. Document a bounded cleanup plan before any review-driven refactoring; use protected behavior and prefer deletion/reuse.
- [x] Stage new files for diff coverage, run `bundle exec quality_gate fast`, full `bundle exec quality_gate verify`, and `bundle exec rbs -I sig validate`; resolve all findings with unchanged coverage budgets.
- [x] Build and install the packaged gem into a temporary fixture. Exercise actual analyzer 3.0.14 against Rails/SQLite: missing uniqueness index then repaired clean, missing FK, presence/null mismatch, actual warning, missing analyzer/app, unavailable database, invalid upstream config and swallowed checker error. Confirm no calls to autofix/TODO writers and no runtime dependency addition.
After the verified local freeze, deliver one atomic Lore commit and PR. Record post-commit hosted CI and delivery status in the PR and workspace roadmap, preserving the tested source head.

## Evidence

### Bounded cleanup plan

After regression tests protect the bridge/report contract, make only changes needed for the existing Ruby budgets and review findings: keep subprocess execution in the adapter, separate report normalization using the existing Debride/RubyCritic report pattern when class length requires it, and extract small named operations for boot, output redirection and serialization. Reuse the existing ParseError/failure-diagnostic boundary, delete redundant process-error classes and repeated validation, and preserve all public behavior. Do not introduce generic frameworks, upstream patches, lint exceptions, new dependencies or budget changes. Rerun focused regression tests and fast after each affected slice.

Baseline: worktree starts at merged main `04c8f77`; existing parallel suite passed 1,085 tests / 8,339 assertions, no failures or errors, two existing skips. Existing Active Support/RuboCop method redefinition warnings were observed. No source changes preceded this plan. Real analyzer 3.0.14 is installed in `/private/tmp` for acceptance only; project dependency files remain unchanged.

Independent Luna design review approved the corrected actual `path:line` source-location contract, status/error handling and supported version range. It recommended Rails application eager loading without global Zeitwerk eager loading; this narrower behavior is the implementation contract.

Real-fixture acceptance corrected a second upstream-contract assumption during implementation: 3.0.14's generated `ReportBuilder#to_h` produces dynamic value keys rather than field names. The bridge now must use the public readers explicitly and include a regression that does not rely on a valid upstream `to_h`. The failing installed-bundle audit reported a tool failure rather than a false clean scan.

### Verified local implementation (October 4)

Independent Luna specification and Ruby simplicity reviews approve. The specification review corrected help text that advertised the optional adapter as a default. The simplicity pass removed a one-call validation wrapper and an unnecessary private exception/translation rescue; existing ParseError handling now serves both report validators. No dependencies, defaults, version changes, lint suppressions or budget changes were introduced. `llm.txt` was regenerated and remains byte-identical because its curated links did not change.

The orchestrator's combined focused run passed 181 tests / 1,590 assertions before the help and coverage additions. Final focused adapter, direct bridge, integration and CLI suites pass 16/64, 11/69, 14/100 and 95/659 respectively. Direct bridge fixtures preserve preexisting Rails/analyzer constants and methods, loaded specs and fixture-loaded features; an explicit sentinel regression protects this isolation.

Full `quality_gate fast` and `quality_gate verify` pass with no findings/tool failures, including the parallel test suite, Undercover and SimpleCov. Actual project `bundle exec rbs -I sig validate` and diff checks pass. Coverage is 98.67% line / 92.28% branch; budgets remain 96% / 83%. The first full run identified four diff-coverage gaps; public-input regressions for missing report fields/arrays, unavailable Rails application and failed diagnostic IO closed them without production changes.

The built 0.3.0 artifact contains 90 public payload files, all matching source bytes; tests and internal plans are excluded. SHA256: `d53711aa9593269b5597011b7cfe7d1f6ce2517bfecbd0139095628ed63eb88c`. It has no database_consistency runtime dependency. Ten real installed-package acceptance cases use Rails/Active Record 8.1.3.1, SQLite 2.9.6 and analyzer 3.0.14, resolved from the temporary installed gem rather than this worktree. They verify missing/repaired unique indexes, FK/presence mismatches, warning-only exit 1, actual find_by source locations, unavailable database, malformed config, swallowed checker errors, missing optional analyzer and missing Rails boot file; clean/findings/failure exit codes are 0/1/2. Upstream diagnostic-file side effects were observed on rescued errors.

PostgreSQL/MySQL, other Rails/analyzer versions, nonstandard eager-loaders and sustained application adoption are not verified by this fixture. Future analyzer-range changes need renewed real-package acceptance. No tag, publication or merge is part of this implementation; the original checkout remains clean and unchanged.
