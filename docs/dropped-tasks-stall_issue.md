# Issue: `count_unchecked` counts DROPPED tasks, causing false stalls

## Background

Plans authored against wiggum routinely contain tasks that are explicitly
**dropped** mid-execution — the rationale is recorded in the plan, but the
checkbox is left as `[ ]` because the work was never done. Common reasons:
the dependency the task assumed is gone, a separate phase made it
redundant, or diagnosis showed the assumption behind the task was wrong.

`count_unchecked` (`lib/wiggum.sh:498-507`) greps for `^\s*-\s*\[ \]`
without parsing any annotation, so dropped items count as "remaining"
forever. With nothing left for Claude to advance, two iterations register
as `stall: no progress` and the run terminates as `stalled` even though
the plan is functionally complete.

### Concrete recurrence (real plan, not synthetic)

`docs/ai-slop-detection_issue_plan.md` in `/Users/ben/ux-research` has
27+ tasks across six phases. Three were dropped mid-execution with
rationale recorded inline:

- **2.6** — surprisal/burstiness features. Dropped because the
  llm-server has no perplexity endpoint and the legacy detector already
  targets that hypothesis.
- **4.5** — endpoint smoke test. Dropped because in-process unit
  coverage made it redundant.
- **5.2** — chelsea-ai before/after audit. Dropped because the
  pre-rewrite copy is no longer live.

The wiggum log
(`/Users/ben/ux-research/docs/ai-slop-detection_issue_plan.log`)
shows the consequence:

```
[2026-05-07 11:46:59] phase: 2 - implementation step 1 of 10 (3 remaining)
[2026-05-07 11:56:24] stall: no progress on iteration 1 (3 remaining, stall 1)
[2026-05-07 12:04:53] stall: no progress on iteration 2 (3 remaining, stall 2)
[2026-05-07 12:04:53] stop: stalled after iteration 2
```

Two consecutive stall iterations re-ran phase-1 diagnostic and phase-2
commit cycles on already-shipped code. Nothing landed. The phase-3
summary document explicitly calls this out as a harness bug:

> "The wiggum runner counts `[ ]` boxes without parsing the DROPPED
> annotation, so 2.6, 4.5, and 5.2 register forever as 3 remaining."

The same false-stall pattern shows up in
`docs/jargon-analyzer-bottleneck_plan.log` (three stalls in a row on the
same three deploy-gated bullets) and is a recurring frustration when
plans exceed the no-progress threshold for legitimate reasons.

## Goals

1. Allow plan authors to mark a task as dropped without checking the
   box, and have `count_unchecked` exclude it from the remaining count.
2. Keep the dropped task visible in the plan file (so the rationale
   stays alongside the original task text) — do not require deleting
   the line or rewriting it as `[x]`.
3. Make the convention explicit and discoverable enough that
   `wiggum status` / `wiggum check` and the phase-3 summary prompt know
   the difference between "done", "remaining", and "dropped".

## Non-goals

- Inferring dropped status from prose. The marker must be a
  syntactically explicit token, not natural language.
- Backfilling existing plans. Adopt-as-you-go.
- Changing how `[x]` is counted.
- Auto-dropping tasks based on stall behavior.

## Current behavior

- `count_unchecked` (`lib/wiggum.sh:498`) — `grep -cE '^\s*-\s*\[ \]'`.
  Every empty checkbox counts, regardless of trailing annotation.
- `count_total_tasks` (`lib/wiggum.sh:510`) — `grep -cE '^\s*-\s*\[[ xX]\]'`.
  Same treatment.
- `run_execute` phase-2 loop (`lib/wiggum.sh:1322-1407`) — uses
  `count_unchecked` to drive `prev_remaining` / `remaining` and the
  no-progress guard at line 1395.
- Phase-3 summary prompt has no input that distinguishes
  dropped-but-unchecked tasks from genuinely remaining ones.

## Desired behavior

### Convention

Adopt the `[~]` checkbox state as "dropped". Examples that should
count as dropped:

```markdown
- [~] **2.6** — surprisal/burstiness. Dropped: llm-server has no
      perplexity endpoint.
- [~] 5.2 chelsea-ai before/after audit (DROPPED — pre-rewrite copy
      no longer live)
```

`[~]` is preferred over a sentinel like `[x] DROPPED` because:

- It is a distinct lexical state, so `count_unchecked` and
  `count_total_tasks` can detect it with a single regex tweak.
- It is visually distinct from both `[ ]` (todo) and `[x]` (done) when
  scanning a plan in any markdown viewer.
- It does not collide with GitHub's task-list rendering (`[~]` simply
  renders as plain text — acceptable, since wiggum plans are read in
  IDEs and via `cat`/`grep`).

### Function changes

- `count_unchecked` continues to count only `[ ]`. No change.
- `count_total_tasks` is widened to count `[ ]`, `[x]`, `[X]`, and
  `[~]`. (So `total - unchecked - dropped == done`.)
- New helper `count_dropped` (mirror of `count_unchecked`) returns
  the number of `[~]` lines. Used by:
  - `run_execute` summary line
    (`Phase 2: Implementation step $i of $MAX_ITERATIONS (R remaining, D dropped)`)
  - Phase-3 summary prompt context
  - `wiggum status` (if/when status reporting is reintroduced)

### Stall guard

The current stall guard compares `remaining` to `prev_remaining`.
With dropped tasks excluded from `remaining`, the guard works as
intended without further changes — a fully-dropped queue reports
`remaining = 0`, so `if [[ "$remaining" -eq 0 ]]` at line 1369
short-circuits to `complete`.

### Phase-2 implementation prompt

The phase-2 prompt (around `lib/wiggum.sh:1245`) instructs Claude to
"Pick the next unchecked `[ ]` task". Update the prompt so Claude
explicitly understands `[~]` is a do-not-pick state, with a brief
note that it represents an in-plan decision to drop the task and
should not be revisited.

### Phase-3 summary prompt

Pass the dropped count and the list of dropped task labels into the
phase-3 summary so the generated summary can render a "What was
dropped" subsection without inventing it from prose. (Currently the
ux-research summary docs derive this manually, which is the only
reason the harness bug was caught at all.)

## Acceptance criteria

- [ ] `count_unchecked` returns N for a plan with N `[ ]` lines and
      M `[~]` lines (i.e. ignores `[~]`).
- [ ] `count_total_tasks` returns `N + M + done`.
- [ ] New `count_dropped` returns M.
- [ ] `wiggum execute` against a plan whose only unchecked items are
      `[~]` reports `complete`, not `stalled`. Specifically: a plan
      with three `[~]` and zero `[ ]` runs phase 1, skips the phase-2
      loop (because `count_unchecked` returns 0), and proceeds to the
      phase-3 summary on the first iteration.
- [ ] A plan with two `[ ]` and three `[~]` reports
      `2 remaining, 3 dropped` in the phase-2 step header and the
      stall guard fires only when `[ ]` count fails to decrease.
- [ ] Phase-3 summary prompt receives both counts and the dropped
      task labels.
- [ ] Phase-2 implementation prompt instructs Claude to skip `[~]`
      lines when picking the next task.
- [ ] `shellcheck -s bash wiggum.sh lib/wiggum.sh install.sh`
      passes with zero warnings.
- [ ] `bats test/wiggum.bats` passes, with new tests covering:
      - `count_unchecked` ignores `[~]`
      - `count_total_tasks` counts `[~]`
      - `count_dropped` counts only `[~]`
      - All-dropped plan completes (regression test for the false-stall)
      - Mixed `[ ]` / `[~]` / `[x]` plan reports correct counts
- [ ] README documents the `[~]` marker — what it means, when to use
      it, and the convention of recording rationale on the same line.

## Files to touch

- `lib/wiggum.sh`
  - `count_unchecked` (line 498) — no behavior change, but add a
    comment explaining `[~]` is excluded.
  - `count_total_tasks` (line 510) — widen regex to `\[[ xX~]\]`.
  - New `count_dropped` helper alongside the other counters.
  - `run_execute` phase-2 loop header (line 1330) — show dropped count.
  - Phase-2 implementation prompt block (around line 1245) — mention `[~]`.
  - Phase-3 summary prompt block (around line 1322 onward) — pass
    dropped count and list.
- `test/wiggum.bats` — new tests per acceptance criteria, slotted in
  next to the existing `count_unchecked` / `count_total_tasks` blocks
  (lines 257-308 and 310 onward).
- `README.md` — document the marker and the rationale-on-same-line
  convention.

## Risks and notes

- **GitHub markdown rendering.** `[~]` renders as plain text, not as
  a styled checkbox. Acceptable for a developer-facing tool; mention
  this in the README.
- **Existing plans.** Authors who currently delete dropped lines
  outright won't see a behavior change. Authors who leave `[ ]` with
  a "DROPPED" annotation will continue to hit the false-stall until
  they convert to `[~]`. Adopt-as-you-go is fine; we are not going to
  parse English.
- **Don't fall back to prose detection.** Resist the temptation to
  also exclude lines matching `\bDROPPED\b` after `[ ]`. That keeps
  the bug alive in a different form (any task with the word DROPPED
  anywhere on the line silently disappears) and rewards inconsistent
  authoring. The point of `[~]` is that it is a syntactic state, not
  a free-text convention.
- **Phase-1 reconcile.** The phase-1 diagnostic should not "reconcile"
  `[~]` lines into `[ ]` or `[x]` if it sees the work missing. Add an
  instruction to the phase-1 prompt that `[~]` is a terminal state,
  same as `[x]`.
