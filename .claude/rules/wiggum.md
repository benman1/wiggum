# Working with wiggum

Wiggum is a self-driving agent loop: from one command it plans, implements,
verifies and commits, unattended. The `/wiggum` skill is the playbook for driving
a run. This file is the part that has to hold whether or not the skill is loaded.

## Reach for the loop, or edit directly

- **Use wiggum** when the change needs the loop: several interdependent steps where
  each has to be verified before the next can be written, or where you cannot
  predict what the verify suite will say until you try.
- **Edit directly** when you can hold the whole change in your head and one run of
  the verify suite settles it — even when it spans several files. Wiggum runs a full
  cycle *per task*: a fresh Claude session, the entire verify waterfall, a commit.
  On a change that is really one edit, that dwarfs the work and fragments it into
  noisy commits. "It's a new feature" is not on its own a reason.
- **Say which of the two you are doing before you start**, in a sentence. "Queue
  these" is an instruction about sequence, not permission to start hand-editing.

## What makes a plan worth running

The plan is the entire input to an unattended run — nobody reads it back to you
before the work happens. Four things it has to carry, and the first is the one
plans skip most:

- **The case for doing it.** Answer *in the plan*: if we ship this, is the product
  or the codebase actually better? A defect gone, a benefit somebody can observe, a
  duplication removed, a boundary made testable. A plan that can't answer it is a
  list of edits looking for a reason — and the loop will build it anyway.
- **The problem it answers, cited.** The issue number, the failing case, the
  research finding. Work with no stated problem can't be checked against one.
- **Real code, by path**, on both sides of anything it integrates, and marked when a
  path is one the plan proposes to *create*. A path cited as existing that doesn't
  is a task resting on a dead premise, and the run will invent something to satisfy
  it.
- **An observable `Acceptance:` per task** — a log line, a row, a passing test, a
  response body. "Looks better" is not acceptance.

## Plans are counted, not read

- Wiggum tracks progress by counting `- [ ]` checkboxes. A task written as a
  heading, as bold text, or as prose is invisible: the run reports `0 tasks` and
  stops.
- `[~]` means **dropped** — decided against, terminal, never re-picked.
- **A task only a person can do must not be an open checkbox.** It makes a finished
  plan look unfinished forever and hands the loop something it cannot act on. Put
  those under their own heading, as a table of what each one is waiting for.
- Before launching, list the recent plans by mtime (`ls -t docs/*_plan.md | head`),
  not by keyword. A plan that supersedes yours rarely shares its vocabulary.

## Launching: size the budget, then chain

- **Always pass `--max-iterations`, sized to the plan's open checkboxes.** One
  iteration is about one task, so a budget under the box count stops the run
  `incomplete` partway through — which reads like a failure and is only a ceiling
  being hit. Count them and launch:

      open=$(grep -c '^ *[-*+] \[ \]' docs/<name>_plan.md)
      wiggum execute docs/<name>_plan.md --background --max-iterations $(( open * 2 + 3 ))

  Iterations are a ceiling, not a target: wiggum stops as soon as the boxes are
  done, and trips its own stall detection long before it burns a big budget. An
  over-generous ceiling costs nothing; a tight one reliably costs a re-run. A flaky
  suite is **not** a reason to raise it — failing verify steps spend
  `max_validation_retries`, a separate budget.
- **Chain plans, don't run them concurrently.** `wiggum chain a.md b.md` gates each
  on the previous finishing. Two verify suites on one box is how a two-minute run
  becomes an hour.
- **To append to a chain that is already running, chain from a queue file.**
  `wiggum chain --queue docs/queue.txt` re-reads the file after every plan, so
  `echo docs/extra_plan.md >> docs/queue.txt` mid-run is picked up when the current
  plan finishes. With plans as arguments the list is fixed at launch. A queue also
  survives a kill — rerun the same command.

## Watching one

- **`wiggum top`** — every run on this machine, one line each: state, task tally,
  and ACTIVITY, the age of the run's newest write. That last column is what
  separates a long task from a wedged one; both of them say `running`.
- **`wiggum status <plan>`** — the counts for one run. It counts checkboxes, so
  `remaining` climbs when you *edit* the plan, not when the run regresses.
- **`wiggum watch <plan>`** — stream one run and block until it ends. Exits 0 only
  on `complete`.
- **`wiggum watch --chain [pid]`** — follow a *chain* across plans. Watching a
  chained plan by name exits 1 immediately, because a plan whose turn hasn't come
  has no pidfile; that reads as "finished" and means "not started".
- **A finished run is not a done run — read the stop reason.** `complete` → done.
  `incomplete` → out of iterations, re-run it. `stalled` → no progress for two
  iterations running; diagnose first or it stalls identically. `aborted` → the
  session died, which is infrastructure, not the plan.
- **After an abort, check the tree before relaunching.** A killed session can leave
  half-finished work that contradicts a guard it just wrote. Get back to the last
  green commit and relaunch from there; wiggum's phase 1 reconciles and redoes the
  task.
- **Don't drive interactive work in the same repo while a run is live**, and tear
  your watch down when the run ends.
- **Never change the machine's sleep or power settings to protect a run** — no
  `caffeinate`, no `pmset`, not "just while this finishes". A run that dies to sleep
  is recoverable: phase 1 reconciles and the finished commits survive. The setting
  is global, it outlives the run, and it is the machine owner's call.

## The verify suite is the contract

- **Read which verify step actually failed before trimming the waterfall.**
  `.wiggumrc` is the user's config, not yours to edit; a trimmed verify is a loan.
- **A run is unattended, and automation gets no exemption.** A task that says "add a
  migration" applies it for real, against whatever the environment points at.
  Isolate anything destructive before queueing the plan, not after.
