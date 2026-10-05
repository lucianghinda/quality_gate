# Live agent repair-loop acceptance

**Goal:** reproduce and evaluate native agent feedback and repair in an installed
Rails host without confusing simulated hook calls or manually clean gates with
live-agent evidence.

**Source:** merged main `a4aabf8a865642e7ac19b4fb40321f1f1fe2a27d`, isolated
`codex/agent-repair-loop` worktree. The user authorized implementation with Luna
subagents and is handling the 0.3.0 release independently. No release/tag/version
actions belong to this work.

## Decisions and limits

- The user accepted the proposed repeatable edit → feedback → repair → clean
  verification trial for Codex and Claude. Build the runner and perform live trials.
- Keep the new tooling under `bin/` and `test/support/`, outside the public gem
  manifest. Normal tests and CI never invoke paid agent sessions or require agent
  credentials. Use Ruby standard-library tooling and the existing installed bundle;
  add no dependencies, lint suppressions or weaker coverage policy.
- The default host is a real, bootable Rails acceptance application, made from the
  existing base/clean fixture and installed gem archive. This is live-agent fixture
  evidence, not sustained adoption in an active application. A separate user's
  application trial needs its selected path; that information has been requested
  while independent implementation proceeds.
- Package loading must resolve the installed archive, not the source checkout.
  Record its version, SHA256 and resolved path. Reuse local gem dependencies and
  lock locally; installation must not silently install additional dependencies.
- Never edit client trust/configuration files directly in user home or use
  hook/permission bypass flags. Codex requires native project trust and exact hook review through
  `/hooks`. Claude print mode executes reviewed project hooks without its usual
  trust dialog; inspect the generated configuration/scripts before launching it.
- Instrument hook commands only in the isolated fixture with a standard-library
  recorder forwarding original stdin, stdout, stderr and exit status to the exact
  installed generated launcher. It adds observations, not findings or repairs.
  Native client transcripts and hook session identifiers must corroborate those
  observations. Direct recorder/hook tests are always synthetic evidence.

Alternatives considered: existing direct launcher tests alone cannot establish
native activation; modifying production hooks just to collect acceptance evidence
widens runtime behavior unnecessarily. Use an external fixture recorder and native
session transcript instead. A deterministic fake agent is useful for regressions,
but never substitutes for a real Codex/Claude session in published claims.

## Tooling and command contract

`bin/agent_repair_acceptance` provides `prepare`, `run` and `report` plus help.

```sh
ruby bin/agent_repair_acceptance prepare tmp/trial --gem pkg/quality_gate-0.3.0.gem --client claude --scenario fast
ruby bin/agent_repair_acceptance run tmp/trial
ruby bin/agent_repair_acceptance report tmp/trial
```

Client is `claude` or `codex`; scenario is `fast` or `verify`. The app is created
at `DIRECTORY`; controller receipts and the recorder live in its sibling
`DIRECTORY.evidence`, outside the native workspace. Both destinations must be new;
preparing refuses overwrite rather than changing an existing app.
Each trial has one immutable manifest and one native session. Use a fresh directory
for repeats or the other client/scenario. Missing clients, invalid input and failed
setup produce actionable failures, not successful acceptance. A run is explicit,
bounded (default 600 seconds) and not part of `rake test`.

Prepare copies existing Rails base/clean fixture content, installs the selected gem
into an isolated GEM_HOME with `--local --ignore-dependencies`, uses that installed
package in the host bundle, and runs the real Rails generator with both client hook
options tested in separate fixtures (`--agents` or `--codex`). Configure only real
RuboCop fast and test-suite/Undercover verification;
no fake analyzer output. Give Undercover the local `main` comparison point. Commit
the baseline, check both gates are clean and record HEAD, configuration/test-helper
and generated-hook digests, including installed package files. Runtime logs/caches
are ignored in the fixture.
Do not capture credentials or private client/user configuration.

Installed generated hook commands are wrapped through the copied recorder. Their
event/matcher/timeout contracts remain intact. The recorder persists JSONL with
client, event, session ID, tool name/tool-use ID if supplied, UTC start/end, exact
launcher output/status, and current `lib/calculator.rb`/test source digests. Forward
output/status exactly even for unavailable/malformed-input results. Record errors
must not fabricate success. The expected injected source bytes are part of the
manifest so initial-defect observations are checkable.

The session prompt requests one initial native edit introducing the controlled
scenario, preserving configuration, baseline tests, hooks and Git history. It
does not explain the defect, give repair instructions or inject a second prompt.
Normal installed feedback must cause follow-up edits. The fast scenario introduces
spacing offenses in the existing addition method; behavior remains addition. The
verify scenario adds subtraction without new tests, requiring the same behavior
to remain present after repair and a new test file rather than weakening the
baseline tests/helper. An initial edit that arrives already repaired is inconclusive.

Codex launch uses its installed `exec --json --sandbox workspace-write` surface
after native review. Per-invocation configuration clears additional writable
roots and excludes global temp directories; approval policy `never` refuses
requests to expand the fixture sandbox. Native trusted hooks can write sibling
receipts. User configuration files are not edited. Claude uses
`-p --output-format stream-json --verbose
--include-hook-events` with a bounded turn count and only Read/Edit/Write tools.
This prevents an inherited broad shell permission from turning the trial into a
manual gate-and-repair exercise. Hook execution and independent final checks still
use the real installed gate and tests. Preserve raw native output
only in the ignored local trial; retain a dated, compact summary for review.
Use the already tested Adapter process capture/termination boundary where practical
instead of inventing another generic process manager. Timeouts must stop only the
owned child process group and remain explicit unavailable evidence.

## Evidence contract

The driver writes `manifest.json`, `session.json` (client version, command, UTC
start/end, status, raw JSONL stdout/stderr), `hooks.jsonl`, and final gate results.
These files live in the sibling evidence directory. Run holds the original
manifest in memory and checks its digest after the client exits; report checks
the saved digest again. The evaluator rejects native edits outside the scenario
source and permitted new test files, including edits to ignored controller files.
The evaluator consumes one hash:

| Key | Required fields |
| --- | --- |
| `manifest` | `schema_version: 1`, `client`, `scenario`, `root`, `prepared_at`, `source_path: lib/calculator.rb`, `seed_sha256`, `package` (`version`, `sha256`, `resolved_path`), `baseline` (`fast`, `verify` gate runs), `protected_files` (relative-path SHA256 map), `head`, `prompt` |
| `session` | `kind: native`, `client_version`, UTC `started_at`/`completed_at`, `status`, `stdout` (JSONL), `stderr`, `timed_out: false`, `extra_prompts: 0` |
| `hooks` | Array of recorder records, each with `client`, `event`, `session_id`, `tool_name`, optional `tool_use_id`, UTC `started_at`/`completed_at`, `status`, `stdout`, `stderr`, `source_sha256` and `test_sha256` (relative-path digest map) |
| `final` | `fast`/`verify` gate runs, `behavior`, `protected_files_unchanged`, `allowed_mutations_only`, `head_unchanged` booleans |

`gate_run` is `{ "status" => Integer, "report" => parsed_gate_json }`.
Checks belong to `report["checks"]`. Expected tools are exactly RuboCop for fast
and test-suite/Undercover for verify; each must report `clean`. Recorder records
also include newly appended generated Claude `hook_log` entries when available.
`Evidence.new(evidence).call` returns a JSON-safe hash containing `outcome`,
`reasons`, `client`, `scenario`, `observations` and dated source/session metadata.
Outcomes: `automatic_repair_observed`, `not_observed`, `unavailable`.
Only the first permits report/run exit 0; missing/uncorroborated/failed repair is 1,
and invalid input, unavailability, timeout or tool failure is 2. Do not label a
trusted project or installed hook alone as active or successful.

Success requires all of these:

1. Clean pre-trial fast/verify with nonempty expected check lists and no skipped
   checks/tool failures; package identity and manifest complete.
2. A real native session, successful process/turn completion, native edit to the
   scenario source and hook payload session identity corroborated by that transcript.
3. The initial source digest equals the controlled defect. For fast, PostToolUse
   delivers targeted RuboCop findings; for verify, Stop delivers test/Undercover
   findings and requests continuation. Hook output must actually carry that finding.
4. A later native edit and hook observation show the repair (changed source for
   fast; added tests for verify), followed by a clean native hook check. Fast
   requires the repaired edit's clean PostToolUse result. Restoring the original
   source bytes can legitimately make Claude Stop skip for no Ruby changes;
   independent final verification still runs. The verify scenario requires a
   clean Stop verification after the new test edit.
5. Independent final fast and verify are clean, original behavior holds, subtraction
   remains in the verify scenario, and protected config/hooks/baseline tests/HEAD
   are unchanged. Only the scenario source and newly added test files may change.
   The final manual gate is corroboration, not the repair trigger.

Unknown/malformed transcripts, missing activation, merely registered commands,
skips/debounce in place of the required clean check, unavailable execution,
capped retries, manual hook calls or
shell-only edits cannot satisfy success. Synthetic protocol regressions test the
evaluator, not live client compatibility. This protects against the named false-
positive risks of config weakening, stale clean output and operator-assisted repair;
it is an observation record, not a security attestation against a hostile operator.

## Implementation tasks and ownership

1. Luna evidence/recorder lane owns
   `test/support/agent_repair_acceptance/evidence.rb`, `hook_capture.rb`, and
   `test/acceptance/agent_repair_evidence_test.rb`/recorder tests. Start with failing
   positive/negative evidence cases. Preserve exact launcher IO/status. Share the
   final record shape promptly with the workflow lane.
2. Luna workflow lane owns `bin/agent_repair_acceptance`, loader/project/session/
   command support files and their focused tests. Reuse existing Rails fixtures,
   respect the evidence interface and local artifact provenance. Test overwrite
   refusal, malformed arguments, explicit invocation, baseline protection, missing
   executable and timeouts. No model calls in ordinary tests.
3. Leader integrates, runs actual package/fixture baselines and live clients,
   distinguishes activation/session blockers from product defects, and owns
   `docs/dogfood-log.md`, this implementation record and the external roadmap.
4. Independent Luna specification review precedes Ruby simplicity review. Fix
   reported issues with focused regressions and preserve one atomic Lore commit.

## Review cleanup plan

The independent Luna Ruby review found two unused declarations. Existing project
and evidence regressions protect behavior. Remove only the uncalled
`configure_local_compare_point` method and unused `Evidence::OUTCOMES` constant,
then rerun those focused tests and RuboCop. No additional abstraction or behavior
change is needed.

## Verification

### Trial corrections

Initial live trials exposed two driver issues, fixed with deterministic
regressions: Claude's native command/argument fields must remain separate, and
final manifest hashing must read the sibling evidence directory. The completed
Claude sessions were preserved; their final gates were collected independently
after the directory fix, with the original manifest digest checked before report
evaluation. No agent prompt, edit or hook was replayed to obtain those results.

The initial verify seed used an endless subtraction method. Codex added it without
tests, but Undercover considered its definition line covered. That trial remains
`not_observed`. The final seed uses a multiline method with an unexecuted body.
A real installed-package regression requires a clean test suite and an
`undercover/uncovered_code` finding before any repair. Fresh fixtures are used
for the corrected trials; preemptive test additions still do not prove repair.

Complete manifest and clean-baseline validation runs before client lookup,
including package version/digest, seed, protected files and commit identity.

- [x] Meaningful deterministic regressions pass; direct recorder cases are synthetic.
- [x] Rails fixture loads installed package and both baseline gates are clean.
- [x] Live Claude/Codex attempts have dated, correctly classified evidence.
- [x] Fixture evidence is identified separately; no active-application trial claimed.
- [x] Existing fast/full verify, project RBS and package/diff checks pass unchanged.
- [x] Independent Luna specification and Ruby simplicity reviews approve.

Final local verification passed on Ruby 4.0.1: fast RuboCop, test suite,
Undercover, SimpleCov, project RBS and diff checks. Coverage is 98.68% line and
92.35% branch against unchanged 96%/83% budgets. The built gem has 90 public
files matching source; developer tooling, tests, local receipts and this internal
plan are excluded. The curated `llm.txt` regenerated unchanged.

Claude Code 2.1.284 and Codex CLI 0.160.0 both showed automatic fast repair:
native initial edit, targeted PostToolUse finding, later native repair and a
clean hook, with independent final gates and protected state checks passing.
Both clients added tests proactively in the corrected verify trials, before any
Stop finding. Those trials are `not_observed`, despite clean Stop/final checks.
A native Stop-triggered coverage repair remains unproven. The public
[dated summary](../dogfood-log.md) records package identity and these limits.
The installed-gate seed regression failed against the old endless definition
(expected exit 1, actual exit 0) and passed with the final multiline body.

Delivery uses one atomic Lore commit and PR. Exact-head hosted CI and archive
identity are recorded in the ignored post-commit package receipt, preserving
the verified source rather than editing it to append CI metadata.

Public docs explain reproduction, explicit agent invocation/cost, native review,
receipt interpretation and privacy boundaries. Public summaries omit private app
identifiers/absolute host paths. Raw session/trust evidence stays in ignored local
trial directories. Results and post-commit CI will be recorded without retesting
or modifying frozen source merely to add metadata. Release publication is external
to this task and remains owned by the user.
