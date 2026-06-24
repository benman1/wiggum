---
name: wiggum
description: Orchestrate the wiggum CLI — create a workplan, run it, monitor it, wait for it, detect when it's blocked, kill it if it runs too long, and chain workplans together
disable-model-invocation: true
argument-hint: <issue, plan file, or "chain: plan-a.md plan-b.md">
---

# Wiggum: Orchestrator

You **drive the `wiggum` CLI** — you do not re-implement its loop yourself. Wiggum
is a self-driving agent loop (plan → implement → verify → commit). Your job is to
turn the request into a workplan, launch wiggum on it, supervise the run, and
report the outcome. Execute without asking for confirmation.

The request: **$ARGUMENTS**

## Prerequisites

`wiggum` must be on `PATH`. Check once with `command -v wiggum`.

- If it's missing, tell the user to install it (`./install.sh` in the wiggum repo)
  and stop — do not hand-simulate the loop.
- Run from the target project root. A `.wiggumrc` there defines the verify/autofix
  steps; if there is none, wiggum skips verification (still fine).
- **Activate the project's environment first.** wiggum runs Claude's tools and the
  `.wiggumrc` verify steps in your *current* shell environment. If the repo uses one
  — conda (`environment.yml`), a virtualenv/`.venv`, Poetry/uv (`poetry.lock`/
  `uv.lock`), a Node version (`.nvmrc`), Bundler (`Gemfile`), etc. — detect it and
  activate it in the same shell you launch wiggum from, *before* running, or
  tests/builds run against the wrong interpreter and fail spuriously. For
  unattended/background runs, prefer making the `.wiggumrc` verify commands
  self-activating (e.g. `conda run -n <env> pytest`, `poetry run pytest`) so the run
  is reproducible no matter which shell starts it.

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

Sidecar files live next to the plan: `docs/<name>.pid`, `docs/<name>.out`,
`docs/<name>.log`. `status`/`watch`/`kill` all derive these from the plan path,
so always refer to a run by its **plan file**.

## Workflow

### 1. Classify the request

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

## Phase 1: <name>
- [ ] <discrete task>
  Acceptance: <observable outcome — a passing test, a specific log line, a file
  that exists, a command that exits 0>. Never a feeling ("works", "looks right").
  Files: <best-effort paths this task creates or modifies>
- [ ] <next task>
  Acceptance: ...
  Files: ...
```

Rules for a good plan:
- Every task is one `- [ ]` line (GFM `*`/`+` bullets also count) with its own
  **Acceptance:** and **Files:** lines. A task without observable acceptance is a
  wish, not a step.
- `[x]` = done, `[ ]` = pending, `[~]` = dropped (terminal — wiggum won't re-pick
  it). Record why on the `[~]` line.
- Before finalizing, confirm the APIs/commands the plan assumes actually exist
  (grep the repo). Don't plan around a hallucinated API.
- Keep plans focused. Very large plans (40+ tasks) tend to stall — split them and
  `chain` instead.

Confirm the plan looks right, then continue.

### 3. Execute and supervise

Launch detached so you can monitor and bound it:

```
wiggum execute docs/<name>_plan.md --background
```

Then supervise in a loop until it finishes:

1. `wiggum status docs/<name>_plan.md` — read **State** and the task counts.
2. While **State** is `running`, keep watching:
   `wiggum watch docs/<name>_plan.md --timeout 1800 --kill-on-timeout`
   `watch` blocks until the run ends (your "wait"); `--timeout`/`--kill-on-timeout`
   bound a stuck run. Tune the timeout to the plan's size.
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
  tasks — optionally with a higher `--max-iterations`. Between runs, `wiggum status
  <plan>` must show `remaining` going *down*; if it stops dropping, treat it as a
  stall.
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
