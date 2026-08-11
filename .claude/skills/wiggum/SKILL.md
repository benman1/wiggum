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
- **Tie a claim to its artifact.** When tasks write a report, a status table, or a
  changelog *about* something they produce, add a guard asserting the record matches
  reality — a row claiming a trained model names a checkpoint that exists on disk, a
  row marked done names a real output. Agents fill in a row optimistically before the
  work behind it finishes, and a plausible false record is worse than a missing one.
  In a real run this guard is what stopped a report claiming a model was trained
  while its training was still running.
- **A parity claim must be tested against the pre-change code.** When a task's
  acceptance is "behaviour is unchanged when the switch is off", a test comparing the
  new code's two paths to each other proves only internal consistency: a diff that
  removes lines can pass it while having moved the baseline. Say in the task that the
  comparison is against the previous commit — extract the old file
  (`git show <ref>:<path>`) and compare outputs, or pin a digest computed on the
  clean tree. Prefer pinning a digest over pure inputs (a transform, a parser); for
  anything whose output depends on the BLAS library or thread count, such as trained
  weights, a pinned digest is flaky and the old-vs-new comparison is a one-time
  migration check instead.
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

### 3a. Runs longer than your own session: launch durably

`--background` daemonizes inside the **calling shell's session**. That survives you
closing a pipe; it does *not* survive the session itself being destroyed — a
terminal restart, the agent session ending, the supervising process exiting. When
that happens the whole tree goes with it, and the signature is a clean `.out`
ending mid-phase: no error, no summary file. Don't go hunting for a bug in the
plan; it was killed from outside. `nohup … &` buys immunity to SIGHUP only, so it
delays this rather than fixing it.

For any run you expect to outlive your own session, launch it inside a detached
multiplexer instead:

```
screen -dmS wig1 bash -lc 'source "$(conda info --base)/etc/profile.d/conda.sh"; \
  conda activate <env>; \
  exec wiggum execute docs/<name>_plan.md --max-iterations N >> docs/<name>_plan.out 2>&1'
```

Run wiggum in the **foreground inside** the multiplexer — no `--background`. The
multiplexer supplies the durability, and a daemonizing child would let its session
exit immediately and take the tree down. `tmux new -d -s wig1 '<same>'` works
identically; macOS has `screen` at `/usr/bin/screen` and no `setsid`.

The cost: a foreground run writes no `.pid`, so `wiggum status` can't find it and a
`kill -0 $(cat <plan>.pid)` liveness check reports "gone" when the file is merely
absent — indistinguishable from a real death. Check liveness with `screen -ls` and
`pgrep -f "wiggum execute docs/<name>_plan"` instead. Task counts still work,
because `wiggum status` reads the plan's checkboxes.

**Verify survival before believing any launch pattern.** Every one of these failure
modes looks healthy at the five-minute mark. Don't record a pattern as working
until it has outlived at least one session teardown.

### 3b. Tasks that outlast an iteration

An iteration completes roughly one task, so a task whose work takes longer than an
iteration — training a model, a long build, a big migration — will not flip its
checkbox inside that iteration. Wiggum scores the iteration as no progress, and two
of those in a row stop the run while the real work is still going.

Handle it from both sides:

- **In the plan:** a long-running task should launch its job into its own detached
  session and record the artifact path in its `Acceptance:`. A later iteration then
  observes the finished artifact instead of restarting an hour of work. Say so in
  the task, so the implementing agent doesn't run it inline.
- **As supervisor:** never treat `No progress detected` as a stall before checking
  whether such a job is alive (next section).

### 3c. Reading the sidecars without fooling yourself

`.out` is opened in **append** mode, so it accumulates every run's history. Two
traps follow, and both bit a real supervision session:

- A grep over the whole file matches a stall line from a *dead* run and reports it
  as current.
- A monitor that dedupes by message text records that string once, then goes
  **deaf** to the next genuine occurrence of it.

Baseline the match count before you launch and report only the increase, with line
numbers so you can tell which run a hit belongs to:

```
prevn=$(grep -cE 'No progress detected|RUN ABORTED' docs/<name>_plan.out)
```

Filtering to "just this run" has its own trap: if the new run hasn't flushed its
`=== WIGGUM EXECUTE MODE ===` banner yet, a check that scans only after the last
banner finds an empty section, and "no stalls in this run" is then trivially true.
Count the banners before trusting that conclusion.

`.log` is the timing record: its `phase2-validate-N-fix-M` entries give wall clock
per phase, which is how you find out where a run actually spent its time.

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

**First, rule out a false stall.** A stall means *wiggum* saw no checkbox move, not
that nothing is happening. Before diagnosing anything, check whether work is
progressing outside the iteration window:

- `pgrep -f "<the long command the task launches>"` and `screen -ls` / `tmux ls` —
  is the job the task spawned still alive?
- Is its output still growing? Cache directory size, an output file's mtime, a
  checkpoint appearing. Take two readings a minute apart rather than one.

If something is running, **do nothing**: let it finish, then relaunch. Phase 1
reconciles the repo against the plan and marks the task done from the artifact
instead of redoing the work. Killing the run here is safe (the detached job
survives); relaunching *before* the job finishes is not useful, because the same
task will fail its acceptance the same way.

Only when nothing is running is it a real stall:

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

**Check the machine before blaming the plan.** wiggum runs Claude, the verify
steps, and anything a task spawns — concurrently with any *other* wiggum run on the
box. Read `uptime`'s load average against the core count (`sysctl -n hw.ncpu` /
`nproc`). A load many times the core count makes every verify pass several times
slower, turns a working run into one that looks wedged, and makes the supervising
session itself a candidate for being reaped. Two concurrent runs plus a training job
on a 4-core machine reached load 59 in a real session. Serialising two runs finishes
both sooner than interleaving them; if the other run isn't yours to stop, say so
rather than quietly competing with it.

**The verify tax is often the real cost.** `verify`/`autofix` run over the **whole
repo** after every task and again after **each** fix attempt (up to
`max_validation_retries`, default 5). On a large suite that dominates everything
else: measure one pass from `.log` before concluding the task's own work is slow. A
single real session spent 27 minutes on one round's three fix attempts and 40 on the
next round's one.

If that tax is the bottleneck, `--no-verify` is a **CLI flag** — use it instead of
editing `.wiggumrc`, which is the user's config. It is a real reduction in safety,
so when you spend it: say what you traded, run the specific tests that guard the
work after each task yourself, and run the full suite once before calling the work
done. Report what that final run found rather than fixing quietly and claiming a
clean finish.

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
- **Launch durably for anything long** (step 3a): `--background` dies with the
  session that started it. Use a detached `screen`/`tmux` with wiggum in the
  foreground inside it, and check liveness with `pgrep`, not the `.pid` file.
- **Rule out a false stall before remediating** (step 4): if a job the task spawned
  is still alive and its output still growing, wait and relaunch — don't rewrite a
  task that was working.
- **Read the sidecars as append-only history** (step 3c): baseline your grep counts,
  or you will report a dead run's stall as current and then miss the live one.
- **Don't trust a green report over the artifact.** Read the numbers an agent writes
  into a report against the files that produced them; check that a "parity" or
  "unchanged" claim was tested against the previous commit and not against the new
  code's own second path.
- **Report honestly:** if it stalled or was killed, say so with the cause from the
  log — don't round an incomplete run up to "done". The same applies to your own
  supervision: if you turned off verification or skipped a check, say which.
