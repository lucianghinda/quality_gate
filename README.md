# QualityGate

QualityGate gives Ruby projects one workflow for checking changes: quick feedback while editing, verification before finishing, and a separate security audit. Set up a plain Ruby project with `quality_gate init`, or a Rails application with the Rails generator.

The `fast` gate runs RuboCop. `verify` runs Reek, the test suite, and Undercover in order. For `audit`, Rails defaults run Brakeman followed by bundler-audit; the Ruby setup uses bundler-audit alone.

## Quick start

Add QualityGate to your Gemfile using the [installation instructions](#installation). For a Ruby gem or application with an existing test suite, run:

```sh
bundle install
bundle exec quality_gate init --profile ruby
bundle exec quality_gate fast
bundle exec quality_gate verify
```

For Rails, replace the init command with `bin/rails generate quality_gate:install`.

Review the installer summary: existing configuration is preserved, and conflicts require manual integration. Agent hooks are optional; add `--agents` to the setup command to install them. Use `--pretend` to preview filesystem changes. See [Ruby setup](#plain-ruby-and-other-test-runners) for test-runner selection and command overrides.

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

The built-in fast path is meant for changed files:

```sh
bundle exec quality_gate fast --files app/models/user.rb
```

`verify` records coverage while it runs the full test suite, then checks changed code with Undercover. A clean `verify` or `audit` run prints this clean summary:

```text
0 findings, 0 tool failures
```

Use `--files` to select paths for RuboCop and Reek; the first path follows the option and further paths follow it as separate arguments:

```sh
bundle exec quality_gate fast --files lib/quality_gate.rb test/test_quality_gate.rb
```

Paths must exist, including paths from the configuration file. Any missing path returns exit `2` before tools run. A bare `fast` scans the project; it does not discover changed files automatically.

| Adapter | Scope with `--files` |
| --- | --- |
| RuboCop, Reek | Selected files/directories, subject to the tool's exclusions |
| Test suite | Full configured suite |
| Undercover | Git changes against the comparison point |
| SimpleCov | Aggregate coverage summary |
| Brakeman | Whole application |
| bundler-audit | Gemfile.lock |

`verify --files app/models/user.rb` therefore narrows Reek, but still runs the full suite and checks Git changes. JSON includes each adapter's scope and status. When stderr is a terminal, progress names each tool before it starts; redirected output and hook invocations remain quiet except for diagnostics.

Choose text or JSON output with `--format text` or `--format json`:

```sh
bundle exec quality_gate verify --format json
```

The shorter form `quality_gate version` works when the installed executable is already on your `PATH`.

The repository config must also use exactly `text` or `json` for `format`; any other configured value is rejected as a configuration error before a gate runs.

## Output contract

Gate text output includes tool, severity, location when available, rule, and message:

```text
<tool> <severity> <file>:<line> <rule> <message>
```

Multiline messages retain indented detail lines. Findings without a source location omit it rather than printing `:0`. The final gate output line is the summary:

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
```

Default adapters when no project configuration overrides them (the Rails setup uses these; Ruby init writes its own test command and omits Brakeman):

- `fast` => `rubocop`
- `verify` => `reek`, then `test_suite`, then `undercover`
- `audit` => `brakeman`, then `bundler_audit`

Default timeouts:

- `default` => `120`
- `rubocop` => `10`
- `test_suite` => `120`
- `undercover` => `120`

`adapters` lists adapter names per gate. The built-in registry knows `rubocop`, `reek`, `test_suite`, `undercover`, `simplecov`, `brakeman`, and `bundler_audit`. SimpleCov is registry-known but not a default adapter: the default verify adapters are Reek, the test suite, and Undercover, in that order. Unknown adapter names still become reported tool failures instead of being ignored.

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

After the test suite runs, the adapter reads SimpleCov's `coverage/.last_run.json` summary without rerunning tests. A missing or unusable record is a tool failure. A branch budget without usable branch data is also a tool failure and names `enable_coverage :branch` as the required SimpleCov setup. Coverage below a configured budget produces a stable error finding: `line_coverage_below_minimum` for the line budget and `branch_coverage_below_minimum` for the branch budget.

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

`adapters` must be a mapping whose only permitted keys are `fast`, `verify`, and `audit`, and each layer value must be an array of non-empty strings. The mapping may specify any subset of those gates; unspecified gates keep the shipped defaults. A misspelled layer key such as `fasst` is rejected as a configuration error instead of silently falling back to a clean run.

`commands` follows the same three gate layers. Every command is an argv array of non-empty strings, never a shell command string. `commands.verify.test_suite` defaults to `["bin/rails", "test"]`.

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

Undercover compares against the configured `compare_point` when present. Otherwise it uses the merge base of `HEAD` and the detected default branch: `refs/remotes/origin/HEAD` when available, then local `main`, then local `master`. If history is shallow, the default branch is missing, there is no earlier commit, or a detached checkout has no shared ancestor, verify reports an informational `undercover_skipped` finding with the reason instead of silently passing.

Each uncovered region is a warning that names its file, first line, full line range, node, uncovered lines, and uncovered branch context. If the coverage record is absent, verify reports a tool failure explaining that the SimpleCov wiring is missing. Install it with `quality_gate init --profile ruby` or the Rails generator. The test-suite and Undercover adapters ignore `--files`: the suite and the Git change define their scope.

### Security audit behavior

The security adapters deliberately ignore `--files`. Brakeman scans the whole application because its data-flow analysis crosses file boundaries. bundler-audit always checks `Gemfile.lock`, and dependency advisories use that file with line `0` rather than inventing a source location.

bundler-audit tries to update its advisory database first. If that update fails and a real, usable local database exists, QualityGate scans the cached database and writes exactly one fallback warning to standard error. If no usable advisory database exists, bundler-audit returns a tool failure and exit code `2`; an unchecked dependency audit is never reported as clean.

### Coverage template

QualityGate packages coverage templates for Rails/Minitest and plain Ruby. Both setup paths render coverage into a marked block after the Ruby source prologue and before host application code is required.

The host-facing coverage templates are Undercover-only. They activate only when `ENV["COVERAGE"] == "1"`, load SimpleCov and the Undercover formatter, start branch coverage, and write `coverage/coverage.json`. The Rails template filters `test`; the Ruby template filters both `test` and `spec`. HTML output is only part of this gem's self-dogfood setup and is not configured for generated hosts.

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

Coverage starts only with `COVERAGE=1`, which the test-suite adapter supplies, and filters both `test` and `spec`. Undercover requires a Git comparison point; set `compare_point` in shallow CI checkouts or fetch the base branch/history. Agent hooks and contracts are installed only with `--agents`.

## Installation

QualityGate has not been published to RubyGems yet. Until it is released, install it from GitHub with Bundler:

```ruby
gem "quality_gate", github: "lucianghinda/quality_gate"
```

Then install for Ruby or Rails:

```sh
bundle install
bundle exec quality_gate init --profile ruby
```

```sh
bin/rails generate quality_gate:install
```

The Rails generator manages these host artifacts:

- `.quality_gate.yml`
- `.rubocop.yml`
- `config/initializers/bullet.rb`
- `config/initializers/strong_migrations.rb`
- a marked coverage block in `test/test_helper.rb`, before executable host code

With `--agents`, it additionally manages:

- `.claude/hooks/quality_gate_fast.rb`
- `.claude/hooks/quality_gate_verify_stop.rb`
- `.claude/settings.json`
- one marker-owned Quality Gate contract section in `CLAUDE.md`
- one marker-owned Quality Gate contract section in `AGENTS.md`

Installation is idempotent. A missing file is written, while a byte-identical file is left untouched. For wholly owned files such as `.quality_gate.yml`, `.rubocop.yml`, both files under `.claude/hooks/`, and `.claude/settings.json`, if an existing file has different content the generator never overwrites or merges it unless it is the exact known settings snapshot described next: otherwise, the installer prints the current template for manual use, marks the conflict as needing a person, and continues with the remaining artifacts. The sole upgrade exception is `.claude/settings.json` whose bytes exactly match the previously shipped PostToolUse-only template; rerunning the installer safely replaces that known snapshot with the current PostToolUse-and-Stop template. Any customized settings file remains a manual conflict and is not overwritten.

The generated Strong Migrations initializer begins with the exact provenance line `# Generated by Quality Gate.`. On its first install, QualityGate records the newest existing migration as the baseline, or records that no migration exists yet. On later runs, that provenance makes the recorded baseline take precedence, so newer migrations leave the generated initializer unchanged. An unmarked initializer is always developer-owned and therefore follows the conflict/manual policy; when it already contains `StrongMigrations.start_after`, the printed marked template preserves that established baseline instead of advancing it.

Use `--skip-initializers` when the host does not use Bullet or Strong Migrations. Use `--skip-coverage` to leave the Minitest helper alone. Use `--pretend` to preview the run without changing the filesystem; pending writes are reported as skipped.

```sh
bin/rails generate quality_gate:install --skip-initializers
bin/rails generate quality_gate:install --skip-coverage
bin/rails generate quality_gate:install --pretend
```

For coverage, the generator preserves a UTF-8 BOM and shebang, then leading blank lines, ordinary comments, all Ruby and Emacs directives, and complete `=begin`/`=end` comment blocks before the marked block. It inserts coverage immediately before the first executable host code. Inserted lines use the helper's existing LF or CRLF convention.

### Claude Code agent hooks

Agent installation is opt-in. A default rerun neither updates nor removes previously installed agent files. To refresh an older installation, pass `--agents` explicitly and review any manual conflicts. Hooks provide feedback: a session ending does not guarantee verification passed. Run the CLI directly in CI and enforce its exit status.

Plain Ruby projects use `bundle exec quality_gate init --profile ruby --agents` to install or refresh the same integration. The Rails commands below apply to Rails applications.

For agent integration, run `bin/rails generate quality_gate:install --agents`. The generator writes `.claude/hooks/quality_gate_fast.rb` and `.claude/hooks/quality_gate_verify_stop.rb`, installs the exact Claude Code `PostToolUse` and `Stop` entries in `.claude/settings.json`, and manages one marker-owned Quality Gate contract block inside `CLAUDE.md` and `AGENTS.md`. The Stop command has a 300-second Claude Code timeout. The marker-owned contract sections are narrower than the wholly owned files: a single stale Quality Gate block is replaced in place, the surrounding bytes are preserved, and any unmatched or multiple marker cases fall back to manual installation. If a hook file is byte-identical but has lost its executable mode, reinstalling repairs the mode without rewriting the file. After `bundle install` or a gem upgrade, rerun `bin/rails generate quality_gate:install --agents` to reinstall the generated hooks and contract files.

The `PostToolUse` hook runs file-scoped `quality_gate fast` after Ruby edits. Findings exit 2 and return the gate's JSON report to Claude as feedback. If an attempted fast run is unavailable, the first attempt in that unavailable streak exits 2 with one stderr line naming `bundle exec quality_gate fast` and `log/quality_gate_hooks.jsonl`; the already-applied edit stands and is not rolled back. Repeated unavailable attempts exit 0 silently. Non-Ruby paths and deleted files remain cheap skips.

The `Stop` hook checks for Ruby working-tree edits and automatically runs `quality_gate verify` before Claude finishes. With no Ruby edits it skips without starting the verifier. A clean result from the same `session_id` is debounced when no Ruby edit was logged at or after that result. Findings exit 2 with the machine-readable JSON report only after the matching `verify_blocked` record is safely appended, so Claude receives the feedback and continues working. If prior hook history cannot be read safely or that record cannot be written, the hook suppresses the feedback and fails open so the retry cap cannot deadlock. Invalid verifier output, a tool failure, a verifier timeout, or a command exception also fails open as unavailable. After three consecutive blocked finish attempts in one session, the next attempt is capped and exits 0.

Hook activity is appended to `log/quality_gate_hooks.jsonl`. Stop records include `session_id` and use the outcomes `verify_skipped`, `verify_debounced`, `verify_clean`, `verify_blocked`, `verify_unavailable`, and `verify_cap`. The CLI warns on stderr when the last 20 valid records include either fast-hook `unavailable` or Stop-hook `verify_unavailable` outcomes. The warning does not change the gate's JSON output or exit code.

Codex does not consume the Claude Code hook automatically. Use the manual Codex workflow in `docs/codex.md` to run the same `fast`, `verify`, and `audit` commands yourself.

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

Run the tests, lint checks, or complete default task:

```sh
bundle exec rake test
bundle exec rubocop
bundle exec rake
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
