# Execution Summary: `[~]` dropped-task marker

Plan: `docs/dropped-tasks-stall_issue_plan.md`
Issue: `docs/dropped-tasks-stall_issue.md`
Run started: 2026-05-08 09:52:03
Stop reason: `complete` (all tasks resolved by iteration 8 of phase 2)

## What was implemented

All nine phases of the plan landed.

- **Phase 1 -- Counter primitives.** `count_unchecked` got a comment
  documenting the intentional `[~]` exclusion. `count_total_tasks` was
  widened to `\[[ xX~]\]` so dropped tasks are part of the
  denominator. A new `count_dropped` helper was added with the same
  shape as `count_unchecked` but matching `[~]`.
- **Phase 2 -- Counter unit tests.** Seven new Bats tests cover:
  `count_unchecked` ignoring `[~]`, `count_total_tasks` including it,
  and `count_dropped` across mixed/empty/missing/indented/multi-file
  inputs.
- **Phase 3 -- `run_execute` wiring.** `dropped` is now computed once
  per phase-2 iteration (alongside `prev_remaining`) and recomputed
  whenever `remaining` is. The phase-2 step header and stall log line
  both report `(R remaining, D dropped)`. An inline comment marks the
  zero-remaining short-circuit branch as the all-dropped fast path.
- **Phase 4 -- Phase-2 prompt.** The implementation prompt now tells
  Claude to skip `[~]` lines and treat them as terminal.
- **Phase 5 -- Phase-1 reconcile prompt.** The diagnostic prompt now
  instructs Claude to leave `[~]` lines untouched during reconcile.
- **Phase 6 -- Phase-3 summary prompt.** Before the phase-3 call,
  `dropped_lines` and `final_dropped` are captured; a `dropped_context`
  string is built only when at least one `[~]` exists, then appended to
  the prompt. The phase-3 prompt also forbids re-marking `[~]` as
  `[x]`.
- **Phase 7 -- End-to-end Bats.** Two regression tests cover the
  all-dropped plan (must short-circuit to `complete`) and the mixed
  plan (counters report `2 remaining, 3 dropped, 6 total`).
- **Phase 8 -- README.** Added a "Dropped tasks" subsection with
  meaning, usage, on-line rationale guidance, the GitHub-rendering
  caveat, a concrete example, and an explicit "what `[~]` is NOT"
  note.
- **Phase 9 -- Final verification.** ShellCheck clean, `bats
  test/wiggum.bats` green, `./test/run.sh` green, manual smoke test
  confirmed the new log format and the all-dropped short-circuit.

## What was deferred

- **7.3 -- Phase-2 prompt-string Bats assertion.** Marked `[~]` in the
  plan with rationale on the same line. The phase-2 prompt is
  constructed inline inside `run_execute`; extracting a builder solely
  to make the prompt assertable in isolation would add abstraction
  with no other reuse. Visual review of `lib/wiggum.sh:1377`
  confirmed the `Skip any task marked [~]` instruction is present, so
  the value of the test was judged not worth the refactor cost. This
  is precisely the case the new `[~]` marker exists to express.

## Issues encountered

None worth carrying forward. The work fell out cleanly because the
existing zero-remaining short-circuit was already correct once
`count_unchecked` excluded `[~]` -- no new control flow was needed
for the all-dropped fast path.

## Verification results

- `shellcheck -s bash wiggum.sh lib/wiggum.sh install.sh` -- zero
  warnings.
- `bats test/wiggum.bats` -- all green, including the seven new
  counter tests (Phase 2) and the two new regression tests (Phase 7).
- `./test/run.sh` -- green (lint + tests).
- Manual smoke test: an all-dropped plan run through `wiggum execute`
  with `claude` stubbed terminated on the first phase-2 iteration with
  `stop_reason=complete`; the log line emitted the new `(R remaining,
  D dropped)` format.

## Why execution stopped

`complete`. By iteration 8 of phase 2, `count_unchecked` over the
plan files returned 0 and `run_execute` short-circuited to phase 3
(see `docs/dropped-tasks-stall_issue_plan.log:48`). The plan now
contains zero `[ ]` lines: 56 `[x]` and 1 `[~]` (task 7.3, dropped
with rationale).
