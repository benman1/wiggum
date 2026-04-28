# Issue: optional skip-commit and skip-verify modes

## Background

Wiggum currently always runs the verification waterfall (`run_validation`)
during `execute` and `check`, and always asks Claude to commit after
implementation, validation, summary, and docs phases. Users want explicit
ways to opt out of either behavior:

- Skip wiggum's verification pass entirely (e.g., when iterating on
  experimental code where running the full test suite each cycle is too
  slow, or when tests are known to be broken and not in scope).
- Skip wiggum-driven commits entirely (e.g., when the user wants to
  review changes manually before committing, or is exploring multiple
  approaches in an unstaged working tree).

A user observed that removing `verify` lines from `.wiggumrc` does not
prevent pytest from being called in a Python project. This is correct
and expected: `run_validation` already short-circuits when `VERIFY_STEPS`
is empty (`lib/wiggum.sh:1080`). The pytest invocation comes from Claude
itself during phase-2 implementation, where the prompt instructs it to
"Write tests for new logic" (`lib/wiggum.sh:1245`). Out of scope for this
issue: changing Claude's implementation prompt. `--no-verify` only
suppresses wiggum's own verify pass.

## Goals

1. Add a `--no-verify` CLI flag and a `verify = off` (or equivalent)
   config key that skips wiggum's verification waterfall in `execute`
   and `check`.
2. Add a `--no-commit` CLI flag and a `commit = off` config key that
   skips every wiggum-issued commit prompt in `execute`, `check`, and
   `docs`.
3. Honor CLI > config > default precedence, matching the existing
   pattern for `MAX_ITERATIONS` (`CLI_MAX_ITERATIONS` overrides config).
4. Add Bats coverage for both flags and both config keys.

## Non-goals

- Telling Claude not to run tests, builds, or type-checks during
  implementation. Claude's self-checking stays. (A separate issue can
  cover that if needed.)
- Changing how `verify`/`autofix` lines are parsed today.
- Adding partial skips (e.g., "skip verify but not autofix"). Verify
  is all-or-nothing for this issue.

## Current behavior

- `apply_config` (`lib/wiggum.sh:81`) populates `VERIFY_STEPS` from
  `verify` and `autofix` lines.
- `run_validation` (`lib/wiggum.sh:1079`) skips cleanly when
  `VERIFY_STEPS` is empty.
- `run_check` (`lib/wiggum.sh:1410`) refuses to run with no verify
  steps and exits 0.
- Wiggum-driven commits are issued at five sites, all via
  `prompt_commit`:
  - `lib/wiggum.sh:1222` — phase-1 reconcile commit (execute)
  - `lib/wiggum.sh:1255` — phase-2 per-iteration commit (execute)
  - `lib/wiggum.sh:1329` — phase-3 summary commit (execute)
  - `lib/wiggum.sh:1404` — docs update commit (docs / phase-4)
  - `lib/wiggum.sh:1425` — check-mode commit after fixes

## Desired behavior

### `--no-verify` / `verify = off`

- `execute`: phase-2 `run_validation` call (line 1250) becomes a no-op.
  Print `(verification skipped via --no-verify)` to stderr in place of
  the usual validation output.
- `check`: refuse to run with a clear error: `Error: --no-verify makes
  'wiggum check' a no-op. Drop the flag or use a different command.`
  Exit `EXIT_BAD_ARGS`.
- Verification config keys (`verify`, `autofix`) in `.wiggumrc` are
  still parsed (no warnings) but `VERIFY_STEPS` is cleared after
  `apply_config` if the skip flag is set.
- `print_verify_steps` shows `Verification steps: (skipped)` instead of
  `(none configured)` so the user can tell why nothing ran.

### `--no-commit` / `commit = off`

- All five `run_claude … "$(prompt_commit …)"` sites are gated by a
  helper:

  ```bash
  commit_or_skip() {
      if [[ "$NO_COMMIT" == true ]]; then
          echo "(commit skipped via --no-commit)" >&2
          return 0
      fi
      WIGGUM_CURRENT_LABEL="$1"
      shift
      run_claude -p --permission-mode bypassPermissions "$(prompt_commit "$@")"
  }
  ```

- Working-tree state at end of run is the user's problem; document this
  in README.

### Precedence

- New globals: `NO_VERIFY` (bool), `NO_COMMIT` (bool), `CLI_NO_VERIFY`,
  `CLI_NO_COMMIT`. Reset in `wiggum_reset`.
- CLI flag sets both `NO_VERIFY` and `CLI_NO_VERIFY` (or commit
  equivalents) to `true`.
- `apply_config` sets `NO_VERIFY` / `NO_COMMIT` from `verify = off` /
  `commit = off` only when the corresponding `CLI_*` is empty.
- Add `verify` and `commit` to the allow-list in `load_config_from`
  (line 71). Treat any value other than `off`/`false`/`0` as a no-op
  for these keys (so existing `verify = <command>` lines keep working —
  `verify` already routes through the existing path; only the literal
  off-values flip the new toggle).

  Wait — `verify` is already used as a multi-value key for commands.
  Don't overload it. Use distinct config keys instead:

  - `skip_verify = true` → sets `NO_VERIFY=true`
  - `skip_commit = true` → sets `NO_COMMIT=true`

  This keeps the existing `verify = <cmd>` semantics untouched.

## Acceptance criteria

- [x] `wiggum execute --no-verify <plan>` runs phases 1–4 without
      invoking `run_validation`. Stderr contains
      `(verification skipped via --no-verify)`.
- [x] `wiggum execute --no-commit <plan>` completes without any
      `git commit` invocation by wiggum (Claude may still commit if it
      decides to — that's not in scope, but the wiggum-issued prompts
      are gone). Stderr contains `(commit skipped via --no-commit)` at
      each gated site.
- [x] Both flags can be combined.
- [x] `wiggum check --no-verify` exits with `EXIT_BAD_ARGS` and a clear
      error.
- [x] `wiggum check --no-commit` runs verification but does not commit
      after fixes.
- [x] `.wiggumrc` containing `skip_verify = true` and/or
      `skip_commit = true` produces the same behavior as the CLI flags.
- [x] CLI flag overrides config when they disagree.
- [x] Unknown values for `skip_verify` / `skip_commit` (e.g.,
      `skip_verify = maybe`) emit a warning and are treated as `false`.
- [x] `shellcheck -s bash wiggum.sh lib/wiggum.sh install.sh` passes
      with zero warnings.
- [x] `bats test/wiggum.bats` passes, with new tests covering:
      - `--no-verify` skips `run_validation` in execute
      - `--no-commit` skips all five commit sites
      - `skip_verify = true` in `.wiggumrc` works
      - `skip_commit = true` in `.wiggumrc` works
      - CLI overrides config
      - `wiggum check --no-verify` errors out
- [x] README documents both flags and config keys, including the
      caveat that `--no-verify` does not stop Claude from running
      tests during implementation.
- [x] `usage` strings for `execute` and `check` list the new flags.

## Files to touch

- `lib/wiggum.sh`
  - `wiggum_reset` — add new state vars
  - `load_config_from` allow-list — add `skip_verify`, `skip_commit`
  - `apply_config` — handle the new keys with CLI precedence
  - `parse_args` — handle `--no-verify`, `--no-commit`
  - `usage` (execute, check) — document the flags
  - `run_validation` / `run_execute` — gate the phase-2 call
  - `run_check` — refuse `--no-verify`; gate the post-fix commit
  - Introduce `commit_or_skip` helper; replace the five
    `run_claude … prompt_commit` sites with it
  - `print_verify_steps` — show `(skipped)` when `NO_VERIFY=true`
- `test/wiggum.bats` — new tests per acceptance criteria
- `README.md` — document flags, config keys, and the Claude caveat

## Risks and notes

- The phase-1 reconcile commit currently uses an inline prompt, not
  `prompt_commit` — double-check the call site at line 1222 and route
  it through `commit_or_skip` too, or skip it inline.
- `run_check` currently has an early return when `VERIFY_STEPS` is
  empty (line 1412). With `--no-verify`, refuse before that check so
  the error message is specific.
- A `.wiggumrc` containing only `skip_verify = true` plus
  `max_iterations` (no `verify` lines) is a valid configuration and
  should not warn.
- Document in README that `--no-commit` leaves the working tree dirty
  and that subsequent `wiggum execute` runs will see uncommitted state
  in phase-1 diagnostic — Claude may try to reconcile it.
