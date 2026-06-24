#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# smoke.sh - End-to-end smoke test for the wiggum CLI.
#
# Exercises the real artifact on its Claude-free code paths only, so the run is
# deterministic and needs no Claude Code authentication. Every check runs in a
# fresh temp working directory with a temp HOME, so the real environment (and
# ~/.claude) is never touched. Prints "Smoke test passed." only if every check
# succeeds; exits non-zero on the first failure.
###############################################################################

# Resolve the repo root (smoke.sh lives at the top of the repo).
REPO="$(cd "$(dirname "$0")" && pwd)"

# Hermetic scratch space: a working dir and a HOME that init cannot escape.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wiggum_smoke.XXXXXX")"
TMP_HOME="$(mktemp -d "${TMPDIR:-/tmp}/wiggum_home.XXXXXX")"
trap 'rm -rf "$WORK" "$TMP_HOME"' EXIT

# Report a failed check and abort with a non-zero status.
fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# Confirm the repo root resolved to a real wiggum checkout before any check.
[[ -f "$REPO/wiggum.sh" ]] || fail "cannot find wiggum.sh under $REPO"

# Run every check from inside the hermetic working dir with the temp HOME.
export HOME="$TMP_HOME"
cd "$WORK"

# --- Checks are added by later plan steps. ---

echo "Smoke test passed."
