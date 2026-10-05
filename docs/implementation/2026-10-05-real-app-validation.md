# Real-application validation pilot

Status: initial installation trials recorded in two private applications;
onboarding repairs and finding triage are required before rollout.
Ordinary-session repair, sustained adoption and review-time results remain open.

## Purpose and scope

Validate QualityGate 0.3.0 in two existing applications during ordinary work.
Measure installation effort, useful findings, false positives, gate latency,
native agent feedback and review effort. Use the published gem in each app's
bundle. Keep the fixture results in [the validation guide](../dogfood-log.md)
distinct from this pilot.

The user has authorized starting this phase and supplied two application paths.
Their identities and source revisions belong in the private pilot records.
Preserve each app's existing client setup unless the user selects another.

The existing [incident catalogue](../incidents.md) covers N+1 queries, unsafe
migrations, complexity and untested changes. The
[Codex integration guide](../codex.md) and README define supported installation,
gate scopes and native activation. This pilot uses those existing capabilities;
it does not add analyzers or a new measurement framework.

## Sequence and ownership

1. **Leader: record the pilot before editing adoption instructions.** Write this
   plan and a private app/session record template. Update the external product
   roadmap to identify the pilot as the current work.
2. **Documentation lane:** reconcile README availability with the published
   0.3.0 release; add an ordered real-app adoption procedure to
   `docs/dogfood-log.md`. Keep fixture evidence and pilot targets distinct.
   Existing documentation/distribution tests protect the public contract;
   runtime code and dependencies remain unchanged.
3. **Leader, after app selection:** inspect each app's instructions, clean/dirty
   state, Ruby/Rails versions, test runner, existing gate configuration, Git
   history and test services. Create an isolated worktree at a recorded commit.
   Establish the existing suite result before installation. Use the app's
   documented test database/services; a code worktree alone does not isolate
   databases or external services.
4. **Per-app installation:** add the released gem using the project's established
   bundle convention, preview setup, inspect proposed changes, install and
   integrate conflicts while preserving custom configuration. Run Doctor, fast,
   verify and audit independently; record actual check statuses and findings.
   Existing findings are observations to triage, not reasons to silently disable
   checks. Use a reviewed warning baseline only where needed and permitted by
   the baseline contract. Optional analyzers are evaluated later if app evidence
   establishes a need.
5. **Native activation and ordinary work:** review the selected client hooks and
   collect actual native edit, feedback, repair and final verification evidence
   during useful application tasks. Do not inject fixture Calculator code into
   an application. A controlled defect, if needed, belongs in a separate
   disposable trial and is labelled controlled rather than ordinary usage.
6. **Sustained observation:** begin with two weeks and at least ten eligible
   sessions per application. This is an initial pilot checkpoint; it does not
   replace the original one-month feedback and two-month adoption/review-time
   goals. Review evidence weekly and decide whether to retain the integration,
   fix an observed product problem or extend the sample.

## Measurements and acceptance criteria

| Area | Record | Initial checkpoint |
| --- | --- | --- |
| Provenance | App alias, commit, gem/client/runtime versions, config identity | Complete for both selected apps |
| Installation | Elapsed time, actual manual interventions, conflicts and boot/setup blockers | Reproducible setup changes; every blocker explained |
| Existing behavior | Before/after suite command and result | No unexplained regression caused by installation |
| Gate execution | Command, exit, check statuses/scopes, duration and findings | Each configured check executes or is explicitly recorded as unavailable/skipped |
| Fast latency | One cold and five warm file-scoped runs on a representative large Ruby file; native hook round trips separately | Compare each run and warm median/max with the existing <10-second target; no percentile claim from this sample |
| Finding usefulness | Actionable defect, intentional policy exception, false positive, duplicate or unresolved; repair effort | Every encountered finding classified or left explicitly unresolved |
| Agent delivery | Eligible sessions, hook activation, feedback delivery, unavailable/capped attempts | Report numerator/denominator; approximately 80% is the existing target, not an assumed result |
| Agent repair | Finding-bearing sessions and corroborated native feedback → later edit → clean result | Report observed repairs separately from proactive fixes, manual prompts and unobserved repairs |
| Review effort | Minutes and rough task size for comparable changes, with/without the former workflow | Descriptive comparison only; no claimed reduction without baseline observations |
| Retention | Working days used, disabled checks, manual-pipeline usage and reason | Explicit per-app keep/fix/stop decision at the checkpoint |

An eligible session changes a path supported by the intended integration using
the client's matching native edit tool, or attempts to finish after relevant code
changes. Eligibility does not require that a hook was actually active or fired.
Count missing/inactive hooks and unavailable/capped outcomes
in the appropriate denominators; do not discard unsuccessful attempts.
Record native feedback delivery separately from repair success. A session with no
findings cannot demonstrate a finding-triggered repair. If a metric cannot be
observed, write `unknown`, not zero.

For fast and Stop separately, the delivery rate is the number of event-eligible
sessions with observed native feedback divided by all sessions eligible for that
event. Inactive, unavailable and capped attempts remain in the denominator.
Report unknown observations separately: the observed-delivery fraction is a
lower bound when observation is incomplete, not proof that unknown events failed.
The approximately 80% target is assessed only with the accompanying sample size
and observation completeness.

Establish a client-specific observation method before counting native outcomes.
Claude's generated hook log and native transcript can support that record;
Codex does not provide the same QualityGate history log. Preserve native hook
output and corroborating edits when available, otherwise mark delivery/repair
unknown. Hook trust settings and the agent's narrative alone are not execution
evidence. Keep fast-event and Stop-event denominators separate.

The fixture runner remains useful for detector regressions and reproducibility.
Its `prepare` command creates a new fixture; it must not be pointed at an
existing app as an installation or adoption-measurement command.

## Records and boundaries

Raw records stay in ignored local storage or the application's private records.
Public documentation uses aliases and sanitized summaries. Do not publish source,
absolute paths, session identifiers, credentials or private finding messages.
Read app instructions and test service configuration before booting the app.
Do not copy production databases, run production migrations or send real
notifications as part of validation. Stop an app trial if its test environment
cannot be distinguished from production, and continue unaffected documentation
and other-app work.

A baseline may accept eligible historical warnings, but must not hide test,
security, coverage or tool failures. Record the before/after findings and any
policy adjustment. Do not equate a clean run with exhaustive correctness.

## Verification and delivery

- Check the documented commands against the shipped CLI/help and generator.
- Run existing evidence-documentation, distribution and LLM-index tests; inspect
  local links and the final documentation diff.
- Review this plan and guide independently before publishing a documentation PR.
- Verify each app's configuration and generated diff, then rerun its existing
  suite and configured gates after installation.
- Preserve raw evidence and publish only supported outcomes. Installation,
  controlled repair and sustained adoption are separate completion states.
- Record the documentation commit/PR separately from app installation branches.
  The overall pilot stays open until both real-app checkpoints are assessed.

## Initial onboarding findings — October 5

The published gem exposes integration work that the controlled fixture did not
settle. Keep the app branches local until deployment compatibility is resolved.

- **Framework selection:** Rails supplies its `test_unit` generator default to
  QualityGate's `test_framework` option, which accepts only `minitest` or `rspec`.
  A default preview fails; explicitly supplying `--test-framework minitest`
  allows setup. A product regression should exercise Rails option inheritance,
  not only construct the profile directly.
- **Runtime compatibility:** in app A, the default Bullet initializer prevents
  test boot because Bullet 8.2.0 rejects Active Record 8.2.0.alpha. An earlier
  trial without initializers passed its test step; that does not establish a
  working default installation. Keep the compatibility failure visible rather
  than silently disabling the detector.
- **Dependency groups and initializers:** generated initializers unconditionally
  require Bullet and StrongMigrations, while the documented dependency group is
  development/test. Excluding that group can leave production boot without those
  gems. This is a source-inspection risk; no production boot was attempted.
- **Existing lint policy:** preserving host RuboCop configuration also preserves
  its quoting rules. Generated single-quoted strings needed a narrow manual
  adjustment. The retained host policy does not prove that QualityGate's shipped
  custom rules are active.
- **Private artifacts:** generated coverage output needs an app ignore entry
  when one does not already exist. Keep it outside installation commits.

These observations prioritize onboarding repairs and finding triage ahead of
another analyzer. No warnings or failures were baselined to make the trial green.

## Initial gate results — October 5

Both isolated worktrees use the published 0.3.0 gem and Ruby 4.0.1. The apps'
original checkouts were left alone. Results below are installation evidence,
not native agent or sustained-adoption evidence.

| Check | App A | App B |
| --- | --- | --- |
| Existing suite | 559 tests / 2,651 assertions; passed | 1,078 tests / 3,860 assertions; passed |
| Suite with default initializers | Boot blocked by Bullet / Active Record 8.2 alpha incompatibility | Same tests and assertions; passed |
| Full fast after generated quote alignment | Clean under retained host policy | Clean under retained host policy |
| Verify | 706 Reek findings plus the test boot failure | 1,337 Reek findings; tests and Undercover clean |
| Audit after advisory refresh | Brakeman and Bundler Audit clean | Brakeman clean; 10 dependency findings representing 4 distinct advisories |
| Native integration | Claude and Codex files installed; activation unobserved | Codex files installed; activation unobserved |

App B's affected dependency versions were already present before installation;
seven audit entries represent different locked platforms for one advisory.
Findings remain unresolved, not automatically classified as confirmed defects.
App B also reports four Reek findings in generated coverage setup. App A's
Undercover result reports clean, but its failed suite means that result cannot
establish a successful default coverage run. Initial sandbox socket failures and
failed advisory refreshes were kept separately from the successful elevated
command retries; an old cached audit result was not used as current evidence.

The immediate next work is the Rails onboarding repair described above, followed
by rerunning these trials and reviewing existing findings. Ordinary-session
observation starts only once the integration is usable; the two-week checkpoint
has not been satisfied by these setup runs.

Documentation validation: 40 focused tests / 711 assertions passed, project
fast passed, and independent Luna review found no privacy or evidence blocker.
Runtime product code and package dependencies are unchanged by this docs change.
