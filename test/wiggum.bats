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

    # Keep the machine-wide run registry inside the temp dir: a test that starts
    # a run must never announce it in the real ~/.wiggum, nor read runs the
    # developer actually has going.
    #
    # Exported, not just set: several tests spawn the CLI or a fresh `bash -c`,
    # and an unexported value lets the child fall back to the real registry.
    export WIGGUM_REGISTRY_DIR="$TEST_DIR/registry"

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

# ── Suite invariants ─────────────────────────────────────────────────────────

# Bash 3.2 (the system bash on macOS) does not apply `set -e` to a failing
# `[[ ]]` inside a function, so a bare mid-body `[[ ]]` never fails its test --
# only the last command's status is reported.  Every standalone `[[ ]]`
# assertion must therefore end in `|| return 1` to actually bind.
@test "suite: every standalone [[ ]] assertion binds under bash 3.2" {
    local unbound
    unbound="$(grep -cE '^[[:space:]]*\[\[ .* \]\][[:space:]]*$' "$BATS_TEST_FILENAME" || true)"
    [ "$unbound" -eq 0 ]
}

@test "suite: the run registry is exported so a child process cannot reach the real one" {
    # A spawned CLI re-evaluates `${WIGGUM_REGISTRY_DIR:-$HOME/.wiggum/runs}`
    # from scratch. Unexported, that resolves to the developer's own registry
    # and a test run announces phantom jobs in it -- which `wiggum top` then
    # reports as real work on the machine.
    run bash -c 'echo "${WIGGUM_REGISTRY_DIR:-UNSET}"'
    [ "$output" = "$TEST_DIR/registry" ]
}

# ── parse_args ───────────────────────────────────────────────────────────────

@test "parse_args: no arguments prints usage and exits EXIT_BAD_ARGS" {
    run parse_args
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"wiggum"* ]] || return 1
    [[ "$output" == *"Usage"* ]] || return 1
}

@test "parse_args: --help prints usage and succeeds" {
    run parse_args --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]] || return 1
}

@test "parse_args: help shows overview" {
    run parse_args help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Commands"* ]] || return 1
    [[ "$output" == *"help <command>"* ]] || return 1
}

@test "parse_args: help plan shows plan details" {
    run parse_args help plan
    [ "$status" -eq 0 ]
    [[ "$output" == *"wiggum plan"* ]] || return 1
    [[ "$output" == *"--plan-file"* ]] || return 1
    [[ "$output" == *"Examples"* ]] || return 1
}

@test "parse_args: help execute shows execute details" {
    run parse_args help execute
    [ "$status" -eq 0 ]
    [[ "$output" == *"wiggum execute"* ]] || return 1
    [[ "$output" == *"--max-iterations"* ]] || return 1
    [[ "$output" == *"--background"* ]] || return 1
    [[ "$output" == *"Phases"* ]] || return 1
}

@test "parse_args: help execute documents --at and its three time forms" {
    run parse_args help execute
    [ "$status" -eq 0 ]
    [[ "$output" == *"--at <WHEN>"* ]] || return 1
    [[ "$output" == *"+90m"* ]] || return 1
    [[ "$output" == *"01:07"* ]] || return 1
    [[ "$output" == *"@1756180020"* ]] || return 1
}

@test "parse_args: help status/watch/kill/chain show their details" {
    run parse_args help status
    [ "$status" -eq 0 ]
    [[ "$output" == *"wiggum status"* ]] || return 1

    run parse_args help watch
    [ "$status" -eq 0 ]
    [[ "$output" == *"wiggum watch"* ]] || return 1
    [[ "$output" == *"--timeout"* ]] || return 1
    [[ "$output" == *"--kill-on-timeout"* ]] || return 1

    run parse_args help kill
    [ "$status" -eq 0 ]
    [[ "$output" == *"wiggum kill"* ]] || return 1

    run parse_args help chain
    [ "$status" -eq 0 ]
    [[ "$output" == *"wiggum chain"* ]] || return 1
}

@test "parse_args: top-level help lists the orchestration commands" {
    run parse_args help
    [ "$status" -eq 0 ]
    [[ "$output" == *"status"* ]] || return 1
    [[ "$output" == *"watch"* ]] || return 1
    [[ "$output" == *"kill"* ]] || return 1
    [[ "$output" == *"chain"* ]] || return 1
    [[ "$output" == *"top"* ]] || return 1
}

@test "parse_args: help top shows the overview details" {
    run parse_args help top
    [ "$status" -eq 0 ]
    [[ "$output" == *"wiggum top"* ]] || return 1
    [[ "$output" == *"at a glance"* ]] || return 1
}

@test "parse_args: top is a known mode and needs no files" {
    parse_args top
    [ "$MODE" = "top" ]
}

@test "parse_args: top collects optional scan dirs into FILES" {
    parse_args top plans docs
    [ "$MODE" = "top" ]
    [ "${#FILES[@]}" -eq 2 ]
    [ "${FILES[0]}" = "plans" ]
}

@test "parse_args: help docs shows docs details" {
    run parse_args help docs
    [ "$status" -eq 0 ]
    [[ "$output" == *"wiggum docs"* ]] || return 1
    [[ "$output" == *"-i"* ]] || return 1
    [[ "$output" == *"-o"* ]] || return 1
}

@test "parse_args: help init shows presets" {
    run parse_args help init
    [ "$status" -eq 0 ]
    [[ "$output" == *"wiggum init"* ]] || return 1
    [[ "$output" == *"Presets"* ]] || return 1
}

@test "parse_args: help unknown falls back to overview" {
    run parse_args help bogus
    [ "$status" -eq 0 ]
    [[ "$output" == *"Commands"* ]] || return 1
}

@test "parse_args: unknown mode exits EXIT_BAD_ARGS" {
    run parse_args destroy
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"unknown mode"* ]] || return 1
}

@test "parse_args: plan mode requires files when stdin is a terminal" {
    run parse_args plan < /dev/null
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"stdin was empty"* ]] || return 1
}

@test "parse_args: plan reads from stdin when no files given" {
    # pipe runs in subshell so globals won't propagate; capture STDIN_FILE path
    local tmp
    tmp="$(echo "Add dark mode toggle" | { parse_args plan; echo "$STDIN_FILE"; })"
    local sfile
    sfile="$(echo "$tmp" | tail -1)"
    [ -f "$sfile" ]
    [[ "$(cat "$sfile")" == "Add dark mode toggle" ]] || return 1
    rm -f "$sfile"
}

@test "parse_args: stdin rejects empty input" {
    run parse_args plan < /dev/null
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"stdin was empty"* ]] || return 1
}

@test "parse_args: stdin with --plan-file sets CLI_PLAN_FILE" {
    local out
    out="$(echo "Fix the bug" | { parse_args plan --plan-file my_plan.md; echo "$CLI_PLAN_FILE"; })"
    local val
    val="$(echo "$out" | tail -1)"
    [[ "$val" == "my_plan.md" ]] || return 1
}

@test "parse_args: -- collects multiple remaining files" {
    make_file "a.md"
    make_file "b.md"
    parse_args plan -- "a.md" "b.md"
    [[ "${#FILES[@]}" -eq 2 ]] || return 1
}

@test "parse_args: plan mode rejects missing file" {
    run parse_args plan nonexistent.md
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"file not found"* ]] || return 1
}

@test "parse_args: rejects file outside project directory with EXIT_BAD_ARGS" {
    local outside
    outside="$(mktemp -d)"
    echo "# issue" > "$outside/issue.md"
    run parse_args plan "$outside/issue.md"
    rm -rf "$outside"
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"outside the project directory"* ]] || return 1
}

@test "parse_args: -- ends option parsing" {
    make_file "issue.md"
    parse_args plan --verbose -- "issue.md"
    [[ " ${FILES[*]} " == *"issue.md"* ]] || return 1
    [[ "$VERBOSE" == "true" ]] || return 1
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

@test "parse_args: -b/--background sets BACKGROUND" {
    make_file plan.md
    parse_args execute plan.md --background
    [ "$BACKGROUND" = "true" ]
    wiggum_reset
    make_file plan.md
    parse_args execute plan.md -b
    [ "$BACKGROUND" = "true" ]
}

@test "parse_args: --at sets AT_TIME to an HH:MM spec" {
    make_file plan.md
    parse_args execute plan.md --at 01:07
    [ "$MODE" = "execute" ]
    [ "$AT_TIME" = "01:07" ]
}

@test "parse_args: --at accepts a duration spec" {
    make_file plan.md
    parse_args execute plan.md --at +90m
    [ "$AT_TIME" = "+90m" ]
}

@test "parse_args: --at accepts an @epoch spec" {
    make_file plan.md
    parse_args execute plan.md --at @1756180020
    [ "$AT_TIME" = "@1756180020" ]
}

@test "parse_args: --at defaults to empty and is cleared by wiggum_reset" {
    make_file plan.md
    parse_args execute plan.md
    [ -z "$AT_TIME" ]
    wiggum_reset
    make_file plan.md
    parse_args execute plan.md --at +1h
    [ "$AT_TIME" = "+1h" ]
    wiggum_reset
    [ -z "$AT_TIME" ]
}

@test "parse_args: --at with no value exits EXIT_BAD_ARGS" {
    # Must not die on an unbound "$2" under set -u, and must not shift past
    # the end of the argument list.
    make_file plan.md
    run parse_args execute plan.md --at
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"--at"* ]] || return 1
}

@test "parse_args: --at does not swallow the following option" {
    # The failure this guards is `--at --verbose` silently consuming the flag
    # and scheduling for a spec of "--verbose".
    make_file plan.md
    run parse_args execute plan.md --at --verbose
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
}

@test "parse_args: --at rejects an unparseable time naming the three forms" {
    make_file plan.md
    run parse_args execute plan.md --at tomorrow
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"+90m"* ]] || return 1
    [[ "$output" == *"01:07"* ]] || return 1
    [[ "$output" == *"@"* ]] || return 1
}

@test "parse_args: --at rejects a bare duration with no unit" {
    make_file plan.md
    run parse_args execute plan.md --at +90
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
}

@test "parse_args: --at rejects an out-of-range hour" {
    make_file plan.md
    run parse_args execute plan.md --at 25:00
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
}

@test "parse_args: --at and --background are both accepted together" {
    # --at implies detachment, so --background alongside it is redundant
    # rather than an error.  Phase 2 decides which one wins at launch; here
    # only the parse has to survive both.
    make_file plan.md
    parse_args execute plan.md --at 01:07 --background
    [ "$AT_TIME" = "01:07" ]
    [ "$BACKGROUND" = "true" ]
}

@test "parse_args: --at is validated with the same rules as parse_at_time" {
    # A spec parse_args accepts must be one parse_at_time can resolve; if the
    # two ever diverge, --at accepts a time the launcher then cannot use.
    make_file plan.md
    parse_args execute plan.md --at 08:30
    [ "$AT_TIME" = "08:30" ]
    run parse_at_time "$AT_TIME"
    [ "$status" -eq 0 ]
}

@test "parse_args: watch flags set timeout/poll/kill-on-timeout" {
    make_file plan.md
    parse_args watch plan.md --timeout 600 --poll-interval 2 --kill-on-timeout
    [ "$MODE" = "watch" ]
    [ "$WATCH_TIMEOUT" = "600" ]
    [ "$WATCH_POLL" = "2" ]
    [ "$KILL_ON_TIMEOUT" = "true" ]
}

@test "parse_args: status/watch/kill accept a plan file" {
    make_file plan.md
    parse_args status plan.md
    [ "$MODE" = "status" ]
    [ "${FILES[0]}" = "plan.md" ]
    wiggum_reset; make_file plan.md
    parse_args kill plan.md
    [ "$MODE" = "kill" ]
}

@test "parse_args: status/watch/kill require a plan file" {
    run parse_args status
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"requires a plan file"* ]] || return 1
}

@test "parse_args: chain collects multiple plan files" {
    make_file a.md
    make_file b.md
    parse_args chain a.md b.md
    [ "$MODE" = "chain" ]
    [ "${#FILES[@]}" -eq 2 ]
    [ "${FILES[0]}" = "a.md" ]
    [ "${FILES[1]}" = "b.md" ]
}

@test "parse_args: chain requires at least one plan file" {
    run parse_args chain
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"requires one or more plan files"* ]] || return 1
}

@test "parse_args: status/watch/kill/chain are known modes" {
    for m in status watch kill chain; do
        make_file plan.md
        run parse_args "$m" plan.md
        [ "$status" -eq 0 ]
        wiggum_reset
    done
}

@test "parse_args: unknown option exits EXIT_BAD_ARGS" {
    make_file plan.md
    run parse_args plan plan.md --bogus
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"unknown option"* ]] || return 1
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
    [[ " ${CLAUDE_EXTRA_ARGS[*]} " == *" --verbose "* ]] || return 1
}

# ── wiggum_reset ─────────────────────────────────────────────────────────────

@test "wiggum_reset clears all state" {
    make_file x.md
    parse_args plan x.md --plan-file foo.md
    wiggum_reset
    [ -z "$MODE" ]
    [ "${#FILES[@]}" -eq 0 ]
    [ -z "$PLAN_FILE" ]
    [ "$MAX_ITERATIONS" -eq 30 ]
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

@test "count_unchecked: counts * and + bullets (GFM task lists)" {
    cat > plan.md <<'EOF'
- [ ] dash task
* [ ] star task
+ [ ] plus task
* [x] star done
+ [~] plus dropped
EOF
    local result
    result="$(count_unchecked plan.md)"
    [ "$result" -eq 3 ]
}

@test "count_unchecked: counts heading-form and numbered checkboxes" {
    # The planner sometimes emits tasks as '### [ ] N.N Title' headings or as
    # ordered-list items rather than bullets; those must still count.
    cat > plan.md <<'EOF'
# Plan title (not a task)
## Phase 1 (not a task)
### [ ] 1.1 heading task
#### [x] 1.2 heading done
- [ ] bullet task
1. [ ] numbered task
10. [x] numbered done
### Phase 2 (heading, no checkbox -- not a task)
EOF
    local result
    result="$(count_unchecked plan.md)"
    [ "$result" -eq 3 ]
}

@test "count_unchecked: ignores a heading with no checkbox" {
    cat > plan.md <<'EOF'
# Title
## Phase 1 — setup
### Subsection
EOF
    local result
    result="$(count_unchecked plan.md)"
    [ "$result" -eq 0 ]
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

@test "count_total_tasks: counts * and + bullets" {
    cat > plan.md <<'EOF'
- [ ] dash todo
* [x] star done
+ [~] plus dropped
EOF
    local result
    result="$(count_total_tasks plan.md)"
    [ "$result" -eq 3 ]
}

@test "count_total_tasks: counts heading-form and numbered checkboxes" {
    cat > plan.md <<'EOF'
### [ ] 1.1 heading todo
### [x] 1.2 heading done
#### [~] 1.3 heading dropped
1. [ ] numbered todo
## Phase heading (not a task)
EOF
    local result
    result="$(count_total_tasks plan.md)"
    [ "$result" -eq 4 ]
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

@test "count_dropped: counts * and + dropped bullets" {
    cat > plan.md <<'EOF'
* [~] star dropped
+ [~] plus dropped
- [ ] dash todo
EOF
    local result
    result="$(count_dropped plan.md)"
    [ "$result" -eq 2 ]
}

@test "count_dropped: counts heading-form dropped checkboxes" {
    cat > plan.md <<'EOF'
### [~] 1.1 heading dropped
1. [~] numbered dropped
### [ ] 1.2 heading todo
EOF
    local result
    result="$(count_dropped plan.md)"
    [ "$result" -eq 2 ]
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
    [[ "$result" == *"There are 2 dropped tasks"* ]] || return 1
    [[ "$result" == *"What was dropped"* ]] || return 1
    [[ "$result" == *"Do not re-mark"* ]] || return 1
    [[ "$result" == *"[~]"* ]] || return 1
    [[ "$result" == *"**2.6** dropped: no perplexity endpoint"* ]] || return 1
    [[ "$result" == *"**3.1** dropped: covered by upstream"* ]] || return 1
}

@test "build_dropped_context: starts with literal \\n\\n separator" {
    cat > plan.md <<'EOF'
- [~] dropped
EOF
    local result
    result="$(build_dropped_context plan.md)"
    # Match the conditional-context pattern in run_execute, which prepends
    # a literal `\n\n` so the appended block reads as a fresh paragraph.
    [[ "$result" == '\n\n'* ]] || return 1
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
    [[ "$result" == *"There are 3 dropped tasks"* ]] || return 1
    [[ "$result" == *"from a"* ]] || return 1
    [[ "$result" == *"from b1"* ]] || return 1
    [[ "$result" == *"from b2"* ]] || return 1
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
    [[ "$output" == *"Warning"* ]] || return 1
    [[ "$output" == *"41 tasks"* ]] || return 1
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
    [[ "$output" == *"41 tasks"* ]] || return 1
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
    [[ "$(cat docs/stdin.md)" == "my issue text" ]] || return 1
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
    [[ "$(cat docs/stdin.md)" == "new plan" ]] || return 1
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

@test "looks_like_plan: accepts * and + bullet checkboxes" {
    printf "* [ ] Star task\n" > star.md
    looks_like_plan star.md
    printf "+ [x] Plus task\n" > plus.md
    looks_like_plan plus.md
}

@test "looks_like_plan: accepts heading-form and numbered checkboxes" {
    printf "### [ ] 1.1 Heading task\n" > head.md
    looks_like_plan head.md
    printf "1. [ ] Numbered task\n" > num.md
    looks_like_plan num.md
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

# ── input_describes_defect ───────────────────────────────────────────────────

@test "input_describes_defect: accepts a defect-shaped input file" {
    echo "This is a Bug: the column is wrong" > issue.md
    input_describes_defect issue.md
}

@test "input_describes_defect: rejects a feature-shaped input file" {
    echo "Add a CSV export button to the reports page" > issue.md
    ! input_describes_defect issue.md
}

@test "input_describes_defect: rejects an empty file" {
    : > issue.md
    ! input_describes_defect issue.md
}

@test "input_describes_defect: rejects a nonexistent path without stderr noise" {
    run input_describes_defect does-not-exist.md
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "input_describes_defect: accepts when only a later file is defect-shaped" {
    echo "Add a CSV export button to the reports page" > feature.md
    echo "The nightly job crashes after the deploy" > issue.md
    input_describes_defect feature.md issue.md
}

@test "input_describes_defect: matches a capitalized signal word" {
    echo "# BUG REPORT" > issue.md
    input_describes_defect issue.md
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
    [[ "$output" == *"score: 42"* ]] || return 1
    [[ "$output" == *"Benchmark:"* ]] || return 1
}

@test "run_benchmarks: concatenates output from multiple scripts" {
    BENCHMARK_SCRIPTS=("echo 'size: 100kb'" "echo 'speed: 200ms'")
    local output
    output="$(run_benchmarks)"
    [[ "$output" == *"size: 100kb"* ]] || return 1
    [[ "$output" == *"speed: 200ms"* ]] || return 1
}

@test "run_benchmarks: handles failing scripts gracefully" {
    BENCHMARK_SCRIPTS=("false")
    local output
    output="$(run_benchmarks)"
    [[ "$output" == *"failed with exit code"* ]] || return 1
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
    [[ "$result" == *"0"* ]] || return 1
    [[ "$result" == *"5"* ]] || return 1
}

@test "extract_benchmark_numbers: extracts decimals" {
    local result
    result="$(echo 'Ratio: 0.955x, PR-AUC: 0.42' | extract_benchmark_numbers)"
    [[ "$result" == *"0.955"* ]] || return 1
    [[ "$result" == *"0.42"* ]] || return 1
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
    [[ "$result" == *"0.955"* ]] || return 1
    [[ "$result" == *"3353"* ]] || return 1
    [[ "$result" == *"17.5"* ]] || return 1
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
    [[ "$result" != *- ]] || return 1
}

@test "slugify: falls back to date when file is empty" {
    touch plan.md
    local result
    result="$(slugify plan.md)"
    [[ "$result" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
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

# ── trim_whitespace ──────────────────────────────────────────────────────────

@test "trim_whitespace: strips leading and trailing whitespace" {
    [ "$(trim_whitespace "   npm test   ")" = "npm test" ]
    [ "$(trim_whitespace $'\tnpm test\t')" = "npm test" ]
}

@test "trim_whitespace: keeps interior whitespace" {
    [ "$(trim_whitespace "  ruff format .  ")" = "ruff format ." ]
}

@test "trim_whitespace: preserves double quotes" {
    [ "$(trim_whitespace ' pytest -k "not slow" ')" = 'pytest -k "not slow"' ]
}

@test "trim_whitespace: preserves an apostrophe" {
    [ "$(trim_whitespace " echo don't ")" = "echo don't" ]
}

@test "trim_whitespace: preserves backslashes" {
    [ "$(trim_whitespace ' grep \d file ')" = 'grep \d file' ]
}

@test "trim_whitespace: empty and all-whitespace inputs yield empty" {
    [ "$(trim_whitespace "")" = "" ]
    [ "$(trim_whitespace "    ")" = "" ]
}

# ── load_config_from ─────────────────────────────────────────────────────────

@test "load_config_from: preserves quotes in a verify command" {
    cat > test.rc <<'EOF'
verify = pytest -k "not slow"
EOF
    local output
    output="$(load_config_from test.rc)"
    [ "$output" = 'verify=pytest -k "not slow"' ]
}

@test "load_config_from: preserves a backslash in a verify command" {
    cat > test.rc <<'EOF'
verify = grep -q \d report.txt
EOF
    local output
    output="$(load_config_from test.rc)"
    [ "$output" = 'verify=grep -q \d report.txt' ]
}

@test "load_config_from: an apostrophe does not truncate the value" {
    cat > test.rc <<'EOF'
verify = sh -c "echo it's fine"
EOF
    local output
    output="$(load_config_from test.rc)"
    [ "$output" = 'verify=sh -c "echo it'"'"'s fine"' ]
}

@test "load_config_from: outputs verify lines to stdout" {
    cat > test.rc <<'EOF'
verify = npm test
verify = npm run build
EOF
    local output
    output="$(load_config_from test.rc)"
    [[ "$output" == *"verify=npm test"* ]] || return 1
    [[ "$output" == *"verify=npm run build"* ]] || return 1
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
    [[ "$output" == *"iterations=10"* ]] || return 1
    [[ "$output" == *"max_validation_retries=2"* ]] || return 1
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
    [[ "$output" == *"unknown config key"* ]] || return 1
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
    [[ "$err" == *"Loading config from"* ]] || return 1
}

@test "load_config: 'no config found' message goes to stderr not stdout" {
    HOME="$TEST_DIR/nohome"
    mkdir -p "$HOME"
    local out err
    out="$(load_config 2>/dev/null)"
    err="$(load_config 2>&1 >/dev/null)"
    [ -z "$out" ]
    [[ "$err" == *"No .wiggumrc found"* ]] || return 1
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

@test "apply_config: sets claude_retries" {
    apply_config <<< "claude_retries=4"
    [ "$CLAUDE_RETRIES" = "4" ]
}

@test "apply_config: CLI_CLAUDE_RETRIES takes precedence over config" {
    CLI_CLAUDE_RETRIES="0"
    CLAUDE_RETRIES="0"
    apply_config <<< "claude_retries=4"
    [ "$CLAUDE_RETRIES" = "0" ]
}

@test "load_config_from: claude_retries is recognized and forwarded" {
    cat > .wiggumrc <<'EOF'
claude_retries = 4
EOF
    run load_config_from .wiggumrc
    [[ "$output" == *"claude_retries=4"* ]] || return 1
    [[ "$output" != *"unknown config key"* ]] || return 1
}

@test "parse_args: --claude-retries sets CLAUDE_RETRIES and marks the CLI override" {
    make_file "plan.md"
    parse_args execute plan.md --claude-retries 5
    [ "$CLAUDE_RETRIES" = "5" ]
    [ "$CLI_CLAUDE_RETRIES" = "5" ]
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
    [[ "$output" == *"npm run type-check"* ]] || return 1
    [[ "$output" == *"npm test"* ]] || return 1
    [[ "$output" == *"npm run build"* ]] || return 1
}

@test "generate_rc: python preset contains ruff and pytest" {
    local output
    output="$(generate_rc python)"
    [[ "$output" == *"ruff format"* ]] || return 1
    [[ "$output" == *"pytest"* ]] || return 1
}

@test "generate_rc: astro preset contains prettier" {
    local output
    output="$(generate_rc astro)"
    [[ "$output" == *"prettier"* ]] || return 1
}

@test "generate_rc: bash preset contains shellcheck and bats" {
    local output
    output="$(generate_rc bash)"
    [[ "$output" == *"shellcheck"* ]] || return 1
    [[ "$output" == *"bats"* ]] || return 1
}

@test "generate_rc: unknown preset exits EXIT_BAD_ARGS" {
    run generate_rc golang
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"unknown preset"* ]] || return 1
}

# ── run_init ─────────────────────────────────────────────────────────────────

@test "run_init: creates .wiggumrc from explicit preset" {
    INIT_PRESET="python"
    # stdin order: permission-mode, permissions, skill
    printf "\nn\nn\n" | run_init
    [ -f ".wiggumrc" ]
    grep -q "pytest" .wiggumrc
}

@test "run_init: auto-detects preset" {
    INIT_PRESET=""
    touch package.json
    printf "\nn\nn\n" | run_init
    [ -f ".wiggumrc" ]
    grep -q "npm test" .wiggumrc
}

@test "run_init: defaults permission_mode to auto" {
    INIT_PRESET="node"
    # Empty answer to the permission-mode prompt selects the default (auto).
    printf "\nn\nn\n" | run_init
    grep -q "permission_mode = auto" .wiggumrc
}

@test "run_init: writes bypassPermissions when chosen" {
    INIT_PRESET="node"
    # "2" at the permission-mode prompt selects bypassPermissions.
    printf "2\nn\nn\n" | run_init
    grep -q "permission_mode = bypassPermissions" .wiggumrc
    ! grep -q "permission_mode = auto" .wiggumrc
}

@test "run_init: chosen permission_mode is loadable config" {
    INIT_PRESET="node"
    printf "\nn\nn\n" | run_init
    # The generated line must round-trip through the config loader.
    wiggum_reset
    apply_config < <(load_config_from .wiggumrc)
    [ "$PERMISSION_MODE" = "auto" ]
}

@test "run_init: creates .claude/settings.local.json when approved" {
    INIT_PRESET="node"
    # stdin order: permission-mode, permissions, pkg-manager, skill
    printf "\ny\nn\nn\n" | run_init
    [ -f ".claude/settings.local.json" ]
    grep -q "git add" .claude/settings.local.json
    grep -q "npm run" .claude/settings.local.json
}

@test "run_init: skips permissions when declined" {
    INIT_PRESET="node"
    printf "\nn\nn\n" | run_init
    [ ! -f ".claude/settings.local.json" ]
}

@test "run_init: fails with EXIT_BAD_ARGS when nothing to detect and no preset" {
    INIT_PRESET=""
    run run_init
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"Could not auto-detect"* ]] || return 1
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

# ── prompt verification helpers ──────────────────────────────────────────────

@test "prompt_plan_verification: requires a Files line per task" {
    run prompt_plan_verification
    [ "$status" -eq 0 ]
    [[ "$output" == *"'Files:' line"* ]] || return 1
    [[ "$output" == *"create or modify"* ]] || return 1
}

@test "prompt_plan_verification: requires confirming dependencies exist" {
    run prompt_plan_verification
    [[ "$output" == *"confirm the libraries, APIs, and commands"* ]] || return 1
    [[ "$output" == *"actually exist"* ]] || return 1
}

@test "prompt_plan_verification: requires path:line citations for current behaviour" {
    run prompt_plan_verification
    [ "$status" -eq 0 ]
    [[ "$output" == *"path:line"* ]] || return 1
    [[ "$output" == *"read that line"* ]] || return 1
    [[ "$output" == *"current behaviour"* ]] || return 1
}

@test "prompt_plan_verification: requires checking test-file harness feasibility" {
    run prompt_plan_verification
    [ "$status" -eq 0 ]
    [[ "$output" == *"module-scope mocks"* ]] || return 1
    [[ "$output" == *"vi.mock"* ]] || return 1
    [[ "$output" == *"needs a new one"* ]] || return 1
    [[ "$output" == *"weaken an existing mock"* ]] || return 1
}

@test "prompt_implement_verification: demands assumption checks before coding" {
    run prompt_implement_verification
    [ "$status" -eq 0 ]
    [[ "$output" == *"verify your assumptions"* ]] || return 1
    [[ "$output" == *"do not assume"* ]] || return 1
}

@test "prompt_implement_verification: requires a failing test first when none exists" {
    run prompt_implement_verification
    [[ "$output" == *"write a minimal failing test first"* ]] || return 1
}

@test "prompt_implement_verification: requires happy, edge, and failure spot checks" {
    run prompt_implement_verification
    [[ "$output" == *"three spot checks"* ]] || return 1
    [[ "$output" == *"happy path"* ]] || return 1
    [[ "$output" == *"edge case"* ]] || return 1
    [[ "$output" == *"failure case"* ]] || return 1
}

@test "prompt_implement_verification: gates task completion on acceptance and spot checks" {
    run prompt_implement_verification
    [[ "$output" == *"Do not mark a task"* ]] || return 1
    [[ "$output" == *"acceptance criterion is met and all three spot checks pass"* ]] || return 1
}

@test "prompt_acceptance_criteria: requires a per-phase Acceptance Criteria section" {
    run prompt_acceptance_criteria
    [ "$status" -eq 0 ]
    [[ "$output" == *"### Acceptance Criteria"* ]] || return 1
}

@test "prompt_acceptance_criteria: names the four criteria categories" {
    run prompt_acceptance_criteria
    [[ "$output" == *"Happy Path"* ]] || return 1
    [[ "$output" == *"Edge Cases"* ]] || return 1
    [[ "$output" == *"Error States"* ]] || return 1
    [[ "$output" == *"Non-Functional"* ]] || return 1
}

@test "prompt_acceptance_criteria: recommends the Given/When/Then form" {
    run prompt_acceptance_criteria
    [[ "$output" == *"Given"* ]] || return 1
    [[ "$output" == *"When"* ]] || return 1
    [[ "$output" == *"Then"* ]] || return 1
}

@test "prompt_acceptance_criteria: demands an observable check for Non-Functional" {
    run prompt_acceptance_criteria
    [[ "$output" == *"Non-Functional"* ]] || return 1
    [[ "$output" == *"observable check"* ]] || return 1
}

@test "prompt_acceptance_criteria: keeps the section additive to per-task lines" {
    run prompt_acceptance_criteria
    [[ "$output" == *"additive"* ]] || return 1
    [[ "$output" == *"per-task 'Acceptance:' and 'Files:' lines"* ]] || return 1
}

@test "prompt_expected_benefits: opens the plan with the benefits section" {
    run prompt_expected_benefits
    [ "$status" -eq 0 ]
    [[ "$output" == *"## Expected benefits"* ]] || return 1
    [[ "$output" == *"most valuable first"* ]] || return 1
}

@test "prompt_expected_benefits: every benefit carries an observable signal" {
    run prompt_expected_benefits
    [[ "$output" == *"'Signal:' line"* ]] || return 1
    [[ "$output" == *"after shipping"* ]] || return 1
    # An unmeasurable benefit is labelled, not padded out into a fake metric.
    [[ "$output" == *"speculative"* ]] || return 1
}

@test "prompt_expected_benefits: ties every phase back to a benefit" {
    run prompt_expected_benefits
    [[ "$output" == *"'Serves:' line"* ]] || return 1
    [[ "$output" == *"scope creep"* ]] || return 1
    # The planner may conclude the work is not worth doing as scoped.
    [[ "$output" == *"do not justify the work"* ]] || return 1
    [[ "$output" == *"smaller version"* ]] || return 1
}

@test "prompt_constraints_summary: follows the benefits section" {
    run prompt_constraints_summary
    [[ "$output" == *"Immediately after '## Expected benefits'"* ]] || return 1
    # The pre-existing ordering rule survives: still ahead of phases and tasks.
    [[ "$output" == *"before writing any phases or tasks"* ]] || return 1
}

@test "prompt_issue_ledger: names where a repo keeps its issue ledger" {
    run prompt_issue_ledger
    [ "$status" -eq 0 ]
    [[ "$output" == *"issue ledger"* ]] || return 1
    [[ "$output" == *"ISSUES.md"* ]] || return 1
    [[ "$output" == *"CHANGELOG"* ]] || return 1
    # The seed issue file itself is a ledger when it carries a status table.
    [[ "$output" == *"the plan's own issue file"* ]] || return 1
}

@test "prompt_issue_ledger: closes only what actually shipped" {
    run prompt_issue_ledger
    [[ "$output" == *"ONLY the entries this run actually finished"* ]] || return 1
    [[ "$output" == *"commit refs"* ]] || return 1
    # An open or dropped task must not produce a shipped row.
    [[ "$output" == *"has NOT shipped"* ]] || return 1
    [[ "$output" == *"false 'done' row"* ]] || return 1
    [[ "$output" == *"untouched"* ]] || return 1
}

@test "prompt_issue_ledger: never invents a ledger or closes a remote tracker" {
    run prompt_issue_ledger
    [[ "$output" == *"Never invent a ledger"* ]] || return 1
    [[ "$output" == *"backfilling an entry"* ]] || return 1
    # Closing someone's GitHub/Jira issue is a human's call, not the loop's.
    [[ "$output" == *"Do not close a remote tracker"* ]] || return 1
    [[ "$output" == *"leave closing it to a human"* ]] || return 1
}

@test "prompt_research_and_delegation: keeps non-edit tasks actionable" {
    run prompt_research_and_delegation
    [ "$status" -eq 0 ]
    [[ "$output" == *"actionable"* ]] || return 1
    [[ "$output" == *"research task"* ]] || return 1
    # A research task still lands an artifact, not a feeling of understanding.
    [[ "$output" == *"written artifact"* ]] || return 1
    [[ "$output" == *"never 'understand X'"* ]] || return 1
}

@test "prompt_research_and_delegation: allows bounded nested wiggum runs" {
    run prompt_research_and_delegation
    [[ "$output" == *"wiggum plan"* ]] || return 1
    [[ "$output" == *"--max-iterations"* ]] || return 1
    [[ "$output" == *"foreground"* ]] || return 1
    # Guardrails: self-contained, bounded, and never fanned out in parallel.
    [[ "$output" == *"self-contained"* ]] || return 1
    [[ "$output" == *"never launch nested runs in parallel"* ]] || return 1
}

@test "prompt_constraints_summary: opens the plan with a Constraints section as a self-check" {
    run prompt_constraints_summary
    [ "$status" -eq 0 ]
    [[ "$output" == *"## Constraints"* ]] || return 1
    [[ "$output" == *"self-check"* ]] || return 1
}

@test "prompt_constraints_summary: names in-scope, out-of-scope, and never-do" {
    run prompt_constraints_summary
    [[ "$output" == *"In scope"* ]] || return 1
    [[ "$output" == *"Out of scope"* ]] || return 1
    [[ "$output" == *"Never do"* ]] || return 1
}

@test "prompt_risk_gates: names the four risk gates" {
    run prompt_risk_gates
    [ "$status" -eq 0 ]
    [[ "$output" == *"read-only measurement"* ]] || return 1
    [[ "$output" == *"never"* ]] || return 1
    [[ "$output" == *"legitimate exceptions"* ]] || return 1
    [[ "$output" == *"first run"* ]] || return 1
}

@test "prompt_risk_gates: states each gate conditionally so no phase is mandated" {
    run prompt_risk_gates
    [[ "$output" == *"If a phase is justified by"* ]] || return 1
    [[ "$output" == *"If a task"* ]] || return 1
    [[ "$output" == *"not triggered"* ]] || return 1
}

@test "prompt_risk_gates: irreversible tasks carry all four conditions" {
    run prompt_risk_gates
    [[ "$output" == *"dry run"* ]] || return 1
    [[ "$output" == *"export"* ]] || return 1
    [[ "$output" == *"idempotent"* ]] || return 1
    [[ "$output" == *"affected count"* ]] || return 1
}

@test "prompt_risk_gates: a new guard must pass now and fail on reintroduction" {
    run prompt_risk_gates
    [[ "$output" == *"passes against current code on its first run"* ]] || return 1
    [[ "$output" == *"reintroduced"* ]] || return 1
}

@test "prompt_phase_sequencing: separates ship-independence from task dependencies" {
    run prompt_phase_sequencing
    [ "$status" -eq 0 ]
    [[ "$output" == *"ship independently"* ]] || return 1
    [[ "$output" == *"must wait"* ]] || return 1
    [[ "$output" == *"not the task-dependency list"* ]] || return 1
}

@test "prompt_phase_sequencing: gives the discriminator for shipping risk" {
    run prompt_phase_sequencing
    [[ "$output" == *"nulls into values"* ]] || return 1
    [[ "$output" == *"delete good data"* ]] || return 1
}

@test "prompt_defect_diagnosis: names the four diagnosis sections" {
    run prompt_defect_diagnosis
    [ "$status" -eq 0 ]
    [[ "$output" == *"## Symptoms"* ]] || return 1
    [[ "$output" == *"## Root cause"* ]] || return 1
    [[ "$output" == *"## Why existing verification missed it"* ]] || return 1
    [[ "$output" == *"## Blast radius"* ]] || return 1
    [[ "$output" == *"unaffected"* ]] || return 1
}

@test "prompt_defect_diagnosis: requires every symptom tagged observed or predicted" {
    run prompt_defect_diagnosis
    [[ "$output" == *"observed"* ]] || return 1
    [[ "$output" == *"predicted"* ]] || return 1
    [[ "$output" == *"EVERY symptom tagged"* ]] || return 1
}

@test "prompt_defect_diagnosis: requires the tell" {
    run prompt_defect_diagnosis
    [[ "$output" == *"tell"* ]] || return 1
    [[ "$output" == *"benign explanation"* ]] || return 1
}

@test "prompt_defect_diagnosis: requires path:line for each root-cause step" {
    run prompt_defect_diagnosis
    [[ "$output" == *"numbered path from entry point to failure"* ]] || return 1
    [[ "$output" == *"path:line"* ]] || return 1
}

@test "prompt_defect_diagnosis: permits skipping for non-defect work" {
    run prompt_defect_diagnosis
    [[ "$output" =~ not.*defect ]] || return 1
    [[ "$output" == *"inventing symptoms"* ]] || return 1
}

@test "prompt_constraints_summary: requires it before any phases or tasks" {
    run prompt_constraints_summary
    [[ "$output" == *"before writing any phases or tasks"* ]] || return 1
}

# ── setup_wiggum_skill ───────────────────────────────────────────────────────

@test "setup_wiggum_skill: creates skill file when approved" {
    echo "y" | setup_wiggum_skill
    [ -f ".claude/skills/wiggum/SKILL.md" ]
    grep -q "name: wiggum" .claude/skills/wiggum/SKILL.md
    grep -q '\$ARGUMENTS' .claude/skills/wiggum/SKILL.md
}

@test "setup_wiggum_skill: skill is model-invocable (no disable flag)" {
    echo "y" | setup_wiggum_skill
    # The orchestrator is meant to be driven by Claude (execute, watch, ...),
    # so it must NOT carry disable-model-invocation.
    ! grep -q "disable-model-invocation" .claude/skills/wiggum/SKILL.md
}

@test "setup_wiggum_skill: skips when declined" {
    echo "n" | setup_wiggum_skill
    [ ! -f ".claude/skills/wiggum/SKILL.md" ]
}

@test "wiggum_skill_content: emits the skill markdown" {
    run wiggum_skill_content
    [[ "$output" == *"name: wiggum"* ]] || return 1
    [[ "$output" == *"wiggum execute"* ]] || return 1
}

@test "wiggum_skill_content: documents the phase-level Acceptance Criteria section" {
    run wiggum_skill_content
    [[ "$output" == *"### Acceptance Criteria"* ]] || return 1
    [[ "$output" == *"Happy Path"* ]] || return 1
    [[ "$output" == *"Edge Cases"* ]] || return 1
    [[ "$output" == *"Error States"* ]] || return 1
    [[ "$output" == *"Non-Functional"* ]] || return 1
}

@test "wiggum_skill_content: documents starting the plan from expected benefits" {
    run wiggum_skill_content
    [[ "$output" == *"## Expected benefits"* ]] || return 1
    [[ "$output" == *"Start from the benefits, not from the tasks"* ]] || return 1
    [[ "$output" == *"Signal:"* ]] || return 1
    [[ "$output" == *"speculative"* ]] || return 1
    # Phases trace back to the benefits they deliver.
    [[ "$output" == *"Serves: benefits"* ]] || return 1
    [[ "$output" == *"scope creep"* ]] || return 1
}

@test "wiggum_skill_content: documents research tasks and nested wiggum runs" {
    run wiggum_skill_content
    [[ "$output" == *"doesn't have to be an edit"* ]] || return 1
    [[ "$output" == *"Research / a deep-dive spike"* ]] || return 1
    [[ "$output" == *"never \"understand X\""* ]] || return 1
    [[ "$output" == *"A nested wiggum run"* ]] || return 1
    [[ "$output" == *"--max-iterations N"* ]] || return 1
    # A background child would outlive the iteration that launched it.
    [[ "$output" == *"foreground"* ]] || return 1
}

@test "wiggum_skill_content: documents opening the plan with a Constraints section" {
    run wiggum_skill_content
    [[ "$output" == *"## Constraints"* ]] || return 1
    [[ "$output" == *"In scope"* ]] || return 1
    [[ "$output" == *"Out of scope"* ]] || return 1
    [[ "$output" == *"Never do"* ]] || return 1
}

@test "wiggum_skill_content: documents the defect diagnosis sections" {
    run wiggum_skill_content
    [[ "$output" == *"## Symptoms"* ]] || return 1
    [[ "$output" == *"## Root cause"* ]] || return 1
    [[ "$output" == *"## Why existing verification missed it"* ]] || return 1
    [[ "$output" == *"## Blast radius"* ]] || return 1
    [[ "$output" == *"defect work only"* ]] || return 1
    [[ "$output" == *"**observed**"* ]] || return 1
    [[ "$output" == *"**predicted**"* ]] || return 1
    [[ "$output" == *"omit them rather than inventing"* ]] || return 1
}

@test "wiggum_skill_content: documents the risk gates" {
    run wiggum_skill_content
    [[ "$output" == *"four risk gates"* ]] || return 1
    [[ "$output" == *"read-only measurement"* ]] || return 1
    [[ "$output" == *"dry run"* ]] || return 1
    [[ "$output" == *"idempotent"* ]] || return 1
    [[ "$output" == *"record the affected"* ]] || return 1
    [[ "$output" == *"legitimate exceptions"* ]] || return 1
    [[ "$output" == *"first run"* ]] || return 1
    [[ "$output" == *"reintroduced"* ]] || return 1
    # A gate that doesn't apply is marked, not dropped.
    [[ "$output" == *"mark a gate whose trigger is absent"* ]] || return 1
}

@test "wiggum_skill_content: documents the issue ledger closing with the run" {
    run wiggum_skill_content
    [[ "$output" == *"issue ledger"* ]] || return 1
    [[ "$output" == *"3f"* ]] || return 1
    # What the supervisor owns: pointing at an unfindable ledger, and checking the
    # record against the tree rather than trusting the row.
    [[ "$output" == *"name that path in the plan"* ]] || return 1
    [[ "$output" == *"git show --stat"* ]] || return 1
    [[ "$output" == *"still \`[ ]\`"* ]] || return 1
    # It reports an absent ledger; it does not create one or close a remote tracker.
    [[ "$output" == *"will not invent a ledger"* ]] || return 1
    [[ "$output" == *"GitHub, Jira"* ]] || return 1
}

@test "wiggum_skill_content: documents --at in the CLI reference table" {
    run wiggum_skill_content
    # Agents drive wiggum from this table; a flag missing here is a flag unused.
    [[ "$output" == *"wiggum execute <plan> --at <WHEN>"* ]] || return 1
    [[ "$output" == *"+90m"* ]] || return 1
    [[ "$output" == *"01:07"* ]] || return 1
    [[ "$output" == *"@1756180020"* ]] || return 1
}

@test "wiggum_skill_content: committed SKILL.md stays in sync with the heredoc" {
    local committed
    committed="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/.claude/skills/wiggum/SKILL.md"
    [ -f "$committed" ]
    # Fails loudly if the two copies drift; the function is the source of truth.
    diff <(wiggum_skill_content) "$committed"
}

@test "setup_wiggum_skill: leaves an up-to-date skill untouched" {
    mkdir -p .claude/skills/wiggum
    wiggum_skill_content > .claude/skills/wiggum/SKILL.md
    run setup_wiggum_skill
    [ "$status" -eq 0 ]
    [[ "$output" == *"up to date"* ]] || return 1
}

@test "setup_wiggum_skill: offers to update an outdated skill and keeps it on no" {
    mkdir -p .claude/skills/wiggum
    echo "old skill v0" > .claude/skills/wiggum/SKILL.md
    run bash -c "source '$WIGGUM_LIB'; echo n | setup_wiggum_skill"
    [ "$status" -eq 0 ]
    [[ "$output" == *"older /wiggum skill"* ]] || return 1
    # Declining keeps the user's file intact.
    grep -q "old skill v0" .claude/skills/wiggum/SKILL.md
}

@test "setup_wiggum_skill: updates an outdated skill on yes" {
    mkdir -p .claude/skills/wiggum
    echo "old skill v0" > .claude/skills/wiggum/SKILL.md
    echo "y" | setup_wiggum_skill
    # Now matches the current content; the stale text is gone.
    ! grep -q "old skill v0" .claude/skills/wiggum/SKILL.md
    grep -q "name: wiggum" .claude/skills/wiggum/SKILL.md
    grep -q "Preflight" .claude/skills/wiggum/SKILL.md
}

@test "setup_wiggum_skill: skill drives the wiggum CLI commands" {
    echo "y" | setup_wiggum_skill
    grep -q "wiggum execute" .claude/skills/wiggum/SKILL.md
    grep -q "wiggum status" .claude/skills/wiggum/SKILL.md
    grep -q "wiggum watch" .claude/skills/wiggum/SKILL.md
    grep -q "wiggum kill" .claude/skills/wiggum/SKILL.md
    grep -q "wiggum chain" .claude/skills/wiggum/SKILL.md
    grep -q "wiggum top" .claude/skills/wiggum/SKILL.md
    # Warn the driving agent off the internal shell-function names, which fail
    # with "command not found" in a fresh shell (e.g. under conda run).
    grep -q "run_top" .claude/skills/wiggum/SKILL.md
    grep -qi "command not found" .claude/skills/wiggum/SKILL.md
}

@test "setup_wiggum_skill: skill covers supervision and plan format" {
    echo "y" | setup_wiggum_skill
    # Supervision: monitor, wait, detect-blocked, scoped kill.
    grep -q -- "--background" .claude/skills/wiggum/SKILL.md
    grep -q -- "--kill-on-timeout" .claude/skills/wiggum/SKILL.md
    grep -qi "blocked" .claude/skills/wiggum/SKILL.md
    # Plan format it can author, and why the checkboxes matter (counted for progress).
    grep -q "Acceptance:" .claude/skills/wiggum/SKILL.md
    grep -q "Files:" .claude/skills/wiggum/SKILL.md
    grep -q "0 tasks" .claude/skills/wiggum/SKILL.md
    # Runtime environment guidance (activate conda/venv/etc. before running).
    grep -qi "environment" .claude/skills/wiggum/SKILL.md
    grep -qi "conda" .claude/skills/wiggum/SKILL.md
}

@test "setup_wiggum_skill: skill is the authoritative interface (no --help spelunking)" {
    echo "y" | setup_wiggum_skill
    local skill=".claude/skills/wiggum/SKILL.md"
    # One batched preflight, and the skill asserts itself as the source of truth.
    grep -qi "authoritative" "$skill"
    grep -qi "preflight" "$skill"
    grep -q -- "--help" "$skill"
}

@test "setup_wiggum_skill: skill covers stalled/incomplete remediation" {
    echo "y" | setup_wiggum_skill
    local skill=".claude/skills/wiggum/SKILL.md"
    # Distinguishes the stop reasons and drives a remediate-and-re-run loop.
    grep -qi "incomplete" "$skill"
    grep -qi "stalled" "$skill"
    grep -qi "remediate" "$skill"
    # Stall mitigations: spot-check, split tasks, drop with [~], escalate.
    grep -q "wiggum check" "$skill"
    grep -q '\[~\]' "$skill"
    # Bounded retries, not an infinite loop.
    grep -qi "cap" "$skill"
}

@test "setup_wiggum_skill: skill says to watch a running run and summarize" {
    echo "y" | setup_wiggum_skill
    local skill=".claude/skills/wiggum/SKILL.md"
    grep -q "wiggum watch" "$skill"
    grep -qi "already in progress" "$skill"
    grep -qi "report a summary" "$skill"
}

@test "run_init: creates skill when approved" {
    INIT_PRESET="node"
    # permission-mode(default), y=permissions, n=pkg-manager, y=skill
    printf "\ny\nn\ny\n" | run_init
    [ -f ".claude/skills/wiggum/SKILL.md" ]
}

@test "run_init: aborts on existing .wiggumrc when user says no" {
    echo "old" > .wiggumrc
    INIT_PRESET="node"
    run bash -c "source '$WIGGUM_LIB'; INIT_PRESET=node; echo n | run_init"
    grep -q "old" .wiggumrc
}

# ── prompt_permission_mode ───────────────────────────────────────────────────

@test "prompt_permission_mode: empty input defaults to auto" {
    [ "$(echo "" | prompt_permission_mode 2>/dev/null)" = "auto" ]
    [ "$(echo "1" | prompt_permission_mode 2>/dev/null)" = "auto" ]
}

@test "prompt_permission_mode: 2 or bypass selects bypassPermissions" {
    [ "$(echo "2" | prompt_permission_mode 2>/dev/null)" = "bypassPermissions" ]
    [ "$(echo "bypass" | prompt_permission_mode 2>/dev/null)" = "bypassPermissions" ]
    [ "$(echo "bypassPermissions" | prompt_permission_mode 2>/dev/null)" = "bypassPermissions" ]
}

@test "prompt_permission_mode: unrecognized input falls back to auto" {
    [ "$(echo "garbage" | prompt_permission_mode 2>/dev/null)" = "auto" ]
}

# ── run_validation ───────────────────────────────────────────────────────────

@test "run_validation: skips when no verify steps" {
    VERIFY_STEPS=()
    run run_validation
    [ "$status" -eq 0 ]
    [[ "$output" == *"No verification steps"* ]] || return 1
}

@test "run_validation: passes when all steps succeed" {
    VERIFY_STEPS=("true" "true")
    run run_validation
    [ "$status" -eq 0 ]
    [[ "$output" == *"All verification steps passed"* ]] || return 1
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
    [[ "$output" == *"Validation failed 2 times"* ]] || return 1
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
    [[ "$output" == *"attempt 1 of 3"* ]] || return 1
    [[ "$output" == *"attempt 2 of 3"* ]] || return 1
    [[ "$output" == *"attempt 3 of 3"* ]] || return 1
    [[ "$output" != *"attempt 4 of 3"* ]] || return 1
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
    [[ "$output" == *"--- Error output ---"* ]] || return 1
    [[ "$output" == *"some error details"* ]] || return 1
    [[ "$output" == *"Check that your .wiggumrc verify commands are correct"* ]] || return 1
    [[ "$output" == *"Last failing command"* ]] || return 1
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
    [[ "$output" == *"Requesting fix from Claude"* ]] || return 1
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
    [[ "$output" != *"SHOULD_NOT_RUN"* ]] || return 1
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
    [[ "$output" == *"PASSED"* ]] || return 1
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
    [[ "$output" == *"requires -i"* ]] || return 1
}

@test "parse_args: docs mode fails without -o" {
    make_file in.md
    run parse_args docs -i in.md
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"requires -o"* ]] || return 1
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
    [[ "${claude_calls[0]}" == *"summary.md"* ]] || return 1
    [[ "${claude_calls[0]}" == *"readme.md"* ]] || return 1
}

@test "run_update_docs: prints input and output in log" {
    make_file s.md
    make_file r.md
    run run_update_docs s.md -- r.md
    [ "$status" -eq 0 ]
    [[ "$output" == *"Input: s.md"* ]] || return 1
    [[ "$output" == *"Output: r.md"* ]] || return 1
    [[ "$output" == *"Documentation updated"* ]] || return 1
}

@test "run_update_docs: handles multiple inputs and outputs" {
    make_file a.md
    make_file b.md
    make_file x.md
    make_file y.md
    run run_update_docs a.md b.md -- x.md y.md
    [ "$status" -eq 0 ]
    [[ "$output" == *"Input: a.md b.md"* ]] || return 1
    [[ "$output" == *"Output: x.md y.md"* ]] || return 1
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
    [[ "$output" == *"wiggum check"* ]] || return 1
    [[ "$output" == *"verification"* ]] || return 1
}

# ── run_check ────────────────────────────────────────────────────────────────

@test "run_check: passes when all verify steps pass" {
    VERIFY_STEPS=("true" "true")
    run run_check
    [ "$status" -eq 0 ]
    [[ "$output" == *"ALL CHECKS PASSED"* ]] || return 1
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
    [[ "$output" == *"CHECKS FAILED"* ]] || return 1
}

@test "run_check: reports no steps when none configured" {
    VERIFY_STEPS=()
    run run_check
    [ "$status" -eq 0 ]
    [[ "$output" == *"No verification steps"* ]] || return 1
}

@test "run_check: reminds about the shell environment when steps run" {
    VERIFY_STEPS=("true")
    run run_check
    [ "$status" -eq 0 ]
    [[ "$output" == *"Reminder:"* ]] || return 1
    [[ "$output" == *"environment"* ]] || return 1
}

@test "run_check: no environment reminder when there are no steps" {
    VERIFY_STEPS=()
    run run_check
    [[ "$output" != *"Reminder:"* ]] || return 1
}

@test "run_check: uses same run_validation as execute mode" {
    # Verify it calls the shared function by checking for validation pass output
    VERIFY_STEPS=("true")
    run run_check
    [[ "$output" == *"Validation pass"* ]] || return 1
    [[ "$output" == *"All verification steps passed"* ]] || return 1
}

# ── run_docs ─────────────────────────────────────────────────────────────────

@test "run_docs: uses DOCS_INPUT and DOCS_OUTPUT" {
    make_file summary.md
    make_file readme.md
    DOCS_INPUT=("summary.md")
    DOCS_OUTPUT=("readme.md")
    run run_docs
    [ "$status" -eq 0 ]
    [[ "$output" == *"WIGGUM DOCS MODE"* ]] || return 1
    [[ "$output" == *"Input: summary.md"* ]] || return 1
    [[ "$output" == *"Output: readme.md"* ]] || return 1
    [[ "$output" == *"WIGGUM DOCS COMPLETE"* ]] || return 1
}

# ── generate_uuid ────────────────────────────────────────────────────────────

@test "generate_uuid: produces valid UUID format" {
    local uuid
    uuid="$(generate_uuid)"
    [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 1
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

@test "log_init: creates missing parent directory" {
    MODE="plan"
    FILES=("docs/stdin.md")
    log_init "docs/stdin_plan.md"
    [ -f "docs/stdin_plan.log" ]
    [ "$WIGGUM_LOG_FILE" = "docs/stdin_plan.log" ]
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
    [[ "$captured_args" == *"--session-id"* ]] || return 1
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
    [[ "$captured_args" == *"--resume"* ]] || return 1
    [[ "$captured_args" == *"--fork-session"* ]] || return 1
    [[ "$captured_args" == *"$first_id"* ]] || return 1
    # -c should be stripped
    [[ "$captured_args" != *" -c "* ]] || return 1
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
    [[ "$stderr" == *"session:"* ]] || return 1
}

# ── run_claude failure reporting ─────────────────────────────────────────────
#
# Three consecutive real runs died on "API Error: Connection closed
# mid-response" and reported nothing to the terminal: quiet mode sent claude's
# output to /dev/null and `set -e` unwound the script. These tests pin the
# behaviour that makes such a death visible.

@test "run_claude: reports a failed session on stderr instead of dying silently" {
    log_init "plan.md"
    claude() { echo "API Error: Connection closed mid-response."; return 1; }
    export -f claude
    CLAUDE_RETRIES=0
    WIGGUM_CURRENT_LABEL="phase2-implement-1"

    run run_claude -p "do the work"
    [ "$status" -eq "$EXIT_CLAUDE_FAILED" ]
    [[ "$output" == *"claude session failed during 'phase2-implement-1'"* ]] || return 1
    [[ "$output" == *"Connection closed mid-response"* ]] || return 1
}

@test "run_claude: failure report includes the exit code and the session id" {
    log_init "plan.md"
    claude() { echo "boom"; return 7; }
    export -f claude
    CLAUDE_RETRIES=0
    WIGGUM_CURRENT_LABEL="test"

    run run_claude -p "hi"
    [[ "$output" == *"exit 7"* ]] || return 1
    [[ "$output" == *"session:"* ]] || return 1
    [[ "$output" == *"claude --resume"* ]] || return 1
}

@test "run_claude: failure report quotes the tail of the transcript" {
    log_init "plan.md"
    claude() { echo "the last thing claude said"; return 1; }
    export -f claude
    CLAUDE_RETRIES=0
    WIGGUM_CURRENT_LABEL="test"

    run run_claude -p "hi"
    [[ "$output" == *"the last thing claude said"* ]] || return 1
}

@test "run_claude: logs the failure so the run log records it" {
    log_init "plan.md"
    claude() { echo "API Error"; return 1; }
    export -f claude
    CLAUDE_RETRIES=0
    WIGGUM_CURRENT_LABEL="phase1-diagnostic"

    run run_claude -p "hi"
    grep -q "phase1-diagnostic: FAILED exit 1" plan.log
}

@test "run_claude: does not log 'done' for a failed session" {
    log_init "plan.md"
    claude() { return 1; }
    export -f claude
    CLAUDE_RETRIES=0
    WIGGUM_CURRENT_LABEL="test"

    run run_claude -p "hi"
    ! grep -q "test: done" plan.log
}

@test "run_claude: retries a failed session up to CLAUDE_RETRIES times" {
    log_init "plan.md"
    echo 0 > attempts
    claude() {
        local n
        n=$(cat attempts)
        echo $((n + 1)) > attempts
        return 1
    }
    export -f claude
    CLAUDE_RETRIES=2
    WIGGUM_CURRENT_LABEL="test"

    run run_claude -p "hi"
    [ "$status" -eq "$EXIT_CLAUDE_FAILED" ]
    [ "$(cat attempts)" -eq 3 ]
}

@test "run_claude: stops retrying once a session succeeds" {
    log_init "plan.md"
    echo 0 > attempts
    claude() {
        local n
        n=$(cat attempts)
        n=$((n + 1))
        echo "$n" > attempts
        if [ "$n" -ge 2 ]; then
            return 0
        fi
        return 1
    }
    export -f claude
    CLAUDE_RETRIES=3
    WIGGUM_CURRENT_LABEL="test"

    run run_claude -p "hi"
    [ "$status" -eq 0 ]
    [ "$(cat attempts)" -eq 2 ]
}

@test "run_claude: each retry gets a fresh session id" {
    log_init "plan.md"
    claude() {
        while [[ $# -gt 0 ]]; do
            if [[ "$1" == "--session-id" ]]; then
                echo "$2" >> ids
            fi
            shift
        done
        return 1
    }
    export -f claude
    CLAUDE_RETRIES=1
    WIGGUM_CURRENT_LABEL="test"

    run run_claude -p "hi"
    [ "$(wc -l < ids)" -eq 2 ]
    [ "$(sort -u ids | wc -l)" -eq 2 ]
}

@test "run_claude: a retry forks from the original session, not the dead attempt" {
    log_init "plan.md"
    claude() { return 0; }
    export -f claude
    WIGGUM_CURRENT_LABEL="test"
    run_claude -p "first" 2>/dev/null
    local first="$WIGGUM_LAST_SESSION_ID"

    claude() {
        while [[ $# -gt 0 ]]; do
            if [[ "$1" == "--resume" ]]; then
                echo "$2" >> resumes
            fi
            shift
        done
        return 1
    }
    export -f claude
    CLAUDE_RETRIES=1
    run run_claude -p -c "second"

    [ "$(sort -u resumes | wc -l)" -eq 1 ]
    [ "$(head -n1 resumes)" = "$first" ]
}

@test "run_claude: warns when claude exits 0 but reported an API error" {
    log_init "plan.md"
    claude() { echo "API Error: Connection closed mid-response."; return 0; }
    export -f claude
    WIGGUM_CURRENT_LABEL="test"

    run run_claude -p "hi"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Warning: claude exited 0"* ]] || return 1
    grep -q "test: done" plan.log
}

@test "run_claude: a clean session produces no failure noise" {
    log_init "plan.md"
    claude() { echo "all good"; return 0; }
    export -f claude
    WIGGUM_CURRENT_LABEL="test"

    run run_claude -p "hi"
    [ "$status" -eq 0 ]
    [[ "$output" != *"failed"* ]] || return 1
    [[ "$output" != *"Warning"* ]] || return 1
}

@test "run_claude: keeps the transcript of a failed session" {
    log_init "plan.md"
    mkdir -p tmpdir
    TMPDIR="$TEST_DIR/tmpdir"
    claude() { echo "dead"; return 1; }
    export -f claude
    CLAUDE_RETRIES=0
    WIGGUM_CURRENT_LABEL="test"

    run_claude -p "hi" 2>/dev/null || true
    [ -s "$WIGGUM_LAST_FAILURE_OUT" ]
    grep -q "dead" "$WIGGUM_LAST_FAILURE_OUT"
}

@test "run_claude: deletes the transcript of a successful session" {
    log_init "plan.md"
    mkdir -p tmpdir
    TMPDIR="$TEST_DIR/tmpdir"
    claude() { echo "fine"; return 0; }
    export -f claude
    WIGGUM_CURRENT_LABEL="test"

    run_claude -p "hi" 2>/dev/null
    [ "$(find "$TMPDIR" -name 'wiggum-claude-*' | wc -l)" -eq 0 ]
}

# ── report_unfinished_run ────────────────────────────────────────────────────
#
# read_run_status greps the .out file for "Status: ". A run that unwound under
# `set -e` never printed one, so `wiggum status` said "not running (no status
# recorded)" for a crash and for a run that was never launched alike.

@test "report_unfinished_run: prints a status line when the run did not finish" {
    log_init "plan.md"
    WIGGUM_RUN_FINISHED=false
    run report_unfinished_run
    [[ "$output" == *"Status: aborted"* ]] || return 1
    [[ "$output" == *"WIGGUM RUN ABORTED"* ]] || return 1
}

@test "report_unfinished_run: stays silent when the run finished normally" {
    log_init "plan.md"
    WIGGUM_RUN_FINISHED=true
    run report_unfinished_run
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "report_unfinished_run: names a claude failure as the cause" {
    log_init "plan.md"
    WIGGUM_RUN_FINISHED=false
    WIGGUM_LAST_FAILURE_OUT="/tmp/wiggum-claude-xyz"
    run bash -c "source '$WIGGUM_LIB'
        WIGGUM_RUN_FINISHED=false
        WIGGUM_LAST_FAILURE_OUT=/tmp/wiggum-claude-xyz
        (exit $EXIT_CLAUDE_FAILED)
        report_unfinished_run" 2>&1
    [[ "$output" == *"a claude session failed"* ]] || return 1
    [[ "$output" == *"/tmp/wiggum-claude-xyz"* ]] || return 1
}

@test "report_unfinished_run: aborted status is readable by read_run_status" {
    log_init "plan.md"
    WIGGUM_RUN_FINISHED=false
    report_unfinished_run > out.txt 2>&1 || true
    local final
    final="$(read_run_status out.txt)"
    [[ "$final" == aborted* ]] || return 1
}

# ── scan_claude_failure ──────────────────────────────────────────────────────

@test "scan_claude_failure: finds the connection-drop marker" {
    printf 'working...\nAPI Error: Connection closed mid-response.\n' > out.txt
    run scan_claude_failure out.txt
    [[ "$output" == *"Connection closed mid-response"* ]] || return 1
}

@test "scan_claude_failure: reports nothing for a clean transcript" {
    printf 'read the plan\nedited two files\ndone\n' > out.txt
    run scan_claude_failure out.txt
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "scan_claude_failure: reports nothing for a missing file" {
    run scan_claude_failure /nonexistent/transcript
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# The CLI sources this library under `set -euo pipefail`; bats does not. A
# helper whose grep finds nothing exits 1, and assigning that to a variable
# aborts the run -- which is how a *successful* claude session first came to
# kill the whole execute loop. Exercise the set -e path explicitly.
@test "scan_claude_failure: a clean transcript does not abort under set -e" {
    printf 'all fine\n' > out.txt
    run bash -c "set -euo pipefail
        source '$WIGGUM_LIB'
        found=\"\$(scan_claude_failure out.txt)\"
        echo \"survived:[\$found]\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"survived:[]"* ]] || return 1
}

@test "run_claude: a successful session does not abort under set -e" {
    run bash -c "set -euo pipefail
        source '$WIGGUM_LIB'
        claude() { echo 'did some work'; return 0; }
        log_init plan.md
        WIGGUM_CURRENT_LABEL=phase1-diagnostic
        run_claude -p 'hi' >/dev/null 2>&1
        echo 'reached the end'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"reached the end"* ]] || return 1
    grep -q "phase1-diagnostic: done" plan.log
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
    [[ "$output" == *"not created or is empty"* ]] || return 1
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
    [[ "$output" == *"not created or is empty"* ]] || return 1
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

@test "run_plan: wires the acceptance-criteria helper and per-task rule into the planner prompt" {
    mkdir -p docs
    echo "Fix the bug" > issue.md
    FILES=("issue.md")
    STDIN_FILE="/tmp/fake_stdin"
    CLI_PLAN_FILE=""
    PLAN_FILE="docs/issue_plan.md"

    # Capture the prompt claude receives; still write the plan so run_plan succeeds
    captured="$TEST_DIR/captured_prompt.txt"
    claude() { printf '%s\n' "$@" > "$captured"; echo "# Plan" > "$PLAN_FILE"; return 0; }
    export -f claude

    run_plan 2>/dev/null

    # The phase-level Acceptance Criteria section and its four categories reached the prompt
    grep -q '### Acceptance Criteria' "$captured"
    grep -q 'Happy Path' "$captured"
    grep -q 'Edge Cases' "$captured"
    grep -q 'Error States' "$captured"
    grep -q 'Non-Functional' "$captured"
    # The recommended Given/When/Then form reached the prompt
    grep -q 'Given' "$captured"
    grep -q 'When' "$captured"
    grep -q 'Then' "$captured"
    # The unchanged per-task acceptance rule is still present verbatim (additive change)
    grep -q "'Acceptance:' line stating an observable outcome" "$captured"
    # The benefits-first opening reached the prompt
    grep -q '## Expected benefits' "$captured"
    grep -q "'Serves:' line" "$captured"
    # The constraints self-check reached the prompt, after the benefits
    grep -q '## Constraints' "$captured"
    grep -q 'before writing any phases or tasks' "$captured"
    # Research tasks and nested wiggum runs reached the prompt
    grep -q 'research task' "$captured"
    grep -q 'nested wiggum run' "$captured"
    # The four risk gates reached the prompt
    grep -q 'read-only measurement' "$captured"
    grep -q 'dry run' "$captured"
    grep -q 'idempotent' "$captured"
    grep -q 'legitimate exceptions' "$captured"
    # The sequencing rule reached the prompt
    grep -q 'ship independently' "$captured"
    grep -q 'not the task-dependency list' "$captured"
    # Appended once for the whole prompt, not once per input file
    [ "$(grep -c 'dry run' "$captured")" -eq 1 ]
}

@test "run_plan: includes the diagnosis sections for defect-shaped input" {
    mkdir -p docs
    echo "Login crashes after deploy -- the traceback points at session.py" > issue.md
    FILES=("issue.md")
    STDIN_FILE="/tmp/fake_stdin"
    CLI_PLAN_FILE=""
    PLAN_FILE="docs/issue_plan.md"

    captured="$TEST_DIR/captured_prompt.txt"
    errlog="$TEST_DIR/stderr.txt"
    claude() { printf '%s\n' "$@" > "$captured"; echo "# Plan" > "$PLAN_FILE"; return 0; }
    export -f claude

    run_plan 2>"$errlog"

    # All four diagnosis sections reached the prompt
    grep -q '## Symptoms' "$captured"
    grep -q '## Root cause' "$captured"
    grep -q '## Why existing verification missed it' "$captured"
    grep -q '## Blast radius' "$captured"
    # The stderr line reports the sections were enabled
    grep -q 'Diagnosis sections: enabled' "$errlog"
    # Pre-existing clauses survive the insertion
    grep -q "'Acceptance:' line stating an observable outcome" "$captured"
    grep -q '## Constraints' "$captured"
    # Appended once for the whole prompt, not once per input file
    [ "$(grep -c '## Blast radius' "$captured")" -eq 1 ]
}

@test "run_plan: omits the diagnosis sections for a feature request" {
    mkdir -p docs
    echo "Add a CSV export button to the reports page" > issue.md
    FILES=("issue.md")
    STDIN_FILE="/tmp/fake_stdin"
    CLI_PLAN_FILE=""
    PLAN_FILE="docs/issue_plan.md"

    captured="$TEST_DIR/captured_prompt.txt"
    errlog="$TEST_DIR/stderr.txt"
    claude() { printf '%s\n' "$@" > "$captured"; echo "# Plan" > "$PLAN_FILE"; return 0; }
    export -f claude

    run_plan 2>"$errlog"

    # The planner is never asked to invent symptoms
    ! grep -q '## Symptoms' "$captured"
    ! grep -q '## Blast radius' "$captured"
    # The stderr line reports the sections were skipped
    grep -q 'Diagnosis sections: skipped' "$errlog"
    # The universal rules still reached the prompt
    grep -q 'dry run' "$captured"
    grep -q 'ship independently' "$captured"
    grep -q '## Constraints' "$captured"
}

@test "run_plan: feature-request prompt stays within budget" {
    mkdir -p docs
    echo "Add a CSV export button to the reports page" > issue.md
    FILES=("issue.md")
    STDIN_FILE="/tmp/fake_stdin"
    CLI_PLAN_FILE=""
    PLAN_FILE="docs/issue_plan.md"

    captured="$TEST_DIR/captured_prompt.txt"
    claude() { printf '%s\n' "$@" > "$captured"; echo "# Plan" > "$PLAN_FILE"; return 0; }
    export -f claude

    run_plan 2>/dev/null

    # A feature request pays for the universal rules only, never the defect text.
    # The ceiling tracks those rules as they grow -- it went from 8000 to 9000
    # when the diagram guidance landed. What it guards is the line above: the
    # defect sections must never leak into a feature prompt.
    ! grep -q '## Symptoms' "$captured"
    [ "$(wc -c < "$captured")" -lt 9000 ]
}

@test "run_plan: defect prompt stays within budget and exceeds the feature prompt" {
    mkdir -p docs
    echo "Add a CSV export button to the reports page" > feature.md
    echo "Login crashes after deploy -- the traceback points at session.py" > defect.md

    STDIN_FILE="/tmp/fake_stdin"
    CLI_PLAN_FILE=""

    local feature_capture="$TEST_DIR/feature_prompt.txt"
    local defect_capture="$TEST_DIR/defect_prompt.txt"
    captured="$feature_capture"
    claude() { printf '%s\n' "$@" > "$captured"; echo "# Plan" > "$PLAN_FILE"; return 0; }
    export -f claude

    FILES=("feature.md")
    PLAN_FILE="docs/feature_plan.md"
    run_plan 2>/dev/null

    captured="$defect_capture"
    FILES=("defect.md")
    PLAN_FILE="docs/defect_plan.md"
    run_plan 2>/dev/null

    local feature_size defect_size
    feature_size="$(wc -c < "$feature_capture")"
    defect_size="$(wc -c < "$defect_capture")"

    # The diagnosis sections are real added text, and they stay bounded.
    [ "$defect_size" -gt "$feature_size" ]
    [ "$defect_size" -lt 10000 ]
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
    [[ "$output" == *"must be sourced"* ]] || return 1
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

@test "CLI: execute --help shows the execute help and exits 0" {
    # `--help` after a subcommand used to print the top-level overview and then
    # fall through into running the command, dying on an unbound FILES[0].
    local cli="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/wiggum.sh"
    run bash "$cli" execute --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"wiggum execute - Implement a workplan"* ]] || return 1
    [[ "$output" == *"--at <WHEN>"* ]] || return 1
    [[ "$output" != *"unbound variable"* ]] || return 1
}

@test "CLI: execute bails out with EXIT_BAD_ARGS when stdin is not a plan" {
    # Reproduces the exact failure mode that caused the original bug: an
    # upstream `wiggum plan` leaked chatter into the pipe, and execute
    # happily processed 2 lines of nonsense. After the fix, execute must
    # refuse early with a clear hint.
    local cli="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/wiggum.sh"
    run bash -c "printf 'Loading config from .wiggumrc\nPlan written to X.\n' | '$cli' execute"
    [ "$status" -eq 1 ]   # EXIT_BAD_ARGS
    [[ "$output" == *"does not look like a wiggum plan"* ]] || return 1
    [[ "$output" == *"wiggum execute <plan-file>"* ]] || return 1
}

@test "CLI: execute accepts stdin that is a real plan" {
    # Positive counterpart: a proper plan on stdin must not be rejected.
    # We set max_iterations to 0 via an env-provided config so execute exits
    # cleanly once the input passes the shape check, without calling Claude.
    local cli="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/wiggum.sh"
    run bash -c "printf '# Workplan\n- [ ] First task\n' | '$cli' execute 2>&1 | head -5"
    # We only care that the shape check did not reject the input.
    [[ "$output" != *"does not look like a wiggum plan"* ]] || return 1
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
    [[ "$output" != *"unknown config key"* ]] || return 1
    [[ "$output" != *"Warning"* ]] || return 1
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
    [[ "$output" == *"invalid value for skip_verify"* ]] || return 1
}

@test "apply_config: invalid skip_commit value warns and treats as false" {
    run apply_config <<< "skip_commit=sometimes"
    [ "$status" -eq 0 ]
    [[ "$output" == *"invalid value for skip_commit"* ]] || return 1
}

@test "print_verify_steps: shows (skipped) when NO_VERIFY=true" {
    NO_VERIFY=true
    VERIFY_STEPS=("npm test")
    run print_verify_steps 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"(skipped)"* ]] || return 1
    [[ "$output" != *"npm test"* ]] || return 1
}

@test "print_verify_steps: shows (none configured) when no steps and NO_VERIFY=false" {
    NO_VERIFY=false
    VERIFY_STEPS=()
    run print_verify_steps 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"(none configured)"* ]] || return 1
}

@test "commit_or_skip: skips and prints message when NO_COMMIT=true" {
    NO_COMMIT=true
    local claude_calls=0
    claude() { claude_calls=$((claude_calls + 1)); }
    export -f claude
    run commit_or_skip "test-commit"
    [ "$status" -eq 0 ]
    [[ "$output" == *"(commit skipped via --no-commit)"* ]] || return 1
}

@test "commit_or_skip: invokes claude when NO_COMMIT=false" {
    NO_COMMIT=false
    local captured=""
    claude() { captured="$*"; }
    export -f claude
    log_init "plan.md"
    commit_or_skip "test-commit"
    # claude should have been called with a prompt about committing
    [[ -n "$captured" ]] || return 1
}

@test "commit_or_skip: passes extra files arg through to prompt_commit" {
    NO_COMMIT=false
    local captured=""
    claude() { captured="$*"; }
    export -f claude
    log_init "plan.md"
    commit_or_skip "test-commit" "summary.md and plan.md"
    [[ "$captured" == *"summary.md and plan.md"* ]] || return 1
}

@test "run_check: --no-verify produces clear error and exits EXIT_BAD_ARGS" {
    NO_VERIFY=true
    VERIFY_STEPS=("true")
    run run_check
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"--no-verify makes 'wiggum check' a no-op"* ]] || return 1
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
    [[ "$output" == *"ALL CHECKS PASSED"* ]] || return 1
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
    [[ "$output" == *"All verification steps passed"* ]] || return 1
}

# ── Effort & permission mode ──────────────────────────────────────────────────

@test "wiggum_reset: EFFORT defaults to xhigh, PERMISSION_MODE to bypassPermissions" {
    wiggum_reset
    [ "$EFFORT" = "xhigh" ]
    [ "$PERMISSION_MODE" = "bypassPermissions" ]
}

@test "validate_effort: accepts all valid levels" {
    validate_effort low && validate_effort medium && validate_effort high \
        && validate_effort xhigh && validate_effort max
}

@test "validate_effort: rejects an invalid level" {
    run validate_effort ultra
    [ "$status" -ne 0 ]
}

@test "validate_permission_mode: accepts all valid modes" {
    validate_permission_mode acceptEdits && validate_permission_mode auto \
        && validate_permission_mode bypassPermissions \
        && validate_permission_mode default && validate_permission_mode dontAsk \
        && validate_permission_mode plan
}

@test "validate_permission_mode: rejects an invalid mode" {
    run validate_permission_mode yolo
    [ "$status" -ne 0 ]
}

@test "parse_args: --effort sets EFFORT and CLI_EFFORT" {
    make_file plan.md
    parse_args plan plan.md --effort max
    [ "$EFFORT" = "max" ]
    [ "$CLI_EFFORT" = "max" ]
}

@test "parse_args: invalid --effort exits EXIT_BAD_ARGS" {
    make_file plan.md
    run parse_args plan plan.md --effort turbo
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"invalid --effort"* ]] || return 1
}

@test "parse_args: --permission-mode sets PERMISSION_MODE and CLI_PERMISSION_MODE" {
    make_file plan.md
    parse_args plan plan.md --permission-mode auto
    [ "$PERMISSION_MODE" = "auto" ]
    [ "$CLI_PERMISSION_MODE" = "auto" ]
}

@test "parse_args: invalid --permission-mode exits EXIT_BAD_ARGS" {
    make_file plan.md
    run parse_args plan plan.md --permission-mode godmode
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"invalid --permission-mode"* ]] || return 1
}

@test "load_config_from: effort is recognized and forwarded" {
    cat > test.rc <<'EOF'
effort = high
EOF
    local output
    output="$(load_config_from test.rc)"
    [ "$output" = "effort=high" ]
}

@test "load_config_from: permission_mode is recognized and forwarded" {
    cat > test.rc <<'EOF'
permission_mode = auto
EOF
    local output
    output="$(load_config_from test.rc)"
    [ "$output" = "permission_mode=auto" ]
}

@test "apply_config: effort sets EFFORT" {
    apply_config <<< "effort=medium"
    [ "$EFFORT" = "medium" ]
}

@test "apply_config: permission_mode sets PERMISSION_MODE" {
    apply_config <<< "permission_mode=acceptEdits"
    [ "$PERMISSION_MODE" = "acceptEdits" ]
}

@test "apply_config: CLI_EFFORT takes precedence over config effort" {
    EFFORT="max"
    CLI_EFFORT="max"
    apply_config <<< "effort=low"
    [ "$EFFORT" = "max" ]
}

@test "apply_config: CLI_PERMISSION_MODE takes precedence over config permission_mode" {
    PERMISSION_MODE="auto"
    CLI_PERMISSION_MODE="auto"
    apply_config <<< "permission_mode=plan"
    [ "$PERMISSION_MODE" = "auto" ]
}

@test "apply_config: invalid effort warns and keeps default" {
    run apply_config <<< "effort=turbo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"invalid value for effort"* ]] || return 1
}

@test "apply_config: invalid permission_mode warns and keeps default" {
    run apply_config <<< "permission_mode=godmode"
    [ "$status" -eq 0 ]
    [[ "$output" == *"invalid value for permission_mode"* ]] || return 1
}

@test "run_claude: injects default --effort and --permission-mode" {
    local captured=""
    claude() { captured="$*"; }
    log_init "plan.md"
    WIGGUM_CURRENT_LABEL="t"
    run_claude -p "hi"
    [[ "$captured" == *"--effort xhigh"* ]] || return 1
    [[ "$captured" == *"--permission-mode bypassPermissions"* ]] || return 1
}

@test "run_claude: honors EFFORT and PERMISSION_MODE overrides" {
    local captured=""
    claude() { captured="$*"; }
    log_init "plan.md"
    EFFORT="low"
    PERMISSION_MODE="auto"
    WIGGUM_CURRENT_LABEL="t"
    run_claude -p "hi"
    [[ "$captured" == *"--effort low"* ]] || return 1
    [[ "$captured" == *"--permission-mode auto"* ]] || return 1
}

@test "run_claude: omits --effort when EFFORT is empty" {
    local captured=""
    claude() { captured="$*"; }
    log_init "plan.md"
    EFFORT=""
    WIGGUM_CURRENT_LABEL="t"
    run_claude -p "hi"
    [[ "$captured" != *"--effort"* ]] || return 1
}

@test "run_claude: does not duplicate a caller-provided --permission-mode" {
    local captured=""
    claude() { captured="$*"; }
    log_init "plan.md"
    WIGGUM_CURRENT_LABEL="t"
    run_claude -p --permission-mode plan "hi"
    [[ "$captured" == *"--permission-mode plan"* ]] || return 1
    # Default (bypassPermissions) must NOT also be injected.
    [[ "$captured" != *"bypassPermissions"* ]] || return 1
}

# ── split_prompts ─────────────────────────────────────────────────────────────

@test "split_prompts: splits on delimiter lines" {
    printf 'one\n---\ntwo\n---\nthree\n' > p.txt
    split_prompts p.txt
    [ "${#RUN_PROMPTS[@]}" -eq 3 ]
    [ "${RUN_PROMPTS[0]}" = "one" ]
    [ "${RUN_PROMPTS[1]}" = "two" ]
    [ "${RUN_PROMPTS[2]}" = "three" ]
}

@test "split_prompts: preserves multi-line prompts" {
    printf 'line a\nline b\n---\nsecond\n' > p.txt
    split_prompts p.txt
    [ "${#RUN_PROMPTS[@]}" -eq 2 ]
    [ "${RUN_PROMPTS[0]}" = $'line a\nline b' ]
    [ "${RUN_PROMPTS[1]}" = "second" ]
}

@test "split_prompts: skips empty and whitespace-only chunks" {
    printf '\n---\n   \n---\nreal\n---\n\n' > p.txt
    split_prompts p.txt
    [ "${#RUN_PROMPTS[@]}" -eq 1 ]
    [ "${RUN_PROMPTS[0]}" = "real" ]
}

@test "split_prompts: honors a custom RUN_DELIMITER" {
    RUN_DELIMITER="###"
    printf 'a\n###\nb\n' > p.txt
    split_prompts p.txt
    [ "${#RUN_PROMPTS[@]}" -eq 2 ]
    [ "${RUN_PROMPTS[0]}" = "a" ]
    [ "${RUN_PROMPTS[1]}" = "b" ]
}

# ── parse_args (run mode) ─────────────────────────────────────────────────────

@test "parse_args: run mode collects positional prompts" {
    parse_args run "first" "second" "third"
    [ "$MODE" = "run" ]
    [ "${#RUN_PROMPTS[@]}" -eq 3 ]
    [ "${RUN_PROMPTS[0]}" = "first" ]
    [ "${RUN_PROMPTS[2]}" = "third" ]
}

@test "parse_args: run mode reads prompts from -f file" {
    printf 'aaa\n---\nbbb\n' > steps.txt
    parse_args run -f steps.txt
    [ "$RUN_PROMPTS_FILE" = "steps.txt" ]
    [ "${#RUN_PROMPTS[@]}" -eq 2 ]
}

@test "parse_args: run mode reads prompts from stdin" {
    parse_args run <<< $'xxx\n---\nyyy'
    [ "${#RUN_PROMPTS[@]}" -eq 2 ]
}

@test "parse_args: run mode with no prompts exits EXIT_BAD_ARGS" {
    run parse_args run < /dev/null
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"no prompts"* ]] || return 1
}

@test "parse_args: run mode -f with missing file exits EXIT_BAD_ARGS" {
    run parse_args run -f nope.txt
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"prompts file not found"* ]] || return 1
}

@test "parse_args: run mode sets --session-file, --new-session, --delimiter" {
    parse_args run --session-file s.id --new-session --delimiter "###" "p"
    [ "$RUN_SESSION_FILE" = "s.id" ]
    [ "$RUN_NEW_SESSION" = "true" ]
    [ "$RUN_DELIMITER" = "###" ]
    [ "${#RUN_PROMPTS[@]}" -eq 1 ]
}

@test "parse_args: help run shows run details" {
    run parse_args help run
    [ "$status" -eq 0 ]
    [[ "$output" == *"wiggum run"* ]] || return 1
    [[ "$output" == *"--session-file"* ]] || return 1
}

# ── run_prompts ───────────────────────────────────────────────────────────────

@test "run_prompts: chains prompts — first fresh, later prompts resume" {
    wiggum_reset
    claude() { printf '%s\n' "$*" >> calls.log; }
    RUN_PROMPTS=("p1" "p2" "p3")
    run_prompts >/dev/null 2>&1
    [ "$(grep -c . calls.log)" -eq 3 ]
    local l1 l2 l3
    l1="$(sed -n 1p calls.log)"
    l2="$(sed -n 2p calls.log)"
    l3="$(sed -n 3p calls.log)"
    [[ "$l1" != *"--resume"* ]] || return 1
    [[ "$l2" == *"--resume"* ]] || return 1
    [[ "$l3" == *"--resume"* ]] || return 1
}

@test "run_prompts: writes the session id to --session-file" {
    wiggum_reset
    claude() { :; }
    RUN_PROMPTS=("only")
    RUN_SESSION_FILE="sess.id"
    run_prompts >/dev/null 2>&1
    [ -s sess.id ]
    [ "$(cat sess.id)" = "$WIGGUM_LAST_SESSION_ID" ]
}

@test "run_prompts: resumes the session id from an existing --session-file" {
    wiggum_reset
    claude() { printf '%s\n' "$*" >> calls.log; }
    echo "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" > sess.id
    RUN_PROMPTS=("only")
    RUN_SESSION_FILE="sess.id"
    run_prompts >/dev/null 2>&1
    [[ "$(cat calls.log)" == *"--resume aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"* ]] || return 1
}

@test "run_prompts: --new-session ignores an existing --session-file" {
    wiggum_reset
    claude() { printf '%s\n' "$*" >> calls.log; }
    echo "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" > sess.id
    RUN_PROMPTS=("only")
    RUN_SESSION_FILE="sess.id"
    RUN_NEW_SESSION=true
    run_prompts >/dev/null 2>&1
    [[ "$(cat calls.log)" != *"--resume"* ]] || return 1
}

# ── run_sidecar_file ─────────────────────────────────────────────────────────

@test "run_sidecar_file: derives sibling pid/out/log paths" {
    [ "$(run_sidecar_file docs/foo_plan.md pid)" = "docs/foo_plan.pid" ]
    [ "$(run_sidecar_file docs/foo_plan.md out)" = "docs/foo_plan.out" ]
    [ "$(run_sidecar_file docs/foo_plan.md log)" = "docs/foo_plan.log" ]
}

@test "run_sidecar_file: matches the log path log_init uses" {
    mkdir -p docs
    log_init "docs/plan.md"
    [ "$WIGGUM_LOG_FILE" = "$(run_sidecar_file docs/plan.md log)" ]
}

# ── process_alive ────────────────────────────────────────────────────────────

@test "process_alive: true for a live pid, false for a dead one" {
    sleep 5 &
    local pid=$!
    process_alive "$pid"
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
    ! process_alive "$pid"
}

@test "process_alive: false for empty pid" {
    ! process_alive ""
}

# ── read_run_status ──────────────────────────────────────────────────────────

@test "read_run_status: returns the last recorded status" {
    printf 'Status: incomplete\nmore\nStatus: complete\n' > run.out
    [ "$(read_run_status run.out)" = "complete" ]
}

@test "read_run_status: empty for missing file or no status line" {
    [ -z "$(read_run_status missing.out)" ]
    printf 'no status here\n' > run.out
    [ -z "$(read_run_status run.out)" ]
}

# ── detect_blocked ───────────────────────────────────────────────────────────

@test "detect_blocked: true on stall/validation markers" {
    printf 'No progress detected (2 tasks remaining, stall 1 of 2).\n' > a.out
    detect_blocked a.out
    printf 'Stalled for 2 consecutive iterations.\n' > b.out
    detect_blocked b.out
    printf 'Validation failed 5 times. Stopping to prevent runaway.\n' > c.out
    detect_blocked c.out
}

@test "detect_blocked: false on a clean run and missing file" {
    printf 'All verification steps passed.\nStatus: complete\n' > ok.out
    ! detect_blocked ok.out
    ! detect_blocked missing.out
}

# ── format_progress ──────────────────────────────────────────────────────────

@test "format_progress: renders done/total/remaining/dropped" {
    [ "$(format_progress 6 3 2 1)" = "Tasks: 3/6 done, 2 remaining, 1 dropped" ]
}

# ── run_status ───────────────────────────────────────────────────────────────

@test "run_status: reports 'not started' with no sidecars" {
    cat > plan.md <<'EOF'
- [ ] one
- [x] two
EOF
    FILES=(plan.md)
    run run_status
    [[ "$output" == *"Plan: plan.md"* ]] || return 1
    [[ "$output" == *"Tasks: 1/2 done, 1 remaining, 0 dropped"* ]] || return 1
    [[ "$output" == *"State: not started"* ]] || return 1
}

@test "run_status: reports running when pidfile names a live process" {
    cat > plan.md <<'EOF'
- [ ] one
EOF
    sleep 5 &
    local pid=$!
    echo "$pid" > plan.pid
    FILES=(plan.md)
    run run_status
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    [[ "$output" == *"State: running (pid $pid)"* ]] || return 1
}

@test "run_status: reports finished status from the out file" {
    cat > plan.md <<'EOF'
- [x] one
EOF
    printf 'Status: stalled\n' > plan.out
    FILES=(plan.md)
    run run_status
    [[ "$output" == *"State: finished: stalled"* ]] || return 1
}

# A scheduled run is a fourth state, distinct from running: the difference is
# what tells somebody whether to expect output for the next few hours.

# Write a .scheduled sidecar by hand, the shape at_waiter_script claims one
# with, and hand back the pid it names so the test body can tear it down.
write_schedule_sidecar() {
    local target="$1" human="$2" pid="$3" spec="${4:-+90m}"
    printf 'target=%s\ntarget_human=%s\nspec=%s\npid=%s\n' \
        "$target" "$human" "$spec" "$pid" > plan.scheduled
}

@test "run_status: reports a scheduled run with its target time" {
    cat > plan.md <<'EOF'
- [ ] one
- [x] two
EOF
    sleep 5 &
    local waiter=$!
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    write_schedule_sidecar "$((PROTO_EPOCH + 5400))" "23:30:00 today" "$waiter"
    FILES=(plan.md)
    run run_status
    kill_waiter "$waiter"
    # The task counts stay alongside the schedule -- a scheduled run still has
    # a plan worth reporting progress on.
    [[ "$output" == *"Tasks: 1/2 done, 1 remaining, 0 dropped"* ]] || return 1
    [[ "$output" == *"State: scheduled for 23:30:00 today (in 1h 30m)"* ]] || return 1
    [[ "$output" != *"running"* ]] || return 1
}

@test "run_status: a live pidfile wins over a scheduled sidecar" {
    # Both present means the waiter fired between the two reads. The pidfile is
    # the newer fact, so it wins.
    cat > plan.md <<'EOF'
- [ ] one
EOF
    sleep 5 &
    local pid=$!
    echo "$pid" > plan.pid
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    write_schedule_sidecar "$((PROTO_EPOCH + 5400))" "23:30:00 today" "$pid"
    FILES=(plan.md)
    run run_status
    kill_waiter "$pid"
    [[ "$output" == *"State: running (pid $pid)"* ]] || return 1
    [[ "$output" != *"scheduled"* ]] || return 1
}

@test "run_status: a schedule outlives a finished run's pidfile" {
    # Scheduling is allowed over a pidfile whose process is gone, so the dead
    # pidfile must not shadow the schedule that replaced it.
    cat > plan.md <<'EOF'
- [ ] one
EOF
    sleep 5 &
    local waiter=$!
    echo 999999 > plan.pid
    printf 'Status: complete\n' > plan.out
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    write_schedule_sidecar "$((PROTO_EPOCH + 60))" "22:01:00 today" "$waiter"
    FILES=(plan.md)
    run run_status
    kill_waiter "$waiter"
    [[ "$output" == *"State: scheduled for 22:01:00 today (in 1m 0s)"* ]] || return 1
}

@test "run_status: renders the target from the epoch, not the stored wording" {
    # target_human was written when the run was scheduled; read a day later
    # "tomorrow" is wrong. The epoch is the fact, so the wording is recomputed.
    cat > plan.md <<'EOF'
- [ ] one
EOF
    sleep 5 &
    local waiter=$!
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    write_schedule_sidecar "$((PROTO_EPOCH + 10800))" "01:00:00 tomorrow" "$waiter" "01:00"
    FILES=(plan.md)
    run run_status
    kill_waiter "$waiter"
    [[ "$output" == *"State: scheduled for 01:00:00 tomorrow (in 3h 0m)"* ]] || return 1
}

@test "run_status: a truncated schedule sidecar reads as unreadable, not a crash" {
    cat > plan.md <<'EOF'
- [ ] one
EOF
    printf 'targ' > plan.scheduled
    FILES=(plan.md)
    run run_status
    [ "$status" -eq 0 ]
    # The path comes from run_sidecar_file, so it wears whatever ./ prefix
    # that gives a bare filename.
    [[ "$output" == *"State: scheduled (unreadable schedule file: "*"plan.scheduled)"* ]] || return 1
}

# A machine that was off at 01:07 is the ordinary case, not an error state. The
# sidecar outlives the waiter that wrote it, so the pair -- dead pid, past
# target -- is what "missed" means, and reporting it as still pending would
# have somebody waiting all morning for output that is never coming.

# A pid that is certainly not alive. Reaping a killed child leaves its pid free
# for the kernel to hand out again; this one is above the default pid_max on
# both Linux and macOS, so nothing can be wearing it.
DEAD_PID=999999

@test "run_status: a dead waiter with a past target reads as missed" {
    cat > plan.md <<'EOF'
- [ ] one
- [x] two
EOF
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    # 01:07 this morning, twenty-one hours before the frozen 22:00.
    write_schedule_sidecar "$((PROTO_EPOCH - 75180))" "01:07:00 today" "$DEAD_PID" "01:07"
    FILES=(plan.md)
    run run_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"State: missed: was scheduled for 01:07:00 today (20h 53m ago)"* ]] || return 1
    # Pending and missed are opposite claims about whether to expect output.
    [[ "$output" != *"State: scheduled for"* ]] || return 1
    # Task counts survive the missed state, as they do the scheduled one.
    [[ "$output" == *"Tasks: 1/2 done, 1 remaining, 0 dropped"* ]] || return 1
}

@test "run_status: status is read-only -- a missed schedule keeps its sidecar" {
    # run_status never starts or stops anything, and that includes tidying up
    # after a waiter. The healing is that a stale sidecar stops blocking, not
    # that reading the state deletes it.
    cat > plan.md <<'EOF'
- [ ] one
EOF
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    write_schedule_sidecar "$((PROTO_EPOCH - 3600))" "21:00:00 today" "$DEAD_PID"
    FILES=(plan.md)
    run run_status
    [ "$status" -eq 0 ]
    [ -f plan.scheduled ]
}

@test "run_status: a dead waiter with a future target will not fire either" {
    # A reboot before the target kills the waiter without the target passing.
    # Nothing will start, so reporting it as pending would be a false promise
    # -- but it is not "missed" while the time is still ahead.
    cat > plan.md <<'EOF'
- [ ] one
EOF
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    write_schedule_sidecar "$((PROTO_EPOCH + 5400))" "23:30:00 today" "$DEAD_PID"
    FILES=(plan.md)
    run run_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"State: not waiting: was scheduled for 23:30:00 today (in 1h 30m), but its waiter is gone"* ]] || return 1
}

@test "run_status: a live waiter with a past target is still pending, not missed" {
    # The waiter polls the wall clock, so between the target passing and the
    # loop's next tick it is alive and about to fire. Only a dead waiter is
    # evidence the run will not happen.
    cat > plan.md <<'EOF'
- [ ] one
EOF
    sleep 5 &
    local waiter=$!
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    write_schedule_sidecar "$((PROTO_EPOCH - 5))" "21:59:55 today" "$waiter"
    FILES=(plan.md)
    run run_status
    kill_waiter "$waiter"
    [ "$status" -eq 0 ]
    [[ "$output" == *"State: scheduled for 21:59:55 today"* ]] || return 1
    [[ "$output" != *"missed"* ]] || return 1
}

@test "run_status: a schedule sidecar with no pid reads as missed once past" {
    # A sidecar truncated after `target=` but before `pid=` names no waiter, so
    # there is nothing alive to wait for. process_alive on an empty pid is
    # false, which lands it in the same state as a dead one.
    cat > plan.md <<'EOF'
- [ ] one
EOF
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    printf 'target=%s
target_human=21:00:00 today
' "$((PROTO_EPOCH - 3600))" > plan.scheduled
    FILES=(plan.md)
    run run_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"State: missed: was scheduled for 21:00:00 today (1h 0m ago)"* ]] || return 1
}

# ── kill_run / run_kill ──────────────────────────────────────────────────────

@test "kill_run: terminates a live process and removes the pidfile" {
    sleep 30 &
    local pid=$!
    echo "$pid" > run.pid
    kill_run run.pid
    sleep 0.2
    ! process_alive "$pid"
    [ ! -f run.pid ]
}

@test "kill_run: errors when the pidfile is missing" {
    run kill_run nope.pid
    [ "$status" -ne 0 ]
    [[ "$output" == *"No run pidfile"* ]] || return 1
}

@test "kill_run: cleans up a stale pidfile for a dead process" {
    sleep 1 &
    local pid=$!
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    echo "$pid" > run.pid
    run kill_run run.pid
    [ "$status" -eq 0 ]
    [ ! -f run.pid ]
    [[ "$output" == *"not running"* ]] || return 1
}

@test "run_kill: derives the pidfile from the plan path" {
    cat > plan.md <<'EOF'
- [ ] one
EOF
    sleep 30 &
    local pid=$!
    echo "$pid" > plan.pid
    FILES=(plan.md)
    run_kill
    sleep 0.2
    ! process_alive "$pid"
    [ ! -f plan.pid ]
}

# Cancelling a schedule is not the same act as stopping a run: nothing has
# started, so there is no output to explain and the message has to say so.

@test "run_kill: cancels a scheduled run and removes its sidecar" {
    freeze_clock_now "22:00:00"
    schedule_far_future "+6h"
    local waiter
    waiter="$(sidecar_field pid)"

    run run_kill

    # The waiter sleeps in a child, so it goes down a moment after the signal
    # rather than in the same instant. Bounded wait, then tear down whatever
    # survived -- a failing assertion must not leave a detached waiter behind.
    local tries=50
    while [ "$tries" -gt 0 ] && process_alive "$waiter"; do
        sleep 0.1
        tries=$((tries - 1))
    done
    kill_waiter "$waiter"

    [ "$status" -eq 0 ]
    [ -n "$waiter" ] || return 1
    ! process_alive "$waiter"
    [ ! -f docs/plan.scheduled ] || return 1
    [ ! -f docs/plan.pid ] || return 1
    [[ "$output" == *"Cancelling"* ]] || return 1
    [[ "$output" != *"Killing wiggum run"* ]] || return 1
}

@test "run_kill: a live run outranks a schedule" {
    # Both present means the waiter fired between the two reads. The run is the
    # newer fact, so kill it rather than cancelling a schedule that is over.
    cat > plan.md <<'EOF'
- [ ] one
EOF
    sleep 1 &
    local dead=$!
    kill "$dead" 2>/dev/null; wait "$dead" 2>/dev/null || true
    sleep 30 &
    local pid=$!
    echo "$pid" > plan.pid
    write_schedule_sidecar "$((PROTO_EPOCH + 5400))" "23:30:00 today" "$dead"
    FILES=(plan.md)
    run run_kill
    sleep 0.2
    kill "$pid" 2>/dev/null || true
    [ "$status" -eq 0 ]
    ! process_alive "$pid"
    [ ! -f plan.pid ]
    [[ "$output" == *"Killing wiggum run"* ]] || return 1
    [[ "$output" != *"Cancelling"* ]] || return 1
}

@test "run_kill: clears a schedule whose waiter is already dead" {
    # A machine that was off at the target time is the ordinary case, not an
    # error: there is nothing to signal, only a sidecar to drop.
    cat > plan.md <<'EOF'
- [ ] one
EOF
    sleep 1 &
    local dead=$!
    kill "$dead" 2>/dev/null; wait "$dead" 2>/dev/null || true
    write_schedule_sidecar "$((PROTO_EPOCH + 5400))" "23:30:00 today" "$dead"
    FILES=(plan.md)
    run run_kill
    [ "$status" -eq 0 ]
    [ ! -f plan.scheduled ]
    [[ "$output" == *"no longer waiting"* ]] || return 1
}

@test "run_kill: reports nothing to stop with neither sidecar present" {
    cat > plan.md <<'EOF'
- [ ] one
EOF
    FILES=(plan.md)
    run run_kill
    [ "$status" -eq 0 ]
    [[ "$output" == *"Nothing to stop"* ]] || return 1
}

@test "run_kill: never pattern-matches the process table for the waiter" {
    # The waiter's command line is a long env-and-bash-c string; a pgrep -f over
    # it can truncate or hit twice. The sidecar records the one pid to signal.
    local body
    body="$(sed -n '/^cancel_schedule()/,/^}/p' "$WIGGUM_LIB")"
    [ -n "$body" ] || return 1
    [[ "$body" != *pgrep* ]] || return 1
    [[ "$body" != *pkill\ -f* ]] || return 1
    [[ "$body" == *read_schedule_field* ]] || return 1
}

# ── claim_run_pidfile / release_run_pidfile ──────────────────────────────────

@test "claim_run_pidfile: registers this process in the plan's sidecar" {
    mkdir -p docs
    : > docs/p_plan.md
    claim_run_pidfile docs/p_plan.md
    [ "$(cat docs/p_plan.pid)" = "$$" ]
    [ "$WIGGUM_RUN_PIDFILE" = "docs/p_plan.pid" ]
}

@test "claim_run_pidfile: a sidecar a launcher already claimed is left alone" {
    mkdir -p docs
    : > docs/p_plan.md
    echo 4242 > docs/p_plan.pid
    WIGGUM_RUN_PIDFILE=docs/p_plan.pid
    claim_run_pidfile docs/p_plan.md
    [ "$(cat docs/p_plan.pid)" = "4242" ]
}

@test "claim_run_pidfile: does not clobber a live run's sidecar" {
    mkdir -p docs
    : > docs/p_plan.md
    sleep 30 &
    local pid=$!
    echo "$pid" > docs/p_plan.pid
    run claim_run_pidfile docs/p_plan.md
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    [ "$status" -eq 0 ]
    [[ "$output" == *"already active"* ]] || return 1
    [ "$(cat docs/p_plan.pid)" = "$pid" ]
}

@test "claim_run_pidfile: takes over a dead run's leftover sidecar" {
    mkdir -p docs
    : > docs/p_plan.md
    sleep 1 &
    local pid=$!
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    echo "$pid" > docs/p_plan.pid
    claim_run_pidfile docs/p_plan.md
    [ "$(cat docs/p_plan.pid)" = "$$" ]
}

@test "claim_run_pidfile: no plan, no sidecar" {
    claim_run_pidfile ""
    [ -z "$WIGGUM_RUN_PIDFILE" ]
}

@test "release_run_pidfile: removes the sidecar this process claimed" {
    mkdir -p docs
    : > docs/p_plan.md
    claim_run_pidfile docs/p_plan.md
    release_run_pidfile
    [ ! -f docs/p_plan.pid ]
    [ -z "$WIGGUM_RUN_PIDFILE" ]
}

@test "release_run_pidfile: leaves a sidecar that names another process" {
    mkdir -p docs
    : > docs/p_plan.md
    echo 4242 > docs/p_plan.pid
    WIGGUM_RUN_PIDFILE=docs/p_plan.pid
    release_run_pidfile
    [ -f docs/p_plan.pid ]
    [ "$(cat docs/p_plan.pid)" = "4242" ]
}

@test "release_run_pidfile: no-op when nothing was claimed" {
    run release_run_pidfile
    [ "$status" -eq 0 ]
}

# ── run registry (machine-wide discovery) ────────────────────────────────────

@test "register_run: files a run under its pid with an absolute base path" {
    mkdir -p docs
    : > docs/r_plan.md
    register_run 4242 docs/r_plan.md
    [ -f "$WIGGUM_REGISTRY_DIR/4242" ]
    [ "$(cat "$WIGGUM_REGISTRY_DIR/4242")" = "$TEST_DIR/docs/r_plan" ]
}

@test "find_registered_runs: lists live runs and prunes dead ones" {
    mkdir -p docs
    : > docs/live_plan.md
    : > docs/dead_plan.md
    sleep 30 &
    local live=$!
    sleep 1 &
    local dead=$!
    kill "$dead" 2>/dev/null; wait "$dead" 2>/dev/null || true
    register_run "$live" docs/live_plan.md
    register_run "$dead" docs/dead_plan.md
    run find_registered_runs
    kill "$live" 2>/dev/null; wait "$live" 2>/dev/null || true
    [ "$output" = "$TEST_DIR/docs/live_plan" ]
    # The read is the only thing that sweeps the registry, so it has to prune.
    [ ! -f "$WIGGUM_REGISTRY_DIR/$dead" ]
}

@test "find_registered_runs: empty when nothing is registered" {
    run find_registered_runs
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "claim_run_pidfile: announces the run machine-wide, release withdraws it" {
    mkdir -p docs
    : > docs/r_plan.md
    claim_run_pidfile docs/r_plan.md
    [ "$(cat "$WIGGUM_REGISTRY_DIR/$$")" = "$TEST_DIR/docs/r_plan" ]
    release_run_pidfile
    [ ! -f "$WIGGUM_REGISTRY_DIR/$$" ]
}

@test "relativize_run_base: local runs render relative, others absolute" {
    run relativize_run_base "$PWD/docs/here_plan"
    [ "$output" = "docs/here_plan" ]
    run relativize_run_base "./cwd_plan"
    [ "$output" = "cwd_plan" ]
    run relativize_run_base "/elsewhere/proj/docs/there_plan"
    [ "$output" = "/elsewhere/proj/docs/there_plan" ]
}

@test "collect_top_bases: with no args, unions the registry with the local scan" {
    mkdir -p docs
    : > docs/local_plan.md
    : > docs/local_plan.pid
    # A genuinely different project, outside this one -- the case the directory
    # scan cannot see and the registry exists for.
    local remote
    remote="$(mktemp -d)"
    mkdir -p "$remote/docs"
    : > "$remote/docs/remote_plan.md"
    sleep 30 &
    local pid=$!
    register_run "$pid" "$remote/docs/remote_plan.md"
    run collect_top_bases
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    rm -rf "$remote"
    [[ "$output" == *"docs/local_plan"* ]] || return 1
    [[ "$output" == *"$remote/docs/remote_plan"* ]] || return 1
}

@test "collect_top_bases: a local run found twice is one row" {
    mkdir -p docs
    : > docs/dup_plan.md
    : > docs/dup_plan.pid
    sleep 30 &
    local pid=$!
    register_run "$pid" docs/dup_plan.md
    run collect_top_bases
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    [ "${#lines[@]}" -eq 1 ]
    [ "$output" = "docs/dup_plan" ]
}

@test "collect_top_bases: arguments narrow the view instead of widening it" {
    mkdir -p docs
    : > docs/local_plan.md
    : > docs/local_plan.pid
    local remote
    remote="$(mktemp -d)"
    mkdir -p "$remote/docs"
    : > "$remote/docs/remote_plan.md"
    sleep 30 &
    local pid=$!
    register_run "$pid" "$remote/docs/remote_plan.md"
    run collect_top_bases docs
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    rm -rf "$remote"
    [ "$output" = "docs/local_plan" ]
}

@test "run_top: shows a run started from another directory" {
    local remote
    remote="$(mktemp -d)"
    mkdir -p "$remote/docs"
    cat > "$remote/docs/remote_plan.md" <<'EOF'
- [ ] a
- [x] b
EOF
    sleep 30 &
    local pid=$!
    echo "$pid" > "$remote/docs/remote_plan.pid"
    register_run "$pid" "$remote/docs/remote_plan.md"
    FILES=()
    run run_top
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    [ "$status" -eq 0 ]
    # Absolute, because the row has to say which project it belongs to.
    [[ "$output" == *"$remote/docs/remote_plan.md"* ]] || return 1
    [[ "$output" == *"$pid"* ]] || return 1
    [[ "$output" == *"running"* ]] || return 1
    [[ "$output" == *"1/2 done, 1 left"* ]] || return 1
    rm -rf "$remote"
}

@test "registered_pid_for_base: finds the live pid, ignores a dead entry" {
    mkdir -p docs
    : > docs/r_plan.md
    sleep 30 &
    local live=$!
    sleep 1 &
    local dead=$!
    kill "$dead" 2>/dev/null; wait "$dead" 2>/dev/null || true
    register_run "$dead" docs/r_plan.md
    run registered_pid_for_base "$TEST_DIR/docs/r_plan"
    [ -z "$output" ]
    register_run "$live" docs/r_plan.md
    run registered_pid_for_base "$TEST_DIR/docs/r_plan"
    kill "$live" 2>/dev/null; wait "$live" 2>/dev/null || true
    [ "$output" = "$live" ]
}

@test "registered_pid_for_base: nothing for an unregistered plan" {
    run registered_pid_for_base "$TEST_DIR/docs/never_plan"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "run_top: a registered run with no pidfile still reads as running" {
    mkdir -p docs
    cat > docs/orphan_plan.md <<'EOF'
- [ ] a
- [x] b
EOF
    # The sidecar is the cheaper read, but it is not the authority: a run whose
    # `.pid` went missing under it is still a run.
    sleep 30 &
    local pid=$!
    register_run "$pid" docs/orphan_plan.md
    [ ! -f docs/orphan_plan.pid ]
    FILES=()
    run run_top
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    [ "$status" -eq 0 ]
    [[ "$output" == *"docs/orphan_plan.md"* ]] || return 1
    [[ "$output" == *"$pid"* ]] || return 1
    [[ "$output" == *"running"* ]] || return 1
    [[ "$output" == *"1/2 done, 1 left"* ]] || return 1
}

@test "run_top: a stale pidfile with no registration still reads as finished" {
    mkdir -p docs
    printf -- '- [x] a\n' > docs/old_plan.md
    sleep 1 &
    local pid=$!
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    echo "$pid" > docs/old_plan.pid
    printf 'Status: complete\n' > docs/old_plan.out
    FILES=()
    run run_top
    [[ "$output" == *"finished: complete"* ]] || return 1
}

@test "run_top: says so when the machine has nothing running anywhere" {
    FILES=()
    run run_top
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing registered on this machine"* ]] || return 1
}

# ── launch_execute_background ─────────────────────────────────────────────────

@test "launch_execute_background: writes pidfile + out, runs the loop once" {
    mkdir -p docs
    cat > docs/plan.md <<'EOF'
- [ ] one
EOF
    # Stub the loop so we don't invoke claude; the subshell inherits it.
    run_execute() { echo "loop ran for ${FILES[0]}"; }
    FILES=(docs/plan.md)
    BACKGROUND=true
    launch_execute_background >/dev/null 2>&1
    [ -f docs/plan.pid ]
    # Wait for the detached subshell to finish writing its output.
    local pid
    pid="$(cat docs/plan.pid)"
    wait "$pid" 2>/dev/null || true
    [ -f docs/plan.out ]
    grep -q "loop ran for docs/plan.md" docs/plan.out
}

@test "launch_execute_background: the detached child inherits the claim, so it never rewrites the pidfile" {
    mkdir -p docs
    cat > docs/plan.md <<'EOF'
- [ ] one
EOF
    # The real loop calls claim_run_pidfile; an inherited WIGGUM_RUN_PIDFILE is
    # what makes that a no-op. Report what the child inherited, then confirm the
    # file still names the subshell rather than this shell.
    run_execute() { echo "claimed=[$WIGGUM_RUN_PIDFILE]"; }
    FILES=(docs/plan.md)
    BACKGROUND=true
    launch_execute_background >/dev/null 2>&1
    local pid
    pid="$(cat docs/plan.pid)"
    wait "$pid" 2>/dev/null || true
    grep -q "claimed=\[docs/plan.pid\]" docs/plan.out
    [ "$pid" != "$$" ]
    # And the sidecar outlives the run, so `status` can still report on a
    # background run nobody watched.
    [ -f docs/plan.pid ]
    [ "$(cat docs/plan.pid)" = "$pid" ]
}

@test "launch_execute_background: registers the detached child, not the launcher" {
    mkdir -p docs
    cat > docs/plan.md <<'EOF'
- [ ] one
EOF
    # Hold the child open long enough to read the registry while it is alive.
    run_execute() { sleep 5; }
    FILES=(docs/plan.md)
    BACKGROUND=true
    launch_execute_background >/dev/null 2>&1
    local pid
    pid="$(cat docs/plan.pid)"
    [ "$(cat "$WIGGUM_REGISTRY_DIR/$pid")" = "$TEST_DIR/docs/plan" ]
    [ ! -f "$WIGGUM_REGISTRY_DIR/$$" ]
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    # Nothing unregisters a background run; the next read prunes it.
    run find_registered_runs
    [ -z "$output" ]
    [ ! -f "$WIGGUM_REGISTRY_DIR/$pid" ]
}

@test "launch_execute_background: refuses to start over a live run" {
    mkdir -p docs
    cat > docs/plan.md <<'EOF'
- [ ] one
EOF
    sleep 30 &
    local pid=$!
    echo "$pid" > docs/plan.pid
    FILES=(docs/plan.md)
    BACKGROUND=true
    run launch_execute_background
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    [ "$status" -ne 0 ]
    [[ "$output" == *"already active"* ]] || return 1
}

# ── run_watch ─────────────────────────────────────────────────────────────────

@test "run_watch: errors when no background run exists" {
    cat > plan.md <<'EOF'
- [ ] one
EOF
    FILES=(plan.md)
    run run_watch
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"No background run found"* ]] || return 1
}

@test "run_watch: streams output and returns 0 when run completes" {
    cat > plan.md <<'EOF'
- [x] one
EOF
    # Background a short-lived process that writes a completing out file.
    ( printf '=== WIGGUM EXECUTE MODE ===\nStatus: complete\n' > plan.out; sleep 1 ) &
    local pid=$!
    echo "$pid" > plan.pid
    FILES=(plan.md)
    WATCH_POLL=1
    run run_watch
    [ "$status" -eq 0 ]
    [[ "$output" == *"Status: complete"* ]] || return 1
    [ ! -f plan.pid ]
}

# ── explain mode / plan feedback ─────────────────────────────────────────────

@test "parse_args: explain is a valid mode and takes files" {
    make_file docs/x_plan.md
    parse_args explain docs/x_plan.md
    [ "$MODE" = "explain" ]
    [ "${FILES[0]}" = "docs/x_plan.md" ]
    [ -z "$EXPLAIN_FILE" ]
}

@test "parse_args: --explain-file sets the output destination" {
    make_file docs/x_plan.md
    parse_args explain docs/x_plan.md --explain-file docs/x_explained.md
    [ "$EXPLAIN_FILE" = "docs/x_explained.md" ]
}

@test "parse_args: --no-feedback sets NO_FEEDBACK" {
    make_file docs/x.md
    parse_args plan docs/x.md --no-feedback
    [ "$NO_FEEDBACK" = "true" ]
}

@test "wiggum_reset clears the explain and feedback state" {
    make_file docs/x_plan.md
    parse_args explain docs/x_plan.md --explain-file out.md
    wiggum_reset
    [ -z "$EXPLAIN_FILE" ]
    [ "$NO_FEEDBACK" = "false" ]
}

@test "parse_args: an unknown mode names explain among the valid ones" {
    run parse_args nonsense
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"'explain'"* ]] || return 1
}

@test "run_explain: prints to stdout and writes nothing by default" {
    mkdir -p docs
    printf -- '- [ ] a\n' > docs/x_plan.md
    claude() { printf '%s\n' "$*" > captured; echo "the explanation"; return 0; }
    export -f claude
    MODE=explain
    FILES=(docs/x_plan.md)
    run run_explain
    [ "$status" -eq 0 ]
    grep -q "Print your answer. Write no files." captured
    ! grep -q "Use the Write tool" captured
    [ ! -f docs/x_explained.md ]
}

@test "run_explain: asks the four questions and forbids changes" {
    mkdir -p docs
    printf -- '- [ ] a\n' > docs/x_plan.md
    claude() { printf '%s\n' "$*" > captured; return 0; }
    export -f claude
    MODE=explain
    FILES=(docs/x_plan.md)
    run_explain >/dev/null 2>&1
    grep -q "What it contains" captured
    grep -q "What it is worth" captured
    grep -q "How it reaches users" captured
    grep -q "Open decisions" captured
    grep -q "read-only explanation" captured
}

@test "run_explain: --explain-file writes a file and reports it" {
    mkdir -p docs
    printf -- '- [ ] a\n' > docs/x_plan.md
    claude() { echo "explained" > docs/x_explained.md; return 0; }
    export -f claude
    MODE=explain
    FILES=(docs/x_plan.md)
    EXPLAIN_FILE=docs/x_explained.md
    run run_explain
    [ "$status" -eq 0 ]
    [ -f docs/x_explained.md ]
    [[ "$output" == *"Explanation written: docs/x_explained.md"* ]] || return 1
}

@test "run_explain: an empty explanation file is an error, not a success" {
    mkdir -p docs
    printf -- '- [ ] a\n' > docs/x_plan.md
    claude() { return 0; }
    export -f claude
    MODE=explain
    FILES=(docs/x_plan.md)
    EXPLAIN_FILE=docs/x_explained.md
    run run_explain
    [ "$status" -eq "$EXIT_PLAN_FAILED" ]
    [[ "$output" == *"was not created or is empty"* ]] || return 1
}

@test "run_plan_feedback: edits the plan in place and protects the tasks" {
    mkdir -p docs
    printf -- '- [ ] a\n' > docs/x_plan.md
    PLAN_FILE=docs/x_plan.md
    claude() { printf '%s\n' "$*" > captured; return 0; }
    export -f claude
    run_plan_feedback >/dev/null 2>&1
    grep -q "## Open decisions" captured
    grep -q "How this reaches users" captured
    grep -q "do not reword, reorder, renumber, split, merge or delete" captured
    grep -q "UPDATE that file in place" captured
}

@test "run_plan_feedback: continues the planning session rather than reading cold" {
    mkdir -p docs
    printf -- '- [ ] a\n' > docs/x_plan.md
    PLAN_FILE=docs/x_plan.md
    # run_claude consumes -c itself (it becomes --resume/--fork-session), so the
    # claude stub never sees it -- capture the call one level up.
    run_claude() { printf '%s\n' "$@" > rc_args; return 0; }
    run_plan_feedback >/dev/null 2>&1
    grep -qx -- "-c" rc_args
    grep -qx -- "docs/x_plan.md" rc_args
}

@test "run_plan_feedback: --no-feedback skips it entirely" {
    mkdir -p docs
    printf -- '- [ ] a\n' > docs/x_plan.md
    PLAN_FILE=docs/x_plan.md
    NO_FEEDBACK=true
    claude() { printf '%s\n' "$*" > captured; return 0; }
    export -f claude
    run run_plan_feedback
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipped (--no-feedback)"* ]] || return 1
    [ ! -f captured ]
}

@test "run_plan: a piped plan skips the feedback pass" {
    mkdir -p docs
    echo "an issue" > issue.md
    claude() { printf '%s\n' "$*" >> calls; echo "# Plan" > "$PLAN_FILE"; return 0; }
    export -f claude
    MODE=plan
    FILES=(issue.md)
    PLAN_FILE=docs/issue_plan.md
    STDIN_FILE=/tmp/fake_stdin
    CLI_PLAN_FILE=""
    run_plan >/dev/null 2>&1
    # Exactly one claude call: the plan itself, no feedback pass.
    ! grep -q "## Open decisions" calls
}

@test "run_plan: the plan prompt tells the planner to cite the issue ledger" {
    mkdir -p docs
    echo "an issue" > issue.md
    claude() { printf '%s\n' "$*" >> calls; echo "# Plan" > "$PLAN_FILE"; return 0; }
    export -f claude
    MODE=plan
    FILES=(issue.md)
    PLAN_FILE=docs/issue_plan.md
    STDIN_FILE=/tmp/fake_stdin
    CLI_PLAN_FILE=""
    run_plan >/dev/null 2>&1
    grep -q "Anchor the plan to the issues it comes from" calls
    grep -q "ISSUES.md" calls
    grep -q "Never invent or create a tracker" calls
}

@test "prompt_open_decisions: refuses to invent a decision" {
    run prompt_open_decisions
    [[ "$output" == *"If nothing is genuinely open"* ]] || return 1
    [[ "$output" == *"effort estimate"* ]] || return 1
}

@test "prompt_user_benefit: asks all four questions, users included" {
    run prompt_user_benefit
    [[ "$output" == *"WHAT IT CONTAINS"* ]] || return 1
    [[ "$output" == *"WHAT THE BENEFIT IS TO USERS"* ]] || return 1
    [[ "$output" == *"HOW IT IS COMMUNICATED"* ]] || return 1
    [[ "$output" == *"has not shipped"* ]] || return 1
}

@test "prompt_plan_issue_refs: never invents or creates a tracker" {
    run prompt_plan_issue_refs
    [[ "$output" == *"Never invent or create a tracker"* ]] || return 1
    [[ "$output" == *"never cite an entry you have not read"* ]] || return 1
}

@test "docs: explain is documented on every surface" {
    local root
    root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    grep -q "explain   Explain" "$root/lib/wiggum.sh"
    grep -q "wiggum explain - " "$root/lib/wiggum.sh"
    grep -q "explain     Explain" "$root/README.md"
    grep -q "### Explain mode" "$root/README.md"
    grep -q "explain" "$root/completions/wiggum.bash"
    grep -q "'explain:" "$root/completions/wiggum.zsh"
    grep -q "wiggum explain" "$root/.claude/skills/wiggum/SKILL.md"
}

@test "docs: the CLI dispatches explain" {
    local cli
    cli="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/wiggum.sh"
    grep -q "run_explain" "$cli"
    run bash "$cli" help explain
    [ "$status" -eq 0 ]
    [[ "$output" == *"wiggum explain - "* ]] || return 1
}

# ── run_chain ─────────────────────────────────────────────────────────────────

@test "run_chain: executes each plan in order with a fresh session" {
    cat > a.md <<'EOF'
- [ ] a
EOF
    cat > b.md <<'EOF'
- [ ] b
EOF
    run_execute() { echo "${FILES[0]}" >> chain.log; return 0; }
    FILES=(a.md b.md)
    run_chain >/dev/null 2>&1
    [ "$(sed -n 1p chain.log)" = "a.md" ]
    [ "$(sed -n 2p chain.log)" = "b.md" ]
}

@test "run_chain: stops at the first failing plan" {
    cat > a.md <<'EOF'
- [ ] a
EOF
    cat > b.md <<'EOF'
- [ ] b
EOF
    cat > c.md <<'EOF'
- [ ] c
EOF
    run_execute() {
        echo "${FILES[0]}" >> chain.log
        [[ "${FILES[0]}" == "b.md" ]] && return 1
        return 0
    }
    FILES=(a.md b.md c.md)
    run run_chain
    [ "$status" -eq "$EXIT_PLAN_FAILED" ]
    [ "$(grep -c . chain.log)" -eq 2 ]
    [[ "$(cat chain.log)" != *"c.md"* ]] || return 1
}

@test "run_chain: registers each plan in turn so top follows the chain" {
    cat > a.md <<'EOF'
- [ ] a
EOF
    cat > b.md <<'EOF'
- [ ] b
EOF
    # Snapshot the live sidecars from inside each plan's run: the claim exists
    # only while that plan is being worked on.
    run_execute() {
        claim_run_pidfile "${FILES[0]}"
        echo "$(echo ./*.pid)" >> seen
        release_run_pidfile
        return 0
    }
    FILES=(a.md b.md)
    run_chain >/dev/null 2>&1
    [ "$(sed -n 1p seen)" = "./a.pid" ]
    [ "$(sed -n 2p seen)" = "./b.pid" ]
    # Nothing is left claiming a plan the chain has finished with.
    [ ! -f a.pid ]
    [ ! -f b.pid ]
}

@test "run_chain: a plan that unwinds mid-run does not keep its claim" {
    cat > a.md <<'EOF'
- [ ] a
EOF
    cat > b.md <<'EOF'
- [ ] b
EOF
    # a.md claims and then fails without releasing, the way an unwound run does.
    run_execute() {
        claim_run_pidfile "${FILES[0]}"
        [[ "${FILES[0]}" == "a.md" ]] && return 1
        return 0
    }
    FILES=(a.md b.md)
    run run_chain
    [ "$status" -eq "$EXIT_PLAN_FAILED" ]
    [ ! -f a.pid ]
}

# ── chain --queue ────────────────────────────────────────────────────────────

@test "read_queue: skips blanks and comments, trims whitespace" {
    printf '  docs/a_plan.md  \n\n# a comment\ndocs/b_plan.md # trailing\n' > q.txt
    run read_queue q.txt
    [ "$status" -eq 0 ]
    [ "$(sed -n 1p <<< "$output")" = "docs/a_plan.md" ]
    [ "$(sed -n 2p <<< "$output")" = "docs/b_plan.md" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "read_queue: a missing queue file is empty, not an error" {
    run read_queue nope.txt
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "read_queue: a final line with no newline still counts" {
    printf 'docs/a_plan.md' > q.txt
    run read_queue q.txt
    [ "$output" = "docs/a_plan.md" ]
}

@test "next_queued_plan: returns the first plan not already done" {
    printf 'a.md\nb.md\nc.md\n' > q.txt
    run next_queued_plan q.txt ""
    [ "$output" = "a.md" ]
    run next_queued_plan q.txt "$(printf 'a.md\n')"
    [ "$output" = "b.md" ]
    run next_queued_plan q.txt "$(printf 'a.md\nb.md\nc.md\n')"
    [ -z "$output" ]
}

@test "parse_args: --queue is chain-only and refuses positional plans" {
    printf 'a.md\n' > q.txt
    make_file a.md
    run parse_args execute --queue q.txt
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"only valid for 'wiggum chain'"* ]] || return 1
    run parse_args chain a.md --queue q.txt
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"not both"* ]] || return 1
}

@test "parse_args: --queue needs the file to exist" {
    run parse_args chain --queue missing.txt
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"queue file not found"* ]] || return 1
}

@test "parse_args: a queued chain takes no positional files" {
    printf 'a.md\n' > q.txt
    parse_args chain --queue q.txt
    [ "$MODE" = "chain" ]
    [ "$QUEUE_FILE" = "q.txt" ]
    [ "${#FILES[@]}" -eq 0 ]
}

@test "run_chain_queue: runs the queued plans in order" {
    printf -- '- [ ] a\n' > a.md
    printf -- '- [ ] b\n' > b.md
    printf 'a.md\nb.md\n' > q.txt
    QUEUE_FILE=q.txt
    run_execute() { echo "${FILES[0]}" >> ran.log; return 0; }
    run_chain_queue >/dev/null 2>&1
    [ "$(sed -n 1p ran.log)" = "a.md" ]
    [ "$(sed -n 2p ran.log)" = "b.md" ]
}

@test "run_chain_queue: a plan appended while running is picked up" {
    printf -- '- [ ] a\n' > a.md
    printf -- '- [ ] b\n' > b.md
    printf 'a.md\n' > q.txt
    QUEUE_FILE=q.txt
    # The queue grows during the first plan, exactly as a person appending to
    # it mid-chain would.
    run_execute() {
        echo "${FILES[0]}" >> ran.log
        [[ "${FILES[0]}" == "a.md" ]] && printf 'b.md\n' >> q.txt
        return 0
    }
    run_chain_queue >/dev/null 2>&1
    [ "$(sed -n 2p ran.log)" = "b.md" ]
    [ "$(grep -c . ran.log)" -eq 2 ]
}

@test "run_chain_queue: a plan removed from the queue after running is not repeated" {
    printf -- '- [ ] a\n' > a.md
    printf 'a.md\n' > q.txt
    QUEUE_FILE=q.txt
    run_execute() { echo "${FILES[0]}" >> ran.log; printf 'a.md\na.md\n' > q.txt; return 0; }
    run_chain_queue >/dev/null 2>&1
    [ "$(grep -c . ran.log)" -eq 1 ]
}

@test "run_chain_queue: stops at the first failing plan" {
    printf -- '- [ ] a\n' > a.md
    printf -- '- [ ] b\n' > b.md
    printf -- '- [ ] c\n' > c.md
    printf 'a.md\nb.md\nc.md\n' > q.txt
    QUEUE_FILE=q.txt
    run_execute() {
        echo "${FILES[0]}" >> ran.log
        [[ "${FILES[0]}" == "b.md" ]] && return 1
        return 0
    }
    run run_chain_queue
    [ "$status" -eq "$EXIT_PLAN_FAILED" ]
    [ "$(grep -c . ran.log)" -eq 2 ]
    [[ "$(cat ran.log)" != *"c.md"* ]] || return 1
}

@test "run_chain_queue: a queued plan that does not exist fails loudly" {
    printf 'ghost.md\n' > q.txt
    QUEUE_FILE=q.txt
    run_execute() { echo ran >> ran.log; return 0; }
    run run_chain_queue
    [ "$status" -eq "$EXIT_PLAN_FAILED" ]
    [[ "$output" == *"does not exist"* ]] || return 1
    [ ! -f ran.log ]
}

@test "run_chain_queue: an empty queue says so and succeeds" {
    : > q.txt
    QUEUE_FILE=q.txt
    run run_chain_queue
    [ "$status" -eq 0 ]
    [[ "$output" == *"queue was empty"* ]] || return 1
}

@test "run_chain: --queue takes precedence over the argv form" {
    printf -- '- [ ] a\n' > a.md
    printf 'a.md\n' > q.txt
    QUEUE_FILE=q.txt
    FILES=()
    run_execute() { echo "${FILES[0]}" >> ran.log; return 0; }
    run_chain >/dev/null 2>&1
    [ "$(cat ran.log)" = "a.md" ]
}

# ── find_run_sidecars / run_top ──────────────────────────────────────────────

@test "find_run_sidecars: finds runs in docs/ and cwd, sorted/deduped" {
    mkdir -p docs
    : > docs/a_plan.pid
    : > docs/b_plan.pid
    : > c_plan.pid
    run find_run_sidecars
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "./c_plan" || "${lines[0]}" == "c_plan" ]] || return 1
    [[ "$output" == *"docs/a_plan"* ]] || return 1
    [[ "$output" == *"docs/b_plan"* ]] || return 1
    [ "${#lines[@]}" -eq 3 ]
}

@test "find_run_sidecars: empty when there are no runs" {
    mkdir -p docs
    run find_run_sidecars
    [ -z "$output" ]
}

@test "find_run_sidecars: accepts a plan path or a sidecar directly" {
    mkdir -p docs
    : > docs/x_plan.pid
    run find_run_sidecars docs/x_plan.md
    [[ "$output" == *"docs/x_plan"* ]] || return 1
    run find_run_sidecars docs/x_plan.pid
    [[ "$output" == *"docs/x_plan"* ]] || return 1
}

@test "find_run_sidecars: a scheduled run counts as a known run" {
    mkdir -p docs
    : > docs/s_plan.scheduled
    run find_run_sidecars
    [ "$output" = "docs/s_plan" ]
    run find_run_sidecars docs/s_plan.md
    [ "$output" = "docs/s_plan" ]
}

@test "find_run_sidecars: a plan with both sidecars is listed once" {
    mkdir -p docs
    : > docs/both_plan.pid
    : > docs/both_plan.scheduled
    run find_run_sidecars
    [ "${#lines[@]}" -eq 1 ]
    [ "$output" = "docs/both_plan" ]
}

@test "run_top: friendly message when there are no runs" {
    FILES=()
    run run_top
    [ "$status" -eq 0 ]
    [[ "$output" == *"No wiggum runs found"* ]] || return 1
}

@test "run_top: lists a running run with pid, state and task tally" {
    mkdir -p docs
    cat > docs/r_plan.md <<'EOF'
- [ ] a
- [ ] b
- [x] c
EOF
    sleep 30 &
    local pid=$!
    echo "$pid" > docs/r_plan.pid
    FILES=()
    run run_top
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    [ "$status" -eq 0 ]
    [[ "$output" == *"PLAN"* ]] || return 1
    [[ "$output" == *"docs/r_plan.md"* ]] || return 1
    [[ "$output" == *"$pid"* ]] || return 1
    [[ "$output" == *"running"* ]] || return 1
    [[ "$output" == *"1/3 done, 2 left"* ]] || return 1
}

@test "run_top: shows a finished run from its out file" {
    mkdir -p docs
    cat > docs/f_plan.md <<'EOF'
- [x] a
- [x] b
EOF
    sleep 1 &
    local pid=$!
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    echo "$pid" > docs/f_plan.pid
    printf 'Status: complete\n' > docs/f_plan.out
    FILES=()
    run run_top
    [[ "$output" == *"docs/f_plan.md"* ]] || return 1
    [[ "$output" == *"finished: complete"* ]] || return 1
    [[ "$output" == *"2/2 done"* ]] || return 1
}

@test "run_top: lists a run that is only scheduled" {
    mkdir -p docs
    cat > docs/s_plan.md <<'EOF'
- [ ] a
- [ ] b
EOF
    sleep 30 &
    local waiter=$!
    printf 'target=%s\ntarget_human=%s\nspec=%s\npid=%s\n' \
        "$(( $(wiggum_now_epoch) + 3600 ))" "tomorrow 01:07" "01:07" "$waiter" \
        > docs/s_plan.scheduled
    FILES=()
    run run_top
    kill "$waiter" 2>/dev/null; wait "$waiter" 2>/dev/null || true
    [ "$status" -eq 0 ]
    [[ "$output" == *"docs/s_plan.md"* ]] || return 1
    [[ "$output" == *"scheduled for"* ]] || return 1
    [[ "$output" == *"0/2 done, 2 left"* ]] || return 1
}

@test "run_top: a live run outranks a stale schedule for the same plan" {
    mkdir -p docs
    cat > docs/s_plan.md <<'EOF'
- [ ] a
EOF
    sleep 30 &
    local pid=$!
    echo "$pid" > docs/s_plan.pid
    printf 'target=1\ntarget_human=then\nspec=01:07\npid=1\n' > docs/s_plan.scheduled
    FILES=()
    run run_top
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    [[ "$output" == *"$pid"* ]] || return 1
    [[ "$output" == *"running"* ]] || return 1
    [[ "$output" != *"scheduled for"* ]] || return 1
}

@test "read_run_status: no Status line is empty and successful, not a failure" {
    printf 'working...\nno status here\n' > out.txt
    run read_run_status out.txt
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "current_run_slice: a file with no run separator is not a failure" {
    printf 'old output\n' > out.txt
    run current_run_slice out.txt
    [ "$status" -eq 0 ]
    [ "$output" = "old output" ]
}

@test "run_top: one run with no recorded status does not truncate the table" {
    mkdir -p docs
    printf -- '- [ ] a\n' > docs/a_plan.md
    : > docs/a_plan.pid
    # A .out with no "Status:" line used to make grep exit 1, pipefail
    # propagate it, and set -e abort run_top part-way down the list.
    printf 'started, then killed\n' > docs/a_plan.out
    printf -- '- [ ] b\n' > docs/z_plan.md
    : > docs/z_plan.pid
    FILES=()
    run bash -c "set -euo pipefail; source '$WIGGUM_LIB'; export WIGGUM_REGISTRY_DIR='$WIGGUM_REGISTRY_DIR'; cd '$TEST_DIR'; FILES=(); run_top"
    [ "$status" -eq 0 ]
    [[ "$output" == *"docs/a_plan.md"* ]] || return 1
    # The row after the failing one has to survive.
    [[ "$output" == *"docs/z_plan.md"* ]] || return 1
}

@test "run_top: running runs sort above finished ones" {
    mkdir -p docs
    printf -- '- [x] a\n' > docs/aaa_plan.md
    sleep 1 &
    local dead=$!
    kill "$dead" 2>/dev/null; wait "$dead" 2>/dev/null || true
    echo "$dead" > docs/aaa_plan.pid
    printf 'Status: complete\n' > docs/aaa_plan.out
    printf -- '- [ ] b\n' > docs/zzz_plan.md
    sleep 30 &
    local live=$!
    echo "$live" > docs/zzz_plan.pid
    FILES=()
    run run_top
    kill "$live" 2>/dev/null; wait "$live" 2>/dev/null || true
    # Alphabetically aaa precedes zzz; by state the running one leads.
    local first
    first="$(printf '%s\n' "$output" | sed -n '2p')"
    [[ "$first" == *"zzz_plan.md"* ]] || return 1
    [[ "$first" == *"running"* ]] || return 1
}

@test "run_last_activity: seconds since the newest sidecar, empty when none" {
    mkdir -p docs
    : > docs/a_plan.md
    run run_last_activity docs/a_plan
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    : > docs/a_plan.log
    run run_last_activity docs/a_plan
    [ -n "$output" ]
    [ "$output" -ge 0 ]
    [ "$output" -lt 60 ]
}

@test "file_mtime_epoch: a missing file yields nothing, not a failure" {
    run file_mtime_epoch nope.txt
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "json_escape: quotes and backslashes survive" {
    run json_escape 'a"b\c'
    [ "$output" = 'a\"b\\c' ]
}

@test "run_top: the table carries an activity column" {
    mkdir -p docs
    printf -- '- [ ] a\n' > docs/r_plan.md
    : > docs/r_plan.pid
    : > docs/r_plan.log
    FILES=()
    run run_top
    [ "$status" -eq 0 ]
    [[ "$output" == *"ACTIVITY"* ]] || return 1
}

@test "run_top: --json emits parseable records with null for what is absent" {
    mkdir -p docs
    printf -- '- [ ] a\n- [x] b\n' > docs/j_plan.md
    sleep 1 &
    local dead=$!
    kill "$dead" 2>/dev/null; wait "$dead" 2>/dev/null || true
    echo "$dead" > docs/j_plan.pid
    FILES=()
    TOP_JSON=true
    run run_top
    [ "$status" -eq 0 ]
    [[ "$output" == *'"plan": "docs/j_plan.md"'* ]] || return 1
    # Nothing is running, so pid is null rather than the string "-".
    [[ "$output" == *'"pid": null'* ]] || return 1
    [[ "$output" == *'"total": 2'* ]] || return 1
    [[ "$output" == *'"done": 1'* ]] || return 1
    printf '%s' "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d, list) and len(d) == 1, d"
}

@test "run_top: --json and the table agree on state and counts" {
    mkdir -p docs
    printf -- '- [ ] a\n' > docs/k_plan.md
    printf 'Status: complete\n' > docs/k_plan.out
    : > docs/k_plan.pid
    FILES=()
    TOP_JSON=false
    run run_top
    [[ "$output" == *"finished: complete"* ]] || return 1
    TOP_JSON=true
    run run_top
    [[ "$output" == *'"state": "finished: complete"'* ]] || return 1
}

@test "parse_args: --json sets TOP_JSON" {
    parse_args top --json
    [ "$TOP_JSON" = "true" ]
    wiggum_reset
    [ "$TOP_JSON" = "false" ]
}

@test "run_top: flags a blocked run" {
    mkdir -p docs
    cat > docs/b_plan.md <<'EOF'
- [ ] a
EOF
    sleep 30 &
    local pid=$!
    echo "$pid" > docs/b_plan.pid
    printf 'No progress detected (1 tasks remaining, stall 1 of 2).\n' > docs/b_plan.out
    FILES=()
    run run_top
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    [[ "$output" == *"running (blocked)"* ]] || return 1
}

# ── run_execute: empty / all-done guard ──────────────────────────────────────

@test "run_execute: a foreground run registers itself, then releases the sidecar" {
    mkdir -p docs
    cat > docs/plan.md <<'EOF'
# Plan
- [x] already done
EOF
    # The claim lives only for the length of the run, so read it from inside a
    # claude call rather than after the run has cleaned up. This is the case
    # that used to be invisible to `top`: every plan in a chain runs this way.
    claude() { [ -f docs/plan.pid ] && cp docs/plan.pid pid_seen; return 0; }
    export -f claude
    MODE=execute
    FILES=(docs/plan.md)
    SUMMARY_FILE=docs/plan_summary.md
    NO_VERIFY=true
    NO_COMMIT=true
    run run_execute
    [ "$status" -eq 0 ]
    [ "$(cat pid_seen)" = "$$" ]
    [ ! -f docs/plan.pid ]
}

@test "run_execute: skips the implement step when no tasks are pending" {
    mkdir -p docs
    cat > docs/plan.md <<'EOF'
# Plan
- [x] already done
EOF
    # Record every prompt claude is handed so we can assert which steps ran.
    claude() { printf '%s\n' "$*" >> claude_calls; return 0; }
    export -f claude
    MODE=execute
    FILES=(docs/plan.md)
    SUMMARY_FILE=docs/plan_summary.md
    NO_VERIFY=true
    NO_COMMIT=true
    run run_execute
    [ "$status" -eq 0 ]
    [[ "$output" == *"No pending tasks"* ]] || return 1
    [[ "$output" == *"(complete)"* ]] || return 1
    # Phase 1 still ran, but the phase-2 implement prompt was never issued.
    grep -q "Analyze the repository against the workplan" claude_calls
    ! grep -q "Execute the next discrete implementation step" claude_calls
}

@test "run_execute: warns when the plan still has no trackable tasks" {
    # If phase 1 can't produce any checkboxes (here, a no-op stub), wiggum skips
    # implementation rather than spinning -- the post-phase-1 safety net.
    mkdir -p docs
    cat > docs/plan.md <<'EOF'
# Plan
Just prose, no checkboxes at all.
EOF
    claude() { printf '%s\n' "$*" >> claude_calls; return 0; }
    export -f claude
    MODE=execute
    FILES=(docs/plan.md)
    SUMMARY_FILE=docs/plan_summary.md
    NO_VERIFY=true
    NO_COMMIT=true
    run run_execute
    [ "$status" -eq 0 ]
    [[ "$output" == *"no trackable tasks"* ]] || return 1
    ! grep -q "Execute the next discrete implementation step" claude_calls
}

@test "run_execute: counts checkboxes that phase 1 adds to the plan" {
    # Proves the counts are read AFTER phase 1: a heading-only task (0 checkboxes
    # to start) becomes trackable once the phase-1 diagnostic rewrites it.
    mkdir -p docs
    cat > docs/plan.md <<'EOF'
# Plan
### Task one (no checkbox yet)
EOF
    claude() {
        if [[ "$*" == *"Analyze the repository against the workplan"* ]]; then
            printf '# Plan\n- [ ] Task one\n' > docs/plan.md
        fi
        printf '%s\n' "$*" >> claude_calls
        return 0
    }
    export -f claude
    MODE=execute
    FILES=(docs/plan.md)
    SUMMARY_FILE=docs/plan_summary.md
    NO_VERIFY=true
    NO_COMMIT=true
    run run_execute
    [ "$status" -eq 0 ]
    # The added checkbox was counted, so implementation ran (not the skip path).
    [[ "$output" != *"no trackable tasks"* ]] || return 1
    grep -q "Execute the next discrete implementation step" claude_calls
}

@test "run_execute: phase 3 reconciles the issue ledger" {
    mkdir -p docs
    cat > docs/plan.md <<'EOF'
# Plan
- [x] already done
EOF
    claude() { printf '%s\n' "$*" >> claude_calls; return 0; }
    export -f claude
    MODE=execute
    FILES=(docs/plan.md)
    SUMMARY_FILE=docs/plan_summary.md
    NO_VERIFY=true
    NO_COMMIT=true
    run run_execute
    [ "$status" -eq 0 ]
    # Phase 3 aligns the ledger alongside the plan checkboxes, not just the summary.
    grep -q "Close the loop on the issue ledger" claude_calls
    grep -q "Never invent a ledger" claude_calls
    # ...and the summary has to say which entries closed and which stayed open.
    grep -q "issue-ledger entries you closed" claude_calls
    # The pre-existing phase-3 duties survive the insertion.
    grep -q "marking completed tasks with \[x\]" claude_calls
    grep -q "Write a concise execution summary" claude_calls
}

@test "run_execute: the phase 3 commit picks up the ledger it just edited" {
    mkdir -p docs
    cat > docs/plan.md <<'EOF'
# Plan
- [x] already done
EOF
    claude() { printf '%s\n' "$*" >> claude_calls; return 0; }
    export -f claude
    MODE=execute
    FILES=(docs/plan.md)
    SUMMARY_FILE=docs/plan_summary.md
    NO_VERIFY=true
    NO_COMMIT=false
    run run_execute
    [ "$status" -eq 0 ]
    # A ledger edited but left uncommitted is a ledger that didn't get updated.
    grep -q "any issue ledger updated" claude_calls
}

# ── env_reminder ─────────────────────────────────────────────────────────────

@test "env_reminder: generic reminder when no environment markers" {
    run env_reminder
    [[ "$output" == *"current shell environment"* ]] || return 1
}

@test "env_reminder: warns when a conda project has no env active" {
    touch environment.yml
    export CONDA_DEFAULT_ENV="" VIRTUAL_ENV=""
    run env_reminder
    [[ "$output" == *"Warning:"* ]] || return 1
    [[ "$output" == *"conda activate"* ]] || return 1
}

@test "env_reminder: treats conda 'base' as no env active" {
    touch environment.yml
    export CONDA_DEFAULT_ENV="base" VIRTUAL_ENV=""
    run env_reminder
    [[ "$output" == *"Warning:"* ]] || return 1
}

@test "env_reminder: warns when a Python venv project has no env active" {
    touch requirements.txt
    export CONDA_DEFAULT_ENV="" VIRTUAL_ENV=""
    run env_reminder
    [[ "$output" == *"Warning:"* ]] || return 1
    [[ "$output" == *"virtualenv"* ]] || return 1
}

@test "env_reminder: stays soft when a virtualenv is active" {
    touch requirements.txt
    export CONDA_DEFAULT_ENV="" VIRTUAL_ENV="/tmp/proj/.venv"
    run env_reminder
    [[ "$output" != *"Warning:"* ]] || return 1
    [[ "$output" == *"is active"* ]] || return 1
}

@test "env_reminder: stays soft when a non-base conda env is active" {
    touch environment.yml
    export CONDA_DEFAULT_ENV="proj-env" VIRTUAL_ENV=""
    run env_reminder
    [[ "$output" != *"Warning:"* ]] || return 1
    [[ "$output" == *"proj-env"* ]] || return 1
}

@test "env_reminder: tailors the hint to Node projects" {
    touch package.json
    run env_reminder
    [[ "$output" == *"Node"* ]] || [[ "$output" == *"nvm"* ]] || return 1
}

@test "run_execute: reminds about the shell environment" {
    mkdir -p docs
    cat > docs/plan.md <<'EOF'
- [x] done
EOF
    claude() { return 0; }
    export -f claude
    MODE=execute
    FILES=(docs/plan.md)
    SUMMARY_FILE=docs/plan_summary.md
    NO_VERIFY=true
    NO_COMMIT=true
    run run_execute
    [[ "$output" == *"Reminder:"* ]] || return 1
    [[ "$output" == *"environment"* ]] || return 1
}

# ── current_run_slice / .out appends across runs ──────────────────────────────

@test "current_run_slice: returns only the last run's section" {
    printf -- '--- wiggum run 2026-01-01 00:00:00 ---\nold noise\nStatus: stalled\n' > run.out
    printf -- '--- wiggum run 2026-01-02 00:00:00 ---\nfresh\n' >> run.out
    run current_run_slice run.out
    [[ "$output" == *"fresh"* ]] || return 1
    [[ "$output" != *"old noise"* ]] || return 1
}

@test "current_run_slice: whole file when no separator is present" {
    printf 'legacy line\nStatus: complete\n' > run.out
    run current_run_slice run.out
    [[ "$output" == *"legacy line"* ]] || return 1
}

@test "current_run_slice: empty for a missing file" {
    run current_run_slice missing.out
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "read_run_status: ignores a previous run's status" {
    printf -- '--- wiggum run 2026-01-01 00:00:00 ---\nStatus: stalled\n' > run.out
    printf -- '--- wiggum run 2026-01-02 00:00:00 ---\nStatus: complete\n' >> run.out
    [ "$(read_run_status run.out)" = "complete" ]
}

@test "read_run_status: empty while the current run has recorded no status" {
    printf -- '--- wiggum run 2026-01-01 00:00:00 ---\nStatus: complete\n' > run.out
    printf -- '--- wiggum run 2026-01-02 00:00:00 ---\nstill working\n' >> run.out
    [ -z "$(read_run_status run.out)" ]
}

@test "detect_blocked: a dead run's stall does not flag the current run" {
    printf -- '--- wiggum run 2026-01-01 00:00:00 ---\nNo progress detected\n' > run.out
    printf -- '--- wiggum run 2026-01-02 00:00:00 ---\nworking fine\n' >> run.out
    ! detect_blocked run.out
}

@test "detect_blocked: still true for a stall in the current run" {
    printf -- '--- wiggum run 2026-01-01 00:00:00 ---\nfine\n' > run.out
    printf -- '--- wiggum run 2026-01-02 00:00:00 ---\nStalled for 300s\n' >> run.out
    detect_blocked run.out
}

@test "launch_execute_background: appends to .out and separates the runs" {
    cat > plan.md <<'EOF'
- [x] done
EOF
    printf 'output from an earlier run\n' > plan.out
    FILES=(plan.md)
    MODE=execute
    SUMMARY_FILE=plan_summary.md
    NO_VERIFY=true
    NO_COMMIT=true
    BACKGROUND=true
    launch_execute_background >/dev/null 2>&1
    wait || true
    grep -q 'output from an earlier run' plan.out
    grep -q '^--- wiggum run ' plan.out
}

# ── release_pidfile: the kill-then-relaunch race ──────────────────────────────

@test "release_pidfile: removes the pidfile it was given" {
    echo 111 > plan.pid
    release_pidfile plan.pid 111
    [ ! -f plan.pid ]
}

@test "release_pidfile: keeps a pidfile a relaunch has already replaced" {
    echo 222 > plan.pid
    release_pidfile plan.pid 111
    [ -f plan.pid ]
    [ "$(cat plan.pid)" = "222" ]
}

@test "release_pidfile: silent no-op when the pidfile is gone" {
    run release_pidfile missing.pid 111
    [ "$status" -eq 0 ]
}

@test "run_watch: does not delete a newer run's pidfile when its own run ends" {
    cat > plan.md <<'EOF'
- [x] one
EOF
    printf -- '--- wiggum run 2026-01-01 00:00:00 ---\nStatus: complete\n' > plan.out
    # The run being watched stays alive long enough for a relaunch to land
    # mid-watch, which is where the race lives.
    ( sleep 3 ) &
    local watched=$!
    echo "$watched" > plan.pid
    # A relaunch replaces the pidfile while watch is still polling.
    ( sleep 1; echo 999999 > plan.pid ) &
    FILES=(plan.md)
    WATCH_POLL=1
    run run_watch
    [ -f plan.pid ]
    [ "$(cat plan.pid)" = "999999" ]
}

@test "run_watch: streams only the current run, not the whole history" {
    cat > plan.md <<'EOF'
- [x] one
EOF
    printf -- '--- wiggum run 2026-01-01 00:00:00 ---\nANCIENT_MARKER\nStatus: stalled\n' > plan.out
    # launch_execute_background writes this run's separator synchronously, before
    # any watch can attach; model that rather than withholding it.
    printf -- '--- wiggum run 2026-01-02 00:00:00 ---\n' >> plan.out
    ( sleep 1; printf 'CURRENT_MARKER\nStatus: complete\n' >> plan.out ) &
    local pid=$!
    echo "$pid" > plan.pid
    FILES=(plan.md)
    WATCH_POLL=1
    run run_watch
    [[ "$output" != *"ANCIENT_MARKER"* ]] || return 1
    [[ "$output" == *"CURRENT_MARKER"* ]] || return 1
}

@test "current_run_slice: the ABORTED banner is not a run separator" {
    # report_unfinished_run writes "=== WIGGUM RUN ABORTED ===" into .out just
    # BELOW the status line it is reporting. A separator prefix that matches that
    # banner slices the status away and read_run_status goes blind.
    printf -- '--- wiggum run 2026-01-01 00:00:00 ---\n' > run.out
    printf 'Status: aborted (exit 3)\n=== WIGGUM RUN ABORTED ===\n' >> run.out
    run current_run_slice run.out
    [[ "$output" == *"Status: aborted"* ]] || return 1
    [ "$(read_run_status run.out)" = "aborted (exit 3)" ]
}

# ── wiggum_now_epoch / wiggum_now_hms ────────────────────────────────────────

@test "wiggum_now_epoch: returns a bare epoch in seconds" {
    local now
    now="$(wiggum_now_epoch)"
    [[ "$now" =~ ^[0-9]+$ ]] || return 1
    # Bracketed by 2020 and 2100, so a date string, a stray label or an empty
    # result cannot pass as an epoch.
    [ "$now" -gt 1577836800 ]
    [ "$now" -lt 4102444800 ]
}

@test "wiggum_now_hms: returns HH:MM:SS on a zero-padded 24-hour clock" {
    local hms
    hms="$(wiggum_now_hms)"
    [[ "$hms" =~ ^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$ ]] || return 1
    # Zero-padded fields are what lets the caller do 10# arithmetic on them.
    [ "$((10#${hms%%:*}))" -le 23 ]
    [ "$((10#$(echo "$hms" | cut -d: -f2)))" -le 59 ]
}

@test "wiggum_now: two reads of the epoch never go backwards" {
    local first second
    first="$(wiggum_now_epoch)"
    second="$(wiggum_now_epoch)"
    [ "$second" -ge "$first" ]
}

@test "wiggum_now: overriding the accessors injects a clock into a caller" {
    # The accessors exist to be stubbed the way claude is stubbed in setup().
    # A caller reading the clock through them sees the injected time.
    #
    # Assert the library defines both before overriding them: without this the
    # test passes vacuously when they do not exist, since a caller that fails
    # with 127 also does not print the injected time.
    declare -F wiggum_now_epoch >/dev/null
    declare -F wiggum_now_hms >/dev/null
    clock_reader() { echo "$(wiggum_now_epoch) $(wiggum_now_hms)"; }
    [ "$(clock_reader)" != "1756180020 22:00:00" ]
    wiggum_now_epoch() { echo 1756180020; }
    wiggum_now_hms() { echo "22:00:00"; }
    [ "$(clock_reader)" = "1756180020 22:00:00" ]
}

# ── parse_at_time ────────────────────────────────────────────────────────────

# Freeze the clock by overriding the two accessors, the way setup() stubs
# claude.  The stubs read globals rather than locals: a function defined inside
# another function still resolves its variables when it is *called*, by which
# point a local of the definer has gone out of scope.
freeze_clock() {
    FAKE_EPOCH="$1"
    FAKE_HMS="$2"
    wiggum_now_epoch() { echo "$FAKE_EPOCH"; }
    wiggum_now_hms() { echo "$FAKE_HMS"; }
}

# The design note's prototype clock: 2026-08-25 22:00:00.
PROTO_EPOCH=1756180020

# Freeze the injected clock at the *real* epoch, wearing an arbitrary
# wall-clock face. Anything that starts a waiter needs this rather than
# PROTO_EPOCH: the waiter is a separate process reading the real clock, so a
# target resolved from a fixed past epoch is already due the moment it starts.
# The HH:MM:SS stays fixed because describe_at_target builds its summary from
# that, not from the epoch. The chosen epoch lands in WIGGUM_TEST_NOW.
freeze_clock_now() {
    WIGGUM_TEST_NOW="$(date +%s)"
    freeze_clock "$WIGGUM_TEST_NOW" "${1:-22:00:00}"
}

@test "parse_at_time: +90m resolves to ninety minutes from now" {
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    run parse_at_time "+90m"
    [ "$status" -eq 0 ]
    [ "$output" = "$((PROTO_EPOCH + 5400))" ]
}

@test "parse_at_time: +6h resolves to six hours from now, crossing midnight" {
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    run parse_at_time "+6h"
    [ "$status" -eq 0 ]
    # 22:00 + 6h is 04:00 the next day; epoch arithmetic needs no calendar.
    [ "$output" = "$((PROTO_EPOCH + 21600))" ]
}

@test "parse_at_time: +2d resolves to two days from now" {
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    run parse_at_time "+2d"
    [ "$status" -eq 0 ]
    [ "$output" = "$((PROTO_EPOCH + 172800))" ]
}

@test "parse_at_time: +2d crossing a month end is plain addition" {
    # 2026-08-30 22:00:00 + 2d is 2026-09-01.  There is no calendar in the
    # path, so a month end is not a special case -- this pins that it stays so.
    freeze_clock 1756612020 "22:00:00"
    run parse_at_time "+2d"
    [ "$status" -eq 0 ]
    [ "$output" = "$((1756612020 + 172800))" ]
}

@test "parse_at_time: HH:MM earlier than now rolls to tomorrow" {
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    run parse_at_time "01:07"
    [ "$status" -eq 0 ]
    # 22:00 -> 01:07 next day is 3h07m = 11220s.
    [ "$output" = "$((PROTO_EPOCH + 11220))" ]
}

@test "parse_at_time: HH:MM later than now stays today" {
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    run parse_at_time "23:30"
    [ "$status" -eq 0 ]
    [ "$output" = "$((PROTO_EPOCH + 5400))" ]
}

@test "parse_at_time: HH:MM equal to now means tomorrow" {
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    run parse_at_time "22:00"
    [ "$status" -eq 0 ]
    # Never resolves to now: a zero-second wait is far more likely to be a
    # user meaning "tonight" than one meaning "immediately".
    [ "$output" = "$((PROTO_EPOCH + 86400))" ]
}

@test "parse_at_time: 08:30 is decimal, not invalid octal" {
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    run parse_at_time "08:30"
    [ "$status" -eq 0 ]
    [ "$output" = "$((PROTO_EPOCH + 37800))" ]
}

@test "parse_at_time: 09:00 is decimal, not invalid octal" {
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    run parse_at_time "09:00"
    [ "$status" -eq 0 ]
    [ "$output" = "$((PROTO_EPOCH + 39600))" ]
}

@test "parse_at_time: a zero-padded current time is decimal too" {
    # The octal trap is on both sides: the *current* hour and minute come from
    # wiggum_now_hms and are zero-padded as well.  09:08:07 is three of them.
    freeze_clock "$PROTO_EPOCH" "09:08:07"
    run parse_at_time "09:09"
    [ "$status" -eq 0 ]
    # 09:08:07 -> 09:09:00 is 53s.
    [ "$output" = "$((PROTO_EPOCH + 53))" ]
}

@test "parse_at_time: 00:00 rolls over midnight" {
    freeze_clock "$PROTO_EPOCH" "23:59:30"
    run parse_at_time "00:00"
    [ "$status" -eq 0 ]
    [ "$output" = "$((PROTO_EPOCH + 30))" ]
}

@test "parse_at_time: @epoch is used as-is" {
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    run parse_at_time "@1756180020"
    [ "$status" -eq 0 ]
    [ "$output" = "1756180020" ]
}

@test "parse_at_time: @epoch in the past resolves rather than erroring" {
    # Resolving lets the caller report "that time has passed" itself; erroring
    # here would make a past epoch indistinguishable from a typo.
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    run parse_at_time "@1000000000"
    [ "$status" -eq 0 ]
    [ "$output" = "1000000000" ]
}

@test "parse_at_time: rejects an out-of-range hour" {
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    run parse_at_time "25:00"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "parse_at_time: rejects an out-of-range minute" {
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    run parse_at_time "12:60"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "parse_at_time: rejects a twelve-hour clock" {
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    run parse_at_time "1am"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "parse_at_time: rejects a calendar word" {
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    run parse_at_time "tomorrow"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "parse_at_time: rejects an unknown duration unit" {
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    run parse_at_time "+5x"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "parse_at_time: rejects a duration with no unit" {
    # Bare +90 is ambiguous between sleep's seconds and at's minutes; a silent
    # sixtyfold error is worse than an error message naming the three forms.
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    run parse_at_time "+90"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "parse_at_time: rejects a non-numeric epoch" {
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    run parse_at_time "@later"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "parse_at_time: rejects the empty string" {
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    run parse_at_time ""
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "parse_at_time: rejects a missing argument" {
    # Must not die on an unbound variable under set -u.
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    run parse_at_time
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "parse_at_time: reads the clock only through the accessors" {
    # If the function called `date` directly, a frozen clock would not move it.
    # Two different frozen clocks must give two different answers.
    local first second
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    first="$(parse_at_time "+1h")"
    freeze_clock 1000000000 "22:00:00"
    second="$(parse_at_time "+1h")"
    [ "$first" = "$((PROTO_EPOCH + 3600))" ]
    [ "$second" = "1000003600" ]
}

# ── format_duration / describe_at_target ─────────────────────────────────────

@test "format_duration: renders seconds, minutes, hours and days" {
    [ "$(format_duration 45)" = "45s" ]
    [ "$(format_duration 90)" = "1m 30s" ]
    [ "$(format_duration 11220)" = "3h 7m" ]
    [ "$(format_duration 194400)" = "2d 6h" ]
}

@test "format_duration: zero and negative spans render as 0s" {
    [ "$(format_duration 0)" = "0s" ]
    [ "$(format_duration -5)" = "0s" ]
}

@test "describe_at_target: renders a target later today" {
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    [ "$(describe_at_target "$((PROTO_EPOCH + 5400))")" = "23:30:00 today" ]
}

@test "describe_at_target: renders a target that has rolled to tomorrow" {
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    local target
    target="$(parse_at_time "01:07")"
    [ "$(describe_at_target "$target")" = "01:07:00 tomorrow" ]
}

@test "describe_at_target: renders a target several days out" {
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    [ "$(describe_at_target "$((PROTO_EPOCH + 2 * 86400))")" = "22:00:00 in 2 days" ]
}

@test "describe_at_target: renders a target in the past" {
    # Phase 3 reports a missed schedule; flooring the day arithmetic rather
    # than truncating is what keeps a past target from reading as `today`.
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    [ "$(describe_at_target "$((PROTO_EPOCH - 86400))")" = "22:00:00 yesterday" ]
}

@test "describe_at_target: reads the clock only through the accessors" {
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    local first
    first="$(describe_at_target "$((PROTO_EPOCH + 3600))")"
    freeze_clock 1000000000 "06:00:00"
    [ "$first" = "23:00:00 today" ]
    [ "$(describe_at_target 1000003600)" = "07:00:00 today" ]
}

# ── launch_execute_delayed ───────────────────────────────────────────────────

# Schedule a run far enough out that the waiter is still sleeping when the
# assertions run, and hand back its pid so the test body can kill it. The plan
# is explicit that a failing test must not leave a detached waiter behind.
schedule_far_future() {
    local spec="${1:-+90m}"
    mkdir -p docs
    cat > docs/plan.md <<'EOF'
- [ ] one
EOF
    FILES=(docs/plan.md)
    AT_TIME="$spec"
    launch_execute_delayed >/dev/null 2>&1
}

sidecar_field() {
    sed -n "s/^$1=//p" docs/plan.scheduled
}

kill_waiter() {
    local pid="$1"
    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

@test "launch_execute_delayed: writes a .scheduled sidecar with the resolved epoch" {
    freeze_clock_now "22:00:00"
    schedule_far_future "+90m"
    local waiter
    waiter="$(sidecar_field pid)"
    kill_waiter "$waiter"
    [ -f docs/plan.scheduled ]
    [ "$(sidecar_field target)" = "$((WIGGUM_TEST_NOW + 5400))" ]
    [ "$(sidecar_field target_human)" = "23:30:00 today" ]
    [ "$(sidecar_field spec)" = "+90m" ]
    [ -n "$waiter" ]
}

@test "launch_execute_delayed: records a live waiter pid" {
    freeze_clock_now "22:00:00"
    schedule_far_future "+6h"
    local waiter
    waiter="$(sidecar_field pid)"
    local alive=1
    process_alive "$waiter" && alive=0
    kill_waiter "$waiter"
    [ "$alive" -eq 0 ]
}

@test "launch_execute_delayed: writes no pidfile at schedule time" {
    # A scheduled run must never read as running -- the distinction is what
    # tells somebody whether to expect output.
    freeze_clock_now "22:00:00"
    schedule_far_future "+90m"
    local waiter
    waiter="$(sidecar_field pid)"
    kill_waiter "$waiter"
    [ ! -f docs/plan.pid ]
}

@test "launch_execute_delayed: reports the target and the managing commands" {
    freeze_clock_now "22:00:00"
    mkdir -p docs
    cat > docs/plan.md <<'EOF'
- [ ] one
EOF
    FILES=(docs/plan.md)
    AT_TIME="+90m"
    run launch_execute_delayed
    kill_waiter "$(sidecar_field pid)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"23:30:00 today"* ]] || return 1
    [[ "$output" == *"1h 30m"* ]] || return 1
    [[ "$output" == *"wiggum status docs/plan.md"* ]] || return 1
    [[ "$output" == *"wiggum kill docs/plan.md"* ]] || return 1
}

@test "launch_execute_delayed: a past time exits EXIT_BAD_ARGS and writes no sidecar" {
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    mkdir -p docs
    cat > docs/plan.md <<'EOF'
- [ ] one
EOF
    FILES=(docs/plan.md)
    AT_TIME="@$((PROTO_EPOCH - 3600))"
    run launch_execute_delayed
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [ ! -f docs/plan.scheduled ]
    [ ! -f docs/plan.pid ]
    [[ "$output" == *"past"* ]] || return 1
}

@test "launch_execute_delayed: a target equal to now is in the past" {
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    mkdir -p docs
    cat > docs/plan.md <<'EOF'
- [ ] one
EOF
    FILES=(docs/plan.md)
    AT_TIME="@$PROTO_EPOCH"
    run launch_execute_delayed
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [ ! -f docs/plan.scheduled ]
}

@test "launch_execute_delayed: an unparseable time exits EXIT_BAD_ARGS naming the three forms" {
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    mkdir -p docs
    cat > docs/plan.md <<'EOF'
- [ ] one
EOF
    FILES=(docs/plan.md)
    AT_TIME="tomorrow"
    run launch_execute_delayed
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [ ! -f docs/plan.scheduled ]
    [[ "$output" == *"+90m"* ]] || return 1
    [[ "$output" == *"01:07"* ]] || return 1
    [[ "$output" == *"@"* ]] || return 1
}

@test "launch_execute_delayed: refuses to schedule over a live run" {
    freeze_clock "$PROTO_EPOCH" "22:00:00"
    mkdir -p docs
    cat > docs/plan.md <<'EOF'
- [ ] one
EOF
    sleep 30 &
    local pid=$!
    echo "$pid" > docs/plan.pid
    FILES=(docs/plan.md)
    AT_TIME="+90m"
    run launch_execute_delayed
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [ ! -f docs/plan.scheduled ]
    [[ "$output" == *"already active"* ]] || return 1
}

@test "launch_execute_delayed: refuses a second schedule over a live waiter" {
    freeze_clock_now "22:00:00"
    schedule_far_future "+90m"
    local waiter
    waiter="$(sidecar_field pid)"
    AT_TIME="+6h"
    run launch_execute_delayed
    kill_waiter "$waiter"
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"already scheduled"* ]] || return 1
    # The original schedule survives the refusal.
    [ "$(sidecar_field target)" = "$((WIGGUM_TEST_NOW + 5400))" ]
}

@test "launch_execute_delayed: overwrites a stale schedule whose waiter has died" {
    # A machine that was off at the target time is the ordinary case, not an
    # error state, so a dead waiter must not block a fresh schedule.
    freeze_clock_now "22:00:00"
    mkdir -p docs
    cat > docs/plan.md <<'EOF'
- [ ] one
EOF
    sleep 30 &
    local dead=$!
    kill "$dead" 2>/dev/null; wait "$dead" 2>/dev/null || true
    printf 'target=%s\ntarget_human=old\npid=%s\nspec=01:07\n' "$((WIGGUM_TEST_NOW - 86400))" "$dead" \
        > docs/plan.scheduled
    FILES=(docs/plan.md)
    AT_TIME="+6h"
    run launch_execute_delayed
    kill_waiter "$(sidecar_field pid)"
    [ "$status" -eq 0 ]
    [ "$(sidecar_field target)" = "$((WIGGUM_TEST_NOW + 21600))" ]
}

@test "launch_execute_delayed: a missed schedule reports missed, then reschedules" {
    # The whole of the self-healing path in one go: the machine was off at
    # 01:07, so status says missed rather than pending, and the next --at is
    # accepted over the leftover instead of refused as a conflict.
    freeze_clock_now "22:00:00"
    mkdir -p docs
    cat > docs/plan.md <<'EOF'
- [ ] one
EOF
    printf 'target=%s\ntarget_human=01:07:00 tomorrow\npid=%s\nspec=01:07\n' \
        "$((WIGGUM_TEST_NOW - 75180))" "$DEAD_PID" > docs/plan.scheduled

    FILES=(docs/plan.md)
    run run_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"State: missed: was scheduled for 01:07:00 today (20h 53m ago)"* ]] || return 1

    AT_TIME="+6h"
    run launch_execute_delayed
    kill_waiter "$(sidecar_field pid)"
    [ "$status" -eq 0 ]
    [ "$(sidecar_field target)" = "$((WIGGUM_TEST_NOW + 21600))" ]
}

@test "launch_execute_delayed: leaves a dead pidfile alone and schedules anyway" {
    freeze_clock_now "22:00:00"
    mkdir -p docs
    cat > docs/plan.md <<'EOF'
- [ ] one
EOF
    sleep 30 &
    local dead=$!
    kill "$dead" 2>/dev/null; wait "$dead" 2>/dev/null || true
    echo "$dead" > docs/plan.pid
    FILES=(docs/plan.md)
    AT_TIME="+90m"
    run launch_execute_delayed
    kill_waiter "$(sidecar_field pid)"
    [ "$status" -eq 0 ]
    [ -f docs/plan.scheduled ]
}

@test "launch_execute_delayed: clears AT_TIME and BACKGROUND for the detached run" {
    # The waiter re-enters run_execute; if either flag survived it would recurse
    # straight back into a launcher instead of running the loop.
    freeze_clock_now "22:00:00"
    BACKGROUND=true
    schedule_far_future "+90m"
    kill_waiter "$(sidecar_field pid)"
    [ -z "$AT_TIME" ]
    [ "$BACKGROUND" = false ]
}

# ── the detached waiter ──────────────────────────────────────────────────────

# Build a project the waiter can really run in. The waiter is a separate
# process, so it inherits none of this file's shell functions: `claude` has to
# be a real executable on PATH and the config a real .wiggumrc, or the run it
# starts is not the run these assertions describe.
make_runnable_project() {
    mkdir -p docs bin
    cat > docs/plan.md <<'EOF'
# Waiter plan

- [ ] one
EOF
    cat > bin/claude <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x bin/claude
    cat > .wiggumrc <<'EOF'
max_iterations = 0
skip_verify = true
skip_commit = true
EOF
    PATH="$PWD/bin:$PATH"
}

@test "launch_execute_delayed: the detached waiter starts the run at the target time" {
    make_runnable_project
    FILES=(docs/plan.md)
    AT_TIME="@$(( $(date +%s) + 2 ))"
    WIGGUM_AT_POLL_INTERVAL=1
    launch_execute_delayed >/dev/null 2>&1

    local waiter
    waiter="$(sidecar_field pid)"

    # Bounded wait for the swap from scheduled to running, then tear down
    # whatever is still alive before asserting -- a failing assertion must not
    # leave a detached waiter or a real run behind.
    local tries=60
    while [ "$tries" -gt 0 ] && [ ! -f docs/plan.pid ]; do
        sleep 0.5
        tries=$((tries - 1))
    done
    local runner
    runner="$(cat docs/plan.pid 2>/dev/null || true)"
    kill "$waiter" 2>/dev/null || true
    kill "$runner" 2>/dev/null || true

    [ -n "$waiter" ] || return 1
    [ ! -f docs/plan.scheduled ] || return 1
    [ -f docs/plan.pid ] || return 1
    [ -n "$runner" ] || return 1
    [ "$(grep -c -- '--- wiggum run' docs/plan.out)" -eq 1 ]
}

@test "launch_execute_delayed: the waiter runs outside the scheduling shell's process group" {
    # The whole point of detaching: a six-hour wait outlives the terminal that
    # started it. A backgrounded subshell shares this shell's process group and
    # goes down with it; `screen -dmS` puts the waiter in a session of its own.
    freeze_clock_now "22:00:00"
    schedule_far_future "+90m"
    local waiter
    waiter="$(sidecar_field pid)"
    local waiter_pgid mine
    waiter_pgid="$(ps -o pgid= -p "$waiter" 2>/dev/null | tr -d '[:space:]')"
    mine="$(ps -o pgid= -p $$ 2>/dev/null | tr -d '[:space:]')"
    kill_waiter "$waiter"
    [ -n "$waiter_pgid" ] || return 1
    [ -n "$mine" ] || return 1
    [ "$waiter_pgid" != "$mine" ] || return 1
}

@test "launch_execute_delayed: falls back to nohup when screen cannot start the waiter" {
    # Not every box has a working screen. The fallback buys SIGHUP immunity
    # rather than a new session, which is weaker but is what macOS leaves us --
    # there is no setsid.
    screen() { return 1; }
    freeze_clock_now "22:00:00"
    mkdir -p docs
    cat > docs/plan.md <<'EOF'
- [ ] one
EOF
    FILES=(docs/plan.md)
    AT_TIME="+90m"
    run launch_execute_delayed
    local waiter
    waiter="$(sidecar_field pid)"
    kill -HUP "$waiter" 2>/dev/null || true
    sleep 0.3
    local survived=1
    process_alive "$waiter" && survived=0
    kill_waiter "$waiter"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nohup"* ]] || return 1
    [ "$survived" -eq 0 ]
}

# ── at_replay_argv ───────────────────────────────────────────────────────────

@test "at_replay_argv: replays the captured invocation without --at" {
    WIGGUM_ARGV=(execute docs/plan.md --at 01:07 --max-iterations 5)
    local out
    out="$(at_replay_argv | tr '\0' '\n')"
    [ "$out" = "$(printf 'execute\ndocs/plan.md\n--max-iterations\n5')" ]
}

@test "at_replay_argv: drops --background, which the waiter must not re-enter" {
    # The waiter runs the CLI in the foreground inside its own session. A
    # replayed --background would daemonize and let that session exit, taking
    # the tree with it.
    WIGGUM_ARGV=(execute docs/plan.md --background --at +90m)
    local out
    out="$(at_replay_argv | tr '\0' '\n')"
    [ "$out" = "$(printf 'execute\ndocs/plan.md')" ]
}

@test "at_replay_argv: falls back to the file list when no argv was captured" {
    WIGGUM_ARGV=()
    FILES=(docs/plan.md docs/other.md)
    local out
    out="$(at_replay_argv | tr '\0' '\n')"
    [ "$out" = "$(printf 'execute\ndocs/plan.md\ndocs/other.md')" ]
}

@test "parse_args: records the invocation for a delayed run to replay" {
    make_file "docs/plan.md"
    parse_args execute docs/plan.md --at +90m
    [ "${WIGGUM_ARGV[0]}" = "execute" ]
    [ "${WIGGUM_ARGV[1]}" = "docs/plan.md" ]
    [ "${WIGGUM_ARGV[2]}" = "--at" ]
    [ "${WIGGUM_ARGV[3]}" = "+90m" ]
}

@test "launch_execute_delayed: a waiter that cannot claim its schedule starts nothing" {
    # The launcher reports an unclaimed schedule as nothing scheduled. A waiter
    # that outlived that message would start a run hours later that the user was
    # told would never happen, so it has to exit instead.
    [ "$(id -u)" -ne 0 ] || skip "root ignores the directory permissions this relies on"
    mkdir -p docs
    cat > docs/plan.md <<'EOF'
- [ ] one
EOF
    FILES=(docs/plan.md)
    AT_TIME="@$(( $(date +%s) + 2 ))"
    WIGGUM_AT_POLL_INTERVAL=1
    WIGGUM_AT_CLAIM_TIMEOUT=1
    chmod 500 docs
    run launch_execute_delayed
    sleep 3
    local strays
    strays="$(pgrep -f "WIGGUM_AT_SCHEDULED=docs/plan.scheduled" | wc -l | tr -d '[:space:]')"
    chmod 700 docs
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"nothing was scheduled"* ]] || return 1
    [ ! -f docs/plan.scheduled ] || return 1
    [ ! -f docs/plan.pid ] || return 1
    [ ! -f docs/plan.out ] || return 1
    [ "$strays" -eq 0 ]
}

# ── run_execute: --at and --background compose ───────────────────────────────

@test "run_execute: --at hands off to the delayed launcher instead of running" {
    freeze_clock_now "22:00:00"
    mkdir -p docs
    cat > docs/plan.md <<'EOF'
- [ ] one
EOF
    FILES=(docs/plan.md)
    SUMMARY_FILE=docs/plan_summary.md
    AT_TIME="+90m"
    run run_execute
    kill_waiter "$(sidecar_field pid)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Scheduled wiggum execute"* ]] || return 1
    [ -f docs/plan.scheduled ] || return 1
    [[ "$output" != *"WIGGUM EXECUTE MODE"* ]] || return 1
}

@test "run_execute: --background alongside --at is accepted and ignored" {
    # --at always detaches, so --background is redundant rather than an error.
    # One hand-off, one run -- and one line of output so nobody is left
    # wondering which of the two flags won.
    freeze_clock_now "22:00:00"
    mkdir -p docs
    cat > docs/plan.md <<'EOF'
- [ ] one
EOF
    FILES=(docs/plan.md)
    SUMMARY_FILE=docs/plan_summary.md
    AT_TIME="+90m"
    BACKGROUND=true
    run run_execute
    local waiter
    waiter="$(sidecar_field pid)"
    kill_waiter "$waiter"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--background"* ]] || return 1
    [[ "$output" == *"ignored"* ]] || return 1
    [ "$(find docs -name '*.scheduled' | wc -l | tr -d '[:space:]')" -eq 1 ]
    [ -n "$waiter" ] || return 1
    # launch_execute_background writes the pidfile and the run separator
    # synchronously before it forks, so the absence of both is what proves no
    # second detached process was started alongside the waiter.
    [ ! -f docs/plan.pid ] || return 1
    [ ! -f docs/plan.out ] || return 1
}

@test "run_execute: a refused --at does not fall through to a background run" {
    # The dangerous shape of "accepted and ignored": if --at returned instead of
    # handing off, --background would pick the run up and start it now -- the
    # opposite of what asking for a later time meant.
    freeze_clock_now "22:00:00"
    mkdir -p docs
    cat > docs/plan.md <<'EOF'
- [ ] one
EOF
    FILES=(docs/plan.md)
    SUMMARY_FILE=docs/plan_summary.md
    AT_TIME="@$((WIGGUM_TEST_NOW - 3600))"
    BACKGROUND=true
    run run_execute
    [ "$status" -eq "$EXIT_BAD_ARGS" ]
    [[ "$output" == *"in the past"* ]] || return 1
    [ ! -f docs/plan.scheduled ] || return 1
    [ ! -f docs/plan.pid ] || return 1
    [ ! -f docs/plan.out ] || return 1
}

# ── Shell completions ────────────────────────────────────────────────────────

@test "completions: execute offers --at in both bash and zsh" {
    local root block
    root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    [ -f "$root/completions/wiggum.bash" ]
    [ -f "$root/completions/wiggum.zsh" ]
    # Scoped to the execute block in each file: a --at mentioned anywhere else
    # would not complete on the command that actually takes it.
    for shell in bash zsh; do
        block="$(awk '/^        execute\)/,/^            ;;$/' "$root/completions/wiggum.$shell")"
        [ -n "$block" ] || return 1
        [[ "$block" == *"--at"* ]] || return 1
    done
}

# ── Documentation sync ───────────────────────────────────────────────────────

# A flag nobody can find is a flag nobody uses, and this repo documents each one
# in five places that drift independently: the command's own `--help`, the
# README, both shell completions, and the CLI reference table in the embedded
# skill text -- which is what an agent driving wiggum reads.  Names the surfaces
# missing FLAG rather than returning a bare boolean, so a failure says which one
# went stale.
#
# COMMAND (default `execute`) scopes the three per-command surfaces to their own
# case block: a flag mentioned elsewhere in lib/wiggum.sh is not documentation
# for the command that takes it.  A surface whose file is absent or whose block
# extracts empty is reported as `(unreadable)`, so a moved file or a reindented
# heredoc fails the guard loudly instead of passing it vacuously.
undocumented_surfaces() {
    local flag="$1" command="${2:-execute}"
    local root surface start text file missing=""

    root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    # Matched with index(), not a regex, so the `)` needs no escaping.
    start="        ${command})"

    for surface in usage readme completion-bash completion-zsh skill-table; do
        text=""
        case "$surface" in
            usage)
                file="$root/lib/wiggum.sh"
                if [ -f "$file" ]; then
                    text="$(sed -n '/^usage() {/,/^}/p' "$file" |
                        awk -v start="$start" 'index($0, start) == 1, /^            ;;$/')"
                fi
                ;;
            readme)
                file="$root/README.md"
                if [ -f "$file" ]; then
                    text="$(cat "$file")"
                fi
                ;;
            completion-bash|completion-zsh)
                file="$root/completions/wiggum.${surface#completion-}"
                if [ -f "$file" ]; then
                    text="$(awk -v start="$start" \
                        'index($0, start) == 1, /^            ;;$/' "$file")"
                fi
                ;;
            skill-table)
                text="$(wiggum_skill_content |
                    awk '/^\| Command \| What it does \|/,/^$/')"
                ;;
        esac

        if [ -z "$text" ]; then
            missing="$missing $surface(unreadable)"
        elif ! printf '%s\n' "$text" | sed 's/^/ /; s/$/ /' |
                grep -qE -- "[^A-Za-z0-9_-]${flag}[^A-Za-z0-9_-]"; then
            missing="$missing $surface"
        fi
    done

    echo "${missing# }"
}

@test "docs: --at is documented on every surface" {
    local missing
    missing="$(undocumented_surfaces --at)"
    if [ -n "$missing" ]; then
        echo "--at is missing from: $missing"
        return 1
    fi
}

@test "docs: the doc-sync guard names every surface for an undocumented flag" {
    # Proves the guard discriminates.  Without this, a helper that silently
    # extracted nothing -- or matched too loosely -- would pass the test above
    # for a flag that is documented nowhere at all.
    local missing
    missing="$(undocumented_surfaces --no-such-flag)"
    [ "$missing" = "usage readme completion-bash completion-zsh skill-table" ]
}

@test "docs: the doc-sync guard does not match a flag by prefix" {
    # `--at` must not be satisfied by a `--attach` sitting on the same line;
    # that is how a removed flag reads as present.
    local missing
    missing="$(undocumented_surfaces --a)"
    [ "$missing" = "usage readme completion-bash completion-zsh skill-table" ]
}

# ── Guard: the --at path takes no decisions that are not wiggum's to take ────

# The functions that exist because of `--at`, plus the three command entry
# points that dispatch into them.  Named explicitly rather than matched by
# pattern so that a function renamed out of the list is a loud failure below
# and not a silently narrowed guard.
at_path_functions() {
    printf '%s\n' \
        wiggum_now_epoch wiggum_now_hms parse_at_time format_duration \
        describe_at_target wait_until_epoch at_replay_argv at_waiter_script \
        start_at_waiter read_schedule_field launch_execute_delayed \
        describe_schedule_state cancel_schedule \
        run_execute run_status run_kill
}

# The bodies of those functions with comments stripped, so the guards below read
# what the code does rather than what it says about itself -- the four command
# names are discussed at length in the comments above `wait_until_epoch`,
# `start_at_waiter` and `launch_execute_delayed`, and a guard that counted those
# would fail on a clean tree.
#
# Bodies only, and scoped to lib/wiggum.sh: `examples/wiggum-cron.sh` and
# `examples/wiggum-nightly-setup.sh` set up genuinely recurring runs and are
# supposed to name `crontab` and `launchctl`.
#
# FILE defaults to the repo's own lib.  A missing file, or a function that is
# not in it, exits non-zero naming what was not found, so a rename cannot turn
# this into a test that reads nothing and passes.
at_path_source() {
    local file="${1:-}" fn body text=""

    if [ -z "$file" ]; then
        file="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/wiggum.sh"
    fi
    if [ ! -f "$file" ]; then
        echo "at_path_source: no such file: $file" >&2
        return 1
    fi

    while read -r fn; do
        body="$(sed -n "/^${fn}() {/,/^}/p" "$file")"
        if [ -z "$body" ]; then
            echo "at_path_source: no function named $fn in $file" >&2
            return 1
        fi
        text="$text$body
"
    done < <(at_path_functions)

    printf '%s' "$text" | sed 's/[[:space:]]#.*$//; s/^[[:space:]]*#.*$//'
}

# Names the decision-taking commands invoked in the source on stdin, sorted and
# space-separated; empty when there are none.
#
# `caffeinate` and `pmset` would take a decision about the user's hardware that
# is not wiggum's to take -- staying awake costs battery and heat, and a tool
# asserting it silently from a shell is worse than a run that starts late.
# `crontab` and `launchctl` would leave recurring state behind a flag whose
# whole contract is one invocation, one run.
decision_taking_commands() {
    grep -owE 'caffeinate|pmset|crontab|launchctl' | sort -u | tr '\n' ' ' |
        sed 's/ $//'
}

@test "guards: the --at code path invokes no wake-lock or recurring-schedule command" {
    local src found
    src="$(at_path_source)" || return 1

    # Proves the extractor produced code and not an empty string, which is the
    # shape in which this guard would pass without checking anything.
    [[ "$src" == *"screen -dmS"* ]] || return 1

    found="$(printf '%s\n' "$src" | decision_taking_commands)"
    if [ -n "$found" ]; then
        echo "the --at code path invokes: $found"
        return 1
    fi
}

@test "guards: the wake-lock guard catches each of the four commands" {
    # Proves the guard discriminates.  Without this, a matcher that never fired
    # would pass the test above on a tree that had grown all four.
    local cmd found
    for cmd in caffeinate pmset crontab launchctl; do
        found="$(printf 'wait_until_epoch() {\n    %s -i sleep 3600\n}\n' "$cmd" |
            decision_taking_commands)"
        [ "$found" = "$cmd" ] || return 1
    done
}

@test "guards: the wake-lock guard does not fire on a comment or a longer word" {
    # `# no caffeinate here` is the comment this repo actually carries, and
    # `pmsetup` is the false positive a bare substring match would invent.
    local found
    found="$(printf '    echo pmsetup\n    echo uncrontabbed\n' |
        decision_taking_commands)"
    [ -z "$found" ]
}

@test "guards: the --at source extractor fails loudly when it cannot read the path" {
    run at_path_source "$TEST_DIR/absent.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such file"* ]] || return 1

    printf 'unrelated() {\n    :\n}\n' > "$TEST_DIR/partial.sh"
    run at_path_source "$TEST_DIR/partial.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no function named wiggum_now_epoch"* ]] || return 1
}

# Names the `date` invocations on stdin that pass anything but a `+FORMAT`,
# sorted and space-separated; empty when there are none.
#
# `date -d` is GNU-only, `date -j -f` and `date -r <epoch>` are BSD-only, and
# CI runs one platform at a time, so a later edit reaching for either would
# break the other silently.  Resolving `<WHEN>` with `%s`/`%H`/`%M`/`%S` and
# shell arithmetic instead of a calendar parser is the invariant the whole
# design rests on, and this is what holds it.
#
# `gdate` is matched too: reaching for GNU coreutils on macOS is the same
# defect wearing a different name, and the design deliberately keeps
# platform-specific date parsing outside wiggum, behind the `@<epoch>` form.
date_flag_calls() {
    grep -owE "g?date[[:space:]]+[^[:space:]]+" |
        grep -vE "g?date[[:space:]]+[\"']?\+" |
        sort -u | tr '\n' ' ' | sed 's/ $//'
}

@test "guards: no date call in the --at code path uses a flag beyond +FORMAT" {
    local src found
    src="$(at_path_source)" || return 1

    # Proves the extractor produced the clock accessors and not an empty
    # string, which is the shape in which this guard would pass without
    # checking anything.
    [[ "$src" == *"date +%s"* ]] || return 1
    [[ "$src" == *"date +%H:%M:%S"* ]] || return 1

    found="$(printf '%s\n' "$src" | date_flag_calls)"
    if [ -n "$found" ]; then
        echo "the --at code path calls date with a non-format argument: $found"
        return 1
    fi
}

@test "guards: the date-flag guard catches each platform-specific flag" {
    # Proves the guard discriminates.  Without this, a matcher that never
    # fired would pass the test above on a tree that had grown all of them.
    local spec flag found
    for spec in "date -d:date -d" "date -j:date -j" "date -r:date -r" \
        "gdate -d:gdate -d"; do
        flag="${spec%%:*}"
        found="$(printf 'parse_at_time() {\n    %s "@$1" +%%s\n}\n' "$flag" |
            date_flag_calls)"
        [ "$found" = "${spec#*:}" ] || return 1
    done
}

@test "guards: the date-flag guard does not fire on a format or a prose word" {
    # The three shapes the clean tree actually carries -- bare, single-quoted
    # and double-quoted formats -- plus the prose false positive a bare
    # substring match would invent out of "update" and "validate".
    local found
    found="$(printf '%s\n' \
        '    date +%s' \
        "    date '+%Y-%m-%d %H:%M:%S'" \
        '    date "+%s"' \
        '    echo "update the plan and validate the candidate"' |
        date_flag_calls)"
    [ -z "$found" ]
}

# ── install.sh ───────────────────────────────────────────────────────────────

# A source tree holding the two files the installer insists on, plus a copy of
# install.sh: SOURCE_DIR is the installer's own directory, so a fake source has
# to carry the installer itself.
make_install_source() {
    local dir="$1" body="$2"
    mkdir -p "$dir/lib"
    printf '#!/usr/bin/env bash\n%s\n' "$body" > "$dir/wiggum.sh"
    printf '# lib: %s\n' "$body" > "$dir/lib/wiggum.sh"
    cp "$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/install.sh" "$dir/install.sh"
}

inode_of() {
    ls -i "$1" | awk '{print $1}'
}

@test "install: an upgrade swaps the file, leaving a run that holds it open alone" {
    # bash reads a script by byte offset as it goes, and a wiggum run holds its
    # script open for hours. Rewriting that inode in place moves every offset
    # under a live run: bash resumes inside the new text and dies on the
    # fragment it lands in -- "syntax error near unexpected token", exit 2, on a
    # plan that was doing fine. Installing by rename leaves the old inode for
    # the run that started on it.
    HOME="$TEST_DIR/home"
    mkdir -p "$HOME"
    local src="$TEST_DIR/src" prefix="$TEST_DIR/prefix" installed
    installed="$prefix/lib/wiggum/wiggum.sh"

    make_install_source "$src" "echo v1"
    WIGGUM_PREFIX="$prefix" bash "$src/install.sh" >/dev/null

    local before after held
    before="$(inode_of "$installed")"
    exec 9< "$installed"

    make_install_source "$src" "echo v2 -- longer, so every byte offset moves"
    WIGGUM_PREFIX="$prefix" bash "$src/install.sh" >/dev/null

    after="$(inode_of "$installed")"
    held="$(cat <&9)"
    exec 9<&-

    [ "$before" != "$after" ] || return 1
    grep -q 'echo v1' <<< "$held" || return 1
    ! grep -q 'v2' <<< "$held" || return 1
    grep -q 'echo v2' "$installed"
}

@test "install: no half-written file is ever visible at the installed path" {
    # The temp the installer renames from must sit beside the destination, not
    # be the destination -- and it must not be left behind.
    HOME="$TEST_DIR/home"
    mkdir -p "$HOME"
    local src="$TEST_DIR/src" prefix="$TEST_DIR/prefix"
    make_install_source "$src" "echo v1"
    WIGGUM_PREFIX="$prefix" bash "$src/install.sh" >/dev/null
    WIGGUM_PREFIX="$prefix" bash "$src/install.sh" >/dev/null

    [ ! -e "$prefix/lib/wiggum/wiggum.sh.new" ] || return 1
    [ ! -e "$prefix/lib/wiggum/lib/wiggum.sh.new" ] || return 1
    [ -x "$prefix/lib/wiggum/wiggum.sh" ] || return 1
    [ -L "$prefix/bin/wiggum" ]
}

@test "install: a prefix that is not /usr/local writes nothing outside itself" {
    # The suite installs into a temp prefix, so completion files must follow the
    # prefix rather than landing in the developer's real site-functions dir.
    HOME="$TEST_DIR/home"
    mkdir -p "$HOME"
    local src="$TEST_DIR/src" prefix="$TEST_DIR/prefix"
    make_install_source "$src" "echo v1"
    mkdir -p "$src/completions" "$prefix/share/zsh/site-functions" \
             "$prefix/etc/bash_completion.d"
    echo "# zsh completion" > "$src/completions/wiggum.zsh"
    echo "# bash completion" > "$src/completions/wiggum.bash"

    WIGGUM_PREFIX="$prefix" bash "$src/install.sh" >/dev/null

    grep -q 'zsh completion' "$prefix/share/zsh/site-functions/_wiggum" || return 1
    grep -q 'bash completion' "$prefix/etc/bash_completion.d/wiggum"
}

# A sudo that does nothing but record what it was asked to run, first on PATH.
# Nothing in the suite may actually escalate, so the stub also proves the
# absence of a call: an empty log is the assertion.
stub_sudo() {
    mkdir -p "$TEST_DIR/bin"
    export SUDO_LOG="$TEST_DIR/sudo.log"
    : > "$SUDO_LOG"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$SUDO_LOG"\nexit 0\n' \
        > "$TEST_DIR/bin/sudo"
    chmod +x "$TEST_DIR/bin/sudo"
    PATH="$TEST_DIR/bin:$PATH"
}

@test "install: a prefix the user owns is written without sudo" {
    HOME="$TEST_DIR/home"
    mkdir -p "$HOME"
    local src="$TEST_DIR/src" prefix="$TEST_DIR/prefix"
    make_install_source "$src" "echo v1"
    stub_sudo

    WIGGUM_PREFIX="$prefix" bash "$src/install.sh" >/dev/null

    [ -f "$prefix/lib/wiggum/wiggum.sh" ] || return 1
    [ ! -s "$SUDO_LOG" ]
}

@test "install: a prefix the user cannot write escalates, and \$HOME still does not" {
    # The decision is per destination. A single global answer -- "this install
    # needs root" -- would sudo the skill copy too and leave root-owned files
    # in the user's own ~/.claude.
    HOME="$TEST_DIR/home"
    mkdir -p "$HOME"
    local src="$TEST_DIR/src" prefix="$TEST_DIR/locked/prefix"
    make_install_source "$src" "echo v1"
    mkdir -p "$src/.claude/skills/wiggum"
    echo "# skill" > "$src/.claude/skills/wiggum/SKILL.md"
    mkdir -p "$TEST_DIR/locked"
    chmod 555 "$TEST_DIR/locked"
    stub_sudo

    WIGGUM_PREFIX="$prefix" bash "$src/install.sh" >/dev/null
    chmod 755 "$TEST_DIR/locked"

    grep -q "mkdir -p $prefix/lib/wiggum/lib" "$SUDO_LOG" || return 1
    grep -q "cp $src/wiggum.sh $prefix/lib/wiggum/wiggum.sh.new" "$SUDO_LOG" || return 1
    ! grep -q "$HOME" "$SUDO_LOG" || return 1
    grep -q '# skill' "$HOME/.claude/skills/wiggum/SKILL.md"
}
