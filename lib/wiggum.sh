#!/usr/bin/env bash
# wiggum core library — sourced by the CLI and by tests

VERSION="0.1.0"

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
            verify)
                VERIFY_STEPS+=("$value")
                ;;
            autofix)
                VERIFY_STEPS+=("autofix:$value")
                ;;
            iterations)
                ITERATIONS="$value"
                ;;
            max_validation_retries)
                MAX_VALIDATION_RETRIES="$value"
                ;;
            *)
                echo "Warning: unknown config key '$key'" >&2
                ;;
        esac
    done < "$config_file"
}

load_config() {
    local config_file
    config_file="$(find_config)"

    if [[ -z "$config_file" ]]; then
        echo "No .wiggumrc found (checked ./ and ~/). Using defaults."
        return
    fi

    echo "Loading config from $config_file"
    load_config_from "$config_file"
}

# ── Argument parsing ─────────────────────────────────────────────────────────

usage() {
    cat <<EOF
wiggum $VERSION - Self-driving agent loop

Usage:
  wiggum init [preset]
  wiggum plan <files...> [--plan-file <output>]
  wiggum execute <files...> [--summary-file <output>] [--iterations <n>]

Modes:
  init      Generate a .wiggumrc for a standard project setup
  plan      Create a workplan from the given issue/spec files
  execute   Implement a workplan with iterative validation

Presets (for init):
  node      Node.js project (type-check, test, build, lint)
  next      Next.js project (type-check, test, build, lint)
  python    Python project (ruff, pytest)
  astro     Astro project (type-check, test, build, format)
  (none)    Auto-detect from project files

Options:
  --plan-file <path>      Output path for the generated plan (default: <base>_plan.md)
  --summary-file <path>   Output path for the execution summary (default: <base>_summary.md)
  --iterations <n>        Number of implementation iterations (default: 3)
  --verbose               Pass --verbose to Claude Code for detailed output
  -h, --help              Show this help

Configuration:
  Place a .wiggumrc file in the current directory or \$HOME.
  See README.md for config format.
EOF
}

parse_args() {
    if [[ $# -eq 0 ]]; then
        usage
        return 1
    fi

    MODE="$1"
    shift

    if [[ "$MODE" == "-h" || "$MODE" == "--help" ]]; then
        usage
        return 0
    fi

    if [[ "$MODE" != "plan" && "$MODE" != "execute" && "$MODE" != "init" ]]; then
        echo "Error: unknown mode '$MODE'. Use 'plan', 'execute', or 'init'." >&2
        return 1
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
                shift 2
                ;;
            --summary-file)
                SUMMARY_FILE="$2"
                shift 2
                ;;
            --iterations)
                ITERATIONS="$2"
                shift 2
                ;;
            --verbose)
                export VERBOSE=true
                CLAUDE_EXTRA_ARGS+=("--verbose")
                shift
                ;;
            -h|--help)
                usage
                return 0
                ;;
            -*)
                echo "Error: unknown option '$1'" >&2
                return 1
                ;;
            *)
                FILES+=("$1")
                shift
                ;;
        esac
    done

    if [[ ${#FILES[@]} -eq 0 ]]; then
        echo "Error: no input files specified." >&2
        return 1
    fi

    for f in "${FILES[@]}"; do
        if [[ ! -f "$f" ]]; then
            echo "Error: file not found: $f" >&2
            return 1
        fi
    done
}

# ── Output filenames ─────────────────────────────────────────────────────────

derive_output_file() {
    local base="${FILES[0]}"
    local dir
    dir="$(dirname "$base")"
    local name
    name="$(basename "$base" .md)"

    if [[ "$MODE" == "plan" ]]; then
        if [[ -z "$PLAN_FILE" ]]; then
            PLAN_FILE="${dir}/${name}_plan.md"
        fi
    elif [[ "$MODE" == "execute" ]]; then
        if [[ -z "$SUMMARY_FILE" ]]; then
            SUMMARY_FILE="${dir}/${name}_summary.md"
        fi
    fi
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
        *)
            echo "Error: unknown preset '$preset'." >&2
            echo "Available presets: node, next, python, astro" >&2
            return 1
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
            return 1
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
}

# ── Claude wrapper ───────────────────────────────────────────────────────────

run_claude() {
    claude ${CLAUDE_EXTRA_ARGS[@]+"${CLAUDE_EXTRA_ARGS[@]}"} "$@"
}

# ── Plan ─────────────────────────────────────────────────────────────────────

run_plan() {
    echo "=== WIGGUM PLAN MODE ==="
    echo "Input files: ${FILES[*]}"
    echo "Output plan: $PLAN_FILE"
    echo ""

    local file_list="${FILES[*]}"

    run_claude -p --permission-mode bypassPermissions \
        "You are a project planner. The issue/spec files to analyze are ONLY: $file_list. Ignore README.md and other repo documentation -- they are not input. Produce a detailed, actionable workplan as a markdown checklist with phases, discrete tasks (each with [ ] status), acceptance criteria, and dependencies. Write the plan to: $PLAN_FILE" \
        "${FILES[@]}"

    if [[ -f "$PLAN_FILE" ]]; then
        echo ""
        echo "Plan created: $PLAN_FILE"
    else
        echo "Warning: plan file was not created. Check Claude output above."
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
                    prompt="The verification step '$cmd' failed even after autofix. Fix these errors:\n$output"
                    needs_fix=true
                    break
                fi
            else
                if output=$(eval "$cmd" 2>&1); then
                    : # passed
                else
                    output=$(echo "$output" | tail -n 60)
                    echo "FAILED: $cmd"
                    prompt="The verification step '$cmd' failed. Fix these errors:\n$output"
                    needs_fix=true
                    break
                fi
            fi
            echo "PASSED: $cmd"
        done

        if [[ "$needs_fix" == true ]]; then
            if [[ $retries -ge $MAX_VALIDATION_RETRIES ]]; then
                echo "Validation failed $MAX_VALIDATION_RETRIES times. Stopping to prevent runaway."
                return 1
            fi
            echo "Requesting fix from Claude..."
            run_claude -p -c --permission-mode acceptEdits "$(echo -e "$prompt")"
            retries=$((retries + 1))
            continue
        fi

        echo "All verification steps passed."
        return 0
    done
}

# ── Execute ──────────────────────────────────────────────────────────────────

run_execute() {
    echo "=== WIGGUM EXECUTE MODE ==="
    echo "Input files: ${FILES[*]}"
    echo "Iterations: $ITERATIONS"
    echo "Summary output: $SUMMARY_FILE"
    if [[ ${#VERIFY_STEPS[@]} -gt 0 ]]; then
        echo "Verification steps: ${VERIFY_STEPS[*]}"
    else
        echo "Verification steps: (none configured)"
    fi
    echo ""

    local file_list="${FILES[*]}"

    # Phase 1: Diagnostic & status sync
    echo "--- Phase 1: Diagnostic & Status Sync ---"
    run_claude -p --permission-mode acceptEdits \
        "The workplan is defined ONLY in: $file_list. Ignore README.md and other documentation -- they are NOT the plan. Analyze the repository against the workplan. If implementation status is inaccurate, update the plan using [x] for done, [ ] for not done. Do not change the plan structure. List the next steps to implement." \
        "${FILES[@]}"

    run_claude -p --permission-mode acceptEdits \
        "If $file_list was modified, execute 'git add $file_list' and 'git commit -m \"reconcile plan status\"'. Single line message only."

    # Phase 2: Iterative implementation
    for ((i = 1; i <= ITERATIONS; i++)); do
        echo ""
        echo "--- Phase 2: Implementation step $i of $ITERATIONS ---"

        # Implementation: fresh session with plan context
        run_claude -p -c --permission-mode acceptEdits \
            "The workplan is defined ONLY in: $file_list. Ignore README.md and other documentation -- they are NOT the plan. Execute the next discrete implementation step from the plan. Write tests for new logic. Fix any existing issues found." \
            "${FILES[@]}"

        # Validation: uses -c to keep implementation context for fixes
        run_validation || echo "Warning: validation did not fully pass on iteration $i"

        # Commit: fresh session to review changes with full context window
        echo "Committing changes..."
        run_claude -p --permission-mode acceptEdits \
            "Review uncommitted changes. For each modified file, execute 'git add <file>' and 'git commit -m \"<message>\"'. The message MUST be a single line. DO NOT include any trailers, footers, or attributions. Use only the imperative mood describing the logic change."
    done

    # Phase 3: Summary & alignment
    echo ""
    echo "--- Phase 3: Summary & Alignment ---"
    run_claude -p -c --permission-mode acceptEdits \
        "The workplan is defined ONLY in: $file_list. Review all implementation work done. 1. Update the plan files ($file_list) by marking completed tasks with [x]. 2. Write a concise execution summary to $SUMMARY_FILE covering: what was implemented, what was deferred, any issues encountered, and verification results." \
        "${FILES[@]}"

    run_claude -p --permission-mode acceptEdits \
        "Stage and commit any remaining changes including $SUMMARY_FILE and $file_list. For each modified file, execute 'git add <file>' and 'git commit -m \"<message>\"'. Single line imperative messages only. DO NOT include any trailers, footers, or attributions."

    echo ""
    if [[ -f "$SUMMARY_FILE" ]]; then
        echo "Summary written to: $SUMMARY_FILE"
    fi
    echo "=== WIGGUM EXECUTION COMPLETE ==="
}
