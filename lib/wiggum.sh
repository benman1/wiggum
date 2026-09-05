#!/usr/bin/env bash
# wiggum core library — sourced by the CLI and by tests
# Do not execute directly; source this file instead.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "Error: lib/wiggum.sh is a library and must be sourced, not executed directly." >&2
    exit 1
fi

VERSION="0.1.0"

# ── Exit codes ──────────────────────────────────────────────────────────────

export EXIT_BAD_ARGS=1
export EXIT_NO_CONFIG=2
export EXIT_VALIDATION_FAILED=3
export EXIT_CLAUDE_FAILED=4
export EXIT_PLAN_FAILED=5

# ── Own location ────────────────────────────────────────────────────────────

# Where this library and the CLI that fronts it live. install.sh lays them out
# as <root>/wiggum.sh and <root>/lib/wiggum.sh, and the repo has the same
# shape, so one hop up from the library directory finds the entry point.
#
# The delayed waiter needs both: it is a fresh process in a session of its own,
# so it inherits no shell functions and has to re-source the library and
# re-invoke the CLI rather than calling either in place.
WIGGUM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIGGUM_LIB_PATH="$WIGGUM_LIB_DIR/$(basename "${BASH_SOURCE[0]}")"
WIGGUM_CLI="${WIGGUM_CLI:-$(cd "$WIGGUM_LIB_DIR/.." && pwd)/wiggum.sh}"

# ── State (reset by wiggum_reset for testing) ───────────────────────────────

wiggum_reset() {
    MODE=""
    # The argv this process was invoked with, captured by parse_args. A
    # delayed run replays it in a detached process, so it has to outlive the
    # parse that produced it.
    WIGGUM_ARGV=()
    FILES=()
    PLAN_FILE=""
    SUMMARY_FILE=""
    EXPLAIN_FILE=""
    QUEUE_FILE=""
    TOP_JSON=false
    NO_FEEDBACK=false
    MAX_ITERATIONS=30
    MAX_VALIDATION_RETRIES=5
    MAX_STALL_COUNT=2
    CLAUDE_RETRIES=2
    INIT_PRESET=""
    VERIFY_STEPS=()
    BENCHMARK_SCRIPTS=()
    VERBOSE=false
    WIGGUM_SHOW_OUTPUT=false
    CLAUDE_EXTRA_ARGS=()
    CLI_MAX_ITERATIONS=""
    CLI_MAX_RETRIES=""
    CLI_CLAUDE_RETRIES=""
    UPDATE_DOCS=()
    DOCS_INPUT=()
    DOCS_OUTPUT=()
    # The `.pid` sidecar this run claimed, if it claimed one. Empty means
    # unclaimed: the run has not started, or a launcher already wrote the
    # sidecar on its behalf and this process must not touch it.
    WIGGUM_RUN_PIDFILE=""
    WIGGUM_LOG_FILE=""
    STDIN_FILE=""
    CLI_PLAN_FILE=""
    NO_VERIFY=false
    NO_COMMIT=false
    CLI_NO_VERIFY=""
    CLI_NO_COMMIT=""
    EFFORT="xhigh"
    CLI_EFFORT=""
    PERMISSION_MODE="bypassPermissions"
    CLI_PERMISSION_MODE=""
    RUN_PROMPTS=()
    RUN_PROMPTS_FILE=""
    RUN_SESSION_FILE=""
    RUN_NEW_SESSION=false
    RUN_DELIMITER="---"
    BACKGROUND=false
    # Exported the way VERBOSE is: the run --at schedules is detached
    # into a child process, so the spec has to cross that boundary to
    # stay reportable from the waiter.
    export AT_TIME=""
    WATCH_TIMEOUT=0
    WATCH_POLL=5
    KILL_ON_TIMEOUT=false
}

wiggum_reset

# ── Value validation ─────────────────────────────────────────────────────────

# Valid effort levels accepted by `claude --effort`.
validate_effort() {
    case "${1:-}" in
        low|medium|high|xhigh|max) return 0 ;;
        *) return 1 ;;
    esac
}

# Valid permission modes accepted by `claude --permission-mode`.
validate_permission_mode() {
    case "${1:-}" in
        acceptEdits|auto|bypassPermissions|default|dontAsk|plan) return 0 ;;
        *) return 1 ;;
    esac
}

# ── Clock ────────────────────────────────────────────────────────────────────

# The wall clock, read through two accessors so a test can inject a fixed time
# by overriding them -- the same trick test/wiggum.bats uses to stub `claude`.
#
# Both call `date` with nothing but a `+FORMAT` argument. `date -d` is GNU-only
# and `date -j` and `date -r` are BSD-only, so any of them would break the other
# platform silently. Keeping every clock read flagless is what lets the delayed
# execution path resolve a time with plain arithmetic instead of a date parser.
#
# `%s` is the one portability assumption: it is absent from POSIX but present in
# BSD, GNU and busybox `date`. `%H`, `%M` and `%S` are specified by POSIX.

wiggum_now_epoch() {
    date +%s
}

wiggum_now_hms() {
    date +%H:%M:%S
}

# Resolve a `--at <WHEN>` spec to an absolute epoch on stdout.  Returns
# non-zero and writes nothing at all on anything it does not recognise, so a
# caller substituting the output cannot silently end up with an empty string.
#
# Three forms, chosen so that none of them needs a date parser:
#
#   +<N>m|h|d   now plus N minutes, hours or days -- `sleep` and `at` durations
#   HH:MM       the next time the wall clock reads that, rolling to tomorrow
#               when it has already passed today -- `at 01:07`
#   @<epoch>    taken as-is
#
# The unit on the duration form is required.  A bare `+90` means seconds to
# `sleep` and minutes to `at`, and guessing between them is a sixtyfold error
# made silently; an error naming the three forms is cheaper.
#
# There is deliberately no calendar-date form.  Turning "Aug 30 01:07" into an
# epoch needs `date -d` (GNU) or `date -j -f` (BSD) and neither accepts the
# other's syntax, which is the platform branch this design exists to avoid.
# `@<epoch>` is the escape hatch: produce the epoch with whatever your own
# platform gives you and hand that over, keeping date parsing outside wiggum.
#
# One accepted inaccuracy: HH:MM resolves to "now plus the seconds until that
# clock time", so on the two nights a year a DST transition falls inside the
# wait, the target lands an hour early or late.  Fixing that needs the calendar
# parsing above, so it is documented rather than branched for.
#
# Every field is forced to base 10.  `08` and `09` are invalid octal, and an
# unprefixed `$((08))` under `set -e` would kill the run on a valid input --
# for the *current* time as much as the requested one, since wiggum_now_hms
# zero-pads as well.
parse_at_time() {
    local spec="${1:-}"
    local now
    now="$(wiggum_now_epoch)"

    case "$spec" in
        @*)
            local epoch="${spec#@}"
            [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
            # An epoch in the past resolves rather than erroring, so the caller
            # can report "that time has passed" instead of "unrecognised".
            printf '%s\n' "$((10#$epoch))"
            return 0
            ;;
        +*)
            local rest="${spec#+}"
            [[ "$rest" =~ ^([0-9]+)([mhd])$ ]] || return 1
            local amount="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}"
            local seconds
            case "$unit" in
                m) seconds=60 ;;
                h) seconds=3600 ;;
                d) seconds=86400 ;;
            esac
            printf '%s\n' "$((now + 10#$amount * seconds))"
            return 0
            ;;
        *:*)
            [[ "$spec" =~ ^([0-9][0-9]):([0-9][0-9])$ ]] || return 1
            local hh="${BASH_REMATCH[1]}" mm="${BASH_REMATCH[2]}"
            [ "$((10#$hh))" -le 23 ] || return 1
            [ "$((10#$mm))" -le 59 ] || return 1

            local now_hms
            now_hms="$(wiggum_now_hms)"
            [[ "$now_hms" =~ ^([0-9][0-9]):([0-9][0-9]):([0-9][0-9])$ ]] || return 1
            local now_h="${BASH_REMATCH[1]}" now_m="${BASH_REMATCH[2]}" now_s="${BASH_REMATCH[3]}"

            local delta
            delta=$(( (10#$hh * 3600 + 10#$mm * 60)
                      - (10#$now_h * 3600 + 10#$now_m * 60 + 10#$now_s) ))
            # At or before the current second means tomorrow: somebody typing
            # the time it already is means tonight, not this instant.
            if [ "$delta" -le 0 ]; then
                delta=$((delta + 86400))
            fi
            printf '%s\n' "$((now + delta))"
            return 0
            ;;
    esac

    return 1
}

# Render a span of seconds compactly -- `45s`, `1m 30s`, `3h 7m`, `2d 6h` --
# for the "in <duration>" half of a scheduled run's report. Two units is the
# most anyone reads off a schedule line; the rest is noise at this precision.
format_duration() {
    local secs="${1:-0}"
    if [ "$secs" -lt 0 ]; then
        secs=0
    fi
    local days=$((secs / 86400))
    local hours=$(((secs % 86400) / 3600))
    local mins=$(((secs % 3600) / 60))
    local rest=$((secs % 60))

    if [ "$days" -gt 0 ]; then
        printf '%dd %dh\n' "$days" "$hours"
    elif [ "$hours" -gt 0 ]; then
        printf '%dh %dm\n' "$hours" "$mins"
    elif [ "$mins" -gt 0 ]; then
        printf '%dm %ds\n' "$mins" "$rest"
    else
        printf '%ds\n' "$rest"
    fi
}

# Render a target epoch as a local wall-clock time -- `01:07:00 tomorrow`.
#
# Derived by arithmetic from the two clock accessors rather than by formatting
# the epoch, because turning an epoch back into a calendar time needs `date -r`
# (BSD) or `date -d @` (GNU) and neither exists on the other platform. Same
# trade parse_at_time makes, and the same accepted inaccuracy: a DST transition
# between now and the target shifts the rendering by an hour.
#
# The day arithmetic floors rather than truncates, so a target in the past
# reads as `yesterday` instead of collapsing onto `today` -- which is what lets
# a missed schedule be reported as missed.
describe_at_target() {
    local target="${1:-}"
    [[ "$target" =~ ^-?[0-9]+$ ]] || return 1

    local now now_hms
    now="$(wiggum_now_epoch)"
    now_hms="$(wiggum_now_hms)"
    [[ "$now_hms" =~ ^([0-9][0-9]):([0-9][0-9]):([0-9][0-9])$ ]] || return 1

    local now_sod
    now_sod=$(( 10#${BASH_REMATCH[1]} * 3600
                + 10#${BASH_REMATCH[2]} * 60
                + 10#${BASH_REMATCH[3]} ))

    local total=$((now_sod + target - now))
    local sod=$(( (total % 86400 + 86400) % 86400 ))
    local days=$(( (total - sod) / 86400 ))

    local when
    case "$days" in
        0)  when="today" ;;
        1)  when="tomorrow" ;;
        -1) when="yesterday" ;;
        -*) when="${days#-} days ago" ;;
        *)  when="in $days days" ;;
    esac

    printf '%02d:%02d:%02d %s\n' \
        "$((sod / 3600))" "$(((sod % 3600) / 60))" "$((sod % 60))" "$when"
}

# ── Config loading ───────────────────────────────────────────────────────────

# Strip leading and trailing whitespace, leaving the value otherwise intact.
#
# Deliberately not `echo "$s" | xargs`: xargs parses its input as shell-ish
# words, so quotes and backslashes are syntax to it rather than data. On real
# .wiggumrc values that silently rewrites the command being configured —
# `pytest -k "not slow"` loses its quotes and runs as `pytest -k not slow`,
# `grep \d file` loses the backslash, and a lone apostrophe makes xargs abort
# with "unmatched single quote", truncating the value to its first word.
# Parameter expansion touches whitespace only.
trim_whitespace() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

find_config() {
    if [[ -f ".wiggumrc" ]]; then
        echo ".wiggumrc"
    elif [[ -f "$HOME/.wiggumrc" ]]; then
        echo "$HOME/.wiggumrc"
    fi
}

load_config_from() {
    local config_file="$1"

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        local key="${line%%=*}"
        local value="${line#*=}"
        key="$(trim_whitespace "$key")"
        value="$(trim_whitespace "$value")"

        case "$key" in
            verify|autofix|benchmark|iterations|max_iterations|max_validation_retries|claude_retries|skip_verify|skip_commit|effort|permission_mode)
                echo "$key=$value"
                ;;
            *)
                echo "Warning: unknown config key '$key'" >&2
                ;;
        esac
    done < "$config_file"
}

apply_config() {
    local line
    while IFS= read -r line; do
        local key="${line%%=*}"
        local value="${line#*=}"
        case "$key" in
            verify)
                VERIFY_STEPS+=("$value")
                ;;
            autofix)
                VERIFY_STEPS+=("autofix:$value")
                ;;
            benchmark)
                BENCHMARK_SCRIPTS+=("$value")
                ;;
            iterations|max_iterations)
                if [[ -z "$CLI_MAX_ITERATIONS" ]]; then
                    MAX_ITERATIONS="$value"
                fi
                ;;
            max_validation_retries)
                if [[ -z "$CLI_MAX_RETRIES" ]]; then
                    MAX_VALIDATION_RETRIES="$value"
                fi
                ;;
            claude_retries)
                if [[ -z "$CLI_CLAUDE_RETRIES" ]]; then
                    CLAUDE_RETRIES="$value"
                fi
                ;;
            skip_verify)
                if [[ -z "$CLI_NO_VERIFY" ]]; then
                    case "$value" in
                        true|1|yes|on)   NO_VERIFY=true ;;
                        false|0|no|off)  NO_VERIFY=false ;;
                        *)
                            echo "Warning: invalid value for skip_verify: '$value' (expected true/false). Treating as false." >&2
                            NO_VERIFY=false
                            ;;
                    esac
                fi
                ;;
            skip_commit)
                if [[ -z "$CLI_NO_COMMIT" ]]; then
                    case "$value" in
                        true|1|yes|on)   NO_COMMIT=true ;;
                        false|0|no|off)  NO_COMMIT=false ;;
                        *)
                            echo "Warning: invalid value for skip_commit: '$value' (expected true/false). Treating as false." >&2
                            NO_COMMIT=false
                            ;;
                    esac
                fi
                ;;
            effort)
                if [[ -z "$CLI_EFFORT" ]]; then
                    if validate_effort "$value"; then
                        EFFORT="$value"
                    else
                        echo "Warning: invalid value for effort: '$value' (expected low/medium/high/xhigh/max). Keeping '$EFFORT'." >&2
                    fi
                fi
                ;;
            permission_mode)
                if [[ -z "$CLI_PERMISSION_MODE" ]]; then
                    if validate_permission_mode "$value"; then
                        PERMISSION_MODE="$value"
                    else
                        echo "Warning: invalid value for permission_mode: '$value' (expected acceptEdits/auto/bypassPermissions/default/dontAsk/plan). Keeping '$PERMISSION_MODE'." >&2
                    fi
                fi
                ;;
        esac
    done
}

load_config() {
    local config_file
    config_file="$(find_config)"

    if [[ -z "$config_file" ]]; then
        # Informational output must go to stderr. Otherwise it leaks into
        # downstream pipes (e.g. `wiggum plan X | wiggum execute`), where the
        # next command sees config chatter instead of a real plan.
        echo "No .wiggumrc found (checked ./ and ~/). Using defaults." >&2
        return
    fi

    echo "Loading config from $config_file" >&2
    apply_config < <(load_config_from "$config_file")
}

# ── Argument parsing ─────────────────────────────────────────────────────────

usage() {
    local cmd="${1:-}"

    case "$cmd" in
        init)
            cat <<EOF
wiggum init - Generate a .wiggumrc for a standard project setup

Usage:
  wiggum init [preset]

Presets:
  node      Node.js project (type-check, test, build, lint)
  next      Next.js project (type-check, test, build, lint)
  python    Python project (ruff, pytest)
  astro     Astro project (type-check, test, build, format)
  bash      Bash project (shellcheck, bats)
  (none)    Auto-detect from project files

Asks which Claude permission mode to write into .wiggumrc (auto, the
guardrailed default, or bypassPermissions). Also offers to set up Claude Code
permissions in .claude/settings.local.json and reminds you to create a
CLAUDE.md if one is missing.
EOF
            ;;
        plan)
            cat <<EOF
wiggum plan - Create a workplan from issue/spec files

Usage:
  wiggum plan <files...> [options]
  wiggum plan [options] < description.txt
  echo "description" | wiggum plan [options]

Options:
  --plan-file <path>   Output path for the plan (default: <base>_plan.md)
  --no-feedback        Skip the feedback pass over the finished plan
  --verbose            Show Claude output (suppressed by default)

Reads issue descriptions, specs, or requirements and produces a structured
markdown workplan with phases, tasks, acceptance criteria, and dependencies.
Does not modify your codebase.

A second pass then adds the context a reader needs to judge the plan, without
touching the work itself: an '## Open decisions' section naming the choices
still open with their options, trade-offs and effort, and a '## How this reaches
users' section naming the documentation, help text or web pages a user would
have to read to learn the feature exists. Same analysis as 'wiggum explain'.
'--no-feedback' skips it; a piped plan skips it automatically.

When no files are given, reads from stdin.

Examples:
  wiggum plan issues/login-bug.md
  wiggum plan issues/*.md --plan-file docs/sprint_plan.md
  echo "Add dark mode toggle" | wiggum plan
  wiggum plan <<< "Fix the login timeout bug"
EOF
            ;;
        explain)
            cat <<EOF
wiggum explain - Explain what a plan or issue is worth, and what it leaves open

Usage:
  wiggum explain <files...> [options]
  wiggum explain [options] < plan.md

Options:
  --explain-file <path>  Write the explanation to a file instead of stdout
  --verbose              Show Claude output as it is produced

Read-only. Reads a workplan or issue file and answers four questions under four
headings: what it contains, what it is worth, how it reaches users (which docs,
help text or web pages would have to change for anyone to find out), and which
decisions are still open -- with each option's trade-offs and rough effort.

Changes nothing: no edits, no plan, no commit. This is the same analysis
'wiggum plan' folds into a plan it writes, available on demand for a plan
somebody else wrote, one already part-executed, or an issue nobody has planned.

When no files are given, reads from stdin.

Examples:
  wiggum explain docs/auth_plan.md
  wiggum explain issues/*.md --explain-file docs/auth_explained.md
  wiggum explain docs/auth_plan.md --verbose
EOF
            ;;
        execute)
            cat <<EOF
wiggum execute - Implement a workplan with iterative validation

Usage:
  wiggum execute <files...> [options]
  wiggum execute [options] < plan.md
  wiggum plan issue.md | wiggum execute

Options:
  --max-iterations <n>          Maximum implementation iterations (default: 30)
  --max-validation-retries <n>  Max fix attempts per verification step (default: 5)
  --claude-retries <n>          Retries when a claude session dies mid-run,
                                e.g. a dropped connection (default: 2; 0 disables)
  --summary-file <path>         Output path for the summary (default: <base>_summary.md)
  --benchmark <script>          Run script after each iteration, feed output to Claude (repeatable)
  --update-docs <files>         Comma-separated doc files to update after execution
  -b, --background              Run detached; write a pidfile and capture output
                                so 'wiggum status/watch/kill <plan>' can supervise it
  --at <WHEN>                   Wait until WHEN, then run once, detached; accepts
                                +90m (relative), 01:07 (the next such clock time)
                                or @1756180020 (epoch). Implies --background.
  --no-verify                   Skip wiggum's verification waterfall (Claude may
                                still run tests during implementation)
  --no-commit                   Skip every wiggum-issued git commit
  --verbose                     Show Claude output (suppressed by default)

Verification steps:
  Loaded from .wiggumrc. Each step is run after implementation:
    verify  = <cmd>    Run command; fail if non-zero exit (e.g., pytest, npm test)
    autofix = <cmd>    Run command to fix, then re-run to verify (e.g., ruff check --fix)

Phases:
  1. Diagnostic & Status Sync - reconcile plan against repo state
  2. Iterative Implementation - implement, verify, commit, progress check
     Stops early when all tasks are checked off, or when no progress
     is made for 2 consecutive iterations.
  3. Summary & Alignment     - update plan checkboxes and issue ledger,
                                write summary
  4. Documentation Update     - update docs (if --update-docs is set)

When no files are given, reads from stdin.

Examples:
  wiggum execute docs/plan.md
  wiggum execute docs/plan.md --max-iterations 5 --update-docs README.md
  wiggum execute docs/plan.md --background    # then: wiggum watch docs/plan.md
  wiggum execute docs/plan.md --at 01:07      # run once tonight at 01:07
  wiggum plan issue.md | wiggum execute
  echo "Add dark mode" | wiggum plan | wiggum execute
EOF
            ;;
        status)
            cat <<EOF
wiggum status - Show task progress and run state for a plan

Usage:
  wiggum status <plan-file>

Reports how many tasks are done / remaining / dropped, and whether a run
started with 'wiggum execute --background' is currently running, appears
blocked (stalled or stuck in the validation waterfall), or has finished.
Read-only -- never starts or stops anything.

Examples:
  wiggum status docs/plan.md
EOF
            ;;
        watch)
            cat <<EOF
wiggum watch - Follow a background run until it finishes

Usage:
  wiggum watch <plan-file> [options]

Options:
  --timeout <seconds>     Stop watching after this long (0 = wait forever)
  --kill-on-timeout       On timeout, kill the run (only that run's process)
  --poll-interval <secs>  How often to poll for new output (default: 5)

Streams the run's output and blocks until it completes -- wiggum's "wait".
Exits 0 only if the run finished 'complete'; non-zero for stalled, incomplete,
or killed. Pair with 'wiggum execute --background' to launch then wait.

Examples:
  wiggum watch docs/plan.md
  wiggum watch docs/plan.md --timeout 1800 --kill-on-timeout
EOF
            ;;
        kill)
            cat <<EOF
wiggum kill - Stop a background run

Usage:
  wiggum kill <plan-file>

Kills the wiggum process recorded for this plan (and the claude subprocess it
spawned), then removes the pidfile. Targets only this run's process tree --
never a blanket kill of every wiggum/claude on the system.

Examples:
  wiggum kill docs/plan.md
EOF
            ;;
        chain)
            cat <<EOF
wiggum chain - Execute several workplans back to back

Usage:
  wiggum chain <plan-file...> [options]
  wiggum chain --queue <file> [options]

Runs 'wiggum execute' on each plan in order, each in a fresh session. Stops at
the first plan that fails so a broken step doesn't drag the rest down. Accepts
the same execution options as 'wiggum execute' (e.g. --max-iterations).

Options:
  --queue <file>       Read the plan list from a file instead of arguments

With plans as arguments the list is fixed when the chain starts. With --queue it
is re-read after every plan, so a line appended while the chain is working is
picked up when the current plan finishes. One path per line, '#' starts a
comment, blank lines ignored. A plan already run is not repeated even if the
file changes, and a queued path that does not exist when its turn comes stops
the chain rather than being skipped.

Because the list is on disk rather than in argv, a killed chain resumes by
running the same command again: delete the finished plans from the file first,
or leave them and let their tasks reconcile as already done.

Examples:
  wiggum chain docs/schema_plan.md docs/api_plan.md docs/ui_plan.md
  wiggum chain docs/*.plan.md --max-iterations 5
  wiggum chain --queue docs/queue.txt --max-iterations 12
  echo docs/extra_plan.md >> docs/queue.txt   # while the chain runs
EOF
            ;;
        top)
            cat <<EOF
wiggum top - List every wiggum run on this machine at a glance

Usage:
  wiggum top [dirs-or-plans...]

Prints one line per run: the plan, its pid (or '-' if not running), its state
(running / running (blocked) / scheduled for <time> / finished: <reason> / not
running), how long since the run last wrote anything, and a task tally.
Read-only -- never starts or stops anything.

Options:
  --json               Emit the same records as JSON instead of a table

ACTIVITY is the age of the newest sidecar write. It is what separates a long
task from a wedged one: both read 'running', and only the clock tells them
apart. With --json, 'pid' and 'idle_seconds' are null when absent rather than
'-', so a script can test for absence instead of parsing the table.

With no arguments it shows every run in flight anywhere on this machine,
whichever directory it was started from, plus every run with a sidecar in
'docs/' or the current directory (which is where finished runs are recorded).
A run outside the current project is shown by its absolute path, so the row
says which project it belongs to.

Every run announces itself while it works, foreground and background alike, so
a plan running inside 'wiggum chain' shows up too -- as the row for the plan
the chain is on right now.

Pass arguments to narrow the view to one place: a directory (scanned for
'*.pid' and '*.scheduled'), a plan file (its sidecars), or a sidecar itself.
Arguments turn the machine-wide listing off.

Note: a run drops its own pidfile when it ends, and 'watch'/'kill' clear one
too, so a finished foreground or chained run won't appear. An unwatched
background run lingers as 'finished: <reason>' until its next run.

Examples:
  wiggum top                # everything running, anywhere
  wiggum top plans/         # only what is in plans/
  wiggum top --json | jq -r '.[] | select(.state == "running") | .plan'
EOF
            ;;
        docs)
            cat <<EOF
wiggum docs - Update documentation from input files

Usage:
  wiggum docs -i <input...> -o <output...>

Options:
  -i <files...>   Input files (summaries, plans, changelogs, code)
  -o <files...>   Output doc files to update
  --verbose       Show Claude output (suppressed by default)

Reads input files for context, then updates each output file to reflect
the changes. Preserves existing structure and style.

Examples:
  wiggum docs -i docs/summary.md -o README.md
  wiggum docs -i docs/plan.md docs/summary.md -o README.md docs/API.md
EOF
            ;;
        check)
            cat <<EOF
wiggum check - Run verification waterfall and fix issues

Usage:
  wiggum check [options]

Options:
  --max-validation-retries <n>  Max fix attempts per step (default: 5)
  --no-commit                   Skip the post-fix wiggum commit
  --verbose                     Show Claude output (suppressed by default)

Note: --no-verify is rejected here -- it would make 'wiggum check' a no-op.

Runs the verify/autofix steps from .wiggumrc against the current codebase.
When a step fails, Claude is asked to fix the issue. Repeats up to
max_validation_retries times. Does not implement new features or commit.

Verification steps (from .wiggumrc):
  verify  = <cmd>    Run command; fail if non-zero exit (e.g., pytest)
  autofix = <cmd>    Run command to fix, then re-run to verify (e.g., ruff check --fix)

Useful after manual edits or before committing to ensure everything passes.

Examples:
  wiggum check
  wiggum check --verbose
  wiggum check --max-validation-retries 3
EOF
            ;;
        run)
            cat <<EOF
wiggum run - Feed a series of prompts to Claude in one continuous session

Usage:
  wiggum run <prompt...> [options]
  wiggum run -f <prompts-file> [options]
  command | wiggum run [options]

Options:
  -f, --prompts-file <path>   Read prompts from a file (split on delimiter lines)
  --session-file <path>       Persist/resume the session id across invocations
  --new-session               Ignore an existing --session-file and start fresh
  --delimiter <str>           Prompt separator line for -f/stdin (default: ---)
  --effort <level>            Reasoning effort: low|medium|high|xhigh|max (default: xhigh)
  --permission-mode <mode>    acceptEdits|auto|bypassPermissions|default|dontAsk|plan
  --verbose                   Pass --verbose to Claude Code

Runs each prompt in order. The first prompt starts a fresh session (or resumes
the one in --session-file); every later prompt continues the same session, so
Claude keeps full context between prompts. Claude's responses go to stdout;
wiggum status and session ids go to stderr.

Prompts can come from positional arguments (each argument is one prompt), a
file via -f, or stdin. In a file or on stdin, prompts are separated by a line
containing only the delimiter (default '---'), so prompts may span multiple
lines.

With --session-file, the session id is saved to that file and resumed on the
next run -- so a cron job can run a step now and follow up later in the same
session. Use --new-session to start over.

Examples:
  wiggum run "Summarize today's git log" "Draft release notes from it"
  wiggum run -f steps.txt --session-file .wiggum-session
  echo "What changed in the last commit?" | wiggum run
  # Cron: day 1 starts the session, day 2 follows up in it
  wiggum run --session-file .wiggum-session "Scaffold the API skeleton"
  wiggum run --session-file .wiggum-session "Now add auth to that API"
EOF
            ;;
        *)
            cat <<EOF
wiggum $VERSION - Self-driving agent loop

Usage:
  wiggum <command> [files...] [options]
  command | wiggum <command> [options]
  wiggum help <command>

Commands:
  init      Generate a .wiggumrc for a standard project setup
  plan      Create a workplan from issue/spec files
  explain   Explain a plan's worth and its open decisions (read-only)
  execute   Implement a workplan with iterative validation
  check     Run verification waterfall and fix issues
  docs      Update documentation from input files
  run       Feed a series of prompts to Claude in one continuous session
  status    Show task progress and run state for a plan
  watch     Follow a background run until it finishes (wait)
  kill      Stop a background run (only that run's process)
  chain     Execute several workplans back to back
  top       List every wiggum run on this machine at a glance

Run 'wiggum help <command>' for details on a specific command.

Options:
  --effort <level>          Reasoning effort: low|medium|high|xhigh|max (default: xhigh)
  --permission-mode <mode>  Claude permission mode (default: bypassPermissions)
  --verbose                 Show Claude output (suppressed by default)
  -h, --help                Show this help

Configuration:
  Place a .wiggumrc file in the current directory or \$HOME.
  See README.md for config format.
EOF
            ;;
    esac
}

parse_args() {
    # Snapshot the invocation before it is consumed. `--at` replays this in a
    # detached process later; reconstructing the command from the globals it
    # set would silently stop carrying every option added after this was
    # written.
    WIGGUM_ARGV=("$@")

    if [[ $# -eq 0 ]]; then
        usage
        return "$EXIT_BAD_ARGS"
    fi

    MODE="$1"
    shift

    if [[ "$MODE" == "-h" || "$MODE" == "--help" ]]; then
        usage
        return 0
    fi

    if [[ "$MODE" == "help" ]]; then
        usage "${1:-}"
        return 0
    fi

    case "$MODE" in
        plan|execute|explain|init|docs|check|run|status|watch|kill|chain|top) ;;
        *)
            echo "Error: unknown mode '$MODE'. Use 'plan', 'execute', 'explain', 'check', 'docs', 'run', 'status', 'watch', 'kill', 'chain', 'top', or 'init'." >&2
            return "$EXIT_BAD_ARGS"
            ;;
    esac

    if [[ "$MODE" == "init" ]]; then
        if [[ $# -gt 0 && ! "$1" == -* ]]; then
            INIT_PRESET="$1"
            shift
        fi
        return 0
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --plan-file)
                PLAN_FILE="$2"
                CLI_PLAN_FILE="$2"
                shift 2
                ;;
            --summary-file)
                SUMMARY_FILE="$2"
                shift 2
                ;;
            --iterations|--max-iterations)
                MAX_ITERATIONS="$2"
                CLI_MAX_ITERATIONS="$2"
                shift 2
                ;;
            --max-retries|--max-validation-retries)
                MAX_VALIDATION_RETRIES="$2"
                CLI_MAX_RETRIES="$2"
                shift 2
                ;;
            --claude-retries)
                CLAUDE_RETRIES="$2"
                CLI_CLAUDE_RETRIES="$2"
                shift 2
                ;;
            --verbose)
                export VERBOSE=true
                CLAUDE_EXTRA_ARGS+=("--verbose")
                shift
                ;;
            --effort)
                if validate_effort "${2:-}"; then
                    EFFORT="$2"
                    CLI_EFFORT="$2"
                    shift 2
                else
                    echo "Error: invalid --effort '${2:-}' (expected low/medium/high/xhigh/max)." >&2
                    return "$EXIT_BAD_ARGS"
                fi
                ;;
            --permission-mode)
                if validate_permission_mode "${2:-}"; then
                    PERMISSION_MODE="$2"
                    CLI_PERMISSION_MODE="$2"
                    shift 2
                else
                    echo "Error: invalid --permission-mode '${2:-}' (expected acceptEdits/auto/bypassPermissions/default/dontAsk/plan)." >&2
                    return "$EXIT_BAD_ARGS"
                fi
                ;;
            -f|--prompts-file)
                RUN_PROMPTS_FILE="$2"
                shift 2
                ;;
            --session-file)
                RUN_SESSION_FILE="$2"
                shift 2
                ;;
            --new-session)
                RUN_NEW_SESSION=true
                shift
                ;;
            --delimiter)
                RUN_DELIMITER="$2"
                shift 2
                ;;
            --explain-file)
                EXPLAIN_FILE="$2"
                shift 2
                ;;
            --queue)
                QUEUE_FILE="$2"
                shift 2
                ;;
            --json)
                TOP_JSON=true
                shift
                ;;
            --no-feedback)
                NO_FEEDBACK=true
                shift
                ;;
            -b|--background)
                BACKGROUND=true
                shift
                ;;
            --at)
                # Validated here rather than at launch so a typo costs nothing:
                # the spec is resolved again by the launcher, but a run
                # scheduled six hours out should not be the thing that
                # discovers the time was unreadable.  `${2:-}` keeps a missing
                # value from tripping `set -u`, and rejecting it stops the
                # shift from swallowing the option that follows.
                if parse_at_time "${2:-}" >/dev/null; then
                    AT_TIME="$2"
                    shift 2
                else
                    echo "Error: invalid --at '${2:-}' (expected +<N>m|h|d, HH:MM or @<epoch>; e.g. +90m, 01:07, @1756180020)." >&2
                    return "$EXIT_BAD_ARGS"
                fi
                ;;
            --timeout)
                WATCH_TIMEOUT="$2"
                shift 2
                ;;
            --poll-interval)
                WATCH_POLL="$2"
                shift 2
                ;;
            --kill-on-timeout)
                KILL_ON_TIMEOUT=true
                shift
                ;;
            --no-verify)
                NO_VERIFY=true
                CLI_NO_VERIFY=true
                shift
                ;;
            --no-commit)
                NO_COMMIT=true
                CLI_NO_COMMIT=true
                shift
                ;;
            --update-docs)
                IFS=',' read -ra UPDATE_DOCS <<< "$2"
                shift 2
                ;;
            --benchmark)
                BENCHMARK_SCRIPTS+=("$2")
                shift 2
                ;;
            -i)
                shift
                while [[ $# -gt 0 && "$1" != -* ]]; do
                    DOCS_INPUT+=("$1")
                    shift
                done
                ;;
            -o)
                shift
                while [[ $# -gt 0 && "$1" != -* ]]; do
                    DOCS_OUTPUT+=("$1")
                    shift
                done
                ;;
            -h|--help)
                # Show the help for the command actually being asked about, and
                # switch MODE so main() stops here. Without the switch, `wiggum
                # execute --help` printed help and then ran execute with no
                # files, dying on an unbound FILES[0].
                usage "$MODE"
                MODE="help"
                return 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                echo "Error: unknown option '$1'" >&2
                return "$EXIT_BAD_ARGS"
                ;;
            *)
                if [[ "$MODE" == "run" ]]; then
                    RUN_PROMPTS+=("$1")
                else
                    FILES+=("$1")
                fi
                shift
                ;;
        esac
    done

    # remaining args after -- are all files (or prompts, in run mode)
    while [[ $# -gt 0 ]]; do
        if [[ "$MODE" == "run" ]]; then
            RUN_PROMPTS+=("$1")
        else
            FILES+=("$1")
        fi
        shift
    done

    # run mode collects prompts (positional, -f, or stdin), not plan files
    if [[ "$MODE" == "run" ]]; then
        if [[ -n "$RUN_PROMPTS_FILE" ]]; then
            if [[ ! -r "$RUN_PROMPTS_FILE" ]]; then
                echo "Error: prompts file not found or unreadable: $RUN_PROMPTS_FILE" >&2
                return "$EXIT_BAD_ARGS"
            fi
            split_prompts "$RUN_PROMPTS_FILE"
        fi
        # No positional or -f prompts: read them from stdin if piped.
        if [[ ${#RUN_PROMPTS[@]} -eq 0 && ! -t 0 ]]; then
            local stdin_prompts
            stdin_prompts="$(mktemp "${TMPDIR:-/tmp}/wiggum_run.XXXXXX")"
            cat > "$stdin_prompts"
            split_prompts "$stdin_prompts"
            rm -f "$stdin_prompts"
        fi
        if [[ ${#RUN_PROMPTS[@]} -eq 0 ]]; then
            echo "Error: no prompts given. Pass prompts as arguments, with -f <file>, or via stdin." >&2
            return "$EXIT_BAD_ARGS"
        fi
        return 0
    fi

    # check mode needs no input files
    if [[ "$MODE" == "check" ]]; then
        return 0
    fi

    # A queued chain reads its plans from the queue file, so it takes no
    # positional arguments and must not fall through to the stdin branch below.
    if [[ -n "$QUEUE_FILE" ]]; then
        if [[ "$MODE" != "chain" ]]; then
            echo "Error: --queue is only valid for 'wiggum chain'." >&2
            return "$EXIT_BAD_ARGS"
        fi
        if [[ ${#FILES[@]} -gt 0 ]]; then
            echo "Error: pass plans either as arguments or with --queue, not both." >&2
            return "$EXIT_BAD_ARGS"
        fi
        if [[ ! -f "$QUEUE_FILE" ]]; then
            echo "Error: queue file not found: $QUEUE_FILE" >&2
            return "$EXIT_BAD_ARGS"
        fi
        return 0
    fi

    # top mode takes optional scan targets (dirs/plans/pidfiles) in FILES; they
    # need no file-existence validation (a directory would fail it).
    if [[ "$MODE" == "top" ]]; then
        return 0
    fi

    # docs mode uses -i/-o instead of positional files
    if [[ "$MODE" == "docs" ]]; then
        if [[ ${#DOCS_INPUT[@]} -eq 0 ]]; then
            echo "Error: docs mode requires -i <input files>." >&2
            return "$EXIT_BAD_ARGS"
        fi
        if [[ ${#DOCS_OUTPUT[@]} -eq 0 ]]; then
            echo "Error: docs mode requires -o <output doc files>." >&2
            return "$EXIT_BAD_ARGS"
        fi
        return 0
    fi

    if [[ ${#FILES[@]} -eq 0 ]]; then
        case "$MODE" in
            status|watch|kill)
                echo "Error: $MODE requires a plan file (e.g. wiggum $MODE docs/foo_plan.md)." >&2
                return "$EXIT_BAD_ARGS"
                ;;
            chain)
                echo "Error: chain requires one or more plan files." >&2
                return "$EXIT_BAD_ARGS"
                ;;
        esac
        if [[ -t 0 ]]; then
            echo "Error: no input files specified (or pipe text via stdin)." >&2
            return "$EXIT_BAD_ARGS"
        fi
        STDIN_FILE="$(mktemp "${TMPDIR:-/tmp}/wiggum_stdin.XXXXXX")"
        cat > "$STDIN_FILE"
        if [[ ! -s "$STDIN_FILE" ]]; then
            rm -f "$STDIN_FILE"
            echo "Error: stdin was empty." >&2
            return "$EXIT_BAD_ARGS"
        fi
        FILES+=("$STDIN_FILE")
    fi

    local work_dir
    work_dir="$(pwd)"
    for f in "${FILES[@]}"; do
        # stdin temp file is outside the project — skip validation for it
        if [[ "$f" == "$STDIN_FILE" ]]; then
            continue
        fi
        if [[ ! -f "$f" ]]; then
            echo "Error: file not found: $f" >&2
            return "$EXIT_BAD_ARGS"
        fi
        local abs_path
        abs_path="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
        if [[ "$abs_path" != "$work_dir"/* ]]; then
            echo "Error: file is outside the project directory: $f" >&2
            echo "Copy it into the repo first, e.g.: cp $f docs/" >&2
            return "$EXIT_BAD_ARGS"
        fi
    done
}

# ── Plan progress ────────────────────────────────────────────────────────────

# Markdown prefixes that can introduce a task checkbox line. A task is counted
# when one of these starts the line and is immediately followed by a `[ ]`/
# `[x]`/`[~]` box:
#   - `*` `+`   unordered list bullets (GitHub-flavored markdown task lists)
#   #..######   ATX headings -- Claude's planner sometimes emits tasks as
#               `### [ ] 1.2 Title` rather than bullets; those must still count
#   1. 2. 10.   ordered list items
# Matching only `-` silently undercounts the other forms and reports a false
# "0 remaining" / "complete". The trailing `\[[ xX~]\]` box is the strong
# disambiguator, so non-task headings (`## Phase 1`) and inline `[ ]` in prose
# are not matched. Used by every task-counting regex below so they stay
# consistent.
WIGGUM_TASK_PREFIX='(#{1,6}|[-*+]|[0-9]+\.)'

# Counts only `[ ]` -- pending tasks the agent should pick up.
# `[~]` is the dropped/abandoned state and is intentionally excluded;
# do not widen this regex to include it. Dropped tasks are terminal,
# like `[x]`, and counting them as remaining causes false stalls.
count_unchecked() {
    local count=0
    local f
    for f in "$@"; do
        if [[ -f "$f" ]]; then
            count=$((count + $(grep -cE "^[[:space:]]*${WIGGUM_TASK_PREFIX}[[:space:]]*\[ \]" "$f" || true)))
        fi
    done
    echo "$count"
}

# Count all task states across one or more plan files: `[ ]`, `[x]`/`[X]`,
# and `[~]` (dropped). Includes `[~]` so that
# total - unchecked - dropped == done holds.
count_total_tasks() {
    local count=0
    local f
    for f in "$@"; do
        if [[ -f "$f" ]]; then
            count=$((count + $(grep -cE "^[[:space:]]*${WIGGUM_TASK_PREFIX}[[:space:]]*\[[ xX~]\]" "$f" || true)))
        fi
    done
    echo "$count"
}

# Count only `[~]` -- tasks intentionally dropped/abandoned mid-plan.
count_dropped() {
    local count=0
    local f
    for f in "$@"; do
        if [[ -f "$f" ]]; then
            count=$((count + $(grep -cE "^[[:space:]]*${WIGGUM_TASK_PREFIX}[[:space:]]*\[~\]" "$f" || true)))
        fi
    done
    echo "$count"
}

# Build the phase-3 "dropped tasks" paragraph that gets appended to the
# summary prompt. Empty when no `[~]` lines exist, so plans that don't use
# the dropped marker get an unchanged phase-3 prompt. The leading `\n\n` is
# literal -- matches the conditional-context pattern used by
# `final_benchmark_context` in `run_execute`.
build_dropped_context() {
    local count
    count="$(count_dropped "$@")"
    if [[ "$count" -eq 0 ]]; then
        return 0
    fi
    local dropped_lines
    dropped_lines="$(grep -hE "^[[:space:]]*${WIGGUM_TASK_PREFIX}[[:space:]]*\[~\]" "$@" 2>/dev/null || true)"
    # `%s` keeps the literal `\n` backslashes intact -- matches the
    # conditional-context pattern in `run_execute`.
    printf '%s' "\\n\\nThere are $count dropped tasks (\`[~]\`). Render them in the summary under a \"What was dropped\" subsection, preserving the rationale recorded on each line. Do not re-mark \`[~]\` as \`[x]\` -- it is the terminal dropped state, not pending. The dropped lines are:\\n$dropped_lines"
}

# Threshold for the large-plan warning. Plans above this tend to stall and
# lose focus; the warning nudges the user to split them.
WIGGUM_LARGE_PLAN_THRESHOLD=40

# Emit a stderr warning if the combined task count across the given files
# exceeds WIGGUM_LARGE_PLAN_THRESHOLD. Always returns 0.
warn_if_plan_large() {
    local total
    total="$(count_total_tasks "$@")"
    if [[ "$total" -gt "$WIGGUM_LARGE_PLAN_THRESHOLD" ]]; then
        echo "Warning: plan has $total tasks (threshold: $WIGGUM_LARGE_PLAN_THRESHOLD). Large plans tend to stall and lose focus -- consider splitting into smaller, sequential workplans." >&2
    fi
    return 0
}

# ── Stdin persistence ────────────────────────────────────────────────────────

persist_stdin() {
    local dir="docs"
    mkdir -p "$dir"
    local dest="${dir}/stdin.md"
    cp "$STDIN_FILE" "$dest"
    echo "$dest"
}

# Trim surrounding whitespace (including newlines) from a chunk and, if it is
# non-empty, append it as one prompt to RUN_PROMPTS.
append_prompt_chunk() {
    local chunk="$1"
    chunk="${chunk#"${chunk%%[![:space:]]*}"}"   # strip leading whitespace
    chunk="${chunk%"${chunk##*[![:space:]]}"}"    # strip trailing whitespace
    if [[ -n "$chunk" ]]; then
        RUN_PROMPTS+=("$chunk")
    fi
}

# Split a file into prompts on lines equal to the delimiter ($RUN_DELIMITER,
# default "---"), appending each non-empty chunk to RUN_PROMPTS. Multi-line
# prompts are preserved; blank or whitespace-only chunks are skipped. Used by
# `wiggum run` for both -f files and piped stdin.
split_prompts() {
    local file="$1"
    local chunk="" line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$RUN_DELIMITER" ]]; then
            append_prompt_chunk "$chunk"
            chunk=""
        else
            chunk+="$line"$'\n'
        fi
    done < "$file"
    append_prompt_chunk "$chunk"
}

# Returns 0 if the file looks like a wiggum plan (has at least one markdown
# checkbox `- [ ]`/`- [x]` or one `#` heading). Returns 1 otherwise.
#
# Guards against a failure mode seen in the wild: upstream tools (another
# wiggum process, a shell function with stray `echo`, etc.) accidentally
# leak a few lines of chatter into the pipe feeding `wiggum execute`. A
# non-empty but non-plan input would otherwise be silently accepted,
# consuming Claude tokens on nonsense and stopping early with "0 tasks".
looks_like_plan() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    grep -qE "^[[:space:]]*${WIGGUM_TASK_PREFIX}[[:space:]]*\[[ xX]\]|^#" "$f"
}

# Returns 0 if any readable input file reads like a defect report, 1 otherwise.
#
# Gates the diagnosis sections of the planner prompt so a greenfield feature
# request is never pushed into inventing symptoms. Only strong signals count:
# weak words (`error`, `fail`, `missing`, `null` on their own) appear in
# ordinary feature specs and are deliberately excluded. Absent or unreadable
# paths are skipped silently, and an empty argument list returns 1.
DEFECT_SIGNAL_REGEX='bug|defect|regression|broken|breaks|crash|traceback|stack ?trace|incident|steps to reproduce|no longer|used to work|silently|wrong|incorrect|misreport'

input_describes_defect() {
    local f
    for f in "$@"; do
        [[ -f "$f" && -r "$f" ]] || continue
        if grep -qiE "$DEFECT_SIGNAL_REGEX" "$f" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# Derive a filename-safe slug from a file's first heading or first line.
# Falls back to a date stamp if nothing usable is found.
slugify() {
    local file="$1"
    local text=""
    # Try first markdown heading
    text="$(grep -m1 '^#' "$file" 2>/dev/null | sed 's/^#* *//')"
    # Fall back to first non-empty line
    if [[ -z "$text" ]]; then
        text="$(grep -m1 '.' "$file" 2>/dev/null)"
    fi
    # Lowercase, replace non-alnum with hyphens, trim, truncate
    text="$(echo "$text" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//' | cut -c1-50)"
    # Strip trailing hyphen from truncation
    text="${text%-}"
    if [[ -z "$text" ]]; then
        text="$(date +%Y-%m-%d)"
    fi
    echo "$text"
}

# ── Output filenames ─────────────────────────────────────────────────────────

derive_output_file() {
    local mode="$1"
    local base_file="$2"
    local current_value="${3:-}"

    if [[ -n "$current_value" ]]; then
        echo "$current_value"
        return
    fi

    local dir
    dir="$(dirname "$base_file")"
    local name
    name="$(basename "$base_file" .md)"

    case "$mode" in
        plan)    echo "${dir}/${name}_plan.md" ;;
        execute) echo "${dir}/${name}_summary.md" ;;
    esac
}

# ── Init ─────────────────────────────────────────────────────────────────────

detect_preset() {
    if [[ -f "next.config.js" || -f "next.config.ts" || -f "next.config.mjs" ]]; then
        echo "next"
    elif [[ -f "astro.config.mjs" || -f "astro.config.ts" ]]; then
        echo "astro"
    elif [[ -f "pyproject.toml" || -f "setup.py" || -f "requirements.txt" ]]; then
        echo "python"
    elif [[ -f "package.json" ]]; then
        echo "node"
    elif [[ -f ".wiggumrc" ]] && grep -q 'shellcheck\|bats' .wiggumrc 2>/dev/null; then
        echo "bash"
    elif [[ -f ".shellcheckrc" ]] || [[ -d "test" && -f "test/run.sh" ]]; then
        echo "bash"
    else
        echo ""
    fi
}

generate_rc() {
    local preset="$1"

    case "$preset" in
        node)
            cat <<'RCEOF'
# .wiggumrc - Node.js project
verify = npm run type-check
verify = npm test
verify = npm run build
autofix = npm run lint -- --fix

max_iterations = 30
max_validation_retries = 5
RCEOF
            ;;
        next)
            cat <<'RCEOF'
# .wiggumrc - Next.js project
verify = npm run type-check
verify = npm test
verify = npm run build
autofix = npm run lint -- --fix

max_iterations = 30
max_validation_retries = 5
RCEOF
            ;;
        python)
            cat <<'RCEOF'
# .wiggumrc - Python project
autofix = ruff format . && ruff check --fix .
verify = pytest

max_iterations = 30
max_validation_retries = 5
RCEOF
            ;;
        astro)
            cat <<'RCEOF'
# .wiggumrc - Astro project
verify = npm run type-check
verify = npm test
verify = npm run build
autofix = npx prettier --write .

max_iterations = 30
max_validation_retries = 5
RCEOF
            ;;
        bash)
            cat <<'RCEOF'
# .wiggumrc - Bash project
verify = shellcheck -s bash *.sh **/*.sh
verify = bats test/

max_iterations = 30
max_validation_retries = 5
RCEOF
            ;;
        *)
            echo "Error: unknown preset '$preset'." >&2
            echo "Available presets: node, next, python, astro, bash" >&2
            return "$EXIT_BAD_ARGS"
            ;;
    esac
}

# Ask which Claude permission mode wiggum should bake into .wiggumrc. Prints the
# chosen mode to stdout; all prompts go to stderr so the value can be captured
# with $(...). Defaults to `auto` (the recommended guardrailed mode) -- only an
# explicit `2`/`bypass`/`bypassPermissions` selects bypassPermissions.
prompt_permission_mode() {
    echo "" >&2
    echo "Which permission mode should wiggum use for its Claude runs?" >&2
    echo "  1) auto              Claude's auto-mode classifier decides each action (recommended)" >&2
    echo "  2) bypassPermissions runs every action with no checks (fastest, no guardrails)" >&2
    echo "Choose [1]: " >&2
    local answer
    read -r answer
    case "$answer" in
        2|bypass|bypassPermissions) echo "bypassPermissions" ;;
        *)                          echo "auto" ;;
    esac
}

run_init() {
    local preset="$INIT_PRESET"

    if [[ -z "$preset" ]]; then
        preset=$(detect_preset)
        if [[ -z "$preset" ]]; then
            echo "Could not auto-detect project type." >&2
            echo "Specify a preset: wiggum init <node|next|python|astro>" >&2
            return "$EXIT_BAD_ARGS"
        fi
        echo "Detected project type: $preset"
    fi

    if [[ -f ".wiggumrc" ]]; then
        echo "A .wiggumrc already exists in this directory. Overwrite? [y/N]"
        read -r answer
        if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
            echo "Aborted."
            return 0
        fi
    fi

    local perm_mode
    perm_mode="$(prompt_permission_mode)"

    generate_rc "$preset" > .wiggumrc
    printf '\npermission_mode = %s\n' "$perm_mode" >> .wiggumrc
    echo "Created .wiggumrc ($preset preset, permission_mode = $perm_mode)"

    # Offer to set up Claude Code permissions for verification commands
    setup_claude_permissions "$preset"

    # Install the /wiggum skill for Claude Code
    setup_wiggum_skill

    if [[ ! -f "CLAUDE.md" ]]; then
        echo ""
        echo "Tip: Create a CLAUDE.md file with project standards, architecture, and"
        echo "conventions. Wiggum passes it to Claude Code automatically, which helps"
        echo "Claude write code that fits your project. See the wiggum README for details."
    fi
}

setup_claude_permissions() {
    local preset="$1"
    local settings_file=".claude/settings.local.json"

    # Build the allow list based on preset
    local rules=()
    rules+=("Bash(git add *)")
    rules+=("Bash(git commit *)")
    rules+=("Bash(git status)")
    rules+=("Bash(git diff *)")

    # Extra rules for package manager access (opt-in)
    local extra_rules=()

    case "$preset" in
        node|next)
            rules+=("Bash(npm run *)")
            rules+=("Bash(npx *)")
            extra_rules+=("Bash(npm install *)")
            extra_rules+=("Bash(npm *)")
            ;;
        python)
            rules+=("Bash(ruff *)")
            rules+=("Bash(pytest *)")
            rules+=("Bash(pytest)")
            extra_rules+=("Bash(pip install *)")
            extra_rules+=("Bash(pip *)")
            ;;
        astro)
            rules+=("Bash(npm run *)")
            rules+=("Bash(npx *)")
            extra_rules+=("Bash(npm install *)")
            extra_rules+=("Bash(npm *)")
            ;;
        bash)
            rules+=("Bash(shellcheck *)")
            rules+=("Bash(bats *)")
            rules+=("Bash(chmod *)")
            ;;
    esac

    echo ""
    echo "Wiggum needs Claude Code permissions to run verification and git commands."
    echo "The following rules would be added to $settings_file:"
    echo ""
    for rule in "${rules[@]}"; do
        echo "  allow: $rule"
    done
    echo ""
    echo "Add these permissions? [y/N]"
    read -r answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        echo "Skipped. You can add permissions manually or approve them when prompted."
        return 0
    fi

    # Ask about package manager permissions separately
    if [[ ${#extra_rules[@]} -gt 0 ]]; then
        echo ""
        echo "Also allow package manager commands? (lets Claude install dependencies)"
        for rule in "${extra_rules[@]}"; do
            echo "  allow: $rule"
        done
        echo ""
        echo "Allow package manager access? [y/N]"
        read -r answer
        if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
            rules+=("${extra_rules[@]}")
        fi
    fi

    # Build JSON
    mkdir -p .claude

    if [[ -f "$settings_file" ]]; then
        # Merge new rules into existing file, preserving all other keys
        echo "Updating $settings_file"
        local new_rules_json="["
        local first=true
        for rule in "${rules[@]}"; do
            if [[ "$first" == "true" ]]; then
                first=false
            else
                new_rules_json="$new_rules_json,"
            fi
            new_rules_json="$new_rules_json\"$rule\""
        done
        new_rules_json="$new_rules_json]"

        python3 -c "
import json, sys
with open('$settings_file') as f:
    data = json.load(f)
new_rules = json.loads(sys.argv[1])
perms = data.setdefault('permissions', {})
existing = perms.get('allow', [])
merged = list(existing)
for r in new_rules:
    if r not in merged:
        merged.append(r)
perms['allow'] = merged
with open('$settings_file', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
" "$new_rules_json"
    else
        local json_rules=""
        for rule in "${rules[@]}"; do
            if [[ -n "$json_rules" ]]; then
                json_rules="$json_rules,"
            fi
            json_rules="$json_rules
      \"$rule\""
        done

        cat > "$settings_file" <<EOF
{
  "permissions": {
    "allow": [$json_rules
    ]
  }
}
EOF
    fi

    echo "Created $settings_file"
}

# Emit the current /wiggum skill markdown to stdout. This is the single source of
# truth for the skill -- setup_wiggum_skill uses it both to install a fresh copy
# and to detect (and offer to refresh) a stale copy from an older wiggum version.
wiggum_skill_content() {
    cat <<'SKILL_EOF'
---
name: wiggum
description: Orchestrate the wiggum CLI — create a workplan, run it, monitor it, wait for it, detect when it's blocked, kill it if it runs too long, and chain workplans together. Use for any non-trivial change you want planned, executed, verified, and committed through wiggum.
argument-hint: <issue, plan file, or "chain: plan-a.md plan-b.md">
---

# Wiggum: Orchestrator

You **drive the `wiggum` CLI** — you do not re-implement its loop yourself. Wiggum
is a self-driving agent loop (plan → implement → verify → commit). Your job is to
turn the request into a workplan, launch wiggum on it, supervise the run, and
report the outcome. Execute without asking for confirmation.

The request: **$ARGUMENTS**

## Preflight — one step, then act

This skill is the **authoritative reference for wiggum's interface**: the commands
and flags in "The CLI you drive" and the steps below are correct and current. Use
them verbatim — do **not** burn turns running `wiggum --help` / `wiggum help execute`
to re-derive syntax you already have here.

The only things you genuinely can't know up front are repo-specific, so do this
discovery **once, in a single command**, then proceed:

```
command -v wiggum && cat .wiggumrc 2>/dev/null && ls environment.yml .venv .nvmrc Gemfile poetry.lock uv.lock 2>/dev/null
```

- **wiggum on PATH?** If `command -v wiggum` is empty, tell the user to install it
  (`./install.sh` in the wiggum repo) and stop — do not hand-simulate the loop. Run
  from the target project root.
- **`.wiggumrc`** — wiggum reads it itself; you read it here only to learn the verify
  steps (and therefore which environment to activate). No config → wiggum just skips
  verification (still fine).
- **Activate the project's environment.** wiggum runs Claude's tools and the verify
  steps in your *current* shell. If the markers above show one — conda
  (`environment.yml`), a virtualenv/`.venv`, Poetry/uv (`poetry.lock`/`uv.lock`), a
  Node version (`.nvmrc`), Bundler (`Gemfile`), etc. — activate it in the same shell
  you launch from, *before* running, or tests/builds hit the wrong interpreter and
  fail spuriously. For unattended/background runs, prefer self-activating verify
  commands in `.wiggumrc` (e.g. `conda run -n <env> pytest`, `poetry run pytest`) so
  the run is reproducible no matter which shell starts it.

That's the whole preflight. Everything else you need is in this skill.

## The CLI you drive

| Command | What it does |
|---|---|
| `wiggum plan <issue-or-file> [--plan-file docs/<slug>_plan.md]` | Write a workplan, then add its open decisions and audience analysis. Does not touch code. |
| `wiggum explain <plan-or-issue>` | Explain what a plan contains, what it is worth to users, how they would find out about it, and which decisions are still open. Read-only. |
| `wiggum execute <plan> [--max-iterations N]` | Run the loop in the foreground (blocks). |
| `wiggum execute <plan> --background` | Run detached; writes `docs/<name>.pid` + `docs/<name>.out`. Returns immediately. |
| `wiggum execute <plan> --at <WHEN>` | Wait until WHEN, then run once, detached. WHEN is `+90m` (relative), `01:07` (the next such clock time) or `@1756180020` (epoch). Creates nothing recurring; `status` reports it as scheduled and `kill` cancels it. |
| `wiggum status <plan>` | Task counts + run state (not started / running / running but appears blocked / finished: \<reason\>). Read-only. |
| `wiggum watch <plan> [--timeout S] [--kill-on-timeout] [--poll-interval N]` | Stream output and block until the run finishes — this is "wait". |
| `wiggum kill <plan>` | Stop the run (only that run's process tree). |
| `wiggum chain <plan...> [--max-iterations N]` | Execute several plans in order; stop at the first failure. |
| `wiggum chain --queue <file>` | Same, but the plan list is read from a file and re-read after every plan, so appending a line adds work to a chain already running. |
| `wiggum top` | Every run at a glance: plan, pid, state, time since last activity, task tally. Blocked and running sort first. Read-only. |
| `wiggum top --json` | The same records as JSON, with `pid` and `idle_seconds` null when absent. Use this instead of parsing the table or asking `pgrep` about a process when the question is about a run. |

Sidecar files live next to the plan: `docs/<name>.pid`, `docs/<name>.out`,
`docs/<name>.log`. `status`/`watch`/`kill` all derive these from the plan path,
so always refer to a run by its **plan file**.

Always invoke these as `wiggum <command>` (e.g. `wiggum top`, `wiggum status`).
Wiggum's internals are shell functions named `run_top`, `run_status`, etc. — those
are **not** commands. Never call `run_top`/`run_status`/… directly: they only exist
inside wiggum's own process, so in any fresh shell (notably under `conda run …`)
they fail with `command not found`. The `wiggum` binary is the only entry point.

## Workflow

### 1. Classify the request

- **A wiggum run already in progress** — the user asks to check on / monitor /
  wait for / report on a run, or `wiggum status <plan>` shows `running`: do **not**
  start a new run. Attach to it with `wiggum watch <plan>` to follow it to
  completion (your "wait"), then report a summary (step 5). If you don't know which
  plan, run `wiggum top` — with no arguments it lists every run in flight
  anywhere on this machine, not only the ones under the current directory, so a
  run you started from another project still shows up. This is the common
  "what's my background run doing?" case.
- **An existing plan file** (path ending in `_plan.md`, or a markdown file full of
  `- [ ]` tasks): skip to step 3.
- **"chain: a.md b.md c.md"** or several plan paths: this is a chain — go to
  "Chaining" below.
- **An issue file or a free-text description**: create a plan first (step 2).

### 2. Create a wiggum-compatible workplan

Either run `wiggum plan "<issue or file>"` (it writes `docs/<slug>_plan.md`), or
write the plan yourself in the format below. A wiggum plan is a markdown checklist:

```markdown
# <Title>

## Expected benefits
1. <the outcome someone gets, in their terms — not the change being made>
   Signal: <the observable thing that shows it landed after shipping>
2. <the next benefit, ranked below the first> — **speculative**
   Signal: <what you would measure once it can be measured>

## Constraints
- In scope: <what this work will do>
- Out of scope: <what it deliberately will not do>
- Never do: <actions that would be wrong here>

## The shape of it
```mermaid
flowchart TD
    A["what somebody does"] --> B{"the decision<br/>this work changes"}
    B -- "the ordinary case" --> C["NEW: what the work adds"]
    B -- "the failure branch" --> D["what happens instead"]
```
<two or three sentences naming what the reader should take from it>

<!-- defect work only — omit all four sections for feature work -->
## Symptoms
- <what is observably wrong, in the terms of whoever sees it> — **observed**
- <what follows from the code but you have not seen happen> — **predicted**
- The tell: <the signal that separates this defect from the benign explanation>

## Root cause
1. <step from the entry point toward the failure> — `path:line`
2. <next step> — `path:line`

## Why existing verification missed it
<the blind spot, citing the tests that pass anyway; if a passing test pins the
buggy behaviour, name it>

## Blast radius
<what is affected — and explicitly what is unaffected, and why>

## Phase 1: <name>
Serves: benefits 1, 2
- [ ] <discrete task>
  Acceptance: <observable outcome — a passing test, a specific log line, a file
  that exists, a command that exits 0>. Never a feeling ("works", "looks right").
  Files: <best-effort paths this task creates or modifies>
- [ ] <next task>
  Acceptance: ...
  Files: ...

### Acceptance Criteria
**Happy Path** — Given <context>, When <action>, Then <observable outcome>.
**Edge Cases** — empty, boundary, or large inputs behave correctly.
**Error States** — invalid input or a failed/unavailable dependency fails safely
with a clear error.
**Non-Functional** — name an observable check (a benchmark command, a lint rule,
a measurable threshold), never a feeling.
```

Rules for a good plan:
- **Start from the benefits, not from the tasks.** The plan opens with
  `## Expected benefits`: a numbered list, most valuable first, of what the work is
  *for* — each one an outcome someone gets, never the change being made ("a failed
  verify names the offending file in one line" is a benefit; "refactor the error
  handler" is not). Each benefit gets a `Signal:` line — the observable thing that
  shows it landed *after shipping* (a number that moves, an error that stops
  appearing, a manual step nobody performs any more) — and a benefit you can't
  measure yet is marked **speculative** rather than dressed up. Then derive the
  phases from that list: every phase carries a `Serves:` line naming the benefit
  numbers it delivers, and a phase that serves none is scope creep — cut it, or
  name the benefit that justifies it. If the benefits don't justify the work as
  scoped, say so in one line at the top and propose the smaller version that does.
  This is what stops a plan from being a tidy list of edits nobody needed.
- Then, still before any phase, add a `## Constraints` section as a self-check
  — `In scope`, `Out of scope`, and `Never do` — then derive the phases so they
  stay within those bounds.
- **Cite the issues the plan comes from.** Find where the repo tracks them — the
  issue or spec files the plan was built from, and any tracker in version control
  (`ISSUES.md`, `TODO.md`, `ROADMAP.md`, `docs/issues*.md`, a `CHANGELOG` section,
  a status table inside the plan's own issue file) — and name the open entries each
  phase addresses, with `path:line` where you can. This is what lets phase 3 close
  exactly those entries and no others instead of inferring which ones this work was
  about (step 3f). A phase that closes no tracked entry says so rather than leaving
  it ambiguous, and if the repo keeps no ledger the plan says that in one line.
  Never cite an entry you have not read: a plan pointing at an issue that does not
  exist is worse than one pointing at nothing.
- **Say what is still open, and who the work is for.** `wiggum plan` adds these
  itself in a feedback pass, and `wiggum explain <plan>` produces them on demand for
  a plan you did not write — but if you are writing the plan by hand, include them:
  an `## Open decisions` section (the choices a person still has to make, each with
  its options, what each buys and costs, and rough effort — or one line saying
  nothing is open), and a `## How this reaches users` section naming the README
  sections, `--help` text, release notes or web pages somebody would have to read to
  learn the feature exists. A feature nobody can discover has not shipped, and the
  doc task that fixes it belongs in the plan rather than in somebody's memory.
- **Draw it before you phase it.** After the constraints and before the first
  phase, add `## The shape of it`: one mermaid diagram of the thing the plan acts
  on, and two or three sentences saying what to take from it. Choose by what the
  work changes — a **user flow** (`flowchart TD`) when it changes what somebody
  experiences, an **architecture** diagram (`flowchart LR`) when it changes how
  components call each other, a **sequence** diagram when it is about ordering
  across systems (a webhook, a retry, a cutover). Draw the system as it will be
  *after* the work and mark the nodes the plan adds or changes, so the blast
  radius is visible at a glance. Label nodes in the reader's words, not function
  names; stay under ~20 nodes; put decisions in rhombus nodes and name every
  branch **including the failure branch**, because the branch nobody drew is the
  one nobody built. This is a scoping check, not decoration: a plan whose diagram
  cannot be drawn is a plan whose scope is not yet understood, so say that in the
  section and make the first phase the research that would let you draw it.
- Every task is a real Markdown checkbox line — `- [ ]` (GFM `*`/`+` bullets also
  count) — with its own **Acceptance:** and **Files:** lines. This matters
  mechanically: wiggum tracks progress by *counting* `[ ]`/`[x]`/`[~]` checkboxes,
  so a "task" written as a heading, bold text, or plain prose has no checkbox, is
  invisible to wiggum, and makes the run report `0 tasks` and stop immediately. A
  task without observable acceptance is a wish, not a step.
- `[x]` = done, `[ ]` = pending, `[~]` = dropped (terminal — wiggum won't re-pick
  it). Record why on the `[~]` line.
- \`[~]\` means *decided against*, not *waiting on somebody*. It is terminal: the
  run skips it and the summary files it under "What was dropped", so a task parked
  there because a person still has to decide is silently recorded as abandoned. If a
  phase needs a human decision first, do not mark it \`[~]\` -- leave the tasks
  \`[ ]\`, say in the phase header that it is gated, and keep that plan out of the
  queue (or split the gated phase into its own plan that nobody runs yet). Reserve
  \`[~]\` for work someone has actually decided not to do, and record that decision
  and its date on the line.
- Give each phase its own phase-level **### Acceptance Criteria** section, in
  addition to (not instead of) the per-task `Acceptance:`/`Files:` lines. Organize
  it into four categories: **Happy Path** (the primary flow works end to end),
  **Edge Cases** (empty, boundary, or large inputs), **Error States** (invalid
  input or a failed/unavailable dependency fails safely with a clear error), and
  **Non-Functional** (performance, formatting, accessibility). Every Non-Functional
  criterion must name an *observable check* — a benchmark command, a lint rule, a
  measurable threshold — never a feeling. `Given <context>, When <action>, Then
  <observable outcome>` is the recommended form, but a plain observable pass/fail
  line is fine where Given/When/Then is overkill.
- Before finalizing, confirm the APIs/commands the plan assumes actually exist
  (grep the repo). Don't plan around a hallucinated API.
- Every statement the plan makes about *current* behaviour cites its source as
  `path:line`, and you must have read that line before citing it — no citation
  from memory or inference. This complements `Files:`: `Files:` covers what a task
  will write, the citations cover what you read to justify the plan.
- Before planning a task that adds a test to an existing file, read that file's
  harness. Module-scope mocks (`vi.mock`, `jest.mock`, fixtures, monkeypatching)
  are hoisted per file and can make the intended test impossible there, so the task
  must state whether the test can live in that file or needs a new one. Never plan
  to weaken an existing mock so a new test fits.
- When the input is a defect report, diagnose before prescribing: the four sections
  above (`## Symptoms`, `## Root cause`, `## Why existing verification missed it`,
  `## Blast radius`) go before the phases, with every symptom tagged **observed**
  or **predicted**. For work that isn't a defect, omit them rather than inventing
  symptoms.
- Apply the four risk gates, and mark a gate whose trigger is absent as *not
  triggered* rather than dropping it silently: (1) **measure before you act** — a
  phase justified by a claim about production data or runtime state starts with a
  read-only measurement of that claim; (2) **activating never-run code is not a
  no-op** — precede it with a read-only impact report over real inputs; (3)
  **irreversible work carries four conditions** — default to a dry run, export the
  affected rows before the first real write, be idempotent, and record the affected
  count per scope; (4) **a new guard must pass on a clean tree** — enumerate the
  legitimate exceptions up front, and its acceptance states that the guard passes
  against current code on its first run and fails when the defect is reintroduced.
- Close the plan with a `## Sequencing — what can ship independently` section
  naming, for every phase, whether it can ship independently or must wait, and why.
  This is not the task-dependency list: `Depends on:` orders the work, this states
  shipping risk. A fix that only turns nulls into values ships freely; a fix that
  can delete good data waits for the measurement that bounds its blast radius.
- **Tie a claim to its artifact.** When tasks write a report, a status table, or a
  changelog *about* something they produce, add a guard asserting the record matches
  reality — a row claiming a trained model names a checkpoint that exists on disk, a
  row marked done names a real output. Agents fill in a row optimistically before the
  work behind it finishes, and a plausible false record is worse than a missing one.
  In a real run this guard is what stopped a report claiming a model was trained
  while its training was still running.
- **A parity claim must be tested against the pre-change code.** When a task's
  acceptance is "behaviour is unchanged when the switch is off", a test comparing the
  new code's two paths to each other proves only internal consistency: a diff that
  removes lines can pass it while having moved the baseline. Say in the task that the
  comparison is against the previous commit — extract the old file
  (`git show <ref>:<path>`) and compare outputs, or pin a digest computed on the
  clean tree. Prefer pinning a digest over pure inputs (a transform, a parser); for
  anything whose output depends on the BLAS library or thread count, such as trained
  weights, a pinned digest is flaky and the old-vs-new comparison is a one-time
  migration check instead.
- **A task doesn't have to be an edit — it has to be actionable.** Two kinds earn
  their place beside code changes, and both are still real checkboxes with
  `Acceptance:` and `Files:` lines:
  - **Research / a deep-dive spike**, when the plan depends on something not yet
    known. Put it *before* the work that depends on it, and make its acceptance a
    written artifact — findings in a file, a measured number, a recorded decision —
    never "understand X". The dependent task names what the research must return
    and what a given answer would change. An unknown left implicit becomes a
    mid-run stall; an unknown given its own task is just the first step.
  - **A nested wiggum run**, when a sub-problem is big enough to be its own
    workplan. The task runs `wiggum plan "<sub-problem>" --plan-file
    docs/<sub>_plan.md`, then `wiggum execute docs/<sub>_plan.md --max-iterations N`
    in the *foreground* (it is already inside a run — a `--background` child would
    outlive the iteration that started it, unsupervised). Acceptance: the child's
    `docs/<sub>_summary.md` exists and its boxes are checked. Delegate only
    self-contained sub-problems, always bound the child with `--max-iterations`,
    and never fan several children out at once — they compete for the same machine.
    If you find yourself planning three of these, you wanted `wiggum chain` at the
    top level instead.
- Keep plans focused. Very large plans (40+ tasks) tend to stall — split them and
  `chain` instead.

Confirm the plan looks right, then continue.

### 3. Execute and supervise

**Pick the launch mode from how long the job will run — before anything else.**
Most supervision pain comes from launching a multi-hour plan the way you'd launch
a five-minute one. Estimate roughly: a real workplan spends *minutes per task*,
and the verify step runs over the whole repo after every task (and again after
each fix attempt), so a 35-task plan on a big suite is hours, not minutes.

| Job length | Launch it | Wait on it | Why |
|---|---|---|---|
| Minutes, a handful of tasks | `wiggum execute <plan>` foreground | it blocks | Nothing to supervise. |
| Longer than one tool call, shorter than your session | `wiggum execute <plan> --background --max-iterations N` | `wiggum watch <plan>` | You get `status`/`watch`/`kill` and a `.pid` sidecar. |
| Longer than your own session | detached `screen`/`tmux`, wiggum **foreground inside it** (§3a) | `screen -ls` + a PID check | `--background` dies with the session that started it. |

If you are unsure which of the last two you are in, assume the third. Re-launching
a plan is cheap (phase 1 reconciles the repo against the plan); losing four hours
of a run to a session teardown is not.

**Both budgets get sized, and they are not the same budget.** A long job has two
independent ceilings and under-sizing either one ends the run early:

| Flag | Bounds | Size it by |
|---|---|---|
| `--max-iterations` | how many **tasks** it may attempt | `open × 2 + 3` (below) |
| `watch --timeout` | how long **you** wait, in seconds | the plan's realistic wall clock, generously |

Setting a six-hour `--timeout` on a 25-iteration budget for a 35-task plan is
incoherent: the wall clock is irrelevant once the iteration ceiling stops the run
two-thirds through. Compute the iteration budget from the plan, then set a timeout
that comfortably exceeds how long that many iterations will take. When you cannot
estimate the wall clock, use a large `--timeout` **without** `--kill-on-timeout`
so an overrun leaves the run alive for you to inspect rather than killing healthy
work.

**If a human suggests an iteration number, check it against the box count before
using it.** "use --max-iterations 25" on a 35-box plan is a number that cannot
finish, and taking it literally buys a guaranteed re-run. Do the arithmetic, say
what it comes to and why, and launch with the sized figure — this is a correction
they will want, not an instruction to follow off a cliff.

**First, activate the project environment** (from preflight) — *before* you launch,
not after. Launching `-b` into the wrong env means the verify steps (pytest/ruff/…)
run under the wrong interpreter and thrash, and you waste a `kill` + relaunch.
`wiggum execute` prints an environment line at startup; if it warns that no env is
active, stop, activate it, and relaunch.

**Size the iteration budget to the plan, on the FIRST launch.** An iteration
completes roughly one task, so a run needs at least as many iterations as the plan
has open checkboxes, plus headroom for the ones that need a second pass. The
default is **30** — from `--max-iterations`'s built-in default, the `max_iterations`
in the `.wiggumrc` templates wiggum generates, or a `.wiggumrc` written for an
older, smaller plan — and a config written for a smaller plan is almost always
wrong for a real workplan. An undersized budget — 3 iterations on an 11-task plan
— does not fail loudly; it stops `incomplete` about a quarter of the way in, which
reads like a stall and costs a supervise cycle to diagnose.

So count the boxes and pass the flag explicitly — **always**, even when
`.wiggumrc` already sets `max_iterations`, because the flag overrides it and you
should not have to read their config to get this right:

```
open=$(grep -c '^ *[-*+] \[ \]' docs/<name>_plan.md)
wiggum execute docs/<name>_plan.md --background --max-iterations $(( open * 2 + 3 ))
```

`open * 2 + 3` is a reasonable rule of thumb — roughly two passes per task plus
slack. Do **not** economise here: iterations are a *ceiling*, not a target. Wiggum
stops as soon as every task is done, and it stops on its own stall detection long
before it burns a large budget, so an over-generous ceiling costs nothing while a
tight one reliably costs a re-run. If you catch yourself re-running a plan purely
because it stopped `incomplete`, the budget was too small at launch.

**Size it to tasks, not to how flaky the suite is.** Verification has its own,
separate budget: a failing `verify` step spends `max_validation_retries` (default
5, per verification step), never `max_iterations`. So a flaky or slow test suite
cannot exhaust the iteration budget, and padding `--max-iterations` does nothing to
absorb it. The two knobs answer different questions — *how many tasks are there*
versus *how many fix attempts does a failing check get* — and conflating them leads
to sizing the wrong one. If verification is the problem, the levers are narrowing
the `verify` command or `--no-verify` (see the verify tax below), not a bigger
iteration ceiling.

Then launch detached so you can monitor and bound it:

```
wiggum execute docs/<name>_plan.md --background --max-iterations <sized above>
```

Then supervise in a loop until it finishes:

1. `wiggum status docs/<name>_plan.md` — read **State** and the task counts.
2. While **State** is `running`, `wiggum watch <plan>` it — always watch a running
   workplan through to the end rather than leaving it unattended:
   `wiggum watch docs/<name>_plan.md --timeout 1800 --kill-on-timeout`
   `watch` streams the run's output and blocks until it ends (your "wait");
   `--timeout`/`--kill-on-timeout` bound a stuck run. **Tune the timeout to the
   plan's size, and drop `--kill-on-timeout` when you are not confident in the
   estimate** — 1800 s is right for a handful of tasks and will execute a healthy
   multi-hour run. Without the kill flag an overrun just returns and says the run
   is still active, which is recoverable; with it, you have destroyed hours of
   work to enforce a guess. When it returns, summarize what happened (step 5) —
   don't just leave the run finished and silent.
3. **Spot a wedged run early.** Treat the run as spinning (not working) when
   `status` reports `running but appears blocked`, or `watch` returns non-zero —
   under the hood the `.out`/`.log` shows `No progress detected`, `Stalled for ...`,
   or `Validation failed N times`. Read the tail of `docs/<name>.out` to see why,
   let it reach its natural stop (or let `--kill-on-timeout` bound it), then
   remediate in step 4. Don't keep a wedged run alive.
4. **Kill only when needed.** If a run overruns or is wedged and you must stop it,
   use `wiggum kill docs/<name>_plan.md`. This kills only that run's process tree
   (the wiggum process and the `claude` it spawned) — never a blanket kill of other
   wiggum/claude processes. Prefer `--kill-on-timeout` on `watch` so you don't have
   to babysit it.

For a quick, small run you may skip backgrounding and just `wiggum execute <plan>`
in the foreground.

### 3a. Runs longer than your own session: launch durably

`--background` daemonizes inside the **calling shell's session**. That survives you
closing a pipe; it does *not* survive the session itself being destroyed — a
terminal restart, the agent session ending, the supervising process exiting. When
that happens the whole tree goes with it, and the signature is a clean `.out`
ending mid-phase: no error, no summary file. Don't go hunting for a bug in the
plan; it was killed from outside. `nohup … &` buys immunity to SIGHUP only, so it
delays this rather than fixing it.

**A detached run still dies if the machine sleeps.** `screen` survives your session; it
does not survive the Mac suspending. On a laptop, a multi-hour run left overnight is
exactly the run that gets cut in half by a sleep nobody noticed, and the signature is
identical to the one above: a clean `.out` ending mid-phase.

**Never touch the power settings yourself.** Not Caffeine, Amphetamine or
KeepingYouAwake; not `caffeinate` or `pmset`; not System Settings. Whether the machine
stays awake is the user's decision, it has real battery and heat costs, and silently
changing it in either direction is worse than a run that stops. If a long run is being
launched and staying awake matters, **say so and let the user decide** — one sentence,
then launch anyway.

For any run you expect to outlive your own session, launch it inside a detached
multiplexer instead:

```
screen -dmS wig1 bash -lc 'source "$(conda info --base)/etc/profile.d/conda.sh"; \
  conda activate <env>; \
  exec wiggum execute docs/<name>_plan.md --max-iterations N >> docs/<name>_plan.out 2>&1'
```

Run wiggum in the **foreground inside** the multiplexer — no `--background`. The
multiplexer supplies the durability, and a daemonizing child would let its session
exit immediately and take the tree down. `tmux new -d -s wig1 '<same>'` works
identically; macOS has `screen` at `/usr/bin/screen` and no `setsid`.

A foreground run does register itself while it works — a `.pid` next to the plan
and an entry in the machine-wide registry — so `wiggum status` and `wiggum top`
find it from anywhere. But it clears both the moment it ends, and a
`kill -0 $(cat <plan>.pid)` check then reports "gone" for a plan that merely
finished, indistinguishable from a real death. The multiplexer session also
outlives any one plan. Check the session with `screen -ls` / `tmux ls` and a
process check, and read the plan's own state from `wiggum status`, which counts
its checkboxes.

**Check a PID, not a pattern.** wiggum's own `process_alive()` is `kill -0 "$pid"`
(`lib/wiggum.sh`), and that is the primitive to copy: it asks the kernel about one
process and parses no text, so nothing about other processes or terminal width can
fool it. Capture the PID when you launch (`$!`, or `screen -ls`) and check that.

Pattern-matching liveness fails in two ways that both look exactly like "the job
finished", and a waiter shaped `until ! <check>; do sleep 30; done` cannot tell
either from success, because it reads *any* non-zero exit as "gone":

- `pgrep -f` **errors** rather than returning empty when any unrelated process has
  non-UTF-8 bytes in its command line: `Regular expression evaluation error (illegal
  byte sequence)`, exit non-zero, waiter fires.
- `ps -eo pid,command` **truncates** the command column to the terminal width, so in
  a background context with no tty the match string can be cut off entirely. Use
  `ps -eo pid,command -ww` if you must match text at all.

Whatever you check, confirm a *completion* by its **artifact** — the output file
exists, the job's log has its `saved …` line — never by the absence of a process
alone. A job that dies at minute 50 also stops being a process, and the two are
indistinguishable until you look for what it was supposed to produce.

For a run wiggum itself started, skip all of this: `wiggum watch <plan>` blocks
until it finishes and streams its output.

**Verify survival before believing any launch pattern.** Every one of these failure
modes looks healthy at the five-minute mark. Don't record a pattern as working
until it has outlived at least one session teardown.

### 3b. Tasks that outlast an iteration

An iteration completes roughly one task, so a task whose work takes longer than an
iteration — training a model, a long build, a big migration — will not flip its
checkbox inside that iteration. Wiggum scores the iteration as no progress, and two
of those in a row stop the run while the real work is still going.

Handle it from both sides:

- **In the plan:** a long-running task should launch its job into its own detached
  session and record the artifact path in its `Acceptance:`. A later iteration then
  observes the finished artifact instead of restarting an hour of work. Say so in
  the task, so the implementing agent doesn't run it inline.
- **As supervisor:** never treat `No progress detected` as a stall before checking
  whether such a job is alive (next section).

### 3c. Reading the sidecars without fooling yourself

**Both sidecars append across runs, each run separated by a marker.** `.out`
carries `--- wiggum run <timestamp> ---` at the top of every run's output, and
`.log` carries the same marker on every run's entries. So relaunching a plan no longer
destroys the log of the run you are relaunching *because of* — the output you
need to diagnose it is still there, above the separator.

**Wiggum's own readers already scope themselves to the current run**, so
`wiggum status` will not report a dead run's stall as a live one, and
`wiggum watch` streams from this run's separator instead of replaying history.

**Your greps do not scope themselves.** A `grep` over the whole `.out` reads
every run at once, and two failures follow — both bit a real supervision session
before the separators existed:

- A match on a stall line from a *dead* run gets reported as current.
- A monitor that dedupes by message text records that string once, then goes
  **deaf** to the next genuine occurrence of it.

So scope the read to the current run, the same way wiggum does — everything from
the last separator on:

```
awk '/^--- wiggum run /{buf=""} {buf=buf $0 ORS} END{printf "%s", buf}' docs/<name>_plan.out \
  | grep -nE 'No progress detected|Stalled for|Validation failed'
```

Do not anchor on `=== WIGGUM RUN` — that is the *aborted-run* banner, and it
sits below the status line it reports, so slicing from it hides the status.

If you would rather count, baseline the match over the whole file before you
launch and report only the increase — but prefer scoping, because a baseline is
one more piece of state to get wrong.

`.log` is the timing record: its `phase2-validate-N-fix-M` entries give wall clock
per phase, which is how you find out where a run actually spent its time.

### 3d. Relaunching, and the pidfile race (fixed — recognise it on older installs)

**Current wiggum guards this.** `watch` and `kill` release a run's pidfile only
when it still names the pid they were supervising (`release_pidfile`), so a
relaunch that lands while an old run is winding down keeps its sidecar.

**On an older wiggum, the cleanup was unguarded** (`rm -f "$pidfile"` at the end
of `run_watch`) and deleted whatever pidfile was at that path. Kill a run and
relaunch in the same breath, and the lingering watch deletes the **new** run's
pidfile. Worth recognising, because the symptom reads as success:

- `wiggum watch` returns **exit 0** with `No background run found for <plan> (no
  pidfile)`.
- `wiggum status` drops its `State:` line.
- The run is meanwhile working perfectly.

Read that as "the run finished" and you will report a completed job that is
still going. **Confirm with the kernel, not the sidecar** — the run is detached
and reparented to init, so `ps` finds it:

```
ps -o pid,ppid,etime,command -ww | grep "[w]iggum execute <plan>"
```

If it is alive, restore the sidecar rather than restarting hours of work — but
only after confirming the pid really is that plan's run:

```
if ps -o command= -p "$pid" -ww | grep -q "wiggum execute <plan>"; then
    printf '%s\n' "$pid" > docs/<name>_plan.pid
fi
```

Either way, letting the old `watch` return before you relaunch costs nothing and
avoids the question.

### 3e. Watches are yours to tear down, and status counts are not activity

Two ways a supervisor reports progress that is not happening. Both were observed
in a real session, and in both the user was the one who noticed.

**Stop the watch when the run stops.** A persistent tail on a run's sidecar
(`Monitor`, a backgrounded `tail -f`, any long-lived poll) does not end when
wiggum does; it goes quiet, which is indistinguishable from a run that is simply
between iterations. Worse, the harness keeps advertising it: the user's status
line reads `1 monitor still running` for as long as it lives. In the observed
case that ran for sixteen hours after the run had finished, tailing a file
nothing was writing to, while the user waited for it to "do something".

So the moment `wiggum status` reports `finished: <reason>`, tear the watch down
in the same turn you report the outcome. A watch outliving its run is not
harmless bookkeeping; it is a false progress indicator you put on the user's
screen. Take the same care with a `tail -f` that greps for a completion banner:
if the log goes quiet the pipeline hangs rather than exiting.

**`wiggum status` counts checkboxes in a file, not work in flight.** `remaining`
is a `grep -c` over the plan, so it moves whenever the *plan* changes, with or
without a process. Add a phase to a finished plan and `remaining` climbs from 0
to 16 while nothing whatsoever is executing. That reads exactly like a stalled
run to anyone watching the number.

Two consequences:

- **Always read `State:` beside the counts, and quote both.** `finished: complete`
  with 16 remaining means "somebody edited the plan since the run"; `running but
  appears blocked` with 16 remaining means something is wrong. The counts alone
  cannot tell them apart.
- **If you scope new tasks without launching, say so in plain words.** "I have
  added 16 tasks and nothing is running" is the honest sentence. Silence after
  writing a phase, while the counter climbs, invites the user to assume a run is
  chewing on it.

**Never infer liveness from a watch.** A monitor that has emitted nothing for an
hour tells you nothing: the run may be mid-build, finished, or dead. Confirm with
`kill -0 "$pid"` on a PID you captured at launch (step 3a), or `screen -ls` /
`tmux ls`. Then confirm *completion* by the artifact, per step 3a: the summary
file exists, the plan's boxes moved.

### 3f. The issue ledger closes with the run

Phase 3 reconciles the **issue ledger**, not just the plan. It looks for wherever the
repo tracks the issues this work came from — an `ISSUES.md`, `TODO.md`, `ROADMAP.md`,
a `docs/issues*.md`, a `CHANGELOG` entry, a status table inside the plan's own issue
file — marks the entries this run actually finished, and records each one's commit
refs and the observed result. Entries whose tasks are still `[ ]` or `[~]` stay open,
with the reason in the summary. It will not invent a ledger the repo doesn't keep,
backfill an entry for work nobody tracked, or close a remote tracker (GitHub, Jira)
on its own — those are named in the summary for a human to close.

Two things stay yours:

- **Point it at a ledger it can't find.** If the repo tracks issues somewhere a grep
  wouldn't turn up — a `docs/issues/` directory, a table inside a README, a file named
  for the team rather than for issues — name that path in the plan (`## Expected
  benefits` or `## Constraints` is a good spot). A ledger the run can't find is one it
  will honestly report as absent, which is correct and still not what you wanted.
- **Check the record against the tree when you report.** `git show --stat` on the
  phase 3 commit says whether the ledger actually moved. The failure worth catching is
  a row marked shipped whose task is still `[ ]`: agents fill rows in optimistically,
  and a plausible false record is worse than a missing one.

### 4. If the run didn't finish `complete` — remediate and re-run

A finished run is not necessarily a done one. Read its stop reason from
`wiggum status <plan>` (`finished: <reason>`) and `docs/<name>_summary.md`. Wiggum
stops for three reasons; handle each differently:

- **`complete`** — 0 tasks remain. Go to Report.
- **`incomplete`** — it hit `--max-iterations` while still making progress; it just
  ran out of budget. The plan is fine. Re-run `wiggum execute <plan>` — phase 1
  reconciles the repo against the plan, then it continues the remaining `[ ]`
  tasks — **with a budget sized to the tasks that are still open** (step 3's
  `open * 2 + 3`), not the same ceiling that just ran out. Between runs, `wiggum
  status <plan>` must show `remaining` going *down*; if it stops dropping, treat it
  as a stall. Reaching `incomplete` at all usually means the launch budget was
  under-sized — fix that at launch next time rather than re-running repeatedly.
- **`stalled`** — no progress for two iterations in a row. Re-running as-is will
  just stall again. **Diagnose, mitigate, then re-run.**

**First, rule out a false stall.** A stall means *wiggum* saw no checkbox move, not
that nothing is happening. Before diagnosing anything, check whether work is
progressing outside the iteration window:

- `pgrep -f "<the long command the task launches>"` and `screen -ls` / `tmux ls` —
  is the job the task spawned still alive?
- Is its output still growing? Cache directory size, an output file's mtime, a
  checkpoint appearing. Take two readings a minute apart rather than one.

If something is running, **do nothing**: let it finish, then relaunch. Phase 1
reconciles the repo against the plan and marks the task done from the artifact
instead of redoing the work. Killing the run here is safe (the detached job
survives); relaunching *before* the job finishes is not useful, because the same
task will fail its acceptance the same way.

Only when nothing is running is it a real stall:

**Diagnose the stall** (don't trust the checkboxes alone):
1. Read the evidence — `docs/<name>_summary.md` ("issues encountered" / "deferred"),
   the tail of `docs/<name>.out` and `.log` (the `No progress detected` /
   `Validation failed N times` lines), and the still-`[ ]` tasks. Pin down *which*
   task didn't advance and *why*.
2. Spot-check reality vs. the plan:
   - Run the project's own checks: `wiggum check` (runs the `.wiggumrc` verify/autofix
     steps and shows the real failure).
   - `grep` the repo for the files/symbols/APIs the stuck task assumed exist.
   - Confirm whether partial work actually landed — sometimes the work is done and
     only the box is unticked (phase-1 reconcile usually fixes that, but verify).

**Mitigate — match the fix to the cause:**
- *Task too big or vague* → split it into smaller `[ ]` steps, each with a concrete,
  observable `Acceptance:` line.
- *Acceptance can't be met / is ambiguous* → rewrite it to something reachable and
  checkable.
- *Built on a wrong or hallucinated API / assumption* → fix the task after reading
  the real source; correct dependencies or ordering.
- *A `.wiggumrc` verify command is itself wrong* → surface it to the user; **don't**
  edit `.wiggumrc` (it's their config).
- *Genuinely impossible, out of scope, or superseded* → mark the task `[~]` with a
  one-line rationale so wiggum stops re-picking it (its designed escape hatch).
- *Needs access, credentials, an external dependency, or a real product decision* →
  stop and ask the user; you can't resolve it.

**Check the machine before blaming the plan.** wiggum runs Claude, the verify
steps, and anything a task spawns — concurrently with any *other* wiggum run on the
box. Read `uptime`'s load average against the core count (`sysctl -n hw.ncpu` /
`nproc`). A load many times the core count makes every verify pass several times
slower, turns a working run into one that looks wedged, and makes the supervising
session itself a candidate for being reaped. Two concurrent runs plus a training job
on a 4-core machine reached load 59 in a real session. Serialising two runs finishes
both sooner than interleaving them; if the other run isn't yours to stop, say so
rather than quietly competing with it.

**The verify tax is often the real cost.** `verify`/`autofix` run over the **whole
repo** after every task and again after **each** fix attempt (up to
`max_validation_retries`, default 5). On a large suite that dominates everything
else: measure one pass from `.log` before concluding the task's own work is slow. A
single real session spent 27 minutes on one round's three fix attempts and 40 on the
next round's one.

If that tax is the bottleneck, `--no-verify` is a **CLI flag** — use it instead of
editing `.wiggumrc`, which is the user's config. It is a real reduction in safety,
so when you spend it: say what you traded, run the specific tests that guard the
work after each task yourself, and run the full suite once before calling the work
done. Report what that final run found rather than fixing quietly and claiming a
clean finish.

Then re-execute. **Bound the loop:** at most ~2–3 remediation cycles. If it stalls
again on the *same* task after a mitigation, stop and hand the user the diagnosis
plus options instead of burning more runs — mirror wiggum's own discipline (it caps
stall and validation retries precisely to avoid runaway).

### 5. Report

When the work is done (or you've stopped to escalate), run `wiggum status <plan>`
once more and report:
- the final stop reason (complete / stalled / incomplete) and how many remediation
  re-runs it took,
- task counts (done / remaining / dropped),
- what the summary file (`docs/<name>_summary.md`) says was done and deferred,
- which issue-ledger entries the run closed and which stayed open — or, if the repo
  keeps no ledger, that the summary says so rather than leaving it silent (step 3f),
- if you stopped on a stall: the cause you found, the mitigation you tried, and the
  decision you need from the user.

## Chaining workplans

When the work spans several independent plans, run them in sequence:

```
wiggum chain docs/schema_plan.md docs/api_plan.md docs/ui_plan.md
```

`chain` runs `wiggum execute` on each plan in order, each in a fresh session, and
stops at the first plan that fails — so a broken early step doesn't waste effort on
the rest. Each plan registers its own `.pid` while it is the active one and drops it
when it ends, so `wiggum top` shows a running chain as a row for the plan it is on
right now, and nothing for the plans on either side of it. To supervise a long chain,
background it and watch the active plan's sidecars, or run the plans one at a time
with the supervise loop in step 3 so you can inspect and fix between stages.

## Rules

- **Drive the CLI; don't reimplement it.** Plan/implement/verify/commit are
  wiggum's job. You orchestrate: plan, launch, monitor, wait, unblock, kill, chain.
- **Back out when the loop isn't warranted.** wiggum runs a full cycle *per task* —
  a fresh `claude` session, the whole verify suite, a commit. If you could make the
  change and confirm it in a single pass, say so and edit it directly rather than
  planning it; a plan that fragments one edit into eight commits costs more than it
  returns. Size and file count are the wrong test — prompt wording, a doc sweep, or
  a function copying an existing pattern is direct work even across many files. The
  loop earns its cost when steps depend on each other and each needs verifying
  before the next can be written.
- **Never ask for confirmation** — just execute.
- **Refer to runs by their plan file** — that's how status/watch/kill find the
  sidecars.
- **Always pass `--max-iterations`, sized to the plan's open checkboxes** (step 3).
  The 3-iteration default is a floor for toy plans, not a budget for a real
  workplan, and under-sizing it turns a working run into a false `incomplete`.
  Check any human-suggested number against the box count before using it.
- **Size the watch timeout too, and separately** (step 3): `--max-iterations`
  bounds tasks, `watch --timeout` bounds your wall clock. Drop
  `--kill-on-timeout` unless you are confident in the estimate — it destroys a
  healthy long run to enforce a guess.
- **Kill scope:** only ever stop the run you started (`wiggum kill <plan>`), never
  a blanket process kill.
- **The ledger closes with the run** (step 3f): phase 3 marks the issues this run
  actually finished, with their commit refs. Name a hard-to-find ledger in the plan,
  and when you report, confirm no row marked shipped sits above a task still `[ ]`.
- **Don't edit `.wiggumrc`** to make verification pass — it's the user's config. If
  a verify command itself is wrong, surface it.
- **A finished run isn't a done one.** Always check the stop reason: `incomplete`
  → re-run; `stalled` → diagnose and mitigate before re-running (step 4). Never
  re-run a stalled plan unchanged.
- **Remediate, don't loop forever.** Cap re-runs (~2–3) and confirm `remaining` is
  dropping between them; if a task stays stuck after a mitigation, escalate with the
  diagnosis instead of burning more runs.
- **Launch durably for anything long** (step 3a): `--background` dies with the
  session that started it. Use a detached `screen`/`tmux` with wiggum in the
  foreground inside it. `wiggum top` finds a foreground run from any directory, but
  the registration goes the moment the plan ends — for the session as a whole,
  check `pgrep`.
- **Rule out a false stall before remediating** (step 4): if a job the task spawned
  is still alive and its output still growing, wait and relaunch — don't rewrite a
  task that was working.
- **Scope your own greps of `.out` to the current run** (step 3c): both sidecars
  append across runs behind a separator. Wiggum's readers scope themselves; your
  `grep` does not, and an unscoped one reports a dead run's stall as current and
  then goes deaf to the live one.
- **Confirm a run ended with `ps`, not with the sidecar** (step 3d): on older
  wiggum a lingering `watch` could delete a newer run's pidfile, and the symptom
  — `watch` exiting 0 with "no pidfile" — is indistinguishable from a clean
  finish.
- **Tear down your watch when the run ends, and never read counts as activity**
  (step 3e): a monitor outliving its run shows the user `1 monitor still running`
  and reads as work in progress; `wiggum status` counts checkboxes, so `remaining`
  climbs when you *edit* the plan. Quote `State:` beside the counts, and say
  plainly when you have scoped tasks without launching.
- **Don't trust a green report over the artifact.** Read the numbers an agent writes
  into a report against the files that produced them; check that a "parity" or
  "unchanged" claim was tested against the previous commit and not against the new
  code's own second path.
- **Report honestly:** if it stalled or was killed, say so with the cause from the
  log — don't round an incomplete run up to "done". The same applies to your own
  supervision: if you turned off verification or skipped a check, say which.
SKILL_EOF
}

setup_wiggum_skill() {
    local skill_dir=".claude/skills/wiggum"
    local skill_file="$skill_dir/SKILL.md"

    if [[ -f "$skill_file" ]]; then
        # Already current: nothing to do.
        if diff -q <(wiggum_skill_content) "$skill_file" >/dev/null 2>&1; then
            echo ""
            echo "Claude Code skill at $skill_file is already up to date — skipping."
            return 0
        fi
        # Stale copy from an older wiggum: offer to refresh it rather than
        # silently leaving the project on an outdated skill.
        echo ""
        echo "An older /wiggum skill exists at $skill_file."
        echo "Update it to the current version? [y/N]"
        read -r answer
        if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
            echo "Kept your existing skill."
            return 0
        fi
        wiggum_skill_content > "$skill_file"
        echo "Updated $skill_file to the current /wiggum skill."
        return 0
    fi

    echo ""
    echo "Install the /wiggum slash command for Claude Code?"
    echo "This lets you run the wiggum workflow from inside Claude Code"
    echo "with: /wiggum <issue-file-or-description>"
    echo ""
    echo "Install /wiggum skill? [y/N]"
    read -r answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        echo "Skipped."
        return 0
    fi

    mkdir -p "$skill_dir"
    wiggum_skill_content > "$skill_file"
    echo "Created $skill_file"
    echo "You can now use /wiggum inside Claude Code."
}

# ── Logging ──────────────────────────────────────────────────────────────────

# Derive a sidecar file path (log/pid/out) for a plan or base file, using the
# same `<dir>/<name>.<ext>` naming the log file uses. This is the contract that
# lets `status`/`watch`/`kill` find a run that `execute --background` started:
# given the plan path, every command derives the same pid/out/log paths.
#   run_sidecar_file docs/foo_plan.md pid -> docs/foo_plan.pid
run_sidecar_file() {
    local base_file="$1" ext="$2"
    local dir name
    dir="$(dirname "$base_file")"
    name="$(basename "$base_file" .md)"
    echo "${dir}/${name}.${ext}"
}

log_init() {
    local base_file="$1"
    WIGGUM_LOG_FILE="$(run_sidecar_file "$base_file" log)"

    mkdir -p "$(dirname "$WIGGUM_LOG_FILE")"
    echo "--- wiggum run $(date '+%Y-%m-%d %H:%M:%S') ---" >> "$WIGGUM_LOG_FILE"
    log_entry "command" "wiggum $MODE ${FILES[*]+${FILES[*]}}"
}

log_entry() {
    local label="$1"
    local message="$2"
    if [[ -n "$WIGGUM_LOG_FILE" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $label: $message" >> "$WIGGUM_LOG_FILE"
    fi
}

generate_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        # Fallback: generate from /dev/urandom
        od -x /dev/urandom | head -1 | awk '{print $2$3"-"$4"-"$5"-"$6"-"$7$8$9}'
    fi
}

# ── Claude wrapper ───────────────────────────────────────────────────────────

WIGGUM_LAST_SESSION_ID=""

# Path to the transcript of the claude invocation that most recently failed.
# Empty while every session has succeeded.
WIGGUM_LAST_FAILURE_OUT=""

# Markers the Claude CLI prints when a session dies or degrades at the
# transport/API layer rather than finishing its task. Used only to name the
# cause in the failure report; the exit code is what decides failure, so a
# marker appearing in ordinary output can never abort a healthy run.
WIGGUM_CLAUDE_FAILURE_MARKERS='API Error|Connection closed mid-response|Connection error|Request timed out|Request was aborted|overloaded_error|rate_limit_error|Credit balance is too low|Invalid API key|OAuth token has expired|Prompt is too long'

# Echo the first transport/API failure marker found in a captured transcript,
# with a little trailing context, or nothing. Separate from run_claude so it
# can be tested against a fixture file.
#
# Always exits 0. A clean transcript makes grep exit 1, and callers assign the
# result to a variable, so returning grep's status would abort the whole run
# under `set -e` every time a session succeeded.
scan_claude_failure() {
    local outfile="$1"
    [[ -f "$outfile" ]] || return 0
    grep -oiE "($WIGGUM_CLAUDE_FAILURE_MARKERS).{0,100}" "$outfile" | head -n1 || true
}

# Create a private transcript file for one claude invocation. Deleted when the
# session succeeds, kept (and its path reported) when it fails, so a crash can
# be read after the fact without leaving files in the user's repo.
claude_capture_file() {
    local dir="${TMPDIR:-/tmp}"
    mktemp "${dir%/}/wiggum-claude-XXXXXX"
}

# Report a failed claude session on stderr. This is the whole point of the
# wrapper: in quiet mode claude's output went to /dev/null and `set -e` then
# unwound the run, so a dead session showed on the terminal as nothing but the
# session id line and a returned shell prompt.
report_claude_failure() {
    local label="$1" session_id="$2" rc="$3" outfile="$4"
    local reason
    reason="$(scan_claude_failure "$outfile")"

    {
        echo ""
        echo "!! claude session failed during '$label' (exit $rc)."
        if [[ -n "$reason" ]]; then
            echo "   cause:      $reason"
        fi
        echo "   session:    $session_id"
        if [[ -s "$outfile" ]]; then
            echo "   transcript: $outfile"
            echo "   --- last 20 lines ---"
            tail -n 20 "$outfile" | sed 's/^/   | /'
            echo "   --- end of transcript ---"
        else
            echo "   transcript: (claude produced no output)"
        fi
        echo "   inspect:    claude --resume $session_id"
        echo ""
    } >&2

    log_entry "$label" "FAILED exit $rc${reason:+ - $reason}"
}

run_claude() {
    local label="${WIGGUM_CURRENT_LABEL:-claude}"

    # Snapshot the session a -c call forks from before looping: a retry must
    # fork from the same predecessor, not from the attempt that just died.
    local resume_from="$WIGGUM_LAST_SESSION_ID"

    # Split out -c/--continue (wiggum's flag, not claude's) and note whether
    # the caller passed its own --permission-mode, so we don't also inject the
    # configured one (an explicit per-call override wins).
    local filtered_args=()
    local has_perm_mode=false
    local wants_continue=false
    for arg in "$@"; do
        if [[ "$arg" == "-c" || "$arg" == "--continue" ]]; then
            wants_continue=true
        else
            [[ "$arg" == "--permission-mode" ]] && has_perm_mode=true
            filtered_args+=("$arg")
        fi
    done

    # Inject the configured effort and permission mode (unless overridden).
    local injected_args=()
    if [[ -n "$EFFORT" ]]; then
        injected_args+=("--effort" "$EFFORT")
    fi
    if [[ "$has_perm_mode" != true ]]; then
        injected_args+=("--permission-mode" "$PERMISSION_MODE")
    fi

    local attempt=1 rc=0
    while :; do
        # A fresh session id per attempt: --session-id rejects an id that has
        # already been used, so reusing the dead attempt's id would turn a
        # retryable network blip into a hard failure.
        local session_id
        session_id="$(generate_uuid)"
        local session_args=("--session-id" "$session_id")
        if [[ "$wants_continue" == true && -n "$resume_from" ]]; then
            session_args+=("--resume" "$resume_from" "--fork-session")
            log_entry "$label" "session $session_id (resumed from $resume_from)"
            echo "  session: $session_id (resumed from $resume_from)" >&2
        else
            log_entry "$label" "session $session_id"
            echo "  session: $session_id" >&2
        fi
        WIGGUM_LAST_SESSION_ID="$session_id"

        local outfile
        outfile="$(claude_capture_file)"

        rc=0
        if [[ "$VERBOSE" == true || "$WIGGUM_SHOW_OUTPUT" == true ]]; then
            claude "${session_args[@]}" \
                ${injected_args[@]+"${injected_args[@]}"} \
                ${CLAUDE_EXTRA_ARGS[@]+"${CLAUDE_EXTRA_ARGS[@]}"} "${filtered_args[@]}" \
                2>&1 | tee "$outfile" || rc=$?
        else
            claude "${session_args[@]}" \
                ${injected_args[@]+"${injected_args[@]}"} \
                ${CLAUDE_EXTRA_ARGS[@]+"${CLAUDE_EXTRA_ARGS[@]}"} "${filtered_args[@]}" \
                >"$outfile" 2>&1 || rc=$?
        fi

        if [[ "$rc" -eq 0 ]]; then
            # A session can finish successfully and still have dropped a
            # response part way through. Say so rather than letting the next
            # phase build on a half-finished one.
            local warning
            warning="$(scan_claude_failure "$outfile")"
            if [[ -n "$warning" ]]; then
                echo "Warning: claude exited 0 during '$label' but reported: $warning" >&2
                log_entry "$label" "warning - $warning"
            fi
            rm -f "$outfile"
            break
        fi

        report_claude_failure "$label" "$session_id" "$rc" "$outfile"
        WIGGUM_LAST_FAILURE_OUT="$outfile"

        if [[ "$attempt" -gt "$CLAUDE_RETRIES" ]]; then
            echo "Giving up on '$label' after $attempt attempt(s)." >&2
            log_entry "$label" "gave up after $attempt attempt(s)"
            return "$EXIT_CLAUDE_FAILED"
        fi

        echo "Retrying '$label' (attempt $((attempt + 1)) of $((CLAUDE_RETRIES + 1)))..." >&2
        log_entry "$label" "retry $attempt of $CLAUDE_RETRIES"
        attempt=$((attempt + 1))
    done

    log_entry "$label" "done"
}

# ── Plan ─────────────────────────────────────────────────────────────────────

# Second pass over a freshly written plan: adds the context a reader needs to
# judge it, without touching the work itself.
#
# Runs with -c so it reviews the plan it just wrote rather than re-reading it
# cold. Deliberately additive -- rewriting tasks here would let a review pass
# silently redesign work the first pass reasoned about, and the checkbox counts
# wiggum tracks would move for reasons nobody asked for.
#
# Skipped by --no-feedback, and by a piped run: piping means the plan is going
# straight into `wiggum execute`, where the extra sections cost a second claude
# call and are read by nobody.
run_plan_feedback() {
    if [[ "$NO_FEEDBACK" == true ]]; then
        echo "Feedback step: skipped (--no-feedback)" >&2
        return 0
    fi

    echo "" >&2
    echo "--- Plan feedback: open decisions and audience ---" >&2
    log_entry "phase" "plan feedback"

    local prev_label="${WIGGUM_CURRENT_LABEL:-plan}"
    WIGGUM_CURRENT_LABEL="plan-feedback"
    run_claude -p -c \
        "Review the workplan you just wrote to $PLAN_FILE and UPDATE that file in place, adding the context a reader needs to judge it. $(prompt_open_decisions) Put that analysis in a new '## Open decisions' section, immediately after the constraints and before the first phase. $(prompt_user_benefit) Fold items 1 to 3 of that analysis into the plan's existing '## Expected benefits' section rather than repeating them beside it, and put item 4 in a '## How this reaches users' section directly below it -- if the plan has no task covering a documentation or website change that item 4 says is missing, add it as a real checkbox task with an Acceptance line, in the phase where it belongs. Do NOT otherwise change the plan: do not reword, reorder, renumber, split, merge or delete any existing task, phase or acceptance criterion. Use the Edit tool on $PLAN_FILE. Do not print the plan. $PROMPT_SUFFIX" \
        "$PLAN_FILE"
    WIGGUM_CURRENT_LABEL="$prev_label"
    return 0
}

# `wiggum explain <plan-or-issue>` -- the same analysis the plan feedback step
# performs, on demand and read-only.
#
# Separate from `plan` because the questions outlive the plan's creation: a plan
# somebody else wrote, one half-executed, or an issue file nobody has planned yet
# all raise them, and regenerating the plan to find out is both expensive and
# destructive. Writes nothing to the repository and makes no commit; the analysis
# goes to stdout unless --explain-file names a destination.
run_explain() {
    local file_list="${FILES[*]}"

    echo "=== WIGGUM EXPLAIN MODE ===" >&2
    echo "Input files: $file_list" >&2
    if [[ -n "$EXPLAIN_FILE" ]]; then
        echo "Output: $EXPLAIN_FILE" >&2
    else
        echo "Output: stdout" >&2
    fi
    echo "" >&2

    log_init "${FILES[0]}"

    local destination
    if [[ -n "$EXPLAIN_FILE" ]]; then
        destination="Use the Write tool to save your answer to: $EXPLAIN_FILE. Do not print it."
    else
        destination="Print your answer. Write no files."
    fi

    WIGGUM_CURRENT_LABEL="explain"
    WIGGUM_SHOW_OUTPUT=true
    run_claude -p \
        "Explain the following file(s) to somebody deciding whether to run this work: $file_list. Read them, and read the repository around them for anything they assert about current behaviour. $(prompt_user_benefit) Then, separately: $(prompt_open_decisions) Answer under four headings -- 'What it contains', 'What it is worth', 'How it reaches users', 'Open decisions'. Change NOTHING in the repository: this is a read-only explanation, so make no edits, write no plan, and run no git command that alters state. $destination $PROMPT_SUFFIX" \
        "${FILES[@]}"
    WIGGUM_SHOW_OUTPUT=false

    if [[ -n "$EXPLAIN_FILE" ]]; then
        if [[ -f "$EXPLAIN_FILE" && -s "$EXPLAIN_FILE" ]]; then
            echo "" >&2
            echo "Explanation written: $EXPLAIN_FILE" >&2
        else
            echo "Error: explanation file was not created or is empty. Check Claude output above." >&2
            return "$EXIT_PLAN_FAILED"
        fi
    fi
    return 0
}

run_plan() {
    local piped=false
    # Pipe the plan to stdout when no explicit -o was given AND either stdin
    # was piped in (echo ... | wiggum plan) or stdout is a pipe (wiggum plan
    # docs/X.md | wiggum execute). Without the stdout check, a file-argument
    # invocation would leak Claude's chat reply into the downstream pipe
    # while the real plan stays on disk.
    if [[ -z "$CLI_PLAN_FILE" ]] && { [[ -n "$STDIN_FILE" ]] || [[ ! -t 1 ]]; }; then
        piped=true
    fi

    echo "=== WIGGUM PLAN MODE ===" >&2
    echo "Input files: ${FILES[*]}" >&2
    # The diagnosis sections are paid for only when the input reads like a
    # defect report -- a feature request must never be pushed into inventing
    # symptoms. The detector is a heuristic, so the emitted text also carries
    # its own skip clause.
    local defect_rules=""
    if input_describes_defect "${FILES[@]+"${FILES[@]}"}"; then
        defect_rules="$(prompt_defect_diagnosis) "
        echo "Diagnosis sections: enabled (input looks like a defect report)" >&2
    else
        echo "Diagnosis sections: skipped (input does not look like a defect report)" >&2
    fi
    if [[ "$piped" == true ]]; then
        echo "Output: stdout" >&2
    else
        echo "Output plan: $PLAN_FILE" >&2
    fi
    echo "" >&2

    if [[ -n "$STDIN_FILE" ]]; then
        log_init "$PLAN_FILE"
    else
        log_init "${FILES[0]}"
    fi
    local file_list="${FILES[*]}"

    WIGGUM_CURRENT_LABEL="plan"
    if [[ "$piped" != true ]]; then
        WIGGUM_SHOW_OUTPUT=true
    fi
    run_claude -p \
        "You are a project planner. $(prompt_workplan "$file_list") $(prompt_expected_benefits) $(prompt_constraints_summary) $(prompt_plan_diagram) ${defect_rules}Produce a detailed, actionable workplan as a markdown checklist with phases and discrete tasks. Write each task as a Markdown bullet checkbox line -- '- [ ] <task>' -- not as a heading and not as bare prose; this is the form wiggum counts and GitHub renders as a checkbox. Include dependencies between tasks. Every task MUST have an 'Acceptance:' line stating an observable outcome -- a passing test, a specific log line, a file that exists, a command that exits 0, a SQL row. Not a feeling ('looks better', 'works correctly'). A task without observable acceptance is a wish, not a step. $(prompt_plan_verification) $(prompt_acceptance_criteria) $(prompt_risk_gates) $(prompt_research_and_delegation) $(prompt_phase_sequencing) $(prompt_plan_issue_refs) Use the Write tool to save the plan to: $PLAN_FILE. Do not print the plan to stdout -- only write it to the file. $PROMPT_SUFFIX" \
        "${FILES[@]}"
    WIGGUM_SHOW_OUTPUT=false

    if [[ -f "$PLAN_FILE" && -s "$PLAN_FILE" ]]; then
        # A piped plan is on its way into `wiggum execute`, where the extra
        # sections cost a second claude call and are read by nobody.
        if [[ "$piped" != true ]]; then
            run_plan_feedback
        fi
        warn_if_plan_large "$PLAN_FILE"
        if [[ "$piped" == true ]]; then
            cat "$PLAN_FILE"
            rm -f "$PLAN_FILE" "$STDIN_FILE"
        else
            echo "" >&2
            echo "Plan created: $PLAN_FILE" >&2
        fi
    else
        echo "Error: plan file was not created or is empty. Check Claude output above." >&2
        return "$EXIT_PLAN_FAILED"
    fi
}

# ── Prompt templates ─────────────────────────────────────────────────────────

# Common suffix appended to all prompts.
PROMPT_SUFFIX="Do not ask for confirmation -- just do it."

# Build workplan context preamble.  Usage: $(prompt_workplan "$file_list")
prompt_workplan() {
    echo "The workplan is defined ONLY in: $1. You may read README.md and other project documentation for context, but they are not the plan."
}

# Expected-benefits section that must open the plan.  Usage: $(prompt_expected_benefits)
# The open-decisions analysis, shared by `wiggum explain` and the plan feedback
# step. A plan states what will be done; the choices still genuinely open are the
# part a human has to settle, and a run that guesses at one spends iterations
# discovering it guessed wrong.
prompt_open_decisions() {
    echo "Identify the decisions this work leaves OPEN -- the choices a person still has to make. For each: the decision in one line; the context needed to judge it (what in the repo forces it, as path:line, and what depends on it); the realistic options, with what each buys and costs; and a rough effort estimate per option, flagging which parts you are unsure of. Order them by the phase each blocks, and name that phase. Only a real fork belongs here, not a detail the implementer should just pick. If nothing is genuinely open, say so in one line rather than inventing a dilemma."
}

# The audience analysis, shared by `wiggum explain` and the plan feedback step.
# Work that nobody can find out about is work that only half shipped, and the
# documentation and web changes that close that gap are routinely remembered
# after the fact rather than planned.
prompt_user_benefit() {
    echo "Explain the work from the outside in. 1. WHAT IT CONTAINS: the phases and what each changes, in plain terms, for somebody who has not read the tasks. 2. WHAT BENEFIT IT BRINGS: what becomes true when this is done that is not true now -- an outcome, not an edit. 3. WHAT THE BENEFIT IS TO USERS: the same, in the words of somebody who USES the product; name who they are and what they were doing when they hit this problem. If users see nothing and this serves maintainers, say so rather than inflating it. 4. HOW IT IS COMMUNICATED: the places a user would look to find out -- README sections, --help text, release notes, a website page, completions -- citing each as a path, and whether the work covers it. A feature nobody can discover has not shipped."
}

# Appended to the plan prompt so planning starts from the issues the repository
# already tracks. prompt_issue_ledger reconciles that ledger in phase 3, but
# nothing told the PLANNER to look at it, so plans rarely named the entries they
# addressed and phase 3 was left inferring which ones this work closed.
prompt_plan_issue_refs() {
    echo "Anchor the plan to the issues it comes from: the issue or spec files it was built from, plus any tracker in version control (ISSUES.md, TODO.md, ROADMAP.md, docs/issues*.md, a CHANGELOG section, a status table in the plan's own issue file). On each phase, cite the open entries it addresses as path:line, so phase 3 closes exactly those; a phase closing none says so. If the repo keeps no ledger, say that in one line. Never invent or create a tracker, and never cite an entry you have not read."
}

prompt_expected_benefits() {
    echo "START the plan with an '## Expected benefits' section, before anything else: a numbered list, most valuable first, of what this work is FOR -- each one an outcome someone gets, not the change being made ('a failed verify names the offending file in one line' is a benefit; 'refactor the error handler' is not). Give every benefit a 'Signal:' line -- the observable thing that shows it landed after shipping (a number that moves, an error that stops appearing, a manual step nobody performs any more) -- and mark one you cannot measure yet as 'speculative' rather than dressing it up. Then derive everything else from that list: every phase MUST carry a 'Serves:' line naming the benefit numbers it delivers, and a phase that serves none is scope creep -- cut it, or name the benefit that justifies it. If the benefits do not justify the work as scoped, say so in one line at the top of the section and propose the smaller version that does."
}

# Constraints self-check that must follow the benefits.  Usage: $(prompt_constraints_summary)
prompt_constraints_summary() {
    echo "Immediately after '## Expected benefits', and before writing any phases or tasks, add a '## Constraints' section as a self-check: 'In scope' (what this work will do), 'Out of scope' (what it deliberately will not do), and 'Never do' (actions that would be wrong here -- e.g. editing the user's config, breaking the public interface, or weakening verification to make it pass). Then derive the phases and tasks so they stay within these bounds."
}

# Diagram that must follow the constraints.  Usage: $(prompt_plan_diagram)
prompt_plan_diagram() {
    echo "After '## Constraints' and before the first phase, add a '## The shape of it' section: ONE mermaid diagram of the thing the plan acts on, plus two or three sentences naming what the reader should take from it. Pick by what the work changes -- 'flowchart TD' of the USER FLOW when it changes what somebody experiences, 'flowchart LR' ARCHITECTURE when it changes how components call each other, 'sequenceDiagram' when it is about ordering across systems. Draw the system as it will be AFTER the work, prefixing changed nodes 'NEW'/'CHANGED' so the blast radius is visible at a glance. Label nodes in the reader's words, not function names; stay under about 20 nodes, splitting into two diagrams before exceeding that; put decisions in rhombus nodes and name every branch on its edge, including the failure branch, because the branch nobody drew is the one nobody built. A plan whose diagram cannot be drawn is a plan whose scope is not yet understood: say so there, and make the first phase the research that would let you draw it."
}

# Verification discipline appended to the planner prompt.  Usage: $(prompt_plan_verification)
prompt_plan_verification() {
    echo "Every task MUST also have a 'Files:' line naming the files it will create or modify (best-effort paths). Before finalizing the plan, confirm the libraries, APIs, and commands the approach depends on actually exist -- grep the repo or read the dependency. Do not build the plan around an assumed or hallucinated API. Every statement the plan makes about current behaviour MUST cite its source as \`path:line\`, and you MUST have read that line before citing it -- no citation from memory or inference. This complements the 'Files:' line: 'Files:' covers what a task will write, the citations cover what you read to justify the plan. Before planning a task that adds a test to an existing file, read that file's harness: module-scope mocks (\`vi.mock\`, \`jest.mock\`, fixtures, monkeypatching) are hoisted per file and can make the intended test impossible there -- the task MUST state whether the test can live in that file or needs a new one. Never plan to weaken an existing mock so a new test fits; that quietly reduces the coverage the file already had."
}

# Phase-level acceptance-criteria discipline appended to the planner prompt.  Usage: $(prompt_acceptance_criteria)
prompt_acceptance_criteria() {
    echo "In addition to the per-task 'Acceptance:'/'Files:' lines (which stay), give EACH phase its own '### Acceptance Criteria' section organized by four categories: 'Happy Path' (the primary flow works end to end), 'Edge Cases' (empty, boundary, or large inputs), 'Error States' (invalid input or a failed/unavailable dependency fails safely with a clear error), and 'Non-Functional' (performance, formatting, accessibility). Every 'Non-Functional' criterion MUST name an 'observable check' -- a benchmark command, a lint rule, a measurable threshold -- never a feeling. Recommend writing each criterion in the 'Given <context>, When <action>, Then <observable outcome>' form, but a plain observable pass/fail line is allowed where Given/When/Then is overkill. This phase-level section is additive: it does NOT replace the per-task 'Acceptance:' and 'Files:' lines."
}

# Risk gates appended to the planner prompt.  Usage: $(prompt_risk_gates)
prompt_risk_gates() {
    echo "Apply these four risk gates. Each is conditional: mark one whose trigger is absent 'not triggered' rather than omitting it, and never add a phase for it. (1) Measure first: If a phase is justified by a claim about production data or runtime state, make the FIRST phase a read-only measurement of it, and have each dependent phase name the result that would make it unnecessary. (2) Activating never-run code is not a no-op: If a task enables or first-runs a path that has never executed against real data, precede it with a read-only impact report over real inputs, reviewed before shipping. (3) Irreversible work carries four conditions: If a task deletes, overwrites or rewrites data, it MUST default to a dry run, export the affected rows before the first real write, be idempotent, and record the affected count per scope. (4) A new guard must pass on a clean tree: If a task adds a guard, lint rule or CI check, enumerate the legitimate exceptions up front, and its acceptance MUST state that the guard passes against current code on its first run and fails when the defect is reintroduced."
}

# Non-edit task kinds -- research spikes and nested wiggum runs.  Usage: $(prompt_research_and_delegation)
prompt_research_and_delegation() {
    echo "Tasks do not all have to be edits, but every task must still be actionable -- something someone could start on Monday morning. Where the plan depends on something you do not yet know, make the unknown its own research task, placed before the work that depends on it: it is still a checkbox with a real 'Acceptance:' and 'Files:' line, so it lands a written artifact -- findings in a file, a measured number, a recorded decision -- never 'understand X', and the dependent task names what the research must return and what it would change. Where a sub-problem is large enough to be its own workplan, a task may delegate it to a nested wiggum run instead of inlining it: 'wiggum plan' to write the sub-plan, then 'wiggum execute <sub-plan> --max-iterations N' in the foreground, accepted when the sub-plan's summary exists and its boxes are checked. Delegate only self-contained sub-problems, always bound the child run, and never launch nested runs in parallel -- they compete for the same machine."
}

# Phase sequencing rule appended to the planner prompt.  Usage: $(prompt_phase_sequencing)
prompt_phase_sequencing() {
    echo "After the phases, close the plan with a '## Sequencing -- what can ship independently' section that names, for every phase, whether it can ship independently or must wait, and the reason. This is not the task-dependency list: 'Depends on:' orders the work, this states shipping risk. Discriminator: a fix that only turns nulls into values ships freely; a fix that can delete good data must wait for the measurement that bounds its blast radius."
}

# Defect diagnosis sections, emitted only when the input looks like a defect
# report (see input_describes_defect).  Usage: $(prompt_defect_diagnosis)
prompt_defect_diagnosis() {
    echo "The input reads like a defect report, so the plan MUST diagnose before it prescribes: place these four sections BEFORE the phases. '## Symptoms': what is observably wrong, in the terms of whoever sees it (a user, an on-call engineer, a dashboard), with EVERY symptom tagged **observed** (you saw it in data, logs, or a reproduction) or **predicted** (it follows from the code but you have not seen it happen) -- never present a predicted symptom as observed. Name the tell: the specific signal that separates this defect from the benign explanation, so a reader can tell them apart. '## Root cause': a numbered path from entry point to failure, each step carrying its \`path:line\`. '## Why existing verification missed it': name the blind spot and cite the tests that pass anyway; if a passing test pins the buggy behaviour, say so and name it. '## Blast radius': what is affected, and explicitly what is unaffected and why. If the input turns out not to be a defect after all, omit these four sections rather than inventing symptoms."
}

# Issue-ledger reconciliation appended to the phase 3 prompt.  Usage: $(prompt_issue_ledger)
prompt_issue_ledger() {
    echo "Close the loop on the issue ledger. Find where this repository tracks the issues this work came from: the issue or spec files the plan was built from, and any tracker kept in version control -- an ISSUES.md, TODO.md, ROADMAP.md, a docs/issues*.md, a CHANGELOG entry, or a status table inside the plan's own issue file. Update ONLY the entries this run actually finished: mark each one shipped, and record its commit refs (read them from 'git log --oneline' for the commits this run made) plus the observable result its acceptance criterion asked for. A task still '[ ]', or '[~]', has NOT shipped -- leave its entry open and say why in the summary; a plausible false 'done' row is worse than a missing one. Never invent a ledger: if the repo keeps none, or it keeps one with no entry for this work, write one line in the summary saying so instead of creating a tracker or backfilling an entry nobody asked for. Leave entries this run did not work on untouched. Do not close a remote tracker (a GitHub or Jira issue) from here -- name the issue and its commits in the summary and leave closing it to a human, unless a plan task explicitly said to close it."
}

# Verification discipline appended to the implementation prompt.  Usage: $(prompt_implement_verification)
prompt_implement_verification() {
    echo "Before writing code, verify your assumptions: confirm the functions, APIs, and imports you will call actually exist and the config values you depend on are defined -- grep the repo or read the source, do not assume. Treat every \`file:line\` reference in the plan itself as stale until you have checked it: plans are written before the work and the code moves underneath them, including by earlier iterations of this same run. Open each cited location, and if the plan points at the wrong place, correct the citation in the plan in the same commit as the code -- a task implemented against a citation nobody re-read is how a fix lands in the wrong function. If the thing a citation describes has already been done, say so and mark the task \`[x]\` with the evidence instead of re-implementing it. If no test covers the change, write a minimal failing test first, then implement until it passes. After implementing, run three spot checks and show your work as input -> expected -> actual: the happy path, an edge case (empty, boundary, or large input), and a failure case (invalid input must fail safely with a clear error). Do not mark a task \`[x]\` until its acceptance criterion is met and all three spot checks pass; never round an unverified result up to done."
}

# Build a commit prompt.  Optional arg: extra files to mention.
prompt_commit() {
    local extra="${1:-}"
    local files_clause="modified and untracked files"
    if [[ -n "$extra" ]]; then
        files_clause="uncommitted changes (modified and untracked files) including $extra"
    fi
    echo "Review all $files_clause. For each file, execute 'git add <file>' and 'git commit -m \"<message>\"'. $PROMPT_SUFFIX The message MUST be a single line. DO NOT include any trailers, footers, or attributions. Use only the imperative mood describing the logic change."
}

# Run a wiggum-issued commit step, or skip it under --no-commit.
# Args: <session-label> [extra-files-to-mention]
commit_or_skip() {
    if [[ "$NO_COMMIT" == true ]]; then
        echo "(commit skipped via --no-commit)" >&2
        return 0
    fi
    local label="$1"
    shift
    WIGGUM_CURRENT_LABEL="$label"
    run_claude -p "$(prompt_commit "$@")"
}

# ── Validation ───────────────────────────────────────────────────────────────

print_verify_steps() {
    local fd="${1:-2}"  # default to stderr
    if [[ "$NO_VERIFY" == true ]]; then
        echo "Verification steps: (skipped)" >&"$fd"
        return
    fi
    if [[ ${#VERIFY_STEPS[@]} -eq 0 ]]; then
        echo "Verification steps: (none configured)" >&"$fd"
        return
    fi
    echo "Verification steps:" >&"$fd"
    local step
    for step in "${VERIFY_STEPS[@]}"; do
        echo "  - $step" >&"$fd"
    done
}

# Run each configured verify/autofix step, asking Claude to fix what fails,
# up to MAX_VALIDATION_RETRIES passes.
#
# On the `eval "$cmd"` below: this is intentional and cannot be replaced with a
# plain "${cmd_array[@]}" dispatch. A verify step is a *shell command line* the
# user wrote in their own .wiggumrc — `ruff format . && ruff check --fix .`,
# `npm test | tee log`, `cd sub && make` — so it legitimately contains operators,
# pipes, redirections and quoting that only a shell can interpret. Splitting it
# into words and exec'ing it would break every step that uses them.
#
# The trust boundary is therefore .wiggumrc itself: its contents execute with the
# privileges of whoever runs wiggum, exactly like a Makefile or an npm script.
# That is the same trust a user already extends by running the tool in their
# repo. What matters is that nothing *else* reaches this eval: values arrive only
# from load_config_from's fixed key allowlist, never from a plan file, a Claude
# response, or a CLI argument, so a workplan cannot inject a command here.
run_validation() {
    if [[ ${#VERIFY_STEPS[@]} -eq 0 ]]; then
        echo "(No verification steps configured in .wiggumrc - skipping validation)"
        return 0
    fi

    local retries=0

    while true; do
        echo "--- Validation pass (attempt $((retries + 1)) of $MAX_VALIDATION_RETRIES) ---"
        local needs_fix=false
        local prompt=""

        for step in "${VERIFY_STEPS[@]}"; do
            local is_autofix=false
            local cmd="$step"

            if [[ "$step" == autofix:* ]]; then
                is_autofix=true
                cmd="${step#autofix:}"
            fi

            echo "Running: $cmd"
            local output

            if $is_autofix; then
                eval "$cmd" 2>&1 || true
                if output=$(eval "$cmd" 2>&1); then
                    : # autofix resolved it
                else
                    output=$(echo "$output" | tail -n 60)
                    echo "FAILED (after autofix): $cmd"
                    echo "--- Error output ---"
                    echo "$output"
                    echo "--------------------"
                    prompt="WIGGUM VALIDATION FAILURE. The command below was run by wiggum (from .wiggumrc), NOT by your code. If the command itself is wrong (e.g. wrong script name), you CANNOT fix it -- tell the user to update .wiggumrc. Only fix issues in the actual source code. Read the actual error output below before forming a hypothesis -- do not guess from the filename or command alone. After editing, re-run the failing command yourself and confirm it now passes; do not infer success from the edit. $PROMPT_SUFFIX\n\nCommand: $cmd\nSource: .wiggumrc (autofix step)\nExit code: non-zero\n\nError output:\n$output"
                    needs_fix=true
                    break
                fi
            else
                if output=$(eval "$cmd" 2>&1); then
                    : # passed
                else
                    output=$(echo "$output" | tail -n 60)
                    echo "FAILED: $cmd"
                    echo "--- Error output ---"
                    echo "$output"
                    echo "--------------------"
                    prompt="WIGGUM VALIDATION FAILURE. The command below was run by wiggum (from .wiggumrc), NOT by your code. If the command itself is wrong (e.g. wrong script name), you CANNOT fix it -- tell the user to update .wiggumrc. Only fix issues in the actual source code. Read the actual error output below before forming a hypothesis -- do not guess from the filename or command alone. After editing, re-run the failing command yourself and confirm it now passes; do not infer success from the edit. $PROMPT_SUFFIX\n\nCommand: $cmd\nSource: .wiggumrc (verify step)\nExit code: non-zero\n\nError output:\n$output"
                    needs_fix=true
                    break
                fi
            fi
            echo "PASSED: $cmd"
        done

        if [[ "$needs_fix" == true ]]; then
            retries=$((retries + 1))
            if [[ $retries -ge $MAX_VALIDATION_RETRIES ]]; then
                echo ""
                echo "Validation failed $MAX_VALIDATION_RETRIES times. Stopping to prevent runaway."
                echo "Check that your .wiggumrc verify commands are correct."
                echo "Last failing command: $cmd"
                return "$EXIT_VALIDATION_FAILED"
            fi
            echo "Requesting fix from Claude..."
            WIGGUM_CURRENT_LABEL="${WIGGUM_CURRENT_LABEL}-fix-$retries"
            run_claude -p -c "$(echo -e "$prompt")"
            continue
        fi

        echo "All verification steps passed."
        return 0
    done
}

# ── Benchmarks ───────────────────────────────────────────────────────────────

# Extract all numeric values from text (integers and decimals).
# Returns one number per line, suitable for comparison.
extract_benchmark_numbers() {
    grep -oE '[0-9]+(\.[0-9]+)?' | sort -n
}

# Compare two sets of benchmark numbers.  Returns 0 (true) if
# the numbers differ, meaning the benchmark made progress.
benchmark_numbers_changed() {
    local prev_nums="$1"
    local curr_nums="$2"
    [[ "$curr_nums" != "$prev_nums" ]]
}

# Run all benchmark scripts and capture concatenated output.
# Returns empty string if no benchmarks are configured.
#
# The `eval "$script"` here is the same deliberate choice as in run_validation:
# a benchmark is a user-authored shell command line, so pipes and operators must
# work. Note the provenance differs — BENCHMARK_SCRIPTS is filled from
# .wiggumrc *and* from `--benchmark` on the command line, so unlike VERIFY_STEPS
# it is not config-only. Both sources are the invoking user, not the workplan or
# a Claude response, so a plan still cannot inject a command here.
run_benchmarks() {
    if [[ ${#BENCHMARK_SCRIPTS[@]} -eq 0 ]]; then
        return 0
    fi
    local script output
    for script in "${BENCHMARK_SCRIPTS[@]}"; do
        echo "--- Benchmark: $script ---"
        if output=$(eval "$script" 2>&1); then
            echo "$output"
        else
            echo "(failed with exit code $?)"
            echo "$output"
        fi
    done
}

# ── Execute ──────────────────────────────────────────────────────────────────

# Warn that wiggum runs Claude's tools and the .wiggumrc verify steps in the
# *current* shell environment -- so the project's environment must be active, or
# the toolchain resolves to the wrong interpreter and steps fail spuriously.
#
# For Python-flavored projects we can tell whether *an* env is active (via
# VIRTUAL_ENV / a non-base CONDA_DEFAULT_ENV), so we warn preventively in the case
# that actually bites -- pytest/ruff silently running under the wrong interpreter.
# When an env is active, or for non-Python toolchains we can't introspect, we fall
# back to a softer reminder.
env_reminder() {
    local kind=""
    if [[ -f environment.yml || -f environment.yaml ]]; then
        kind="conda"
    elif [[ -f poetry.lock || -f uv.lock || -d .venv || -f Pipfile || -f requirements.txt ]]; then
        kind="python"
    elif [[ -f .nvmrc || -f package.json ]]; then
        kind="node"
    elif [[ -f Gemfile ]]; then
        kind="ruby"
    fi

    if [[ "$kind" == "conda" || "$kind" == "python" ]]; then
        if [[ -n "${VIRTUAL_ENV:-}" ]] \
           || { [[ -n "${CONDA_DEFAULT_ENV:-}" ]] && [[ "${CONDA_DEFAULT_ENV:-}" != "base" ]]; }; then
            echo "Reminder: wiggum runs in your current shell environment ('${VIRTUAL_ENV:-${CONDA_DEFAULT_ENV:-}}' is active) -- make sure it is the right one for this project." >&2
        else
            local how="activate the project's virtualenv"
            [[ "$kind" == "conda" ]] && how="run 'conda activate <env>'"
            echo "Warning: this looks like a Python project but no virtualenv/conda env is active -- ${how} BEFORE launching, or the verify steps (pytest/ruff) run against the wrong interpreter and thrash." >&2
        fi
        return
    fi

    case "$kind" in
        node) echo "Reminder: wiggum runs in your current shell -- select the project's Node version (e.g. 'nvm use') first if it needs one." >&2 ;;
        ruby) echo "Reminder: wiggum runs in your current shell -- use the project's Ruby/bundler env (e.g. 'bundle exec') first if it needs one." >&2 ;;
        *)    echo "Reminder: wiggum runs verify steps and Claude in your current shell environment -- activate the project's environment (conda/venv/poetry/nvm) first if it needs one." >&2 ;;
    esac
}

# Set to true only once run_execute reaches its normal end. The EXIT trap reads
# it to tell an orderly finish from an unwind.
WIGGUM_RUN_FINISHED=true

# EXIT-trap reporter. Any failing command inside run_execute unwinds the whole
# script under `set -e`, skipping the "Status:" line at the bottom of the run.
# Without that line read_run_status finds nothing and `wiggum status` reports
# "not running (no status recorded)", which reads identically to a run that was
# never started. Print the status here so a crash is recorded as a crash.
report_unfinished_run() {
    local rc=$?
    if [[ "${WIGGUM_RUN_FINISHED:-true}" == true ]]; then
        return 0
    fi
    log_entry "abort" "run ended early (exit $rc)"
    {
        echo ""
        echo "Status: aborted (exit $rc)"
        if [[ "$rc" -eq "$EXIT_CLAUDE_FAILED" ]]; then
            echo "The run stopped because a claude session failed, not because the plan finished."
            if [[ -n "$WIGGUM_LAST_FAILURE_OUT" ]]; then
                echo "Transcript: $WIGGUM_LAST_FAILURE_OUT"
            fi
        fi
        if [[ -n "$WIGGUM_LOG_FILE" ]]; then
            echo "Log: $WIGGUM_LOG_FILE"
        fi
        if [[ -n "$WIGGUM_LAST_SESSION_ID" ]]; then
            echo "Session: $WIGGUM_LAST_SESSION_ID"
        fi
        echo "=== WIGGUM RUN ABORTED ==="
    } >&2
    release_run_pidfile
    return "$rc"
}

run_execute() {
    # Surface this before anything else (and before the background hand-off) so
    # the person launching the run sees it, not just the .out log.
    env_reminder

    # A delayed run is handed off first, because --at already detaches: it
    # takes precedence over --background rather than competing with it, so
    # passing both is redundant rather than an error. Say which one took
    # effect -- a flag silently doing nothing is worse than one that is
    # refused, since nobody goes looking for the run that never started.
    #
    # Returning here rather than falling through is the point: --background
    # would otherwise pick the run up and start it now, which is the opposite
    # of what asking for a later time meant.
    if [[ -n "$AT_TIME" ]]; then
        if [[ "$BACKGROUND" == true ]]; then
            echo "Note: --at already detaches; --background is redundant and was ignored." >&2
        fi
        launch_execute_delayed
        return $?
    fi

    # In background mode, hand off to the launcher, which re-enters this
    # function (with BACKGROUND cleared) inside a detached subshell.
    if [[ "$BACKGROUND" == true ]]; then
        launch_execute_background
        return $?
    fi

    WIGGUM_RUN_FINISHED=false
    trap 'report_unfinished_run' EXIT

    # Register the run before the first phase, not after it: the plan being
    # worked on right now is exactly what `top` is asked about.
    claim_run_pidfile "${FILES[0]:-}"

    echo "=== WIGGUM EXECUTE MODE ===" >&2
    echo "Input files: ${FILES[*]}" >&2
    echo "Max iterations: $MAX_ITERATIONS" >&2
    echo "Summary output: $SUMMARY_FILE" >&2
    print_verify_steps 2
    if [[ ${#BENCHMARK_SCRIPTS[@]} -gt 0 ]]; then
        echo "Benchmarks:" >&2
        local script
        for script in "${BENCHMARK_SCRIPTS[@]}"; do
            echo "  - $script" >&2
        done
    fi
    echo "" >&2

    if [[ -n "$STDIN_FILE" ]]; then
        log_init "$SUMMARY_FILE"
    else
        log_init "${FILES[0]}"
    fi
    local file_list="${FILES[*]}"

    warn_if_plan_large "${FILES[@]}"

    # Phase 1: Diagnostic & status sync
    echo "--- Phase 1: Diagnostic & Status Sync ---" >&2
    log_entry "phase" "1 - diagnostic & status sync"
    WIGGUM_CURRENT_LABEL="phase1-diagnostic"
    run_claude -p \
        "$(prompt_workplan "$file_list") Analyze the repository against the workplan. Verify before claiming -- when checking whether a task is done, read the actual file or run the actual command. Do not infer status from filenames, comments, or commit messages. If a task touches state shared with other modules (a status column, a config flag, a lifecycle field), grep every site that writes it and enumerate the values it can leave behind, including transient ones from interrupted runs. If implementation status is inaccurate, update the plan using [x] for done, [ ] for not done. Leave \`[~]\` lines untouched. \`[~]\` is the terminal dropped state -- the work was intentionally abandoned and is not pending. Do not convert \`[~]\` to \`[ ]\` or \`[x]\`. First, make sure every task is a Markdown checkbox wiggum can track: if any task is written as a heading, bold text, a numbered item, or plain prose without a \`[ ]\`/\`[x]\`/\`[~]\` box, rewrite just that line as a \`- [ ]\` checkbox (preserving its done/dropped state). Wiggum measures progress by counting these boxes, so a task without one is invisible to it. Beyond adding any missing checkboxes, do not change the plan structure. List the next steps to implement. $PROMPT_SUFFIX" \
        "${FILES[@]}"

    if [[ "$NO_COMMIT" == true ]]; then
        echo "(commit skipped via --no-commit)" >&2
    else
        WIGGUM_CURRENT_LABEL="phase1-commit"
        run_claude -p \
            "Check if $file_list has any changes (modified or untracked). If so, execute 'git add $file_list' and 'git commit -m \"reconcile plan status\"'. $PROMPT_SUFFIX If there are no changes, do nothing."
    fi

    # Phase 2: Iterative implementation
    local stall_count=0
    local prev_remaining prev_dropped
    prev_remaining="$(count_unchecked "${FILES[@]}")"
    prev_dropped="$(count_dropped "${FILES[@]}")"
    local stop_reason="incomplete"
    local benchmark_output=""
    local prev_benchmark_nums=""

    # Nothing to implement: skip the loop instead of burning a full
    # implement/verify/commit cycle on a plan with no pending tasks. This fires
    # either when phase 1 found everything already done, or when the plan has no
    # task checkboxes wiggum can track at all (a formatting problem worth
    # flagging, not a reason to spin Claude).
    if [[ "$prev_remaining" -eq 0 ]]; then
        if [[ "$(count_total_tasks "${FILES[@]}")" -eq 0 ]]; then
            echo "Warning: the plan has no trackable tasks -- expected checkbox" \
                 "lines like '- [ ] ...' or '### [ ] ...'. Skipping implementation." >&2
            log_entry "warn" "plan has no trackable task checkboxes"
        else
            echo "No pending tasks in the plan -- skipping implementation." >&2
            log_entry "phase" "2 - skipped (no pending tasks)"
        fi
        stop_reason="complete"
    fi

    for ((i = 1; i <= MAX_ITERATIONS && prev_remaining > 0; i++)); do
        echo "" >&2
        echo "--- Phase 2: Iteration $i of $MAX_ITERATIONS ($prev_remaining tasks remaining, $prev_dropped dropped) ---" >&2
        log_entry "phase" "2 - iteration $i of $MAX_ITERATIONS ($prev_remaining tasks remaining, $prev_dropped dropped)"

        # Implementation: bypassPermissions so file changes are auto-approved
        local benchmark_context=""
        if [[ -n "$benchmark_output" ]]; then
            benchmark_context="\n\nBenchmark results from the previous iteration:\n$benchmark_output\n\nUse these results to guide your implementation — focus on improving the metrics."
        fi
        WIGGUM_CURRENT_LABEL="phase2-implement-$i"
        run_claude -p -c \
            "$(prompt_workplan "$file_list") Execute the next discrete implementation step from the plan. The next step is the next \`[ ]\` task. Skip any task marked \`[~]\` -- that is the dropped state, an in-plan decision not to do the work. Treat \`[~]\` as terminal, like \`[x]\`. Do not revisit, reconcile, or re-evaluate \`[~]\` lines. $(prompt_implement_verification) Fix any existing issues found. Do your own legwork -- if a question can be answered by running a command, reading a file, or grepping the repo, do it yourself rather than stopping to ask. Only ask the user when you genuinely lack access or the action is destructive.${benchmark_context} $PROMPT_SUFFIX" \
            "${FILES[@]}"

        # Validation: uses -c to keep implementation context for fixes
        if [[ "$NO_VERIFY" == true ]]; then
            echo "(verification skipped via --no-verify)" >&2
        else
            WIGGUM_CURRENT_LABEL="phase2-validate-$i"
            run_validation || echo "Warning: validation did not fully pass on iteration $i" >&2
        fi

        # Commit: bypassPermissions so git commands run without prompting
        echo "Committing changes..." >&2
        commit_or_skip "phase2-commit-$i"

        # Run benchmarks after commit (output feeds into next iteration)
        local curr_benchmark_nums=""
        if [[ ${#BENCHMARK_SCRIPTS[@]} -gt 0 ]]; then
            echo "Running benchmarks..." >&2
            benchmark_output="$(run_benchmarks)"
            echo "$benchmark_output" >&2
            log_entry "benchmark" "$benchmark_output"
            curr_benchmark_nums="$(echo "$benchmark_output" | extract_benchmark_numbers)"
        fi

        # Check progress: tasks completed OR benchmark numbers changed
        local remaining dropped
        remaining="$(count_unchecked "${FILES[@]}")"
        dropped="$(count_dropped "${FILES[@]}")"

        # `count_unchecked` excludes `[~]`, so an all-dropped plan reports
        # remaining=0 here and short-circuits to `complete` -- no further
        # implementation iterations run. Do not re-introduce `[~]` into
        # `count_unchecked`'s regex, or this branch will stop firing and
        # dropped tasks will trigger false stalls again.
        if [[ "$remaining" -eq 0 ]]; then
            echo "All tasks complete — stopping early." >&2
            log_entry "stop" "all tasks complete after iteration $i"
            stop_reason="complete"
            break
        fi

        local task_progress=false
        if [[ "$remaining" -lt "$prev_remaining" ]]; then
            task_progress=true
        fi

        local benchmark_progress=false
        if [[ ${#BENCHMARK_SCRIPTS[@]} -gt 0 ]] \
              && benchmark_numbers_changed "$prev_benchmark_nums" "$curr_benchmark_nums"; then
            benchmark_progress=true
        fi

        if $task_progress || $benchmark_progress; then
            stall_count=0
            if $benchmark_progress && ! $task_progress; then
                echo "Benchmark metrics changed ($remaining tasks remaining — benchmark progress counts)." >&2
                log_entry "progress" "benchmark metrics changed on iteration $i ($remaining remaining)"
            fi
        else
            stall_count=$((stall_count + 1))
            echo "No progress detected ($remaining tasks remaining, $dropped dropped, stall $stall_count of $MAX_STALL_COUNT)." >&2
            log_entry "stall" "no progress on iteration $i ($remaining remaining, $dropped dropped, stall $stall_count)"
            if [[ "$stall_count" -ge "$MAX_STALL_COUNT" ]]; then
                echo "Stalled for $MAX_STALL_COUNT consecutive iterations — stopping." >&2
                log_entry "stop" "stalled after iteration $i"
                stop_reason="stalled"
                break
            fi
        fi

        prev_benchmark_nums="$curr_benchmark_nums"

        prev_remaining="$remaining"
        prev_dropped="$dropped"
    done

    # Phase 3: Summary & alignment
    echo "" >&2
    echo "--- Phase 3: Summary & Alignment (${stop_reason}) ---" >&2
    log_entry "phase" "3 - summary & alignment ($stop_reason)"

    local final_benchmark_context=""
    if [[ ${#BENCHMARK_SCRIPTS[@]} -gt 0 && -n "$benchmark_output" ]]; then
        final_benchmark_context="\n\nFinal benchmark results:\n$benchmark_output\n\nInclude these benchmark results in the summary."
    fi

    local dropped_context
    dropped_context="$(build_dropped_context "${FILES[@]}")"

    WIGGUM_CURRENT_LABEL="phase3-summary"
    run_claude -p -c \
        "$(prompt_workplan "$file_list") Execution stopped because: $stop_reason. Review all implementation work done. 1. Update the plan files ($file_list) by marking completed tasks with [x]. 2. $(prompt_issue_ledger) 3. Write a concise execution summary to $SUMMARY_FILE covering: what was implemented, what was deferred, any issues encountered, verification results, which issue-ledger entries you closed and which stay open (and where that ledger is, or that the repo keeps none), and why execution stopped ($stop_reason).${final_benchmark_context}${dropped_context} $PROMPT_SUFFIX" \
        "${FILES[@]}"

    commit_or_skip "phase3-commit" "$SUMMARY_FILE, $file_list, and any issue ledger updated"

    echo "" >&2

    # Phase 4 (optional): Update documentation
    if [[ ${#UPDATE_DOCS[@]} -gt 0 ]]; then
        echo "" >&2
        echo "--- Phase 4: Documentation Update ---" >&2
        log_entry "phase" "4 - documentation update"
        WIGGUM_CURRENT_LABEL="phase4-docs"
        run_update_docs "$SUMMARY_FILE" "${FILES[@]}" -- "${UPDATE_DOCS[@]}"
    fi

    if [[ -n "$STDIN_FILE" ]]; then
        rm -f "$STDIN_FILE"
    fi

    # Rename plan and summary to meaningful filenames
    if [[ "${FILES[0]}" == docs/stdin.md ]]; then
        local slug
        slug="$(slugify "${FILES[0]}")"
        local final_plan="docs/${slug}_plan.md"
        local final_summary="docs/${slug}_summary.md"
        mv "${FILES[0]}" "$final_plan"
        echo "Plan: $final_plan" >&2
        if [[ -f "$SUMMARY_FILE" ]]; then
            mv "$SUMMARY_FILE" "$final_summary"
            echo "Summary: $final_summary" >&2
        fi
    elif [[ -f "$SUMMARY_FILE" ]]; then
        echo "Summary: $SUMMARY_FILE" >&2
    fi

    log_entry "complete" "wiggum execution finished ($stop_reason)"
    echo "Status: $stop_reason" >&2
    echo "Log: $WIGGUM_LOG_FILE" >&2
    echo "Session: $WIGGUM_LAST_SESSION_ID" >&2
    echo "=== WIGGUM EXECUTION COMPLETE ===" >&2

    WIGGUM_RUN_FINISHED=true
    release_run_pidfile
    trap - EXIT
}

# ── Orchestration (background / status / watch / kill / chain) ────────────────

# Return 0 if PID names a live process. Thin wrapper so callers read clearly
# and tests can exercise it against a real backgrounded process.
process_alive() {
    local pid="$1"
    [[ -n "$pid" ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

# Echo the last execution status recorded in a run's output file. run_execute
# prints "Status: complete|stalled|incomplete" at the end; in background mode
# that line is captured into the .out file. Echoes nothing when the file is
# missing or no status has been written yet (i.e. the run is still going).
# Marker written to a run's `.out` at launch. `.out` appends (see
# launch_execute_background), so the readers below need a way to tell this run's
# output from the last one's.
# Matches the separator `.log` has always used, and deliberately NOT the
# `=== WIGGUM RUN ABORTED ===` banner report_unfinished_run writes into `.out`:
# an `=== WIGGUM RUN` prefix matches that banner too, and slicing from it hides
# the `Status: aborted` line printed just above.
WIGGUM_RUN_SEPARATOR_PREFIX='--- wiggum run'

# Echo only the current run's portion of a `.out` -- everything from the last run
# separator onward. Falls back to the whole file when no separator is present, so
# `.out` files written before separators existed, and foreground runs, still read
# correctly.
current_run_slice() {
    local outfile="$1"
    [[ -f "$outfile" ]] || return 0
    # `|| true`, because a `.out` with no separator is the ordinary case for a
    # file written before separators existed. grep exits 1 on no match and
    # `pipefail` propagates that, so without this the assignment fails and
    # `set -e` takes the whole command down.
    local start
    start="$(grep -n "^${WIGGUM_RUN_SEPARATOR_PREFIX} " "$outfile" | tail -n1 | cut -d: -f1 || true)"
    if [[ -n "$start" ]]; then
        tail -n +"$start" "$outfile"
    else
        cat "$outfile"
    fi
}

# Remove a run's pidfile only if it still names the pid we were supervising.
# `watch` and `kill` both clean up when their run ends; a relaunch in that window
# puts a NEW pid in the file, and removing it then orphans a live run from
# status/watch/kill. The symptom is indistinguishable from a clean finish --
# `watch` exits 0 with "No background run found" while the run is still working.
release_pidfile() {
    local pidfile="$1" expected="$2"
    [[ -f "$pidfile" ]] || return 0
    local current
    current="$(tr -d '[:space:]' < "$pidfile")"
    if [[ "$current" == "$expected" ]]; then
        rm -f "$pidfile"
    fi
    return 0
}

# Where runs announce themselves machine-wide, one file per run, named by pid
# and holding the absolute base path of the plan it is working on.
#
# The `.pid` sidecar alone can only ever answer "what is running *here*",
# because finding one means already knowing which directory to look in. `top`
# is asked the other question -- "what is running" -- and answering it from the
# current directory made an idle project look like an idle machine. The process
# table would answer it too, but only by matching command lines, which is the
# liveness guess this repo refuses everywhere else.
#
# Overridable so a test never writes into the real home directory.
WIGGUM_REGISTRY_DIR="${WIGGUM_REGISTRY_DIR:-${HOME:-/tmp}/.wiggum/runs}"

# Absolute base path (the plan minus its `.md`) for a plan given by any path.
# `top` prints these for runs outside the current directory, so a row says
# which project it belongs to rather than just which plan.
absolute_run_base() {
    local base="$1" dir name
    dir="$(cd "$(dirname "$base")" 2>/dev/null && pwd)" || return 0
    name="$(basename "$base" .md)"
    printf '%s/%s\n' "$dir" "$name"
}

# Announce a run in the machine-wide registry. Keyed by the pid that is doing
# the work, so a dead entry is self-evident and can be pruned on sight.
register_run() {
    local pid="$1" base="$2" abs
    [[ -n "$pid" && -n "$base" ]] || return 0
    abs="$(absolute_run_base "$base")"
    [[ -n "$abs" ]] || return 0
    mkdir -p "$WIGGUM_REGISTRY_DIR" 2>/dev/null || return 0
    printf '%s\n' "$abs" > "$WIGGUM_REGISTRY_DIR/$pid" 2>/dev/null || return 0
    return 0
}

# Every run registered anywhere on this machine, as absolute base paths.
#
# Reading prunes: an entry whose pid is gone belongs to a run that ended, or
# one killed before it could clean up after itself. Nothing else sweeps this
# directory, so the read has to, or a crash would leave a phantom run listed
# forever -- and a `top` that invents runs is no better than one that hides
# them.
find_registered_runs() {
    [[ -d "$WIGGUM_REGISTRY_DIR" ]] || return 0
    local f pid base
    for f in "$WIGGUM_REGISTRY_DIR"/*; do
        [[ -f "$f" ]] || continue
        pid="$(basename "$f")"
        if ! process_alive "$pid"; then
            rm -f "$f"
            continue
        fi
        base="$(head -n1 "$f")"
        [[ -n "$base" ]] && echo "$base"
    done
    return 0
}

# The live pid a base path is registered under, if any.
#
# Splits the two jobs the sidecars were doing at once: the `.pid` next to a plan
# says *where* a run is, the registry says *whether it is alive*. They are
# written together, so normally either answers both -- but a run whose sidecar
# went missing under it is still a run, and reporting it as "not running" is the
# exact failure `top` exists to prevent. The registry is the authority on
# liveness; the sidecar is preferred only because it is the cheaper read.
registered_pid_for_base() {
    local want="$1"
    [[ -n "$want" && -d "$WIGGUM_REGISTRY_DIR" ]] || return 0
    local f pid
    for f in "$WIGGUM_REGISTRY_DIR"/*; do
        [[ -f "$f" ]] || continue
        [[ "$(head -n1 "$f")" == "$want" ]] || continue
        pid="$(basename "$f")"
        if process_alive "$pid"; then
            printf '%s\n' "$pid"
            return 0
        fi
    done
    return 0
}

# Drop a run's registry entry. Takes the pid it was filed under, which is not
# always `$$`: launch_execute_background files its detached child under the
# child's pid.
unregister_run() {
    local pid="$1"
    [[ -n "$pid" ]] || return 0
    rm -f "$WIGGUM_REGISTRY_DIR/$pid"
    return 0
}

# Record the running process in the plan's `.pid` sidecar.
#
# That sidecar is the only thing `top`/`status`/`watch`/`kill` look for, and it
# used to be written exclusively by `execute --background` and the `--at`
# waiter. A foreground `wiggum execute` wrote none -- and `run_chain` runs every
# one of its plans in the foreground, so an entire chain was invisible to
# supervision. Worse, `top` still rendered rows for the stale pidfiles finished
# background runs leave behind, so the table read as "every plan finished,
# nothing running" while two chains were working. That is the dangerous
# direction to be wrong in: it invites launching more work onto a loaded box.
#
# Skipped when WIGGUM_RUN_PIDFILE is already set, which is how
# launch_execute_background tells the detached child that the file is spoken
# for. The launcher wrote the subshell's pid, which is the one `kill` must
# stop; `$$` inside that subshell is the *parent's* pid (bash 3.2 has no
# $BASHPID), so a child re-claim would aim every supervision command at the
# wrong process.
#
# A sidecar naming a live process is left alone rather than clobbered. Two runs
# on one plan is already a mistake; overwriting would orphan the first from
# `watch` and `kill`, which is the exact failure release_pidfile exists to
# prevent.
claim_run_pidfile() {
    local base="${1:-}"
    [[ -n "$base" ]] || return 0
    [[ -z "$WIGGUM_RUN_PIDFILE" ]] || return 0

    local pidfile existing=""
    pidfile="$(run_sidecar_file "$base" pid)"
    if [[ -f "$pidfile" ]]; then
        existing="$(tr -d '[:space:]' < "$pidfile")"
    fi
    if process_alive "$existing"; then
        echo "Warning: another wiggum run is already active for $base (pid $existing);" \
             "leaving its sidecar in place -- this run will not appear in 'wiggum top'." >&2
        return 0
    fi

    mkdir -p "$(dirname "$pidfile")"
    printf '%s\n' "$$" > "$pidfile"
    WIGGUM_RUN_PIDFILE="$pidfile"
    register_run "$$" "$base"
    return 0
}

# Drop the sidecar this run claimed, once the run is over.
#
# Releasing matters most for a chain: the plan that just finished has to stop
# showing as running before the next one starts, or `top` reports the chain
# against a plan it has already moved off. It also keeps finished foreground
# runs from accumulating as rows that are neither running nor reportable -- a
# foreground run writes no `.out`, so such a row has no status to show.
#
# The rule is one line of release_pidfile: remove the file only while it still
# names *this* process. That covers three cases at once. A relaunch that reused
# the sidecar in the meantime keeps its claim. A run that never claimed one has
# nothing to remove. And the file launch_execute_background wrote survives,
# because it names the detached subshell rather than `$$` -- which is what lets
# `status` still report on a background run nobody watched.
release_run_pidfile() {
    [[ -n "$WIGGUM_RUN_PIDFILE" ]] || return 0
    release_pidfile "$WIGGUM_RUN_PIDFILE" "$$"
    unregister_run "$$"
    WIGGUM_RUN_PIDFILE=""
    return 0
}

# Echoes nothing, successfully, when the run recorded no status. That is a
# normal state (a run still going, or one killed before it could write one),
# not an error: `grep` exits 1 on no match, `pipefail` propagates it, and a
# bare failure here used to abort `wiggum top` part-way through its list --
# printing a truncated table and exiting 1, which reads as "those are all the
# runs" rather than "this command failed".
read_run_status() {
    local outfile="$1"
    [[ -f "$outfile" ]] || return 0
    current_run_slice "$outfile" | grep -E '^Status: ' | tail -n1 | sed -E 's/^Status: //' || true
}

# Return 0 if a run's output shows it is blocked: a stall was detected, the
# validation waterfall gave up, or progress repeatedly failed to advance.
# Used by `status`/`watch` to flag runs that are spinning rather than working.
detect_blocked() {
    local outfile="$1"
    [[ -f "$outfile" ]] || return 1
    current_run_slice "$outfile" \
        | grep -qE 'No progress detected|Stalled for|validation did not fully pass|Validation failed [0-9]+ times'
}

# One-line task progress summary. Args: total done remaining dropped
format_progress() {
    local total="$1" done="$2" remaining="$3" dropped="$4"
    echo "Tasks: ${done}/${total} done, ${remaining} remaining, ${dropped} dropped"
}

# Launch `run_execute` detached, recording its pid and capturing all output to
# a sidecar .out file so `watch`/`status`/`kill` can find and supervise it.
# The pid written is wiggum's own (a backgrounded subshell running the loop) --
# never a blanket process name -- so `kill` only ever stops this run.
launch_execute_background() {
    local base="${FILES[0]}"
    local pidfile outfile
    pidfile="$(run_sidecar_file "$base" pid)"
    outfile="$(run_sidecar_file "$base" out)"
    mkdir -p "$(dirname "$pidfile")"

    # Refuse to start a second run over a live one; its pidfile would be
    # clobbered and `watch`/`kill` would lose track of the original process.
    if [[ -f "$pidfile" ]]; then
        local existing
        existing="$(tr -d '[:space:]' < "$pidfile")"
        if process_alive "$existing"; then
            echo "A wiggum run is already active for $base (pid $existing)." >&2
            echo "Use 'wiggum watch $base' or 'wiggum kill $base' first." >&2
            return "$EXIT_BAD_ARGS"
        fi
    fi

    # Clear BACKGROUND so the detached subshell runs the real loop instead of
    # recursing back into this launcher.
    BACKGROUND=false
    # Claim the sidecar on the child's behalf, BEFORE forking so the child
    # inherits the claim: the pid that belongs in this file is the subshell's,
    # which only the parent can see (`$!`), and the child would otherwise write
    # `$$` -- this shell's pid -- over it and misdirect `watch` and `kill`.
    WIGGUM_RUN_PIDFILE="$pidfile"
    # Append rather than truncate: relaunching a plan used to destroy the log of
    # the very run you are relaunching because of, which is the output you need
    # to diagnose it. `.log` has always appended with a per-run separator; `.out`
    # now matches. The separator is written HERE, synchronously, not inside the
    # subshell -- `watch` can attach before a backgrounded write lands, and it
    # needs the marker to know where this run's output starts.
    printf '%s %s ---\n' "$WIGGUM_RUN_SEPARATOR_PREFIX" "$(date '+%Y-%m-%d %H:%M:%S')" >> "$outfile"
    ( run_execute ) >>"$outfile" 2>&1 &
    local pid=$!
    echo "$pid" > "$pidfile"
    # File the child under its own pid, not this shell's: the CLI exits as soon
    # as this function returns, and an entry keyed to a dead launcher would be
    # pruned out from under a run that is still going. Nothing unregisters it
    # when the run ends -- find_registered_runs prunes it when the pid goes.
    register_run "$pid" "$base"

    echo "Started wiggum execute in the background." >&2
    echo "  pid:     $pid" >&2
    echo "  output:  $outfile" >&2
    echo "  watch:   wiggum watch $base" >&2
    echo "  status:  wiggum status $base" >&2
    echo "  kill:    wiggum kill $base" >&2
}

# How often the waiter re-reads the wall clock, in seconds. Overridable from
# the environment so a test can schedule a run two seconds out without waiting
# a poll interval for it.
WIGGUM_AT_POLL_INTERVAL="${WIGGUM_AT_POLL_INTERVAL:-30}"

# Block until the wall clock reaches TARGET.
#
# Polls rather than sleeping the whole interval in one go. A single long
# `sleep` is suspended along with the machine and resumes afterwards, so it
# fires late by roughly the suspend duration -- on a laptop, that is every
# overnight schedule. Re-reading the clock self-corrects across a suspend.
#
# Deliberately no wake lock: no `caffeinate`, no `pmset`, nothing that decides
# on the user's behalf whether their machine stays awake. If it was asleep at
# the target the run starts on wake, late, and says so.
wait_until_epoch() {
    local target="$1" now nap
    while :; do
        now="$(wiggum_now_epoch)"
        [ "$now" -lt "$target" ] || break
        nap=$((target - now))
        if [ "$nap" -gt "$WIGGUM_AT_POLL_INTERVAL" ]; then
            nap="$WIGGUM_AT_POLL_INTERVAL"
        fi
        sleep "$nap"
    done
}

# How long to wait for a detached waiter to claim its schedule, in seconds.
# The waiter writes the sidecar as its first statement, before it can block on
# anything, so this is a guard against a launch that never happened rather than
# an allowance for a slow one.
WIGGUM_AT_CLAIM_TIMEOUT="${WIGGUM_AT_CLAIM_TIMEOUT:-10}"

# Rebuild the command line a delayed run should replay: exactly what the user
# typed, minus the two flags that describe the hand-off rather than the run.
#
# Replaying argv is what keeps `--at` faithful. The alternative -- snapshotting
# the globals parse_args set and restoring them in the waiter -- means naming
# every execute option, and the next option added is one nobody remembers to
# add to the list, so `--at` quietly stops honouring it. Here the run at 01:07
# is the command that was typed, re-parsed against the config as it stands then.
#
# `--at` goes because the waiter would otherwise schedule another waiter.
# `--background` goes because the waiter runs the CLI in the foreground of its
# own session: a daemonizing child would let that session exit immediately and
# take the run down with it.
#
# Emitted NUL-separated so an argument containing whitespace survives the trip.
# Falls back to `execute <files>` when nothing was captured, which is the case
# when the library is driven directly rather than through the CLI.
at_replay_argv() {
    local arg skip=false emitted=false
    for arg in ${WIGGUM_ARGV[@]+"${WIGGUM_ARGV[@]}"}; do
        if [[ "$skip" == true ]]; then
            skip=false
            continue
        fi
        case "$arg" in
            --at)
                skip=true
                ;;
            -b|--background)
                ;;
            *)
                printf '%s\0' "$arg"
                emitted=true
                ;;
        esac
    done

    if [[ "$emitted" != true ]]; then
        printf '%s\0' execute ${FILES[@]+"${FILES[@]}"}
    fi
}

# The body of the detached waiter, run by a fresh bash under `screen` or
# `nohup`.
#
# It re-sources the library for `wait_until_epoch` and re-invokes the CLI for
# the run itself, because a detached process inherits no shell functions.
# Everything it varies on arrives through the environment; the command line
# carries only the argv to replay, so no quoting has to survive being flattened
# into a string.
at_waiter_script() {
    cat <<'WAITER'
set -uo pipefail
cd "$WIGGUM_AT_CWD" || exit 1

# Claim the schedule first, and with this process's own pid. `screen -dmS`
# forks and tells the caller nothing about what it started, so this sidecar is
# how the launcher learns which single process `status` should report and
# `kill` should stop -- the alternative being a pattern match over the process
# table, which is the liveness guess this repo avoids everywhere else. Written
# to a temp file and moved into place so a concurrent reader never sees half a
# sidecar.
#
# A failed claim is a hard exit, not a warning. The launcher reports an
# unclaimed schedule as nothing having been scheduled, and a waiter that
# outlived that message would start a run hours later that the user was told
# would never happen.
printf 'target=%s\ntarget_human=%s\nspec=%s\npid=%s\n' \
    "$WIGGUM_AT_TARGET" "$WIGGUM_AT_HUMAN" "$WIGGUM_AT_SPEC" "$$" \
    > "$WIGGUM_AT_SCHEDULED.$$" \
    && mv "$WIGGUM_AT_SCHEDULED.$$" "$WIGGUM_AT_SCHEDULED" \
    || { rm -f "$WIGGUM_AT_SCHEDULED.$$"; exit 1; }

source "$WIGGUM_AT_LIB"
wait_until_epoch "$WIGGUM_AT_TARGET"

# Swap scheduled for running. The sidecar goes before the pidfile arrives, so
# no reader is ever left holding both and having to guess which one is true.
rm -f "$WIGGUM_AT_SCHEDULED"
printf '%s %s ---\n' "$WIGGUM_RUN_SEPARATOR_PREFIX" "$(date '+%Y-%m-%d %H:%M:%S')" >> "$WIGGUM_AT_OUT"
"$WIGGUM_AT_CLI" "$@" >> "$WIGGUM_AT_OUT" 2>&1 &
wiggum_run_pid=$!
echo "$wiggum_run_pid" > "$WIGGUM_AT_PIDFILE"
# Stay alive for the run rather than exiting into it, so the run has a parent
# to be torn down with instead of being orphaned mid-flight.
wait "$wiggum_run_pid"
WAITER
}

# Start the waiter somewhere it can outlive the shell that scheduled it.
#
# `screen -dmS` first, because it puts the waiter in a session of its own. That
# is the property that matters: a backgrounded subshell stays in the calling
# shell's process group and dies with the terminal, and the wait here is
# measured in hours. `nohup` is the fallback when screen is absent or refuses
# to start -- it buys immunity to SIGHUP and nothing more, which is weaker, but
# macOS has no `setsid` so it is what is left.
#
# No wake lock on either path: nothing here calls `caffeinate` or `pmset`.
# Whether the machine is awake at the target time is the user's decision about
# their own hardware, and taking it silently from a shell is worse than a run
# that starts late.
start_at_waiter() {
    local session="$1"
    shift

    if command -v screen >/dev/null 2>&1; then
        if screen -dmS "$session" "$@"; then
            return 0
        fi
        echo "Warning: screen could not start the waiter; falling back to nohup." >&2
    else
        echo "Note: screen is not installed; detaching the waiter with nohup." >&2
    fi

    nohup "$@" </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
}

# Read one `key=value` field out of a run's `.scheduled` sidecar. Echoes
# nothing when the file or the field is missing, so a truncated sidecar reads
# as absent rather than crashing its caller.
read_schedule_field() {
    local schedfile="$1" field="$2"
    [[ -f "$schedfile" ]] || return 0
    sed -n "s/^${field}=//p" "$schedfile" | tail -n1
}

# Schedule a run for a wall-clock time and hand it to a waiter that starts it.
#
# Kept separate from launch_execute_background because a scheduled run must not
# look like a running one. Writing the pidfile now would make `status` report a
# run as active while it is only sleeping, and `watch` attach to a process that
# produces nothing for hours; the `.scheduled` sidecar keeps the two states
# distinguishable, and the waiter swaps one for the other when it fires.
#
# Exactly one run results. Nothing recurring is written anywhere -- no crontab
# line, no LaunchAgent -- because one invocation should mean one run.
launch_execute_delayed() {
    local base="${FILES[0]}"
    local spec="$AT_TIME"
    local pidfile schedfile outfile target now waiting
    pidfile="$(run_sidecar_file "$base" pid)"
    schedfile="$(run_sidecar_file "$base" scheduled)"
    outfile="$(run_sidecar_file "$base" out)"
    mkdir -p "$(dirname "$pidfile")"

    # Same refusal as --background, for the same reason: a second run would
    # clobber the pidfile and orphan the first from watch/kill.
    if [[ -f "$pidfile" ]]; then
        local existing
        existing="$(tr -d '[:space:]' < "$pidfile")"
        if process_alive "$existing"; then
            echo "A wiggum run is already active for $base (pid $existing)." >&2
            echo "Use 'wiggum watch $base' or 'wiggum kill $base' first." >&2
            return "$EXIT_BAD_ARGS"
        fi
    fi

    # And refuse a second schedule over a live waiter, which would queue two
    # runs of the same plan against each other. A sidecar whose waiter has died
    # is stale rather than a conflict -- a machine that was off at the target
    # time is the ordinary case -- so it is overwritten below.
    waiting="$(read_schedule_field "$schedfile" pid)"
    if process_alive "$waiting"; then
        echo "A wiggum run is already scheduled for $base (pid $waiting)." >&2
        echo "  when:   $(read_schedule_field "$schedfile" target_human)" >&2
        echo "Use 'wiggum status $base' or 'wiggum kill $base' first." >&2
        return "$EXIT_BAD_ARGS"
    fi

    # parse_args validated this already; re-resolving here is what turns the
    # spec into an epoch, and it keeps the launcher usable on its own.
    if ! target="$(parse_at_time "$spec")"; then
        echo "Error: invalid --at '$spec' (expected +<N>m|h|d, HH:MM or @<epoch>; e.g. +90m, 01:07, @1756180020)." >&2
        return "$EXIT_BAD_ARGS"
    fi

    now="$(wiggum_now_epoch)"
    if [ "$target" -le "$now" ]; then
        echo "Error: --at '$spec' resolves to $(format_duration $((now - target))) in the past; nothing was scheduled." >&2
        return "$EXIT_BAD_ARGS"
    fi

    local human
    human="$(describe_at_target "$target")"

    # Work out what the waiter will run before clearing anything, so the
    # replay describes the command as it was typed.
    local arg
    local -a replay=()
    while IFS= read -r -d '' arg; do
        replay+=("$arg")
    done < <(at_replay_argv)

    # Clear both flags for anything that keeps going in this process: BACKGROUND
    # for --background, AT_TIME for this one. Neither reaches the waiter -- it
    # is a separate process replaying a command line both flags were stripped
    # from -- but a caller that carries on in-process must not re-enter a
    # launcher on the way out.
    BACKGROUND=false
    AT_TIME=""

    # The waiter writes the sidecar, the pidfile and the run separator itself.
    # The separator marks where this run's output begins, so dating it now
    # would put it hours early; the sidecar is written there because that is
    # the only place the waiter's own pid is known.
    local session
    session="wiggum-$(slugify "$base")"

    local -a waiter_env=(
        "WIGGUM_AT_CWD=$PWD"
        "WIGGUM_AT_LIB=$WIGGUM_LIB_PATH"
        "WIGGUM_AT_CLI=$WIGGUM_CLI"
        "WIGGUM_AT_TARGET=$target"
        "WIGGUM_AT_HUMAN=$human"
        "WIGGUM_AT_SPEC=$spec"
        "WIGGUM_AT_SCHEDULED=$schedfile"
        "WIGGUM_AT_OUT=$outfile"
        "WIGGUM_AT_PIDFILE=$pidfile"
        "WIGGUM_AT_POLL_INTERVAL=$WIGGUM_AT_POLL_INTERVAL"
    )

    # Drop any stale sidecar first. Every refusal is behind us, so whatever is
    # here names a waiter that is already dead -- and leaving it would make the
    # claim below read the dead pid back as if it were the new waiter's.
    rm -f "$schedfile"

    if ! start_at_waiter "$session" \
            env "${waiter_env[@]}" \
            bash -c "$(at_waiter_script)" "$session" ${replay[@]+"${replay[@]}"}; then
        echo "Error: could not detach a waiter for $base; nothing was scheduled." >&2
        return "$EXIT_BAD_ARGS"
    fi

    # Learn the waiter's pid from the sidecar it claims the schedule with.
    # `screen -dmS` reports nothing about what it forked, so there is no `$!`
    # worth capturing on that path, and guessing from the process table is the
    # pattern match this repo refuses everywhere else.
    local waiter="" tries=$((WIGGUM_AT_CLAIM_TIMEOUT * 10))
    while [ "$tries" -gt 0 ]; do
        waiter="$(read_schedule_field "$schedfile" pid)"
        if [[ -n "$waiter" ]]; then
            break
        fi
        sleep 0.1
        tries=$((tries - 1))
    done

    if [[ -z "$waiter" ]]; then
        # Nothing to clean up. The waiter claims the schedule before it can
        # block on anything, so an unclaimed one never started rather than
        # running silently somewhere.
        echo "Error: the waiter for $base did not start within ${WIGGUM_AT_CLAIM_TIMEOUT}s;" \
             "nothing was scheduled." >&2
        return "$EXIT_BAD_ARGS"
    fi

    echo "Scheduled wiggum execute for $human (in $(format_duration $((target - now))))." >&2
    echo "  plan:    $base" >&2
    echo "  pid:     $waiter" >&2
    echo "  output:  $outfile" >&2
    echo "  status:  wiggum status $base" >&2
    echo "  kill:    wiggum kill $base" >&2
    echo "Runs once. Nothing recurring was created; wiggum will not keep this machine awake." >&2
}

# Describe a `.scheduled` sidecar as a single state phrase for `status`.
#
# The wording is recomputed from the target epoch rather than read back from
# the `target_human` the launcher stored, because that string was rendered
# relative to schedule time: a run scheduled last night for "01:00:00
# tomorrow" is not tomorrow any more when somebody reads it this morning. The
# epoch is the fact; the phrasing is a view of it.
#
# A sidecar whose target will not parse is reported as unreadable rather than
# guessed at or allowed to abort the caller -- `status` is the command you run
# when something is already confusing, so it must survive a truncated file.
#
# The sidecar outlives the waiter that wrote it, so its presence alone does not
# mean a run is still coming. The waiter is the thing that fires; if it is gone
# the schedule is a leftover, and saying "scheduled" would have somebody wait
# all morning for output that is never coming. A machine that was off at 01:07
# is the ordinary case rather than an error state, which is why the leftover is
# reported and stepped over rather than treated as a fault. Two dead-waiter
# states, because the tense differs: past the target it was missed, before it
# nothing is waiting to fire.
#
# Only a dead waiter is evidence of that. A live one whose target has just
# passed is mid-poll and about to start, so it stays pending.
describe_schedule_state() {
    local schedfile="$1" target waiter
    target="$(read_schedule_field "$schedfile" target)"
    waiter="$(read_schedule_field "$schedfile" pid)"

    local human
    if [[ -z "$target" ]] || ! human="$(describe_at_target "$target")"; then
        echo "scheduled (unreadable schedule file: $schedfile)"
        return 0
    fi

    local now
    now="$(wiggum_now_epoch)"

    if process_alive "$waiter"; then
        echo "scheduled for $human (in $(format_duration $((target - now))))"
    elif [ "$target" -le "$now" ]; then
        echo "missed: was scheduled for $human ($(format_duration $((now - target))) ago)"
    else
        echo "not waiting: was scheduled for $human (in $(format_duration $((target - now)))), but its waiter is gone"
    fi
}

# Print task progress and run state for a plan. Reads the pid/scheduled/out
# sidecars to distinguish: not started, scheduled, running, running-but-blocked,
# or finished (with the recorded stop reason). Read-only -- never starts or
# stops anything.
run_status() {
    local base="${FILES[0]}"
    local pidfile outfile schedfile total remaining dropped done_count
    pidfile="$(run_sidecar_file "$base" pid)"
    outfile="$(run_sidecar_file "$base" out)"
    schedfile="$(run_sidecar_file "$base" scheduled)"

    total="$(count_total_tasks "$base")"
    remaining="$(count_unchecked "$base")"
    dropped="$(count_dropped "$base")"
    done_count=$((total - remaining - dropped))

    echo "Plan: $base"
    format_progress "$total" "$done_count" "$remaining" "$dropped"

    local state="not started" pid=""
    if [[ -f "$pidfile" ]]; then
        pid="$(tr -d '[:space:]' < "$pidfile")"
    fi

    # A live pidfile outranks a schedule: both present means the waiter fired
    # between the two reads, and the pidfile is the newer fact. A dead one does
    # not, because scheduling is allowed over a finished run's pidfile and the
    # leftover must not shadow the schedule that replaced it.
    if process_alive "$pid"; then
        if detect_blocked "$outfile"; then
            state="running but appears blocked (pid $pid)"
        else
            state="running (pid $pid)"
        fi
    elif [[ -f "$schedfile" ]]; then
        state="$(describe_schedule_state "$schedfile")"
    elif [[ -f "$pidfile" ]]; then
        local final
        final="$(read_run_status "$outfile")"
        if [[ -n "$final" ]]; then
            state="finished: $final"
        else
            state="not running (no status recorded)"
        fi
    elif [[ -f "$outfile" ]]; then
        local final
        final="$(read_run_status "$outfile")"
        [[ -n "$final" ]] && state="finished: $final"
    fi
    echo "State: $state"
}

# Follow a background run until it finishes, streaming its output. Honors
# --timeout (and --kill-on-timeout) so a stuck run can be bounded. Exits 0 only
# when the run finished "complete"; non-zero otherwise (stalled/incomplete/
# killed). This is wiggum's "wait" primitive.
run_watch() {
    local base="${FILES[0]}"
    local pidfile outfile
    pidfile="$(run_sidecar_file "$base" pid)"
    outfile="$(run_sidecar_file "$base" out)"

    if [[ ! -f "$pidfile" ]]; then
        echo "No background run found for $base (no pidfile)." >&2
        echo "Start one with: wiggum execute $base --background" >&2
        return "$EXIT_BAD_ARGS"
    fi
    local pid
    pid="$(tr -d '[:space:]' < "$pidfile")"

    echo "Watching wiggum run for $base (pid $pid)..." >&2
    if [[ "$WATCH_TIMEOUT" -gt 0 ]]; then
        echo "Timeout: ${WATCH_TIMEOUT}s (kill on timeout: $KILL_ON_TIMEOUT)" >&2
    fi

    # `.out` accumulates across runs, so start from this run's separator rather
    # than replaying every previous run's output on the first poll.
    local waited=0 last_lines=0 sep_line
    sep_line="$(grep -n "^${WIGGUM_RUN_SEPARATOR_PREFIX} " "$outfile" 2>/dev/null | tail -n1 | cut -d: -f1 || true)"
    if [[ -n "$sep_line" ]]; then
        last_lines=$((sep_line - 1))
    fi
    while process_alive "$pid"; do
        if [[ -f "$outfile" ]]; then
            local now
            now="$(wc -l < "$outfile" | tr -d ' ')"
            if (( now > last_lines )); then
                tail -n +$((last_lines + 1)) "$outfile"
                last_lines="$now"
            fi
        fi
        if [[ "$WATCH_TIMEOUT" -gt 0 && "$waited" -ge "$WATCH_TIMEOUT" ]]; then
            echo "Watch timeout reached after ${waited}s." >&2
            if [[ "$KILL_ON_TIMEOUT" == true ]]; then
                kill_run "$pidfile"
                echo "Status: killed (timeout)" >&2
                return "$EXIT_CLAUDE_FAILED"
            fi
            echo "Run still active; leaving it running (pass --kill-on-timeout to stop it)." >&2
            return 0
        fi
        sleep "$WATCH_POLL"
        waited=$((waited + WATCH_POLL))
    done

    # Drain any output written between the last poll and exit.
    if [[ -f "$outfile" ]]; then
        tail -n +$((last_lines + 1)) "$outfile" || true
    fi

    release_pidfile "$pidfile" "$pid"
    local final
    final="$(read_run_status "$outfile")"
    echo "Run finished. Status: ${final:-unknown}" >&2
    [[ "$final" == "complete" ]]
}

# Kill the wiggum process for a run, identified by its pidfile, plus its direct
# children (e.g. the claude subprocess it spawned). This deliberately targets
# only the recorded pid tree -- it never does a blanket pkill of every
# wiggum/claude on the system, so unrelated runs are untouched.
kill_run() {
    local pidfile="$1"
    if [[ ! -f "$pidfile" ]]; then
        echo "No run pidfile found: $pidfile" >&2
        return "$EXIT_BAD_ARGS"
    fi
    local pid
    pid="$(tr -d '[:space:]' < "$pidfile")"
    if [[ -z "$pid" ]]; then
        echo "Pidfile is empty: $pidfile" >&2
        rm -f "$pidfile"
        return "$EXIT_BAD_ARGS"
    fi
    if ! process_alive "$pid"; then
        echo "Wiggum run (pid $pid) is not running; cleaning up pidfile." >&2
        release_pidfile "$pidfile" "$pid"
        return 0
    fi
    echo "Killing wiggum run (pid $pid) and its children..." >&2
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
    release_pidfile "$pidfile" "$pid"
    return 0
}

# Cancel a schedule that has not fired yet: stop the waiter its `.scheduled`
# sidecar names, then drop the sidecar.
#
# The pid comes out of the sidecar and nowhere else. The waiter's command line
# is a long env-and-bash-c string, so a `pgrep -f` over it can match twice or
# truncate -- the guess this repo refuses everywhere else, and the reason the
# waiter records its own pid the moment it starts.
#
# The waiter naps in a `sleep` child, so signal the child first: killing only
# the parent leaves that sleep holding a poll interval open. Same shape as
# kill_run, and the same discipline -- children of one recorded pid, never a
# pattern.
#
# Says "cancelled", not "killed", because nothing ran. The distinction is what
# tells somebody there is no output to go looking for.
cancel_schedule() {
    local schedfile="$1"
    local waiter human
    waiter="$(read_schedule_field "$schedfile" pid)"
    human="$(read_schedule_field "$schedfile" target_human)"
    [[ -n "$human" ]] || human="an unrecorded time"

    if process_alive "$waiter"; then
        echo "Cancelling the wiggum run scheduled for $human (waiter pid $waiter)..." >&2
        pkill -TERM -P "$waiter" 2>/dev/null || true
        kill -TERM "$waiter" 2>/dev/null || true
    else
        # A machine that was off at the target time is the ordinary case, not
        # an error state: there is nothing to signal, only a sidecar to drop.
        echo "The run scheduled for $human is no longer waiting; clearing its schedule." >&2
    fi

    rm -f "$schedfile"
    return 0
}

# `wiggum kill <plan>` entry point -- derives the sidecars from the plan path
# and stops whichever of the two states the plan is actually in.
#
# A live pidfile outranks a schedule, the same precedence run_status reads them
# in: both present means the waiter fired between the two reads, and the run is
# the newer fact. A dead pidfile does not outrank one, because scheduling is
# allowed over a finished run's leftovers.
#
# With neither present there is nothing to stop, which is a state to report
# rather than an error. `kill` is what you reach for when you are unsure what
# is running, and it should not fail for answering "nothing".
run_kill() {
    local base="${FILES[0]}"
    local pidfile schedfile pid=""
    pidfile="$(run_sidecar_file "$base" pid)"
    schedfile="$(run_sidecar_file "$base" scheduled)"

    if [[ -f "$pidfile" ]]; then
        pid="$(tr -d '[:space:]' < "$pidfile")"
    fi

    if process_alive "$pid"; then
        kill_run "$pidfile"
        return
    fi

    if [[ -f "$schedfile" ]]; then
        cancel_schedule "$schedfile"
        return
    fi

    # Nothing scheduled, so a leftover pidfile is the only thing left to
    # report on -- kill_run cleans up a stale one and says so.
    if [[ -f "$pidfile" ]]; then
        kill_run "$pidfile"
        return
    fi

    echo "Nothing to stop for $base: no run is active or scheduled." >&2
    return 0
}

# Collect the base paths -- a plan path minus its `.md` -- of every run wiggum
# knows about: anything carrying a `.pid` sidecar (running, or finished and not
# yet cleaned up) or a `.scheduled` one (waiting for its `--at` time). Scanning
# only pidfiles left a scheduled run absent from `top` while `status` reported
# it, so the two commands disagreed about the same run.
#
# With no args, scans `docs/` and the current directory; each arg may be a
# directory, a plan file, or either sidecar. Sorted and deduped so `top` renders
# deterministically and a plan holding both sidecars is still one row.
find_run_sidecars() {
    local args=("$@")
    [[ ${#args[@]} -eq 0 ]] && args=(docs .)
    local a f
    for a in "${args[@]}"; do
        if [[ -d "$a" ]]; then
            for f in "$a"/*.pid "$a"/*.scheduled; do
                [[ -f "$f" ]] && echo "${f%.*}"
            done
        elif [[ "$a" == *.pid || "$a" == *.scheduled ]]; then
            [[ -f "$a" ]] && echo "${a%.*}"
        elif [[ "$a" == *.md ]]; then
            f="${a%.md}"
            [[ -f "${f}.pid" || -f "${f}.scheduled" ]] && echo "$f"
        fi
    done | sort -u
}

# Modification time of a file, in epoch seconds. BSD and GNU `stat` disagree on
# the flag, and neither is present everywhere, so fall back to nothing rather
# than to a wrong number: a missing timestamp hides a column, a wrong one is
# read as activity that did not happen.
file_mtime_epoch() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || true
}

# Seconds since a run last wrote to any of its sidecars, or nothing when it has
# never written one.
#
# This is the column that separates a long task from a wedged one. `running`
# alone cannot: a chain whose claude session is stuck looks exactly like a chain
# doing an hour of real work, and the only way to tell them apart used to be
# diffing log tails by hand.
run_last_activity() {
    local base="$1" newest="" f m
    for f in "${base}.log" "${base}.out" "${base}.pid"; do
        m="$(file_mtime_epoch "$f")"
        [[ -n "$m" ]] || continue
        if [[ -z "$newest" || "$m" -gt "$newest" ]]; then
            newest="$m"
        fi
    done
    [[ -n "$newest" ]] || return 0
    local now
    now="$(wiggum_now_epoch)"
    echo $((now - newest))
}

# Minimal JSON string escaping: the only values wiggum emits are file paths and
# short states, so backslash, quote and control characters are the whole set.
json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g'
}

# One `top` record for the run at BASE (a plan path minus its `.md`), emitted
# tab-separated for run_top to sort and render: rank, plan, pid (or `-`), state,
# time since the run last wrote anything, a task tally, then the raw counts.
# Derives every sidecar from the base and resolves state in the same precedence
# `status` uses, so the two never describe one run differently.
top_row() {
    local base="$1"
    local plan="${base}.md"
    local out="${base}.out"
    local pidfile="${base}.pid"
    local schedfile="${base}.scheduled"

    local total remaining dropped done_count
    total="$(count_total_tasks "$plan")"
    remaining="$(count_unchecked "$plan")"
    dropped="$(count_dropped "$plan")"
    done_count=$((total - remaining - dropped))

    local pid="" pid_display state
    if [[ -f "$pidfile" ]]; then
        pid="$(tr -d '[:space:]' < "$pidfile")"
    fi
    # No live sidecar is not the same as no live run: ask the registry before
    # concluding the run is over.
    if ! process_alive "$pid"; then
        pid="$(registered_pid_for_base "$(absolute_run_base "$plan")")"
    fi
    # A live pidfile outranks a schedule (the waiter fired between the two
    # reads); a dead one does not, because scheduling over a finished run's
    # leftovers is allowed. Same order run_status reads them in.
    if process_alive "$pid"; then
        pid_display="$pid"
        if detect_blocked "$out"; then
            state="running (blocked)"
        else
            state="running"
        fi
    elif [[ -f "$schedfile" ]]; then
        pid_display="-"
        state="$(describe_schedule_state "$schedfile")"
    else
        pid_display="-"
        local final
        final="$(read_run_status "$out")"
        if [[ -n "$final" ]]; then
            state="finished: $final"
        else
            state="not running"
        fi
    fi

    local tasks="${done_count}/${total} done"
    [[ "$remaining" -gt 0 ]] && tasks="${tasks}, ${remaining} left"
    [[ "$dropped" -gt 0 ]] && tasks="${tasks}, ${dropped} dropped"

    local idle activity
    idle="$(run_last_activity "$base")"
    if [[ -n "$idle" ]]; then
        activity="$(format_duration "$idle")"
    else
        idle=""
        activity="-"
    fi

    # Leading rank, stripped by run_top after sorting. Without it the table is
    # alphabetical, which buries the one running job among a dozen finished
    # ones -- the opposite of what someone types `top` to find out.
    local rank=3
    case "$state" in
        "running (blocked)") rank=0 ;;
        running)             rank=1 ;;
        scheduled*)          rank=2 ;;
    esac

    # Tab-separated record. run_top sorts on the rank and renders the rest as a
    # table or as JSON, so the two outputs cannot describe a run differently.
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$rank" "$plan" "$pid_display" "$state" "$activity" "$tasks" \
        "$total" "$done_count" "$remaining" "$dropped"
}

# Render a run's base path the way `top` should show it: relative when the run
# belongs to the current directory, absolute when it does not.
#
# It also makes the two discovery sources dedupe against each other by plain
# string comparison, so a local run found both in the registry and by the
# directory scan is one row rather than two.
relativize_run_base() {
    local base="$1"
    case "$base" in
        "$PWD"/*) base="${base#"$PWD"/}" ;;
        ./*)      base="${base#./}" ;;
    esac
    printf '%s\n' "$base"
}

# The set of runs `wiggum top` should show.
#
# With no arguments, that is every run registered anywhere on this machine plus
# every run with a sidecar in `docs/` or the current directory. The registry
# supplies what is running elsewhere; the directory scan supplies local history,
# which the registry deliberately drops as soon as a run's process is gone.
#
# With arguments, it is exactly what was asked for and nothing else -- that is
# what makes `wiggum top <dir>` a way to narrow the view rather than a second
# way to widen it.
collect_top_bases() {
    local f
    if [[ $# -gt 0 ]]; then
        find_run_sidecars "$@"
        return 0
    fi
    { find_registered_runs; find_run_sidecars; } | while IFS= read -r f; do
        relativize_run_base "$f"
    done | sort -u
}

# `wiggum top` -- a one-shot, at-a-glance overview of every wiggum run on this
# machine, wherever it was started from, plus any run with a sidecar here.
# Optional args narrow the view to given directories, plan files, or sidecars.
# Read-only; never starts or stops anything.
run_top() {
    # Portable collect (no mapfile -- wiggum targets bash 3.2+ on stock macOS).
    local bases=() f
    while IFS= read -r f; do
        [[ -n "$f" ]] && bases+=("$f")
    done < <(collect_top_bases "${FILES[@]+"${FILES[@]}"}")
    if [[ ${#bases[@]} -eq 0 ]]; then
        echo "No wiggum runs found (nothing registered on this machine, and no .pid or .scheduled sidecars in docs/ or the current directory)."
        echo "Start one with: wiggum execute <plan> --background"
        return 0
    fi
    # Blocked first, then running, then scheduled, then everything finished.
    # `sort -s` keeps the alphabetical order collect_top_bases produced within
    # each group.
    local records
    records="$(for f in "${bases[@]}"; do top_row "$f"; done | sort -s -k1,1n | cut -f2-)"

    if [[ "$TOP_JSON" == true ]]; then
        top_render_json "$records"
        return 0
    fi

    printf '%-40s %-8s %-20s %-9s %s\n' "PLAN" "PID" "STATE" "ACTIVITY" "TASKS"
    local plan pid state activity tasks
    while IFS=$'\t' read -r plan pid state activity tasks _total _done _left _dropped; do
        [[ -n "$plan" ]] || continue
        printf '%-40s %-8s %-20s %-9s %s\n' "$plan" "$pid" "$state" "$activity" "$tasks"
    done <<< "$records"
}

# `wiggum top --json` -- the same records as the table, for a script that needs
# to decide something rather than read something. `idle_seconds` is null when a
# run has never written a sidecar, and `pid` is null when nothing is running,
# so a caller can test for absence rather than parsing `-`.
top_render_json() {
    local records="$1" first=true
    local plan pid state activity tasks total done_count left dropped
    echo "["
    while IFS=$'\t' read -r plan pid state activity tasks total done_count left dropped; do
        [[ -n "$plan" ]] || continue
        [[ "$first" == true ]] || echo ","
        first=false
        local pid_json="null" idle_json="null" idle
        [[ "$pid" != "-" ]] && pid_json="$pid"
        idle="$(run_last_activity "${plan%.md}")"
        [[ -n "$idle" ]] && idle_json="$idle"
        printf '  {"plan": "%s", "pid": %s, "state": "%s", "idle_seconds": %s, "tasks": {"total": %s, "done": %s, "remaining": %s, "dropped": %s}}' \
            "$(json_escape "$plan")" "$pid_json" "$(json_escape "$state")" "$idle_json" \
            "$total" "$done_count" "$left" "$dropped"
    done <<< "$records"
    echo ""
    echo "]"
}

# Plan paths listed in a queue file: one per line, `#` starts a comment, blank
# lines ignored. Echoes nothing for a missing file rather than failing, because
# a queue can legitimately be deleted while the chain that reads it is winding
# down.
read_queue() {
    local file="$1" line
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        # Trim surrounding whitespace without spawning a process per line.
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -n "$line" ]] && printf '%s\n' "$line"
    done < "$file"
    return 0
}

# The next plan in the queue that this run has not already executed, or nothing
# when the queue is exhausted.
#
# The file is re-read on every call, which is the whole point: a line appended
# while a plan is running is picked up when that plan finishes. A line removed
# before it is reached is simply never run, and one removed after it ran stays
# in DONE, so editing the file mid-chain cannot cause a repeat.
next_queued_plan() {
    local file="$1" done_list="${2:-}" line
    while IFS= read -r line; do
        if printf '%s\n' "$done_list" | grep -Fxq -- "$line"; then
            continue
        fi
        printf '%s\n' "$line"
        return 0
    done < <(read_queue "$file")
    return 0
}

# `wiggum chain --queue <file>` -- a chain whose plan list lives on disk.
#
# `run_chain` takes its plans from argv, which fixes the list at launch: there
# is nowhere to add work to a chain that is already running. Reading the list
# from a file instead means appending a line adds a plan to the tail, and the
# queue survives the process, so a killed chain can be resumed by re-running the
# same command.
#
# Stops at the first plan that fails, exactly as the argv form does. A queued
# plan that does not exist when its turn comes is a failure rather than a skip:
# silently passing over a path somebody typed wrong would leave the work undone
# with nothing saying so.
run_chain_queue() {
    local done_list="" plan idx=0 rc=0 total_done=0
    echo "=== WIGGUM CHAIN MODE (queue: $QUEUE_FILE) ===" >&2

    while :; do
        plan="$(next_queued_plan "$QUEUE_FILE" "$done_list")"
        [[ -n "$plan" ]] || break

        idx=$((idx + 1))
        done_list="${done_list}${plan}
"
        echo "" >&2
        echo "=== Chain plan $idx (queued): $plan ===" >&2

        if [[ ! -f "$plan" ]]; then
            echo "=== Chain plan $idx FAILED: $plan does not exist -- stopping chain ===" >&2
            return "$EXIT_PLAN_FAILED"
        fi

        # Fresh session per plan, as in the argv form.
        WIGGUM_LAST_SESSION_ID=""
        FILES=("$plan")
        SUMMARY_FILE="$(derive_output_file execute "$plan" "")"
        rc=0
        run_execute || rc=$?
        release_run_pidfile
        if [[ "$rc" -ne 0 ]]; then
            echo "=== Chain plan $idx FAILED: $plan -- stopping chain ===" >&2
            return "$EXIT_PLAN_FAILED"
        fi
        total_done=$((total_done + 1))
        echo "=== Chain plan $idx complete: $plan ===" >&2
    done

    echo "" >&2
    if [[ "$total_done" -eq 0 ]]; then
        echo "=== WIGGUM CHAIN COMPLETE: the queue was empty ===" >&2
    else
        echo "=== WIGGUM CHAIN COMPLETE: $total_done plan(s) from $QUEUE_FILE ===" >&2
    fi
    return 0
}

# Execute several workplans back to back, each in its own fresh session, in the
# order given. Stops at the first plan that fails so a broken step doesn't drag
# the rest of the chain down. This is wiggum's "chain up different workplans".
run_chain() {
    if [[ -n "$QUEUE_FILE" ]]; then
        run_chain_queue
        return $?
    fi
    local plans=("${FILES[@]}")
    local total=${#plans[@]}
    local idx=0 f
    echo "=== WIGGUM CHAIN MODE ($total plan(s)) ===" >&2
    for f in "${plans[@]}"; do
        idx=$((idx + 1))
        echo "" >&2
        echo "=== Chain plan $idx of $total: $f ===" >&2
        # Fresh session per plan so context from one workplan doesn't leak
        # into the next.
        WIGGUM_LAST_SESSION_ID=""
        FILES=("$f")
        SUMMARY_FILE="$(derive_output_file execute "$f" "")"
        # A plan that unwinds mid-run never reaches its own release, and the
        # stale claim would stop the next plan from registering -- leaving the
        # chain reported against a plan it has already moved off. Release here,
        # where both outcomes pass through. Harmless after a clean finish:
        # run_execute has already dropped the claim.
        local rc=0
        run_execute || rc=$?
        release_run_pidfile
        if [[ "$rc" -eq 0 ]]; then
            echo "=== Chain plan $idx of $total complete: $f ===" >&2
        else
            echo "=== Chain plan $idx of $total FAILED: $f -- stopping chain ===" >&2
            return "$EXIT_PLAN_FAILED"
        fi
    done
    echo "" >&2
    echo "=== WIGGUM CHAIN COMPLETE: $total plan(s) ===" >&2
    return 0
}

# ── Docs ─────────────────────────────────────────────────────────────────────

run_update_docs() {
    local -a inputs=()
    local -a outputs=()
    local parsing="inputs"

    # Split args on "--" separator: inputs... -- outputs...
    for arg in "$@"; do
        if [[ "$arg" == "--" ]]; then
            parsing="outputs"
            continue
        fi
        if [[ "$parsing" == "inputs" ]]; then
            inputs+=("$arg")
        else
            outputs+=("$arg")
        fi
    done

    local input_list="${inputs[*]}"
    local output_list="${outputs[*]}"

    echo "Updating documentation..."
    echo "  Input: $input_list"
    echo "  Output: $output_list"

    local prev_label="${WIGGUM_CURRENT_LABEL:-docs}"
    WIGGUM_CURRENT_LABEL="${prev_label}-update"
    run_claude -p \
        "Update the following documentation files: $output_list. Use the input files as context for what has changed: $input_list. For each output file: read its current content, then update it to reflect the changes described in the input files. Preserve the existing structure and style of each document. Only update sections that are affected by the changes. Do not rewrite sections that are already accurate. $PROMPT_SUFFIX" \
        "${inputs[@]}" "${outputs[@]}"

    commit_or_skip "${prev_label}-commit" "$output_list"

    echo "Documentation updated: $output_list"
}

run_check() {
    echo "=== WIGGUM CHECK MODE ==="
    if [[ "$NO_VERIFY" == true ]]; then
        echo "Error: --no-verify makes 'wiggum check' a no-op. Drop the flag or use a different command." >&2
        return "$EXIT_BAD_ARGS"
    fi
    if [[ ${#VERIFY_STEPS[@]} -eq 0 ]]; then
        echo "No verification steps configured in .wiggumrc. Nothing to check."
        return 0
    fi
    env_reminder
    print_verify_steps 1
    echo ""

    WIGGUM_CURRENT_LABEL="check"
    if run_validation; then
        echo ""
        if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
            echo "Committing changes..."
            commit_or_skip "check-commit"
        fi
        if [[ -n "${WIGGUM_LAST_SESSION_ID:-}" ]]; then
            echo "Session: $WIGGUM_LAST_SESSION_ID"
        fi
        echo "=== ALL CHECKS PASSED ==="
    else
        echo ""
        if [[ -n "${WIGGUM_LAST_SESSION_ID:-}" ]]; then
            echo "Session: $WIGGUM_LAST_SESSION_ID"
        fi
        echo "=== CHECKS FAILED ==="
        return "$EXIT_VALIDATION_FAILED"
    fi
}

run_docs() {
    echo "=== WIGGUM DOCS MODE ==="
    echo "Input: ${DOCS_INPUT[*]}"
    echo "Output: ${DOCS_OUTPUT[*]}"
    echo ""

    log_init "${DOCS_OUTPUT[0]}"
    WIGGUM_CURRENT_LABEL="docs"
    run_update_docs "${DOCS_INPUT[@]}" -- "${DOCS_OUTPUT[@]}"

    log_entry "complete" "wiggum docs finished"
    echo "Log: $WIGGUM_LOG_FILE"
    echo "=== WIGGUM DOCS COMPLETE ==="
}

# ── Run (prompt chaining) ─────────────────────────────────────────────────────

# Feed a series of prompts to Claude in one continuous session. The first
# prompt starts a fresh session (or resumes one from --session-file); every
# subsequent prompt continues it via run_claude's -c handling. With
# --session-file the session id is persisted so a later invocation (e.g. a
# cron job) can follow up in the same session.
run_prompts() {
    echo "=== WIGGUM RUN MODE ===" >&2
    echo "Prompts: ${#RUN_PROMPTS[@]}" >&2
    echo "Effort: $EFFORT" >&2
    echo "Permission mode: $PERMISSION_MODE" >&2

    # Resume a saved session unless told to start fresh with --new-session.
    if [[ -n "$RUN_SESSION_FILE" && "$RUN_NEW_SESSION" != true && -s "$RUN_SESSION_FILE" ]]; then
        WIGGUM_LAST_SESSION_ID="$(tr -d '[:space:]' < "$RUN_SESSION_FILE")"
        echo "Resuming session: $WIGGUM_LAST_SESSION_ID" >&2
    fi
    echo "" >&2

    # Log next to the session file when given, otherwise under docs/.
    if [[ -n "$RUN_SESSION_FILE" ]]; then
        log_init "$RUN_SESSION_FILE"
    else
        log_init "docs/run.md"
    fi

    # Show Claude's responses on stdout (session ids and chatter stay on
    # stderr) so `wiggum run ... > out.txt` captures the answers -- useful
    # for cron jobs that pipe the output somewhere.
    WIGGUM_SHOW_OUTPUT=true

    local idx=0 prompt
    for prompt in "${RUN_PROMPTS[@]}"; do
        idx=$((idx + 1))
        echo "--- Prompt $idx of ${#RUN_PROMPTS[@]} ---" >&2
        log_entry "run" "prompt $idx of ${#RUN_PROMPTS[@]}"
        WIGGUM_CURRENT_LABEL="run-$idx"
        if [[ $idx -eq 1 && -z "$WIGGUM_LAST_SESSION_ID" ]]; then
            run_claude -p "$prompt"
        else
            run_claude -p -c "$prompt"
        fi
        # Persist after each prompt so a follow-up can resume even if a later
        # prompt fails mid-chain.
        if [[ -n "$RUN_SESSION_FILE" ]]; then
            echo "$WIGGUM_LAST_SESSION_ID" > "$RUN_SESSION_FILE"
        fi
    done

    WIGGUM_SHOW_OUTPUT=false

    if [[ -n "$RUN_SESSION_FILE" ]]; then
        echo "Session saved to: $RUN_SESSION_FILE" >&2
    fi

    log_entry "complete" "wiggum run finished"
    echo "" >&2
    echo "Session: $WIGGUM_LAST_SESSION_ID" >&2
    echo "Log: $WIGGUM_LOG_FILE" >&2
    echo "=== WIGGUM RUN COMPLETE ===" >&2
}
