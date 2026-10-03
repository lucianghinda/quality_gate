# Native Codex verification implementation plan

> Agent execution: use `superpowers-ruby:subagent-driven-development`; Luna authors and independent reviewers, with the leader owning integration and verification.

**Goal:** make full end-of-turn verification available to Codex users through an explicit installer option.

**Architecture:** `--codex` installs a synchronous native Stop hook, an executable Ruby launcher, and the existing owned AGENTS.md contract. The launcher loads the project's bundle and calls a small `QualityGate::CodexStopHook` wrapper around the existing CLI. Existing Claude `--agents` behavior remains compatible. No dependency, version, analyzer-policy or trust changes.

**Tech stack:** Ruby 3.2+, standard-library JSON/StringIO/Shellwords, existing QualityGate CLI and installer filesystem boundaries, native Codex hooks.

## Selection and verified capabilities

PR #12 merged as `4089111e629fac58304d8870bd3bfdab11276c9a`; this branch starts there. Full baseline verify passes with zero findings or tool failures.

Codex CLI 0.160.0 reports `hooks` stable and enabled. The [official hook documentation](https://developers.openai.com/codex/hooks) describes project `.codex/hooks.json`, synchronous Stop command hooks, JSON `decision: block`/`reason` continuation, `stop_hook_active`, and review/trust through `/hooks`. Project and hook trust are prerequisites; never modify trust or use the bypass flag. SessionEnd is too short for verification.

Manual-only guidance leaves a repeatable task to the agent. Reproducing both Claude hooks would add tool-specific per-edit parsing and state management. Select one Stop hook first; manual fast/audit and direct CI checks remain required. Always run full verify on Stop, even for an unchanged worktree: this avoids stale clean debounce and missing changes. Document the latency explicitly.

## Behavior contract

- Plain Ruby: `bundle exec quality_gate init --codex`; Rails: `bin/rails generate quality_gate:install --codex`. `--agents --codex` installs both clients. `--codex` alone does not install Claude hooks or CLAUDE.md.
- New artifacts: `.codex/hooks.json`, `.codex/hooks/quality_gate_verify_stop.rb`, and AGENTS.md's existing owned section. Register paths with the existing safe agent-artifact writer. Preserve unrelated bytes, custom hook configurations, symlink protections, conflict reporting and pretend/idempotent behavior. Do not introduce JSON merging or new filesystem hardening.
- Stop configuration has one command handler, timeout 600 seconds. Generate a shell-quoted absolute script path so invocation from nested directories and installations inside a monorepo works. Document that moving the project requires updating this command and reviewing changed hook trust. Do not touch `.codex/config.toml`, user-home configuration or trust state.
- Launcher determines the installed project from its own location, changes to that directory before loading Bundler, selects that project's Gemfile, loads QualityGate, parses stdin JSON and emits exactly one JSON response. Missing bundle/gem and malformed input produce a visible `systemMessage`, successful exit, and no clean claim.
- Runtime validates Stop event input and boolean `stop_hook_active`, then calls the existing `CLI.run(["verify", "--format", "json"], ...)` with captured output in the project directory. Reuse gate exit semantics and normalized report; do not duplicate analyzer protocols or independently invoke tools.
- A clean valid gate returns `{}`. Findings return `{"decision":"block","reason":"..."}` requesting fixes and including normalized findings. On a resumed Stop (`stop_hook_active: true`) rerun verification, but if findings remain return a visible cap message, permitting the turn to finish. At most one repair continuation per turn; cap is not a clean result.
- Tool failure, malformed/inconsistent report, invalid input or runtime exception returns a visible unavailable message and does not block indefinitely. Gate errors must never become clean reports. Do not use `continue:false` to suppress remediation.
- This first slice has no per-edit hook, debounce, session counter or hook history. Doctor recognizes the installed Codex hook and describes missing history as unchecked; it cannot prove activation, trust or current verification. Existing Claude history is historical evidence only.
- Generated contracts and public docs explain manual fast/audit, native trust activation, runtime cost, cap/fail-open semantics, conflict resolution and removal. Keep existing default installation instructions correct.

## Task 1 — Runtime and generated launcher

Files: create `lib/quality_gate/codex_stop_hook.rb`, `test/quality_gate/codex_stop_hook_test.rb`, and `lib/generators/quality_gate/install/templates/codex_verify_stop.rb.tt`; modify `sig/quality_gate.rbs`.

- [x] Write focused failing tests for clean, findings, active continuation clean/cap, tool failure, malformed/nonmapping input, wrong event and nonboolean active state, malformed/inconsistent CLI JSON, and runtime exception. Stub only CLI.run; assert its exact full verify arguments and directory.
- [x] Implement the small wrapper with methods within existing five-line and class-length budgets. Use StringIO to capture CLI output; output a Hash for JSON serialization, not an external CLI status.
- [x] Add the standalone launcher and rendered-process tests proving installed root selection from a nested/foreign cwd, successful stdout JSON, and missing-bundle/malformed-input messages. Use isolated temporary fixtures and existing gems, with caller bundle variables unset in acceptance processes.
- [x] Run focused tests and `bundle exec quality_gate fast`; no new suppressions.

## Task 2 — Installer and public contract

Files: modify `lib/quality_gate/installation.rb`, `installer.rb`, `init_command.rb`, `cli.rb` initializer help, `doctor_hooks.rb`, Rails `install_generator.rb`, owned agent-section templates, `README.md`, `docs/codex.md`, `CHANGELOG.md`, `llm.txt`; create `codex_hooks.json.tt`. Extend focused CLI, Ruby/Rails installation, template and Doctor tests.

- [x] Write failing tests for separate/composed opt-in (both Claude artifacts and a singular AGENTS block), generated native JSON schema and shell quoting, both profiles, idempotence, executable 0755 mode including reinstall repair, pretend, custom hooks.json conflicts and existing safe artifact boundary reuse (including .codex directory/script symlinks).
- [x] Wire the option through existing entry points and shared installation step; install AGENTS.md exactly once when both options are used. Reuse existing writing/conflict machinery; no custom merge or client-selection framework.
- [x] Add Doctor's installed-file recognition and tests preserving unchecked evidence, including config-only and script-only partial installations with missing history; never infer readiness from files.
- [x] Update documentation and generated agent guidance; regenerate `llm.txt` with the existing index task.
- [x] Run focused tests and fast; independently review specification compliance before Ruby simplicity review. Fix and recheck concrete findings.

## Task 3 — Delivery evidence

- [x] Stage source before Undercover and freeze source/index during final checks. Run fast, full verify, RBS validation and diff checks with existing coverage budgets.
- [x] Build/install a local gem and exercise actual generated scripts for clean/findings/continuation/failure, nested cwd, and a missing bundle. Verify package contents exclude internal plans and match committed bytes. This is generated-script acceptance; do not claim a live native-agent repair loop was tested unless it actually was.
- [x] Record evidence here; update the workspace roadmap for merged baseline and selected Codex work.
- [ ] Create one atomic Lore commit, open a new PR, and verify hosted CI on its exact head across the existing Ruby matrix. Do not merge, tag or publish.

## Known boundaries

Native trust and host timeout/process handling belong to Codex. A missing or untrusted hook can never establish verification; CI and manual gates remain the enforcement evidence. Full verify on every Stop may be expensive, and the single-continuation cap permits unresolved findings after a visible warning. The first release does not establish hook health through Doctor or implement automatic fast feedback.

## Execution evidence

Task 1 passed independent Luna specification review, then independent Ruby simplicity review. Runtime tests pass 8 runs / 99 assertions; rendered launcher process tests pass 2 / 22. The initial missing-class regression and float-count schema regression failed before implementation and passed afterward. Full and scoped fast checks reported zero findings/tool failures on the completed core. Existing Finding constants are reused, and no suppressions were added.

Real process fixtures exposed two startup details: a missing Gemfile must be rejected explicitly, and unlocked Bundler setup can print resolution text. The launcher requires the installed project's Gemfile, loads only its bundle-selected QualityGate gem, and captures/restores setup output before emitting one native JSON response. Foreign/nested cwd and missing-Gemfile cases are covered. Final installer, full-gate and package evidence remain pending.

Loading the actual project signatures with `bundle exec rbs -I sig validate` found a pre-existing `_BaselineMatch` syntax error from PR #12: interfaces require method declarations rather than `attr_reader`. The two getters now use equivalent `def` signatures; the failing parser check became green. This is a narrow packaged-signature correction with no runtime change. Final validation explicitly includes `-I sig`, which a bare RBS invocation omits.

Task 2 passed independent Luna specification review followed by Ruby simplicity review. Focused Codex installation tests pass 12 runs / 101 assertions and CLI tests 95 / 655; adjacent Ruby/Rails installers, templates, Doctor, distribution and profile checks also pass. The new installer tests were red before wiring the flag/artifacts. Rails string-keyed option rendering is supported, combined installation checks both Claude hooks and a singular AGENTS block, and init help exposes the new flag. Scoped fast and diff checks are clean. The existing documentation index was regenerated and is byte-identical. Simplicity review removed unnecessary bundle-install reinstallation guidance; refreshing integration is conditional on changed generated files, and duplicate conflict guidance was deleted.

The first full verification passed the suite and aggregate coverage budgets but found one diff-coverage gap in the nonmapping summary guard. A public-call regression now covers nil/array summaries with unavailable responses and no decision; runtime tests pass 9 runs / 113 assertions and scoped fast remains clean. Both independent reviewers approve the targeted regression; runtime and policy are unchanged. Final full verification passes with source/index frozen: test suite, Undercover and SimpleCov are clean, with zero findings/tool failures. Project fast, `rbs -I sig validate` and diff checks pass. Coverage is 98.56% line / 91.93% branch, with unchanged budgets of 96% / 83%.

Installed-package acceptance passes on the local 0.3.0 artifact (83 public files; SHA256 `4adc1c0cdeac6eebabccce0ddc96ecae19aa9c358afb15ed704c9a0106dd540d`). All payload bytes match reviewed source, with internal plans/tests excluded. A separate project containing spaces and an apostrophe exercises actual installed init, native JSON command quoting, nested cwd, clean verification, suite findings, continued-Stop cap, invalid config, malformed input and missing Gemfile. Temporary install fixtures are removed. These are real generated-script tests, not a live Codex native-agent repair loop or publication.

This document precedes the atomic commit and PR. Post-commit artifact binding and exact-head hosted CI evidence will be recorded in the PR and workspace roadmap; no merge, tag or publication is authorized by this slice.
