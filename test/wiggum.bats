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

@test "parse_args: no arguments prints usage and exits EXIT_BAD_ARGS" {
    run parse_args
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"wiggum"* ]]
    [[ "$output" == *"Usage"* ]]
}

@test "parse_args: --help prints usage and succeeds" {
    run parse_args --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]]
}

@test "parse_args: unknown mode exits EXIT_BAD_ARGS" {
    run parse_args destroy
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"unknown mode"* ]]
}

@test "parse_args: plan mode requires files" {
    run parse_args plan
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"no input files"* ]]
}

@test "parse_args: plan mode rejects missing file" {
    run parse_args plan nonexistent.md
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"file not found"* ]]
}

@test "parse_args: rejects file outside project directory with EXIT_BAD_ARGS" {
    local outside
    outside="$(mktemp -d)"
    echo "# issue" > "$outside/issue.md"
    run parse_args plan "$outside/issue.md"
    rm -rf "$outside"
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"outside the project directory"* ]]
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

@test "parse_args: --iterations takes precedence over config" {
    make_file plan.md
    parse_args execute plan.md --iterations 7
    # Config would set iterations=3, but CLI should win
    cat > test.rc <<'EOF'
iterations = 3
EOF
    apply_config < <(load_config_from test.rc)
    [ "$ITERATIONS" = "7" ]
}

@test "parse_args: --summary-file sets SUMMARY_FILE" {
    make_file plan.md
    parse_args execute plan.md --summary-file out.md
    [ "$SUMMARY_FILE" = "out.md" ]
}

@test "parse_args: unknown option exits EXIT_BAD_ARGS" {
    make_file plan.md
    run parse_args plan plan.md --bogus
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
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
    local result
    result="$(derive_output_file plan docs/issue.md "")"
    [ "$result" = "docs/issue_plan.md" ]
}

@test "derive_output_file: execute mode produces <base>_summary.md" {
    local result
    result="$(derive_output_file execute docs/plan.md "")"
    [ "$result" = "docs/plan_summary.md" ]
}

@test "derive_output_file: passes through explicit value for plan" {
    local result
    result="$(derive_output_file plan issue.md "my_plan.md")"
    [ "$result" = "my_plan.md" ]
}

@test "derive_output_file: passes through explicit value for execute" {
    local result
    result="$(derive_output_file execute plan.md "my_summary.md")"
    [ "$result" = "my_summary.md" ]
}

@test "derive_output_file: handles nested paths" {
    local result
    result="$(derive_output_file plan src/docs/feature.md "")"
    [ "$result" = "src/docs/feature_plan.md" ]
}

@test "derive_output_file: strips only .md extension" {
    local result
    result="$(derive_output_file plan notes.txt.md "")"
    [ "$result" = "./notes.txt_plan.md" ]
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

@test "load_config_from: outputs verify lines to stdout" {
    cat > test.rc <<'EOF'
verify = npm test
verify = npm run build
EOF
    local output
    output="$(load_config_from test.rc)"
    [[ "$output" == *"verify=npm test"* ]]
    [[ "$output" == *"verify=npm run build"* ]]
}

@test "load_config_from: outputs autofix lines to stdout" {
    cat > test.rc <<'EOF'
autofix = ruff format .
EOF
    local output
    output="$(load_config_from test.rc)"
    [ "$output" = "autofix=ruff format ." ]
}

@test "load_config_from: outputs iterations and max_validation_retries" {
    cat > test.rc <<'EOF'
iterations = 10
max_validation_retries = 2
EOF
    local output
    output="$(load_config_from test.rc)"
    [[ "$output" == *"iterations=10"* ]]
    [[ "$output" == *"max_validation_retries=2"* ]]
}

@test "load_config_from: skips comments and blank lines" {
    cat > test.rc <<'EOF'
# this is a comment
   # indented comment

verify = npm test

EOF
    local output
    output="$(load_config_from test.rc)"
    local count
    count="$(echo "$output" | grep -c .)"
    [ "$count" -eq 1 ]
}

@test "load_config_from: warns on unknown key to stderr" {
    cat > test.rc <<'EOF'
banana = yellow
EOF
    run load_config_from test.rc
    [ "$status" -eq 0 ]
    [[ "$output" == *"unknown config key"* ]]
}

# ── apply_config ─────────────────────────────────────────────────────────────

@test "apply_config: applies verify steps in order" {
    cat > test.rc <<'EOF'
verify = npm test
verify = npm run build
EOF
    apply_config < <(load_config_from test.rc)
    [ "${#VERIFY_STEPS[@]}" -eq 2 ]
    [ "${VERIFY_STEPS[0]}" = "npm test" ]
    [ "${VERIFY_STEPS[1]}" = "npm run build" ]
}

@test "apply_config: applies autofix with prefix" {
    apply_config <<< "autofix=ruff format ."
    [ "${VERIFY_STEPS[0]}" = "autofix:ruff format ." ]
}

@test "apply_config: mixed verify and autofix preserve order" {
    cat > test.rc <<'EOF'
verify = npm test
autofix = npm run lint -- --fix
verify = npm run build
EOF
    apply_config < <(load_config_from test.rc)
    [ "${#VERIFY_STEPS[@]}" -eq 3 ]
    [ "${VERIFY_STEPS[0]}" = "npm test" ]
    [ "${VERIFY_STEPS[1]}" = "autofix:npm run lint -- --fix" ]
    [ "${VERIFY_STEPS[2]}" = "npm run build" ]
}

@test "apply_config: sets iterations and max_validation_retries" {
    apply_config <<< "$(printf "iterations=10\nmax_validation_retries=2")"
    [ "$ITERATIONS" = "10" ]
    [ "$MAX_VALIDATION_RETRIES" = "2" ]
}

@test "apply_config: CLI_ITERATIONS takes precedence over config" {
    CLI_ITERATIONS="7"
    ITERATIONS="7"
    apply_config <<< "iterations=10"
    [ "$ITERATIONS" = "7" ]
}

@test "apply_config: CLI_MAX_RETRIES takes precedence over config" {
    CLI_MAX_RETRIES="3"
    MAX_VALIDATION_RETRIES="3"
    apply_config <<< "max_validation_retries=10"
    [ "$MAX_VALIDATION_RETRIES" = "3" ]
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

@test "generate_rc: unknown preset exits EXIT_BAD_ARGS" {
    run generate_rc golang
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
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

@test "run_init: fails with EXIT_BAD_ARGS when nothing to detect and no preset" {
    INIT_PRESET=""
    run run_init
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
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

@test "run_validation: fails with EXIT_VALIDATION_FAILED after max retries" {
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
    [ "$status" -eq "$EXIT_VALIDATION_FAILED" ]
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
    [ "$status" -eq "$EXIT_VALIDATION_FAILED" ]
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

# ── Exit codes ───────────────────────────────────────────────────────────────

@test "exit codes: constants are distinct non-zero integers" {
    [ "$EXIT_BAD_ARGS" -ne 0 ]
    [ "$EXIT_NO_CONFIG" -ne 0 ]
    [ "$EXIT_VALIDATION_FAILED" -ne 0 ]
    [ "$EXIT_CLAUDE_FAILED" -ne 0 ]
    # All distinct
    [ "$EXIT_BAD_ARGS" -ne "$EXIT_NO_CONFIG" ]
    [ "$EXIT_BAD_ARGS" -ne "$EXIT_VALIDATION_FAILED" ]
    [ "$EXIT_BAD_ARGS" -ne "$EXIT_CLAUDE_FAILED" ]
    [ "$EXIT_NO_CONFIG" -ne "$EXIT_VALIDATION_FAILED" ]
    [ "$EXIT_NO_CONFIG" -ne "$EXIT_CLAUDE_FAILED" ]
    [ "$EXIT_VALIDATION_FAILED" -ne "$EXIT_CLAUDE_FAILED" ]
}

# ── Strict mode ──────────────────────────────────────────────────────────────

@test "library enforces set -u: unset variable is an error" {
    # bash -u exits 1 on unbound variable; run warns about 127 but that's fine
    bats_require_minimum_version 1.5.0
    run ! bash -c "set -u; source '$WIGGUM_LIB'; echo \"\$UNDEFINED_VAR_XYZ\""
}

@test "lib/wiggum.sh rejects direct execution" {
    run bash "$WIGGUM_LIB"
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be sourced"* ]]
}

@test "CLI entry point runs under set -euo pipefail" {
    local cli="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/wiggum.sh"
    # A bad mode should exit non-zero, not continue
    run bash "$cli" badmode
    [ "$status" -ne 0 ]
}

@test "CLI entry point wraps dispatch in main function" {
    local cli="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/wiggum.sh"
    # main must be defined as a function in wiggum.sh
    grep -q '^main()' "$cli"
    # Last non-empty line must call main
    local last
    last="$(grep -v '^$' "$cli" | tail -1)"
    [ "$last" = 'main "$@"' ]
}
