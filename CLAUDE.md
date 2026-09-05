# Wiggum -- Project Standards

Wiggum is a **self-driving agent loop** that orchestrates Claude Code to turn issue descriptions into working, verified code. It plans, implements, verifies, self-heals, and commits -- all from a single shell command.

## How we work here (dogfood wiggum)

We use the tool on its own codebase -- but the test is the **shape of the work, not its size or its file count**.

**Drive it through wiggum** when the change needs the loop: several interdependent steps where each has to be verified before the next one can be written, or where you cannot predict what the verify suite will say until you try. That is what wiggum is for.

**Edit it directly** when you can hold the whole change in your head and a single `./test/run.sh` tells you whether it is right -- even when it spans `lib/` + tests + docs + the skill. Prompt text, a new mode that copies the shape of an existing one, a doc sweep across several surfaces: all direct-edit work.

The overhead is the reason. Wiggum runs a full cycle **per task** -- a fresh `claude` session, the entire verify suite, and a git commit. On a change that is really one edit, that dwarfs the work and fragments one logical change into a string of noisy commits. Reach for wiggum when the loop earns its cost, and say so plainly when it does not; "it is a new feature" is not on its own a reason.

Use the `/wiggum` skill — it is model-invocable, so invoke it to load the orchestration playbook (plan, run, monitor, wait, detect-blocked, kill, chain) and drive the run. Equivalently, run the `wiggum` CLI directly:

1. **Plan:** `wiggum plan "<issue or description>"` (or `wiggum plan <issue-file>`) -> produces `docs/<slug>_plan.md`. Read and adjust the plan before running it.
2. **Execute:** `wiggum execute docs/<slug>_plan.md`. Add `--background` to supervise with `wiggum status|watch|kill <plan>`; use `wiggum chain <plan...>` for work too large for one plan.
3. Let the loop plan -> implement -> verify (this repo's `.wiggumrc`: shellcheck + bats) -> commit. Review the resulting commits and `docs/<slug>_summary.md`.

Always direct, never planned: one-line fixes, doc and comment tweaks, and the supervision of wiggum runs themselves (status/watch/kill/top/chain).

If a wiggum run does fragment one logical change across several commits, squash them (`git reset --soft <base>`) into one before finishing -- see the commit rules below.

## Tech Stack

- **Language:** Bash (4+)
- **Core:** Single library (`lib/wiggum.sh`) sourced by a thin CLI (`wiggum.sh`)
- **Testing:** Bats (bats-core)
- **Linting:** ShellCheck
- **External dependency:** Claude Code CLI (`claude`)

## 1. Architecture

- `lib/wiggum.sh` contains all logic as pure functions. It is sourced, never executed directly.
- `wiggum.sh` is the CLI entry point -- it should stay under 30 lines.
- `wiggum_reset()` clears all global state. Tests call it before each run.
- `run_claude()` wraps all `claude` invocations. Never call `claude` directly.
- Configuration is loaded from `.wiggumrc` (current directory, then `$HOME`).
- Input files must be inside the project directory. External paths are rejected.

## 2. Code Quality

- All scripts run under `set -euo pipefail`.
- ShellCheck must pass with zero warnings on `wiggum.sh`, `lib/wiggum.sh`, and `install.sh`.
- Prefer functions over inline logic. Keep functions focused and testable.
- Use `>&2` for error and warning output. Use stdout for user-facing messages.
- Quote all variable expansions. Use `${arr[@]+"${arr[@]}"}` for potentially empty arrays under `set -u`.

## 3. Version Control (Git)

- Use short, single-line, imperative commit messages.
- No prefixes (`feat:`, `fix:`), no `Co-Authored-By` trailers, no multi-line messages.
- One commit per logically distinct change.
- **Commit as soon as a change passes the full suite (`./test/run.sh`) — don't wait to be asked.** When work spans several files (lib + tests + docs + skill), stage and commit them together as the one logical change.

## 4. Testing

- **Lint:** `shellcheck -s bash wiggum.sh lib/wiggum.sh install.sh`
- **Unit tests:** `bats test/wiggum.bats`
- **Full suite:** `./test/run.sh` (runs lint then tests)
- Every new function or behavior needs a Bats test.
- Tests must be self-contained -- each test gets a fresh temp directory and calls `wiggum_reset`.
- Mock `claude` in tests (stub it as a no-op function in `setup()`).
- Test behavior, not implementation. Assert on outputs, exit codes, and side effects (files created, state set).

## 5. Claude Prompt Conventions

These matter because wiggum's prompts are its primary interface with Claude Code:

- Always name the plan files explicitly: "The workplan is defined ONLY in: `<files>`".
- Always include: "You may read README.md and other project documentation for context, but they are not the plan."
- Commit prompts must say: "Do not ask for confirmation -- just do it."
- Commit prompts must say: "DO NOT include any trailers, footers, or attributions."
- Commit prompts must cover "modified and untracked files" (not just "modified").
- Use fresh sessions (`-p` without `-c`) for independent tasks like commits.
- Use `-c` (continue) only where Claude genuinely needs prior context (e.g., implementation -> validation fix).
- **Every prompt helper is on a byte budget.** The plan prompt is assembled from nine
  `prompt_*` helpers and sent on every `wiggum plan` call, so words there cost tokens
  on every run forever. Two Bats tests guard the total (`run_plan: feature-request
  prompt stays within budget`, and the defect counterpart). When one fails, cut the
  helper before raising the ceiling -- a raise is the last resort, and a second raise
  means the helpers need consolidating instead.

## 6. Writing: first draft, then cut

Applies to prompt text, code comments, commit messages, docs, and answers to the user.

**Treat the first version as a first draft.** Keep only the sentences carrying unique
information, then rewrite the survivors. Expect to cut about half: a first pass
typically makes the same point in the lead, again in the detail, and again in the
summary, and only one of those earns its place.

**Cut redundancy, never content.** A sentence goes if it repeats a point already made,
restates the heading above it, hedges a claim the next sentence makes plainly, or
announces what the text is about to do. A sentence stays if it carries a number, a file
path, a trade-off, a risk, an open question, or a thing the reader must decide. A short
text that drops a caveat is worse than a long one that keeps it.

**In prompts, the same rule has teeth.** An instruction Claude already follows from a
neighbouring sentence is pure cost. Name the failure the instruction prevents once, in
the shortest form that still forbids it, and delete the restatement.

## 7. Current Work

- See `docs/` for plans and issues.
