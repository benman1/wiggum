# Delayed execution — execution summary

Plan: `docs/delayed-execution_plan.md` (Status: complete, 17/17 tasks `[x]`)
Stopped because: **complete** — every phase landed and the verify waterfall is clean.

## What was implemented

All five phases, across 21 commits (`3d7c6df..7e94d70`).

**Phase 1 — resolve `<WHEN>` with arithmetic, not a parser.** `wiggum_now_epoch()`
and `wiggum_now_hms()` (`lib/wiggum.sh:119,123`) are one-line `date +FORMAT` calls
that exist to be overridden by tests, which is what lets the production path stay
free of `date -d`/`-j`/`-r`. `parse_at_time()` (`:157`) resolves `+<N>[m|h|d]`,
`HH:MM` and `@<epoch>` to an absolute epoch using only those two accessors and
shell arithmetic, with `10#` forcing base 10 so `08:30` and `09:00` do not die as
invalid octal under `set -e`.

**Phase 2 — wait, then run once.** `--at <WHEN>` is parsed on the `execute` branch
into an `AT_TIME` global (`:858-863`) that `wiggum_reset()` clears (`:80`), and the
spec is validated at parse time so a bad one fails immediately rather than six
hours later. `launch_execute_delayed()` (`:3382`) refuses a live pidfile, refuses a
past target with `EXIT_BAD_ARGS`, writes the `.scheduled` sidecar and detaches a
waiter into `screen -dmS`, falling back to `nohup` — never `setsid`, which macOS
lacks. The waiter polls the wall clock rather than sleeping the interval once, so
it self-corrects across machine suspend. `--background` alongside `--at` is
accepted and ignored, with a line of output saying so.

**Phase 3 — `status` and `kill` know about a schedule.** `status` reports
`scheduled for <time> (in <duration>)` as its own state, distinct from `running`,
and self-heals a stale sidecar into `missed` or `not waiting` (`:3511-3553`) so a
machine that was asleep at 01:07 reads as the ordinary case it is. `kill` cancels a
pending schedule by the single pid in the sidecar (`:3703`), never a `pgrep -f`
pattern.

**Phase 4 — documentation on every surface.** `usage()`, `README.md`
(`### Delayed runs`, `:349`), both completion files, and the CLI reference table in
the embedded skill text (`:1588`).

**Phase 5 — guards.** Three source-reading bats guards: `--at` stays documented on
every surface; the `--at` path invokes no `caffeinate`/`pmset`/`crontab`/`launchctl`;
no `date` call in the path uses a flag beyond `+FORMAT`. Each has companion tests
proving the guard fails when its defect is reintroduced, and that the source
extractor fails loudly rather than passing vacuously when it cannot read a file.

## Beyond the plan's task list

Two helpers the plan implied but did not name:

- `at_replay_argv()` — the waiter re-enters wiggum by replaying the original
  invocation with `--at` and `--background` stripped, NUL-delimited, falling back to
  the file list when no argv was captured. Without this the waiter would have lost
  every other flag on the command line (`--iterations`, `--verify`, and so on).
- `format_duration()` — renders the "in `<duration>`" half of a scheduled run's
  status report.

The doc-sync guard covers **five** surfaces, not the four the plan wrote: `usage`,
`readme`, `completion-bash`, `completion-zsh` and `skill-table` — the plan's own
Phase 4 listed four tasks but the fourth added a fifth surface.

## Issues encountered

**A pre-existing `--help` bug, surfaced by a Phase 4 acceptance criterion.** The
criterion "`wiggum execute --help` shows the flag" failed for a reason unrelated to
`--at`: `-h|--help` called `usage` and returned 0 without switching `MODE`, so
`main()` printed help and then ran `execute` with no files, dying on an unbound
`FILES[0]`. Fixed in `804156c` by passing the subcommand to `usage` and setting
`MODE=help`. This was outside the plan's stated scope but blocked its acceptance,
so it was fixed rather than worked around.

**Three plan revisions before implementation started.** `64d59ce` dropped a
`date_flavour()` probe branching between BSD and GNU `date` in favour of the
parse-free syntax — that decision is now the invariant the Phase 5 date-flag guard
protects. `53e8611` added the sleep-interaction wording. `e6ec1ad` restored a
watch-teardown section the skill source had lost.

## What was deferred

Deliberately, per the plan's Constraints — nothing was dropped under pressure:

- **`wiggum chain --at`.** The flag is accepted on `execute` only. Confirmed absent
  from the chain path; it can follow now that the shape is proven.
- **Recurring schedules.** Out of scope; `examples/wiggum-cron.sh` and
  `examples/wiggum-nightly-setup.sh` already cover that, and the README points at
  them.
- **DST correctness on `HH:MM`.** One accepted inaccuracy: on the two nights a year
  when a transition falls inside the wait, the run starts an hour early or late.
  Handling it properly needs the calendar parsing this design exists to avoid, so it
  is documented in the README instead of branched for.

## Constraints honoured

No `caffeinate`, `pmset`, or any other wake lock is taken for the wait or the run —
whether the machine sleeps stays the user's decision, and the README says wiggum
will not make it for them. No crontab line or LaunchAgent plist is written as a side
effect: one invocation, one run. Both are now enforced by a guard rather than by
convention, and the wake-lock guard reads `lib/wiggum.sh` only, so the examples
directory's legitimate mentions of `crontab` and `launchctl` do not trip it.

## Verification

`./test/run.sh` — exit 0.

- `shellcheck -s bash wiggum.sh lib/wiggum.sh install.sh` — exit 0, zero warnings.
- `bats test/wiggum.bats` — **535 passed, 0 failed.**

The plan's bar was "no lower than the 437 present before this plan plus the tests it
adds". The tree at `3d7c6df~1` has exactly 437 tests, so this plan added **98**.
