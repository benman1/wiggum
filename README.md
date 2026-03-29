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

The result: you kick off a run, walk away, and come back to a branch with a series of clean commits, a reconciled plan, and a summary of what happened.

## How it works

Wiggum has four commands that map to the natural workflow of software development.

### Init mode

```
wiggum init [preset]
```

Generates a `.wiggumrc` configuration file for the current project. If no preset is specified, wiggum inspects the directory for known project files (`package.json`, `next.config.ts`, `pyproject.toml`, etc.) and picks the matching preset automatically. If a `.wiggumrc` already exists, it asks before overwriting.

This is the recommended first step when adopting wiggum in a new project. The generated config provides sensible defaults for verification commands that you can then tune to your specific setup.

### Plan mode

```
wiggum plan <issue-files...>
```

Reads issue descriptions, specs, or requirements documents and produces a structured workplan. The plan is a markdown document with:

- Phases grouping related work
- Discrete tasks, each with a `[ ]` checkbox
- Acceptance criteria
- Dependencies between tasks

This is a read-only analysis step. It does not modify your codebase.

### Execute mode

```
wiggum execute <plan-files...>
```

Takes a workplan (typically one produced by `plan` mode, but any structured markdown will do) and implements it through three phases:

**Phase 1 -- Diagnostic & Status Sync**

Before writing any code, Wiggum compares the plan against the actual state of the repository. It marks tasks that are already complete, flags inaccuracies, and identifies what to do next. This sync is committed separately so implementation commits stay clean.

**Phase 2 -- Iterative Implementation**

For each iteration (controlled by `--iterations` or the config file):

1. **Implement** -- Claude reads the plan, picks the next discrete task, writes the code, and creates tests for new logic.
2. **Verify** -- The verification waterfall runs each configured step in order. On failure:
   - *Autofix steps* run the command once to let it self-correct (e.g., `ruff --fix`), then re-check. Only if the fix didn't resolve it does Claude get involved.
   - *Verify steps* capture the error output and ask Claude to fix the code directly.
   - This cycle repeats up to `max_validation_retries` times before moving on.
3. **Commit** -- Uncommitted changes are reviewed and committed with isolated, imperative-mood messages.

**Phase 3 -- Summary & Alignment**

After all iterations complete, Wiggum:

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
          |  Implement next step |  Phase 2 (x N iterations)
          +----------+-----------+
                     |
               +-----v------+
               |   Verify    |<--+
               +-----+------+   |
                     |           |
                fail |     pass  |
                     v           |
              +------+------+   |
              | Autofix /   +---+
              | Claude fix  |  (up to max_validation_retries)
              +-------------+
                     |
               +-----v------+
               |   Commit    |
               +-----+------+
                     |
            +--------v---------+
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

This copies `wiggum.sh` and `lib/wiggum.sh` to `/usr/local/lib/wiggum/`, symlinks `/usr/local/bin/wiggum` to the entry point, and seeds `~/.wiggumrc` from the example config if you don't have one yet. May prompt for sudo.

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

If no preset is given, wiggum inspects the current directory and picks the best match. The generated `.wiggumrc` is a starting point -- edit it to match your actual scripts.

After creating the `.wiggumrc`, init offers to set up Claude Code permissions (see [Permissions](#permissions) below) and reminds you to create a `CLAUDE.md` if one doesn't exist.

### Creating a plan

```bash
# From a single issue file
wiggum plan issues/login-bug.md

# From multiple spec files
wiggum plan docs/spec.md docs/requirements.md

# With a custom output path
wiggum plan issues/login-bug.md --plan-file docs/login_plan.md
```

Default output: `<input-basename>_plan.md` in the same directory as the first input file.

### Executing a plan

```bash
# Execute with defaults (3 iterations)
wiggum execute docs/login_plan.md

# More iterations for larger plans
wiggum execute docs/plan.md --iterations 10

# Custom summary location
wiggum execute docs/plan.md --summary-file reports/run1_summary.md

# Execute and update README when done
wiggum execute docs/plan.md --update-docs README.md

# Update multiple docs after execution
wiggum execute docs/plan.md --update-docs README.md,docs/API.md

# Multiple context files (plan + supporting docs)
wiggum execute docs/plan.md docs/api_spec.md docs/schema.csv
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
    wiggum execute "$plan" --iterations 3
done
```

**Plan all issues in a directory.** Bash expands globs before wiggum sees them:

```bash
wiggum plan issues/*.md --plan-file docs/backlog_plan.md
```

**Resume a partially-completed plan.** If a previous run only finished some tasks, just run execute again. Phase 1 syncs the checkboxes against the repo, so Claude picks up where it left off:

```bash
# First run: completes 4 of 10 tasks
wiggum execute docs/plan.md --iterations 4

# Second run: starts from task 5
wiggum execute docs/plan.md --iterations 6
```

**Pass supporting context alongside a plan.** Extra files (specs, schemas, PDFs) are passed to Claude as context but aren't treated as the plan:

```bash
wiggum execute docs/plan.md docs/api_spec.md docs/schema.csv
```

### Command reference

```
wiggum <mode> [files...] [options]

Modes:
  init        Generate a .wiggumrc for the current project
  plan        Create a workplan from issue/spec files
  execute     Implement a workplan with iterative validation
  docs        Update documentation from input files

Options:
  --plan-file <path>       Output path for the plan (plan mode)
  --summary-file <path>    Output path for the summary (execute mode)
  --iterations <n>         Number of implementation iterations (execute mode, default: 3)
  --update-docs <files>    Comma-separated doc files to update after execution (execute mode)
  --verbose                Pass --verbose to Claude Code for detailed output
  -i <files...>            Input files (docs mode)
  -o <files...>            Output doc files to update (docs mode)
  -h, --help               Show help
```

### Verbose mode

Pass `--verbose` to see detailed output from Claude Code, including API calls, tool usage, and token counts:

```bash
wiggum execute docs/plan.md --verbose
```

This is useful for debugging or understanding what Claude is doing at each step. The flag is forwarded to every `claude` invocation wiggum makes.

## Configuration

Wiggum looks for a `.wiggumrc` file, first in the current directory, then in `$HOME`. The config uses a simple `key = value` format.

### Config keys

| Key | Description | Default |
|-----|-------------|---------|
| `verify` | A shell command to run as a verification step. Fails are sent to Claude for fixing. Multiple lines define an ordered waterfall. | *(none)* |
| `autofix` | Like `verify`, but the command is run once first to let it self-correct (e.g. linters with `--fix`). Only escalates to Claude if it still fails after autofix. | *(none)* |
| `iterations` | Number of implementation iterations per run. | `3` |
| `max_validation_retries` | Max times the validation cycle retries before giving up. | `5` |

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

### Example configs

**TypeScript / Node.js project:**

```
# .wiggumrc
verify = npm run type-check
verify = npm test
verify = npm run build
autofix = npm run lint -- --fix

iterations = 5
```

**Python project:**

```
# .wiggumrc
autofix = ruff format app tests && ruff check --fix app tests
verify = pytest

iterations = 3
max_validation_retries = 3
```

**Astro / static site with smoke test:**

```
# .wiggumrc
verify = npm run type-check
verify = npm test
verify = npm run build
verify = ./smoke.sh
autofix = npm run format
```

**Next.js project:**

```
# .wiggumrc
verify = npm run type-check
verify = npm test
verify = npm run build
autofix = npm run lint -- --fix

iterations = 3
```

**Minimal (no verification):**

```
# .wiggumrc
iterations = 2
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

## Output files

| Mode | Default output | Override flag |
|------|---------------|---------------|
| `plan` | `<dir>/<basename>_plan.md` | `--plan-file` |
| `execute` | `<dir>/<basename>_summary.md` | `--summary-file` |

The directory and basename are derived from the first input file. For example:

```
wiggum plan docs/auth-issue.md
# produces: docs/auth-issue_plan.md

wiggum execute docs/auth-issue_plan.md
# produces: docs/auth-issue_plan_summary.md
```

## Project structure

```
wiggum/
  wiggum.sh              CLI entry point (thin wrapper)
  lib/wiggum.sh          Core library (all logic, sourceable by tests)
  install.sh             macOS installer
  test/
    wiggum.bats          Bats test suite
    run.sh               Test runner (shellcheck lint + bats)
  .wiggumrc              Self-hosting config (wiggum tests itself)
  .wiggumrc.example      Example config with comments
  CLAUDE.md              Project standards for Claude Code
  .claude/
    settings.local.json  Per-machine Claude Code permissions (not committed)
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

- **Start small.** Use `--iterations 1` for a trial run to see how wiggum interprets your plan before committing to a longer run.
- **Review the plan before executing.** `wiggum plan` is cheap. Edit the generated plan to remove, reorder, or clarify tasks before feeding it to `execute`.
- **Use a branch.** Run wiggum on a feature branch so you can review the full diff before merging.
- **Keep issues focused.** One issue file per feature or bug works better than a single monolithic document.
- **Tune retries to your project.** If your test suite is flaky, increase `max_validation_retries`. If you're paying close attention to token costs, decrease it.
- **Use `--verbose` to debug.** If wiggum isn't doing what you expect, `--verbose` shows exactly what Claude is doing at each step.
- **Create a CLAUDE.md.** Claude Code automatically reads `CLAUDE.md` from the project root. Put your architecture, conventions, and coding standards there so Claude writes code that fits your project. `wiggum init` reminds you if one is missing.
