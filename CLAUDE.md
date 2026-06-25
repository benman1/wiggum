# Wiggum -- Project Standards

Wiggum is a **self-driving agent loop** that orchestrates Claude Code to turn issue descriptions into working, verified code. It plans, implements, verifies, self-heals, and commits -- all from a single shell command.

## How we work here (dogfood wiggum)

For any non-trivial change -- a new feature, a multi-file refactor, a bug fix that touches several functions, anything beyond a quick edit -- drive it through wiggum itself instead of hand-coding it ad hoc. We use the tool on its own codebase.

Use the `/wiggum` skill — it is model-invocable, so invoke it to load the orchestration playbook (plan, run, monitor, wait, detect-blocked, kill, chain) and drive the run. Equivalently, run the `wiggum` CLI directly:

1. **Plan:** `wiggum plan "<issue or description>"` (or `wiggum plan <issue-file>`) -> produces `docs/<slug>_plan.md`. Read and adjust the plan before running it.
2. **Execute:** `wiggum execute docs/<slug>_plan.md`. Add `--background` to supervise with `wiggum status|watch|kill <plan>`; use `wiggum chain <plan...>` for work too large for one plan.
3. Let the loop plan -> implement -> verify (this repo's `.wiggumrc`: shellcheck + bats) -> commit. Review the resulting commits and `docs/<slug>_summary.md`.

Do directly (no plan needed): trivial one-line fixes, doc/comment tweaks, and the supervision of wiggum runs themselves (status/watch/kill/chain).

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

## 6. Current Work

- See `docs/` for plans and issues.
