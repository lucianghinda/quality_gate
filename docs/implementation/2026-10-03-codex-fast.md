# Codex fast feedback after edits

> Use the subagent-driven-development workflow. The leader owns integration, final verification, and one atomic Lore commit.

**Goal:** Give Codex actionable, file-scoped Quality Gate feedback immediately after native patch edits.

**Architecture:** Install a synchronous `PostToolUse` command matching `^apply_patch$` alongside the existing Stop hook. A small bundled Ruby runtime selects affected files from the patch and calls the existing CLI fast gate once. The installed launcher loads the project's bundle and emits one JSON response. Claude's existing Edit/Write fast hook remains unchanged.

**Constraints:** Ruby 3.2+, standard library only, no new dependencies, no autocorrection, no lint suppressions or budget relaxation, no project/user trust changes, no retry state, no hook history or Stop debounce. Keep the existing gate exit meanings and baseline behavior.

## Native contract and behavior

The [official Codex hook contract](https://developers.openai.com/codex/hooks) supports `PostToolUse` for `apply_patch`, including nested calls in code mode. Input reports `hook_event_name`, canonical `tool_name`, `tool_input.command`, and `cwd`. Feedback uses `hookSpecificOutput` with `hookEventName: PostToolUse` and `additionalContext`. Do not reject the completed patch or replace its normal tool result; return feedback without `decision`, `continue`, or a nonzero exit.

- Validate the event, tool, patch string and absolute existing cwd inside the installed project. Invalid payloads return visible unavailable feedback, never a clean claim.
- Parse native `*** Begin Patch` / `*** End Patch` headers, Add File, Update File, Delete File and Move to. Only unprefixed structural lines describe paths; diff content cannot introduce a path. Reject malformed/unsupported structural input rather than guessing or scanning the project.
- Resolve relative paths against the event cwd, not the launcher's cwd. For moves select the destination; deleted paths and files now missing are cheap skips. Deduplicate existing regular files inside the project, including realpath containment for symlinks. Ignore paths outside the project.
- Select `.rb` files and `.erb` files when Herb is configured in fast. Irrelevant edits avoid invoking the gate. A Ruby/ERB mixed patch invokes one fast run with all selected files; pass absolute positional paths so filenames beginning with `-` cannot become options.
- Call `CLI.run(["fast", "--format", "json", "--files", *files], stdout:, stderr:, dir: installed_root)`. Reuse its configured adapters, timeouts, baseline comparison and normalization. Never fall back to a full-project fast run when file selection is empty.
- A valid status 0 report with no findings returns `{}`. Status 1 with findings returns locations, tools/rules and fix instructions as additional context. Tool failures, exceptions, malformed or inconsistent reports return an unavailable `systemMessage` and model-visible context suggesting the manual fast command. No persistent counters or suppression of repeated unavailable attempts.
- Preserve full Stop verification and its one-continuation cap. Shell writes are outside this first per-edit hook and still receive final verification.

## Implementation tasks

### 1. Runtime and launcher

Files: create `lib/quality_gate/codex_fast_hook.rb`, a focused patch-path selector if necessary, `lib/generators/quality_gate/install/templates/codex_fast.rb.tt`, runtime/launcher tests, and signatures in `sig/quality_gate.rbs`.

- [x] Write failing public-call tests using real temporary files and CLI stubs only at the process boundary. Cover multi-file add/update, nested cwd, moves, deletion, mixed Ruby/ERB, Herb opt-in, duplicates, leading-dash/spaced paths, outside paths/symlinks, irrelevant edits, malformed input and gate outcomes. A hunk containing `+*** Add File: bogus.rb` must not select that path. Assert exact native feedback shape and absence of `decision` and `continue` on every response path.
- [x] Implement the smallest idiomatic runtime satisfying those tests. Shared report validation is allowed only if it reduces duplication and preserves existing Stop behavior; write an explicit cleanup plan and run existing Stop regressions before that extraction.
- [x] Add launcher process tests proving project bundle/root selection, nested cwd, strict one-JSON stdout and malformed input/missing Gemfile feedback. Copy the proven Stop launcher bootstrap rather than introduce a general framework.
- [x] Run focused tests and `bundle exec quality_gate fast` on modified Ruby paths. Independent specification review precedes simplicity review.

### 2. Installation and user documentation

Files: `lib/quality_gate/installation.rb`, `lib/quality_gate/doctor_hooks.rb`, CLI help, `codex_hooks.json.tt`, agent contract template, installation/distribution tests, README and `docs/codex.md`.

- [x] Write failing installation tests for both Ruby init and Rails generator, combined flags, executable mode repair, repeat installation, pretend and custom config preservation.
- [x] Register and install `.codex/hooks/quality_gate_fast.rb` with mode 0755. Add a matcher-scoped PostToolUse command with quoted absolute script path and a finite timeout; retain the Stop command.
- [x] Add a prior-Codex snapshot predicate rendered for the current destination root (the old template embeds an absolute path); extend the existing verified atomic replacement mechanism currently used for prior Claude settings. Upgrade only the exact previously generated Stop-only bytes for that root. Any custom bytes, changed project location or file symlink require manual integration. Test same-root old snapshot upgrade, different-root rejection, customized snapshot, symlink and pretend upgrade; preserve the existing config mode.
- [x] Update owned AGENTS contract and setup/help/docs to explain Claude/Codex parity, patch-only scope, feedback/unavailable semantics, manual trust review after config changes, and unchanged Stop behavior. Doctor may recognize the fast launcher but must not claim native execution or trust evidence.
- [x] Update distribution manifest assertions and run related regressions. Independent specification review precedes simplicity review.

### 3. Acceptance and delivery

- [x] Freeze source/index, stage new files and run full `quality_gate fast`, `quality_gate verify --format json`, and `rbs -I sig validate`; inspect normalized results and coverage with unchanged budgets. Run security checks if the implementation introduces security-sensitive command/path behavior.
- [x] Build the gem and exercise the installed launcher with real RuboCop in an isolated project: clean patch, offense patch, repaired patch, nested cwd and unavailable configuration. Verify custom installation preservation and Claude regressions.
- [x] Attempt a live native Codex repair loop using normally reviewed hooks. Do not bypass trust or edit user-home trust. Record actual evidence and any activation/authentication limitation separately from launcher acceptance.
- [ ] Finish with one atomic Lore commit, push a focused PR and verify hosted CI against that exact head. Record completion/evidence here and update the external roadmap. Do not merge or publish a release.

## Initial evidence

- Base: merged main `294009abb0e26ff705b2e32286ab60d0c399e710` (PR #13).
- Existing Claude settings match `Edit|Write` and invoke file-scoped fast; ERB is supported when Herb is configured.
- Installed Codex CLI: 0.160.0. Native hooks contract reviewed on 2026-10-03.
- Clean baseline: `bundle exec rake test` passes 1048 runs / 8023 assertions, zero failures or errors, two existing skips. Source implementation began after this completed.
- Independent Luna design review accepted the architecture and identified exact same-root upgrade matching and native response-shape assertions; both are included above.

## Verification follow-up and bounded cleanup plan

The first full verify passes the suite and aggregate coverage but reports six diff-coverage gaps: malformed finding/summary guards, malformed tool input, a file disappearing during canonicalization, invalid EOF placement, and the parser's zero-operation guard. Add public hook-call regressions for the reachable error paths. Remove the operation counter and its guard: the envelope already requires an interior line, and every line before an operation is rejected by the structural/content handlers, so that final guard is unreachable. Existing empty/malformed patch regressions protect this simplification. Do not add artificial tests that mutate private state just to reach dead code. Rerun focused tests, both reviews, fast and full verify before delivery.

Installed-package acceptance passes with actual RuboCop on clean/offending/repaired edits, nested cwd, repaired Stop, malformed input and invalid configuration. A normal native Codex CLI session applied the two fixture edits but showed no hook feedback. The native `/hooks` screen confirms two definitions need review: PostToolUse is installed (1), active (0), awaiting review (1). This explains the missing feedback and does not establish an agent repair loop. No hook-trust bypass or trust-file changes were used.

Both runtime and installer passed independent Luna specification review followed by simplicity review. Initial installer-related suites pass 322 runs / 3,234 assertions; runtime regressions after the diff-coverage follow-up pass 26 / 190, launcher process tests 2 / 22. Full project fast reports zero findings/tool failures; actual project signatures validate with `rbs -I sig validate`. The first full verify passes the suite and aggregate coverage (98.56% line / 91.83% branch), with the six diff findings addressed above. Final full verification and final package binding remain pending.

## Final local evidence

The targeted coverage follow-up passed independent specification and simplicity review. Final verification, with source and index frozen, reports clean test_suite, Undercover and SimpleCov checks: zero findings and zero tool failures. Full fast and `rbs -I sig validate` pass. Coverage is 98.61% line / 92.08% branch; budgets remain 96% / 83%.

The final local 0.3.0 package (SHA256 `9648f7b85629a044926332f720beaed3ffc2f2025fb1246cbbb63de6e347bc8e`) passes installed-launcher acceptance in a separate project with spaces/apostrophe in its path. Actual RuboCop detects the introduced trailing-whitespace offense, feedback contains its rule and location without blocking keys, repair returns clean, and Stop verification passes. Nested cwd, malformed input and invalid configuration are verified. This is launcher acceptance, not a trusted live native-agent repair loop; the native review screen shows pending hook review as recorded above.

One atomic Lore commit and an exact-head CI-verified PR are the delivery target. Post-commit package binding and hosted CI results are recorded in the PR and external roadmap; this document necessarily precedes that commit. No release publication or merge is included.
