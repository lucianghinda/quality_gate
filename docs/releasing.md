# Releasing Quality Gate

Use Ruby 3.2 or newer and run these commands from the gem directory.

```sh
bin/setup
bin/prepare_release
```

`bin/setup` installs the development bundle. `bin/prepare_release` runs the test
suite and RuboCop, regenerates `llm.txt`, and builds
`pkg/quality_gate-VERSION.gem`. It stops at the first failed prerequisite.
Preparation only creates local files; publishing is a separate maintainer action.

## Documentation

`bin/generate_llm.rb` produces a deterministic index and short overview using an
explicit list of public Markdown documents. It checks every linked document exists
before replacing `llm.txt`. Run it after changing the documentation set and review
the generated output. It requires only Ruby's standard library.

## Executables

The installed command lives in `exe/quality_gate`. The gemspec exposes it as
`quality_gate`. Scripts in `bin/` are development tools and are excluded from the
gem archive. `bin/console` opens an interactive session with the gem loaded.

## Release checklist

1. Update `lib/quality_gate/version.rb` and add the matching `CHANGELOG.md` entry.
   Treat these as one release record: keep the changelog heading, gemspec version,
   and built artifact version synchronized.
2. Run `bin/prepare_release` and review the generated documentation and package.
   Run `bundle exec quality_gate verify` to enforce the repository coverage budgets.
   On the initial commit, Undercover cannot compare against a parent commit, so
   local verification reports a skip and exits nonzero. CI accepts that skip only
   on the root commit, with no other findings and clean test suite and SimpleCov
   checks enforcing the configured aggregate line and branch coverage budgets. The
   repository configuration remains unchanged during verification. Subsequent commits
   run normal verification, including diff coverage; no extra baseline commit is required.
3. Confirm the archive includes runtime code, configuration, licensing, and public
   documentation, with no local paths, credentials, private logs, or internal plans.
4. Before publishing, confirm the version matches in
   `lib/quality_gate/version.rb`, the `CHANGELOG.md` heading, the gemspec, and
   the built gem filename. Review the source commit and confirm it contains the
   intended source and changelog entry. Separately confirm the gem artifact was
   built from that reviewed commit.
5. Commit the reviewed source, create the matching version tag, then push the
   reviewed branch and tag to the public repository. Confirm the remote branch
   and tag point to the reviewed commit before creating the GitHub release.
   Publish the artifact with `gem push pkg/quality_gate-VERSION.gem`, replacing
   `VERSION` with the actual release version; RubyGems MFA is required. Create
   the GitHub release from the pushed tag, using the changelog entry as its notes.
6. After publication, confirm the RubyGems release version and the GitHub
   release title, tag, and notes match the version and changelog entry.

The Rakefile also loads Bundler's gem tasks. Its `release` task can publish and
push Git changes; use it only when those actions are intended.
