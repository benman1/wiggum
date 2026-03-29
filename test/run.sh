#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Lint (shellcheck) ==="
shellcheck -s bash "$PROJECT_DIR/wiggum.sh" "$PROJECT_DIR/lib/wiggum.sh" "$PROJECT_DIR/install.sh"
echo "Lint passed."
echo ""

echo "=== Tests (bats) ==="
bats "$SCRIPT_DIR/wiggum.bats"
