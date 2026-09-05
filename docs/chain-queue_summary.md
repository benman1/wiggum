# Chain from a queue file, and two bugs in `top`

Status: done
Slug: chain-queue
Target files: `lib/wiggum.sh`, `wiggum.sh`, `test/wiggum.bats`, `README.md`, `completions/`

Written after the fact rather than planned up front: both changes came out of a
supervision session where `wiggum top` gave two people the wrong answer about
whether a run was alive.

## 1. `wiggum chain --queue <file>`

**Why.** `run_chain` iterates `FILES`, captured by `parse_args` at launch. The
list lives in that process's memory, so there is no way to add a plan to a chain
that is already running: you wait for it to finish, then start a second chain.
That is the wrong shape for how chains actually get used, which is "here are
three plans, and I will think of a fourth while you work".

**What it does.** `--queue` reads the plan list from a file and re-reads it
after every plan. A line appended while the chain works is picked up when the
current plan finishes. One path per line, `#` starts a comment, blanks ignored.

**The decisions worth recording:**

- **Already-run plans are tracked in memory, not by editing the file.**
  `run_chain_queue` keeps a `done_list` and skips anything in it. So a person can
  reorder or delete lines mid-chain without causing a repeat, and the queue file
  stays theirs to edit. The cost is that the done-set dies with the process: a
  resumed chain re-reads the whole file and re-runs finished plans. That is
  tolerable because phase 1 reconciles a finished plan against the repo and stops
  early, but it is the obvious thing to revisit if resume becomes common.
- **A queued path that does not exist stops the chain.** Skipping it would leave
  work undone with nothing saying so, and the likeliest cause is a typo. Failing
  loudly costs one re-run; skipping silently costs a wrong belief about what
  shipped.
- **`--queue` and positional plans are mutually exclusive**, refused in
  `parse_args`. Accepting both raises a question with no good answer (which order?
  does the queue extend the arguments?) that nobody needs asked.
- **An empty queue succeeds** and says so. It is a normal state for a queue that
  has been drained, not an error.

**Not built:** no locking. Two chains reading one queue would both run every
plan. A lock would need to survive a kill, and a second chain on the same queue
is a mistake worth making visible rather than a case worth supporting.

## 2. `wiggum top` printed a truncated list and exited 1

**The bug.** `read_run_status` pipes `grep -E '^Status: '` over a run's `.out`.
`grep` exits 1 when a run recorded no status, `pipefail` propagates it, the
command substitution fails, and `set -e` kills `run_top` part-way down its list.
`current_run_slice` had the same pattern for a `.out` with no run separator.

A run with no `Status:` line is ordinary: it is still going, or it was killed
before it could write one. In a directory with sixteen runs, one such file made
`top` print ten rows and stop.

**Why it mattered more than it looks.** The output is a table with no error on
it. A truncated table reads as a complete one, and nobody checks `$?` on `top`.
In the session that found this, two people concluded a live run was not running,
and reached for a plausible but wrong explanation (that foreground runs write no
pidfile, which stopped being true when `claim_run_pidfile` landed). The tool was
lying in the direction that gets more work launched onto a loaded machine.

**Fix.** `|| true` on both pipelines, with the reason in a comment so nobody
"tidies" it away. Two regression tests pin the exit code and the empty output;
a third builds the exact directory that used to truncate and asserts the row
after the failing one still prints.

## 3. `top` now sorts by state

Rows were alphabetical, so one running job sat below a dozen finished ones. That
is the opposite of what `top` is for. `top_row` now emits a rank (blocked,
running, scheduled, everything else) that `run_top` sorts on and strips, with
`sort -s` keeping alphabetical order inside each group.

## What is still not right

- `wiggum top` shows finished runs from the current directory alongside live
  ones from anywhere. Sorting makes that readable, but a `--running` flag that
  hides the history would be closer to what `top` does.
- A chain still has no identity of its own in `top`. It shows as a row for the
  plan it is on, which is honest but does not say "this is plan 2 of 5 in a
  chain". The queue file is the obvious place to read that from.
