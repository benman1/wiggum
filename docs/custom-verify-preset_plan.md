# Custom verify preset for projects with no detectable toolchain

## Constraints

- **In scope:** Let `wiggum init` fall back to asking for a verification command when
  `detect_preset` finds nothing, and add a `custom` preset that `generate_rc` can emit.
  Tests, help text and README table updated to match.
- **Out of scope:** Changing any existing preset's output. Changing the verification
  waterfall itself, the execute loop, or how `verify` lines are run. No new config keys.
- **Never do:**
  - Never make `init` non-interactive-hostile: it already reads from stdin for
    permission mode, so the new prompt follows the same pattern and must default
    sensibly on an empty answer.
  - Never write a `.wiggumrc` whose `verify` line points at a file that does not exist
    without saying so. A waterfall that fails on its first run because the script is
    missing looks like a wiggum bug.
  - Never silently change what `wiggum init <preset>` does for the five existing
    presets.

## Motivation

`detect_preset` recognises `next`, `astro`, `python`, `node` and `bash`, all by the
presence of a build manifest. When it finds nothing, `run_init` prints
"Could not auto-detect project type" and exits `EXIT_BAD_ARGS` (`lib/wiggum.sh:1141-1146`).

That is the whole story for a project that has no build manifest because it is not a
code project. The driving case is `/Users/ben/propertyangelsgroup`: a live WordPress
site where the deliverable is the site itself plus docs and scripts. Its verification is
a hand written `scripts/verify.sh` asserting invariants against the live site, and it
works well, but `wiggum init` cannot produce it and the user has to know the `.wiggumrc`
format to write one by hand.

The generalisation is small: when nothing is detected, ask for the verification command
instead of giving up.

**One nuance worth carrying into the docs.** For a code project the waterfall measures
quality against a working tree. For an ops project the subject is a live production
system, so the waterfall must assert only that the system is *not broken*. A verify
failure makes wiggum ask Claude to fix it, so putting a quality goal in there points an
unattended agent at production. The `custom` preset's generated comment should say this.

## Phase 1: The custom preset

- [ ] Add a `custom` case to `generate_rc` that takes the verify command as `$2` and
  emits a `.wiggumrc` with that command as its single `verify` line, plus a comment
  block explaining the invariant-versus-goal distinction.
  Acceptance: `generate_rc custom ./scripts/verify.sh` prints a config containing
  `verify = ./scripts/verify.sh`, and the unknown-preset error path still returns
  `EXIT_BAD_ARGS` for a genuinely unknown name.
  Files: lib/wiggum.sh

- [ ] Add `custom` to the unknown-preset error message so the list stays accurate.
  Acceptance: `generate_rc bogus` prints a message naming all six presets including
  `custom`, and exits `EXIT_BAD_ARGS`.
  Files: lib/wiggum.sh

- [ ] Add a `prompt_verify_command` function following `prompt_permission_mode`'s
  conventions: prompts on stderr, value on stdout, sensible default on an empty answer.
  Default to `./scripts/verify.sh`.
  Acceptance: `echo "" | prompt_verify_command` prints `./scripts/verify.sh`;
  `echo "make check" | prompt_verify_command` prints `make check`.
  Files: lib/wiggum.sh

- [ ] Change `run_init` so a failed detection prompts for a verify command and generates
  the `custom` preset, instead of returning `EXIT_BAD_ARGS`.
  Acceptance: in a temp directory with no manifest, `run_init` with stdin supplying a
  verify command and a permission mode creates a `.wiggumrc` containing that command.
  Files: lib/wiggum.sh

- [ ] Warn, without failing, when the chosen verify command names a file that does not
  exist.
  Acceptance: choosing `./scripts/verify.sh` in a directory where it is absent still
  writes `.wiggumrc` and prints a message naming the missing path.
  Files: lib/wiggum.sh

- [ ] Update the existing test that pins the old behaviour.
  `test/wiggum.bats:1647` is `run_init: fails with EXIT_BAD_ARGS when nothing to detect
  and no preset`. That test asserts exactly what this change removes, so it must be
  rewritten to assert the new prompt path rather than deleted.
  Acceptance: no test in the suite asserts `EXIT_BAD_ARGS` for an undetectable project;
  a replacement test asserts the `custom` config is written.
  Files: test/wiggum.bats

- [ ] Add `setup_claude_permissions` handling for `custom` so the generated permission
  rules are not empty.
  Acceptance: `setup_claude_permissions custom` produces rules covering `git` and
  `Bash(./scripts/*)`, mirroring how the `bash` preset is handled.
  Files: lib/wiggum.sh

### Acceptance Criteria

**Happy Path** — Given a directory with no build manifest, When `wiggum init` runs and
the user accepts the defaults, Then a `.wiggumrc` exists with
`verify = ./scripts/verify.sh` and `permission_mode = auto`.

**Edge Cases** — An empty answer takes the default. A verify command with arguments
(`make check`, `./x.sh --ci`) survives into the config verbatim. An existing `.wiggumrc`
still triggers the overwrite prompt before anything is written.

**Error States** — A named verify script that does not exist warns and continues rather
than failing, because the script is often written after `init`. `generate_rc` with an
unknown preset name still exits `EXIT_BAD_ARGS`.

**Non-Functional** — `shellcheck -s bash wiggum.sh lib/wiggum.sh install.sh` passes with
zero warnings. `bats test/wiggum.bats` passes in full. `./test/run.sh` exits 0.

## Phase 2: Documentation

- [ ] Add `custom` to the preset table in README.md.
  Acceptance: the table has a `custom` row whose "Detected by" reads as the no-manifest
  fallback and whose "Verification steps" names the user supplied command.
  Files: README.md

- [ ] Document the invariant-versus-goal rule in the verification waterfall section,
  with the live-system case as the worked example.
  Acceptance: README.md contains a passage stating that a verify failure causes an agent
  to attempt a fix, and that for a live system the waterfall must assert only that the
  system is not broken.
  Files: README.md

- [ ] Reference a worked example of an ops style verify script.
  Acceptance: README.md points at the invariant categories (service reachable, known
  URLs still resolve, no errors leaking into output, identity unchanged, not
  accidentally deindexed) as the shape of an ops waterfall.
  Files: README.md

### Acceptance Criteria

**Happy Path** — Given the README, When a reader looks up presets, Then `custom` appears
alongside the other five with an accurate description.

**Edge Cases** — The existing five preset rows are unchanged.

**Error States** — Not applicable, documentation only.

**Non-Functional** — No line in the changed README sections exceeds the file's existing
wrapping convention. No em-dashes, per the writing style in the sibling projects.
