# Validation guide

The public acceptance fixtures exercise four representative incident classes with
shipped defaults: N+1 queries, unsafe migrations, complexity creep, and untested
changed code. The [incident catalogue](incidents.md) maps each class to its fixture,
command, and expected finding. These fixtures test detection behavior; they do not
establish compatibility with every application or dependency version.

## Reproduce the checks

After installing development dependencies, run the executable incident contracts:

```sh
bundle exec ruby -Itest test/acceptance/incident_catalog_test.rb
```

Run the complete test suite and aggregate coverage checks with:

```sh
COVERAGE=1 bundle exec rake test
```

Latency checks are opt-in because load and runtime configuration affect results:

```sh
QUALITY_GATE_ACCEPTANCE_TIMING=1 bundle exec ruby -Itest test/acceptance/latency_test.rb
```

The fixture budgets are below 2 seconds for a warm file-scoped `fast` run and below
3 seconds for the installed hook round trip. These are test targets, not measured
release guarantees. A skipped timing check provides no latency evidence.

## Live agent repair trials

From a repository checkout, the maintainer runner can prepare an isolated Rails
host using a built gem and collect native client evidence. It is development
tooling and is not installed by the gem. Ordinary tests and CI do not start agent
sessions; `run` explicitly uses the selected client's credentials and usage budget.

```sh
bin/prepare_release
ruby bin/agent_repair_acceptance prepare tmp/claude-fast --gem pkg/quality_gate-0.3.0.gem --client claude --scenario fast
ruby bin/agent_repair_acceptance run tmp/claude-fast
ruby bin/agent_repair_acceptance report tmp/claude-fast
```

Use a fresh destination for each trial. Choose `--scenario verify` to add a
behavior without tests and exercise Stop feedback. The runner refuses existing
destinations and their sibling evidence directories. It records the installed
package identity, clean baseline, protected configuration, controlled initial edit,
native session and final gates.

For Codex, prepare with `--client codex`, start Codex in that generated host and
review its project and both exact hook definitions through `/hooks` before running
the trial. The runner never changes client trust or uses bypass flags. Claude print
mode executes project hooks without its normal trust dialog; inspect the generated
settings, recorders and launchers before starting it. Each fixture hook command
passes its original input/output and status through a recorder; only the native
client can supply the live event chain used in a successful trial.

Only `automatic_repair_observed` with exit 0 counts as a completed loop. It requires
native edit and hook feedback followed by a repair, clean verification and unchanged
protected files/history. Missing activation, silent skips, caps, manual hook calls,
shell-only edits and a clean final gate by itself are not successful automatic
repair evidence. `not_observed` exits 1; invalid or unavailable execution exits 2.
The Codex session uses workspace write permissions with additional writable roots
and temporary-directory writes disabled. Claude exposes only Read, Edit and Write
tools. Trusted native hooks can still run the installed gates. The runner's
deterministic protocol tests are synthetic and prove its classification rules,
not native client activation.

The app is at `DIRECTORY`; its manifest, recorder, native session, hook observations
and final report are in the sibling `DIRECTORY.evidence` directory. Reports check
the original manifest digest, installed gem files, protected project files and
native edit paths. These are observation records, not an adversarial attestation
against malicious application code or the host operator.

Keep raw sessions and receipts in ignored local trial directories. Publish only
a dated summary without workstation paths, session identifiers, credentials or
private application details. A live Rails fixture trial is distinct from validation
in an active application and from sustained adoption or performance measurements.

## Interpretation and limits

### Native fixture trials — October 5, 2026

These trials used the installed 0.3.0 archive with SHA256
`293b10d93943912e222f4f3d212df61753d65825bdde7803f6b627f2fd24742c`.
Every listed trial completed with clean independent fast/verify gates, preserved
behavior, protected files and Git history.

| Client | Scenario | Outcome | Observation |
| --- | --- | --- | --- |
| Claude Code 2.1.284 | fast | `automatic_repair_observed` | Write introduced the spacing defect; PostToolUse reported it; Edit repaired it and its hook was clean. |
| Codex CLI 0.160.0 | fast | `automatic_repair_observed` | Native patch introduced the spacing defect; PostToolUse reported it; a later patch repaired it and its hook was clean. |
| Claude Code 2.1.284 | verify | `not_observed` | Added tests before Stop reported a finding; Stop was clean. |
| Codex CLI 0.160.0 | verify | `not_observed` | Added tests before Stop reported a finding; Stop was clean. |

The final verify seed uses an untested multiline subtraction body. An installed
gate regression confirms that this body produces an Undercover finding without
tests. Earlier setup attempts and an endless-method seed were inconclusive and
do not contribute successful evidence. Both clients demonstrated automatic fast
repair; a native Stop-triggered coverage repair remains unproven. These are
isolated Rails fixture observations, without active-application or adoption claims.

A clean gate means its configured tools completed without reportable findings.
A timeout, unavailable tool, skipped comparison, or unsupported dependency is not
proof of clean application behavior. Inspect findings and warnings alongside exit
status. The Stop hook can fail open when verification is unavailable; that outcome
must not be counted as successful verification.

Application initialization and third-party compatibility can prevent installation
or checks from completing. Validate the generator, optional initializers, and all
configured gates in the target application. Fixture results do not guarantee
production compatibility, performance, reduced review time, or agent adoption.

The public release includes reproducible fixture contracts rather than private
application records. No current production cohort measurements are claimed.
