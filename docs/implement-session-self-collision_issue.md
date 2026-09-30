# Issue: an implement session mistakes its own orchestrator's pid for a competing run

## Background

An implement session wiggum spawns is a plain `claude --session-id ... --resume
... -p "<task prompt>"` invocation, cwd'd into the target project. Claude Code
loads that project's `CLAUDE.md` and `.claude/rules/*.md` unconditionally for
that process, exactly as it would for a human's interactive session or a
separate session checking on an unrelated live run. Wiggum injects nothing that
marks the session as one of its own children: no env var, no note in the
phase-2 prompt, nothing the session could check mechanically instead of
reasoning about it.

Some projects, following wiggum's own documented advice (the wiggum skill's
"don't drive interactive work in the same repo while a run is live" guidance),
write a project rule telling any session to check `wiggum status`/`wiggum top`
before hand-editing a plan a live run might already hold, so a person doesn't
race an unattended chain. That guidance is correct for its actual case: a
person, or a separate session, editing the same plan or its source files while
an unrelated run is live elsewhere.

The bug: one of wiggum's own implement sessions runs `wiggum status <the exact
plan it is itself implementing>` as a self-check, sees `running (pid NNNNN)`,
and reads that as "a run is live against this plan, and it isn't me." But
`NNNNN` is its own parent, the orchestrator that spawned it. The session then
refuses to write any code, and either stops outright or asks a human what to
do, describing a collision that does not exist: it IS the run.

### Concrete recurrence (real evidence, `~/whismi`)

Six occurrences across three separate dates, two different plans, and two
different machines, tracked as `bug-201` in that project's own
`.wolf/buglog.json`:

- 2026-09-22: `wiggum chain docs/programmed_instruction_plan.md`, sessions
  `cb4cf943`, `1abf40b2`.
- 2026-09-23, same plan rerun: sessions `d9fdd84f-a73e-4768-905b-bcacaf66ba15`,
  `9bc0ed55-6bb4-4e34-8fbd-ac936ace9002`.
- 2026-09-23: `~/whismi/.claude/rules/wiggum.md` gets an explicit
  disambiguating clause added, naming `bug-201` by number and stating
  plainly: "an implement session *is* that run, not a competitor for it."
  That file is a project instruction file loaded unconditionally into every
  session in the repo, implement sessions included, with no gate to miss.
- 2026-09-30, on a Hetzner Ubuntu host, `wiggum execute docs/ereader_plan.md
  --background --max-iterations 57`: iteration 2 (session
  `4a7f48b8-757b-47d8-8d30-d9b2307dbb8b`) and iteration 3 (session
  `34e418f2-e971-43f0-b6d5-2d381a9de5e8`) both hit it, two stalls in a row,
  and the run aborted as `stalled` at 1 of 27 tasks done. Relaunching cleared
  one iteration, then hit it again on the very next iteration (session
  `354909c5-095a-4128-aa2e-196442b90c1d`), stalling a second run at 2 of 27.

Session transcript excerpt (`354909c5`, verbatim reasoning):

> "`wiggum status` confirms it: **running**, pid 1962074, 2/27 tasks done, 25
> remaining. This is a live chain actively working through the same `[ ]`
> tasks you're asking me to pick up by hand. ... I'm the interactive session,
> not a spawned child of that run..."

Stated confidently, and wrong: `354909c5` was a spawned child of pid 1962074,
resumed directly from that same run's own prior commit session.

Each occurrence wastes a full verify waterfall (the plan's `db:check`,
`tokens`, `type-check`, `npm test`, `build`, `lint` steps) for zero task
progress before wiggum's own stall detector catches the pattern after two
consecutive occurrences and aborts. The one mitigation attempted so far lives
entirely in the *consuming* project's rule file, not in wiggum, and even
there — with the exact bug named and the mechanism spelled out in prose,
loaded unconditionally — the failure recurred twice more.

## Goals

1. An implement session should never mistake its own orchestrator process for
   a competing, external wiggum run.
2. The fix should not depend on every project independently writing (and
   re-writing) its own prose carve-out for this — that has been tried once
   and did not hold.
3. Prefer a structural, mechanically-checkable signal over asking the model to
   reason correctly about whether a rule (written for a different case)
   applies to itself.

## Non-goals

- Removing the general "don't hand-edit while a live run exists elsewhere"
  guidance. That is a real warning for an actual human/interactive collision
  and should stay as-is.
- Guaranteeing a project's own instructions can never confuse a spawned
  session about anything else. Out of scope; this issue is specifically the
  "is that pid me?" case.

## Current behavior

- Wiggum spawns each diagnostic/implement/commit session as a bare `claude`
  invocation (`--session-id`, `--resume`, `--fork-session`, `--effort xhigh`,
  `--permission-mode auto`, `--model sonnet`, `-p "<task prompt>"`), cwd'd
  into the target repo.
- Nothing distinguishes that invocation's environment from an ordinary
  interactive `claude` session started by a person in the same directory.
- The phase-2 task prompt (composed in `lib/wiggum.sh`) says nothing about the
  session's relationship to the orchestrator process, and does not warn that
  checking wiggum's own status on the plan being implemented will trivially
  report "running" against the session's own ancestor.

## Desired behavior

Options to evaluate, not prescribing one:

1. **An explicit environment signal.** Set `WIGGUM_ORCHESTRATOR_PID=<pid>`
   (and/or `WIGGUM_IMPLEMENT_SESSION=1`) in the spawned session's environment.
   The phase-2 prompt tells the session: "If `wiggum status` reports this
   exact plan running under pid `$WIGGUM_ORCHESTRATOR_PID`, that is you, not a
   competing run." Turns a fuzzy self-recognition judgment into a mechanical
   string comparison the session can actually perform.
2. **Discourage or forbid implement sessions from running `wiggum
   status`/`wiggum top` as part of ordinary task execution.** Its job is
   "implement the next task," not "supervise wiggum." If there's no
   legitimate reason for it to check wiggum's own run state, close off the
   whole class of confusion at the prompt level instead of relying on
   after-the-fact disambiguation.
3. **Ship the disambiguating language centrally, in wiggum's own phase-2
   prompt template**, rather than leaving each project to write (and
   maintain) its own version, which has already failed once under real load.

## Evidence

- `~/whismi/.wolf/buglog.json`, `bug-201`: `occurrences: 6`, `last_seen:
  2026-09-30T14:34:00Z`, spanning `docs/programmed_instruction_plan.md` and
  `docs/ereader_plan.md`, a Mac and a Hetzner host.
- `~/whismi/.claude/rules/wiggum.md`: "Before treating a live-run pid as a
  reason to stop, check whether it belongs to the chain doing the checking" —
  the mitigation that was tried and did not fully hold.
- Session transcripts (2026-09-30, Hetzner host,
  `/root/.claude/projects/-root-whismi/`):
  `4a7f48b8-757b-47d8-8d30-d9b2307dbb8b.jsonl`,
  `34e418f2-e971-43f0-b6d5-2d381a9de5e8.jsonl`,
  `354909c5-095a-4128-aa2e-196442b90c1d.jsonl`. All three show the identical
  reasoning pattern: correctly read `wiggum status`'s pid, incorrectly
  conclude it names an external session.
