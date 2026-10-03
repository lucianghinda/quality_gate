# Codex and Quality Gate

Quality Gate offers two optional native Codex hooks. The `PostToolUse` hook gives file-scoped fast feedback after patches; the `Stop` hook runs the full verification gate. Install both explicitly in a plain Ruby project:

```sh
bundle exec quality_gate init --codex
```

Claude Code's existing fast feedback is triggered by native `Edit` and `Write` calls. Codex uses its native `apply_patch` tool event for the equivalent patch feedback; the hook matcher does not include shell writes or other tools.

For Rails:

```sh
bin/rails generate quality_gate:install --codex
```

`--codex` installs `.codex/hooks.json`, executable `.codex/hooks/quality_gate_fast.rb` and `.codex/hooks/quality_gate_verify_stop.rb` scripts, and the Quality Gate section in `AGENTS.md`. It does not install Claude Code files. Use `--agents --codex` to install both clients; the shared `AGENTS.md` section is still installed once. `--pretend` previews filesystem changes. Reinstalling repairs either script's executable mode and leaves matching files unchanged.

The patch hook runs `quality_gate fast` after completed native `apply_patch` calls only. It selects changed Ruby files and, when Herb is configured in the fast gate, ERB files. A mixed patch gets one file-scoped run. Other tools, including shell writes, do not trigger this feedback hook; those changes are still checked by the final Stop hook. The patch has already been applied before this hook runs, so findings are advisory context for Codex and never roll the edit back.

A clean run returns no extra context. Findings provide Codex with file and rule details to guide a repair. When input, configuration, or a tool is unavailable, the hook reports that fact to Codex and asks it to tell you and run `bundle exec quality_gate fast` manually. A missing fast check never claims the files are clean. Run the manual gate and use CI exit status as enforcement evidence.

Codex gives the patch hook a 30-second native timeout. The shipped RuboCop fast timeout is 10 seconds, but a longer project-specific fast budget or slow analyzer can exceed Codex's hook timeout. In that case, use the manual fast command. The full Stop hook remains synchronous on every Stop and uses its existing 600-second hook timeout. It runs the full `verify` gate, can add substantial latency, and asks for one repair continuation when it finds issues. Codex verifies again on the resumed Stop; if findings remain, it reports the cap and allows the turn to finish. Runtime, input, and tool failures report unavailable and also allow the turn to finish. Hooks provide feedback; an agent session ending is not proof that checks passed.

This integration requires a Codex CLI version with native hooks; it was verified with CLI 0.160.0. Check the [official Codex hooks documentation](https://developers.openai.com/codex/hooks) for current requirements and behavior. [Project configuration layers](https://developers.openai.com/codex/config-basic) load from the project root down to the session working directory, so start Codex in the installed project or one of its descendants for its `.codex` configuration to apply. In a monorepo, a session started at the repository root does not load a nested subproject's hook configuration.

Codex project hooks require a trusted project and explicit hook review. In Codex, open `/hooks`, inspect both scripts and both generated command definitions in `.codex/hooks.json`, then decide whether to trust them. Review both commands again after hook configuration changes or a Quality Gate upgrade. Quality Gate never writes Codex trust state, user-home files, or `.codex/config.toml`. Doctor can recognize installed files, but cannot establish trust, activation, or execution; Codex supplies no Quality Gate hook-history source, so Doctor leaves execution history unchecked.

The generated commands contain absolute paths to the installed Ruby scripts, so they work when Codex starts in a nested working directory. If the project moves, update both command paths and review them in `/hooks` again. Existing customized `.codex/hooks.json` is left unchanged and needs manual integration using the proposal printed by the installer. The only upgrade exception is the exact previously shipped Stop-only JSON generated for this same project root; changed-root snapshots, formatting changes, extra hooks, and customized bytes need manual integration. Symlink destinations are never followed.

The launchers use the installed project's `Gemfile`; install the project's bundle with `bundle install` before trusting the hooks. Ruby and Bundler must be available to the Codex process. To remove the integration, remove both Quality Gate hook entries and scripts, and remove `.codex/hooks.json` only when it contains solely generated Quality Gate configuration. Remove only the Codex instructions from `AGENTS.md` when it also contains Claude guidance, or remove the Quality Gate section when Codex is its only client.

Run the gates directly as well:

- Run `bundle exec quality_gate fast` after Ruby edits.
- Run `bundle exec quality_gate verify` before you finish a change.
- Run `bundle exec quality_gate audit` before you merge security-sensitive work.

Fix findings before you continue editing. Use `--format json` for structured results and inspect `checks` with findings to see each tool's status and scope. Explicit selected paths must exist; a missing path is an input failure. A clean gate describes only its configured checks, not overall application correctness.

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
