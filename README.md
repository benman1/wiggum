# Wiggum

A self-driving agent loop that turns issue descriptions into working, verified code.

Wiggum wraps [Claude Code](https://claude.com/claude-code) in a structured orchestration loop. You give it issue files or spec documents; it produces a workplan, implements it step by step, verifies each step against your project's own toolchain, self-heals failures, and commits the results. The human decides *what* to build. Wiggum figures out *how* and keeps going until it's done.

## Why

AI coding assistants are powerful in single-turn interactions, but real implementation work is multi-step: read the spec, write code, run the linter, fix type errors, run tests, fix regressions, commit, repeat. Each of those handoffs is a place where momentum stalls.

Wiggum automates the full cycle. It acts as a project driver that:

- **Plans before it builds.** Given issue descriptions, it produces a structured workplan with phases, tasks, and acceptance criteria before writing a single line of code.
- **Implements incrementally.** Each iteration tackles one discrete step from the plan, keeping changes focused and reviewable.
- **Verifies with your tools.** After each implementation step, it runs your project's actual verification commands (type checker, test suite, linter, build) in a waterfall. No mock validation.
- **Self-heals.** When a verification step fails, Wiggum feeds the error output back to Claude and asks it to fix the problem. For tools that can auto-correct (like `ruff --fix` or `eslint --fix`), it runs the autofix first and only escalates to Claude if the issue persists.
- **Knows when to stop.** Validation retries are capped to prevent runaway token consumption.
- **Commits as it goes.** Each iteration produces isolated, single-purpose git commits with clean imperative messages.
- **Runs unattended, supervised.** Kick off a run in the background, then check progress, wait for it, spot when it's blocked, and stop it if it overruns — or chain several workplans so they run back to back.

The result: you kick off a run, walk away, and come back to a branch with a series of clean commits, a reconciled plan, and a summary of what happened.

## How it works

Wiggum's commands map to the natural workflow of software development — `init`, `plan`, `execute`, `check`, `docs`, and `run` — with `status`, `watch`, `kill`, and `chain` layered on top to supervise long or batched runs.

### Init mode

```
wiggum init [preset]
```

Generates a `.wiggumrc` configuration file for the current project. If no preset is specified, wiggum inspects the directory for known project files (`package.json`, `next.config.ts`, `pyproject.toml`, etc.) and picks the matching preset automatically. If a `.wiggumrc` already exists, it asks before overwriting.

It also asks which Claude permission mode to bake into the config — `auto` (the default: Claude's auto-mode classifier gates each action, so unattended runs keep a guardrail) or `bypassPermissions` (run everything with no checks). The choice is written as a `permission_mode` line in the generated `.wiggumrc`.

This is the recommended first step when adopting wiggum in a new project. The generated config provides sensible defaults for verification commands that you can then tune to your specific setup.

### Plan mode

```
wiggum plan <issue-files...>
wiggum plan < description.txt
echo "description" | wiggum plan
wiggum plan <issue-files...> | wiggum execute
```

Reads issue descriptions, specs, or requirements documents and produces a structured workplan. The plan is a markdown document with:

- Phases grouping related work
- Discrete tasks, each with a `[ ]` checkbox (GitHub-flavored `-`, `*`, or `+` bullets all count)
- An observable acceptance criterion per task
- The files each task is expected to create or modify
- Dependencies between tasks

Output destination depends on how `plan` is invoked:

| Invocation | Plan goes to |
|---|---|
| File arg, TTY stdout (interactive) | `<basename>_plan.md` on disk |
| File arg, piped stdout (`... \| wiggum execute`, `> file`) | stdout |
| Stdin, TTY stdout | stdout |
| Stdin, piped stdout | stdout |
| `--plan-file <path>` (any invocation) | the specified path |

In short: if stdout is not a terminal, the plan streams through stdout; otherwise it's written to `<basename>_plan.md`. Pass `--plan-file` to force a specific on-disk path.

This is a read-only analysis step. It does not modify your codebase. Before finalizing, Wiggum confirms the libraries and APIs the plan depends on actually exist, so execution doesn't start from a hallucinated assumption.

#### Dropped tasks

Plans use three checkbox states:

- `[ ]` -- pending. Wiggum will pick this up on the next iteration.
- `[x]` -- done. Terminal.
- `[~]` -- dropped. Terminal. The work was intentionally abandoned mid-execution -- typically because the task turned out to be inapplicable, redundant, or out of scope once the surrounding implementation came into focus. Wiggum treats `[~]` exactly like `[x]` for control-flow purposes: it is not counted as remaining, the phase-2 loop will not re-pick it, and phase-1 reconcile will not convert it back to `[ ]`.

Record the rationale on the same line as the marker so future readers (and future iterations) understand why the task was dropped:

```
- [~] **2.6** -- surprisal/burstiness. Dropped: llm-server has no perplexity endpoint.
- [~] **3.1** -- cross-document coreference. Dropped: covered by upstream embeddings already.
```

What `[~]` is **not**:

- Not "deferred to a later phase". If the work is still planned, leave it `[ ]`.
- Not "blocked". If the work is paused waiting on something, leave it `[ ]` and note the blocker in the line.
- Not a way to silence stalls. `[~]` is a recorded decision in the plan, not a control knob.

GitHub-rendering caveat: `[~]` renders as plain text in GitHub's task-list view (only `[ ]` and `[x]` get the interactive checkbox treatment). This is acceptable because plans are primarily read in IDEs, `cat`, and `grep` -- the marker stays distinct everywhere it matters.

### Execute mode

```
wiggum execute <plan-files...>
wiggum execute < plan.md
wiggum plan issue.md | wiggum execute
wiggum execute docs/plan.md --background   # run detached; supervise with status/watch/kill
```

Takes a workplan (typically one produced by `plan` mode, but any structured markdown will do) and implements it through three phases. When no files are given, reads the plan from stdin. At the end, the completed plan and summary are saved with descriptive filenames derived from the plan content (e.g., `docs/improve-chunking_plan.md` and `docs/improve-chunking_summary.md`).

By default `execute` runs in the foreground and blocks until it finishes. Add `--background` (`-b`) to run detached and supervise the run with `status`, `watch`, and `kill` — see [Background runs & supervision](#background-runs--supervision).

**Phase 1 -- Diagnostic & Status Sync**

Before writing any code, Wiggum compares the plan against the actual state of the repository. It marks tasks that are already complete, flags inaccuracies, and identifies what to do next. This sync is committed separately so implementation commits stay clean.

**Phase 2 -- Iterative Implementation**

For each iteration (up to `--max-iterations` or the config file value, stopping early if all tasks are done or progress stalls):

1. **Implement** -- Claude reads the plan and picks the next discrete task. Before coding it verifies its assumptions (the APIs and imports it will call exist, config values are defined), writes a failing test first when nothing covers the change, implements, then runs three spot checks -- happy path, edge case, and failure case -- before marking the task done.
2. **Verify** -- The verification waterfall runs each configured step in order. On failure:
   - *Autofix steps* run the command once to let it self-correct (e.g., `ruff --fix`), then re-check. Only if the fix didn't resolve it does Claude get involved.
   - *Verify steps* capture the error output and ask Claude to fix the code directly.
   - This cycle repeats up to `max_validation_retries` times before moving on.
3. **Commit** -- Uncommitted changes are reviewed and committed with isolated, imperative-mood messages.
4. **Progress check** -- Wiggum counts unchecked `[ ]` boxes in the plan. If none remain, execution stops early (all done). If the count didn't decrease for 2 consecutive iterations, execution stops (stalled). Otherwise, the next iteration begins.

**Phase 3 -- Summary & Alignment**

After all iterations complete (or early stop), Wiggum:

- Updates the plan file, marking completed tasks with `[x]`
- Writes an execution summary covering what was implemented, what was deferred, issues encountered, and verification results
- Commits the updated plan and summary

```
            +------------------+
            |  Status Sync     |  Phase 1
            |  (plan vs repo)  |
            +--------+---------+
                     |
          +----------v-----------+
     +--->|  Implement next step |  Phase 2 (up to N iterations)
     |    +----------+-----------+
     |               |
     |         +-----v------+
     |         |   Verify    |<--+
     |         +-----+------+   |
     |               |           |
     |          fail |     pass  |
     |               v           |
     |        +------+------+   |
     |        | Autofix /   +---+
     |        | Claude fix  |  (up to max_validation_retries)
     |        +-------------+
     |               |
     |         +-----v------+
     |         |   Commit    |
     |         +-----+------+
     |               |
     |       +-------v--------+
     |       | Progress check |
     |       +---+----+---+---+
     |           |    |   |
     |  progress |    |   | all done / stalled
     +-----------+    |   |
                      |   +--------+
                      v            v
            +------------------+  (early stop)
            |  Summary &       |  Phase 3
            |  Plan Update     |
            +------------------+
                     |
            +--------v---------+
            |  Update docs     |  Phase 4 (if --update-docs)
            +------------------+
```

### Docs mode

```
wiggum docs -i <input-files...> -o <output-files...>
```

Updates documentation files based on input context. The `-i` flag specifies source material (summaries, plans, changelogs, code) and the `-o` flag specifies which doc files to update. Claude reads the current content of each output file and updates only the sections affected by the changes described in the input files.

This can be used standalone after a run:

```bash
wiggum docs -i docs/summary.md docs/plan.md -o README.md
```

Or built into the execute flow with `--update-docs` (see [Executing a plan](#executing-a-plan)).

### Check mode

```
wiggum check
```

Runs the verification waterfall from `.wiggumrc` against the current codebase and asks Claude to fix any failures. This is the same validation loop that runs during execute mode, but without the implementation or commit steps.

Useful for:

- **After manual edits** -- verify your changes pass before committing.
- **Before a PR** -- make sure everything's clean.
- **CI gating** -- run `wiggum check` as a pre-merge check.

```bash
wiggum check              # run all verify/autofix steps
wiggum check --verbose    # show Claude output
```

If all steps pass, exits 0. If any step fails after `max_validation_retries` fix attempts, exits non-zero.

### Run mode

```
wiggum run "first prompt" "second prompt" ...
```

Feeds a series of prompts to Claude Code in **one continuous session**. The first prompt starts a fresh session; every later prompt continues it (`claude --resume … --fork-session` under the hood), so Claude keeps full context from one prompt to the next. Claude's responses go to stdout; wiggum's status lines and session ids go to stderr — so `wiggum run … > answers.txt` captures just the answers.

Prompts come from three sources, which can be combined:

- **Positional arguments** — each argument is one prompt: `wiggum run "do X" "now do Y"`.
- **A file** (`-f`/`--prompts-file`) — prompts separated by a line containing only the delimiter (default `---`), so each prompt can span multiple lines.
- **Stdin** — `cat steps.txt | wiggum run`, split the same way.

```bash
wiggum run "Summarize today's git log" "Draft release notes from it"
wiggum run -f steps.txt
echo "What changed in the last commit?" | wiggum run
wiggum run --effort max "Audit this module for race conditions"
```

#### Cron jobs and follow-ups

With `--session-file <path>`, the session id is saved to that file and resumed on the next invocation. This lets a cron job run a step now and follow up later **in the same session**:

```bash
# Monday — starts a session and saves its id to .wiggum-session
wiggum run --session-file .wiggum-session "Scaffold the API skeleton"

# Tuesday — resumes Monday's session and builds on it
wiggum run --session-file .wiggum-session "Now add auth to the API you built"
```

The id is rewritten after every prompt, so a follow-up resumes from the latest completed step even if a later prompt failed mid-chain. Pass `--new-session` to ignore an existing session file and start over. Pair it with `permission_mode = auto` (or `--permission-mode auto`) so unattended runs let Claude's auto-mode classifier decide each action.

For a complete, copy-pasteable cron setup — wrapper script, environment, and the gotchas that bite unattended jobs — see [Scheduling with cron](#scheduling-with-cron).

### Background runs & supervision

`wiggum execute` normally runs in the foreground and blocks until it finishes. For long plans — or when you want to supervise a run, bound it, or fire off several — run it detached and drive it with the supervision commands.

```
wiggum execute docs/plan.md --background   # or -b
```

`--background` launches the loop in a detached process, records its pid, and captures all output to sidecar files next to the plan:

- `docs/plan.pid` — the wiggum process id for this run
- `docs/plan.out` — the full run output (phase headers, progress, status)
- `docs/plan.log` — the structured run log

Every supervision command refers to a run **by its plan file** and derives those sidecars from it:

| Command | Purpose |
|---|---|
| `wiggum status docs/plan.md` | Print task counts and run state: `not started`, `running`, `running but appears blocked`, or `finished: <reason>`. Read-only. |
| `wiggum watch docs/plan.md` | Stream the run's output and **block until it finishes** — wiggum's "wait". Exits 0 only when the run finished `complete`. |
| `wiggum kill docs/plan.md` | Stop the run — and only this run's process tree (the wiggum process and the `claude` it spawned). Never a blanket kill. |

`watch` can bound a run so a wedged loop can't hang forever:

```
wiggum watch docs/plan.md --timeout 1800 --kill-on-timeout   # give up after 30 min and kill it
wiggum watch docs/plan.md --poll-interval 2                   # poll for new output every 2s (default 5)
```

**Detecting a blocked run.** `status` reports `running but appears blocked` (or a finished run as `stalled`) when the output shows wiggum spinning without progress — repeated `No progress detected`, `Stalled for ...`, or a verification waterfall that gave up (`Validation failed N times`). When that happens, read the tail of `docs/plan.out` / `docs/plan.log` to find the cause: usually a failing verify command or a task whose acceptance can't be met. Fix the plan or the source (not `.wiggumrc`) and re-run.

### Chaining workplans

Run several plans back to back, each in a fresh session, stopping at the first failure:

```
wiggum chain docs/schema_plan.md docs/api_plan.md docs/ui_plan.md
wiggum chain docs/*.plan.md --max-iterations 5
```

`chain` runs `wiggum execute` on each plan in order. If a plan fails (stalls or errors), the chain stops there rather than wasting effort on plans that likely depend on it. This is the preferred way to tackle work too large for one plan: split it into focused plans and chain them, instead of writing one 40-task plan that tends to stall.

### Claude Code skill

Wiggum ships a `/wiggum` slash command for Claude Code that acts as an **orchestrator** for the CLI. Instead of re-running the loop in-conversation, the skill drives the `wiggum` binary: it creates a workplan, launches `wiggum execute` (in the background), monitors progress, waits for completion, analyzes whether a run is blocked, kills a run that overruns (only that run's process), and chains workplans together.

```
/wiggum docs/login-bug.md
/wiggum "add rate limiting to the /api/upload endpoint"
/wiggum chain: docs/schema_plan.md docs/api_plan.md docs/ui_plan.md
```

The skill accepts an issue file, a plain-text description (which it turns into a plan), an existing plan file, or several plans to chain. Because it drives the CLI, the `wiggum` binary must be installed and on `PATH` (see [Background runs & supervision](#background-runs--supervision) for the commands it uses).

The skill is installed globally by `install.sh` (to `~/.claude/skills/wiggum/SKILL.md`) so it works in every project. Running `wiggum init` in a specific project installs a project-local copy at `.claude/skills/wiggum/SKILL.md`.

## Prerequisites

- [Claude Code CLI](https://claude.com/claude-code) installed and authenticated
- Bash 4+
- A git repository

## Installation

Clone this repo and run the install script:

```bash
git clone <repo-url> && cd wiggum
./install.sh
```

This copies `wiggum.sh` and `lib/wiggum.sh` to `/usr/local/lib/wiggum/`, symlinks `/usr/local/bin/wiggum` to the entry point, seeds `~/.wiggumrc` from the example config if you don't have one yet, and installs the `/wiggum` Claude Code skill globally. May prompt for sudo.

Or just run it directly from the repo without installing:

```bash
./wiggum.sh plan issues/something.md
```

The CLI resolves the library relative to its own location, so no install step is needed for local use.

## Usage

### Initializing a project

```bash
# Auto-detect project type from files in the current directory
wiggum init

# Specify a preset explicitly
wiggum init python
```

Available presets:

| Preset | Detected by | Verification steps |
|--------|------------|-------------------|
| `node` | `package.json` | type-check, test, build, lint --fix |
| `next` | `next.config.{js,ts,mjs}` | type-check, test, build, lint --fix |
| `python` | `pyproject.toml`, `setup.py`, or `requirements.txt` | ruff format+check (autofix), pytest |
| `astro` | `astro.config.{mjs,ts}` | type-check, test, build, prettier (autofix) |
| `bash` | `.shellcheckrc` or `test/run.sh` | shellcheck, bats |

If no preset is given, wiggum inspects the current directory and picks the best match. The generated `.wiggumrc` is a starting point -- edit it to match your actual scripts.

After creating the `.wiggumrc`, init offers to:

1. Set up Claude Code permissions (see [Permissions](#permissions) below)
2. Install the `/wiggum` Claude Code skill (see [Claude Code skill](#claude-code-skill) below)
3. Remind you to create a `CLAUDE.md` if one doesn't exist

### Creating a plan

```bash
# From a single issue file
wiggum plan issues/login-bug.md

# From multiple spec files
wiggum plan docs/spec.md docs/requirements.md

# With a custom output path
wiggum plan issues/login-bug.md --plan-file docs/login_plan.md

# From a string (plan goes to stdout)
echo "Add dark mode toggle to settings" | wiggum plan

# Here-string shorthand
wiggum plan <<< "Fix the login timeout bug"
```

When given files, default output is `<input-basename>_plan.md` in the same directory as the first input file. When reading from stdin, the plan is written to stdout (use `--plan-file` to override).

### Executing a plan

```bash
# Execute with defaults (3 iterations)
wiggum execute docs/login_plan.md

# More iterations for larger plans
wiggum execute docs/plan.md --max-iterations 10

# Custom summary location
wiggum execute docs/plan.md --summary-file reports/run1_summary.md

# Execute and update README when done
wiggum execute docs/plan.md --update-docs README.md

# Update multiple docs after execution
wiggum execute docs/plan.md --update-docs README.md,docs/API.md

# Multiple context files (plan + supporting docs)
wiggum execute docs/plan.md docs/api_spec.md docs/schema.csv

# Pipe a plan directly from stdin (plan streams to execute, no intermediate file)
wiggum plan issues/bug.md | wiggum execute

# One-liner: describe, plan, and execute
echo "Add rate limiting to /api/upload" | wiggum plan | wiggum execute

# Run detached, then supervise it (status / wait / stop if it overruns)
wiggum execute docs/plan.md --background
wiggum status docs/plan.md
wiggum watch  docs/plan.md --timeout 1800 --kill-on-timeout
```

Two equivalent patterns for plan → execute:

1. **Explicit** (preferred when you want to review or reuse the plan): run each step separately and point `execute` at the plan file on disk.
   ```bash
   wiggum plan    issues/bug.md           # writes issues/bug_plan.md
   wiggum execute issues/bug_plan.md
   ```
2. **Piped** (preferred for one-shot runs): `plan` detects the non-TTY stdout and streams the plan into `execute`. No intermediate file.
   ```bash
   wiggum plan issues/bug.md | wiggum execute
   ```

Default output: `<input-basename>_summary.md` in the same directory as the first input file.

### Batch workflows

**Plan from multiple issues at once.** All files are passed to Claude as context for a single combined plan:

```bash
wiggum plan issues/auth-bug.md issues/rate-limiting.md issues/logging-gap.md
# produces: issues/auth-bug_plan.md (named after the first file)

wiggum plan issues/auth-bug.md issues/rate-limiting.md --plan-file docs/sprint_plan.md
# better: explicit output name for combined plans
```

**Run multiple plans sequentially.** Use a simple loop to execute several plans one after another:

```bash
for plan in docs/*_plan.md; do
    wiggum execute "$plan" --max-iterations 3
done
```

**Plan all issues in a directory.** Bash expands globs before wiggum sees them:

```bash
wiggum plan issues/*.md --plan-file docs/backlog_plan.md
```

**Resume a partially-completed plan.** If a previous run only finished some tasks, just run execute again. Phase 1 syncs the checkboxes against the repo, so Claude picks up where it left off:

```bash
# First run: completes 4 of 10 tasks
wiggum execute docs/plan.md --max-iterations 4

# Second run: starts from task 5
wiggum execute docs/plan.md --max-iterations 6
```

**Pass supporting context alongside a plan.** Extra files (specs, schemas, PDFs) are passed to Claude as context but aren't treated as the plan:

```bash
wiggum execute docs/plan.md docs/api_spec.md docs/schema.csv
```

### Command reference

```
wiggum <mode> [files...] [options]
command | wiggum <mode> [options]

Modes:
  init        Generate a .wiggumrc for the current project
  plan        Create a workplan from issue/spec files
  execute     Implement a workplan with iterative validation
  check       Run verification waterfall and fix issues
  docs        Update documentation from input files
  run         Feed a series of prompts to Claude in one continuous session
  status      Show task progress and run state for a plan
  watch       Follow a background run until it finishes (wait)
  kill        Stop a background run (only that run's process)
  chain       Execute several workplans back to back

Options:
  --plan-file <path>       Output path for the plan (plan mode)
  --summary-file <path>    Output path for the summary (execute mode)
  --max-iterations <n>    Maximum implementation iterations (execute/chain, default: 3)
  --benchmark <script>    Run script after each iteration, feed output to Claude (repeatable)
  --update-docs <files>    Comma-separated doc files to update after execution (execute mode)
  -b, --background         Run execute detached; supervise with status/watch/kill
  --timeout <seconds>      Stop watching after N seconds, 0 = forever (watch mode)
  --kill-on-timeout        On watch timeout, kill the run (watch mode)
  --poll-interval <secs>   How often watch polls for new output (default: 5)
  --no-verify              Skip wiggum's verification waterfall (execute mode; rejected by check)
  --no-commit              Skip every wiggum-issued git commit (execute, check, docs)
  -f, --prompts-file <p>   Read prompts from a file, split on delimiter lines (run mode)
  --session-file <path>    Persist/resume the session id across invocations (run mode)
  --new-session            Ignore an existing --session-file and start fresh (run mode)
  --delimiter <str>        Prompt separator for -f/stdin (run mode, default: ---)
  --effort <level>         Reasoning effort: low|medium|high|xhigh|max (default: xhigh)
  --permission-mode <m>    Claude permission mode (default: bypassPermissions)
  --verbose                Show Claude output (suppressed by default)
  -i <files...>            Input files (docs mode)
  -o <files...>            Output doc files to update (docs mode)
  --                       End of options (remaining args are files)
  -h, --help               Show help

When no files are given, plan and execute read from stdin. Plan writes to
stdout whenever stdout is not a terminal (e.g. pipe or redirect), otherwise
to `<basename>_plan.md` on disk. Execute always writes to files (side
effects are the output). Use -- to pass filenames that start with a dash.
```

### Verbose mode

By default, Claude's response text is suppressed — wiggum shows only its own status lines. Pass `--verbose` to see Claude's full output at each step:

```bash
wiggum execute docs/plan.md --verbose
```

This is useful for debugging or understanding what Claude is doing at each step.

## Configuration

Wiggum looks for a `.wiggumrc` file, first in the current directory, then in `$HOME`. The config uses a simple `key = value` format.

### Config keys

| Key | Description | Default |
|-----|-------------|---------|
| `verify` | A shell command to run as a verification step. Fails are sent to Claude for fixing. Multiple lines define an ordered waterfall. | *(none)* |
| `autofix` | Like `verify`, but the command is run once first to let it self-correct (e.g. linters with `--fix`). Only escalates to Claude if it still fails after autofix. | *(none)* |
| `benchmark` | A shell command to run after each iteration. Output is fed to Claude as context for the next iteration. Purely informational — does not gate or block. Multiple lines are supported. | *(none)* |
| `max_iterations` | Maximum implementation iterations per run. Stops early if all tasks complete or progress stalls. | `3` |
| `max_validation_retries` | Max times the validation cycle retries before giving up. | `5` |
| `skip_verify` | If `true`, skip wiggum's verification waterfall entirely (same as `--no-verify`). | `false` |
| `skip_commit` | If `true`, skip every wiggum-issued git commit (same as `--no-commit`). | `false` |
| `effort` | Reasoning effort passed to Claude Code on every call: `low`, `medium`, `high`, `xhigh`, or `max` (same as `--effort`). | `xhigh` |
| `permission_mode` | Claude Code permission mode for every wiggum-issued call: `acceptEdits`, `auto`, `bypassPermissions`, `default`, `dontAsk`, or `plan` (same as `--permission-mode`). | `bypassPermissions` |

### Skipping verification or commits

Both behaviors are opt-in via CLI flags or config keys. CLI flags win when they disagree with config.

**`--no-verify` / `skip_verify = true`** — skip wiggum's verification waterfall in `execute`. This is useful when iterating on experimental code where running the full test suite each cycle is too slow, or when tests are known broken and not in scope for the current run. Caveat: this only suppresses wiggum's own verify pass. Claude may still run tests, builds, or type-checks during implementation — wiggum does not control Claude's tool use. To stop tests from running entirely, edit your project's CLAUDE.md to instruct Claude not to run them. `wiggum check --no-verify` is rejected (it would make `check` a no-op).

**`--no-commit` / `skip_commit = true`** — skip every wiggum-issued git commit. Useful when reviewing changes manually before committing, or when exploring multiple approaches in an unstaged working tree. The working tree is left dirty; subsequent `wiggum execute` runs will see uncommitted state in phase 1, and Claude may try to reconcile it. Note: Claude may still create its own commits if it decides to — this flag only stops the wiggum-issued prompts.

```bash
wiggum execute docs/plan.md --no-verify              # skip the verify waterfall
wiggum execute docs/plan.md --no-commit              # leave changes uncommitted
wiggum execute docs/plan.md --no-verify --no-commit  # both
wiggum check --no-commit                             # verify but don't commit fixes
```

### Effort and permission mode

Two settings control how every wiggum-issued `claude` call behaves. Both can be set in `.wiggumrc` or per-run on the CLI; the CLI wins on conflict, and both apply to all modes (`plan`, `execute`, `check`, `docs`, `run`).

**`effort` / `--effort`** — the reasoning effort Claude Code uses: `low`, `medium`, `high`, `xhigh`, or `max`. Wiggum defaults to `xhigh` (deep reasoning suits planning and self-healing). Drop to `low`/`medium` for cheaper, faster runs on simple tasks.

**`permission_mode` / `--permission-mode`** — the Claude Code permission mode for the call: `acceptEdits`, `auto`, `bypassPermissions`, `default`, `dontAsk`, or `plan`. `wiggum init` asks for this and writes `permission_mode = auto` by default — Claude's auto-mode classifier gates each action, a guardrailed middle ground for unattended runs. `bypassPermissions` runs everything with no checks (fastest, no guardrails). When the line is absent from `.wiggumrc` entirely, the built-in default is `bypassPermissions` (back-compat for configs written before `init` set this).

```bash
wiggum execute docs/plan.md --effort max               # maximum reasoning
wiggum run --permission-mode auto "tidy up the imports" # let auto-mode decide
```

```ini
# .wiggumrc
effort = xhigh
permission_mode = bypassPermissions
```

### Verify vs autofix

Both `verify` and `autofix` define shell commands that run after each implementation step. The difference is what happens on failure.

**`verify`** -- strict check. If the command exits non-zero, wiggum captures the last 60 lines of output and sends them to Claude with a prompt to fix the code. Use this for tools that only report problems without fixing them: type checkers, test suites, builds.

**`autofix`** -- self-correcting check. Wiggum runs the command once and lets it modify files (e.g. `ruff --fix` rewrites source, `prettier --write` reformats). Then it runs the same command a second time to verify. Only if the second run still fails does Claude get involved. Use this for linters and formatters that have a `--fix` or `--write` mode.

You can mix both freely. They run in the order they appear in the config file.

### Verification waterfall

The waterfall short-circuits: if the first step fails, later steps don't run until it's fixed. This prevents wasting time on a full build when there are type errors, and prevents running the test suite when the code doesn't even compile.

A well-ordered waterfall puts the cheapest and fastest checks first:

```
verify = npm run type-check        # Seconds. Catches most issues.
verify = npm test                  # Tens of seconds. Catches logic errors.
verify = npm run build             # Minutes. Catches integration issues.
verify = ./smoke.sh                # Validates the built output end-to-end.
autofix = npx prettier --write .   # Auto-corrects formatting.
```

When any step fails, wiggum asks Claude to fix it (or runs autofix), then restarts the entire waterfall from the top. This continues up to `max_validation_retries` times. If validation still hasn't passed after all retries, wiggum logs a warning and moves on to the next iteration.

### Smoke tests

A smoke test is a lightweight end-to-end check that validates the built output actually works. Unlike unit tests (which test individual functions) or build commands (which test compilation), a smoke test exercises the real artifact: start the server, hit a URL, check the response.

Smoke tests are project-specific, so wiggum doesn't generate them -- you write a small script and point to it in your config:

```
verify = ./smoke.sh
```

Some examples of what a smoke test might do:

- **Static site:** Build, serve the output directory, fetch the sitemap, verify all listed URLs return 200.
- **API server:** Start the server in the background, hit `/health`, verify the response, kill the server.
- **CLI tool:** Run the built binary with `--help`, verify it exits 0 and prints usage.

A minimal smoke test for an Astro or Next.js static export:

```bash
#!/usr/bin/env bash
# smoke.sh - Verify the build output is navigable
set -euo pipefail

npm run build
npx serve dist -l 4321 &
SERVER_PID=$!
sleep 2

# Check that key pages return 200
for path in "/" "/about" "/api/health"; do
    status=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:4321${path}")
    if [[ "$status" != "200" ]]; then
        echo "FAIL: $path returned $status"
        kill $SERVER_PID
        exit 1
    fi
done

kill $SERVER_PID
echo "Smoke test passed."
```

Because smoke tests are just `verify` lines, they participate in the normal waterfall: if the smoke test fails, Claude sees the output and tries to fix the underlying issue.

### Benchmarks

Benchmarks are different from verification steps. Verification is pass/fail — "is the code correct?" Benchmarks answer "is the code better?" Their output is fed to Claude as context for the next iteration, but they never block or gate progress.

Configure them in `.wiggumrc`, on the command line, or both:

```
# .wiggumrc
benchmark = ./scripts/measure_bundle_size.sh
benchmark = ./scripts/lighthouse_score.sh
```

```bash
wiggum execute docs/plan.md --benchmark "./measure_load_time.sh"
```

After each implementation iteration (post-commit), wiggum runs all benchmark scripts and includes their concatenated output in the next iteration's prompt. Claude uses this to guide its approach — focusing on what's improving and what isn't.

**Examples of benchmark scripts:**

- **Bundle size:** `du -sh dist/ && wc -l dist/**/*.js`
- **Performance score:** `npx lighthouse http://localhost:3000 --output json --quiet | jq '.categories.performance.score'`
- **Test coverage:** `npx jest --coverage --coverageReporters=text-summary 2>&1 | grep Statements`
- **Claude as evaluator:** Have the benchmark script produce the artifact (rendered HTML, API response, generated report) and dump it to stdout. Claude sees the raw output in the next iteration and can judge quality, completeness, or correctness — no external scoring tool needed.

If no benchmark scripts are configured, the loop works exactly as before.

### Example configs

**TypeScript / Node.js project:**

```
# .wiggumrc
verify = npm run type-check
verify = npm test
verify = npm run build
autofix = npm run lint -- --fix

max_iterations = 5
```

**Python project:**

```
# .wiggumrc
autofix = ruff format app tests && ruff check --fix app tests
verify = pytest

max_iterations = 3
max_validation_retries = 3
```

**Astro / static site with smoke test and performance benchmark:**

```
# .wiggumrc
verify = npm run type-check
verify = npm test
verify = npm run build
verify = ./smoke.sh
autofix = npm run format
benchmark = du -sh dist/
```

**Next.js project:**

```
# .wiggumrc
verify = npm run type-check
verify = npm test
verify = npm run build
autofix = npm run lint -- --fix

max_iterations = 3
```

**Minimal (no verification):**

```
# .wiggumrc
max_iterations = 2
```

Without any `verify` or `autofix` lines, wiggum still implements and commits but skips the validation loop entirely.

### Config search order

1. `./.wiggumrc` (project root -- per-project settings)
2. `~/.wiggumrc` (home directory -- personal defaults)

Only the first file found is used. They are not merged.

## Permissions

Wiggum calls Claude Code with different permission modes depending on the task:

| Task | Permission mode | Why |
|------|----------------|-----|
| Planning | `bypassPermissions` | Only reads input and writes the plan file |
| Implementation | `acceptEdits` | Auto-approves file edits, prompts for bash commands |
| Validation fixes | `acceptEdits` | Claude fixes code, same as implementation |
| Git commits | `bypassPermissions` | Only runs `git add` and `git commit` |

`acceptEdits` auto-approves file edits but still prompts for shell commands. This means Claude can write code freely but will ask before running anything in the terminal. `bypassPermissions` skips all prompts -- used only for commit and plan calls where the scope is tightly constrained.

### Setting up permissions with init

When you run `wiggum init`, it offers to create `.claude/settings.local.json` with pre-approved permissions for two categories:

**Verification & git (prompted first):**

These are the commands wiggum needs to run its core loop -- verification steps from your `.wiggumrc` and git operations for committing results.

| Preset | Permissions |
|--------|------------|
| All | `git add *`, `git commit *`, `git status`, `git diff *` |
| node/next/astro | `npm run *`, `npx *` |
| python | `ruff *`, `pytest`, `pytest *` |
| bash | `shellcheck *`, `bats *`, `chmod *` |

**Package manager (prompted separately):**

Allowing Claude to install dependencies is a bigger trust decision, so it's asked as a separate question.

| Preset | Permissions |
|--------|------------|
| node/next/astro | `npm install *`, `npm *` |
| python | `pip install *`, `pip *` |

You can decline either prompt. Without pre-approved permissions, Claude Code will prompt for approval on each command the first time it runs -- wiggum still works, it just pauses for confirmation.

### Manual permission setup

If you prefer to set permissions manually or already have a `.claude/settings.local.json`, add the rules you need:

```json
{
  "permissions": {
    "allow": [
      "Bash(git add *)",
      "Bash(git commit *)",
      "Bash(git status)",
      "Bash(git diff *)",
      "Bash(npm run *)",
      "Bash(npx *)"
    ]
  }
}
```

This file is per-machine (not committed to git). See the [Claude Code permissions docs](https://docs.anthropic.com/en/docs/claude-code/permissions) for the full rule syntax.

## Scheduling with cron

`wiggum run` is built for unattended use: feed it prompts, point `--session-file` at a stable path, and a scheduled job can pick up the same Claude session each time. The catch is the environment — cron runs your job with a **minimal, non-login shell**, so the three things below trip up almost every first attempt.

### The three gotchas

1. **`PATH` is bare.** Cron's `PATH` is typically just `/usr/bin:/bin`. Neither `wiggum` (`/usr/local/bin`) nor `claude` (`~/.local/bin`) is on it, and `node` (used by Claude Code plugin hooks) usually isn't either. Set `PATH` explicitly in the job.
2. **Authentication does not carry over.** An interactive `claude` login is stored in the macOS **Keychain**, which a cron process generally cannot read — `claude` will print `Not logged in · Please run /login` and exit. Provide credentials through the environment instead: either `ANTHROPIC_API_KEY` (API billing), or a long-lived token from `claude setup-token` (Claude subscription) exported in the job.
3. **macOS needs Full Disk Access for cron.** If the job silently does nothing, grant Full Disk Access to `/usr/sbin/cron` under *System Settings → Privacy & Security → Full Disk Access*.

### Recommended setup: a wrapper script

Cron one-liners and prompt quoting fight each other. Put the job in a small script so the environment lives in one place. A ready-to-edit wrapper ships with wiggum at [`examples/wiggum-cron.sh`](examples/wiggum-cron.sh) — copy it out and edit the three marked lines (PATH, auth, and your project path + prompt):

```bash
cp examples/wiggum-cron.sh ~/bin/wiggum-cron.sh
chmod +x ~/bin/wiggum-cron.sh
$EDITOR ~/bin/wiggum-cron.sh   # set PATH, auth, project dir, and the prompt

# Test in a clean environment FIRST — this is where PATH/auth bugs surface:
env -i HOME="$HOME" ~/bin/wiggum-cron.sh
```

The wrapper's core is just the environment fixes plus the call:

```bash
export PATH="/usr/local/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"
export ANTHROPIC_API_KEY="sk-ant-..."   # or a `claude setup-token` token
cd "$HOME/path/to/your/project"
wiggum run --session-file "$HOME/.wiggum-cron-session" \
  --effort high --permission-mode auto \
  "Summarize commits since the last run and append a bullet to STANDUP.md"
```

Then add it to your crontab (`crontab -e`). This runs at 9:00 AM daily and logs both Claude's responses (stdout) and wiggum's status (stderr):

```cron
0 9 * * * /Users/you/bin/wiggum-cron.sh >> /Users/you/wiggum-cron.log 2>&1
```

### Session patterns

- **Continue one session over time** (the follow-up workflow): reuse the same `--session-file` on every run so each job builds on the last. Reset occasionally with `--new-session` so the conversation doesn't grow without bound.
- **Independent runs**: omit `--session-file` (or always pass `--new-session`) so each run starts fresh.

### macOS: launchd alternative

On macOS, `launchd` is more reliable than cron for user agents — it survives reboots, handles logging, and doesn't need the Full Disk Access workaround. Create `~/Library/LaunchAgents/com.you.wiggum.plist` pointing `ProgramArguments` at the same wrapper script, set `StartCalendarInterval`, then `launchctl load` it. The wrapper script and its environment notes above apply unchanged.

## Output files

| Mode | Default output | Override flag |
|------|---------------|---------------|
| `plan` (TTY stdout) | `<dir>/<basename>_plan.md` | `--plan-file` |
| `plan` (piped stdout or stdin input) | stdout | `--plan-file` |
| `execute` | `<dir>/<basename>_summary.md` | `--summary-file` |
| `execute` (stdin) | `docs/stdin_summary.md` | `--summary-file` |
| `execute`/`plan`/`docs` | `<dir>/<basename>.log` | *(always created)* |
| `execute --background` | `<dir>/<basename>.pid`, `<dir>/<basename>.out` | *(always created)* |

The directory and basename are derived from the first input file. When reading from stdin, files default to `docs/`. The background sidecars (`.pid`, `.out`) sit next to the plan and are how `status`/`watch`/`kill` find a detached run; `watch` removes the `.pid` once the run finishes. For example:

```
wiggum plan docs/auth-issue.md
# produces: docs/auth-issue_plan.md

wiggum execute docs/auth-issue_plan.md
# produces: docs/auth-issue_plan_summary.md

echo "Fix auth bug" | wiggum plan
# produces: plan on stdout

echo "Fix auth bug" | wiggum plan --plan-file docs/plan.md
# produces: docs/plan.md
```

## Project structure

```
wiggum/
  wiggum.sh              CLI entry point (thin wrapper)
  lib/wiggum.sh          Core library (all logic, sourceable by tests)
  install.sh             macOS installer
  completions/           Bash and zsh shell completions
  examples/
    wiggum-cron.sh       Wrapper template for running `wiggum run` from cron
  test/
    wiggum.bats          Bats test suite
    run.sh               Test runner (shellcheck lint + bats)
  .wiggumrc              Self-hosting config (wiggum tests itself)
  .wiggumrc.example      Example config with comments
  CLAUDE.md              Project standards for Claude Code
  .claude/
    settings.local.json  Per-machine Claude Code permissions (not committed)
    skills/wiggum/
      SKILL.md           /wiggum slash command for Claude Code
```

## Development

Run the test suite (lint + unit tests):

```bash
./test/run.sh
```

This runs shellcheck on all shell scripts, then the Bats test suite. Requires `bats-core` and `shellcheck`:

```bash
brew install bats-core shellcheck
```

## Tips

- **Start small.** Use `--max-iterations 1` for a trial run to see how wiggum interprets your plan before committing to a longer run.
- **Review the plan before executing.** `wiggum plan` is cheap. Edit the generated plan to remove, reorder, or clarify tasks before feeding it to `execute`.
- **Use a branch.** Run wiggum on a feature branch so you can review the full diff before merging.
- **Keep issues focused.** One issue file per feature or bug works better than a single monolithic document.
- **Tune retries to your project.** If your test suite is flaky, increase `max_validation_retries`. If you're paying close attention to token costs, decrease it.
- **Use `--verbose` to debug.** Claude's output is suppressed by default. Pass `--verbose` to see what Claude is doing at each step.
- **Resume any step with `claude -r`.** Wiggum logs a Claude session ID for every step. Find the session ID in the `.log` file and resume it interactively: `claude -r <session-id>`. Useful for asking follow-up questions about what Claude did during a specific implementation or validation step.
- **Create a CLAUDE.md.** Claude Code automatically reads `CLAUDE.md` from the project root. Put your architecture, conventions, and coding standards there so Claude writes code that fits your project. `wiggum init` reminds you if one is missing.
- **Use `/wiggum` inside Claude Code.** If you're already in a Claude Code session and want to kick off the full loop without switching to the terminal, use `/wiggum <issue>`. It runs the same workflow natively.
