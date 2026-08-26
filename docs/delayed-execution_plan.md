# Delayed execution: `wiggum execute --at <WHEN>`

Status: in progress
Slug: delayed-execution
Target files:
- lib/wiggum.sh
- README.md
- completions/wiggum.bash
- completions/wiggum.zsh
- test/wiggum.bats

## Motivation

There is no way to say "run this plan at 1am". The two things that exist solve a
different problem: `examples/wiggum-cron.sh` and
`examples/wiggum-nightly-setup.sh` set up **recurring** runs through cron or a
LaunchAgent, and their own comments enumerate why that path is awkward
(`examples/wiggum-cron.sh:6-13`): cron gives a bare `PATH`, the interactive
`claude` login lives in the macOS Keychain where cron cannot read it, so a key
has to be supplied by hand, and macOS may demand Full Disk Access for
`/usr/sbin/cron`.

A run launched from the user's own interactive shell has none of those problems.
It inherits `PATH`, the environment, and the Keychain-backed auth. All that is
missing is the waiting.

The immediate case: a 32-task plan on a machine the user does not want to tie up
during the day, started at 01:07 tonight, once. Setting up a LaunchAgent for that
means writing a plist, remembering `StartCalendarInterval` is **recurring**, and
hand-rolling a wrapper that removes itself afterwards. `--at 01:07` should do it.

## Constraints

- In scope: a `--at <WHEN>` option on `wiggum execute` that waits until a wall-clock
  time and then runs exactly once, detached; `status` and `kill` understanding a
  scheduled-but-not-yet-started run; documentation in `--help`, the README, and both
  completion files.
- Out of scope: recurring schedules, which cron and launchd already do better and
  which the two example scripts already cover. `wiggum chain --at` (the flag is
  accepted on `execute` only in this plan; chain can follow once the shape is
  proven). Any change to how the loop itself runs once started.
- Never do: keep the machine awake. No `caffeinate`, no `pmset`, no keep-alive
  wrapper, not for the duration of the wait and not for the run. Whether the
  machine sleeps is the user's decision about their own hardware, and a tool
  asserting otherwise from a shell takes it silently. Document the interaction
  instead. Never write a recurring artifact (crontab line, LaunchAgent plist) as a
  side effect of `--at`: one invocation, one run.

## Design decisions taken before the phases

**`--at` implies detachment.** Waiting six hours in the foreground blocks the
terminal for no benefit, so `--at` hands off the same way `--background` does
(`launch_execute_background`, `lib/wiggum.sh:~2860`). Passing both is allowed and
`--background` is redundant rather than an error.

**Poll the clock; do not `sleep` the whole interval.** A single long `sleep` is
suspended while the machine sleeps and resumes afterwards, so it fires late by
roughly the suspend duration. A loop that re-reads the wall clock
(`while [ "$(date +%s)" -lt "$target" ]; do sleep 30; done`) self-corrects across
suspend and is the only version that is correct on a laptop.

**Do not write a date parser. Choose a syntax that does not need one.** The
first draft of this plan had a `date_flavour()` probe branching between BSD
`date -j -f` and GNU `date -d`, because those are the only ways to turn a
calendar string into an epoch and neither accepts the other's syntax. That whole
problem comes from one of the three accepted forms. Drop it and the rest is
arithmetic:

| form | how it resolves | prior art |
|---|---|---|
| `+90m`, `+6h`, `+2d` | `now + N × unit` | `sleep` and `at` durations |
| `01:07` | seconds-to-midnight arithmetic on `%H`, `%M`, `%S`; rolls to tomorrow when the time has passed | `at 01:07` |
| `@1756180020` | used as-is | GNU `date` and systemd both take `@epoch` |

`date +%s`, `date +%H`, `date +%M` and `date +%S` take no flags and behave
identically on BSD, GNU and busybox, so there is no branch and no probe. The
`@epoch` form is the escape hatch for anybody who wants a specific calendar date:
they produce the epoch with whatever their platform gives them (`date -d`,
`gdate`, python) and hand it over, which keeps platform-specific date parsing
outside wiggum entirely.

Prototyped against a fixed clock of 2026-08-25 22:00 before writing this:
`+90m`→23:30 same day, `+6h`→04:00 next day, `+2d`→22:00 two days on,
`01:07`→next day, `23:30`→same day, `22:00`→next day (a time equal to now means
tomorrow), and `25:00`, `1am`, `tomorrow` and the empty string all rejected.

**Read the clock through two stubbable accessors.** `wiggum_now_epoch()` is
`date +%s` and `wiggum_now_hms()` is `date +%H:%M:%S`. Tests override those two
functions to inject a clock, which is why the production path needs no
`date -r`/`-d`/`-j` at all. Overriding a function is already how `test/wiggum.bats`
stubs `claude` (`test/wiggum.bats:19-21`).

**One accepted inaccuracy: DST.** `HH:MM` resolves to "now plus the number of
seconds until that clock time", so on the two nights a year when a transition
falls inside the wait, the run starts an hour early or late. Handling it properly
requires the calendar parsing this design exists to avoid. Document it in the
README rather than branching for it.

**A scheduled run needs its own sidecar.** Writing the pidfile at schedule time
would make `wiggum status` report a run as active while it is only sleeping, and
`wiggum watch` would attach to a process producing no output for hours. A separate
`.scheduled` file, via the existing `run_sidecar_file "$base" scheduled`, keeps
the two states distinguishable.

## Phase 1: Resolve `<WHEN>` with arithmetic, not a parser

- [x] Add `wiggum_now_epoch()` (`date +%s`) and `wiggum_now_hms()` (`date +%H:%M:%S`) to `lib/wiggum.sh`. Two lines each, no flags, so the same code runs on BSD, GNU and busybox `date`. They exist to be overridden by tests, the way `claude` already is at `test/wiggum.bats:19-21`.
  Acceptance: `bats test/wiggum.bats -f wiggum_now` passes, asserting each returns the expected shape and that overriding them in a test changes what a caller sees.
  Files: lib/wiggum.sh, test/wiggum.bats
- [ ] Add `parse_at_time <spec>` writing an epoch to stdout, non-zero on anything it does not recognise. Accept exactly `+<N>[m|h|d]`, `HH:MM` and `@<epoch>`, using only the two accessors and shell arithmetic. Force base 10 on the hour and minute (`10#`), or `08` and `09` are parsed as invalid octal under `set -e` and the whole run dies on a valid input.
  Acceptance: `bats test/wiggum.bats -f parse_at_time` passes with the eleven cases prototyped in the design note above, including `08:30` and `09:00` resolving correctly, and `25:00`, `1am`, `tomorrow`, `+5x` and the empty string each returning non-zero with nothing on stdout.
  Files: lib/wiggum.sh, test/wiggum.bats
  Depends on: previous task

### Acceptance Criteria
**Happy Path** — Given `01:07` at 22:00, When resolved, Then the epoch is 01:07 the following day.
**Edge Cases** — A time later today versus earlier today. A time exactly equal to now, which means tomorrow. Midnight rollover. `08:30` and `09:00`, which are the octal trap. `+2d` crossing a month end. `@<epoch>` in the past, which resolves rather than erroring so the caller can report it as past.
**Error States** — Unrecognised specs return non-zero and write nothing to stdout, so a caller substituting the output cannot silently get an empty string.
**Non-Functional** — `shellcheck -s bash lib/wiggum.sh` passes with zero warnings. No `date` invocation anywhere in the path uses a flag beyond `+FORMAT`, verified by the guard in Phase 5.

## Phase 2: Wait, then run once

- [ ] Add `--at <WHEN>` to the `execute` branch of the argument parser, beside `-b|--background` (`lib/wiggum.sh:649`) and `--iterations|--max-iterations` (`:593`). Store it in an `AT_TIME` global cleared by `wiggum_reset()`. A missing value must error rather than swallow the next argument.
  Acceptance: `bats test/wiggum.bats -f "parse_args: --at"` passes, including `--at` with no value exiting `EXIT_BAD_ARGS`. This test fails on the current commit, where `--at` is an unknown flag.
  Files: lib/wiggum.sh, test/wiggum.bats
  Depends on: Phase 1
- [ ] Add `launch_execute_delayed()`, modelled on `launch_execute_background()`. It refuses when a live run already holds the pidfile (same check, same message shape), refuses a target time in the past with `EXIT_BAD_ARGS`, writes a `.scheduled` sidecar containing the target epoch, the human-readable target time and the waiter's pid, and prints what was scheduled along with the `status` and `kill` commands to manage it.
  Acceptance: a bats test with a stubbed clock asserts the sidecar is created with the right epoch, that a past time exits `EXIT_BAD_ARGS` and writes no sidecar, and that a live pidfile blocks scheduling.
  Files: lib/wiggum.sh, test/wiggum.bats
  Depends on: previous task
- [ ] Detach the waiter. Prefer `screen -dmS wiggum-<slug>`; fall back to `nohup` with a subshell when `screen` is absent. Do not use `setsid`, which macOS does not have (the skill text embedded at `lib/wiggum.sh:~1660` already records this). The waiter polls the wall clock in a loop rather than sleeping the whole interval, then clears the `.scheduled` file and calls `run_execute` with `BACKGROUND=false`, writing the pidfile and the run separator exactly as the background launcher does.
  Acceptance: an integration test schedules a run two seconds out with `claude` stubbed, waits, and asserts the `.scheduled` file is gone, the pidfile appeared, and the `.out` file gained one run separator.
  Files: lib/wiggum.sh, test/wiggum.bats
  Depends on: previous task
- [ ] Make `--at` and `--background` compose without surprise: `--at` always detaches, and `--background` alongside it is accepted and ignored rather than rejected. Say so in one line of output so nobody wonders which won.
  Acceptance: a test passing both asserts exit 0, one `.scheduled` sidecar, and no second detached process.
  Files: lib/wiggum.sh, test/wiggum.bats
  Depends on: previous task

### Acceptance Criteria
**Happy Path** — Given `wiggum execute plan.md --at 01:07`, When the clock reaches 01:07, Then the plan runs exactly once, detached, with output appended to `docs/<name>.out` behind a run separator.
**Edge Cases** — Scheduling a time two seconds away. Both `--at` and `--background`. A plan whose sidecars do not yet exist. A second `--at` while one is already scheduled, which must be refused rather than silently queueing two runs.
**Error States** — A past time exits `EXIT_BAD_ARGS` and writes no sidecar. An unparseable time exits `EXIT_BAD_ARGS` with a message naming the three accepted forms. A live run blocks scheduling with the same message shape as `--background`.
**Non-Functional** — Exactly one run results; nothing recurring is created anywhere on the system. `shellcheck` passes with zero warnings. The waiter holds no wake lock.

## Phase 3: `status` and `kill` know about a scheduled run

- [ ] Teach `run_status` to read the `.scheduled` sidecar and report `State: scheduled for <time> (in <duration>)` when a run is waiting, keeping the existing task counts alongside it. A scheduled run must never read as `running`, because the distinction is what tells somebody whether to expect output.
  Acceptance: a bats test writes a `.scheduled` sidecar and asserts `status` prints `scheduled` and the target time, and that with no sidecar the existing states are unchanged.
  Files: lib/wiggum.sh, test/wiggum.bats
  Depends on: Phase 2
- [ ] Teach `run_kill` to cancel a scheduled run: kill the waiter by the pid in the sidecar, remove the sidecar, and say it cancelled a schedule rather than stopped a run. Killing only that pid, never a pattern match, per the existing `process_alive` discipline (`lib/wiggum.sh:2793`).
  Acceptance: a test schedules a run far in the future, kills it, and asserts the waiter is gone, the sidecar is gone, no pidfile was created, and the message says cancelled.
  Files: lib/wiggum.sh, test/wiggum.bats
  Depends on: previous task
- [ ] Make a stale `.scheduled` sidecar self-healing: if the pid it names is not alive and its target time has passed, `status` reports the schedule as missed rather than pending, and any new `--at` for that plan is allowed rather than blocked. A machine that was off at 01:07 is the ordinary case, not an error state.
  Acceptance: a test writes a sidecar with a dead pid and a past target, then asserts `status` says missed and a fresh `--at` succeeds.
  Files: lib/wiggum.sh, test/wiggum.bats
  Depends on: previous task

### Acceptance Criteria
**Happy Path** — Given a scheduled run, When `status` is called, Then it reports `scheduled` with the target time; When `kill` is called, Then the schedule is cancelled and nothing runs.
**Edge Cases** — A sidecar whose pid died. A target time already past. Both a `.scheduled` and a `.pid` present, which means the run started between the two reads and the pidfile wins.
**Error States** — A malformed or truncated sidecar is reported as unreadable and does not crash `status`. `kill` on a plan with neither sidecar reports nothing to do and exits 0.
**Non-Functional** — `kill` targets one pid from the sidecar and never a `pgrep -f` pattern, which the embedded skill text at `lib/wiggum.sh:~1671` explains can error or truncate.

## Phase 4: Document it in all four places

- [ ] Add `--at <WHEN>` to the `execute` block of `usage()` (`lib/wiggum.sh:283-320`, beside `-b, --background` at `:296`), naming the three accepted forms (`+90m`, `01:07`, `@<epoch>`) and stating that it implies detachment and runs once.
  Acceptance: `wiggum execute --help` shows the flag and the three forms; `wiggum --help` still exits 0.
  Files: lib/wiggum.sh
  Depends on: Phase 3
- [ ] Add a `### Delayed runs` section to `README.md` next to `### Background runs & supervision` (`README.md:304`). Cover the three time forms with an example of each, why there is no calendar-date form and that `@<epoch>` is the escape hatch, the DST caveat on `HH:MM`, that it runs once and creates nothing recurring, how `status` and `kill` behave, and the sleep interaction: on a laptop that sleeps, the wait resumes on wake and the run starts late, and wiggum will not keep the machine awake for you because that is your call. Point at `examples/wiggum-nightly-setup.sh` for genuinely recurring schedules.
  Acceptance: the section exists, names the three forms, states the run-once guarantee, and says wiggum does not prevent sleep.
  Files: README.md
  Depends on: previous task
- [ ] Add `--at` to both completion files: the `execute` option list in `completions/wiggum.bash:76` and the zsh equivalent. Give it no value completion, since a time is free text.
  Acceptance: `grep -c -- '--at' completions/wiggum.bash completions/wiggum.zsh` returns at least 1 for each.
  Files: completions/wiggum.bash, completions/wiggum.zsh
  Depends on: previous task
- [ ] Update the CLI reference table embedded in the skill text at `lib/wiggum.sh:1364-1369`, which lists `wiggum execute <plan> --background` and is what an agent reads when driving wiggum. A flag documented in `--help` but absent there is a flag agents will not use.
  Acceptance: the table has a `--at` row; `grep -n 'at <WHEN>' lib/wiggum.sh` returns both the usage entry and the table row.
  Files: lib/wiggum.sh
  Depends on: previous task

### Acceptance Criteria
**Happy Path** — Given `wiggum execute --help`, When read, Then `--at` appears with its three forms. Given the README, When a reader looks for delayed runs, Then a section explains it.
**Edge Cases** — `wiggum --help` and `wiggum execute --help` both still exit 0 with the added text.
**Error States** — The error message for an unparseable time names the same three forms the help text does, so the two cannot drift into describing different syntaxes.
**Non-Functional** — README prose matches the repo's existing voice. No line in `usage()` exceeds the width of its neighbours.

## Phase 5: Guards against the documentation drifting

- [ ] Add a bats test asserting `--at` appears in all four documentation surfaces: `usage()`, `README.md`, both completion files, and the embedded skill table. This is the first doc-sync guard in this repo (`grep -n "README" test/wiggum.bats` currently finds only `--update-docs` argument tests), so write it as a small reusable helper that takes a flag name, and use it for `--at`.
  Acceptance: passes on the tree at the end of Phase 4; fails when `--at` is removed from any one of the four.
  Files: test/wiggum.bats
  Depends on: Phase 4
- [ ] Add a bats test asserting nothing in the `--at` code path invokes `caffeinate`, `pmset`, `crontab` or `launchctl`. The first two would take a decision about the user's hardware that is not wiggum's to take; the second two would make a one-shot flag leave recurring state behind. Both are stated in Constraints and neither is otherwise enforced.
  Acceptance: a source-reading test over `lib/wiggum.sh` passes now and fails when any of those four commands is added.
  Files: test/wiggum.bats
  Depends on: previous task
- [ ] Add a bats test asserting no `date` call in the `--at` code path uses a flag other than `+FORMAT`. `date -d` is GNU-only, `date -j` and `date -r <epoch>` are BSD-only, and a well-meaning later edit reaching for one of them would break the other platform silently, since this repo's CI runs on one of them at a time. This is the invariant the whole design rests on.
  Acceptance: passes on the current tree; fails when `date -d` or `date -j` is added to `parse_at_time` or the waiter.
  Files: test/wiggum.bats
  Depends on: previous task
- [ ] Run the full verify waterfall and fix anything this plan broke.
  Acceptance: `shellcheck -s bash wiggum.sh lib/wiggum.sh install.sh` and `bats test/wiggum.bats` both exit 0, with the test count no lower than the 437 present before this plan plus the tests it adds.
  Files: (whatever the run surfaces)
  Depends on: all previous tasks

### Acceptance Criteria
**Happy Path** — Both guards pass on a clean tree on their first run.
**Edge Cases** — Each guard fails when its defect is reintroduced; verify by making the change, running the guard, and reverting.
**Error States** — A guard that cannot find a file it inspects fails loudly rather than passing vacuously.
**Non-Functional** — Both are pure source-reading tests with no clock, no network and no detached process, so they cannot flake.

## Sequencing — what can ship independently

- **Phase 1** ships independently. Two new pure functions that nothing calls yet change no behaviour, and having them tested against injected clocks before anything depends on them is what keeps the rest cheap.
- **Phase 2** needs Phase 1 and is the first phase that changes what the CLI does. It is additive: without `--at` on the command line, every existing path is untouched.
- **Phase 3** needs Phase 2's sidecar to exist before `status` and `kill` can read it. It can ship a release later than Phase 2 without breaking anything; the cost of the gap is that a scheduled run is invisible to `status`, which is confusing rather than harmful.
- **Phase 4** needs the flag to exist. It could ship with Phase 2, but shipping it after Phase 3 means the README can describe `status` and `kill` behaviour rather than promising it.
- **Phase 5** ships last, since both guards read text Phase 4 writes.

**Risk gates.** Gate 1 (measure before acting) is **not triggered**: no claim here
rests on production data or runtime state. Gate 2 (activating never-run code is
not a no-op) applies weakly and is discharged by Phase 2's integration test
scheduling two seconds out, which exercises the whole waiter path before anybody
relies on a six-hour one. Gate 3 (irreversible work) is **not triggered**:
nothing here writes to a database, deletes anything, or touches state outside the
plan's own sidecar files. Gate 4 (a new guard must pass on a clean tree) applies
to both Phase 5 guards; the legitimate exception to enumerate up front is that
`examples/wiggum-cron.sh` and `examples/wiggum-nightly-setup.sh` legitimately
mention `crontab` and `launchctl`, so the second guard reads `lib/wiggum.sh` only
and must not be widened to the examples directory.

**A note for the implementing agent on test placement.** `test/wiggum.bats` stubs
`claude` globally in `setup()` (`test/wiggum.bats:19-21`) and gives each test an
isolated `mktemp -d`. That suits every test in this plan: the integration test in
Phase 2 wants `claude` stubbed, and the sidecar tests want a fresh directory. No
new test file is needed and no existing stub should be weakened. The one thing to
watch is that the Phase 2 integration test must not leave a detached waiter behind
when it fails; kill it in the test body rather than relying on `teardown`.

## References

- `examples/wiggum-cron.sh:6-13` — why cron is awkward for this: bare `PATH`, Keychain auth not readable, Full Disk Access on macOS.
- `examples/wiggum-nightly-setup.sh` — the existing recurring-schedule path, and the per-platform branching precedent this plan follows.
- `lib/wiggum.sh:283-320` — the `execute` usage block, and `-b, --background` at `:296`.
- `lib/wiggum.sh:593,649` — where `--max-iterations` and `--background` are parsed.
- `lib/wiggum.sh:~2860` `launch_execute_background()` — the hand-off shape to copy: pidfile collision check, `BACKGROUND=false`, run separator written synchronously, append rather than truncate.
- `lib/wiggum.sh:2793` `process_alive()` — `kill -0`, the liveness primitive to reuse.
- `lib/wiggum.sh:2833` `release_pidfile()` — releases only when the file still names the expected pid.
- `lib/wiggum.sh:1364-1369` — the CLI reference table in the embedded skill text.
- `lib/wiggum.sh:~1660,~1671` — the existing notes that macOS has `screen` but no `setsid`, and that pattern-matching liveness with `pgrep -f` can error or truncate.
- `README.md:304` — `### Background runs & supervision`, where the new section belongs.
- `completions/wiggum.bash:76` — the `execute` option list.
- `test/wiggum.bats:19-21` — the global `claude` stub and per-test temp dir.
- `.wiggumrc` — verify is `shellcheck -s bash wiggum.sh lib/wiggum.sh install.sh` then `bats test/wiggum.bats`.
- `test/wiggum.bats:19-21` — overriding a function to stub it, the pattern the two clock accessors are designed for.
- POSIX `date`: `%H`, `%M`, `%S` are specified; `%s` is not in POSIX but is present in BSD, GNU and busybox. This is the only portability assumption the design makes.
- `CLAUDE.md` sections 1 and 2 — pure functions in `lib/wiggum.sh`, state cleared by `wiggum_reset()`, `set -euo pipefail`, zero shellcheck warnings, quote every expansion.
