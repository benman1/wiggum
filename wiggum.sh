#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# wiggum - Self-driving agent loop (CLI entry point)
#
# All logic lives in lib/wiggum.sh. This file is the thin CLI wrapper.
###############################################################################

WIGGUM_ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/wiggum.sh
source "$WIGGUM_ROOT/lib/wiggum.sh"

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
