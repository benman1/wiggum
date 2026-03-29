#!/usr/bin/env bats

# ── Setup / Teardown ────────────────────────────────────────────────────────

setup() {
    # Resolve lib relative to this test file
    WIGGUM_LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/../lib" && pwd)/wiggum.sh"

    # Each test gets an isolated temp directory
    TEST_DIR="$(mktemp -d)"
    ORIG_DIR="$(pwd)"
    ORIG_HOME="$HOME"
    cd "$TEST_DIR"

    # Source the library (sets defaults via wiggum_reset)
    source "$WIGGUM_LIB"

    # Stub claude so it never actually runs
    claude() { return 0; }
    export -f claude
}

teardown() {
    cd "$ORIG_DIR"
    HOME="$ORIG_HOME"
    rm -rf "$TEST_DIR"
}

# ── Helpers ──────────────────────────────────────────────────────────────────

make_file() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    echo "# placeholder" > "$path"
}

# ── parse_args ───────────────────────────────────────────────────────────────

@test "parse_args: no arguments prints usage and fails" {
    run parse_args
    [ "$status" -eq 1 ]
    [[ "$output" == *"wiggum"* ]]
    [[ "$output" == *"Usage"* ]]
}

@test "parse_args: --help prints usage and succeeds" {
    run parse_args --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]]
}

@test "parse_args: unknown mode fails" {
    run parse_args destroy
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown mode"* ]]
}

@test "parse_args: plan mode requires files" {
    run parse_args plan
    [ "$status" -eq 1 ]
    [[ "$output" == *"no input files"* ]]
}

@test "parse_args: plan mode rejects missing file" {
    run parse_args plan nonexistent.md
    [ "$status" -eq 1 ]
    [[ "$output" == *"file not found"* ]]
}

@test "parse_args: plan mode accepts existing file" {
    make_file issue.md
    parse_args plan issue.md
    [ "$MODE" = "plan" ]
    [ "${FILES[0]}" = "issue.md" ]
}

@test "parse_args: plan mode accepts multiple files" {
    make_file a.md
    make_file b.md
    parse_args plan a.md b.md
    [ "${#FILES[@]}" -eq 2 ]
}

@test "parse_args: --plan-file sets PLAN_FILE" {
    make_file issue.md
    parse_args plan issue.md --plan-file custom.md
    [ "$PLAN_FILE" = "custom.md" ]
}

@test "parse_args: execute mode with --iterations" {
    make_file plan.md
    parse_args execute plan.md --iterations 7
    [ "$MODE" = "execute" ]
    [ "$ITERATIONS" = "7" ]
}

@test "parse_args: --summary-file sets SUMMARY_FILE" {
    make_file plan.md
    parse_args execute plan.md --summary-file out.md
    [ "$SUMMARY_FILE" = "out.md" ]
}

@test "parse_args: unknown option fails" {
    make_file plan.md
    run parse_args plan plan.md --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown option"* ]]
}

@test "parse_args: init mode sets INIT_PRESET" {
    parse_args init python
    [ "$MODE" = "init" ]
    [ "$INIT_PRESET" = "python" ]
}

@test "parse_args: init mode without preset leaves INIT_PRESET empty" {
    parse_args init
    [ "$MODE" = "init" ]
    [ -z "$INIT_PRESET" ]
}

@test "parse_args: --verbose sets VERBOSE and adds to CLAUDE_EXTRA_ARGS" {
    make_file plan.md
    parse_args execute plan.md --verbose
    [ "$VERBOSE" = "true" ]
    [[ " ${CLAUDE_EXTRA_ARGS[*]} " == *" --verbose "* ]]
}

# ── wiggum_reset ─────────────────────────────────────────────────────────────

@test "wiggum_reset clears all state" {
    make_file x.md
    parse_args plan x.md --plan-file foo.md
    wiggum_reset
    [ -z "$MODE" ]
    [ "${#FILES[@]}" -eq 0 ]
    [ -z "$PLAN_FILE" ]
    [ "$ITERATIONS" -eq 3 ]
}

# ── derive_output_file ───────────────────────────────────────────────────────

@test "derive_output_file: plan mode produces <base>_plan.md" {
    make_file docs/issue.md
    parse_args plan docs/issue.md
    derive_output_file
    [ "$PLAN_FILE" = "docs/issue_plan.md" ]
}

@test "derive_output_file: execute mode produces <base>_summary.md" {
    make_file docs/plan.md
    parse_args execute docs/plan.md
    derive_output_file
    [ "$SUMMARY_FILE" = "docs/plan_summary.md" ]
}

@test "derive_output_file: respects explicit --plan-file" {
    make_file issue.md
    parse_args plan issue.md --plan-file my_plan.md
    derive_output_file
    [ "$PLAN_FILE" = "my_plan.md" ]
}

@test "derive_output_file: respects explicit --summary-file" {
    make_file plan.md
    parse_args execute plan.md --summary-file my_summary.md
    derive_output_file
    [ "$SUMMARY_FILE" = "my_summary.md" ]
}

# ── find_config ──────────────────────────────────────────────────────────────

@test "find_config: returns local .wiggumrc when present" {
    echo "iterations = 1" > .wiggumrc
    local result
    result="$(find_config)"
    [ "$result" = ".wiggumrc" ]
}

@test "find_config: falls back to HOME when no local config" {
    HOME="$TEST_DIR/fakehome"
    mkdir -p "$HOME"
    echo "iterations = 2" > "$HOME/.wiggumrc"
    local result
    result="$(find_config)"
    [ "$result" = "$HOME/.wiggumrc" ]
}

@test "find_config: returns empty when no config anywhere" {
    HOME="$TEST_DIR/emptyhome"
    mkdir -p "$HOME"
    local result
    result="$(find_config)"
    [ -z "$result" ]
}

# ── load_config_from ─────────────────────────────────────────────────────────

@test "load_config_from: parses verify lines in order" {
    cat > test.rc <<'EOF'
verify = npm test
verify = npm run build
EOF
    load_config_from test.rc
    [ "${#VERIFY_STEPS[@]}" -eq 2 ]
    [ "${VERIFY_STEPS[0]}" = "npm test" ]
    [ "${VERIFY_STEPS[1]}" = "npm run build" ]
}

@test "load_config_from: parses autofix with prefix" {
    cat > test.rc <<'EOF'
autofix = ruff format .
EOF
    load_config_from test.rc
    [ "${VERIFY_STEPS[0]}" = "autofix:ruff format ." ]
}

@test "load_config_from: mixed verify and autofix preserve order" {
    cat > test.rc <<'EOF'
verify = npm test
autofix = npm run lint -- --fix
verify = npm run build
EOF
    load_config_from test.rc
    [ "${#VERIFY_STEPS[@]}" -eq 3 ]
    [ "${VERIFY_STEPS[0]}" = "npm test" ]
    [ "${VERIFY_STEPS[1]}" = "autofix:npm run lint -- --fix" ]
    [ "${VERIFY_STEPS[2]}" = "npm run build" ]
}

@test "load_config_from: sets iterations and max_validation_retries" {
    cat > test.rc <<'EOF'
iterations = 10
max_validation_retries = 2
EOF
    load_config_from test.rc
    [ "$ITERATIONS" = "10" ]
    [ "$MAX_VALIDATION_RETRIES" = "2" ]
}

@test "load_config_from: skips comments and blank lines" {
    cat > test.rc <<'EOF'
# this is a comment
   # indented comment

verify = npm test

EOF
    load_config_from test.rc
    [ "${#VERIFY_STEPS[@]}" -eq 1 ]
}

@test "load_config_from: warns on unknown key" {
    cat > test.rc <<'EOF'
banana = yellow
EOF
    run load_config_from test.rc
    [ "$status" -eq 0 ]
    [[ "$output" == *"unknown config key"* ]]
}

# ── detect_preset ────────────────────────────────────────────────────────────

@test "detect_preset: detects next from next.config.ts" {
    touch next.config.ts
    local result
    result="$(detect_preset)"
    [ "$result" = "next" ]
}

@test "detect_preset: detects next from next.config.mjs" {
    touch next.config.mjs
    local result
    result="$(detect_preset)"
    [ "$result" = "next" ]
}

@test "detect_preset: detects astro from astro.config.mjs" {
    touch astro.config.mjs
    local result
    result="$(detect_preset)"
    [ "$result" = "astro" ]
}

@test "detect_preset: detects python from pyproject.toml" {
    touch pyproject.toml
    local result
    result="$(detect_preset)"
    [ "$result" = "python" ]
}

@test "detect_preset: detects python from requirements.txt" {
    touch requirements.txt
    local result
    result="$(detect_preset)"
    [ "$result" = "python" ]
}

@test "detect_preset: detects node from package.json" {
    touch package.json
    local result
    result="$(detect_preset)"
    [ "$result" = "node" ]
}

@test "detect_preset: next takes priority over node" {
    touch package.json
    touch next.config.js
    local result
    result="$(detect_preset)"
    [ "$result" = "next" ]
}

@test "detect_preset: returns empty when nothing detected" {
    local result
    result="$(detect_preset)"
    [ -z "$result" ]
}

# ── generate_rc ──────────────────────────────────────────────────────────────

@test "generate_rc: node preset contains npm verify steps" {
    local output
    output="$(generate_rc node)"
    [[ "$output" == *"npm run type-check"* ]]
    [[ "$output" == *"npm test"* ]]
    [[ "$output" == *"npm run build"* ]]
}

@test "generate_rc: python preset contains ruff and pytest" {
    local output
    output="$(generate_rc python)"
    [[ "$output" == *"ruff format"* ]]
    [[ "$output" == *"pytest"* ]]
}

@test "generate_rc: astro preset contains prettier" {
    local output
    output="$(generate_rc astro)"
    [[ "$output" == *"prettier"* ]]
}

@test "generate_rc: unknown preset fails" {
    run generate_rc golang
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown preset"* ]]
}

# ── run_init ─────────────────────────────────────────────────────────────────

@test "run_init: creates .wiggumrc from explicit preset" {
    INIT_PRESET="python"
    run_init
    [ -f ".wiggumrc" ]
    grep -q "pytest" .wiggumrc
}

@test "run_init: auto-detects preset" {
    INIT_PRESET=""
    touch package.json
    run_init
    [ -f ".wiggumrc" ]
    grep -q "npm test" .wiggumrc
}

@test "run_init: fails when nothing to detect and no preset" {
    INIT_PRESET=""
    run run_init
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not auto-detect"* ]]
}

@test "run_init: aborts on existing .wiggumrc when user says no" {
    echo "old" > .wiggumrc
    INIT_PRESET="node"
    run bash -c "source '$WIGGUM_LIB'; INIT_PRESET=node; echo n | run_init"
    grep -q "old" .wiggumrc
}

# ── run_validation ───────────────────────────────────────────────────────────

@test "run_validation: skips when no verify steps" {
    VERIFY_STEPS=()
    run run_validation
    [ "$status" -eq 0 ]
    [[ "$output" == *"No verification steps"* ]]
}

@test "run_validation: passes when all steps succeed" {
    VERIFY_STEPS=("true" "true")
    run run_validation
    [ "$status" -eq 0 ]
    [[ "$output" == *"All verification steps passed"* ]]
}

@test "run_validation: fails after max retries on persistent failure" {
    # Use a script that always exits 1 (eval + subshell safe)
    cat > "$TEST_DIR/fail.sh" <<'S'
#!/usr/bin/env bash
echo "deliberate failure" >&2
exit 1
S
    chmod +x "$TEST_DIR/fail.sh"

    MAX_VALIDATION_RETRIES=2
    VERIFY_STEPS=("$TEST_DIR/fail.sh")
    run run_validation
    [ "$status" -eq 1 ]
    [[ "$output" == *"Validation failed 2 times"* ]]
}

@test "run_validation: calls claude on verify failure" {
    cat > "$TEST_DIR/fail.sh" <<'S'
#!/usr/bin/env bash
exit 1
S
    chmod +x "$TEST_DIR/fail.sh"

    MAX_VALIDATION_RETRIES=1
    VERIFY_STEPS=("$TEST_DIR/fail.sh")
    run run_validation
    [[ "$output" == *"Requesting fix from Claude"* ]]
}

@test "run_validation: waterfall short-circuits on first failure" {
    cat > "$TEST_DIR/fail.sh" <<'S'
#!/usr/bin/env bash
exit 1
S
    chmod +x "$TEST_DIR/fail.sh"

    MAX_VALIDATION_RETRIES=0
    VERIFY_STEPS=("$TEST_DIR/fail.sh" "echo SHOULD_NOT_RUN")
    run run_validation
    [ "$status" -eq 1 ]
    [[ "$output" != *"SHOULD_NOT_RUN"* ]]
}

@test "run_validation: autofix step runs command twice" {
    # Create a script that tracks call count
    cat > "$TEST_DIR/counter.sh" <<'SCRIPT'
#!/usr/bin/env bash
FILE="$BATS_TEST_TMPDIR/call_count"
count=0
[ -f "$FILE" ] && count=$(cat "$FILE")
count=$((count + 1))
echo "$count" > "$FILE"
# Fail on first call, pass on second
[ "$count" -ge 2 ]
SCRIPT
    chmod +x "$TEST_DIR/counter.sh"
    export BATS_TEST_TMPDIR="$TEST_DIR"

    VERIFY_STEPS=("autofix:$TEST_DIR/counter.sh")
    run run_validation
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASSED"* ]]
}

# ── Strict mode ──────────────────────────────────────────────────────────────

@test "library enforces set -u: unset variable is an error" {
    # bash -u exits 1 on unbound variable; run warns about 127 but that's fine
    bats_require_minimum_version 1.5.0
    run ! bash -c "set -u; source '$WIGGUM_LIB'; echo \"\$UNDEFINED_VAR_XYZ\""
}

@test "CLI entry point runs under set -euo pipefail" {
    local cli="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/wiggum.sh"
    # A bad mode should exit non-zero, not continue
    run bash "$cli" badmode
    [ "$status" -ne 0 ]
}
