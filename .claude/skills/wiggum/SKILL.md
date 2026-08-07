---
name: wiggum
description: Orchestrate the wiggum CLI — create a workplan, run it, monitor it, wait for it, detect when it's blocked, kill it if it runs too long, and chain workplans together. Use for any non-trivial change you want planned, executed, verified, and committed through wiggum.
argument-hint: <issue, plan file, or "chain: plan-a.md plan-b.md">
---

# Wiggum: Orchestrator

You **drive the `wiggum` CLI** — you do not re-implement its loop yourself. Wiggum
is a self-driving agent loop (plan → implement → verify → commit). Your job is to
turn the request into a workplan, launch wiggum on it, supervise the run, and
report the outcome. Execute without asking for confirmation.

The request: **$ARGUMENTS**

## Preflight — one step, then act

This skill is the **authoritative reference for wiggum's interface**: the commands
and flags in "The CLI you drive" and the steps below are correct and current. Use
them verbatim — do **not** burn turns running `wiggum --help` / `wiggum help execute`
to re-derive syntax you already have here.

The only things you genuinely can't know up front are repo-specific, so do this
discovery **once, in a single command**, then proceed:

```
command -v wiggum && cat .wiggumrc 2>/dev/null && ls environment.yml .venv .nvmrc Gemfile poetry.lock uv.lock 2>/dev/null
```

- **wiggum on PATH?** If `command -v wiggum` is empty, tell the user to install it
  (`./install.sh` in the wiggum repo) and stop — do not hand-simulate the loop. Run
  from the target project root.
- **`.wiggumrc`** — wiggum reads it itself; you read it here only to learn the verify
  steps (and therefore which environment to activate). No config → wiggum just skips
  verification (still fine).
- **Activate the project's environment.** wiggum runs Claude's tools and the verify
  steps in your *current* shell. If the markers above show one — conda
  (`environment.yml`), a virtualenv/`.venv`, Poetry/uv (`poetry.lock`/`uv.lock`), a
  Node version (`.nvmrc`), Bundler (`Gemfile`), etc. — activate it in the same shell
  you launch from, *before* running, or tests/builds hit the wrong interpreter and
  fail spuriously. For unattended/background runs, prefer self-activating verify
  commands in `.wiggumrc` (e.g. `conda run -n <env> pytest`, `poetry run pytest`) so
  the run is reproducible no matter which shell starts it.

That's the whole preflight. Everything else you need is in this skill.

## The CLI you drive

| Command | What it does |
|---|---|
| `wiggum plan <issue-or-file> [--plan-file docs/<slug>_plan.md]` | Write a workplan. Does not touch code. |
| `wiggum execute <plan> [--max-iterations N]` | Run the loop in the foreground (blocks). |
| `wiggum execute <plan> --background` | Run detached; writes `docs/<name>.pid` + `docs/<name>.out`. Returns immediately. |
| `wiggum status <plan>` | Task counts + run state (not started / running / running but appears blocked / finished: \<reason\>). Read-only. |
| `wiggum watch <plan> [--timeout S] [--kill-on-timeout] [--poll-interval N]` | Stream output and block until the run finishes — this is "wait". |
| `wiggum kill <plan>` | Stop the run (only that run's process tree). |
| `wiggum chain <plan...> [--max-iterations N]` | Execute several plans in order; stop at the first failure. |
| `wiggum top` | Every run at a glance: one line per known run (plan, pid, state, task tally). Read-only — use it to see them all at once. |

Sidecar files live next to the plan: `docs/<name>.pid`, `docs/<name>.out`,
`docs/<name>.log`. `status`/`watch`/`kill` all derive these from the plan path,
so always refer to a run by its **plan file**.

Always invoke these as `wiggum <command>` (e.g. `wiggum top`, `wiggum status`).
Wiggum's internals are shell functions named `run_top`, `run_status`, etc. — those
are **not** commands. Never call `run_top`/`run_status`/… directly: they only exist
inside wiggum's own process, so in any fresh shell (notably under `conda run …`)
they fail with `command not found`. The `wiggum` binary is the only entry point.

## Workflow

### 1. Classify the request

- **A wiggum run already in progress** — the user asks to check on / monitor /
  wait for / report on a run, or `wiggum status <plan>` shows `running`: do **not**
  start a new run. Attach to it with `wiggum watch <plan>` to follow it to
  completion (your "wait"), then report a summary (step 5). If you don't know which
  plan, run `wiggum top` to list every active run, or look for a `docs/*.pid`
  sidecar. This is the common "what's my background run doing?" case.
- **An existing plan file** (path ending in `_plan.md`, or a markdown file full of
  `- [ ]` tasks): skip to step 3.
- **"chain: a.md b.md c.md"** or several plan paths: this is a chain — go to
  "Chaining" below.
- **An issue file or a free-text description**: create a plan first (step 2).

### 2. Create a wiggum-compatible workplan

Either run `wiggum plan "<issue or file>"` (it writes `docs/<slug>_plan.md`), or
write the plan yourself in the format below. A wiggum plan is a markdown checklist:

```markdown
# <Title>

## Constraints
- In scope: <what this work will do>
- Out of scope: <what it deliberately will not do>
- Never do: <actions that would be wrong here>

<!-- defect work only — omit all four sections for feature work -->
## Symptoms
- <what is observably wrong, in the terms of whoever sees it> — **observed**
- <what follows from the code but you have not seen happen> — **predicted**
- The tell: <the signal that separates this defect from the benign explanation>

## Root cause
1. <step from the entry point toward the failure> — `path:line`
2. <next step> — `path:line`

## Why existing verification missed it
<the blind spot, citing the tests that pass anyway; if a passing test pins the
buggy behaviour, name it>

## Blast radius
<what is affected — and explicitly what is unaffected, and why>

## Phase 1: <name>
- [ ] <discrete task>
  Acceptance: <observable outcome — a passing test, a specific log line, a file
  that exists, a command that exits 0>. Never a feeling ("works", "looks right").
  Files: <best-effort paths this task creates or modifies>
- [ ] <next task>
  Acceptance: ...
  Files: ...

### Acceptance Criteria
**Happy Path** — Given <context>, When <action>, Then <observable outcome>.
**Edge Cases** — empty, boundary, or large inputs behave correctly.
**Error States** — invalid input or a failed/unavailable dependency fails safely
with a clear error.
**Non-Functional** — name an observable check (a benchmark command, a lint rule,
a measurable threshold), never a feeling.
```

Rules for a good plan:
- Open the plan, before any phase, with a `## Constraints` section as a self-check
  — `In scope`, `Out of scope`, and `Never do` — then derive the phases so they
  stay within those bounds.
- Every task is a real Markdown checkbox line — `- [ ]` (GFM `*`/`+` bullets also
  count) — with its own **Acceptance:** and **Files:** lines. This matters
  mechanically: wiggum tracks progress by *counting* `[ ]`/`[x]`/`[~]` checkboxes,
  so a "task" written as a heading, bold text, or plain prose has no checkbox, is
  invisible to wiggum, and makes the run report `0 tasks` and stop immediately. A
  task without observable acceptance is a wish, not a step.
- `[x]` = done, `[ ]` = pending, `[~]` = dropped (terminal — wiggum won't re-pick
  it). Record why on the `[~]` line.
- Give each phase its own phase-level **### Acceptance Criteria** section, in
  addition to (not instead of) the per-task `Acceptance:`/`Files:` lines. Organize
  it into four categories: **Happy Path** (the primary flow works end to end),
  **Edge Cases** (empty, boundary, or large inputs), **Error States** (invalid
  input or a failed/unavailable dependency fails safely with a clear error), and
  **Non-Functional** (performance, formatting, accessibility). Every Non-Functional
  criterion must name an *observable check* — a benchmark command, a lint rule, a
  measurable threshold — never a feeling. `Given <context>, When <action>, Then
  <observable outcome>` is the recommended form, but a plain observable pass/fail
  line is fine where Given/When/Then is overkill.
- Before finalizing, confirm the APIs/commands the plan assumes actually exist
  (grep the repo). Don't plan around a hallucinated API.
- Every statement the plan makes about *current* behaviour cites its source as
  `path:line`, and you must have read that line before citing it — no citation
  from memory or inference. This complements `Files:`: `Files:` covers what a task
  will write, the citations cover what you read to justify the plan.
- Before planning a task that adds a test to an existing file, read that file's
  harness. Module-scope mocks (`vi.mock`, `jest.mock`, fixtures, monkeypatching)
  are hoisted per file and can make the intended test impossible there, so the task
  must state whether the test can live in that file or needs a new one. Never plan
  to weaken an existing mock so a new test fits.
- When the input is a defect report, diagnose before prescribing: the four sections
  above (`## Symptoms`, `## Root cause`, `## Why existing verification missed it`,
  `## Blast radius`) go before the phases, with every symptom tagged **observed**
  or **predicted**. For work that isn't a defect, omit them rather than inventing
  symptoms.
- Apply the four risk gates, and mark a gate whose trigger is absent as *not
  triggered* rather than dropping it silently: (1) **measure before you act** — a
  phase justified by a claim about production data or runtime state starts with a
  read-only measurement of that claim; (2) **activating never-run code is not a
  no-op** — precede it with a read-only impact report over real inputs; (3)
  **irreversible work carries four conditions** — default to a dry run, export the
  affected rows before the first real write, be idempotent, and record the affected
  count per scope; (4) **a new guard must pass on a clean tree** — enumerate the
  legitimate exceptions up front, and its acceptance states that the guard passes
  against current code on its first run and fails when the defect is reintroduced.
- Close the plan with a `## Sequencing — what can ship independently` section
  naming, for every phase, whether it can ship independently or must wait, and why.
  This is not the task-dependency list: `Depends on:` orders the work, this states
  shipping risk. A fix that only turns nulls into values ships freely; a fix that
  can delete good data waits for the measurement that bounds its blast radius.
- Keep plans focused. Very large plans (40+ tasks) tend to stall — split them and
  `chain` instead.

Confirm the plan looks right, then continue.

### 3. Execute and supervise

**First, activate the project environment** (from preflight) — *before* you launch,
not after. Launching `-b` into the wrong env means the verify steps (pytest/ruff/…)
run under the wrong interpreter and thrash, and you waste a `kill` + relaunch.
`wiggum execute` prints an environment line at startup; if it warns that no env is
active, stop, activate it, and relaunch.

**Size the iteration budget to the plan, on the FIRST launch.** An iteration
completes roughly one task, so a run needs at least as many iterations as the plan
has open checkboxes, plus headroom for the ones that need a second pass. The
default is **3** — from `--max-iterations`'s built-in default, the `max_iterations`
in the `.wiggumrc` templates wiggum generates, or a `.wiggumrc` written for an
older, smaller plan — and it is almost always wrong for a real workplan. A 3-
iteration budget on an 11-task plan does not fail loudly; it stops `incomplete`
about a quarter of the way in, which reads like a stall and costs a supervise
cycle to diagnose.

So count the boxes and pass the flag explicitly — **always**, even when
`.wiggumrc` already sets `max_iterations`, because the flag overrides it and you
should not have to read their config to get this right:

```
open=$(grep -c '^ *[-*+] \[ \]' docs/<name>_plan.md)
wiggum execute docs/<name>_plan.md --background --max-iterations $(( open * 2 + 3 ))
```

`open * 2 + 3` is a reasonable rule of thumb — roughly two passes per task plus
slack. Do **not** economise here: iterations are a *ceiling*, not a target. Wiggum
stops as soon as every task is done, and it stops on its own stall detection long
before it burns a large budget, so an over-generous ceiling costs nothing while a
tight one reliably costs a re-run. If you catch yourself re-running a plan purely
because it stopped `incomplete`, the budget was too small at launch.

Then launch detached so you can monitor and bound it:

```
wiggum execute docs/<name>_plan.md --background --max-iterations <sized above>
```

Then supervise in a loop until it finishes:

1. `wiggum status docs/<name>_plan.md` — read **State** and the task counts.
2. While **State** is `running`, `wiggum watch <plan>` it — always watch a running
   workplan through to the end rather than leaving it unattended:
   `wiggum watch docs/<name>_plan.md --timeout 1800 --kill-on-timeout`
   `watch` streams the run's output and blocks until it ends (your "wait");
   `--timeout`/`--kill-on-timeout` bound a stuck run. Tune the timeout to the plan's
   size. When it returns, summarize what happened (step 5) — don't just leave the
   run finished and silent.
3. **Spot a wedged run early.** Treat the run as spinning (not working) when
   `status` reports `running but appears blocked`, or `watch` returns non-zero —
   under the hood the `.out`/`.log` shows `No progress detected`, `Stalled for ...`,
   or `Validation failed N times`. Read the tail of `docs/<name>.out` to see why,
   let it reach its natural stop (or let `--kill-on-timeout` bound it), then
   remediate in step 4. Don't keep a wedged run alive.
4. **Kill only when needed.** If a run overruns or is wedged and you must stop it,
   use `wiggum kill docs/<name>_plan.md`. This kills only that run's process tree
   (the wiggum process and the `claude` it spawned) — never a blanket kill of other
   wiggum/claude processes. Prefer `--kill-on-timeout` on `watch` so you don't have
   to babysit it.

For a quick, small run you may skip backgrounding and just `wiggum execute <plan>`
in the foreground.

### 4. If the run didn't finish `complete` — remediate and re-run

A finished run is not necessarily a done one. Read its stop reason from
`wiggum status <plan>` (`finished: <reason>`) and `docs/<name>_summary.md`. Wiggum
stops for three reasons; handle each differently:

- **`complete`** — 0 tasks remain. Go to Report.
- **`incomplete`** — it hit `--max-iterations` while still making progress; it just
  ran out of budget. The plan is fine. Re-run `wiggum execute <plan>` — phase 1
  reconciles the repo against the plan, then it continues the remaining `[ ]`
  tasks — **with a budget sized to the tasks that are still open** (step 3's
  `open * 2 + 3`), not the same ceiling that just ran out. Between runs, `wiggum
  status <plan>` must show `remaining` going *down*; if it stops dropping, treat it
  as a stall. Reaching `incomplete` at all usually means the launch budget was
  under-sized — fix that at launch next time rather than re-running repeatedly.
- **`stalled`** — no progress for two iterations in a row. Re-running as-is will
  just stall again. **Diagnose, mitigate, then re-run.**

**Diagnose the stall** (don't trust the checkboxes alone):
1. Read the evidence — `docs/<name>_summary.md` ("issues encountered" / "deferred"),
   the tail of `docs/<name>.out` and `.log` (the `No progress detected` /
   `Validation failed N times` lines), and the still-`[ ]` tasks. Pin down *which*
   task didn't advance and *why*.
2. Spot-check reality vs. the plan:
   - Run the project's own checks: `wiggum check` (runs the `.wiggumrc` verify/autofix
     steps and shows the real failure).
   - `grep` the repo for the files/symbols/APIs the stuck task assumed exist.
   - Confirm whether partial work actually landed — sometimes the work is done and
     only the box is unticked (phase-1 reconcile usually fixes that, but verify).

**Mitigate — match the fix to the cause:**
- *Task too big or vague* → split it into smaller `[ ]` steps, each with a concrete,
  observable `Acceptance:` line.
- *Acceptance can't be met / is ambiguous* → rewrite it to something reachable and
  checkable.
- *Built on a wrong or hallucinated API / assumption* → fix the task after reading
  the real source; correct dependencies or ordering.
- *A `.wiggumrc` verify command is itself wrong* → surface it to the user; **don't**
  edit `.wiggumrc` (it's their config).
- *Genuinely impossible, out of scope, or superseded* → mark the task `[~]` with a
  one-line rationale so wiggum stops re-picking it (its designed escape hatch).
- *Needs access, credentials, an external dependency, or a real product decision* →
  stop and ask the user; you can't resolve it.

Then re-execute. **Bound the loop:** at most ~2–3 remediation cycles. If it stalls
again on the *same* task after a mitigation, stop and hand the user the diagnosis
plus options instead of burning more runs — mirror wiggum's own discipline (it caps
stall and validation retries precisely to avoid runaway).

### 5. Report

When the work is done (or you've stopped to escalate), run `wiggum status <plan>`
once more and report:
- the final stop reason (complete / stalled / incomplete) and how many remediation
  re-runs it took,
- task counts (done / remaining / dropped),
- what the summary file (`docs/<name>_summary.md`) says was done and deferred,
- if you stopped on a stall: the cause you found, the mitigation you tried, and the
  decision you need from the user.

## Chaining workplans

When the work spans several independent plans, run them in sequence:

```
wiggum chain docs/schema_plan.md docs/api_plan.md docs/ui_plan.md
```

`chain` runs `wiggum execute` on each plan in order, each in a fresh session, and
stops at the first plan that fails — so a broken early step doesn't waste effort on
the rest. To supervise a long chain, background it and watch the active plan's
sidecars, or run the plans one at a time with the supervise loop in step 3 so you
can inspect and fix between stages.

## Rules

- **Drive the CLI; don't reimplement it.** Plan/implement/verify/commit are
  wiggum's job. You orchestrate: plan, launch, monitor, wait, unblock, kill, chain.
- **Never ask for confirmation** — just execute.
- **Refer to runs by their plan file** — that's how status/watch/kill find the
  sidecars.
- **Always pass `--max-iterations`, sized to the plan's open checkboxes** (step 3).
  The 3-iteration default is a floor for toy plans, not a budget for a real
  workplan, and under-sizing it turns a working run into a false `incomplete`.
- **Kill scope:** only ever stop the run you started (`wiggum kill <plan>`), never
  a blanket process kill.
- **Don't edit `.wiggumrc`** to make verification pass — it's the user's config. If
  a verify command itself is wrong, surface it.
- **A finished run isn't a done one.** Always check the stop reason: `incomplete`
  → re-run; `stalled` → diagnose and mitigate before re-running (step 4). Never
  re-run a stalled plan unchanged.
- **Remediate, don't loop forever.** Cap re-runs (~2–3) and confirm `remaining` is
  dropping between them; if a task stays stuck after a mitigation, escalate with the
  diagnosis instead of burning more runs.
- **Report honestly:** if it stalled or was killed, say so with the cause from the
  log — don't round an incomplete run up to "done".
