#!/usr/bin/env bash
# wiggum core library — sourced by the CLI and by tests
# Do not execute directly; source this file instead.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "Error: lib/wiggum.sh is a library and must be sourced, not executed directly." >&2
    exit 1
fi

VERSION="0.1.0"

# ── Exit codes ──────────────────────────────────────────────────────────────

export EXIT_BAD_ARGS=1
export EXIT_NO_CONFIG=2
export EXIT_VALIDATION_FAILED=3
export EXIT_CLAUDE_FAILED=4

# ── State (reset by wiggum_reset for testing) ───────────────────────────────

wiggum_reset() {
    MODE=""
    FILES=()
    PLAN_FILE=""
    SUMMARY_FILE=""
    ITERATIONS=3
    MAX_VALIDATION_RETRIES=5
    INIT_PRESET=""
    VERIFY_STEPS=()
    VERBOSE=false
    CLAUDE_EXTRA_ARGS=()
    CLI_ITERATIONS=""
    CLI_MAX_RETRIES=""
    UPDATE_DOCS=()
    DOCS_INPUT=()
    DOCS_OUTPUT=()
    WIGGUM_LOG_FILE=""
    STDIN_FILE=""
    CLI_PLAN_FILE=""
}

wiggum_reset

# ── Config loading ───────────────────────────────────────────────────────────

find_config() {
    if [[ -f ".wiggumrc" ]]; then
        echo ".wiggumrc"
    elif [[ -f "$HOME/.wiggumrc" ]]; then
        echo "$HOME/.wiggumrc"
    fi
}

load_config_from() {
    local config_file="$1"

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        local key="${line%%=*}"
        local value="${line#*=}"
        key="$(echo "$key" | xargs)"
        value="$(echo "$value" | xargs)"

        case "$key" in
            verify|autofix|iterations|max_validation_retries)
                echo "$key=$value"
                ;;
            *)
                echo "Warning: unknown config key '$key'" >&2
                ;;
        esac
    done < "$config_file"
}

apply_config() {
    local line
    while IFS= read -r line; do
        local key="${line%%=*}"
        local value="${line#*=}"
        case "$key" in
            verify)
                VERIFY_STEPS+=("$value")
                ;;
            autofix)
                VERIFY_STEPS+=("autofix:$value")
                ;;
            iterations)
                if [[ -z "$CLI_ITERATIONS" ]]; then
                    ITERATIONS="$value"
                fi
                ;;
            max_validation_retries)
                if [[ -z "$CLI_MAX_RETRIES" ]]; then
                    MAX_VALIDATION_RETRIES="$value"
                fi
                ;;
        esac
    done
}

load_config() {
    local config_file
    config_file="$(find_config)"

    if [[ -z "$config_file" ]]; then
        echo "No .wiggumrc found (checked ./ and ~/). Using defaults."
        return
    fi

    echo "Loading config from $config_file"
    apply_config < <(load_config_from "$config_file")
}

# ── Argument parsing ─────────────────────────────────────────────────────────

usage() {
    local cmd="${1:-}"

    case "$cmd" in
        init)
            cat <<EOF
wiggum init - Generate a .wiggumrc for a standard project setup

Usage:
  wiggum init [preset]

Presets:
  node      Node.js project (type-check, test, build, lint)
  next      Next.js project (type-check, test, build, lint)
  python    Python project (ruff, pytest)
  astro     Astro project (type-check, test, build, format)
  bash      Bash project (shellcheck, bats)
  (none)    Auto-detect from project files

Also offers to set up Claude Code permissions in .claude/settings.local.json
and reminds you to create a CLAUDE.md if one is missing.
EOF
            ;;
        plan)
            cat <<EOF
wiggum plan - Create a workplan from issue/spec files

Usage:
  wiggum plan <files...> [options]
  wiggum plan [options] < description.txt
  echo "description" | wiggum plan [options]

Options:
  --plan-file <path>   Output path for the plan (default: <base>_plan.md)
  --verbose            Pass --verbose to Claude Code

Reads issue descriptions, specs, or requirements and produces a structured
markdown workplan with phases, tasks, acceptance criteria, and dependencies.
Does not modify your codebase.

When no files are given, reads from stdin.

Examples:
  wiggum plan issues/login-bug.md
  wiggum plan issues/*.md --plan-file docs/sprint_plan.md
  echo "Add dark mode toggle" | wiggum plan
  wiggum plan <<< "Fix the login timeout bug"
EOF
            ;;
        execute)
            cat <<EOF
wiggum execute - Implement a workplan with iterative validation

Usage:
  wiggum execute <files...> [options]
  wiggum execute [options] < plan.md
  wiggum plan issue.md | wiggum execute

Options:
  --iterations <n>       Number of implementation iterations (default: 3)
  --summary-file <path>  Output path for the summary (default: <base>_summary.md)
  --update-docs <files>  Comma-separated doc files to update after execution
  --verbose              Pass --verbose to Claude Code

Phases:
  1. Diagnostic & Status Sync - reconcile plan against repo state
  2. Iterative Implementation - implement, verify, commit (x N iterations)
  3. Summary & Alignment     - update plan checkboxes, write summary
  4. Documentation Update     - update docs (if --update-docs is set)

When no files are given, reads from stdin.

Examples:
  wiggum execute docs/plan.md
  wiggum execute docs/plan.md --iterations 5 --update-docs README.md
  wiggum plan issue.md | wiggum execute
  echo "Add dark mode" | wiggum plan | wiggum execute
EOF
            ;;
        docs)
            cat <<EOF
wiggum docs - Update documentation from input files

Usage:
  wiggum docs -i <input...> -o <output...>

Options:
  -i <files...>   Input files (summaries, plans, changelogs, code)
  -o <files...>   Output doc files to update
  --verbose       Pass --verbose to Claude Code

Reads input files for context, then updates each output file to reflect
the changes. Preserves existing structure and style.

Examples:
  wiggum docs -i docs/summary.md -o README.md
  wiggum docs -i docs/plan.md docs/summary.md -o README.md docs/API.md
EOF
            ;;
        check)
            cat <<EOF
wiggum check - Run verification waterfall and fix issues

Usage:
  wiggum check [options]

Options:
  --verbose   Pass --verbose to Claude Code

Runs the verify/autofix steps from .wiggumrc against the current codebase.
When a step fails, Claude is asked to fix the issue. Repeats up to
max_validation_retries times. Does not implement new features or commit.

Useful after manual edits or before committing to ensure everything passes.

Examples:
  wiggum check
  wiggum check --verbose
EOF
            ;;
        *)
            cat <<EOF
wiggum $VERSION - Self-driving agent loop

Usage:
  wiggum <command> [files...] [options]
  command | wiggum <command> [options]
  wiggum help <command>

Commands:
  init      Generate a .wiggumrc for a standard project setup
  plan      Create a workplan from issue/spec files
  execute   Implement a workplan with iterative validation
  check     Run verification waterfall and fix issues
  docs      Update documentation from input files

Run 'wiggum help <command>' for details on a specific command.

Options:
  --verbose   Pass --verbose to Claude Code for detailed output
  -h, --help  Show this help

Configuration:
  Place a .wiggumrc file in the current directory or \$HOME.
  See README.md for config format.
EOF
            ;;
    esac
}

parse_args() {
    if [[ $# -eq 0 ]]; then
        usage
        return "$EXIT_BAD_ARGS"
    fi

    MODE="$1"
    shift

    if [[ "$MODE" == "-h" || "$MODE" == "--help" ]]; then
        usage
        return 0
    fi

    if [[ "$MODE" == "help" ]]; then
        usage "${1:-}"
        return 0
    fi

    if [[ "$MODE" != "plan" && "$MODE" != "execute" && "$MODE" != "init" && "$MODE" != "docs" && "$MODE" != "check" ]]; then
        echo "Error: unknown mode '$MODE'. Use 'plan', 'execute', 'check', 'docs', or 'init'." >&2
        return "$EXIT_BAD_ARGS"
    fi

    if [[ "$MODE" == "init" ]]; then
        if [[ $# -gt 0 && ! "$1" == -* ]]; then
            INIT_PRESET="$1"
            shift
        fi
        return 0
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --plan-file)
                PLAN_FILE="$2"
                CLI_PLAN_FILE="$2"
                shift 2
                ;;
            --summary-file)
                SUMMARY_FILE="$2"
                shift 2
                ;;
            --iterations)
                ITERATIONS="$2"
                CLI_ITERATIONS="$2"
                shift 2
                ;;
            --verbose)
                export VERBOSE=true
                CLAUDE_EXTRA_ARGS+=("--verbose")
                shift
                ;;
            --update-docs)
                IFS=',' read -ra UPDATE_DOCS <<< "$2"
                shift 2
                ;;
            -i)
                shift
                while [[ $# -gt 0 && "$1" != -* ]]; do
                    DOCS_INPUT+=("$1")
                    shift
                done
                ;;
            -o)
                shift
                while [[ $# -gt 0 && "$1" != -* ]]; do
                    DOCS_OUTPUT+=("$1")
                    shift
                done
                ;;
            -h|--help)
                usage
                return 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                echo "Error: unknown option '$1'" >&2
                return "$EXIT_BAD_ARGS"
                ;;
            *)
                FILES+=("$1")
                shift
                ;;
        esac
    done

    # remaining args after -- are all files
    while [[ $# -gt 0 ]]; do
        FILES+=("$1")
        shift
    done

    # check mode needs no input files
    if [[ "$MODE" == "check" ]]; then
        return 0
    fi

    # docs mode uses -i/-o instead of positional files
    if [[ "$MODE" == "docs" ]]; then
        if [[ ${#DOCS_INPUT[@]} -eq 0 ]]; then
            echo "Error: docs mode requires -i <input files>." >&2
            return "$EXIT_BAD_ARGS"
        fi
        if [[ ${#DOCS_OUTPUT[@]} -eq 0 ]]; then
            echo "Error: docs mode requires -o <output doc files>." >&2
            return "$EXIT_BAD_ARGS"
        fi
        return 0
    fi

    if [[ ${#FILES[@]} -eq 0 ]]; then
        if [[ -t 0 ]]; then
            echo "Error: no input files specified (or pipe text via stdin)." >&2
            return "$EXIT_BAD_ARGS"
        fi
        STDIN_FILE="$(mktemp "${TMPDIR:-/tmp}/wiggum_stdin.XXXXXX")"
        cat > "$STDIN_FILE"
        if [[ ! -s "$STDIN_FILE" ]]; then
            rm -f "$STDIN_FILE"
            echo "Error: stdin was empty." >&2
            return "$EXIT_BAD_ARGS"
        fi
        FILES+=("$STDIN_FILE")
    fi

    local work_dir
    work_dir="$(pwd)"
    for f in "${FILES[@]}"; do
        # stdin temp file is outside the project — skip validation for it
        if [[ "$f" == "$STDIN_FILE" ]]; then
            continue
        fi
        if [[ ! -f "$f" ]]; then
            echo "Error: file not found: $f" >&2
            return "$EXIT_BAD_ARGS"
        fi
        local abs_path
        abs_path="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
        if [[ "$abs_path" != "$work_dir"/* ]]; then
            echo "Error: file is outside the project directory: $f" >&2
            echo "Copy it into the repo first, e.g.: cp $f docs/" >&2
            return "$EXIT_BAD_ARGS"
        fi
    done
}

# ── Output filenames ─────────────────────────────────────────────────────────

derive_output_file() {
    local mode="$1"
    local base_file="$2"
    local current_value="${3:-}"

    if [[ -n "$current_value" ]]; then
        echo "$current_value"
        return
    fi

    local dir
    dir="$(dirname "$base_file")"
    local name
    name="$(basename "$base_file" .md)"

    case "$mode" in
        plan)    echo "${dir}/${name}_plan.md" ;;
        execute) echo "${dir}/${name}_summary.md" ;;
    esac
}

# ── Init ─────────────────────────────────────────────────────────────────────

detect_preset() {
    if [[ -f "next.config.js" || -f "next.config.ts" || -f "next.config.mjs" ]]; then
        echo "next"
    elif [[ -f "astro.config.mjs" || -f "astro.config.ts" ]]; then
        echo "astro"
    elif [[ -f "pyproject.toml" || -f "setup.py" || -f "requirements.txt" ]]; then
        echo "python"
    elif [[ -f "package.json" ]]; then
        echo "node"
    elif [[ -f ".wiggumrc" ]] && grep -q 'shellcheck\|bats' .wiggumrc 2>/dev/null; then
        echo "bash"
    elif [[ -f ".shellcheckrc" ]] || [[ -d "test" && -f "test/run.sh" ]]; then
        echo "bash"
    else
        echo ""
    fi
}

generate_rc() {
    local preset="$1"

    case "$preset" in
        node)
            cat <<'RCEOF'
# .wiggumrc - Node.js project
verify = npm run type-check
verify = npm test
verify = npm run build
autofix = npm run lint -- --fix

iterations = 3
max_validation_retries = 5
RCEOF
            ;;
        next)
            cat <<'RCEOF'
# .wiggumrc - Next.js project
verify = npm run type-check
verify = npm test
verify = npm run build
autofix = npm run lint -- --fix

iterations = 3
max_validation_retries = 5
RCEOF
            ;;
        python)
            cat <<'RCEOF'
# .wiggumrc - Python project
autofix = ruff format . && ruff check --fix .
verify = pytest

iterations = 3
max_validation_retries = 5
RCEOF
            ;;
        astro)
            cat <<'RCEOF'
# .wiggumrc - Astro project
verify = npm run type-check
verify = npm test
verify = npm run build
autofix = npx prettier --write .

iterations = 3
max_validation_retries = 5
RCEOF
            ;;
        bash)
            cat <<'RCEOF'
# .wiggumrc - Bash project
verify = shellcheck -s bash *.sh **/*.sh
verify = bats test/

iterations = 3
max_validation_retries = 5
RCEOF
            ;;
        *)
            echo "Error: unknown preset '$preset'." >&2
            echo "Available presets: node, next, python, astro, bash" >&2
            return "$EXIT_BAD_ARGS"
            ;;
    esac
}

run_init() {
    local preset="$INIT_PRESET"

    if [[ -z "$preset" ]]; then
        preset=$(detect_preset)
        if [[ -z "$preset" ]]; then
            echo "Could not auto-detect project type." >&2
            echo "Specify a preset: wiggum init <node|next|python|astro>" >&2
            return "$EXIT_BAD_ARGS"
        fi
        echo "Detected project type: $preset"
    fi

    if [[ -f ".wiggumrc" ]]; then
        echo "A .wiggumrc already exists in this directory. Overwrite? [y/N]"
        read -r answer
        if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
            echo "Aborted."
            return 0
        fi
    fi

    generate_rc "$preset" > .wiggumrc
    echo "Created .wiggumrc ($preset preset)"

    # Offer to set up Claude Code permissions for verification commands
    setup_claude_permissions "$preset"

    # Install the /wiggum skill for Claude Code
    setup_wiggum_skill

    if [[ ! -f "CLAUDE.md" ]]; then
        echo ""
        echo "Tip: Create a CLAUDE.md file with project standards, architecture, and"
        echo "conventions. Wiggum passes it to Claude Code automatically, which helps"
        echo "Claude write code that fits your project. See the wiggum README for details."
    fi
}

setup_claude_permissions() {
    local preset="$1"
    local settings_file=".claude/settings.local.json"

    # Build the allow list based on preset
    local rules=()
    rules+=("Bash(git add *)")
    rules+=("Bash(git commit *)")
    rules+=("Bash(git status)")
    rules+=("Bash(git diff *)")

    # Extra rules for package manager access (opt-in)
    local extra_rules=()

    case "$preset" in
        node|next)
            rules+=("Bash(npm run *)")
            rules+=("Bash(npx *)")
            extra_rules+=("Bash(npm install *)")
            extra_rules+=("Bash(npm *)")
            ;;
        python)
            rules+=("Bash(ruff *)")
            rules+=("Bash(pytest *)")
            rules+=("Bash(pytest)")
            extra_rules+=("Bash(pip install *)")
            extra_rules+=("Bash(pip *)")
            ;;
        astro)
            rules+=("Bash(npm run *)")
            rules+=("Bash(npx *)")
            extra_rules+=("Bash(npm install *)")
            extra_rules+=("Bash(npm *)")
            ;;
        bash)
            rules+=("Bash(shellcheck *)")
            rules+=("Bash(bats *)")
            rules+=("Bash(chmod *)")
            ;;
    esac

    echo ""
    echo "Wiggum needs Claude Code permissions to run verification and git commands."
    echo "The following rules would be added to $settings_file:"
    echo ""
    for rule in "${rules[@]}"; do
        echo "  allow: $rule"
    done
    echo ""
    echo "Add these permissions? [y/N]"
    read -r answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        echo "Skipped. You can add permissions manually or approve them when prompted."
        return 0
    fi

    # Ask about package manager permissions separately
    if [[ ${#extra_rules[@]} -gt 0 ]]; then
        echo ""
        echo "Also allow package manager commands? (lets Claude install dependencies)"
        for rule in "${extra_rules[@]}"; do
            echo "  allow: $rule"
        done
        echo ""
        echo "Allow package manager access? [y/N]"
        read -r answer
        if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
            rules+=("${extra_rules[@]}")
        fi
    fi

    # Build JSON
    mkdir -p .claude

    if [[ -f "$settings_file" ]]; then
        # Merge new rules into existing file, preserving all other keys
        echo "Updating $settings_file"
        local new_rules_json="["
        local first=true
        for rule in "${rules[@]}"; do
            if [[ "$first" == "true" ]]; then
                first=false
            else
                new_rules_json="$new_rules_json,"
            fi
            new_rules_json="$new_rules_json\"$rule\""
        done
        new_rules_json="$new_rules_json]"

        python3 -c "
import json, sys
with open('$settings_file') as f:
    data = json.load(f)
new_rules = json.loads(sys.argv[1])
perms = data.setdefault('permissions', {})
existing = perms.get('allow', [])
merged = list(existing)
for r in new_rules:
    if r not in merged:
        merged.append(r)
perms['allow'] = merged
with open('$settings_file', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
" "$new_rules_json"
    else
        local json_rules=""
        for rule in "${rules[@]}"; do
            if [[ -n "$json_rules" ]]; then
                json_rules="$json_rules,"
            fi
            json_rules="$json_rules
      \"$rule\""
        done

        cat > "$settings_file" <<EOF
{
  "permissions": {
    "allow": [$json_rules
    ]
  }
}
EOF
    fi

    echo "Created $settings_file"
}

setup_wiggum_skill() {
    local skill_dir=".claude/skills/wiggum"
    local skill_file="$skill_dir/SKILL.md"

    if [[ -f "$skill_file" ]]; then
        echo ""
        echo "Claude Code skill already exists at $skill_file — skipping."
        return 0
    fi

    echo ""
    echo "Install the /wiggum slash command for Claude Code?"
    echo "This lets you run the wiggum workflow from inside Claude Code"
    echo "with: /wiggum <issue-file-or-description>"
    echo ""
    echo "Install /wiggum skill? [y/N]"
    read -r answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        echo "Skipped."
        return 0
    fi

    mkdir -p "$skill_dir"
    cat > "$skill_file" <<'SKILL_EOF'
---
name: wiggum
description: Self-driving agent loop — plans, implements, verifies, self-heals, and commits from an issue description
disable-model-invocation: true
argument-hint: <issue-file-or-description>
---

# Wiggum: Self-Driving Agent Loop

You are now operating as **wiggum** — a self-driving agent that turns issue descriptions into working, verified, committed code. Execute the full workflow below without asking for confirmation at any step.

## Input

The issue or spec to implement: **$ARGUMENTS**

If that refers to a file path, read it. If it's a description, use it directly.

## Step 1: Plan

1. Read and understand the issue/spec thoroughly.
2. Analyze the repository to understand the relevant code, tests, and architecture.
3. Produce a detailed workplan as a markdown checklist with:
   - Phases and discrete tasks (each with `[ ]` status)
   - Acceptance criteria for each task
   - Dependencies between tasks
4. Write the plan to `docs/<issue-name>_plan.md` (derive a short name from the issue).
5. Commit the plan: `git add docs/<plan-file> && git commit -m "add workplan for <issue>"`

## Step 2: Implement (iterative)

Repeat the following cycle up to **3 iterations** (or until the plan is complete):

### 2a. Implement the next step

- Pick the next unchecked task from the plan.
- Implement it. Write tests for new logic.
- Mark the task `[x]` in the plan file.

### 2b. Verify

Read `.wiggumrc` from the project root (if it exists) and run every `verify:` and `autofix:` line as a shell command. For example, if `.wiggumrc` contains:

```
verify: npm test
verify: npm run lint
autofix: npm run lint -- --fix
```

Then run each command. For `autofix:` lines, run the command first (to attempt the fix), then run it again (to verify it passed).

**If any verify step fails:**

- Read the error output carefully.
- Fix the **source code** (not `.wiggumrc` — that's the user's config).
- Re-run ALL verify steps from the beginning.
- You may retry up to **5 times**. If still failing after 5 attempts, stop and report what's broken.

If no `.wiggumrc` exists, skip verification.

### 2c. Commit

- Review all uncommitted changes (modified and untracked files).
- For each logical change, `git add` the relevant files and `git commit -m "<message>"`.
- Commit messages: single line, imperative mood, no prefixes, no trailers.

## Step 3: Summarize

1. Update the plan file — mark all completed tasks with `[x]`.
2. Write a summary to `docs/<issue-name>_summary.md` covering:
   - What was implemented
   - What was deferred (if anything)
   - Issues encountered
   - Verification results
3. Commit the summary and updated plan.

## Rules

- **Never ask for confirmation** — just execute.
- **Commit messages**: single line, imperative, no `feat:`/`fix:` prefixes, no `Co-Authored-By` trailers.
- **Verification failures**: fix source code, not `.wiggumrc`. If the command itself is wrong (e.g., wrong script name), tell the user to update `.wiggumrc`.
- **Stay focused**: implement what the issue asks for. Don't refactor surrounding code, add docstrings, or make "improvements" beyond scope.
- **Plan files are the source of truth**: always reference and update the plan as you work.
SKILL_EOF

    echo "Created $skill_file"
    echo "You can now use /wiggum inside Claude Code."
}

# ── Logging ──────────────────────────────────────────────────────────────────

log_init() {
    local base_file="$1"
    local dir
    dir="$(dirname "$base_file")"
    local name
    name="$(basename "$base_file" .md)"
    WIGGUM_LOG_FILE="${dir}/${name}.log"

    echo "--- wiggum run $(date '+%Y-%m-%d %H:%M:%S') ---" >> "$WIGGUM_LOG_FILE"
    log_entry "command" "wiggum $MODE ${FILES[*]+${FILES[*]}}"
}

log_entry() {
    local label="$1"
    local message="$2"
    if [[ -n "$WIGGUM_LOG_FILE" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $label: $message" >> "$WIGGUM_LOG_FILE"
    fi
}

generate_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        # Fallback: generate from /dev/urandom
        od -x /dev/urandom | head -1 | awk '{print $2$3"-"$4"-"$5"-"$6"-"$7$8$9}'
    fi
}

# ── Claude wrapper ───────────────────────────────────────────────────────────

WIGGUM_LAST_SESSION_ID=""

run_claude() {
    local label="${WIGGUM_CURRENT_LABEL:-claude}"
    local session_id
    session_id="$(generate_uuid)"
    local session_args=("--session-id" "$session_id")

    # Replace -c/--continue with --resume <previous-session-id>
    local filtered_args=()
    for arg in "$@"; do
        if [[ "$arg" == "-c" || "$arg" == "--continue" ]]; then
            if [[ -n "$WIGGUM_LAST_SESSION_ID" ]]; then
                session_args=("--session-id" "$session_id" "--resume" "$WIGGUM_LAST_SESSION_ID" "--fork-session")
                log_entry "$label" "session $session_id (resumed from $WIGGUM_LAST_SESSION_ID)"
                echo "  session: $session_id (resumed from $WIGGUM_LAST_SESSION_ID)"
            fi
        else
            filtered_args+=("$arg")
        fi
    done

    if [[ "${session_args[*]}" != *"--resume"* ]]; then
        log_entry "$label" "session $session_id"
        echo "  session: $session_id"
    fi

    WIGGUM_LAST_SESSION_ID="$session_id"

    claude "${session_args[@]}" \
        ${CLAUDE_EXTRA_ARGS[@]+"${CLAUDE_EXTRA_ARGS[@]}"} "${filtered_args[@]}"

    log_entry "$label" "done"
}

# ── Plan ─────────────────────────────────────────────────────────────────────

run_plan() {
    local piped=false
    if [[ -n "$STDIN_FILE" && -z "$CLI_PLAN_FILE" ]]; then
        piped=true
    fi

    echo "=== WIGGUM PLAN MODE ===" >&2
    echo "Input files: ${FILES[*]}" >&2
    if [[ "$piped" == true ]]; then
        echo "Output: stdout" >&2
    else
        echo "Output plan: $PLAN_FILE" >&2
    fi
    echo "" >&2

    if [[ -n "$STDIN_FILE" ]]; then
        log_init "$PLAN_FILE"
    else
        log_init "${FILES[0]}"
    fi
    local file_list="${FILES[*]}"

    WIGGUM_CURRENT_LABEL="plan"
    run_claude -p --permission-mode bypassPermissions \
        "You are a project planner. The issue/spec files to analyze are ONLY: $file_list. Ignore README.md and other repo documentation -- they are not input. Produce a detailed, actionable workplan as a markdown checklist with phases, discrete tasks (each with [ ] status), acceptance criteria, and dependencies. Write the plan to: $PLAN_FILE" \
        "${FILES[@]}"

    if [[ -f "$PLAN_FILE" ]]; then
        if [[ "$piped" == true ]]; then
            cat "$PLAN_FILE"
            rm -f "$PLAN_FILE" "$STDIN_FILE"
        else
            echo "" >&2
            echo "Plan created: $PLAN_FILE" >&2
        fi
    else
        echo "Warning: plan file was not created. Check Claude output above." >&2
    fi
}

# ── Validation ───────────────────────────────────────────────────────────────

run_validation() {
    if [[ ${#VERIFY_STEPS[@]} -eq 0 ]]; then
        echo "(No verification steps configured in .wiggumrc - skipping validation)"
        return 0
    fi

    local retries=0

    while true; do
        echo "--- Validation pass (attempt $((retries + 1)) of $MAX_VALIDATION_RETRIES) ---"
        local needs_fix=false
        local prompt=""

        for step in "${VERIFY_STEPS[@]}"; do
            local is_autofix=false
            local cmd="$step"

            if [[ "$step" == autofix:* ]]; then
                is_autofix=true
                cmd="${step#autofix:}"
            fi

            echo "Running: $cmd"
            local output

            if $is_autofix; then
                eval "$cmd" 2>&1 || true
                if output=$(eval "$cmd" 2>&1); then
                    : # autofix resolved it
                else
                    output=$(echo "$output" | tail -n 60)
                    echo "FAILED (after autofix): $cmd"
                    echo "--- Error output ---"
                    echo "$output"
                    echo "--------------------"
                    prompt="WIGGUM VALIDATION FAILURE. The command below was run by wiggum (from .wiggumrc), NOT by your code. If the command itself is wrong (e.g. wrong script name), you CANNOT fix it -- tell the user to update .wiggumrc. Only fix issues in the actual source code.\n\nCommand: $cmd\nSource: .wiggumrc (autofix step)\nExit code: non-zero\n\nError output:\n$output"
                    needs_fix=true
                    break
                fi
            else
                if output=$(eval "$cmd" 2>&1); then
                    : # passed
                else
                    output=$(echo "$output" | tail -n 60)
                    echo "FAILED: $cmd"
                    echo "--- Error output ---"
                    echo "$output"
                    echo "--------------------"
                    prompt="WIGGUM VALIDATION FAILURE. The command below was run by wiggum (from .wiggumrc), NOT by your code. If the command itself is wrong (e.g. wrong script name), you CANNOT fix it -- tell the user to update .wiggumrc. Only fix issues in the actual source code.\n\nCommand: $cmd\nSource: .wiggumrc (verify step)\nExit code: non-zero\n\nError output:\n$output"
                    needs_fix=true
                    break
                fi
            fi
            echo "PASSED: $cmd"
        done

        if [[ "$needs_fix" == true ]]; then
            retries=$((retries + 1))
            if [[ $retries -ge $MAX_VALIDATION_RETRIES ]]; then
                echo ""
                echo "Validation failed $MAX_VALIDATION_RETRIES times. Stopping to prevent runaway."
                echo "Check that your .wiggumrc verify commands are correct."
                echo "Last failing command: $cmd"
                return "$EXIT_VALIDATION_FAILED"
            fi
            echo "Requesting fix from Claude..."
            WIGGUM_CURRENT_LABEL="${WIGGUM_CURRENT_LABEL}-fix-$retries"
            run_claude -p -c --permission-mode bypassPermissions "$(echo -e "$prompt")"
            continue
        fi

        echo "All verification steps passed."
        return 0
    done
}

# ── Execute ──────────────────────────────────────────────────────────────────

run_execute() {
    echo "=== WIGGUM EXECUTE MODE ===" >&2
    echo "Input files: ${FILES[*]}" >&2
    echo "Iterations: $ITERATIONS" >&2
    echo "Summary output: $SUMMARY_FILE" >&2
    if [[ ${#VERIFY_STEPS[@]} -gt 0 ]]; then
        echo "Verification steps: ${VERIFY_STEPS[*]}" >&2
    else
        echo "Verification steps: (none configured)" >&2
    fi
    echo "" >&2

    if [[ -n "$STDIN_FILE" ]]; then
        log_init "$SUMMARY_FILE"
    else
        log_init "${FILES[0]}"
    fi
    local file_list="${FILES[*]}"

    # Phase 1: Diagnostic & status sync
    echo "--- Phase 1: Diagnostic & Status Sync ---" >&2
    log_entry "phase" "1 - diagnostic & status sync"
    WIGGUM_CURRENT_LABEL="phase1-diagnostic"
    run_claude -p --permission-mode bypassPermissions \
        "The workplan is defined ONLY in: $file_list. Ignore README.md and other documentation -- they are NOT the plan. Analyze the repository against the workplan. If implementation status is inaccurate, update the plan using [x] for done, [ ] for not done. Do not change the plan structure. List the next steps to implement." \
        "${FILES[@]}"

    WIGGUM_CURRENT_LABEL="phase1-commit"
    run_claude -p --permission-mode bypassPermissions \
        "Check if $file_list has any changes (modified or untracked). If so, execute 'git add $file_list' and 'git commit -m \"reconcile plan status\"'. Do not ask for confirmation -- just do it. If there are no changes, do nothing."

    # Phase 2: Iterative implementation
    for ((i = 1; i <= ITERATIONS; i++)); do
        echo "" >&2
        echo "--- Phase 2: Implementation step $i of $ITERATIONS ---" >&2
        log_entry "phase" "2 - implementation step $i of $ITERATIONS"

        # Implementation: acceptEdits so file changes are auto-approved
        WIGGUM_CURRENT_LABEL="phase2-implement-$i"
        run_claude -p -c --permission-mode bypassPermissions \
            "The workplan is defined ONLY in: $file_list. Ignore README.md and other documentation -- they are NOT the plan. Execute the next discrete implementation step from the plan. Write tests for new logic. Fix any existing issues found." \
            "${FILES[@]}"

        # Validation: uses -c to keep implementation context for fixes
        WIGGUM_CURRENT_LABEL="phase2-validate-$i"
        run_validation || echo "Warning: validation did not fully pass on iteration $i" >&2

        # Commit: bypassPermissions so git commands run without prompting
        echo "Committing changes..." >&2
        WIGGUM_CURRENT_LABEL="phase2-commit-$i"
        run_claude -p --permission-mode bypassPermissions \
            "Review all uncommitted changes (modified and untracked files). For each file, execute 'git add <file>' and 'git commit -m \"<message>\"'. Do not ask for confirmation -- just do it. The message MUST be a single line. DO NOT include any trailers, footers, or attributions. Use only the imperative mood describing the logic change."
    done

    # Phase 3: Summary & alignment
    echo "" >&2
    echo "--- Phase 3: Summary & Alignment ---" >&2
    log_entry "phase" "3 - summary & alignment"
    WIGGUM_CURRENT_LABEL="phase3-summary"
    run_claude -p -c --permission-mode bypassPermissions \
        "The workplan is defined ONLY in: $file_list. Review all implementation work done. 1. Update the plan files ($file_list) by marking completed tasks with [x]. 2. Write a concise execution summary to $SUMMARY_FILE covering: what was implemented, what was deferred, any issues encountered, and verification results." \
        "${FILES[@]}"

    WIGGUM_CURRENT_LABEL="phase3-commit"
    run_claude -p --permission-mode bypassPermissions \
        "Review all uncommitted changes (modified and untracked files) including $SUMMARY_FILE and $file_list. For each file, execute 'git add <file>' and 'git commit -m \"<message>\"'. Do not ask for confirmation -- just do it. Single line imperative messages only. DO NOT include any trailers, footers, or attributions."

    echo "" >&2
    if [[ -f "$SUMMARY_FILE" ]]; then
        echo "Summary written to: $SUMMARY_FILE" >&2
    fi

    # Phase 4 (optional): Update documentation
    if [[ ${#UPDATE_DOCS[@]} -gt 0 ]]; then
        echo "" >&2
        echo "--- Phase 4: Documentation Update ---" >&2
        log_entry "phase" "4 - documentation update"
        WIGGUM_CURRENT_LABEL="phase4-docs"
        run_update_docs "$SUMMARY_FILE" "${FILES[@]}" -- "${UPDATE_DOCS[@]}"
    fi

    if [[ -n "$STDIN_FILE" ]]; then
        rm -f "$STDIN_FILE"
    fi

    log_entry "complete" "wiggum execution finished"
    echo "Log: $WIGGUM_LOG_FILE" >&2
    echo "=== WIGGUM EXECUTION COMPLETE ===" >&2
}

# ── Docs ─────────────────────────────────────────────────────────────────────

run_update_docs() {
    local -a inputs=()
    local -a outputs=()
    local parsing="inputs"

    # Split args on "--" separator: inputs... -- outputs...
    for arg in "$@"; do
        if [[ "$arg" == "--" ]]; then
            parsing="outputs"
            continue
        fi
        if [[ "$parsing" == "inputs" ]]; then
            inputs+=("$arg")
        else
            outputs+=("$arg")
        fi
    done

    local input_list="${inputs[*]}"
    local output_list="${outputs[*]}"

    echo "Updating documentation..."
    echo "  Input: $input_list"
    echo "  Output: $output_list"

    local prev_label="${WIGGUM_CURRENT_LABEL:-docs}"
    WIGGUM_CURRENT_LABEL="${prev_label}-update"
    run_claude -p --permission-mode bypassPermissions \
        "Update the following documentation files: $output_list. Use the input files as context for what has changed: $input_list. For each output file: read its current content, then update it to reflect the changes described in the input files. Preserve the existing structure and style of each document. Only update sections that are affected by the changes. Do not rewrite sections that are already accurate." \
        "${inputs[@]}" "${outputs[@]}"

    WIGGUM_CURRENT_LABEL="${prev_label}-commit"
    run_claude -p --permission-mode bypassPermissions \
        "Review all uncommitted changes to: $output_list. For each modified file, execute 'git add <file>' and 'git commit -m \"<message>\"'. Do not ask for confirmation -- just do it. Single line imperative messages only. DO NOT include any trailers, footers, or attributions."

    echo "Documentation updated: $output_list"
}

run_check() {
    echo "=== WIGGUM CHECK MODE ==="
    if [[ ${#VERIFY_STEPS[@]} -eq 0 ]]; then
        echo "No verification steps configured in .wiggumrc. Nothing to check."
        return 0
    fi
    echo "Verification steps: ${VERIFY_STEPS[*]}"
    echo ""

    WIGGUM_CURRENT_LABEL="check"
    if run_validation; then
        echo ""
        echo "=== ALL CHECKS PASSED ==="
    else
        echo ""
        echo "=== CHECKS FAILED ==="
        return "$EXIT_VALIDATION_FAILED"
    fi
}

run_docs() {
    echo "=== WIGGUM DOCS MODE ==="
    echo "Input: ${DOCS_INPUT[*]}"
    echo "Output: ${DOCS_OUTPUT[*]}"
    echo ""

    log_init "${DOCS_OUTPUT[0]}"
    WIGGUM_CURRENT_LABEL="docs"
    run_update_docs "${DOCS_INPUT[@]}" -- "${DOCS_OUTPUT[@]}"

    log_entry "complete" "wiggum docs finished"
    echo "Log: $WIGGUM_LOG_FILE"
    echo "=== WIGGUM DOCS COMPLETE ==="
}
