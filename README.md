# QualityGate

QualityGate gives Ruby projects one workflow for checking changes: quick feedback while editing, verification before finishing, and a separate security audit. Set up a plain Ruby project with `quality_gate init`, or a Rails application with the Rails generator.

The `fast` gate runs RuboCop, with optional adapters such as Herb. `verify` runs Reek, the test suite, and Undercover in order. For `audit`, Rails defaults run Brakeman followed by bundler-audit; the Ruby setup uses bundler-audit alone.

This source prepares the 0.3.0 release candidate; it has not been published to RubyGems yet. The latest RubyGems release is 0.2.2; the latest GitHub release is v0.2.3.

The optional `deep` gate is introduced in 0.3.0. Its default adapter is RubyCritic; Debride can be enabled explicitly for project-wide potentially unused method candidates. The gate runs only when requested, and `--files` does not narrow either analyzer.

## Quick start

Add QualityGate to your Gemfile using the [installation instructions](#installation). For a Ruby gem or application with an existing test suite, run:

```sh
bundle install
bundle exec quality_gate init --profile ruby
bundle exec quality_gate fast
bundle exec quality_gate verify
```

For Rails, replace the init command with `bin/rails generate quality_gate:install`.

Review the installer summary: existing configuration is preserved, and conflicts require manual integration. Claude hooks are optional; add `--agents` to install them. Add `--codex` to install the native Codex Stop hook and owned `AGENTS.md` contract. Codex activation requires a trusted project and hook review in `/hooks`; see the [Codex integration guide](docs/codex.md). Use `--pretend` to preview filesystem changes. See [Ruby setup](#plain-ruby-and-other-test-runners) for test-runner selection and command overrides.

The same commands work from your terminal and CI. QualityGate runs existing tools, collects their findings, and distinguishes code findings from tools that could not complete. A clean result only describes the configured checks and their scope.

## Commands

Run from the project root. Discover commands and scope without running checks:

```sh
bundle exec quality_gate --help
bundle exec quality_gate verify --help
```

Run the installed `quality_gate` executable through Bundler:

```sh
bundle exec quality_gate version
bundle exec quality_gate fast
bundle exec quality_gate verify
bundle exec quality_gate audit
```

### Deep analysis (introduced in 0.3.0)

The `deep` gate is invoked explicitly and supports the usual output formats:

```sh
bundle exec quality_gate deep --format text
bundle exec quality_gate deep --format json
bundle exec quality_gate deep --format markdown
```

RubyCritic is optional and is not installed by QualityGate. Add it to the host project's Gemfile (for example, `gem "rubycritic", "~> 5", require: false`) and run `bundle install` before invoking the gate. The default is `deep: [rubycritic]`; `commands.deep.rubycritic` overrides the launcher argv prefix, with the adapter supplying RubyCritic's analysis flags and managing its output directory. Its timeout can be set with `timeouts.rubycritic` (otherwise the existing 120-second default applies).

```yaml
adapters:
  deep:
    - rubycritic
commands:
  deep:
    rubycritic:
      - bundle
      - exec
      - rubycritic
timeouts:
  rubycritic: 120
```

RubyCritic analyzes the project as a whole; `--files` does not narrow this gate. Its findings complement tests and security checks and may overlap Reek. QualityGate does not add a score budget or minimum; RubyCritic owns its score. A completed analysis with no smells exits `0`, reported smells exit `1`, and missing input, configuration, or tool failures exit `2`. A report containing no analyzed Ruby modules is a tool failure, not a clean result. The JSON report is captured through a temporary file that QualityGate removes on success or failure; the adapter does not request HTML output or project-local report artifacts.

#### Debride: potentially unused methods

Debride is an optional host-project dependency; QualityGate does not install it. Add it to the project's Gemfile and install the bundle before enabling the adapter:

```ruby
gem "debride", "~> 1.15", require: false
```

Select Debride alone or alongside RubyCritic in `.quality_gate.yml`:

```yaml
adapters:
  deep:
    - debride
timeouts:
  debride: 120
```

To run both analyzers, add `- rubycritic` before `- debride`. The default remains `deep: [rubycritic]`. The Debride command defaults to the `debride` executable; `commands.deep.debride` overrides its launcher argv prefix, and QualityGate appends `--json` and `.`. For Rails conventions with Bundler, for example:

```yaml
commands:
  deep:
    debride:
      - bundle
      - exec
      - debride
      - --rails
```

QualityGate adds `--json` and `.` after this prefix. It does not select framework options automatically. Leave `--verbose` off: Debride stderr diagnostics, including launcher chatter, make the result a tool failure. `timeouts.debride` uses the existing 120-second default when omitted.

Debride examines the whole project even when `--files` is supplied. Its candidates can be false positives when code is reached through dynamic dispatch, external APIs, metaprogramming, or Rails callbacks. Treat them as review leads: QualityGate does not delete code or prove that a method is dead. Debride does not report how many Ruby files it analyzed, so an empty report can be clean while providing no guarantee that files were present or fully understood.

Debride returns `0` for a clean report or candidates; QualityGate maps these to gate exits `0` and `1`, respectively. Missing tools, timeouts, malformed output, and any stderr diagnostics are tool failures and make the gate exit `2`. This strict check matters because Debride can skip invalid Ruby files, print a warning, and still exit successfully. Keep custom launchers quiet and emit only Debride's JSON on stdout. Like the other adapters, the result uses the standard text, JSON, and Markdown reporters.

This gate is a manual command only. It does not add generated hooks or workflow steps.

The built-in fast path is meant for changed files:

```sh
bundle exec quality_gate fast --files app/models/user.rb
```

`verify` records coverage while it runs the full test suite, then checks changed code with Undercover. A clean `verify` or `audit` run prints this clean summary: one line per tool that ran, naming its status, scope, and duration, then the tally:

```text
reek         clean        project                 312ms
test_suite   clean        test_suite           189137ms
undercover   clean        git_diff                619ms
0 findings, 0 tool failures
```

(Durations above are illustrative, not measured figures.) These tool lines make a clean run visible: you see every tool that ran, not just an absence of findings.

Run a read-only setup preflight with `bundle exec quality_gate doctor`. It prints text by default; `--format json` emits a machine-readable report, regardless of the gate format in the project configuration. `--help` works without loading that configuration. Doctor rejects positional arguments, `--files`, Markdown output, and unknown options.

Doctor is introduced in 0.3.0.

Doctor checks configuration, runtime and bundle context, whether supported launch paths are available, Undercover's comparison point, required coverage evidence, and recent optional hook history. It does not execute analyzers, test suites, or application boot code; install or repair anything; fetch from Git; or establish that the application is clean or works. A ready launcher check means only that the inspected executable or explicit script was found. Custom wrappers and nested bare commands that cannot be resolved safely remain `unchecked`.

The report has scope `preflight`, checks with `id`, `status`, and `message`, and summary counts for every status. Each message describes what was observed and gives a next step when needed. Statuses are `ready`, `warning`, `blocked`, `unchecked`, and `not_applicable`. Exit `0` means applicable preflight checks are ready; `1` means a warning or unchecked observation remains; `2` means a blocker, invalid input, or report failure. `not_applicable` is neutral. These results describe preflight observations, not gate findings or proof of application health.

Coverage artifacts are inspected only when an enabled adapter needs them. Before the first suite run, missing coverage is `unchecked`; run `bundle exec quality_gate verify` to create the evidence. Doctor reads at most 1 MiB from each artifact and does not check freshness, coverage wiring, or budget compliance. Hook history is advisory: absent optional hooks are `not_applicable`; installed hooks without valid history are `unchecked`; and valid history does not verify that hooks are currently installed. The Git comparison probe has a shared five-second budget and never fetches history.

If Bundler prevents the `quality_gate` command from starting, Doctor cannot run. Check Ruby and Bundler outside QualityGate with `ruby -v`, `command -v ruby`, `bundle --version`, and `bundle check`; these are manual troubleshooting commands, not Doctor checks.

Use `--files` to select paths for RuboCop and Reek; the first path follows the option and further paths follow it as separate arguments:

```sh
bundle exec quality_gate fast --files lib/quality_gate.rb test/test_quality_gate.rb
```

Paths must exist, including paths from the configuration file. Any missing path returns exit `2` before tools run. A bare `fast` scans the project; it does not discover changed files automatically. RuboCop is the only default fast adapter, so a clean bare `fast` run prints one tool line then the tally:

```text
rubocop      clean        project                  842ms
0 findings, 0 tool failures
```

(842ms above is illustrative, not a measured figure.)

| Adapter | Scope with `--files` |
| --- | --- |
| RuboCop, Reek | Selected files/directories, subject to the tool's exclusions |
| Herb | Project scan, or selected ERB files/directories; unrelated files are omitted |
| Test suite | Full configured suite |
| Undercover | Git changes against the comparison point |
| SimpleCov | Aggregate coverage summary |
| Brakeman | Whole application |
| bundler-audit | Gemfile.lock |

`verify --files app/models/user.rb` therefore narrows Reek, but still runs the full suite and checks Git changes. JSON includes each adapter's scope and status. When stderr is a terminal, progress names each tool before it starts; redirected output and hook invocations remain quiet except for diagnostics.

Choose text, JSON, or Markdown output with `--format text`, `--format json`, or `--format markdown`:

```sh
bundle exec quality_gate verify --format json
bundle exec quality_gate verify --format markdown
```

The shorter form `quality_gate version` works when the installed executable is already on your `PATH`.

The repository config must also use exactly `text`, `json`, or `markdown` for `format`; any other configured value is rejected as a configuration error before a gate runs.

## Warning baselines

Fast and verify can compare their current results with an explicitly created warning baseline. The feature is disabled by default. Create a snapshot, then compare it on later runs:

```sh
bundle exec quality_gate fast --create-baseline config/fast-baseline.json
bundle exec quality_gate fast --baseline config/fast-baseline.json
# After resolving findings, shrink the accepted set.
bundle exec quality_gate fast --ratchet-baseline config/fast-baseline.json
```

`--baseline PATH` accepts existing entries while reporting new or protected findings normally. `--create-baseline PATH` writes only when every finding is eligible for the snapshot. `--ratchet-baseline PATH` compares first and shrinks the snapshot only when the run has no new or protected findings; a blocked ratchet keeps the original bytes and exits with the ordinary findings or tool-failure status. All three options work only with `fast` and `verify`, are mutually exclusive, and use the command's `--format` reporter. Creation and ratcheting require a full scan: they reject `--files` and non-empty configured `files` before running tools. Comparison can use `--files` and never writes the snapshot.

Baselines store only warning and info findings from RuboCop, Reek, and Herb. Errors, tool failures, test and security results, coverage results, and other analyzers remain enforced. Matching uses tool, normalized project-relative file, rule, severity, and message plus a bounded duplicate count; line numbers do not participate, so moving a finding within its file does not make it new. Identical findings in one file are interchangeable up to their stored count, and the snapshot does not prove semantic identity or source provenance. Review analyzer configuration whenever using ratchet, and review manual baseline JSON edits in Git.

Analyzer process status also remains part of the result contract: RuboCop accepts exits `0` and `1`, while Reek accepts `0` and `2`. Other statuses and process signals fail the tool. Reek's explicit “cannot be processed” source diagnostic also fails the tool even if its JSON is empty and the process exits successfully.

The versioned JSON snapshot records its gate, configured adapter order, and finding entries. It must match the gate and current adapter list exactly. The parent directory must already exist. A successful create or ratchet writes before report output; an output-stream failure does not undo that completed file write. This is a reviewed warning policy for QualityGate results, not a replacement for RuboCop's `.rubocop_todo.yml` mechanism.

Snapshots contain analyzer messages and project-relative paths, so treat them as belonging to the host project. Keep baseline files in the project that owns the findings; do not ship them with QualityGate.

To enable comparison from `.quality_gate.yml`, add a gate-to-path mapping. It remains disabled for gates not listed:

```yaml
baseline:
  fast: config/fast-baseline.json
  verify: config/verify-baseline.json
```

An explicit `--baseline PATH` takes precedence for that invocation. `quality_gate <gate> --help` documents the command-line options without loading configuration.

## Output contract

Gate text output prints, in order: one line per tool that ran, then findings, then the tally.

When a baseline is active, checks keep each adapter's raw status while the finding list and JSON summary describe enforced findings after comparison. The JSON `baseline` object reports the mode, accepted finding records, counts, and whether a create or ratchet write completed. Without a baseline, JSON retains the existing `checks`, `findings`, and `summary` shape.

When at least one tool ran, each gets a line naming the tool, its status, what it inspected, and how long it took:

```text
<tool> <status> <scope> <duration>ms
```

`status` is `clean`, `findings`, `tool_failure`, or `skipped`; `scope` describes what the tool inspected, such as `project`, `selected_files`, `git_diff`, `test_suite`, `coverage_summary`, or `lockfile`. These lines distinguish a clean run, which always names its tools, from a run where nothing executed. An empty adapter list runs no tools and prints none of these lines.

Findings come next, with tool, severity, location when available, rule, and message:

```text
<tool> <severity> <file>:<line> <rule> <message>
```

Multiline messages retain indented detail lines. Findings without a source location omit it rather than printing `:0`. The final gate output line is unchanged, the summary:

```text
<n> findings, <m> tool failures
```

JSON output is one object plus a trailing newline. The top-level keys are `"findings"`, `"summary"`, and `"checks"`. Each finding object has exactly these keys:

- `"tool"`
- `"file"`
- `"line"`
- `"rule"`
- `"severity"`
- `"message"`

The summary object has exactly these keys:

- `"findings"`
- `"tool_failures"`
- `"failed_tools"`

Example:

```json
{
  "findings": [
    {
      "tool": "rubocop",
      "file": "lib/example.rb",
      "line": 7,
      "rule": "Layout/LineLength",
      "severity": "warning",
      "message": "Line is too long"
    },
    {
      "tool": "brakeman",
      "file": "",
      "line": 0,
      "rule": "tool_failure",
      "severity": "error",
      "message": "timed out"
    }
  ],
  "summary": {
    "findings": 2,
    "tool_failures": 1,
    "failed_tools": ["brakeman"]
  },
  "checks": [
    {"tool": "rubocop", "status": "findings", "scope": "project", "requested_files": [], "duration_ms": 120},
    {"tool": "brakeman", "status": "tool_failure", "scope": "project", "requested_files": [], "duration_ms": 120000}
  ]
}
```

`checks` lists invoked adapters in execution order. Each entry has `tool`, `status`, `scope`, `requested_files`, and `duration_ms`. Status is `clean`, `findings`, `tool_failure`, or `skipped`; scope is `selected_files`, `project`, `test_suite`, `git_diff`, `coverage_summary`, `lockfile`, or `unknown`. `requested_files` describes selection input for RuboCop/Reek, not an inventory of files actually examined: tool exclusions still apply. Empty adapter lists produce `checks: []` and run no checks. Durations are observations, not performance guarantees.

When `--format json` is requested, input/configuration failures use the same report envelope with a `quality_gate` tool failure and exit `2`. Use an explicit format flag if malformed YAML might prevent loading your configured format. Inspect exit status as well as the report; a process that cannot start or write stdout cannot produce a JSON report. Help and version remain plain text.

Consumers should tolerate additive JSON fields. Existing finding and summary fields retain their meanings. An informational Undercover skip remains a finding and returns exit `1`; it is not proof that changed code was covered.

Markdown output is for pasting into agent notes, pull request comments, and chat. It prints a level-two heading with the tally, a checks table when at least one tool ran, and a findings list when there are findings:

```markdown
## Quality Gate: 1 findings, 0 tool failures

| Tool | Status | Scope | Duration |
| --- | --- | --- | --- |
| rubocop | findings | selected_files | 1240ms |

### Findings

- **rubocop** warning `lib/a.rb:4` Layout/First: First message
  Second message line
```

Locations are code spans, extra message lines are indented under their finding, and pipe characters in table cells are escaped. Message punctuation is escaped so diagnostic HTML and Markdown markers display literally. Input and configuration errors keep the plain-text stderr behaviour; only JSON has a machine-readable error envelope.

## Configuration

QualityGate looks for `.quality_gate.yml` in the working repository. Values in that file override the shipped defaults for known top-level keys:

```yaml
format: text
files:
  - lib/quality_gate.rb
adapters:
  fast:
    - rubocop
  verify:
    - reek
    - test_suite
    - undercover
  audit:
    - brakeman
    - bundler_audit
commands:
  fast: {}
  verify:
    test_suite:
      - bin/rails
      - test
  audit: {}
timeouts:
  default: 120
  rubocop: 10
  test_suite: 120
  undercover: 120
compare_point:
rubocop_config:
# baseline: {}
```

Default adapters when no project configuration overrides them (the Rails setup uses these; Ruby init writes its own test command and omits Brakeman):

- `fast` => `rubocop`
- `verify` => `reek`, then `test_suite`, then `undercover`
- `audit` => `brakeman`, then `bundler_audit`
- `deep` => `rubycritic` (introduced in 0.3.0; manual invocation only)

Default timeouts:

- `default` => `120`
- `rubocop` => `10`
- `test_suite` => `120`
- `undercover` => `120`

`adapters` lists adapter names per gate. The built-in registry knows `rubocop`, `reek`, `test_suite`, `undercover`, `simplecov`, `brakeman`, `bundler_audit`, `herb`, `rubycritic`, and `debride`. SimpleCov, Herb, and Debride are registry-known optional adapters, not defaults. RubyCritic is the `deep` default; Debride can be selected alongside it or by itself. The default verify adapters are Reek, the test suite, and Undercover, in that order. Unknown adapter names still become reported tool failures instead of being ignored.

### Aggregate coverage budgets

To opt in to aggregate coverage enforcement, add `simplecov` to `adapters.verify` and configure at least one budget:

```yaml
adapters:
  verify:
    - test_suite
    - undercover
    - simplecov
coverage:
  minimum_line: 90
  minimum_branch: 80
```

`coverage.minimum_line` and `coverage.minimum_branch` are independent numeric percentage budgets in the inclusive range `0..100`. At least one is required when the `simplecov` adapter is enabled, and equality with the configured minimum passes. A valid `coverage` mapping alone is inert without `simplecov` in `adapters.verify`.

After the test suite runs, the adapter reads SimpleCov's `coverage/.last_run.json` summary without rerunning tests. When SimpleCov is configured in `verify`, QualityGate removes only that aggregate summary before the test command. A command that produces no fresh summary cannot pass using stale coverage. A missing or unusable record is a tool failure. A branch budget without usable branch data is also a tool failure and names `enable_coverage :branch` as the required SimpleCov setup. Coverage below a configured budget produces a stable error finding: `line_coverage_below_minimum` for the line budget and `branch_coverage_below_minimum` for the branch budget.

`timeouts` sets the default adapter timeout in seconds and allows per-tool entries. The shipped RuboCop timeout is 10 seconds, while the test suite and Undercover each have an explicit 120-second timeout. Brakeman and bundler-audit inherit the 120-second default.

### Projects with longer test suites

Measure a full test run with coverage enabled, then allow enough time for it in
`.quality_gate.yml`. For example, this gem uses a 240-second test-suite budget:

```yaml
timeouts:
  test_suite: 240
  undercover: 120
```

Raising only `timeouts.default` does not override the explicit `test_suite` or
`undercover` values. Adapters run sequentially, so the Claude Stop timeout must
exceed the combined budgets of the selected verify adapters, with extra time
for startup and reporting. For the example above, change the generated Stop
handler's `timeout` from `300` to `600` in `.claude/settings.json`. This also
leaves room for the optional SimpleCov adapter's inherited 120-second budget:

```json
{
  "type": "command",
  "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/quality_gate_verify_stop.rb",
  "args": [],
  "timeout": 600
}
```

Edit that handler inside the existing `hooks.Stop` entry, preserving other
hooks. This makes the settings developer-owned: future installer runs report
`Needs a person` when the file differs from known shipped templates. Review and
apply future settings updates manually while retaining the longer timeout.

An adapter timeout becomes `verify_unavailable` and allows the session to end.
Claude enforces the outer timeout itself and may terminate the hook before it
can write a log record. Check `log/quality_gate_hooks.jsonl` and run
`bundle exec quality_gate verify` manually after changing the budgets.

### Configuration validation

`adapters` must be a mapping whose only permitted keys are `fast`, `verify`, `audit`, and `deep`, and each layer value must be an array of non-empty strings. The mapping may specify any subset of those gates; unspecified gates keep the shipped defaults. A misspelled layer key such as `fasst` is rejected as a configuration error instead of silently falling back to a clean run.

`commands` follows the same four gate layers. Every command is an argv array of non-empty strings, never a shell command string. `commands.verify.test_suite` defaults to `["bin/rails", "test"]`; deep analyzer commands default to their executable names.

`compare_point` may be `nil` or a non-empty String. Set it to a Git ref or commit when CI has too little history to find a common ancestor automatically.

`rubocop_config` is a known top-level key. It must be `nil` or a non-empty String. Use it when you want QualityGate to pass an explicit `rubocop_config` path to RuboCop.

Config selection works like this:

1. If `rubocop_config` is set, QualityGate passes that path to RuboCop.
2. Otherwise, if the host project already has a RuboCop config such as `.rubocop.yml`, QualityGate lets RuboCop use the host config.
3. Otherwise, QualityGate passes the shipped `config/rubocop.yml` from this gem.

The shipped config loads `rubocop-rails`, `rubocop-performance`, and `rubocop-minitest`. It also sets the default metric budgets that the built-in fast gate enforces.

### Sandi Metz rules

The shipped config enforces Sandi Metz's four rules.

| Rule | Enforced by | Budget |
| --- | --- | --- |
| A class stays under a hundred lines | `Metrics/ClassLength` | `Max: 100` |
| A method says one thing in five lines | `Metrics/MethodLength` | `Max: 5` |
| Pass no more than four parameters | `Metrics/ParameterLists` | `Max: 4` |
| A controller action instantiates one object | `QualityGate/ControllerInstanceVariables` | `Max: 1` |

The first three are ordinary RuboCop budgets, so their upstream options apply unchanged. The fourth is a cop this gem ships, and unlike the convention cops below it is enabled by default. It counts the distinct instance variables a public controller action assigns, including `||=`, `+=`, multiple assignment, and assignments made inside a block. Private and protected helpers, class methods, nested classes, and classes whose name does not end in `Controller` are all ignored. It reads only the action's own body, so an instance variable set by a `before_action` callback does not count against the budget. Configure it like any other cop:

```yaml
QualityGate/ControllerInstanceVariables:
  Max: 2
```

Test suites read as linear setup, action, assertion, so the two length rules earn little there. Exempt them from your own `.rubocop.yml` rather than expecting the shipped config to do it. A relative path inside an inherited gem config resolves against that gem's directory, so a `test/**/*` written there would name this gem's tests and never yours:

```yaml
Metrics/MethodLength:
  Exclude:
    - test/**/*
    - spec/**/*
```

### Optional 37signals conventions

Besides the controller rule above, the shipped configuration registers four Rails convention cops, disabled by default pending validation on real applications. To enable the recommended set, inherit the optional preset in your application's `.rubocop.yml`:

```yaml
inherit_gem:
  quality_gate: config/37signals.yml
```

| Cop | Reports | Correction |
| --- | --- | --- |
| `QualityGate/AssociationDefaultBlockValue` | Eager `Current` reads in `belongs_to` defaults, such as `default: Current.user` | Manual: use `default: -> { Current.user }` |
| `QualityGate/PreferAfterSaveCommit` | Literal `after_commit` callbacks for exactly create and update | Safe autocorrection to `after_save_commit` |
| `QualityGate/PrivateOnlyConcern` | Recognized concerns containing only private instance methods | Manual architectural review |
| `QualityGate/BroadcastInController` | Explicit Turbo and ActionCable broadcast calls in controller files | Manual architectural review |

The preset also enables existing `Rails/AttributeDefaultBlockValue`, `Rails/StrongParametersExpect` (Rails 8+), `Rails/Pluck`, and `Rails/SelectMap`. RuboCop Rails applies each cop's version and correction-safety restrictions. `Rails/SaveBang` remains a separate project policy.

Projects keeping their own configuration can load individual cops without inheriting the preset:

```yaml
plugins:
  - quality_gate/rubocop:
      plugin_class_name: QualityGate::RuboCopPlugin

QualityGate/AssociationDefaultBlockValue:
  Enabled: true
```

The adapter respects host configurations; it does not inject this plugin into an existing configuration. Enable it as above, or inherit `config/rubocop.yml` and enable selected cops.

`PrivateOnlyConcern` recognizes `extend ActiveSupport::Concern`; configure `ConcernPaths: ['**/app/models/card/*.rb']` to recognize domain concern paths too. Modules with inclusion hooks, class behavior, public/protected methods, or unclear declarations are exempt. `BroadcastInController` defaults to `Include: ['**/app/controllers/**/*.rb']`; configure `AllowedMethods: ['broadcast_refresh_later']` or ordinary RuboCop `Exclude` patterns for intentional exceptions. It does not flag `render turbo_stream:` responses. These two convention cops identify code for review; they cannot determine the correct architecture.

Configuration is read with safe YAML loading. Unknown top-level keys produce a warning on standard error and are ignored; they do not pollute standard output.

The CLI rejects missing selected paths before dispatch with exit `2`. Deleted-file hook events remain cheap skips. Tool exclusions can still exclude existing selected files; selection is not proof that every requested file was analyzed.

RuboCop severities are normalized into QualityGate severities:

- `info` and `refactor` => `info`
- `convention` and `warning` => `warning`
- `error` and `fatal` => `error`

Syntax errors in Ruby files are reported as normal findings with severity `error`; they are not downgraded into tool failures.

### Verify behavior

The default verify adapters always run in order: Reek reports code smells, the test suite runs with `COVERAGE=1`, then Undercover reads `coverage/coverage.json`. A failing test creates a `test_failure` finding but does not stop Undercover, so test failures and uncovered changed regions appear together. The finding retains the last 20 output lines and points to a unique full-output log under `log/quality_gate/`. Clean test runs create no log. If saving fails, the test failure still includes its tail and a log-write diagnostic. Timeout failures do not guarantee a complete test log. Keep `log/` out of version control and manage retained logs with your project's usual log retention policy.

Reek uses an existing host `.reek.yml` when present and otherwise uses the shipped configuration. It reports smells as warnings and respects `--files`; without selected files it scans the project. Missing selected files are rejected by the CLI before any adapter runs.

Undercover compares against the configured `compare_point` when present. Otherwise it uses the merge base of `HEAD` and the detected default branch: `refs/remotes/origin/HEAD` when available, then `main` (local, then `origin/main`), then `master` (local, then `origin/master`). The remote-tracking fallback covers CI pull request checkouts, which are detached and fetch the default branch only as `origin/main`. If history is shallow, the default branch is missing, there is no earlier commit, or a detached checkout has no shared ancestor, verify reports an informational `undercover_skipped` finding with the reason instead of silently passing.

Each uncovered region is a warning that names its file, first line, full line range, node, uncovered lines, and uncovered branch context. If the coverage record is absent, verify reports a tool failure explaining that the SimpleCov wiring is missing. Install it with `quality_gate init --profile ruby` or the Rails generator. The test-suite and Undercover adapters ignore `--files`: the suite and the Git change define their scope.

### Security audit behavior

The security adapters deliberately ignore `--files`. Brakeman scans the whole application because its data-flow analysis crosses file boundaries. bundler-audit always checks `Gemfile.lock`, and dependency advisories use that file with line `0` rather than inventing a source location.

bundler-audit tries to update its advisory database first. A clean report must exit `0`; vulnerability findings must exit `1`. Abnormal exits or conflicting statuses and reports become tool failures. If the update fails and a real, usable local database exists, QualityGate scans the cached database and writes exactly one fallback warning to standard error. If no usable advisory database exists, bundler-audit returns a tool failure and exit code `2`; an unchecked dependency audit is never reported as clean.

### Coverage template

QualityGate packages coverage templates for Rails Minitest, Rails RSpec, and plain Ruby. Both setup paths render coverage into a marked block after the Ruby source prologue and before host application code is required.

The host-facing coverage templates are Undercover-only. They activate only when `ENV["COVERAGE"] == "1"`, load SimpleCov and the Undercover formatter, start branch coverage, and write `coverage/coverage.json`. Generated Rails and Ruby templates filter both `test` and `spec`. HTML output is only part of this gem's self-dogfood setup and is not configured for generated hosts.

## Exit codes

- `0` — clean gate or completed setup
- `1` — at least one finding and no tool failures, or setup conflicts requiring manual integration
- `2` — invalid input, configuration error, unknown adapter, or another tool failure

For the built-in RuboCop adapter, findings include rule names such as `Lint/Syntax` or `Metrics/MethodLength`. Invalid explicit RuboCop config paths or other RuboCop startup failures are reported as one `tool_failure` finding for `rubocop` and return exit code `2`.

## Dependency range

QualityGate currently supports these runtime dependency ranges:

- `rubocop ~> 1.90`
- `reek ~> 6.5`
- `rubocop-rails ~> 2.37`
- `rubocop-performance ~> 1.27`
- `rubocop-minitest ~> 0.40`
- `brakeman ~> 8.0`
- `bullet ~> 8.2.0`
- `bundler-audit ~> 0.9.3`
- `simplecov ~> 1.1.1`
- `strong_migrations ~> 2.5.2`
- `undercover ~> 0.8.5`

Those are runtime dependencies, not optional extras. If your application pins older or incompatible RuboCop plugins, Bundler may report a dependency conflict when you add QualityGate.

Undercover uses Rugged for Git access. When Bundler cannot use a platform-specific Rugged gem, a clean source build may require CMake and libgit2 build tooling on the host.

## Adopting QualityGate in an existing project

Start with your current `.rubocop.yml` and `.reek.yml`; QualityGate uses host configuration when present. Run `fast`, inspect the output, and fix configuration problems before adding more checks. The installer never silently replaces custom policy. To adopt the shipped rules later, merge this into your RuboCop configuration deliberately:

```yaml
inherit_gem:
  quality_gate: config/rubocop.yml
```

The shipped five-line method and hundred-line class budgets are strict. Review findings and use ordinary tool configuration for intentional exceptions or an existing baseline. Do not treat style compliance or coverage percentages as proof of application correctness.

Select adapters explicitly to introduce checks gradually. For example, start verification with tests alone, then add Reek and Undercover after coverage wiring and Git history are ready:

```yaml
adapters:
  verify:
    - test_suite
```

Omitted gate mappings keep defaults; an explicit empty list disables all checks for that gate. The former `gates` key had no effect and has been removed; delete it from existing configuration. It now produces the ordinary unknown-key warning. Use `adapters` to choose what runs.

### Plain Ruby and other test runners

Run init from the root of an existing Ruby project:

```sh
bundle exec quality_gate init --profile ruby
bundle exec quality_gate fast
bundle exec quality_gate verify
bundle exec quality_gate audit
```

The Ruby profile installs `.quality_gate.yml`, a `.rubocop.yml` inheriting `quality_gate: config/ruby.yml`, and a marked coverage block before application code in the selected helper. Rails cops and the controller instance-variable rule are disabled in this preset. It preserves existing RuboCop and Reek configuration, and creates no Rails initializers. All detector gems remain runtime dependencies, including Rails-oriented tools; this setup does not change the dependency footprint.

Init detects `test/test_helper.rb` for Minitest or `spec/spec_helper.rb` for RSpec. If both exist, select a framework explicitly. The default commands are `bundle exec rake test` and `bundle exec rspec`; your project must already provide the selected test runner and task. Use a command override for a different arrangement:

```sh
bundle exec quality_gate init --test-framework rspec
bundle exec quality_gate init --test-helper test/helper.rb --test-command 'bundle exec ruby -Itest test/all_test.rb'
bundle exec quality_gate init --pretend
bundle exec quality_gate init --agents
bundle exec quality_gate init --help
```

`--profile ruby` is the default. Helper paths are relative to the project root. A custom helper defaults to Minitest unless `--test-framework` is supplied. Command overrides use shell-style quoting to produce an argv array; shell operators and expansions are not executed. Invalid options, ambiguous detection, and missing helpers fail before writing files. `--skip-coverage` allows setup without a helper and omits Undercover from the generated verify configuration. It does not rewrite an existing configuration file.

Setup reports written, unchanged, skipped, and conflicting files. It never replaces custom configuration automatically; merge the displayed template where needed. Repeating setup with unchanged inputs is idempotent. Init uses a text summary; `--format json` applies to gate commands.

Coverage starts only with `COVERAGE=1`, which the test-suite adapter supplies, and filters both `test` and `spec`. Undercover requires a Git comparison point; set `compare_point` in shallow CI checkouts or fetch the base branch/history. Claude hooks require `--agents`; the separate native Codex hook requires `--codex`.

## Installation

Install the published gem as a development and test dependency. The executable is
used through Bundler, so the Gemfile entry does not require the library:

```ruby
group :development, :test do
  gem "quality_gate", "~> 0.2", require: false
end
```

The Rails/RSpec options, `--ci`, and Herb support were introduced in the v0.2.3 GitHub release and are included in this candidate. They are not in the current RubyGems release, 0.2.2.
The `~> 0.2` version constraint will accept 0.3.x once published.

Bundler installs the gem's runtime dependencies automatically. The published
gemspec currently declares:

| Runtime dependency | Version requirement |
| --- | --- |
| brakeman | `~> 8.0` |
| bullet | `~> 8.2.0` |
| bundler-audit | `~> 0.9.3` |
| fiddle | `~> 1.1` |
| reek | `~> 6.5` |
| rubocop | `~> 1.90` |
| rubocop-minitest | `~> 0.40` |
| rubocop-performance | `~> 1.27` |
| rubocop-rails | `~> 2.37` |
| simplecov | `~> 1.1.1` |
| strong_migrations | `~> 2.5.2` |
| undercover | `~> 0.8.5` |

If you need to install directly from the repository instead, Bundler also
supports this Gemfile entry:

```ruby
gem "quality_gate", github: "lucianghinda/quality_gate", require: false
```

Then install and set up for Ruby or Rails:

```sh
bundle install
bundle exec quality_gate init --profile ruby
```

```sh
bin/rails generate quality_gate:install
```

### Rails test setup

The Rails generator detects one existing test helper. If both helpers exist,
choose Minitest or RSpec explicitly:

```sh
bin/rails generate quality_gate:install --test-framework rspec
```

Rails defaults to `test/test_helper.rb` and `bin/rails test`. RSpec uses
`spec/rails_helper.rb` and `bundle exec rspec`. A custom helper under `spec/`
selects RSpec; other custom helpers select Minitest unless specified.

Pass a project-relative helper and command when needed:

```sh
bin/rails generate quality_gate:install --test-helper spec/rails_helper.rb --test-command 'bundle exec rspec'
```

An explicit custom helper must exist when coverage wiring is enabled. Use
`--skip-coverage` to omit coverage wiring. With no detected helper, Rails keeps
Minitest, warns, and installs the remaining artifacts.

The generated `.quality_gate.yml` activates the selected test command as an
argv array. The generator renders each argument as a safe YAML scalar.

The Rails generator manages these host artifacts:

- `.quality_gate.yml`
- `.rubocop.yml`
- `config/initializers/bullet.rb`
- `config/initializers/strong_migrations.rb`
- a marked coverage block in the selected helper, before executable host code

With `--agents`, it additionally manages:

- `.claude/hooks/quality_gate_fast.rb`
- `.claude/hooks/quality_gate_verify_stop.rb`
- `.claude/settings.json`
- one marker-owned Quality Gate contract section in `CLAUDE.md`
- one marker-owned Quality Gate contract section in `AGENTS.md`

With `--codex`, it additionally manages `.codex/hooks.json`, an executable
`.codex/hooks/quality_gate_verify_stop.rb`, and one marker-owned contract section
in `AGENTS.md`. Codex activation requires a trusted project and explicit hook
review in `/hooks`; the installer does not change trust. A custom Codex hook
configuration is left untouched for manual integration. See the
[Codex integration guide](docs/codex.md) for runtime limits, project discovery,
conflict handling, and removal.

Installation is idempotent. A missing file is written, while a byte-identical file is left untouched. For wholly owned files such as `.quality_gate.yml`, `.rubocop.yml`, both files under `.claude/hooks/`, and `.claude/settings.json`, if an existing file has different content the generator never overwrites or merges it unless it is the exact known settings snapshot described next: otherwise, the installer prints the current template for manual use, marks the conflict as needing a person, and continues with the remaining artifacts. The sole upgrade exception is `.claude/settings.json` whose bytes exactly match the previously shipped PostToolUse-only template; rerunning the installer safely replaces that known snapshot with the current PostToolUse-and-Stop template. Any customized settings file remains a manual conflict and is not overwritten.

The generated Strong Migrations initializer begins with the exact provenance line `# Generated by Quality Gate.`. On its first install, QualityGate records the newest existing migration as the baseline, or records that no migration exists yet. On later runs, that provenance makes the recorded baseline take precedence, so newer migrations leave the generated initializer unchanged. An unmarked initializer is always developer-owned and therefore follows the conflict/manual policy; when it already contains `StrongMigrations.start_after`, the printed marked template preserves that established baseline instead of advancing it.

Use `--skip-initializers` when the host does not use Bullet or Strong Migrations. Use `--skip-coverage` to leave the selected test helper alone. Use `--pretend` to preview the run without changing the filesystem; pending writes are reported as skipped.

```sh
bin/rails generate quality_gate:install --skip-initializers
bin/rails generate quality_gate:install --skip-coverage
bin/rails generate quality_gate:install --pretend
```

For coverage, the generator preserves a UTF-8 BOM and shebang, then leading blank lines, ordinary comments, all Ruby and Emacs directives, and complete `=begin`/`=end` comment blocks before the marked block. It inserts coverage immediately before the first executable host code. Inserted lines use the helper's existing LF or CRLF convention. Generated Rails and Ruby coverage blocks exclude both `test` and `spec`.

### Optional GitHub Actions workflow

Pass `--ci` to either setup command to create
`.github/workflows/quality_gate.yml`:

```sh
bundle exec quality_gate init --ci
```

```sh
bin/rails generate quality_gate:install --ci
```

The workflow is opt-in. `--pretend` previews it without writing files. An
existing customized `.github/workflows/quality_gate.yml` is preserved and
reported for manual integration. Later setup without `--ci` leaves an installed
workflow alone.

The generated workflow runs on pushes and pull requests. It grants `contents: read`
and uses `actions/checkout@v7` with `fetch-depth: 0` and
`persist-credentials: false`. It uses `ruby/setup-ruby@v1` with Bundler caching.
Its Ruby selector uses the installing runtime's exact `RUBY_VERSION`. Separate
direct `fast`, `verify`, and `audit` steps enforce each gate's exit status.

Customize the workflow for your supported Ruby matrix, services, and environment.
The generator cannot infer application database services or secrets.

### Optional Herb checks

Herb adds ERB linting to the fast gate without changing its defaults. Install the
official CLI separately, then configure its local executable when needed:

```sh
npm install --save-dev @herb-tools/linter@0.11.0
```

```yaml
adapters:
  fast:
    - rubocop
    - herb
commands:
  fast:
    herb:
      - node_modules/.bin/herb-lint
```

Generated CI installs Ruby and Bundler dependencies only. If Herb is enabled,
customize the workflow to set up Node and install locked npm dependencies before
the fast step.

QualityGate appends JSON output flags and eligible selected paths to the command.
The default launcher is `herb-lint`. Bundler does not add npm's local binaries
to `PATH`. With no selected paths, Herb scans the project. With
selected paths, it receives ERB files and directories; unrelated files are
omitted. Herb applies its own `.herb.yml` exclusions. The generated fast hook
keeps Ruby checks unchanged. It checks ERB only when Herb is enabled. Hook
feedback may fail open; CI enforces direct gate exit codes.

### Claude Code agent hooks

Agent installation is opt-in. A default rerun neither updates nor removes previously installed agent files. To refresh an older installation, pass `--agents` explicitly and review any manual conflicts. Hooks provide feedback: a session ending does not guarantee verification passed. Run the CLI directly in CI and enforce its exit status.

Plain Ruby projects use `bundle exec quality_gate init --profile ruby --agents` to install or refresh the same integration. The Rails commands below apply to Rails applications.

For agent integration, run `bin/rails generate quality_gate:install --agents`. The generator writes `.claude/hooks/quality_gate_fast.rb` and `.claude/hooks/quality_gate_verify_stop.rb`, installs the exact Claude Code `PostToolUse` and `Stop` entries in `.claude/settings.json`, and manages one marker-owned Quality Gate contract block inside `CLAUDE.md` and `AGENTS.md`. The Stop command has a 300-second Claude Code timeout. The marker-owned contract sections are narrower than the wholly owned files: a single stale Quality Gate block is replaced in place, the surrounding bytes are preserved, and any unmatched or multiple marker cases fall back to manual installation. If a hook file is byte-identical but has lost its executable mode, reinstalling repairs the mode without rewriting the file. After `bundle install` or a gem upgrade, rerun `bin/rails generate quality_gate:install --agents` to reinstall the generated hooks and contract files.

The `PostToolUse` hook runs file-scoped `quality_gate fast` after Ruby edits. It also checks ERB edits when Herb is configured in the fast gate. Findings exit 2 and return the gate's JSON report to Claude as feedback. If an attempted fast run is unavailable, the first attempt in that unavailable streak exits 2 with one stderr line naming `bundle exec quality_gate fast` and `log/quality_gate_hooks.jsonl`; the already-applied edit stands and is not rolled back. Repeated unavailable attempts exit 0 silently. Other non-Ruby paths and deleted files remain cheap skips.

The `Stop` hook checks for Ruby working-tree edits and automatically runs `quality_gate verify` before Claude finishes. With no Ruby edits it skips without starting the verifier. A clean result from the same `session_id` is debounced when no Ruby edit was logged at or after that result. Findings exit 2 with the machine-readable JSON report only after the matching `verify_blocked` record is safely appended, so Claude receives the feedback and continues working. If prior hook history cannot be read safely or that record cannot be written, the hook suppresses the feedback and fails open so the retry cap cannot deadlock. Invalid verifier output, a tool failure, a verifier timeout, or a command exception also fails open as unavailable. After three consecutive blocked finish attempts in one session, the next attempt is capped and exits 0.

Hook activity is appended to `log/quality_gate_hooks.jsonl`. Stop records include `session_id` and use the outcomes `verify_skipped`, `verify_debounced`, `verify_clean`, `verify_blocked`, `verify_unavailable`, and `verify_cap`. The CLI warns on stderr when the last 20 valid records include either fast-hook `unavailable` or Stop-hook `verify_unavailable` outcomes. The warning does not change the gate's JSON output or exit code.

Codex uses its native Stop hook only when you install it with `--codex`, start Codex in the installed project or one of its descendants, and explicitly review and trust it. The manual Codex gates and the full activation and removal instructions are in `docs/codex.md`.

For the Rails generator, when `test/test_helper.rb` is missing, it warns that Minitest coverage wiring was skipped, installs the other files, and exits successfully. Plain Ruby init instead requires an existing helper or `--skip-coverage`. Every successful install or preview run ends by naming the next command:

```sh
bundle exec quality_gate fast
```

`bin/rails destroy quality_gate:install` is intentionally read-only. Automatic removal is not supported because coverage is embedded in a developer-owned helper and the agent contract files may contain developer-owned text around the managed markers; the command changes nothing and directs you to the manual removal steps below instead of printing an install summary or next command.

To undo a clean installation, delete the files that the generator wrote (`.quality_gate.yml`, `.rubocop.yml`, `config/initializers/bullet.rb`, `config/initializers/strong_migrations.rb`, `.claude/hooks/quality_gate_fast.rb`, `.claude/hooks/quality_gate_verify_stop.rb`, and `.claude/settings.json`). Then remove the complete block in `test/test_helper.rb` from `# quality_gate coverage — start` through `# quality_gate coverage — end`, including both marker lines, and remove the complete Quality Gate block from `CLAUDE.md` and `AGENTS.md` from `<!-- quality_gate agent contract — start -->` through `<!-- quality_gate agent contract — end -->`. Do not delete a file that predated the generator or contains developer changes outside the managed markers.

## Acceptance evidence

The [incident catalogue](docs/incidents.md) maps executable acceptance fixtures to
four representative classes: N+1 queries, unsafe migrations, complexity creep,
and untested changed code. The [validation guide](docs/dogfood-log.md) provides
commands for reproducing the incident, coverage, and optional latency checks.

Fixture results do not guarantee compatibility or performance in every application.
Timeouts, unavailable tools, and skipped checks must be distinguished from clean
gates. Validate installation and configured tools in the target application before
relying on the results; no production adoption or review-time improvements are claimed.

## Development

Clone the repository and install its dependencies:

```sh
bin/setup
```

Run the tests in two separate Ruby processes, lint checks, or complete serial default task:

```sh
bundle exec rake test:parallel
bundle exec rubocop
bundle exec rake
```

`TEST_WORKERS=4 bundle exec rake test:parallel` changes the worker count.
`bundle exec rake test` preserves the serial runner and its Minitest filtering
options; `test:parallel` accepts the same `N`, `X`, and `A` filters. Named latency
checks (`QUALITY_GATE_ACCEPTANCE_TIMING=1`) always use one worker so concurrent
tests do not distort their measurements.

This repository's `quality_gate verify` uses the parallel task. Each worker writes
isolated coverage results; the parent merges them and generates reports only after
every worker succeeds and supplies coverage. `TEST_WORKERS=1 bundle exec quality_gate verify`
runs the same coverage pipeline with one worker. CI runs RuboCop separately and
lets verify run the full suite once per Ruby version.

To investigate test performance with [TestProf](https://github.com/test-prof/test-prof),
run the serial suite without coverage instrumentation:

```sh
QUALITY_GATE_PROFILE=1 COVERAGE=0 bundle exec rake test
```

This opt-in run prints a TagProf breakdown by test directory and an EventProf
report for `subprocess.quality_gate`, including the ten slowest suites and tests.
The event measures synchronous `Open3.capture2`, `capture2e`, and `capture3`
calls, including time waiting for child processes. It does not measure work
inside those processes or the adapter's separate `popen`/wait implementation.
The profiling switch is consumed before tests run so nested test projects keep
their normal output. Ordinary runs do not enable the profilers, and TestProf is
only a development/test dependency.

Use the serial task for a single report; parallel profiling produces a separate
report per worker. Existing Minitest filters still apply, for example:

```sh
QUALITY_GATE_PROFILE=1 COVERAGE=0 bundle exec rake test N=/test_clean_fixture/
```

The gem is linted by the configuration it ships, so the Sandi Metz budgets apply to its own code. Violations that predate those budgets are frozen file by file in `.rubocop_todo.yml`, which keeps the gate green while forcing new code to meet the budgets. That file is a ratchet: it may only shrink. When you change a file listed there, bring it under the budget and delete its entry; never add one. Regenerate it only after such a burn-down:

```sh
bundle exec rubocop --auto-gen-config --auto-gen-only-exclude --no-exclude-limit \
  --no-offense-counts --no-auto-gen-timestamp
```

`--auto-gen-only-exclude` keeps RuboCop from raising a `Max` to the worst value it finds, which would relax the budget everywhere at once instead of naming the files that owe work.

Prepare the release locally with:

```sh
bin/prepare_release
```

This runs tests and lint, generates [llm.txt](llm.txt), and builds the gem in `pkg/`. It does not publish or push. Maintainer tools live in `bin/`; the installed `quality_gate` command lives in `exe/quality_gate`. See [release preparation](docs/releasing.md) for the workflow and publication steps.

Bug reports and pull requests are welcome at [the QualityGate repository](https://github.com/lucianghinda/quality_gate). Contributors should follow the [code of conduct](https://github.com/lucianghinda/quality_gate/blob/main/CODE_OF_CONDUCT.md).

QualityGate is available under the [MIT License](https://opensource.org/licenses/MIT).
