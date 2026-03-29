#!/usr/bin/env bash
set -euo pipefail

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

    if [[ "$MODE" == "init" ]]; then
        run_init
        return 0
    fi

    load_config

    case "$MODE" in
        plan)
            PLAN_FILE="$(derive_output_file "$MODE" "${FILES[0]}" "$PLAN_FILE")"
            run_plan
            ;;
        execute)
            SUMMARY_FILE="$(derive_output_file "$MODE" "${FILES[0]}" "$SUMMARY_FILE")"
            run_execute
            ;;
        docs)
            run_docs
            ;;
    esac
}

main "$@"
