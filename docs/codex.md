# Codex and QualityGate

Quality Gate supports an optional native Codex Stop hook. Install it explicitly in a plain Ruby project with:

```sh
bundle exec quality_gate init --codex
```

For Rails:

```sh
bin/rails generate quality_gate:install --codex
```

`--codex` installs `.codex/hooks.json`, an executable `.codex/hooks/quality_gate_verify_stop.rb`, and the Quality Gate section in `AGENTS.md`. It does not install Claude Code files. Use `--agents --codex` to install both clients; the shared `AGENTS.md` section is still installed once. Existing custom Codex hook configuration is left unchanged and requires manual integration using the generated configuration proposed in the installer output. Run the installer again to repair the generated script's executable mode or confirm an unchanged installation. `--pretend` previews without writing files.

The hook runs the full `verify` gate synchronously on every Codex Stop. It does not debounce unchanged work, so each Stop can add the full verification runtime. Findings ask Codex for one repair continuation. On the resumed Stop, Quality Gate runs verification again; if findings remain, it reports the cap and allows the turn to finish. Runtime, input, and tool failures display an unavailable message and allow the turn to finish. A clean run returns no decision. This behavior is feedback for the agent, not enforcement: run the commands directly and use CI exit status as the gate.

This integration requires a Codex CLI version with native hooks; it was verified with CLI 0.160.0. Check the [official Codex hooks documentation](https://developers.openai.com/codex/hooks) for current requirements and behavior. [Project configuration layers](https://developers.openai.com/codex/config-basic) load from the project root down to the session working directory, so start Codex in the installed project or one of its descendants for its `.codex` configuration to apply. This matters for monorepos: a session in the repository root does not load a nested subproject's hook configuration.

Codex project hooks require a trusted project and explicit hook review. In Codex, open `/hooks`, inspect `.codex/hooks/quality_gate_verify_stop.rb` and the generated absolute command in `.codex/hooks.json`, then choose whether to trust it. Quality Gate never writes Codex trust state, user-home files, or `.codex/config.toml`. Doctor may recognize either installed file, but it cannot establish activation or trust and has no Codex execution-history source; that evidence remains unchecked.

The generated hook command contains the absolute path of the installed Ruby script, so it works when Codex runs the event from a nested working directory. If the project moves, update that command to the new absolute path and review hook trust again. Conflicts and removal are manual: preserve and merge any custom `hooks.json`, and when removing the integration delete only Quality Gate's hook entries/files and its owned section from `AGENTS.md`.

The generated launcher uses the installed project's `Gemfile`; install the project's bundle with `bundle install` before enabling the hook. Ruby and Bundler must be available to the Codex process. If the hook is unavailable, run verification manually:

- Run `bundle exec quality_gate fast` after Ruby edits.
- Run `bundle exec quality_gate verify` before you finish a change.
- Run `bundle exec quality_gate audit` before you merge security-sensitive work.

Fix findings before you continue editing. Use `--format json` for structured results, and inspect `checks` alongside findings to see each tool's status and scope. Explicit selected paths must exist; a missing path is an input failure. A clean gate describes only its configured checks, not overall application correctness.

Automatic hooks can fail open or cap retries. An agent session ending is not proof of verification. CI should run the gate commands directly and enforce their exit status.

Exit meanings stay the same in Codex and Claude Code:

- Exit 0 means the gate ran clean.
- Exit 1 means the gate reported findings and no tool failures.
- Exit 2 means the gate could not complete cleanly because of invalid input, configuration, or another tool failure.

If the automatic Claude Code hook becomes unavailable, inspect `log/quality_gate_hooks.jsonl`, run `bundle install`, and reinstall the generated integration with the setup command for your project. Codex does not provide this Claude hook history log.

For a plain Ruby project, install or refresh both Claude Code and Codex integration with:

```sh
bundle exec quality_gate init --profile ruby --agents --codex
```

For Rails:

```sh
bin/rails generate quality_gate:install --agents --codex
```
