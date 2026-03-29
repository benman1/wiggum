#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# wiggum - Self-driving agent loop
#
# Modes:
#   plan     - Create a workplan from issue files
#   execute  - Implement a workplan with iterative validation
#
# Usage:
#   wiggum plan <files...> [--plan-file <output>]
#   wiggum execute <files...> [--summary-file <output>] [--iterations <n>]
#
# Files can be individual paths, lists, or shell globs.
#
# Configuration (.wiggumrc):
#   Searched in current directory, then $HOME.
#   YAML-ish key=value format defining verification commands.
###############################################################################

VERSION="0.1.0"

# ── Defaults ─────────────────────────────────────────────────────────────────

MODE=""
FILES=()
PLAN_FILE=""
SUMMARY_FILE=""
ITERATIONS=3
MAX_VALIDATION_RETRIES=5
INIT_PRESET=""

# Verification steps loaded from config (fallback defaults)
# Each entry is "command" or "autofix:command" (autofix runs before asking Claude)
VERIFY_STEPS=()

# ── Config loading ───────────────────────────────────────────────────────────

load_config() {
    local config_file=""

    if [[ -f ".wiggumrc" ]]; then
        config_file=".wiggumrc"
    elif [[ -f "$HOME/.wiggumrc" ]]; then
        config_file="$HOME/.wiggumrc"
    fi

    if [[ -z "$config_file" ]]; then
        echo "No .wiggumrc found (checked ./ and ~/). Using defaults."
        return
    fi

    echo "Loading config from $config_file"

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        local key="${line%%=*}"
        local value="${line#*=}"
        # Trim whitespace
        key="$(echo "$key" | xargs)"
        value="$(echo "$value" | xargs)"

        case "$key" in
            verify)
                VERIFY_STEPS+=("$value")
                ;;
            autofix)
                # Autofix steps run the command (which may self-correct), then
                # only escalate to Claude if the command still fails after autofix
                VERIFY_STEPS+=("autofix:$value")
                ;;
            iterations)
                ITERATIONS="$value"
                ;;
            max_validation_retries)
                MAX_VALIDATION_RETRIES="$value"
                ;;
            *)
                echo "Warning: unknown config key '$key'"
                ;;
        esac
    done < "$config_file"
}

# ── Argument parsing ────────────────────────────────────────────────────────

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
  -h, --help              Show this help

Configuration:
  Place a .wiggumrc file in the current directory or \$HOME.
  See README.md for config format.
EOF
    exit 0
}

parse_args() {
    if [[ $# -eq 0 ]]; then
        usage
    fi

    MODE="$1"
    shift

    if [[ "$MODE" == "-h" || "$MODE" == "--help" ]]; then
        usage
    fi

    if [[ "$MODE" != "plan" && "$MODE" != "execute" && "$MODE" != "init" ]]; then
        echo "Error: unknown mode '$MODE'. Use 'plan', 'execute', or 'init'."
        exit 1
    fi

    # init mode doesn't need input files
    if [[ "$MODE" == "init" ]]; then
        # optional: first positional arg is the preset name
        if [[ $# -gt 0 && ! "$1" == -* ]]; then
            INIT_PRESET="$1"
            shift
        fi
        return
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
            -h|--help)
                usage
                ;;
            -*)
                echo "Error: unknown option '$1'"
                exit 1
                ;;
            *)
                FILES+=("$1")
                shift
                ;;
        esac
    done

    if [[ ${#FILES[@]} -eq 0 ]]; then
        echo "Error: no input files specified."
        exit 1
    fi

    # Verify all input files exist
    for f in "${FILES[@]}"; do
        if [[ ! -f "$f" ]]; then
            echo "Error: file not found: $f"
            exit 1
        fi
    done
}

# ── Derive output filenames ─────────────────────────────────────────────────

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

# ── Init mode ────────────────────────────────────────────────────────────────

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
            echo "Error: unknown preset '$preset'."
            echo "Available presets: node, next, python, astro"
            return 1
            ;;
    esac
}

run_init() {
    local preset="$INIT_PRESET"

    # Auto-detect if no preset given
    if [[ -z "$preset" ]]; then
        preset=$(detect_preset)
        if [[ -z "$preset" ]]; then
            echo "Could not auto-detect project type."
            echo "Specify a preset: wiggum init <node|next|python|astro>"
            exit 1
        fi
        echo "Detected project type: $preset"
    fi

    if [[ -f ".wiggumrc" ]]; then
        echo "A .wiggumrc already exists in this directory. Overwrite? [y/N]"
        read -r answer
        if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
            echo "Aborted."
            exit 0
        fi
    fi

    generate_rc "$preset" > .wiggumrc
    echo "Created .wiggumrc ($preset preset)"
}

# ── Plan mode ────────────────────────────────────────────────────────────────

run_plan() {
    echo "=== WIGGUM PLAN MODE ==="
    echo "Input files: ${FILES[*]}"
    echo "Output plan: $PLAN_FILE"
    echo ""

    claude -p --permission-mode bypassPermissions \
        "You are a project planner. Analyze the following issue/spec files and produce a detailed, actionable workplan. Structure the plan as a markdown checklist with phases, discrete tasks (each with [ ] status), acceptance criteria, and dependencies. Write the plan to: $PLAN_FILE" \
        "${FILES[@]}"

    if [[ -f "$PLAN_FILE" ]]; then
        echo ""
        echo "Plan created: $PLAN_FILE"
    else
        echo "Warning: plan file was not created. Check Claude output above."
    fi
}

# ── Execute mode ─────────────────────────────────────────────────────────────

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

            # Handle autofix: prefix
            if [[ "$step" == autofix:* ]]; then
                is_autofix=true
                cmd="${step#autofix:}"
            fi

            echo "Running: $cmd"
            local output

            if $is_autofix; then
                # Autofix: run the command (it may self-correct, e.g. ruff --fix).
                # If it still fails after autofix, capture output for Claude.
                eval "$cmd" 2>&1 || true
                if ! output=$(eval "$cmd" 2>&1 | tail -n 60); then
                    echo "FAILED (after autofix): $cmd"
                    prompt="The verification step '$cmd' failed even after autofix. Fix these errors:\n$output"
                    needs_fix=true
                    break
                fi
            else
                if ! output=$(eval "$cmd" 2>&1 | tail -n 60); then
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
            claude -p -c --permission-mode acceptEdits "$(echo -e "$prompt")"
            retries=$((retries + 1))
            continue
        fi

        echo "All verification steps passed."
        return 0
    done
}

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

    # Phase 1: Diagnostic & status sync
    echo "--- Phase 1: Diagnostic & Status Sync ---"
    claude -p --permission-mode acceptEdits \
        "Analyze the repository against the provided plan/spec files. If implementation status is inaccurate, update it using [x] for done, [ ] for not done. List the next steps to implement." \
        "${FILES[@]}"

    claude -c -p --permission-mode acceptEdits \
        "If any plan files were modified, stage and commit them with a message like 'reconcile plan status'. Single line commit message only."

    # Phase 2: Iterative implementation
    for ((i = 1; i <= ITERATIONS; i++)); do
        echo ""
        echo "--- Phase 2: Implementation step $i of $ITERATIONS ---"

        claude -p -c --permission-mode acceptEdits \
            "Using the provided plan/spec files, execute the next discrete implementation step. Write tests for new logic." \
            "${FILES[@]}"

        run_validation || echo "Warning: validation did not fully pass on iteration $i"

        echo "Committing changes..."
        claude -c -p --permission-mode acceptEdits \
            "Review uncommitted changes. For each logically distinct change, execute 'git add <files>' and 'git commit -m \"<message>\"'. Single line imperative commit messages only."
    done

    # Phase 3: Summary & alignment
    echo ""
    echo "--- Phase 3: Summary & Alignment ---"
    claude -p -c --permission-mode acceptEdits \
        "Review all implementation work done. 1. Update the plan files by marking completed tasks with [x]. 2. Write a concise execution summary to $SUMMARY_FILE covering: what was implemented, what was deferred, any issues encountered, and verification results." \
        "${FILES[@]}"

    claude -c -p --permission-mode acceptEdits \
        "Stage and commit any remaining changes including $SUMMARY_FILE and updated plan files. Single line imperative commit messages only."

    echo ""
    if [[ -f "$SUMMARY_FILE" ]]; then
        echo "Summary written to: $SUMMARY_FILE"
    fi
    echo "=== WIGGUM EXECUTION COMPLETE ==="
}

# ── Main ─────────────────────────────────────────────────────────────────────

parse_args "$@"

if [[ "$MODE" == "init" ]]; then
    run_init
    exit 0
fi

load_config
derive_output_file

case "$MODE" in
    plan)    run_plan ;;
    execute) run_execute ;;
esac
