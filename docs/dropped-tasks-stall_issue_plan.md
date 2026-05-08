# Workplan: `[~]` dropped-task marker so `count_unchecked` stops false-stalling

Source issue: `docs/dropped-tasks-stall_issue.md`.

This plan introduces an explicit `[~]` checkbox state to mean "dropped"
so `count_unchecked` no longer counts abandoned-but-unchecked tasks as
"remaining". Phases are ordered so each step is independently
shippable and verifiable; later phases depend on earlier ones.

Conventions used here:
- `[ ]` -- task pending, agent should pick it up.
- `[x]` -- task completed.
- Scope: edits to `lib/wiggum.sh`, `test/wiggum.bats`, `README.md`.

---

## Phase 1 -- Counter primitives (`lib/wiggum.sh`)

Goal: get the counting functions correct in isolation, with unit
tests, before any caller starts depending on the new behavior.

Depends on: nothing.

- [x] **1.1** Add a comment above `count_unchecked` explaining that
      `[~]` is intentionally excluded (so future readers don't "fix" it
      by widening the regex).
- [x] **1.2** Widen `count_total_tasks` regex from `\[[ xX]\]` to
      `\[[ xX~]\]` so dropped tasks are part of the denominator and
      `total - unchecked - dropped == done` holds.
- [x] **1.3** Add a new `count_dropped` helper alongside the existing
      counters. Same shape as `count_unchecked` but greps for
      `^\s*-\s*\[~\]`. Echoes the count.
- [x] **1.4** Confirm `count_unchecked` body does NOT need to change:
      `^\s*-\s*\[ \]` already excludes `[~]`. Leave the implementation
      alone, only add the explanatory comment from 1.1.

### Acceptance criteria for Phase 1

- [x] `count_unchecked` returns N for a file with N `[ ]` lines and M
      `[~]` lines (i.e. ignores `[~]`).
- [x] `count_total_tasks` returns N + M + done.
- [x] `count_dropped` returns M for the same file.
- [x] All three helpers handle: empty file, missing file, indented
      checkboxes, multiple files passed as args.
- [x] `shellcheck -s bash lib/wiggum.sh` passes with zero warnings.

---

## Phase 2 -- Unit tests for counter primitives (`test/wiggum.bats`)

Goal: lock the new behavior with tests slotted next to the existing
`count_unchecked` / `count_total_tasks` blocks.

Depends on: Phase 1.

- [x] **2.1** Add `count_unchecked: ignores [~] dropped lines` test:
      file with two `[ ]`, three `[~]`, one `[x]` -> expect 2.
- [x] **2.2** Add `count_total_tasks: counts [~] as a task` test: same
      mixed file -> expect 6 (2 + 3 + 1).
- [x] **2.3** Add `count_dropped: counts only [~] lines` test: same
      mixed file -> expect 3.
- [x] **2.4** Add `count_dropped: returns zero when no [~] lines`
      test: file with only `[ ]` and `[x]` -> expect 0.
- [x] **2.5** Add `count_dropped: returns zero for missing file`
      test (mirrors the existing `count_unchecked` missing-file test).
- [x] **2.6** Add `count_dropped: handles indented [~] lines` test
      (mirrors the existing `count_unchecked` indented-checkbox test).
- [x] **2.7** Add `count_dropped: counts across multiple files` test
      (mirrors the existing multi-file test).

### Acceptance criteria for Phase 2

- [x] `bats test/wiggum.bats` passes with all new tests green.
- [x] Existing counter tests still pass unchanged (no regression in
      `count_unchecked` or `count_total_tasks` behavior for plans that
      contain no `[~]`).

---

## Phase 3 -- `run_execute` phase-2 loop wiring

Goal: surface the dropped count in step headers and log lines, and
verify the existing zero-remaining short-circuit handles all-dropped
plans without further code changes.

Depends on: Phase 1.

- [x] **3.1** In `run_execute` (around `lib/wiggum.sh:1320` onward),
      compute `dropped` once per iteration alongside `prev_remaining`
      via `count_dropped "${FILES[@]}"`. Recompute after each step
      where `remaining` is recomputed (Claude may convert `[ ]` to
      `[~]` mid-run).
- [x] **3.2** Update the phase-2 step-header echo (line ~1330) to read
      `Phase 2: Implementation step $i of $MAX_ITERATIONS ($remaining
      remaining, $dropped dropped)`. Match the wording in the
      `log_entry "phase"` call on the next line.
- [x] **3.3** Update the stall log line at ~1396 to also include
      dropped count for forensics:
      `no progress on iteration $i ($remaining remaining, $dropped
      dropped, stall $stall_count)`.
- [x] **3.4** Confirm by inspection that the existing zero-remaining
      branch at ~1369 (`if [[ "$remaining" -eq 0 ]]`) already short-
      circuits a fully-dropped plan to `complete`, since
      `count_unchecked` excludes `[~]`. Add a brief inline comment
      noting this so a future reader doesn't reintroduce the bug.

### Acceptance criteria for Phase 3

- [x] A plan with three `[~]` and zero `[ ]` enters `run_execute`,
      runs phase 1, and on the very first iteration of the phase-2 loop
      reports `remaining=0` and breaks with `stop_reason=complete`
      (proceeding to phase 3 without ever invoking the implementation
      Claude call).
- [x] A plan with two `[ ]` and three `[~]` reports
      `2 remaining, 3 dropped` in the phase-2 header and the log entry.
- [x] Stall guard fires only on `[ ]` count failing to decrease, not
      on `[~]` count.
- [x] `shellcheck -s bash lib/wiggum.sh` still passes.

---

## Phase 4 -- Phase-2 implementation prompt update

Goal: make Claude treat `[~]` as a do-not-pick state during the
implementation step.

Depends on: Phase 3 (so the loop is already passing `dropped` count
and we know the full prompt context).

- [x] **4.1** Update the phase-2 implementation prompt (around
      `lib/wiggum.sh:1340`) to say, in addition to "Execute the next
      discrete implementation step from the plan": "Skip any task
      marked `[~]` -- that is the dropped state, an in-plan decision
      not to do the work. Treat `[~]` as terminal, like `[x]`. Do not
      revisit, reconcile, or re-evaluate `[~]` lines."
- [x] **4.2** Keep the existing `[ ]` / "next unchecked" wording so
      the prompt remains backward-compatible with plans that have no
      `[~]` lines.

### Acceptance criteria for Phase 4

- [x] The phase-2 prompt string contains the `[~]` skip instruction.
- [x] `shellcheck -s bash lib/wiggum.sh` still passes (heredoc/quoting
      stays clean).
- [x] An eyeball review confirms the prompt still reads naturally and
      doesn't contradict the rest of the implementation instruction.

---

## Phase 5 -- Phase-1 reconcile prompt update

Goal: prevent the phase-1 diagnostic from "fixing" `[~]` back to
`[ ]` or `[x]` when it sees the work missing.

Depends on: Phase 1 (so the convention is established).

- [x] **5.1** Update the phase-1 prompt (around `lib/wiggum.sh:1309`)
      so the reconcile instruction reads, in addition to the current
      `[x] for done, [ ] for not done` guidance: "Leave `[~]` lines
      untouched. `[~]` is the terminal dropped state -- the work was
      intentionally abandoned and is not pending. Do not convert
      `[~]` to `[ ]` or `[x]`."

### Acceptance criteria for Phase 5

- [x] The phase-1 prompt string contains the `[~]`-is-terminal
      instruction.
- [x] `shellcheck -s bash lib/wiggum.sh` still passes.

---

## Phase 6 -- Phase-3 summary prompt update

Goal: feed the dropped count and the dropped task labels into the
phase-3 summary so it can render a "What was dropped" subsection
without inventing it from prose.

Depends on: Phase 1 (for `count_dropped`) and Phase 3 (so `dropped`
is already in scope inside `run_execute`).

- [x] **6.1** Before the phase-3 Claude call (around
      `lib/wiggum.sh:1421`), capture the list of dropped task lines
      from the plan files into a shell variable, e.g.
      `dropped_lines="$(grep -hE '^\s*-\s*\[~\]' "${FILES[@]}" || true)"`.
- [x] **6.2** Capture the dropped count as well via
      `final_dropped="$(count_dropped "${FILES[@]}")"`.
- [x] **6.3** Build a `dropped_context` string that, when non-empty,
      reads roughly: "There are $final_dropped dropped tasks ([~]).
      Render them in the summary under a 'What was dropped' subsection,
      preserving the rationale recorded on each line. The dropped lines
      are: \n$dropped_lines". When `final_dropped == 0`, leave
      `dropped_context` empty so the prompt is unchanged.
- [x] **6.4** Append `${dropped_context}` to the phase-3 prompt
      argument, after `final_benchmark_context`. Mirror the existing
      conditional context pattern.
- [x] **6.5** Update the phase-3 prompt to instruct Claude that `[~]`
      is dropped and must NOT be re-marked as `[x]` during the "mark
      completed tasks" step.

### Acceptance criteria for Phase 6

- [x] When the plan has zero `[~]` lines, the phase-3 prompt is
      unchanged (no spurious "What was dropped" mention).
- [x] When the plan has one or more `[~]` lines, the phase-3 prompt
      contains both the count and the verbatim dropped lines, plus the
      "do not re-mark `[~]` as `[x]`" instruction.
- [x] `shellcheck -s bash lib/wiggum.sh` still passes (quoting around
      `dropped_lines` interpolation is safe; multi-line strings don't
      break the heredoc/`echo -e` pattern used elsewhere in the file).

---

## Phase 7 -- End-to-end regression test (Bats)

Goal: lock the false-stall fix with a behavior test, not just unit
tests on the counters.

Depends on: Phases 1-6.

- [x] **7.1** Add a Bats test for an all-dropped plan: three `[~]`,
      zero `[ ]`, zero `[x]`. Stub `claude` as a no-op as the existing
      tests do. Invoke the relevant slice of `run_execute` (or a
      smaller wrapper if `run_execute` is too coarse to test directly
      -- in that case test the count-driven branch via
      `count_unchecked` returning 0). Assert that no phase-2
      implementation iteration runs (e.g. by counting how many times
      the stub was called, or by checking log entries).
- [x] **7.2** Add a Bats test for a mixed plan: two `[ ]`, three
      `[~]`, one `[x]`. Assert that the phase-2 step header / log line
      reports `2 remaining, 3 dropped`. If asserting on the live
      `run_execute` output is too brittle, assert on the underlying
      counters (`count_unchecked == 2`, `count_dropped == 3`,
      `count_total_tasks == 6`) and the prompt-construction helper
      (if any) -- whichever is the lowest-friction stable surface.
- [~] **7.3** Add a Bats test asserting the phase-2 prompt string
      mentions `[~]` (use the prompt-builder if one exists, or extract
      a small helper as part of Phase 4 if the prompt is currently
      constructed inline -- only extract if doing so is genuinely
      cleaner; otherwise skip this sub-task and rely on visual review).
      Dropped: phase-2 prompt is constructed inline in `run_execute`;
      extracting a builder solely for testability would add abstraction
      with no reuse. Visual review confirmed `lib/wiggum.sh:1377`
      contains the `Skip any task marked [~]` instruction.

### Acceptance criteria for Phase 7

- [x] All-dropped plan regression test passes (would have failed
      before this change set).
- [x] Mixed-plan counter test passes.
- [x] `bats test/wiggum.bats` passes overall.

---

## Phase 8 -- README documentation

Goal: document the marker so plan authors actually use it.

Depends on: Phases 1-6 (so the documented behavior is real).

- [x] **8.1** In README.md, add a short "Dropped tasks" subsection
      under the plan-file conventions area. Cover: what `[~]` means,
      when to use it (mid-execution discovery that a task is no longer
      applicable), how to record the rationale on the same line, and
      that wiggum will not pick `[~]` tasks up again.
- [x] **8.2** Note the GitHub-rendering caveat: `[~]` renders as
      plain text in GitHub's task-list view, which is acceptable
      because plans are primarily read in IDEs / `cat` / `grep`.
- [x] **8.3** Add a concrete example showing a `[~]` line with
      inline rationale, mirroring the issue's examples (e.g.
      `- [~] **2.6** -- surprisal/burstiness. Dropped: llm-server has
      no perplexity endpoint.`).
- [x] **8.4** Briefly mention what `[~]` is NOT: it is not "deferred
      to a later phase" and it is not "blocked" -- it is a terminal
      decision recorded in the plan itself.

### Acceptance criteria for Phase 8

- [x] README contains the `[~]` subsection with meaning, usage,
      rationale-on-same-line guidance, GitHub-rendering caveat, an
      example, and a "what it is NOT" note.

---

## Phase 9 -- Final verification

Goal: full lint + test sweep before declaring done.

Depends on: all earlier phases.

- [ ] **9.1** Run `shellcheck -s bash wiggum.sh lib/wiggum.sh
      install.sh`. Zero warnings.
- [ ] **9.2** Run `bats test/wiggum.bats`. All green, including the
      new tests from Phases 2 and 7.
- [ ] **9.3** Run `./test/run.sh` (lint + tests via the project's
      conventional entry point). Green.
- [ ] **9.4** Manual smoke test: copy `docs/dropped-tasks-stall_issue.md`
      (or any small plan) into a scratch dir, edit a couple of `[ ]`
      lines to `[~]`, and run `wiggum execute` against it with the
      `claude` CLI stubbed (or `--dry-run` if available). Verify the
      log shows the new `(R remaining, D dropped)` format and that an
      all-dropped plan exits with `stop_reason=complete`.

### Acceptance criteria for Phase 9

- [ ] Lint clean.
- [ ] Bats clean.
- [ ] Smoke test confirms the fix end-to-end.

---

## Risks, callouts, and intentional non-goals (carried over from issue)

- **Do NOT add prose-based DROPPED detection.** No regex like
  `\bDROPPED\b` that re-counts `[ ]` lines as dropped. The point of
  `[~]` is that it is a syntactic state.
- **Do NOT backfill existing plans.** Adopt-as-you-go. Plans that
  still use `[ ]` + "DROPPED" annotation will continue to false-stall
  until manually converted -- that is acceptable.
- **Do NOT change how `[x]` is counted.** Out of scope.
- **Do NOT auto-drop tasks based on stall behavior.** Out of scope.
- **Phase-1 reconcile must leave `[~]` alone.** Covered by Phase 5.
- **GitHub task-list rendering of `[~]`** is plain text; called out
  in README per Phase 8.
