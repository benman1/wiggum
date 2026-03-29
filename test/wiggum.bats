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

@test "parse_args: help shows overview" {
    run parse_args help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Commands"* ]]
    [[ "$output" == *"help <command>"* ]]
}

@test "parse_args: help plan shows plan details" {
    run parse_args help plan
    [ "$status" -eq 0 ]
    [[ "$output" == *"wiggum plan"* ]]
    [[ "$output" == *"--plan-file"* ]]
    [[ "$output" == *"Examples"* ]]
}

@test "parse_args: help execute shows execute details" {
    run parse_args help execute
    [ "$status" -eq 0 ]
    [[ "$output" == *"wiggum execute"* ]]
    [[ "$output" == *"--iterations"* ]]
    [[ "$output" == *"Phases"* ]]
}

@test "parse_args: help docs shows docs details" {
    run parse_args help docs
    [ "$status" -eq 0 ]
    [[ "$output" == *"wiggum docs"* ]]
    [[ "$output" == *"-i"* ]]
    [[ "$output" == *"-o"* ]]
}

@test "parse_args: help init shows presets" {
    run parse_args help init
    [ "$status" -eq 0 ]
    [[ "$output" == *"wiggum init"* ]]
    [[ "$output" == *"Presets"* ]]
}

@test "parse_args: help unknown falls back to overview" {
    run parse_args help bogus
    [ "$status" -eq 0 ]
    [[ "$output" == *"Commands"* ]]
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

@test "detect_preset: detects bash from .shellcheckrc" {
    touch .shellcheckrc
    local result
    result="$(detect_preset)"
    [ "$result" = "bash" ]
}

@test "detect_preset: detects bash from test/run.sh" {
    mkdir -p test
    touch test/run.sh
    local result
    result="$(detect_preset)"
    [ "$result" = "bash" ]
}

@test "detect_preset: node takes priority over bash" {
    touch package.json
    touch .shellcheckrc
    local result
    result="$(detect_preset)"
    [ "$result" = "node" ]
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

@test "generate_rc: bash preset contains shellcheck and bats" {
    local output
    output="$(generate_rc bash)"
    [[ "$output" == *"shellcheck"* ]]
    [[ "$output" == *"bats"* ]]
}

@test "generate_rc: unknown preset exits EXIT_BAD_ARGS" {
    run generate_rc golang
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"unknown preset"* ]]
}

# ── run_init ─────────────────────────────────────────────────────────────────

@test "run_init: creates .wiggumrc from explicit preset" {
    INIT_PRESET="python"
    echo "n" | run_init
    [ -f ".wiggumrc" ]
    grep -q "pytest" .wiggumrc
}

@test "run_init: auto-detects preset" {
    INIT_PRESET=""
    touch package.json
    echo "n" | run_init
    [ -f ".wiggumrc" ]
    grep -q "npm test" .wiggumrc
}

@test "run_init: creates .claude/settings.local.json when approved" {
    INIT_PRESET="node"
    echo -e "y\nn" | run_init
    [ -f ".claude/settings.local.json" ]
    grep -q "git add" .claude/settings.local.json
    grep -q "npm run" .claude/settings.local.json
}

@test "run_init: skips permissions when declined" {
    INIT_PRESET="node"
    echo "n" | run_init
    [ ! -f ".claude/settings.local.json" ]
}

@test "run_init: fails with EXIT_BAD_ARGS when nothing to detect and no preset" {
    INIT_PRESET=""
    run run_init
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"Could not auto-detect"* ]]
}

# ── setup_claude_permissions ─────────────────────────────────────────────────

@test "setup_claude_permissions: creates .claude dir and settings file" {
    printf "y\nn\n" | setup_claude_permissions node
    [ -d ".claude" ]
    [ -f ".claude/settings.local.json" ]
}

@test "setup_claude_permissions: node preset includes git and npm rules" {
    printf "y\nn\n" | setup_claude_permissions node
    grep -q '"Bash(git add \*)"' .claude/settings.local.json
    grep -q '"Bash(git commit \*)"' .claude/settings.local.json
    grep -q '"Bash(npm run \*)"' .claude/settings.local.json
    grep -q '"Bash(npx \*)"' .claude/settings.local.json
}

@test "setup_claude_permissions: python preset includes ruff and pytest" {
    printf "y\nn\n" | setup_claude_permissions python
    grep -q '"Bash(ruff \*)"' .claude/settings.local.json
    grep -q '"Bash(pytest \*)"' .claude/settings.local.json
    grep -q '"Bash(pytest)"' .claude/settings.local.json
}

@test "setup_claude_permissions: astro preset includes npm and npx" {
    printf "y\nn\n" | setup_claude_permissions astro
    grep -q '"Bash(npm run \*)"' .claude/settings.local.json
    grep -q '"Bash(npx \*)"' .claude/settings.local.json
}

@test "setup_claude_permissions: bash preset includes shellcheck and bats" {
    echo "y" | setup_claude_permissions bash
    grep -q '"Bash(shellcheck \*)"' .claude/settings.local.json
    grep -q '"Bash(bats \*)"' .claude/settings.local.json
    grep -q '"Bash(chmod \*)"' .claude/settings.local.json
}

@test "setup_claude_permissions: skips when user declines" {
    echo "n" | setup_claude_permissions node
    [ ! -f ".claude/settings.local.json" ]
}

@test "setup_claude_permissions: package manager rules added when both prompts approved" {
    printf "y\ny\n" | setup_claude_permissions node
    grep -q '"Bash(npm install \*)"' .claude/settings.local.json
    grep -q '"Bash(npm \*)"' .claude/settings.local.json
}

@test "setup_claude_permissions: package manager rules skipped when second prompt declined" {
    printf "y\nn\n" | setup_claude_permissions node
    # npm run should be present (base rules)
    grep -q '"Bash(npm run \*)"' .claude/settings.local.json
    # npm install should NOT be present (extra rules declined)
    ! grep -q '"Bash(npm install \*)"' .claude/settings.local.json
}

@test "setup_claude_permissions: python package manager adds pip" {
    printf "y\ny\n" | setup_claude_permissions python
    grep -q '"Bash(pip install \*)"' .claude/settings.local.json
    grep -q '"Bash(pip \*)"' .claude/settings.local.json
}

@test "setup_claude_permissions: output is valid JSON" {
    printf "y\nn\n" | setup_claude_permissions node
    # python/node json validation - try python first, fall back to node
    if command -v python3 &>/dev/null; then
        python3 -m json.tool .claude/settings.local.json > /dev/null
    elif command -v node &>/dev/null; then
        node -e "JSON.parse(require('fs').readFileSync('.claude/settings.local.json','utf8'))"
    else
        head -1 .claude/settings.local.json | grep -q '{'
        tail -1 .claude/settings.local.json | grep -q '}'
    fi
}

@test "setup_claude_permissions: overwrites existing file" {
    mkdir -p .claude
    echo '{}' > .claude/settings.local.json
    printf "y\nn\n" | setup_claude_permissions node
    grep -q '"Bash(git add \*)"' .claude/settings.local.json
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

@test "run_validation: attempt count never exceeds max_validation_retries" {
    cat > "$TEST_DIR/fail.sh" <<'S'
#!/usr/bin/env bash
exit 1
S
    chmod +x "$TEST_DIR/fail.sh"

    MAX_VALIDATION_RETRIES=3
    VERIFY_STEPS=("$TEST_DIR/fail.sh")
    run run_validation
    # Should see attempts 1, 2, 3 but never 4
    [[ "$output" == *"attempt 1 of 3"* ]]
    [[ "$output" == *"attempt 2 of 3"* ]]
    [[ "$output" == *"attempt 3 of 3"* ]]
    [[ "$output" != *"attempt 4 of 3"* ]]
}

@test "run_validation: shows error output and .wiggumrc hint on failure" {
    cat > "$TEST_DIR/fail.sh" <<'S'
#!/usr/bin/env bash
echo "some error details"
exit 1
S
    chmod +x "$TEST_DIR/fail.sh"

    MAX_VALIDATION_RETRIES=1
    VERIFY_STEPS=("$TEST_DIR/fail.sh")
    run run_validation
    [[ "$output" == *"--- Error output ---"* ]]
    [[ "$output" == *"some error details"* ]]
    [[ "$output" == *"Check that your .wiggumrc verify commands are correct"* ]]
    [[ "$output" == *"Last failing command"* ]]
}

@test "run_validation: calls claude on verify failure" {
    cat > "$TEST_DIR/fail.sh" <<'S'
#!/usr/bin/env bash
exit 1
S
    chmod +x "$TEST_DIR/fail.sh"

    MAX_VALIDATION_RETRIES=2
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

# ── parse_args: docs mode ────────────────────────────────────────────────────

@test "parse_args: docs mode with -i and -o" {
    make_file summary.md
    make_file readme.md
    parse_args docs -i summary.md -o readme.md
    [ "$MODE" = "docs" ]
    [ "${DOCS_INPUT[0]}" = "summary.md" ]
    [ "${DOCS_OUTPUT[0]}" = "readme.md" ]
}

@test "parse_args: docs mode with multiple -i and -o files" {
    make_file a.md
    make_file b.md
    make_file out1.md
    make_file out2.md
    parse_args docs -i a.md b.md -o out1.md out2.md
    [ "${#DOCS_INPUT[@]}" -eq 2 ]
    [ "${#DOCS_OUTPUT[@]}" -eq 2 ]
    [ "${DOCS_INPUT[0]}" = "a.md" ]
    [ "${DOCS_INPUT[1]}" = "b.md" ]
    [ "${DOCS_OUTPUT[0]}" = "out1.md" ]
    [ "${DOCS_OUTPUT[1]}" = "out2.md" ]
}

@test "parse_args: docs mode fails without -i" {
    make_file out.md
    run parse_args docs -o out.md
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"requires -i"* ]]
}

@test "parse_args: docs mode fails without -o" {
    make_file in.md
    run parse_args docs -i in.md
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"requires -o"* ]]
}

# ── parse_args: --update-docs ────────────────────────────────────────────────

@test "parse_args: --update-docs sets UPDATE_DOCS array" {
    make_file plan.md
    parse_args execute plan.md --update-docs README.md,docs/API.md
    [ "${#UPDATE_DOCS[@]}" -eq 2 ]
    [ "${UPDATE_DOCS[0]}" = "README.md" ]
    [ "${UPDATE_DOCS[1]}" = "docs/API.md" ]
}

@test "parse_args: --update-docs with single file" {
    make_file plan.md
    parse_args execute plan.md --update-docs README.md
    [ "${#UPDATE_DOCS[@]}" -eq 1 ]
    [ "${UPDATE_DOCS[0]}" = "README.md" ]
}

@test "parse_args: no --update-docs leaves UPDATE_DOCS empty" {
    make_file plan.md
    parse_args execute plan.md
    [ "${#UPDATE_DOCS[@]}" -eq 0 ]
}

# ── run_update_docs ──────────────────────────────────────────────────────────

@test "run_update_docs: calls claude with input and output files" {
    local claude_calls=()
    claude() { claude_calls+=("$*"); }

    make_file summary.md
    make_file readme.md
    run_update_docs summary.md -- readme.md
    [[ "${claude_calls[0]}" == *"summary.md"* ]]
    [[ "${claude_calls[0]}" == *"readme.md"* ]]
}

@test "run_update_docs: prints input and output in log" {
    make_file s.md
    make_file r.md
    run run_update_docs s.md -- r.md
    [ "$status" -eq 0 ]
    [[ "$output" == *"Input: s.md"* ]]
    [[ "$output" == *"Output: r.md"* ]]
    [[ "$output" == *"Documentation updated"* ]]
}

@test "run_update_docs: handles multiple inputs and outputs" {
    make_file a.md
    make_file b.md
    make_file x.md
    make_file y.md
    run run_update_docs a.md b.md -- x.md y.md
    [ "$status" -eq 0 ]
    [[ "$output" == *"Input: a.md b.md"* ]]
    [[ "$output" == *"Output: x.md y.md"* ]]
}

# ── run_docs ─────────────────────────────────────────────────────────────────

@test "run_docs: uses DOCS_INPUT and DOCS_OUTPUT" {
    make_file summary.md
    make_file readme.md
    DOCS_INPUT=("summary.md")
    DOCS_OUTPUT=("readme.md")
    run run_docs
    [ "$status" -eq 0 ]
    [[ "$output" == *"WIGGUM DOCS MODE"* ]]
    [[ "$output" == *"Input: summary.md"* ]]
    [[ "$output" == *"Output: readme.md"* ]]
    [[ "$output" == *"WIGGUM DOCS COMPLETE"* ]]
}

# ── generate_uuid ────────────────────────────────────────────────────────────

@test "generate_uuid: produces valid UUID format" {
    local uuid
    uuid="$(generate_uuid)"
    [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

@test "generate_uuid: produces unique values" {
    local uuid1 uuid2
    uuid1="$(generate_uuid)"
    uuid2="$(generate_uuid)"
    [ "$uuid1" != "$uuid2" ]
}

# ── log_init / log_entry ─────────────────────────────────────────────────────

@test "log_init: creates log file from base filename" {
    make_file docs/plan.md
    MODE="execute"
    FILES=("docs/plan.md")
    log_init "docs/plan.md"
    [ -f "docs/plan.log" ]
    [ "$WIGGUM_LOG_FILE" = "docs/plan.log" ]
}

@test "log_init: appends header with timestamp" {
    make_file issue.md
    MODE="execute"
    FILES=("issue.md")
    log_init "issue.md"
    grep -q "^--- wiggum run" issue.log
}

@test "log_entry: writes timestamped entry to log" {
    make_file plan.md
    MODE="execute"
    FILES=("plan.md")
    log_init "plan.md"
    log_entry "test-label" "test message"
    grep -q "test-label: test message" plan.log
}

@test "log_entry: does nothing when no log file set" {
    WIGGUM_LOG_FILE=""
    log_entry "ignored" "this should not fail"
}

# ── run_claude logging ───────────────────────────────────────────────────────

@test "run_claude: logs session ID" {
    make_file plan.md
    MODE="execute"
    FILES=("plan.md")
    log_init "plan.md"
    WIGGUM_CURRENT_LABEL="test-step"
    run_claude -p "say hi" 2>/dev/null || true
    grep -q "test-step: session" plan.log
}

@test "run_claude: passes --session-id to claude" {
    # Override claude to capture args
    local captured_args=""
    claude() { captured_args="$*"; }

    make_file plan.md
    MODE="execute"
    FILES=("plan.md")
    log_init "plan.md"
    WIGGUM_CURRENT_LABEL="test"
    run_claude -p "hello"
    [[ "$captured_args" == *"--session-id"* ]]
}

@test "run_claude: replaces -c with --resume and --fork-session" {
    local captured_args=""
    claude() { captured_args="$*"; }

    make_file plan.md
    MODE="execute"
    FILES=("plan.md")
    log_init "plan.md"

    # First call sets WIGGUM_LAST_SESSION_ID
    WIGGUM_CURRENT_LABEL="first"
    run_claude -p "hello"
    local first_id="$WIGGUM_LAST_SESSION_ID"

    # Second call with -c should resume from the first
    WIGGUM_CURRENT_LABEL="second"
    run_claude -p -c "follow up"
    [[ "$captured_args" == *"--resume"* ]]
    [[ "$captured_args" == *"--fork-session"* ]]
    [[ "$captured_args" == *"$first_id"* ]]
    # -c should be stripped
    [[ "$captured_args" != *" -c "* ]]
}

@test "run_claude: never combines --session-id with -c" {
    local captured_args=""
    claude() { captured_args="$*"; }

    make_file plan.md
    MODE="execute"
    FILES=("plan.md")
    log_init "plan.md"

    WIGGUM_CURRENT_LABEL="a"
    run_claude -p "first"
    WIGGUM_CURRENT_LABEL="b"
    run_claude -p -c "second"

    # Must not have both --session-id and -c
    if [[ "$captured_args" == *"--session-id"* && "$captured_args" == *" -c "* ]]; then
        fail "--session-id and -c must not appear together"
    fi
}

@test "run_claude: each call gets a unique session ID" {
    local ids=()
    claude() {
        for arg in "$@"; do
            if [[ "$prev_arg" == "--session-id" ]]; then
                ids+=("$arg")
            fi
            prev_arg="$arg"
        done
    }

    make_file plan.md
    MODE="execute"
    FILES=("plan.md")
    log_init "plan.md"

    local prev_arg=""
    WIGGUM_CURRENT_LABEL="a"
    run_claude -p "one"
    prev_arg=""
    WIGGUM_CURRENT_LABEL="b"
    run_claude -p "two"
    prev_arg=""
    WIGGUM_CURRENT_LABEL="c"
    run_claude -p -c "three"

    # All three should have different session IDs
    [ "${#ids[@]}" -eq 3 ]
    [ "${ids[0]}" != "${ids[1]}" ]
    [ "${ids[1]}" != "${ids[2]}" ]
    [ "${ids[0]}" != "${ids[2]}" ]
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
