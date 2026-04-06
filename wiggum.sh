#!/usr/bin/env bash
set -euo pipefail
trap 'echo ""; echo "Interrupted."; exit 130' INT

###############################################################################
# wiggum - Self-driving agent loop (CLI entry point)
#
# All logic lives in lib/wiggum.sh. This file is the thin CLI wrapper.
###############################################################################

# Resolve symlinks so WIGGUM_ROOT points to the real install directory
WIGGUM_SELF="$0"
if [[ -L "$WIGGUM_SELF" ]]; then
    WIGGUM_SELF="$(readlink "$WIGGUM_SELF")"
fi
WIGGUM_ROOT="$(cd "$(dirname "$WIGGUM_SELF")" && pwd)"
# shellcheck source=lib/wiggum.sh disable=SC1091
source "$WIGGUM_ROOT/lib/wiggum.sh"

main() {
    parse_args "$@"

    if [[ "$MODE" == "init" || "$MODE" == "help" || "$MODE" == "-h" || "$MODE" == "--help" || -z "$MODE" ]]; then
        [[ "$MODE" == "init" ]] && run_init
        return 0
    fi

    load_config

    case "$MODE" in
        plan|execute)
            local base_file="${FILES[0]}"
            if [[ -n "$STDIN_FILE" && "$MODE" == "execute" ]]; then
                base_file="$(persist_stdin)"
                FILES[0]="$base_file"
                echo "Persisted stdin to: $base_file" >&2
            elif [[ -n "$STDIN_FILE" ]]; then
                base_file="docs/stdin.md"
            fi
            if [[ "$MODE" == "plan" ]]; then
                PLAN_FILE="$(derive_output_file "$MODE" "$base_file" "$PLAN_FILE")"
                run_plan
            else
                SUMMARY_FILE="$(derive_output_file "$MODE" "$base_file" "$SUMMARY_FILE")"
                run_execute
            fi
            ;;
        check)
            run_check
            ;;
        docs)
            run_docs
            ;;
    esac
}

main "$@"
