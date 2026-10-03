# Baseline and ratchet implementation plan

> For Luna implementers: use test-driven development and bounded ownership. The leader orchestrates, integrates and verifies; independent specification review precedes Ruby simplicity review. User authorized implementation and one atomic PR, so no intermediate commits or repeated approval questions.

**Goal:** adopt fast/verify checks with explicitly accepted existing style debt while enforcing unaccepted findings and an explicit shrink-only ratchet.

**Architecture:** persist deterministic, versioned JSON snapshots; match bounded occurrences of normalized findings after every configured adapter runs. Integrate an opt-in gate policy at the CLI result boundary, preserving raw check statuses and protected findings. Reuse Config, immutable Runner results, existing reporters, CLI error handling and ordinary Ruby file APIs.

**Tech stack:** Ruby >= 3.2, standard-library JSON/Pathname/Tempfile, existing Minitest/RuboCop/RBS tooling. No dependencies, lint exclusions, coverage-budget changes, generated automatic runs or release/version changes.

**Base:** merged main `2637854bd8a9bf957815c40d239ead549654e29d`. Worktree `.worktrees/baseline-ratchet`, branch `codex/baseline-ratchet`. Fresh baseline verify passed tests, Undercover and SimpleCov with zero findings/tool failures. Existing project method/class/parameter limits are 5/100/4, ABC 16; tests are exempt from method/class length only.

## User contract and scope

```sh
# Create an explicit snapshot; never overwrite an existing file.
bundle exec quality_gate fast --create-baseline config/quality_gate_fast.json

# Compare without writing; configured baselines work with hooks and CI too.
bundle exec quality_gate fast --baseline config/quality_gate_fast.json
bundle exec quality_gate fast --baseline config/quality_gate_fast.json --files lib/example.rb

# Remove resolved entries/counts only after a complete, passing comparison.
bundle exec quality_gate fast --ratchet-baseline config/quality_gate_fast.json
```

The same options work with `verify`. They are mutually exclusive and require non-empty paths. Reject them for audit/deep; reject `--files` or non-empty configured `files` for create/ratchet before executing tools. Comparison accepts selected paths without pruning unobserved entries. Directly supplied paths override the corresponding configured baseline for that run. Resolve paths against CLI `dir:`, not incidental process cwd.

```yaml
baseline:
  fast: config/quality_gate_fast.json
  verify: config/quality_gate_verify.json
```

Default is `{}` (disabled); accept only fast/verify keys and non-empty string paths. Do not write or enable config automatically. Existing generated settings retain disabled defaults; add a commented opt-in example without wiring baseline files or changing hooks. `--help` must work without valid config or loading a baseline.

Accept only RuboCop, Reek and Herb findings of severity warning/info with a non-empty project file and `tool_failure? == false`. Error-severity offenses (including RuboCop syntax errors and Herb errors), tests, coverage, Undercover skips, audit/security, unknown tools and deep findings remain enforced. All configured adapters still run. Baseline I/O/schema/context errors exit 2. Capture/ratchet must not write when protected findings or any tool failures remain.

## Snapshot and matching contract

```json
{
  "schema_version": 1,
  "gate": "fast",
  "tools": ["rubocop"],
  "findings": [
    {"tool":"rubocop","file":"lib/example.rb","rule":"Style/StringLiterals","severity":"warning","message":"Prefer double-quoted strings.","count":2}
  ]
}
```

Record exact gate and configured unique adapter names/order (including protected tools in verify). Require context equality on compare/ratchet so disabling or changing the adapter set cannot silently shrink a snapshot. Require at least one eligible analyzer for a snapshot operation. Snapshot capture is always full-project (normal configured exclusions still apply). Durations and line numbers are not stored.

Identity is `(tool, canonical project-relative file, rule, severity, exact message)`. Normalize `./` and absolute in-project paths lexically; never accept paths outside the project, empty/root paths, absolute stored paths or non-canonical stored paths. Do not read source code, parse ASTs or invent a semantic identity. Compare as a multiset: at most the stored count is accepted; excess occurrences remain findings. Changed file/rule/severity/message is new; moving line numbers alone is accepted. Matching is deterministic in input order and does not mutate a snapshot or input findings. Persist grouped entries sorted by identity with positive integer counts and stable JSON formatting/newline.

Reject malformed JSON, unknown schema versions, missing/extra keys, wrong gate/tool/entry types, ineligible stored entries, invalid paths/counts and duplicate identity entries. Do not silently coerce numbers or ignore unknown data. An empty findings list is a valid zero-debt snapshot.

Create uses exclusive file creation and refuses overwrite, including malformed existing files. Ratchet reads and validates an existing snapshot, compares the complete current findings and writes only when the effective result is clean. It replaces the file using a same-directory temporary file and rename. Named failure: partial rewriting could destroy reviewed accepted-debt data; publish the replacement only after serialization/write succeeds. No additional generic filesystem hardening. New/protected findings, missing adapters or failed tools preserve the original bytes. Ratchet may keep the same counts or remove resolved entries/counts; it never adds identities or increases counts. Normal comparison never writes.

## Reporting and guarantees

Extend the existing immutable Runner result with optional baseline metadata; default nil preserves current initialization, derived failed tools, `with`, exit codes and reporter payloads. Metadata carries mode (`compare`, `create`, `ratchet`), accepted findings/count and removed count. Effective `findings` retain only unaccepted and protected findings; checks retain original tool statuses, scope and timing. Raw `findings` check statuses may coexist with exit 0 because the accepted debt is explicitly reported.

Only when baseline processing succeeds, JSON adds a `baseline` object including serialized accepted findings and accepted/removed counts. Text/Markdown add a clearly named baseline summary with mode and counts. Reuse existing field sanitizers and finding serialization; never print an unsanitized path or message. Disabled result JSON remains exactly checks/findings/summary and disabled human output remains unchanged. Exit 0 means no unaccepted findings; 1 means findings remain; 2 retains input/config/tool failure precedence. A failed mutation reports failures and does not imply the snapshot was written.

Limits to document: identical normalized output within one file is interchangeable up to its accepted count; this does not prove code identity or unchanged semantics. Analyzer/rule configuration changes can make debt disappear and must be reviewed together with a ratchet; tool metadata does not hash configuration or pin analyzer versions. Ratchet refuses growth through the CLI, but manual snapshot edits require normal Git review. Snapshot data contains analyzer messages and paths and belongs to the host project; do not ship one in QualityGate. This is explicit acceptance of debt, not an automatic 'all new semantic bugs' detector.

Rejected: exact line matching (ordinary insertions invalidate old debt); unbounded file/rule exclusions (hide new occurrences); automatic shrink on selected runs (drops unobserved debt); generic suppression (hides correctness/security failures); AST/source/Git fingerprints and policy hashes (not required for this first explicit multiset contract).

## Task 1 — Snapshot, multiset matching and persistence

Owner: Luna core implementer. Own only new `lib/quality_gate/baseline.rb`, optional focused `baseline_entries.rb` / `baseline_file.rb` helpers, and `test/quality_gate/baseline_test.rb`. No edits to the loader/Runner/CLI/Config/reporters; focused tests may explicitly require the new core file after test helper. Adjust helper boundaries for clarity within budgets, with no new dependencies or suppressions.

Proposed public interface (keep task 2 consistent; report useful simplifications to leader):

```ruby
Baseline.capture(gate:, tools:, findings:, root:) # -> Baseline; four parameters
Baseline.read(path) # -> Baseline, raises descriptive QualityGate error
snapshot.validate_context!(gate:, tools:)
snapshot.match(findings, root:) # -> immutable match with findings / accepted arrays
snapshot.write(path, create:) # exclusive create or atomic replacement
snapshot.count # accepted occurrence count
snapshot.to_h # validated JSON document
```

- [x] Write and observe failing tests before implementation: line movement; lexical paths; changed message/file/rule/severity; duplicate count growth and shrink; protected tools/error/tool failures; input immutability; deterministic capture and output.
- [x] Implement the smallest validated snapshot/matcher; protected findings survive matching even if forged stored entries attempt to accept them.
- [x] Test malformed/version/type/key/count/path/duplicate rejection and context drift, zero-debt snapshots, overwrite refusal, missing file/read/write failures, and replacement preservation on failed write.
- [x] Implement ordinary read/exclusive creation/atomic ratchet persistence, without source crawlers, caches or generalized storage interfaces.
- [x] Run focused Minitest and scoped RuboCop; report red/green evidence and freeze. No commit or full coverage runs.
- [x] Leader obtains independent Luna spec approval, then simplicity approval before task 2.

Core evidence: initial tests were written first and failed because the module did not yet exist; the first run did not reach behavioral assertions. Independent spec review subsequently found an empty-rule construction defect; a failing behavioral regression demonstrated it, and constructor-level schema validation fixed capture/direct construction together. A further regression reproduced replacement changing an existing file from 0640 to Tempfile's default 0600; ordinary stat/chmod before rename now preserves the existing permission bits. Core tests pass (18 runs / 75 assertions). Scoped RuboCop and diff checks are clean; fast passed before integration edits began and will be rerun on the frozen final diff. Independent spec and Ruby simplicity reviews approve both the core and the permission-preservation follow-up. The small schema/path/persistence modules live privately in `baseline.rb`; no extra helper files were necessary.

## Task 2 — Gate policy, config, CLI, reports and public contracts

Owner: fresh Luna integration implementer after core approval. Own `lib/quality_gate.rb`, `config.rb`, `cli.rb`, `runner.rb`, `reporters/{json,text,markdown}.rb`, new focused `baseline_options.rb` / `baseline_run.rb` if useful, `sig/quality_gate.rbs`, README, CHANGELOG, commented configuration templates, and relevant config/runner/reporter/distribution/template tests plus new `test/quality_gate/baseline_integration_test.rb`. Do not modify approved core without handing a bounded regression back to its owner.

- [x] First write failing CLI-level regressions with controlled adapter output and temporary projects, not a test-only branch in production. Cover creation/configured compare/selected compare/ratchet and enforced exit semantics; verify human baseline summaries and preserve existing reporter error behavior.
- [x] Validate config and mutually exclusive CLI options before tools run. Resolve path/root context once using CLI dir. Use a focused option/policy object if needed; avoid expanding the existing oversized CLI into baseline storage or matching code.
- [x] Apply core matching at the result boundary, preserving protected findings and raw checks. Add immutable optional baseline result metadata with safe `with` behavior and unchanged disabled output. The narrowly extended analyzer failure boundaries are documented below.
- [x] Creation applies a newly captured snapshot only if the effective result is clean; otherwise return original findings, write nothing. Ratchet applies the validated old snapshot; only a clean full-project result can publish a new snapshot captured from accepted current occurrences. Read-only compare never writes.
- [x] Cover configured baseline in ordinary/hook-style selected-file gate runs, mode override of config, dir different from cwd, malformed/missing/context-inconsistent files, partial capture refusal, empty baseline, excessive duplicate/new identities, skipped/failed tests/coverage/security invariants, failing output and failing mutation preservation.
- [x] Update help, README examples/limits/exit meanings, Unreleased changelog, RBS and package assertions. No version bump or generated enablement. Distinguish product baselines from this repository's RuboCop todo ratchet.
- [x] Focused tests, scoped lint and RBS pass; run fast after Ruby edits; freeze and report without commits/full suites.
- [x] Leader obtains independent spec review, then Ruby simplicity review; authors fix verified gaps and reviewers recheck.

## Leader verification and delivery

Observed failure boundaries during real analyzer/package acceptance: RuboCop 1.90.0 could not create its cache under the filesystem sandbox. It emitted valid JSON with zero inspected files while failing; the existing adapter discarded process status and reported clean, allowing an empty baseline creation. A subsequent installed-package regression reproduced ratchet erasing a one-entry snapshot after a failed scan. Reek 6.5.0 similarly emitted `[]` with exit 0 and a stderr source-processing diagnostic for invalid Ruby. Extend this slice narrowly to normalize RuboCop's successful-analysis exit statuses (0/1), Reek's distinct successful-analysis statuses (0/2), and Reek's explicit `cannot be processed by Reek` diagnostic. Preserve ordinary Reek notices and other adapters' exit-status contracts. Add behavioral regressions and repeat installed-package acceptance with a deliberately unwritable RuboCop cache and invalid Reek source. These are reproduced analyzer failures, not speculative filesystem hardening.

- [x] Fresh merged-base verify passes with installed dependencies resolved locally.
- [x] Stage new files before diff coverage. Run fast, full verify and RBS validation on frozen sources; preserve 96% line/83% branch budgets. Fix meaningful coverage gaps rather than policy exclusions.
- [x] Build and inspect the actual gem; exercise installed CLI baseline create/compare/ratchet using real RuboCop and Reek in temporary projects, including line movement, new debt, duplicate growth, resolved debt, tool failure preservation and configured selected-file compare. Only the local artifact is installed; dependencies are reused from existing gems.
- [x] Confirm snapshot/internal plan/test/dev files are absent from package; runtime modules/types/docs included; disabled behavior/defaults remain unchanged.
- [x] Record local evidence here before the atomic Lore commit.

Delivery follows this frozen-source record: push one atomic commit, create the PR, check hosted Ruby 3.2/4.0.1/4.0.6 CI on its exact head, update the workspace roadmap and remove temporary scripts/fixtures. PR/head/CI and final cleanup evidence are recorded in that roadmap after this commit, avoiding self-referential commit amendments. Preserve the user's main checkout and existing worktrees. Do not merge, tag or publish.

Integration evidence: the first comparison regression failed because the old CLI rejected `--baseline`. Independent review and installed-package acceptance found the analyzer failure boundaries described above; targeted regressions subsequently pass. Scoped adapter tests are 42 runs / 126 assertions, CLI 92 / 630, baseline integration 22 / 128, and hook suites 63 / 1,234. Scoped RuboCop (18 Ruby/test files), RBS validation, fast and diff checks pass. The leader independently reran fast and RBS on frozen source. `BaselineRun` contains matching/publication policy; CLI handles input/config context; no new suppressions or dependencies were added. Existing `llm.txt` remains unchanged after regeneration.

Installed-package evidence: version remains 0.3.0; 80 public payload files include the two new runtime modules and exclude tests, internal plans and host snapshots. Actual RuboCop 1.90.0 and Reek 6.5.0 exercise creation/comparison/ratchet, line movement, bounded duplicate growth, syntax/error protection, full-only mutation, configured selected-file comparison and deletion of resolved debt. A RuboCop cache path blocked by an ordinary file and Reek invalid source both produce exit 2 and preserve snapshot bytes. The final source was rebuilt and the full installed-package acceptance repeated successfully. SHA256 of the final local verification artifact: `e5d3d2adaf17200d8f0072935edcdd23104f7e3fe023a757a3149acbdd37e8fb`. This is local package evidence, not publication or sustained application-adoption evidence.

Final coverage pass plan: full verification passed the test-suite and aggregate budgets, but Undercover reported eight changed-method branch gaps. Add meaningful public-input regressions for a NUL finding path, filesystem-root normalization, non-array capture input, an empty baseline option and audit help. In the analyzer guards, inherited capture always returns a Process::Status; remove redundant safe navigation on the status object while preserving signal handling through its nil exitstatus. Review the internal mode dispatch fallback for an explicit failure contract rather than treating an unknown mode as a mutation. No coverage exclusions, policy changes, generic abstractions or test-only production branches.

Coverage follow-up is frozen: core tests are 21 runs / 80 assertions with no production change; CLI tests 95 / 652, integration 23 / 132 and adapters 42 / 126 pass. Empty required-option input is checked both through OptionParser and the explicit non-empty path boundary. Unknown baseline mode is a structured tool failure. Redundant nil receiver checks were deleted; signaled processes remain failures. Scoped lint, RBS, fast and diff checks pass. Prior full specification and Ruby simplicity reviews approve; narrow follow-up rechecks and final full verification are next. The first full run's aggregate coverage was 98.51% line / 91.35% branch, but its eight diff-coverage findings prevented a passing verify result.

Final verification: independent Luna specification and Ruby simplicity rechecks approve the coverage follow-up. Full verify passes with zero findings/tool failures: test suite clean (104,005 ms), Undercover clean, SimpleCov clean. Aggregate coverage is 98.53% line / 91.82% branch with unchanged 96% / 83% budgets. The leader reran fast and RBS successfully on the final runtime sources; only this evidence record changed afterward. All source/index edits were frozen throughout each full verification run. No dependencies, lint policy, coverage policy or release/version changes were made.
