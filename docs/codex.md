# Codex and QualityGate

Codex does not consume Claude Code `PostToolUse` or `Stop` hooks. The optional `.claude/settings.json`, `.claude/hooks/quality_gate_fast.rb`, and `.claude/hooks/quality_gate_verify_stop.rb` files are for Claude Code sessions and are installed only with `--agents`. In Codex, run the same gates manually or have the agent invoke them explicitly:

- Run `bundle exec quality_gate fast` after Ruby edits.
- Run `bundle exec quality_gate verify` before you finish a change.
- Run `bundle exec quality_gate audit` before you merge security-sensitive work.

Fix findings before you continue editing. Use `--format json` for structured results, and inspect `checks` alongside findings to see each tool's status and scope. Explicit selected paths must exist; a missing path is an input failure. A clean gate describes only its configured checks, not overall application correctness.

Automatic Claude hooks can fail open or cap retries. An agent session ending is not proof of verification. CI should run the gate commands directly and enforce their exit status.

Exit meanings stay the same in Codex and Claude Code:

- Exit 0 means the gate ran clean.
- Exit 1 means the gate reported findings and no tool failures.
- Exit 2 means the gate could not complete cleanly because of invalid input, configuration, or another tool failure.

If the automatic Claude Code hook becomes unavailable, inspect `log/quality_gate_hooks.jsonl`, run `bundle install`, and reinstall the generated integration with the setup command for your project.

For a plain Ruby project, install or refresh the generated contract files with:

```sh
bundle exec quality_gate init --profile ruby --agents
```

For Rails:

```sh
bin/rails generate quality_gate:install --agents
```
