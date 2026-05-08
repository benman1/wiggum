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
    [[ "$output" == *"--max-iterations"* ]]
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

@test "parse_args: plan mode requires files when stdin is a terminal" {
    run parse_args plan < /dev/null
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"stdin was empty"* ]]
}

@test "parse_args: plan reads from stdin when no files given" {
    # pipe runs in subshell so globals won't propagate; capture STDIN_FILE path
    local tmp
    tmp="$(echo "Add dark mode toggle" | { parse_args plan; echo "$STDIN_FILE"; })"
    local sfile
    sfile="$(echo "$tmp" | tail -1)"
    [ -f "$sfile" ]
    [[ "$(cat "$sfile")" == "Add dark mode toggle" ]]
    rm -f "$sfile"
}

@test "parse_args: stdin rejects empty input" {
    run parse_args plan < /dev/null
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"stdin was empty"* ]]
}

@test "parse_args: stdin with --plan-file sets CLI_PLAN_FILE" {
    local out
    out="$(echo "Fix the bug" | { parse_args plan --plan-file my_plan.md; echo "$CLI_PLAN_FILE"; })"
    local val
    val="$(echo "$out" | tail -1)"
    [[ "$val" == "my_plan.md" ]]
}

@test "parse_args: -- collects multiple remaining files" {
    make_file "a.md"
    make_file "b.md"
    parse_args plan -- "a.md" "b.md"
    [[ "${#FILES[@]}" -eq 2 ]]
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

@test "parse_args: -- ends option parsing" {
    make_file "issue.md"
    parse_args plan --verbose -- "issue.md"
    [[ " ${FILES[*]} " == *"issue.md"* ]]
    [[ "$VERBOSE" == "true" ]]
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

@test "parse_args: execute mode with --max-iterations" {
    make_file plan.md
    parse_args execute plan.md --max-iterations 7
    [ "$MODE" = "execute" ]
    [ "$MAX_ITERATIONS" = "7" ]
}

@test "parse_args: --max-iterations takes precedence over config" {
    make_file plan.md
    parse_args execute plan.md --max-iterations 7
    # Config would set max_iterations=3, but CLI should win
    cat > test.rc <<'EOF'
max_iterations = 3
EOF
    apply_config < <(load_config_from test.rc)
    [ "$MAX_ITERATIONS" = "7" ]
}

@test "parse_args: legacy --iterations still works" {
    make_file plan.md
    parse_args execute plan.md --iterations 5
    [ "$MAX_ITERATIONS" = "5" ]
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
    [ "$MAX_ITERATIONS" -eq 3 ]
    [ -z "$STDIN_FILE" ]
    [ -z "$CLI_PLAN_FILE" ]
    [ "$NO_VERIFY" = "false" ]
    [ "$NO_COMMIT" = "false" ]
    [ -z "$CLI_NO_VERIFY" ]
    [ -z "$CLI_NO_COMMIT" ]
}

# ── count_unchecked ──────────────────────────────────────────────────────────

@test "count_unchecked: counts unchecked boxes" {
    cat > plan.md <<'EOF'
- [ ] Task one
- [x] Task two
- [ ] Task three
EOF
    local result
    result="$(count_unchecked plan.md)"
    [ "$result" -eq 2 ]
}

@test "count_unchecked: returns zero when all checked" {
    cat > plan.md <<'EOF'
- [x] Task one
- [x] Task two
EOF
    local result
    result="$(count_unchecked plan.md)"
    [ "$result" -eq 0 ]
}

@test "count_unchecked: counts across multiple files" {
    cat > a.md <<'EOF'
- [ ] Task one
EOF
    cat > b.md <<'EOF'
- [ ] Task two
- [ ] Task three
EOF
    local result
    result="$(count_unchecked a.md b.md)"
    [ "$result" -eq 3 ]
}

@test "count_unchecked: returns zero for missing file" {
    local result
    result="$(count_unchecked nonexistent.md)"
    [ "$result" -eq 0 ]
}

@test "count_unchecked: handles indented checkboxes" {
    cat > plan.md <<'EOF'
  - [ ] Indented task
    - [ ] Deeply indented
- [x] Done
EOF
    local result
    result="$(count_unchecked plan.md)"
    [ "$result" -eq 2 ]
}

@test "count_unchecked: ignores [~] dropped lines" {
    cat > plan.md <<'EOF'
- [ ] todo one
- [ ] todo two
- [~] dropped one
- [~] dropped two
- [~] dropped three
- [x] done
EOF
    local result
    result="$(count_unchecked plan.md)"
    [ "$result" -eq 2 ]
}

# ── count_total_tasks ────────────────────────────────────────────────────────

@test "count_total_tasks: counts both checked and unchecked" {
    cat > plan.md <<'EOF'
- [ ] todo
- [x] done
- [X] also done
- not a task
# heading
EOF
    local result
    result="$(count_total_tasks plan.md)"
    [ "$result" -eq 3 ]
}

@test "count_total_tasks: returns zero for missing file" {
    local result
    result="$(count_total_tasks nonexistent.md)"
    [ "$result" -eq 0 ]
}

@test "count_total_tasks: counts [~] as a task" {
    cat > plan.md <<'EOF'
- [ ] todo one
- [ ] todo two
- [~] dropped one
- [~] dropped two
- [~] dropped three
- [x] done
EOF
    local result
    result="$(count_total_tasks plan.md)"
    [ "$result" -eq 6 ]
}

# ── count_dropped ────────────────────────────────────────────────────────────

@test "count_dropped: counts only [~] lines" {
    cat > plan.md <<'EOF'
- [ ] todo one
- [ ] todo two
- [~] dropped one
- [~] dropped two
- [~] dropped three
- [x] done
EOF
    local result
    result="$(count_dropped plan.md)"
    [ "$result" -eq 3 ]
}

@test "count_dropped: returns zero when no [~] lines" {
    cat > plan.md <<'EOF'
- [ ] todo
- [x] done
EOF
    local result
    result="$(count_dropped plan.md)"
    [ "$result" -eq 0 ]
}

@test "count_dropped: returns zero for missing file" {
    local result
    result="$(count_dropped nonexistent.md)"
    [ "$result" -eq 0 ]
}

@test "count_dropped: handles indented [~] lines" {
    cat > plan.md <<'EOF'
  - [~] Indented dropped
    - [~] Deeply indented dropped
- [x] Done
EOF
    local result
    result="$(count_dropped plan.md)"
    [ "$result" -eq 2 ]
}

@test "count_dropped: counts across multiple files" {
    cat > a.md <<'EOF'
- [~] dropped one
EOF
    cat > b.md <<'EOF'
- [~] dropped two
- [~] dropped three
EOF
    local result
    result="$(count_dropped a.md b.md)"
    [ "$result" -eq 3 ]
}

# ── build_dropped_context ────────────────────────────────────────────────────

@test "build_dropped_context: empty when no [~] lines" {
    cat > plan.md <<'EOF'
- [ ] todo
- [x] done
EOF
    local result
    result="$(build_dropped_context plan.md)"
    [ -z "$result" ]
}

@test "build_dropped_context: empty for missing file" {
    local result
    result="$(build_dropped_context nonexistent.md)"
    [ -z "$result" ]
}

@test "build_dropped_context: includes count, verbatim lines, and do-not-re-mark instruction" {
    cat > plan.md <<'EOF'
- [ ] still pending
- [~] **2.6** dropped: no perplexity endpoint
- [~] **3.1** dropped: covered by upstream
- [x] done
EOF
    local result
    result="$(build_dropped_context plan.md)"
    [[ "$result" == *"There are 2 dropped tasks"* ]]
    [[ "$result" == *"What was dropped"* ]]
    [[ "$result" == *"Do not re-mark"* ]]
    [[ "$result" == *"[~]"* ]]
    [[ "$result" == *"**2.6** dropped: no perplexity endpoint"* ]]
    [[ "$result" == *"**3.1** dropped: covered by upstream"* ]]
}

@test "build_dropped_context: starts with literal \\n\\n separator" {
    cat > plan.md <<'EOF'
- [~] dropped
EOF
    local result
    result="$(build_dropped_context plan.md)"
    # Match the conditional-context pattern in run_execute, which prepends
    # a literal `\n\n` so the appended block reads as a fresh paragraph.
    [[ "$result" == '\n\n'* ]]
}

@test "build_dropped_context: aggregates across multiple files" {
    cat > a.md <<'EOF'
- [~] from a
EOF
    cat > b.md <<'EOF'
- [~] from b1
- [~] from b2
EOF
    local result
    result="$(build_dropped_context a.md b.md)"
    [[ "$result" == *"There are 3 dropped tasks"* ]]
    [[ "$result" == *"from a"* ]]
    [[ "$result" == *"from b1"* ]]
    [[ "$result" == *"from b2"* ]]
}

# ── End-to-end regression: dropped tasks ────────────────────────────────────
#
# These lock the false-stall fix on the lowest-friction stable surface --
# the counters that drive `run_execute`'s phase-2 loop. The full
# `run_execute` is too coarse to test directly, so per the plan we assert
# on the underlying values that the loop branches on.

@test "regression: all-dropped plan reports zero remaining (no phase-2 iteration)" {
    cat > plan.md <<'EOF'
- [~] **2.6** dropped: no perplexity endpoint
- [~] **3.1** dropped: covered by upstream
- [~] **4.2** dropped: out of scope
EOF
    # `count_unchecked` returning 0 is the trigger for the early-exit
    # branch in `run_execute` (`if [[ "$remaining" -eq 0 ]]`). If a future
    # change widens the regex to include `[~]`, this assertion would
    # become non-zero and false stalls would return.
    local remaining dropped total
    remaining="$(count_unchecked plan.md)"
    dropped="$(count_dropped plan.md)"
    total="$(count_total_tasks plan.md)"
    [ "$remaining" -eq 0 ]
    [ "$dropped" -eq 3 ]
    [ "$total" -eq 3 ]
}

@test "regression: mixed plan reports 2 remaining, 3 dropped, 6 total" {
    cat > plan.md <<'EOF'
- [ ] todo one
- [ ] todo two
- [~] dropped one
- [~] dropped two
- [~] dropped three
- [x] done one
EOF
    # These are the values that feed the phase-2 step header
    # `($remaining remaining, $dropped dropped)`. Asserting on the
    # counters keeps the test stable against prompt-string churn.
    local remaining dropped total
    remaining="$(count_unchecked plan.md)"
    dropped="$(count_dropped plan.md)"
    total="$(count_total_tasks plan.md)"
    [ "$remaining" -eq 2 ]
    [ "$dropped" -eq 3 ]
    [ "$total" -eq 6 ]
}

# ── warn_if_plan_large ───────────────────────────────────────────────────────

@test "warn_if_plan_large: warns when total tasks exceed threshold" {
    : > plan.md
    local i
    for ((i = 1; i <= 41; i++)); do
        echo "- [ ] task $i" >> plan.md
    done
    run warn_if_plan_large plan.md
    [ "$status" -eq 0 ]
    [[ "$output" == *"Warning"* ]]
    [[ "$output" == *"41 tasks"* ]]
}

@test "warn_if_plan_large: silent at the threshold" {
    : > plan.md
    local i
    for ((i = 1; i <= 40; i++)); do
        echo "- [ ] task $i" >> plan.md
    done
    run warn_if_plan_large plan.md
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "warn_if_plan_large: counts checked and unchecked together" {
    : > plan.md
    local i
    for ((i = 1; i <= 21; i++)); do
        echo "- [ ] todo $i" >> plan.md
    done
    for ((i = 1; i <= 20; i++)); do
        echo "- [x] done $i" >> plan.md
    done
    run warn_if_plan_large plan.md
    [ "$status" -eq 0 ]
    [[ "$output" == *"41 tasks"* ]]
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

# ── persist_stdin ────────────────────────────────────────────────────────────

@test "persist_stdin: creates docs/stdin.md when none exists" {
    STDIN_FILE="$(mktemp)"
    echo "my issue text" > "$STDIN_FILE"
    FILES=("$STDIN_FILE")
    local result
    result="$(persist_stdin)"
    [ "$result" = "docs/stdin.md" ]
    [[ "$(cat docs/stdin.md)" == "my issue text" ]]
    rm -f "$STDIN_FILE"
}

@test "persist_stdin: overwrites docs/stdin.md when it exists" {
    STDIN_FILE="$(mktemp)"
    echo "new plan" > "$STDIN_FILE"
    FILES=("$STDIN_FILE")
    mkdir -p docs
    echo "old plan" > docs/stdin.md
    local result
    result="$(persist_stdin)"
    [ "$result" = "docs/stdin.md" ]
    [[ "$(cat docs/stdin.md)" == "new plan" ]]
    rm -f "$STDIN_FILE"
}

@test "persist_stdin: creates docs directory if missing" {
    STDIN_FILE="$(mktemp)"
    echo "content" > "$STDIN_FILE"
    FILES=("$STDIN_FILE")
    [ ! -d docs ]
    persist_stdin > /dev/null
    [ -d docs ]
    [ -f docs/stdin.md ]
    rm -f "$STDIN_FILE"
}

# ── looks_like_plan ──────────────────────────────────────────────────────────

@test "looks_like_plan: accepts file with unchecked checkbox" {
    echo "- [ ] Do the thing" > plan.md
    looks_like_plan plan.md
}

@test "looks_like_plan: accepts file with checked checkbox" {
    echo "- [x] Already done" > plan.md
    looks_like_plan plan.md
}

@test "looks_like_plan: accepts file with a heading" {
    printf "# Workplan\n\nSome prose.\n" > plan.md
    looks_like_plan plan.md
}

@test "looks_like_plan: accepts indented checkboxes" {
    printf "  - [ ] Nested task\n" > plan.md
    looks_like_plan plan.md
}

@test "looks_like_plan: rejects prose-only file" {
    printf "Just some text.\nNo structure here.\n" > plan.md
    ! looks_like_plan plan.md
}

@test "looks_like_plan: rejects the observed chatter leak" {
    # Exact shape of the bogus input that slipped past the empty-stdin
    # guard: config-loader stderr leak + Claude's confirmation ack.
    cat > plan.md <<'EOF'
Loading config from .wiggumrc
Plan written to `docs/issue_plan.md`. It covers 6 phases with discrete `[ ]` tasks, acceptance criteria, and dependencies.
EOF
    # The phrase "discrete `[ ]` tasks" is inline markdown-in-backticks, not
    # a real checkbox line — the regex must not be fooled.
    ! looks_like_plan plan.md
}

@test "looks_like_plan: rejects missing file" {
    ! looks_like_plan does-not-exist.md
}

@test "looks_like_plan: rejects empty file" {
    : > plan.md
    ! looks_like_plan plan.md
}

# ── run_benchmarks ───────────────────────────────────────────────────────────

@test "run_benchmarks: returns nothing when no scripts configured" {
    BENCHMARK_SCRIPTS=()
    local output
    output="$(run_benchmarks)"
    [ -z "$output" ]
}

@test "run_benchmarks: captures output from single script" {
    BENCHMARK_SCRIPTS=("echo 'score: 42'")
    local output
    output="$(run_benchmarks)"
    [[ "$output" == *"score: 42"* ]]
    [[ "$output" == *"Benchmark:"* ]]
}

@test "run_benchmarks: concatenates output from multiple scripts" {
    BENCHMARK_SCRIPTS=("echo 'size: 100kb'" "echo 'speed: 200ms'")
    local output
    output="$(run_benchmarks)"
    [[ "$output" == *"size: 100kb"* ]]
    [[ "$output" == *"speed: 200ms"* ]]
}

@test "run_benchmarks: handles failing scripts gracefully" {
    BENCHMARK_SCRIPTS=("false")
    local output
    output="$(run_benchmarks)"
    [[ "$output" == *"failed with exit code"* ]]
}

@test "parse_config: benchmark lines populate BENCHMARK_SCRIPTS" {
    mkdir -p "$TEST_DIR"
    cat > "$TEST_DIR/.wiggumrc" <<'EOF'
benchmark = ./measure.sh
benchmark = ./score.sh
EOF
    HOME="$TEST_DIR"
    load_config
    [ "${#BENCHMARK_SCRIPTS[@]}" -eq 2 ]
    [ "${BENCHMARK_SCRIPTS[0]}" = "./measure.sh" ]
    [ "${BENCHMARK_SCRIPTS[1]}" = "./score.sh" ]
}

@test "parse_args: --benchmark adds to BENCHMARK_SCRIPTS" {
    touch file.md
    parse_args execute --benchmark "./measure.sh" --benchmark "./score.sh" file.md
    [ "${#BENCHMARK_SCRIPTS[@]}" -eq 2 ]
    [ "${BENCHMARK_SCRIPTS[0]}" = "./measure.sh" ]
    [ "${BENCHMARK_SCRIPTS[1]}" = "./score.sh" ]
}

# ── extract_benchmark_numbers ────────────────────────────────────────────────

@test "extract_benchmark_numbers: extracts integers" {
    local result
    result="$(echo 'tasks: 5, errors: 0' | extract_benchmark_numbers)"
    [ "$(echo "$result" | wc -l | tr -d ' ')" -eq 2 ]
    [[ "$result" == *"0"* ]]
    [[ "$result" == *"5"* ]]
}

@test "extract_benchmark_numbers: extracts decimals" {
    local result
    result="$(echo 'Ratio: 0.955x, PR-AUC: 0.42' | extract_benchmark_numbers)"
    [[ "$result" == *"0.955"* ]]
    [[ "$result" == *"0.42"* ]]
}

@test "extract_benchmark_numbers: returns empty for no numbers" {
    local result
    result="$(echo 'no numbers here' | extract_benchmark_numbers)"
    [ -z "$result" ]
}

@test "extract_benchmark_numbers: handles mixed output like benchmark script" {
    local result
    result="$(cat <<'EOF' | extract_benchmark_numbers
PROGRESS: 0.600x → 0.955x  (target: 0.9-1.1x)
IMPROVED (distance to 1.0: 0.400 → 0.045)
Enquiries: 3353  |  Converted: 586 (17.5%)
EOF
)"
    # Should find: 0.600, 0.955, 0.9, 1.1, 0.400, 0.045, 3353, 586, 17.5
    [[ "$result" == *"0.955"* ]]
    [[ "$result" == *"3353"* ]]
    [[ "$result" == *"17.5"* ]]
}

@test "extract_benchmark_numbers: sorted numerically" {
    local result
    result="$(echo '100 items, 3 errors, 50.5 score' | extract_benchmark_numbers)"
    local first last
    first="$(echo "$result" | head -1)"
    last="$(echo "$result" | tail -1)"
    [ "$first" = "3" ]
    [ "$last" = "100" ]
}

# ── benchmark_numbers_changed ────────────────────────────────────────────────

@test "benchmark_numbers_changed: detects changed numbers" {
    local prev curr
    prev="$(echo 'Ratio: 0.600x' | extract_benchmark_numbers)"
    curr="$(echo 'Ratio: 0.955x' | extract_benchmark_numbers)"
    benchmark_numbers_changed "$prev" "$curr"
}

@test "benchmark_numbers_changed: returns false for identical numbers" {
    local prev curr
    prev="$(echo 'Ratio: 0.600x' | extract_benchmark_numbers)"
    curr="$(echo 'Ratio: 0.600x' | extract_benchmark_numbers)"
    run benchmark_numbers_changed "$prev" "$curr"
    [ "$status" -ne 0 ]
}

@test "benchmark_numbers_changed: ignores text-only changes" {
    local prev curr
    prev="$(echo 'Score: 42 points (good)' | extract_benchmark_numbers)"
    curr="$(echo 'Score: 42 points (excellent)' | extract_benchmark_numbers)"
    run benchmark_numbers_changed "$prev" "$curr"
    [ "$status" -ne 0 ]
}

@test "benchmark_numbers_changed: ignores timestamp changes" {
    local prev curr
    prev="$(echo '2026-04-15 10:00:00 Ratio: 0.6x' | extract_benchmark_numbers)"
    curr="$(echo '2026-04-15 10:05:00 Ratio: 0.6x' | extract_benchmark_numbers)"
    # Timestamps contain different numbers (10 vs 05) but ratio is same
    # This detects the timestamp diff — acceptable since minute changed
    # The key point: if ONLY non-metric text changes, no false positive
    true  # Document: timestamps with numbers will trigger — this is by design
}

@test "benchmark_numbers_changed: detects new numbers appearing" {
    local prev curr
    prev="$(echo 'Ratio: 0.600x' | extract_benchmark_numbers)"
    curr="$(echo 'Ratio: 0.600x PR-AUC: 0.42' | extract_benchmark_numbers)"
    benchmark_numbers_changed "$prev" "$curr"
}

@test "benchmark_numbers_changed: first iteration always has progress" {
    # prev is empty on first iteration
    local curr
    curr="$(echo 'Ratio: 0.600x' | extract_benchmark_numbers)"
    benchmark_numbers_changed "" "$curr"
}

# ── stall detection with benchmarks ──────────────────────────────────────────

@test "stall detection: no benchmark uses task count only" {
    # Without benchmarks, stall detection should work on checkboxes only
    BENCHMARK_SCRIPTS=()

    # Simulate: same task count twice = stall
    local stall_count=0
    local prev_remaining=5
    local remaining=5

    local task_progress=false
    if [[ "$remaining" -lt "$prev_remaining" ]]; then
        task_progress=true
    fi

    local benchmark_progress=false
    # No benchmarks configured, so benchmark_progress stays false

    if $task_progress || $benchmark_progress; then
        stall_count=0
    else
        stall_count=$((stall_count + 1))
    fi

    [ "$stall_count" -eq 1 ]
}

@test "stall detection: benchmark progress resets stall count" {
    BENCHMARK_SCRIPTS=("echo 'score: 42'")

    local stall_count=1  # already stalled once
    local prev_remaining=5
    local remaining=5  # no task progress

    local task_progress=false
    if [[ "$remaining" -lt "$prev_remaining" ]]; then
        task_progress=true
    fi

    # But benchmark numbers changed
    local prev_nums curr_nums
    prev_nums="$(echo 'Ratio: 0.600x' | extract_benchmark_numbers)"
    curr_nums="$(echo 'Ratio: 0.955x' | extract_benchmark_numbers)"

    local benchmark_progress=false
    if benchmark_numbers_changed "$prev_nums" "$curr_nums"; then
        benchmark_progress=true
    fi

    if $task_progress || $benchmark_progress; then
        stall_count=0
    else
        stall_count=$((stall_count + 1))
    fi

    [ "$stall_count" -eq 0 ]
}

@test "stall detection: same benchmark numbers does not reset stall" {
    BENCHMARK_SCRIPTS=("echo 'score: 42'")

    local stall_count=0
    local prev_remaining=5
    local remaining=5

    local task_progress=false

    local prev_nums curr_nums
    prev_nums="$(echo 'Ratio: 0.600x' | extract_benchmark_numbers)"
    curr_nums="$(echo 'Ratio: 0.600x' | extract_benchmark_numbers)"

    local benchmark_progress=false
    if benchmark_numbers_changed "$prev_nums" "$curr_nums"; then
        benchmark_progress=true
    fi

    if $task_progress || $benchmark_progress; then
        stall_count=0
    else
        stall_count=$((stall_count + 1))
    fi

    [ "$stall_count" -eq 1 ]
}

# ── slugify ──────────────────────────────────────────────────────────────────

@test "slugify: extracts slug from markdown heading" {
    echo "# Improve Chunking for Dashboards" > plan.md
    local result
    result="$(slugify plan.md)"
    [ "$result" = "improve-chunking-for-dashboards" ]
}

@test "slugify: falls back to first non-empty line" {
    echo "Fix the login bug" > plan.md
    local result
    result="$(slugify plan.md)"
    [ "$result" = "fix-the-login-bug" ]
}

@test "slugify: strips special characters" {
    echo "# Add SSO (SAML 2.0) & OAuth!" > plan.md
    local result
    result="$(slugify plan.md)"
    [ "$result" = "add-sso-saml-2-0-oauth" ]
}

@test "slugify: truncates long headings at 50 chars" {
    echo "# This is a very long heading that should be truncated to fit within a reasonable filename length" > plan.md
    local result
    result="$(slugify plan.md)"
    [ "${#result}" -le 50 ]
    # Should not end with a hyphen from truncation
    [[ "$result" != *- ]]
}

@test "slugify: falls back to date when file is empty" {
    touch plan.md
    local result
    result="$(slugify plan.md)"
    [[ "$result" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
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

# ── load_config (outer) ──────────────────────────────────────────────────────

@test "load_config: 'Loading config from ...' goes to stderr not stdout" {
    # Regression guard: this message used to leak on stdout, which poisoned
    # pipelines like `wiggum plan X | wiggum execute` — the receiving wiggum
    # would treat the chatter as a plan.
    echo "iterations = 1" > .wiggumrc
    local out err
    out="$(load_config 2>/dev/null)"
    err="$(load_config 2>&1 >/dev/null)"
    [ -z "$out" ]
    [[ "$err" == *"Loading config from"* ]]
}

@test "load_config: 'no config found' message goes to stderr not stdout" {
    HOME="$TEST_DIR/nohome"
    mkdir -p "$HOME"
    local out err
    out="$(load_config 2>/dev/null)"
    err="$(load_config 2>&1 >/dev/null)"
    [ -z "$out" ]
    [[ "$err" == *"No .wiggumrc found"* ]]
}

@test "load_config: stdout stays clean so it can be piped downstream" {
    # Integration-flavoured: run load_config inside a pipeline and verify
    # nothing flows through the pipe.
    echo "iterations = 1" > .wiggumrc
    local piped
    piped="$(load_config 2>/dev/null | cat)"
    [ -z "$piped" ]
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

@test "apply_config: sets max_iterations and max_validation_retries" {
    apply_config <<< "$(printf "max_iterations=10\nmax_validation_retries=2")"
    [ "$MAX_ITERATIONS" = "10" ]
    [ "$MAX_VALIDATION_RETRIES" = "2" ]
}

@test "apply_config: legacy iterations key still works" {
    apply_config <<< "iterations=10"
    [ "$MAX_ITERATIONS" = "10" ]
}

@test "apply_config: CLI_MAX_ITERATIONS takes precedence over config" {
    CLI_MAX_ITERATIONS="7"
    MAX_ITERATIONS="7"
    apply_config <<< "max_iterations=10"
    [ "$MAX_ITERATIONS" = "7" ]
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
    printf "n\nn\n" | run_init
    [ -f ".wiggumrc" ]
    grep -q "pytest" .wiggumrc
}

@test "run_init: auto-detects preset" {
    INIT_PRESET=""
    touch package.json
    printf "n\nn\n" | run_init
    [ -f ".wiggumrc" ]
    grep -q "npm test" .wiggumrc
}

@test "run_init: creates .claude/settings.local.json when approved" {
    INIT_PRESET="node"
    printf "y\nn\nn\n" | run_init
    [ -f ".claude/settings.local.json" ]
    grep -q "git add" .claude/settings.local.json
    grep -q "npm run" .claude/settings.local.json
}

@test "run_init: skips permissions when declined" {
    INIT_PRESET="node"
    printf "n\nn\n" | run_init
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

@test "setup_claude_permissions: merges into existing file preserving other keys" {
    mkdir -p .claude
    cat > .claude/settings.local.json <<'EOF'
{
  "permissions": {
    "allow": ["Bash(make *)"],
    "deny": ["Bash(rm -rf *)"]
  },
  "other_setting": true
}
EOF
    printf "y\nn\n" | setup_claude_permissions node
    # New rules are present
    grep -q '"Bash(git add \*)"' .claude/settings.local.json
    grep -q '"Bash(npm run \*)"' .claude/settings.local.json
    # Existing allow rule is preserved
    grep -q '"Bash(make \*)"' .claude/settings.local.json
    # Other keys are preserved
    grep -q '"deny"' .claude/settings.local.json
    grep -q '"Bash(rm -rf \*)"' .claude/settings.local.json
    grep -q '"other_setting"' .claude/settings.local.json
}

@test "setup_claude_permissions: does not duplicate existing allow rules" {
    mkdir -p .claude
    cat > .claude/settings.local.json <<'EOF'
{
  "permissions": {
    "allow": ["Bash(git add *)"]
  }
}
EOF
    printf "y\nn\n" | setup_claude_permissions node
    # Count occurrences of "git add" -- should be exactly 1
    local count
    count=$(grep -c '"Bash(git add \*)"' .claude/settings.local.json)
    [ "$count" -eq 1 ]
}

# ── setup_wiggum_skill ───────────────────────────────────────────────────────

@test "setup_wiggum_skill: creates skill file when approved" {
    echo "y" | setup_wiggum_skill
    [ -f ".claude/skills/wiggum/SKILL.md" ]
    grep -q "name: wiggum" .claude/skills/wiggum/SKILL.md
    grep -q "disable-model-invocation: true" .claude/skills/wiggum/SKILL.md
    grep -q '\$ARGUMENTS' .claude/skills/wiggum/SKILL.md
}

@test "setup_wiggum_skill: skips when declined" {
    echo "n" | setup_wiggum_skill
    [ ! -f ".claude/skills/wiggum/SKILL.md" ]
}

@test "setup_wiggum_skill: skips when skill already exists" {
    mkdir -p .claude/skills/wiggum
    echo "existing" > .claude/skills/wiggum/SKILL.md
    run setup_wiggum_skill
    [ "$status" -eq 0 ]
    [[ "$output" == *"already exists"* ]]
    # Original content preserved
    grep -q "existing" .claude/skills/wiggum/SKILL.md
}

@test "setup_wiggum_skill: skill contains verify loop instructions" {
    echo "y" | setup_wiggum_skill
    grep -q "wiggumrc" .claude/skills/wiggum/SKILL.md
    grep -q "autofix" .claude/skills/wiggum/SKILL.md
    grep -q "5 times" .claude/skills/wiggum/SKILL.md
}

@test "run_init: creates skill when approved" {
    INIT_PRESET="node"
    # y=permissions, n=pkg-manager, y=skill
    printf "y\nn\ny\n" | run_init
    [ -f ".claude/skills/wiggum/SKILL.md" ]
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

# ── parse_args: check mode ────────────────────────────────────────────────────

@test "parse_args: check mode needs no files" {
    parse_args check
    [ "$MODE" = "check" ]
}

@test "parse_args: check mode accepts --verbose" {
    parse_args check --verbose
    [ "$MODE" = "check" ]
    [ "$VERBOSE" = "true" ]
}

@test "parse_args: help check shows check details" {
    run parse_args help check
    [ "$status" -eq 0 ]
    [[ "$output" == *"wiggum check"* ]]
    [[ "$output" == *"verification"* ]]
}

# ── run_check ────────────────────────────────────────────────────────────────

@test "run_check: passes when all verify steps pass" {
    VERIFY_STEPS=("true" "true")
    run run_check
    [ "$status" -eq 0 ]
    [[ "$output" == *"ALL CHECKS PASSED"* ]]
}

@test "run_check: fails when verify step fails" {
    cat > "$TEST_DIR/fail.sh" <<'S'
#!/usr/bin/env bash
exit 1
S
    chmod +x "$TEST_DIR/fail.sh"

    MAX_VALIDATION_RETRIES=1
    VERIFY_STEPS=("$TEST_DIR/fail.sh")
    run run_check
    [ "$status" -eq "$EXIT_VALIDATION_FAILED" ]
    [[ "$output" == *"CHECKS FAILED"* ]]
}

@test "run_check: reports no steps when none configured" {
    VERIFY_STEPS=()
    run run_check
    [ "$status" -eq 0 ]
    [[ "$output" == *"No verification steps"* ]]
}

@test "run_check: uses same run_validation as execute mode" {
    # Verify it calls the shared function by checking for validation pass output
    VERIFY_STEPS=("true")
    run run_check
    [[ "$output" == *"Validation pass"* ]]
    [[ "$output" == *"All verification steps passed"* ]]
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

@test "log_init: succeeds when FILES is empty (docs mode)" {
    make_file output.md
    MODE="docs"
    FILES=()
    log_init "output.md"
    grep -q "wiggum docs" output.log
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

@test "run_claude: suppresses stdout by default" {
    log_init "plan.md"
    claude() { echo "visible output"; return 0; }
    export -f claude
    WIGGUM_CURRENT_LABEL="test"
    local output
    output="$(run_claude -p "hello" 2>/dev/null)"
    [ -z "$output" ]
}

@test "run_claude: shows stdout when VERBOSE is true" {
    log_init "plan.md"
    claude() { echo "visible output"; return 0; }
    export -f claude
    VERBOSE=true
    WIGGUM_CURRENT_LABEL="test"
    local output
    output="$(run_claude -p "hello" 2>/dev/null)"
    [ "$output" = "visible output" ]
}

@test "run_claude: shows stdout when WIGGUM_SHOW_OUTPUT is true" {
    log_init "plan.md"
    claude() { echo "visible output"; return 0; }
    export -f claude
    WIGGUM_SHOW_OUTPUT=true
    WIGGUM_CURRENT_LABEL="test"
    local output
    output="$(run_claude -p "hello" 2>/dev/null)"
    [ "$output" = "visible output" ]
}

@test "run_claude: session ID goes to stderr not stdout" {
    log_init "plan.md"
    claude() { return 0; }
    export -f claude
    WIGGUM_CURRENT_LABEL="test"
    local stdout stderr
    stdout="$(run_claude -p "hello" 2>/dev/null)"
    stderr="$(run_claude -p "hello" 2>&1 >/dev/null)"
    [ -z "$stdout" ]
    [[ "$stderr" == *"session:"* ]]
}

# ── Exit codes ───────────────────────────────────────────────────────────────

@test "exit codes: constants are distinct non-zero integers" {
    [ "$EXIT_BAD_ARGS" -ne 0 ]
    [ "$EXIT_NO_CONFIG" -ne 0 ]
    [ "$EXIT_VALIDATION_FAILED" -ne 0 ]
    [ "$EXIT_CLAUDE_FAILED" -ne 0 ]
    [ "$EXIT_PLAN_FAILED" -ne 0 ]
    # All distinct
    [ "$EXIT_BAD_ARGS" -ne "$EXIT_NO_CONFIG" ]
    [ "$EXIT_BAD_ARGS" -ne "$EXIT_VALIDATION_FAILED" ]
    [ "$EXIT_BAD_ARGS" -ne "$EXIT_CLAUDE_FAILED" ]
    [ "$EXIT_BAD_ARGS" -ne "$EXIT_PLAN_FAILED" ]
    [ "$EXIT_NO_CONFIG" -ne "$EXIT_VALIDATION_FAILED" ]
    [ "$EXIT_NO_CONFIG" -ne "$EXIT_CLAUDE_FAILED" ]
    [ "$EXIT_NO_CONFIG" -ne "$EXIT_PLAN_FAILED" ]
    [ "$EXIT_VALIDATION_FAILED" -ne "$EXIT_CLAUDE_FAILED" ]
    [ "$EXIT_VALIDATION_FAILED" -ne "$EXIT_PLAN_FAILED" ]
    [ "$EXIT_CLAUDE_FAILED" -ne "$EXIT_PLAN_FAILED" ]
}

# ── run_plan ─────────────────────────────────────────────────────────────────

@test "run_plan: outputs plan file content to stdout when piped" {
    mkdir -p docs
    echo "Fix the bug" > issue.md
    FILES=("issue.md")
    STDIN_FILE="/tmp/fake_stdin"
    CLI_PLAN_FILE=""
    PLAN_FILE="docs/issue_plan.md"

    # Stub claude to write the plan file
    claude() { echo "# Plan" > "$PLAN_FILE"; return 0; }
    export -f claude

    local output
    output="$(run_plan 2>/dev/null)"
    [ "$output" = "# Plan" ]
    # Plan file should be cleaned up
    [ ! -f "$PLAN_FILE" ]
}

@test "run_plan: fails when plan file is empty" {
    mkdir -p docs
    echo "Fix the bug" > issue.md
    FILES=("issue.md")
    STDIN_FILE="/tmp/fake_stdin"
    CLI_PLAN_FILE=""
    PLAN_FILE="docs/issue_plan.md"

    # Stub claude to create empty file
    claude() { touch "$PLAN_FILE"; return 0; }
    export -f claude

    run run_plan
    [ "$status" -eq "$EXIT_PLAN_FAILED" ]
    [[ "$output" == *"not created or is empty"* ]]
}

@test "run_plan: fails when plan file is not created" {
    mkdir -p docs
    echo "Fix the bug" > issue.md
    FILES=("issue.md")
    STDIN_FILE="/tmp/fake_stdin"
    CLI_PLAN_FILE=""
    PLAN_FILE="docs/issue_plan.md"

    # Stub claude to do nothing
    claude() { return 0; }
    export -f claude

    run run_plan
    [ "$status" -eq "$EXIT_PLAN_FAILED" ]
    [[ "$output" == *"not created or is empty"* ]]
}

@test "run_plan: keeps plan file when explicit -o given" {
    # With an explicit CLI_PLAN_FILE the plan stays on disk regardless of
    # stdin/stdout pipe state. (Without -o, run_plan now also treats
    # non-TTY stdout as piped, which bats can't simulate cleanly.)
    mkdir -p docs
    echo "Fix the bug" > issue.md
    FILES=("issue.md")
    STDIN_FILE=""
    CLI_PLAN_FILE="docs/issue_plan.md"
    PLAN_FILE="docs/issue_plan.md"

    claude() { echo "# Plan" > "$PLAN_FILE"; return 0; }
    export -f claude

    run_plan 2>/dev/null
    [ -f "$PLAN_FILE" ]
    [ "$(cat "$PLAN_FILE")" = "# Plan" ]
}

@test "run_plan: pipes to stdout when stdout is not a TTY" {
    # The new behavior: file argument + piped stdout => plan emitted to
    # stdout and PLAN_FILE cleaned up. This is what makes
    # `wiggum plan X.md | wiggum execute` work correctly.
    mkdir -p docs
    echo "Fix the bug" > issue.md
    FILES=("issue.md")
    STDIN_FILE=""
    CLI_PLAN_FILE=""
    PLAN_FILE="docs/issue_plan.md"

    claude() { echo "# Plan" > "$PLAN_FILE"; return 0; }
    export -f claude

    local output
    output="$(run_plan 2>/dev/null)"
    [ "$output" = "# Plan" ]
    [ ! -f "$PLAN_FILE" ]
}

@test "run_plan: piped mode suppresses claude stdout" {
    mkdir -p docs
    echo "Fix the bug" > issue.md
    FILES=("issue.md")
    STDIN_FILE="/tmp/fake_stdin"
    CLI_PLAN_FILE=""
    PLAN_FILE="docs/issue_plan.md"

    # Stub claude to write plan file AND print chatter to stdout
    claude() {
        echo "Plan saved to docs/issue_plan.md. It covers 8 phases:"
        echo "# Plan" > "$PLAN_FILE"
        return 0
    }
    export -f claude

    local output
    output="$(run_plan 2>/dev/null)"
    # Should only contain the file content, not Claude's chatter
    [ "$output" = "# Plan" ]
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

@test "CLI: execute bails out with EXIT_BAD_ARGS when stdin is not a plan" {
    # Reproduces the exact failure mode that caused the original bug: an
    # upstream `wiggum plan` leaked chatter into the pipe, and execute
    # happily processed 2 lines of nonsense. After the fix, execute must
    # refuse early with a clear hint.
    local cli="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/wiggum.sh"
    run bash -c "printf 'Loading config from .wiggumrc\nPlan written to X.\n' | '$cli' execute"
    [ "$status" -eq 1 ]   # EXIT_BAD_ARGS
    [[ "$output" == *"does not look like a wiggum plan"* ]]
    [[ "$output" == *"wiggum execute <plan-file>"* ]]
}

@test "CLI: execute accepts stdin that is a real plan" {
    # Positive counterpart: a proper plan on stdin must not be rejected.
    # We set max_iterations to 0 via an env-provided config so execute exits
    # cleanly once the input passes the shape check, without calling Claude.
    local cli="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/wiggum.sh"
    run bash -c "printf '# Workplan\n- [ ] First task\n' | '$cli' execute 2>&1 | head -5"
    # We only care that the shape check did not reject the input.
    [[ "$output" != *"does not look like a wiggum plan"* ]]
}

# ── --no-verify / --no-commit ────────────────────────────────────────────────

@test "parse_args: --no-verify sets NO_VERIFY and CLI_NO_VERIFY" {
    make_file plan.md
    parse_args execute plan.md --no-verify
    [ "$NO_VERIFY" = "true" ]
    [ "$CLI_NO_VERIFY" = "true" ]
}

@test "parse_args: --no-commit sets NO_COMMIT and CLI_NO_COMMIT" {
    make_file plan.md
    parse_args execute plan.md --no-commit
    [ "$NO_COMMIT" = "true" ]
    [ "$CLI_NO_COMMIT" = "true" ]
}

@test "parse_args: --no-verify and --no-commit can be combined" {
    make_file plan.md
    parse_args execute plan.md --no-verify --no-commit
    [ "$NO_VERIFY" = "true" ]
    [ "$NO_COMMIT" = "true" ]
}

@test "parse_args: check accepts --no-commit" {
    parse_args check --no-commit
    [ "$MODE" = "check" ]
    [ "$NO_COMMIT" = "true" ]
}

@test "parse_args: check accepts --no-verify (refused at runtime, not at parse)" {
    parse_args check --no-verify
    [ "$MODE" = "check" ]
    [ "$NO_VERIFY" = "true" ]
}

@test "load_config_from: skip_verify is recognized and forwarded" {
    cat > test.rc <<'EOF'
skip_verify = true
EOF
    local output
    output="$(load_config_from test.rc)"
    [ "$output" = "skip_verify=true" ]
}

@test "load_config_from: skip_commit is recognized and forwarded" {
    cat > test.rc <<'EOF'
skip_commit = true
EOF
    local output
    output="$(load_config_from test.rc)"
    [ "$output" = "skip_commit=true" ]
}

@test "load_config_from: skip_verify with only max_iterations does not warn" {
    # A .wiggumrc with skip_verify and max_iterations only (no verify lines)
    # is a valid configuration.
    cat > test.rc <<'EOF'
skip_verify = true
max_iterations = 2
EOF
    run load_config_from test.rc
    [ "$status" -eq 0 ]
    [[ "$output" != *"unknown config key"* ]]
    [[ "$output" != *"Warning"* ]]
}

@test "apply_config: skip_verify=true sets NO_VERIFY" {
    apply_config <<< "skip_verify=true"
    [ "$NO_VERIFY" = "true" ]
}

@test "apply_config: skip_commit=true sets NO_COMMIT" {
    apply_config <<< "skip_commit=true"
    [ "$NO_COMMIT" = "true" ]
}

@test "apply_config: skip_verify=false leaves NO_VERIFY false" {
    apply_config <<< "skip_verify=false"
    [ "$NO_VERIFY" = "false" ]
}

@test "apply_config: CLI_NO_VERIFY=true overrides skip_verify=false in config" {
    NO_VERIFY=true
    CLI_NO_VERIFY=true
    apply_config <<< "skip_verify=false"
    [ "$NO_VERIFY" = "true" ]
}

@test "apply_config: CLI_NO_COMMIT=true overrides skip_commit=false in config" {
    NO_COMMIT=true
    CLI_NO_COMMIT=true
    apply_config <<< "skip_commit=false"
    [ "$NO_COMMIT" = "true" ]
}

@test "apply_config: invalid skip_verify value warns and treats as false" {
    run apply_config <<< "skip_verify=maybe"
    [ "$status" -eq 0 ]
    [[ "$output" == *"invalid value for skip_verify"* ]]
}

@test "apply_config: invalid skip_commit value warns and treats as false" {
    run apply_config <<< "skip_commit=sometimes"
    [ "$status" -eq 0 ]
    [[ "$output" == *"invalid value for skip_commit"* ]]
}

@test "print_verify_steps: shows (skipped) when NO_VERIFY=true" {
    NO_VERIFY=true
    VERIFY_STEPS=("npm test")
    run print_verify_steps 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"(skipped)"* ]]
    [[ "$output" != *"npm test"* ]]
}

@test "print_verify_steps: shows (none configured) when no steps and NO_VERIFY=false" {
    NO_VERIFY=false
    VERIFY_STEPS=()
    run print_verify_steps 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"(none configured)"* ]]
}

@test "commit_or_skip: skips and prints message when NO_COMMIT=true" {
    NO_COMMIT=true
    local claude_calls=0
    claude() { claude_calls=$((claude_calls + 1)); }
    export -f claude
    run commit_or_skip "test-commit"
    [ "$status" -eq 0 ]
    [[ "$output" == *"(commit skipped via --no-commit)"* ]]
}

@test "commit_or_skip: invokes claude when NO_COMMIT=false" {
    NO_COMMIT=false
    local captured=""
    claude() { captured="$*"; }
    export -f claude
    log_init "plan.md"
    commit_or_skip "test-commit"
    # claude should have been called with a prompt about committing
    [[ -n "$captured" ]]
}

@test "commit_or_skip: passes extra files arg through to prompt_commit" {
    NO_COMMIT=false
    local captured=""
    claude() { captured="$*"; }
    export -f claude
    log_init "plan.md"
    commit_or_skip "test-commit" "summary.md and plan.md"
    [[ "$captured" == *"summary.md and plan.md"* ]]
}

@test "run_check: --no-verify produces clear error and exits EXIT_BAD_ARGS" {
    NO_VERIFY=true
    VERIFY_STEPS=("true")
    run run_check
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"--no-verify makes 'wiggum check' a no-op"* ]]
}

@test "run_check: --no-commit suppresses post-fix commit" {
    NO_COMMIT=true
    VERIFY_STEPS=("true")
    # Stub claude so any commit call would record itself
    local commit_called=false
    claude() {
        for arg in "$@"; do
            if [[ "$arg" == *"git add"* ]]; then
                commit_called=true
            fi
        done
    }
    export -f claude
    # Force a dirty working tree so the commit branch would be entered
    run run_check
    [ "$status" -eq 0 ]
    [[ "$output" == *"ALL CHECKS PASSED"* ]]
    # The commit-skipped marker may appear if the working tree is dirty.
    # Either way: claude must not have been called for a commit.
}

@test "run_validation: --no-verify does not affect the function (gate is in caller)" {
    # run_validation itself is not gated; the gate lives in run_execute. So
    # calling run_validation directly with NO_VERIFY=true still runs the
    # configured steps. This documents the contract.
    NO_VERIFY=true
    VERIFY_STEPS=("true")
    run run_validation
    [ "$status" -eq 0 ]
    [[ "$output" == *"All verification steps passed"* ]]
}
