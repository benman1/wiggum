# Smoke Test Workplan — tiny throwaway task

A small, self-contained smoke test for the `wiggum` CLI. A smoke test (per the
README's "Smoke tests" section) exercises the real artifact end-to-end. For a
CLI tool that means: run the built binary on its Claude-free code paths and
assert it behaves.

**Scope guard.** Every check here uses a `wiggum` command path that does **not**
call `claude` (`run_claude`), so the smoke test is deterministic and needs no
Claude Code authentication. The Claude-driven modes (`plan`, `execute`, `check`,
`docs`, `run`) are intentionally out of scope — they are non-deterministic and
require auth. Grounded against `wiggum.sh:20-83` (dispatch), `lib/wiggum.sh`
`run_init` (1029), `looks_like_plan` (891), the outside-project rejection
(`lib/wiggum.sh:754`), and exit codes `EXIT_BAD_ARGS=1` (`lib/wiggum.sh:14`).

---

## Phase 1 — Smoke harness

### [ ] 1.1 Create the smoke script skeleton
Create an executable `smoke.sh` at the repo root running under
`set -euo pipefail`. It resolves the repo root, creates a fresh temp working
directory and a temp `HOME` (so `init` cannot touch the real `~/.claude`),
`trap`s cleanup of both on exit, and prints `Smoke test passed.` only if every
later check passes (exit non-zero on the first failure). No checks yet — just the
scaffold and a final success print.
- **Acceptance:** `shellcheck -s bash smoke.sh` exits 0, and `./smoke.sh` exits 0
  printing `Smoke test passed.` on the last line.
- **Files:** `smoke.sh`
- **Depends on:** none

### [ ] 1.2 Check `--help` exits 0
Add a check that runs `"$REPO/wiggum.sh" --help` and asserts exit status 0
(the help/empty `MODE` branch returns 0 without loading config or calling
`claude`, per `wiggum.sh:23-26`).
- **Acceptance:** `./smoke.sh` still exits 0; temporarily breaking the assertion
  (e.g. asserting a nonzero status) makes `./smoke.sh` exit non-zero with a
  `FAIL: --help` line on stderr.
- **Files:** `smoke.sh`
- **Depends on:** 1.1

### [ ] 1.3 Check `init bash` generates a `.wiggumrc`
In the temp working dir (with `HOME` pointed at the temp HOME), run
`wiggum init bash` with all interactive prompts declined — `run_init` calls
`setup_claude_permissions` and `setup_wiggum_skill`, both of which `read -r`
(`lib/wiggum.sh:1044,1118,...`), so feed `n` to each, e.g.
`yes n | "$REPO/wiggum.sh" init bash`. Assert the command exits 0 and the
generated `.wiggumrc` contains both `shellcheck` and `bats` (the bash preset's
verify lines).
- **Acceptance:** `./smoke.sh` exits 0; `grep -q shellcheck "$tmp/.wiggumrc"` and
  `grep -q bats "$tmp/.wiggumrc"` both succeed inside the run. Removing the
  `init` invocation makes the check fail with `FAIL: init` on stderr.
- **Files:** `smoke.sh`
- **Depends on:** 1.1

### [ ] 1.4 Check `status` reports a fresh plan as not started
Write a minimal plan file with one `- [ ]` task into the temp dir, run
`"$REPO/wiggum.sh" status <plan>` (read-only, no `claude`), and assert it exits 0
and prints the `not started` state (no `.pid`/`.out` sidecars exist yet).
- **Acceptance:** `./smoke.sh` exits 0 and the captured `status` output matches
  `not started` (e.g. `grep -qi 'not started'`).
- **Files:** `smoke.sh`
- **Depends on:** 1.1

### [ ] 1.5 Check an outside-project input file is rejected
Run `"$REPO/wiggum.sh" execute /etc/hosts` from inside the temp working dir and
assert it exits 1 (`EXIT_BAD_ARGS`) printing `outside the project directory`
(`lib/wiggum.sh:754`). This exercises argument validation, which happens before
any `claude` call.
- **Acceptance:** `./smoke.sh` exits 0 because the rejection is observed: the
  invocation's status is `1` and its stderr matches
  `grep -qi 'outside the project directory'`.
- **Files:** `smoke.sh`
- **Depends on:** 1.1

---

## Phase 2 — Verify & wire in

### [ ] 2.1 Add a Bats test that runs the smoke script
Add one Bats test to `test/wiggum.bats` that runs `./smoke.sh` from the repo
root and asserts `status` 0 and that output contains `Smoke test passed.`. The
test must be self-contained (its own temp dir) and must not depend on a real
`claude` binary — stub `claude` per the existing test conventions if the harness
requires it.
- **Acceptance:** `bats test/wiggum.bats` exits 0 with the new test reported as
  `ok`, and `grep -q smoke.sh test/wiggum.bats` succeeds.
- **Files:** `test/wiggum.bats`
- **Depends on:** 1.2, 1.3, 1.4, 1.5

### [ ] 2.2 Full suite stays green
Run the project's full suite (lint + tests). `smoke.sh` must pass ShellCheck
with zero warnings alongside the other scripts.
- **Acceptance:** `./test/run.sh` exits 0 (ShellCheck clean on
  `wiggum.sh lib/wiggum.sh install.sh smoke.sh`, then all Bats tests pass).
- **Files:** `test/run.sh` (only if the lint line needs `smoke.sh` appended),
  `smoke.sh`
- **Depends on:** 2.1

### [ ] 2.3 (Optional) Document the smoke script
Add a one-line mention of `smoke.sh` to the README's "Smoke tests" section as a
concrete in-repo example. Drop this task `[~]` if it reads as redundant once the
script exists.
- **Acceptance:** `grep -q 'smoke.sh' README.md` succeeds, OR the task line is
  marked `[~]` with a reason.
- **Files:** `README.md`
- **Depends on:** 2.2

---

## Notes & dependencies

- **Out of scope (deliberate):** any smoke check that invokes `claude` — the
  `plan`/`execute`/`check`/`docs`/`run` modes. They need auth and are
  non-deterministic; a smoke test must stay fast and hermetic.
- **Hermetic requirement:** `init` writes to `.wiggumrc` and, if prompts are
  accepted, to `~/.claude/skills/...` (`setup_wiggum_skill`). Always run it in a
  temp working dir with a temp `HOME` and decline every prompt so the real
  environment is never modified.
- **Self-hosting tie-in (optional, not required by this plan):** adding
  `verify = ./smoke.sh` to `.wiggumrc` would make wiggum's own verify waterfall
  run this smoke test. Left out to keep this throwaway task small; revisit only
  if desired.
