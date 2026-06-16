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
export EXIT_PLAN_FAILED=5

# ── State (reset by wiggum_reset for testing) ───────────────────────────────

wiggum_reset() {
    MODE=""
    FILES=()
    PLAN_FILE=""
    SUMMARY_FILE=""
    MAX_ITERATIONS=3
    MAX_VALIDATION_RETRIES=5
    MAX_STALL_COUNT=2
    INIT_PRESET=""
    VERIFY_STEPS=()
    BENCHMARK_SCRIPTS=()
    VERBOSE=false
    WIGGUM_SHOW_OUTPUT=false
    CLAUDE_EXTRA_ARGS=()
    CLI_MAX_ITERATIONS=""
    CLI_MAX_RETRIES=""
    UPDATE_DOCS=()
    DOCS_INPUT=()
    DOCS_OUTPUT=()
    WIGGUM_LOG_FILE=""
    STDIN_FILE=""
    CLI_PLAN_FILE=""
    NO_VERIFY=false
    NO_COMMIT=false
    CLI_NO_VERIFY=""
    CLI_NO_COMMIT=""
    EFFORT="xhigh"
    CLI_EFFORT=""
    PERMISSION_MODE="bypassPermissions"
    CLI_PERMISSION_MODE=""
    RUN_PROMPTS=()
    RUN_PROMPTS_FILE=""
    RUN_SESSION_FILE=""
    RUN_NEW_SESSION=false
    RUN_DELIMITER="---"
}

wiggum_reset

# ── Value validation ─────────────────────────────────────────────────────────

# Valid effort levels accepted by `claude --effort`.
validate_effort() {
    case "${1:-}" in
        low|medium|high|xhigh|max) return 0 ;;
        *) return 1 ;;
    esac
}

# Valid permission modes accepted by `claude --permission-mode`.
validate_permission_mode() {
    case "${1:-}" in
        acceptEdits|auto|bypassPermissions|default|dontAsk|plan) return 0 ;;
        *) return 1 ;;
    esac
}

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
            verify|autofix|benchmark|iterations|max_iterations|max_validation_retries|skip_verify|skip_commit|effort|permission_mode)
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
            benchmark)
                BENCHMARK_SCRIPTS+=("$value")
                ;;
            iterations|max_iterations)
                if [[ -z "$CLI_MAX_ITERATIONS" ]]; then
                    MAX_ITERATIONS="$value"
                fi
                ;;
            max_validation_retries)
                if [[ -z "$CLI_MAX_RETRIES" ]]; then
                    MAX_VALIDATION_RETRIES="$value"
                fi
                ;;
            skip_verify)
                if [[ -z "$CLI_NO_VERIFY" ]]; then
                    case "$value" in
                        true|1|yes|on)   NO_VERIFY=true ;;
                        false|0|no|off)  NO_VERIFY=false ;;
                        *)
                            echo "Warning: invalid value for skip_verify: '$value' (expected true/false). Treating as false." >&2
                            NO_VERIFY=false
                            ;;
                    esac
                fi
                ;;
            skip_commit)
                if [[ -z "$CLI_NO_COMMIT" ]]; then
                    case "$value" in
                        true|1|yes|on)   NO_COMMIT=true ;;
                        false|0|no|off)  NO_COMMIT=false ;;
                        *)
                            echo "Warning: invalid value for skip_commit: '$value' (expected true/false). Treating as false." >&2
                            NO_COMMIT=false
                            ;;
                    esac
                fi
                ;;
            effort)
                if [[ -z "$CLI_EFFORT" ]]; then
                    if validate_effort "$value"; then
                        EFFORT="$value"
                    else
                        echo "Warning: invalid value for effort: '$value' (expected low/medium/high/xhigh/max). Keeping '$EFFORT'." >&2
                    fi
                fi
                ;;
            permission_mode)
                if [[ -z "$CLI_PERMISSION_MODE" ]]; then
                    if validate_permission_mode "$value"; then
                        PERMISSION_MODE="$value"
                    else
                        echo "Warning: invalid value for permission_mode: '$value' (expected acceptEdits/auto/bypassPermissions/default/dontAsk/plan). Keeping '$PERMISSION_MODE'." >&2
                    fi
                fi
                ;;
        esac
    done
}

load_config() {
    local config_file
    config_file="$(find_config)"

    if [[ -z "$config_file" ]]; then
        # Informational output must go to stderr. Otherwise it leaks into
        # downstream pipes (e.g. `wiggum plan X | wiggum execute`), where the
        # next command sees config chatter instead of a real plan.
        echo "No .wiggumrc found (checked ./ and ~/). Using defaults." >&2
        return
    fi

    echo "Loading config from $config_file" >&2
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
  --verbose            Show Claude output (suppressed by default)

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
  --max-iterations <n>          Maximum implementation iterations (default: 3)
  --max-validation-retries <n>  Max fix attempts per verification step (default: 5)
  --summary-file <path>         Output path for the summary (default: <base>_summary.md)
  --benchmark <script>          Run script after each iteration, feed output to Claude (repeatable)
  --update-docs <files>         Comma-separated doc files to update after execution
  --no-verify                   Skip wiggum's verification waterfall (Claude may
                                still run tests during implementation)
  --no-commit                   Skip every wiggum-issued git commit
  --verbose                     Show Claude output (suppressed by default)

Verification steps:
  Loaded from .wiggumrc. Each step is run after implementation:
    verify  = <cmd>    Run command; fail if non-zero exit (e.g., pytest, npm test)
    autofix = <cmd>    Run command to fix, then re-run to verify (e.g., ruff check --fix)

Phases:
  1. Diagnostic & Status Sync - reconcile plan against repo state
  2. Iterative Implementation - implement, verify, commit, progress check
     Stops early when all tasks are checked off, or when no progress
     is made for 2 consecutive iterations.
  3. Summary & Alignment     - update plan checkboxes, write summary
  4. Documentation Update     - update docs (if --update-docs is set)

When no files are given, reads from stdin.

Examples:
  wiggum execute docs/plan.md
  wiggum execute docs/plan.md --max-iterations 5 --update-docs README.md
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
  --verbose       Show Claude output (suppressed by default)

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
  --max-validation-retries <n>  Max fix attempts per step (default: 5)
  --no-commit                   Skip the post-fix wiggum commit
  --verbose                     Show Claude output (suppressed by default)

Note: --no-verify is rejected here -- it would make 'wiggum check' a no-op.

Runs the verify/autofix steps from .wiggumrc against the current codebase.
When a step fails, Claude is asked to fix the issue. Repeats up to
max_validation_retries times. Does not implement new features or commit.

Verification steps (from .wiggumrc):
  verify  = <cmd>    Run command; fail if non-zero exit (e.g., pytest)
  autofix = <cmd>    Run command to fix, then re-run to verify (e.g., ruff check --fix)

Useful after manual edits or before committing to ensure everything passes.

Examples:
  wiggum check
  wiggum check --verbose
  wiggum check --max-validation-retries 3
EOF
            ;;
        run)
            cat <<EOF
wiggum run - Feed a series of prompts to Claude in one continuous session

Usage:
  wiggum run <prompt...> [options]
  wiggum run -f <prompts-file> [options]
  command | wiggum run [options]

Options:
  -f, --prompts-file <path>   Read prompts from a file (split on delimiter lines)
  --session-file <path>       Persist/resume the session id across invocations
  --new-session               Ignore an existing --session-file and start fresh
  --delimiter <str>           Prompt separator line for -f/stdin (default: ---)
  --effort <level>            Reasoning effort: low|medium|high|xhigh|max (default: xhigh)
  --permission-mode <mode>    acceptEdits|auto|bypassPermissions|default|dontAsk|plan
  --verbose                   Pass --verbose to Claude Code

Runs each prompt in order. The first prompt starts a fresh session (or resumes
the one in --session-file); every later prompt continues the same session, so
Claude keeps full context between prompts. Claude's responses go to stdout;
wiggum status and session ids go to stderr.

Prompts can come from positional arguments (each argument is one prompt), a
file via -f, or stdin. In a file or on stdin, prompts are separated by a line
containing only the delimiter (default '---'), so prompts may span multiple
lines.

With --session-file, the session id is saved to that file and resumed on the
next run -- so a cron job can run a step now and follow up later in the same
session. Use --new-session to start over.

Examples:
  wiggum run "Summarize today's git log" "Draft release notes from it"
  wiggum run -f steps.txt --session-file .wiggum-session
  echo "What changed in the last commit?" | wiggum run
  # Cron: day 1 starts the session, day 2 follows up in it
  wiggum run --session-file .wiggum-session "Scaffold the API skeleton"
  wiggum run --session-file .wiggum-session "Now add auth to that API"
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
  run       Feed a series of prompts to Claude in one continuous session

Run 'wiggum help <command>' for details on a specific command.

Options:
  --effort <level>          Reasoning effort: low|medium|high|xhigh|max (default: xhigh)
  --permission-mode <mode>  Claude permission mode (default: bypassPermissions)
  --verbose                 Show Claude output (suppressed by default)
  -h, --help                Show this help

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

    if [[ "$MODE" != "plan" && "$MODE" != "execute" && "$MODE" != "init" && "$MODE" != "docs" && "$MODE" != "check" && "$MODE" != "run" ]]; then
        echo "Error: unknown mode '$MODE'. Use 'plan', 'execute', 'check', 'docs', 'run', or 'init'." >&2
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
            --iterations|--max-iterations)
                MAX_ITERATIONS="$2"
                CLI_MAX_ITERATIONS="$2"
                shift 2
                ;;
            --max-retries|--max-validation-retries)
                MAX_VALIDATION_RETRIES="$2"
                CLI_MAX_RETRIES="$2"
                shift 2
                ;;
            --verbose)
                export VERBOSE=true
                CLAUDE_EXTRA_ARGS+=("--verbose")
                shift
                ;;
            --effort)
                if validate_effort "${2:-}"; then
                    EFFORT="$2"
                    CLI_EFFORT="$2"
                    shift 2
                else
                    echo "Error: invalid --effort '${2:-}' (expected low/medium/high/xhigh/max)." >&2
                    return "$EXIT_BAD_ARGS"
                fi
                ;;
            --permission-mode)
                if validate_permission_mode "${2:-}"; then
                    PERMISSION_MODE="$2"
                    CLI_PERMISSION_MODE="$2"
                    shift 2
                else
                    echo "Error: invalid --permission-mode '${2:-}' (expected acceptEdits/auto/bypassPermissions/default/dontAsk/plan)." >&2
                    return "$EXIT_BAD_ARGS"
                fi
                ;;
            -f|--prompts-file)
                RUN_PROMPTS_FILE="$2"
                shift 2
                ;;
            --session-file)
                RUN_SESSION_FILE="$2"
                shift 2
                ;;
            --new-session)
                RUN_NEW_SESSION=true
                shift
                ;;
            --delimiter)
                RUN_DELIMITER="$2"
                shift 2
                ;;
            --no-verify)
                NO_VERIFY=true
                CLI_NO_VERIFY=true
                shift
                ;;
            --no-commit)
                NO_COMMIT=true
                CLI_NO_COMMIT=true
                shift
                ;;
            --update-docs)
                IFS=',' read -ra UPDATE_DOCS <<< "$2"
                shift 2
                ;;
            --benchmark)
                BENCHMARK_SCRIPTS+=("$2")
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
                if [[ "$MODE" == "run" ]]; then
                    RUN_PROMPTS+=("$1")
                else
                    FILES+=("$1")
                fi
                shift
                ;;
        esac
    done

    # remaining args after -- are all files (or prompts, in run mode)
    while [[ $# -gt 0 ]]; do
        if [[ "$MODE" == "run" ]]; then
            RUN_PROMPTS+=("$1")
        else
            FILES+=("$1")
        fi
        shift
    done

    # run mode collects prompts (positional, -f, or stdin), not plan files
    if [[ "$MODE" == "run" ]]; then
        if [[ -n "$RUN_PROMPTS_FILE" ]]; then
            if [[ ! -r "$RUN_PROMPTS_FILE" ]]; then
                echo "Error: prompts file not found or unreadable: $RUN_PROMPTS_FILE" >&2
                return "$EXIT_BAD_ARGS"
            fi
            split_prompts "$RUN_PROMPTS_FILE"
        fi
        # No positional or -f prompts: read them from stdin if piped.
        if [[ ${#RUN_PROMPTS[@]} -eq 0 && ! -t 0 ]]; then
            local stdin_prompts
            stdin_prompts="$(mktemp "${TMPDIR:-/tmp}/wiggum_run.XXXXXX")"
            cat > "$stdin_prompts"
            split_prompts "$stdin_prompts"
            rm -f "$stdin_prompts"
        fi
        if [[ ${#RUN_PROMPTS[@]} -eq 0 ]]; then
            echo "Error: no prompts given. Pass prompts as arguments, with -f <file>, or via stdin." >&2
            return "$EXIT_BAD_ARGS"
        fi
        return 0
    fi

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

# ── Plan progress ────────────────────────────────────────────────────────────

# Counts only `[ ]` -- pending tasks the agent should pick up.
# `[~]` is the dropped/abandoned state and is intentionally excluded;
# do not widen this regex to include it. Dropped tasks are terminal,
# like `[x]`, and counting them as remaining causes false stalls.
count_unchecked() {
    local count=0
    local f
    for f in "$@"; do
        if [[ -f "$f" ]]; then
            count=$((count + $(grep -cE '^\s*-\s*\[ \]' "$f" || true)))
        fi
    done
    echo "$count"
}

# Count all task states across one or more plan files: `[ ]`, `[x]`/`[X]`,
# and `[~]` (dropped). Includes `[~]` so that
# total - unchecked - dropped == done holds.
count_total_tasks() {
    local count=0
    local f
    for f in "$@"; do
        if [[ -f "$f" ]]; then
            count=$((count + $(grep -cE '^\s*-\s*\[[ xX~]\]' "$f" || true)))
        fi
    done
    echo "$count"
}

# Count only `[~]` -- tasks intentionally dropped/abandoned mid-plan.
count_dropped() {
    local count=0
    local f
    for f in "$@"; do
        if [[ -f "$f" ]]; then
            count=$((count + $(grep -cE '^\s*-\s*\[~\]' "$f" || true)))
        fi
    done
    echo "$count"
}

# Build the phase-3 "dropped tasks" paragraph that gets appended to the
# summary prompt. Empty when no `[~]` lines exist, so plans that don't use
# the dropped marker get an unchanged phase-3 prompt. The leading `\n\n` is
# literal -- matches the conditional-context pattern used by
# `final_benchmark_context` in `run_execute`.
build_dropped_context() {
    local count
    count="$(count_dropped "$@")"
    if [[ "$count" -eq 0 ]]; then
        return 0
    fi
    local dropped_lines
    dropped_lines="$(grep -hE '^\s*-\s*\[~\]' "$@" 2>/dev/null || true)"
    # `%s` keeps the literal `\n` backslashes intact -- matches the
    # conditional-context pattern in `run_execute`.
    printf '%s' "\\n\\nThere are $count dropped tasks (\`[~]\`). Render them in the summary under a \"What was dropped\" subsection, preserving the rationale recorded on each line. Do not re-mark \`[~]\` as \`[x]\` -- it is the terminal dropped state, not pending. The dropped lines are:\\n$dropped_lines"
}

# Threshold for the large-plan warning. Plans above this tend to stall and
# lose focus; the warning nudges the user to split them.
WIGGUM_LARGE_PLAN_THRESHOLD=40

# Emit a stderr warning if the combined task count across the given files
# exceeds WIGGUM_LARGE_PLAN_THRESHOLD. Always returns 0.
warn_if_plan_large() {
    local total
    total="$(count_total_tasks "$@")"
    if [[ "$total" -gt "$WIGGUM_LARGE_PLAN_THRESHOLD" ]]; then
        echo "Warning: plan has $total tasks (threshold: $WIGGUM_LARGE_PLAN_THRESHOLD). Large plans tend to stall and lose focus -- consider splitting into smaller, sequential workplans." >&2
    fi
    return 0
}

# ── Stdin persistence ────────────────────────────────────────────────────────

persist_stdin() {
    local dir="docs"
    mkdir -p "$dir"
    local dest="${dir}/stdin.md"
    cp "$STDIN_FILE" "$dest"
    echo "$dest"
}

# Trim surrounding whitespace (including newlines) from a chunk and, if it is
# non-empty, append it as one prompt to RUN_PROMPTS.
append_prompt_chunk() {
    local chunk="$1"
    chunk="${chunk#"${chunk%%[![:space:]]*}"}"   # strip leading whitespace
    chunk="${chunk%"${chunk##*[![:space:]]}"}"    # strip trailing whitespace
    if [[ -n "$chunk" ]]; then
        RUN_PROMPTS+=("$chunk")
    fi
}

# Split a file into prompts on lines equal to the delimiter ($RUN_DELIMITER,
# default "---"), appending each non-empty chunk to RUN_PROMPTS. Multi-line
# prompts are preserved; blank or whitespace-only chunks are skipped. Used by
# `wiggum run` for both -f files and piped stdin.
split_prompts() {
    local file="$1"
    local chunk="" line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$RUN_DELIMITER" ]]; then
            append_prompt_chunk "$chunk"
            chunk=""
        else
            chunk+="$line"$'\n'
        fi
    done < "$file"
    append_prompt_chunk "$chunk"
}

# Returns 0 if the file looks like a wiggum plan (has at least one markdown
# checkbox `- [ ]`/`- [x]` or one `#` heading). Returns 1 otherwise.
#
# Guards against a failure mode seen in the wild: upstream tools (another
# wiggum process, a shell function with stray `echo`, etc.) accidentally
# leak a few lines of chatter into the pipe feeding `wiggum execute`. A
# non-empty but non-plan input would otherwise be silently accepted,
# consuming Claude tokens on nonsense and stopping early with "0 tasks".
looks_like_plan() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    grep -qE '^\s*-\s*\[[ xX]\]|^#' "$f"
}

# Derive a filename-safe slug from a file's first heading or first line.
# Falls back to a date stamp if nothing usable is found.
slugify() {
    local file="$1"
    local text=""
    # Try first markdown heading
    text="$(grep -m1 '^#' "$file" 2>/dev/null | sed 's/^#* *//')"
    # Fall back to first non-empty line
    if [[ -z "$text" ]]; then
        text="$(grep -m1 '.' "$file" 2>/dev/null)"
    fi
    # Lowercase, replace non-alnum with hyphens, trim, truncate
    text="$(echo "$text" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//' | cut -c1-50)"
    # Strip trailing hyphen from truncation
    text="${text%-}"
    if [[ -z "$text" ]]; then
        text="$(date +%Y-%m-%d)"
    fi
    echo "$text"
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

max_iterations = 3
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

max_iterations = 3
max_validation_retries = 5
RCEOF
            ;;
        python)
            cat <<'RCEOF'
# .wiggumrc - Python project
autofix = ruff format . && ruff check --fix .
verify = pytest

max_iterations = 3
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

max_iterations = 3
max_validation_retries = 5
RCEOF
            ;;
        bash)
            cat <<'RCEOF'
# .wiggumrc - Bash project
verify = shellcheck -s bash *.sh **/*.sh
verify = bats test/

max_iterations = 3
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

## File naming

Before starting, derive a short kebab-case slug from the issue (e.g., "improve-chunking"). All output files use this slug:

- **Plan**: `docs/<slug>_plan.md`
- **Summary**: `docs/<slug>_summary.md`

## Step 1: Plan

1. Read and understand the issue/spec thoroughly.
2. Read README.md and other project documentation for context.
3. Analyze the repository to understand the relevant code, tests, and architecture.
4. Produce a detailed workplan as a markdown checklist with:
   - Phases and discrete tasks (each with `[ ]` status)
   - An `Acceptance:` line on every task stating an observable outcome (a passing test, a specific log line, a file that exists, a command that exits 0). Not a feeling. A task without observable acceptance is a wish, not a step.
   - A `Files:` line on every task naming the files it will create or modify (best-effort paths)
   - Dependencies between tasks
5. Before finalizing, confirm the libraries, APIs, and commands the plan depends on actually exist (grep the repo or read the dependency). Do not plan around an assumed or hallucinated API.
6. Write the plan to `docs/<slug>_plan.md`.
7. Commit the plan: `git add docs/<slug>_plan.md && git commit -m "add workplan for <slug>"`

## Step 2: Implement (iterative)

Repeat the following cycle up to **3 iterations** (or until all tasks are checked off):

### 2a. Implement the next step

- Pick the next unchecked `[ ]` task from `docs/<slug>_plan.md`.
- Before writing code, verify your assumptions: confirm the APIs and imports you will call exist and the config values you rely on are defined (grep or read the source — do not assume).
- If no test covers the change, write a minimal failing test first, then implement until it passes.
- After implementing, run three spot checks and show input → expected → actual: the happy path, an edge case (empty, boundary, or large input), and a failure case (invalid input must fail safely with a clear error).
- Mark the task `[x]` only once its acceptance criterion is met and all three spot checks pass — never round an unverified result up to done.

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

### 2d. Progress check

Count the remaining unchecked `[ ]` tasks in `docs/<slug>_plan.md`.

- **All done** (0 remaining): stop reason is **complete**. Go to Step 3.
- **No progress** (same or more remaining as last iteration): if this has happened **2 iterations in a row**, stop reason is **stalled**. Go to Step 3.
- **Max iterations reached**: stop reason is **incomplete**. Go to Step 3.
- **Otherwise**: continue to the next iteration.

## Step 3: Summarize

1. Update `docs/<slug>_plan.md` — mark all completed tasks with `[x]`.
2. Write a summary to `docs/<slug>_summary.md` covering:
   - **Stop reason**: complete, stalled, or incomplete
   - What was implemented
   - What was deferred (if anything)
   - Issues encountered
   - Verification results
3. Commit the summary and updated plan.
4. Report the stop reason to the user.

## Rules

- **Never ask for confirmation** — just execute.
- **Commit messages**: single line, imperative, no `feat:`/`fix:` prefixes, no `Co-Authored-By` trailers.
- **Verification failures**: fix source code, not `.wiggumrc`. If the command itself is wrong (e.g., wrong script name), tell the user to update `.wiggumrc`.
- **Stay focused**: implement what the issue asks for. Don't refactor surrounding code, add docstrings, or make "improvements" beyond scope.
- **Plan file is the source of truth**: always reference and update `docs/<slug>_plan.md` as you work.
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

    mkdir -p "$dir"
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

    # Replace -c/--continue with --resume <previous-session-id>.
    # Track whether the caller passed its own --permission-mode so we don't
    # also inject the configured one (an explicit per-call override wins).
    local filtered_args=()
    local has_perm_mode=false
    for arg in "$@"; do
        if [[ "$arg" == "-c" || "$arg" == "--continue" ]]; then
            if [[ -n "$WIGGUM_LAST_SESSION_ID" ]]; then
                session_args=("--session-id" "$session_id" "--resume" "$WIGGUM_LAST_SESSION_ID" "--fork-session")
                log_entry "$label" "session $session_id (resumed from $WIGGUM_LAST_SESSION_ID)"
                echo "  session: $session_id (resumed from $WIGGUM_LAST_SESSION_ID)" >&2
            fi
        else
            [[ "$arg" == "--permission-mode" ]] && has_perm_mode=true
            filtered_args+=("$arg")
        fi
    done

    # Inject the configured effort and permission mode (unless overridden).
    local injected_args=()
    if [[ -n "$EFFORT" ]]; then
        injected_args+=("--effort" "$EFFORT")
    fi
    if [[ "$has_perm_mode" != true ]]; then
        injected_args+=("--permission-mode" "$PERMISSION_MODE")
    fi

    if [[ "${session_args[*]}" != *"--resume"* ]]; then
        log_entry "$label" "session $session_id"
        echo "  session: $session_id" >&2
    fi

    WIGGUM_LAST_SESSION_ID="$session_id"

    if [[ "$VERBOSE" == true || "$WIGGUM_SHOW_OUTPUT" == true ]]; then
        claude "${session_args[@]}" \
            ${injected_args[@]+"${injected_args[@]}"} \
            ${CLAUDE_EXTRA_ARGS[@]+"${CLAUDE_EXTRA_ARGS[@]}"} "${filtered_args[@]}"
    else
        claude "${session_args[@]}" \
            ${injected_args[@]+"${injected_args[@]}"} \
            ${CLAUDE_EXTRA_ARGS[@]+"${CLAUDE_EXTRA_ARGS[@]}"} "${filtered_args[@]}" >/dev/null
    fi

    log_entry "$label" "done"
}

# ── Plan ─────────────────────────────────────────────────────────────────────

run_plan() {
    local piped=false
    # Pipe the plan to stdout when no explicit -o was given AND either stdin
    # was piped in (echo ... | wiggum plan) or stdout is a pipe (wiggum plan
    # docs/X.md | wiggum execute). Without the stdout check, a file-argument
    # invocation would leak Claude's chat reply into the downstream pipe
    # while the real plan stays on disk.
    if [[ -z "$CLI_PLAN_FILE" ]] && { [[ -n "$STDIN_FILE" ]] || [[ ! -t 1 ]]; }; then
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
    if [[ "$piped" != true ]]; then
        WIGGUM_SHOW_OUTPUT=true
    fi
    run_claude -p \
        "You are a project planner. $(prompt_workplan "$file_list") Produce a detailed, actionable workplan as a markdown checklist with phases, discrete tasks (each with [ ] status), and dependencies. Every task MUST have an 'Acceptance:' line stating an observable outcome -- a passing test, a specific log line, a file that exists, a command that exits 0, a SQL row. Not a feeling ('looks better', 'works correctly'). A task without observable acceptance is a wish, not a step. $(prompt_plan_verification) Use the Write tool to save the plan to: $PLAN_FILE. Do not print the plan to stdout -- only write it to the file. $PROMPT_SUFFIX" \
        "${FILES[@]}"
    WIGGUM_SHOW_OUTPUT=false

    if [[ -f "$PLAN_FILE" && -s "$PLAN_FILE" ]]; then
        warn_if_plan_large "$PLAN_FILE"
        if [[ "$piped" == true ]]; then
            cat "$PLAN_FILE"
            rm -f "$PLAN_FILE" "$STDIN_FILE"
        else
            echo "" >&2
            echo "Plan created: $PLAN_FILE" >&2
        fi
    else
        echo "Error: plan file was not created or is empty. Check Claude output above." >&2
        return "$EXIT_PLAN_FAILED"
    fi
}

# ── Prompt templates ─────────────────────────────────────────────────────────

# Common suffix appended to all prompts.
PROMPT_SUFFIX="Do not ask for confirmation -- just do it."

# Build workplan context preamble.  Usage: $(prompt_workplan "$file_list")
prompt_workplan() {
    echo "The workplan is defined ONLY in: $1. You may read README.md and other project documentation for context, but they are not the plan."
}

# Verification discipline appended to the planner prompt.  Usage: $(prompt_plan_verification)
prompt_plan_verification() {
    echo "Every task MUST also have a 'Files:' line naming the files it will create or modify (best-effort paths). Before finalizing the plan, confirm the libraries, APIs, and commands the approach depends on actually exist -- grep the repo or read the dependency. Do not build the plan around an assumed or hallucinated API."
}

# Verification discipline appended to the implementation prompt.  Usage: $(prompt_implement_verification)
prompt_implement_verification() {
    echo "Before writing code, verify your assumptions: confirm the functions, APIs, and imports you will call actually exist and the config values you depend on are defined -- grep the repo or read the source, do not assume. If no test covers the change, write a minimal failing test first, then implement until it passes. After implementing, run three spot checks and show your work as input -> expected -> actual: the happy path, an edge case (empty, boundary, or large input), and a failure case (invalid input must fail safely with a clear error). Do not mark a task \`[x]\` until its acceptance criterion is met and all three spot checks pass; never round an unverified result up to done."
}

# Build a commit prompt.  Optional arg: extra files to mention.
prompt_commit() {
    local extra="${1:-}"
    local files_clause="modified and untracked files"
    if [[ -n "$extra" ]]; then
        files_clause="uncommitted changes (modified and untracked files) including $extra"
    fi
    echo "Review all $files_clause. For each file, execute 'git add <file>' and 'git commit -m \"<message>\"'. $PROMPT_SUFFIX The message MUST be a single line. DO NOT include any trailers, footers, or attributions. Use only the imperative mood describing the logic change."
}

# Run a wiggum-issued commit step, or skip it under --no-commit.
# Args: <session-label> [extra-files-to-mention]
commit_or_skip() {
    if [[ "$NO_COMMIT" == true ]]; then
        echo "(commit skipped via --no-commit)" >&2
        return 0
    fi
    local label="$1"
    shift
    WIGGUM_CURRENT_LABEL="$label"
    run_claude -p "$(prompt_commit "$@")"
}

# ── Validation ───────────────────────────────────────────────────────────────

print_verify_steps() {
    local fd="${1:-2}"  # default to stderr
    if [[ "$NO_VERIFY" == true ]]; then
        echo "Verification steps: (skipped)" >&"$fd"
        return
    fi
    if [[ ${#VERIFY_STEPS[@]} -eq 0 ]]; then
        echo "Verification steps: (none configured)" >&"$fd"
        return
    fi
    echo "Verification steps:" >&"$fd"
    local step
    for step in "${VERIFY_STEPS[@]}"; do
        echo "  - $step" >&"$fd"
    done
}

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
                    prompt="WIGGUM VALIDATION FAILURE. The command below was run by wiggum (from .wiggumrc), NOT by your code. If the command itself is wrong (e.g. wrong script name), you CANNOT fix it -- tell the user to update .wiggumrc. Only fix issues in the actual source code. Read the actual error output below before forming a hypothesis -- do not guess from the filename or command alone. After editing, re-run the failing command yourself and confirm it now passes; do not infer success from the edit. $PROMPT_SUFFIX\n\nCommand: $cmd\nSource: .wiggumrc (autofix step)\nExit code: non-zero\n\nError output:\n$output"
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
                    prompt="WIGGUM VALIDATION FAILURE. The command below was run by wiggum (from .wiggumrc), NOT by your code. If the command itself is wrong (e.g. wrong script name), you CANNOT fix it -- tell the user to update .wiggumrc. Only fix issues in the actual source code. Read the actual error output below before forming a hypothesis -- do not guess from the filename or command alone. After editing, re-run the failing command yourself and confirm it now passes; do not infer success from the edit. $PROMPT_SUFFIX\n\nCommand: $cmd\nSource: .wiggumrc (verify step)\nExit code: non-zero\n\nError output:\n$output"
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
            run_claude -p -c "$(echo -e "$prompt")"
            continue
        fi

        echo "All verification steps passed."
        return 0
    done
}

# ── Benchmarks ───────────────────────────────────────────────────────────────

# Extract all numeric values from text (integers and decimals).
# Returns one number per line, suitable for comparison.
extract_benchmark_numbers() {
    grep -oE '[0-9]+(\.[0-9]+)?' | sort -n
}

# Compare two sets of benchmark numbers.  Returns 0 (true) if
# the numbers differ, meaning the benchmark made progress.
benchmark_numbers_changed() {
    local prev_nums="$1"
    local curr_nums="$2"
    [[ "$curr_nums" != "$prev_nums" ]]
}

# Run all benchmark scripts and capture concatenated output.
# Returns empty string if no benchmarks are configured.
run_benchmarks() {
    if [[ ${#BENCHMARK_SCRIPTS[@]} -eq 0 ]]; then
        return 0
    fi
    local script output
    for script in "${BENCHMARK_SCRIPTS[@]}"; do
        echo "--- Benchmark: $script ---"
        if output=$(eval "$script" 2>&1); then
            echo "$output"
        else
            echo "(failed with exit code $?)"
            echo "$output"
        fi
    done
}

# ── Execute ──────────────────────────────────────────────────────────────────

run_execute() {
    echo "=== WIGGUM EXECUTE MODE ===" >&2
    echo "Input files: ${FILES[*]}" >&2
    echo "Max iterations: $MAX_ITERATIONS" >&2
    echo "Summary output: $SUMMARY_FILE" >&2
    print_verify_steps 2
    if [[ ${#BENCHMARK_SCRIPTS[@]} -gt 0 ]]; then
        echo "Benchmarks:" >&2
        local script
        for script in "${BENCHMARK_SCRIPTS[@]}"; do
            echo "  - $script" >&2
        done
    fi
    echo "" >&2

    if [[ -n "$STDIN_FILE" ]]; then
        log_init "$SUMMARY_FILE"
    else
        log_init "${FILES[0]}"
    fi
    local file_list="${FILES[*]}"

    warn_if_plan_large "${FILES[@]}"

    # Phase 1: Diagnostic & status sync
    echo "--- Phase 1: Diagnostic & Status Sync ---" >&2
    log_entry "phase" "1 - diagnostic & status sync"
    WIGGUM_CURRENT_LABEL="phase1-diagnostic"
    run_claude -p \
        "$(prompt_workplan "$file_list") Analyze the repository against the workplan. Verify before claiming -- when checking whether a task is done, read the actual file or run the actual command. Do not infer status from filenames, comments, or commit messages. If a task touches state shared with other modules (a status column, a config flag, a lifecycle field), grep every site that writes it and enumerate the values it can leave behind, including transient ones from interrupted runs. If implementation status is inaccurate, update the plan using [x] for done, [ ] for not done. Leave \`[~]\` lines untouched. \`[~]\` is the terminal dropped state -- the work was intentionally abandoned and is not pending. Do not convert \`[~]\` to \`[ ]\` or \`[x]\`. Do not change the plan structure. List the next steps to implement. $PROMPT_SUFFIX" \
        "${FILES[@]}"

    if [[ "$NO_COMMIT" == true ]]; then
        echo "(commit skipped via --no-commit)" >&2
    else
        WIGGUM_CURRENT_LABEL="phase1-commit"
        run_claude -p \
            "Check if $file_list has any changes (modified or untracked). If so, execute 'git add $file_list' and 'git commit -m \"reconcile plan status\"'. $PROMPT_SUFFIX If there are no changes, do nothing."
    fi

    # Phase 2: Iterative implementation
    local stall_count=0
    local prev_remaining prev_dropped
    prev_remaining="$(count_unchecked "${FILES[@]}")"
    prev_dropped="$(count_dropped "${FILES[@]}")"
    local stop_reason="incomplete"
    local benchmark_output=""
    local prev_benchmark_nums=""

    for ((i = 1; i <= MAX_ITERATIONS; i++)); do
        echo "" >&2
        echo "--- Phase 2: Implementation step $i of $MAX_ITERATIONS ($prev_remaining remaining, $prev_dropped dropped) ---" >&2
        log_entry "phase" "2 - implementation step $i of $MAX_ITERATIONS ($prev_remaining remaining, $prev_dropped dropped)"

        # Implementation: bypassPermissions so file changes are auto-approved
        local benchmark_context=""
        if [[ -n "$benchmark_output" ]]; then
            benchmark_context="\n\nBenchmark results from the previous iteration:\n$benchmark_output\n\nUse these results to guide your implementation — focus on improving the metrics."
        fi
        WIGGUM_CURRENT_LABEL="phase2-implement-$i"
        run_claude -p -c \
            "$(prompt_workplan "$file_list") Execute the next discrete implementation step from the plan. The next step is the next \`[ ]\` task. Skip any task marked \`[~]\` -- that is the dropped state, an in-plan decision not to do the work. Treat \`[~]\` as terminal, like \`[x]\`. Do not revisit, reconcile, or re-evaluate \`[~]\` lines. $(prompt_implement_verification) Fix any existing issues found. Do your own legwork -- if a question can be answered by running a command, reading a file, or grepping the repo, do it yourself rather than stopping to ask. Only ask the user when you genuinely lack access or the action is destructive.${benchmark_context} $PROMPT_SUFFIX" \
            "${FILES[@]}"

        # Validation: uses -c to keep implementation context for fixes
        if [[ "$NO_VERIFY" == true ]]; then
            echo "(verification skipped via --no-verify)" >&2
        else
            WIGGUM_CURRENT_LABEL="phase2-validate-$i"
            run_validation || echo "Warning: validation did not fully pass on iteration $i" >&2
        fi

        # Commit: bypassPermissions so git commands run without prompting
        echo "Committing changes..." >&2
        commit_or_skip "phase2-commit-$i"

        # Run benchmarks after commit (output feeds into next iteration)
        local curr_benchmark_nums=""
        if [[ ${#BENCHMARK_SCRIPTS[@]} -gt 0 ]]; then
            echo "Running benchmarks..." >&2
            benchmark_output="$(run_benchmarks)"
            echo "$benchmark_output" >&2
            log_entry "benchmark" "$benchmark_output"
            curr_benchmark_nums="$(echo "$benchmark_output" | extract_benchmark_numbers)"
        fi

        # Check progress: tasks completed OR benchmark numbers changed
        local remaining dropped
        remaining="$(count_unchecked "${FILES[@]}")"
        dropped="$(count_dropped "${FILES[@]}")"

        # `count_unchecked` excludes `[~]`, so an all-dropped plan reports
        # remaining=0 here and short-circuits to `complete` -- no further
        # implementation iterations run. Do not re-introduce `[~]` into
        # `count_unchecked`'s regex, or this branch will stop firing and
        # dropped tasks will trigger false stalls again.
        if [[ "$remaining" -eq 0 ]]; then
            echo "All tasks complete — stopping early." >&2
            log_entry "stop" "all tasks complete after iteration $i"
            stop_reason="complete"
            break
        fi

        local task_progress=false
        if [[ "$remaining" -lt "$prev_remaining" ]]; then
            task_progress=true
        fi

        local benchmark_progress=false
        if [[ ${#BENCHMARK_SCRIPTS[@]} -gt 0 ]] \
              && benchmark_numbers_changed "$prev_benchmark_nums" "$curr_benchmark_nums"; then
            benchmark_progress=true
        fi

        if $task_progress || $benchmark_progress; then
            stall_count=0
            if $benchmark_progress && ! $task_progress; then
                echo "Benchmark metrics changed ($remaining tasks remaining — benchmark progress counts)." >&2
                log_entry "progress" "benchmark metrics changed on iteration $i ($remaining remaining)"
            fi
        else
            stall_count=$((stall_count + 1))
            echo "No progress detected ($remaining tasks remaining, $dropped dropped, stall $stall_count of $MAX_STALL_COUNT)." >&2
            log_entry "stall" "no progress on iteration $i ($remaining remaining, $dropped dropped, stall $stall_count)"
            if [[ "$stall_count" -ge "$MAX_STALL_COUNT" ]]; then
                echo "Stalled for $MAX_STALL_COUNT consecutive iterations — stopping." >&2
                log_entry "stop" "stalled after iteration $i"
                stop_reason="stalled"
                break
            fi
        fi

        prev_benchmark_nums="$curr_benchmark_nums"

        prev_remaining="$remaining"
        prev_dropped="$dropped"
    done

    # Phase 3: Summary & alignment
    echo "" >&2
    echo "--- Phase 3: Summary & Alignment (${stop_reason}) ---" >&2
    log_entry "phase" "3 - summary & alignment ($stop_reason)"

    local final_benchmark_context=""
    if [[ ${#BENCHMARK_SCRIPTS[@]} -gt 0 && -n "$benchmark_output" ]]; then
        final_benchmark_context="\n\nFinal benchmark results:\n$benchmark_output\n\nInclude these benchmark results in the summary."
    fi

    local dropped_context
    dropped_context="$(build_dropped_context "${FILES[@]}")"

    WIGGUM_CURRENT_LABEL="phase3-summary"
    run_claude -p -c \
        "$(prompt_workplan "$file_list") Execution stopped because: $stop_reason. Review all implementation work done. 1. Update the plan files ($file_list) by marking completed tasks with [x]. 2. Write a concise execution summary to $SUMMARY_FILE covering: what was implemented, what was deferred, any issues encountered, verification results, and why execution stopped ($stop_reason).${final_benchmark_context}${dropped_context} $PROMPT_SUFFIX" \
        "${FILES[@]}"

    commit_or_skip "phase3-commit" "$SUMMARY_FILE and $file_list"

    echo "" >&2

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

    # Rename plan and summary to meaningful filenames
    if [[ "${FILES[0]}" == docs/stdin.md ]]; then
        local slug
        slug="$(slugify "${FILES[0]}")"
        local final_plan="docs/${slug}_plan.md"
        local final_summary="docs/${slug}_summary.md"
        mv "${FILES[0]}" "$final_plan"
        echo "Plan: $final_plan" >&2
        if [[ -f "$SUMMARY_FILE" ]]; then
            mv "$SUMMARY_FILE" "$final_summary"
            echo "Summary: $final_summary" >&2
        fi
    elif [[ -f "$SUMMARY_FILE" ]]; then
        echo "Summary: $SUMMARY_FILE" >&2
    fi

    log_entry "complete" "wiggum execution finished ($stop_reason)"
    echo "Status: $stop_reason" >&2
    echo "Log: $WIGGUM_LOG_FILE" >&2
    echo "Session: $WIGGUM_LAST_SESSION_ID" >&2
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
    run_claude -p \
        "Update the following documentation files: $output_list. Use the input files as context for what has changed: $input_list. For each output file: read its current content, then update it to reflect the changes described in the input files. Preserve the existing structure and style of each document. Only update sections that are affected by the changes. Do not rewrite sections that are already accurate. $PROMPT_SUFFIX" \
        "${inputs[@]}" "${outputs[@]}"

    commit_or_skip "${prev_label}-commit" "$output_list"

    echo "Documentation updated: $output_list"
}

run_check() {
    echo "=== WIGGUM CHECK MODE ==="
    if [[ "$NO_VERIFY" == true ]]; then
        echo "Error: --no-verify makes 'wiggum check' a no-op. Drop the flag or use a different command." >&2
        return "$EXIT_BAD_ARGS"
    fi
    if [[ ${#VERIFY_STEPS[@]} -eq 0 ]]; then
        echo "No verification steps configured in .wiggumrc. Nothing to check."
        return 0
    fi
    print_verify_steps 1
    echo ""

    WIGGUM_CURRENT_LABEL="check"
    if run_validation; then
        echo ""
        if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
            echo "Committing changes..."
            commit_or_skip "check-commit"
        fi
        if [[ -n "${WIGGUM_LAST_SESSION_ID:-}" ]]; then
            echo "Session: $WIGGUM_LAST_SESSION_ID"
        fi
        echo "=== ALL CHECKS PASSED ==="
    else
        echo ""
        if [[ -n "${WIGGUM_LAST_SESSION_ID:-}" ]]; then
            echo "Session: $WIGGUM_LAST_SESSION_ID"
        fi
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

# ── Run (prompt chaining) ─────────────────────────────────────────────────────

# Feed a series of prompts to Claude in one continuous session. The first
# prompt starts a fresh session (or resumes one from --session-file); every
# subsequent prompt continues it via run_claude's -c handling. With
# --session-file the session id is persisted so a later invocation (e.g. a
# cron job) can follow up in the same session.
run_prompts() {
    echo "=== WIGGUM RUN MODE ===" >&2
    echo "Prompts: ${#RUN_PROMPTS[@]}" >&2
    echo "Effort: $EFFORT" >&2
    echo "Permission mode: $PERMISSION_MODE" >&2

    # Resume a saved session unless told to start fresh with --new-session.
    if [[ -n "$RUN_SESSION_FILE" && "$RUN_NEW_SESSION" != true && -s "$RUN_SESSION_FILE" ]]; then
        WIGGUM_LAST_SESSION_ID="$(tr -d '[:space:]' < "$RUN_SESSION_FILE")"
        echo "Resuming session: $WIGGUM_LAST_SESSION_ID" >&2
    fi
    echo "" >&2

    # Log next to the session file when given, otherwise under docs/.
    if [[ -n "$RUN_SESSION_FILE" ]]; then
        log_init "$RUN_SESSION_FILE"
    else
        log_init "docs/run.md"
    fi

    # Show Claude's responses on stdout (session ids and chatter stay on
    # stderr) so `wiggum run ... > out.txt` captures the answers -- useful
    # for cron jobs that pipe the output somewhere.
    WIGGUM_SHOW_OUTPUT=true

    local idx=0 prompt
    for prompt in "${RUN_PROMPTS[@]}"; do
        idx=$((idx + 1))
        echo "--- Prompt $idx of ${#RUN_PROMPTS[@]} ---" >&2
        log_entry "run" "prompt $idx of ${#RUN_PROMPTS[@]}"
        WIGGUM_CURRENT_LABEL="run-$idx"
        if [[ $idx -eq 1 && -z "$WIGGUM_LAST_SESSION_ID" ]]; then
            run_claude -p "$prompt"
        else
            run_claude -p -c "$prompt"
        fi
        # Persist after each prompt so a follow-up can resume even if a later
        # prompt fails mid-chain.
        if [[ -n "$RUN_SESSION_FILE" ]]; then
            echo "$WIGGUM_LAST_SESSION_ID" > "$RUN_SESSION_FILE"
        fi
    done

    WIGGUM_SHOW_OUTPUT=false

    if [[ -n "$RUN_SESSION_FILE" ]]; then
        echo "Session saved to: $RUN_SESSION_FILE" >&2
    fi

    log_entry "complete" "wiggum run finished"
    echo "" >&2
    echo "Session: $WIGGUM_LAST_SESSION_ID" >&2
    echo "Log: $WIGGUM_LOG_FILE" >&2
    echo "=== WIGGUM RUN COMPLETE ===" >&2
}
