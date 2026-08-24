#!/usr/bin/env bash
#
# Plan a maintenance sweep in one project, then execute it.
# Usage: wiggum-nightly.sh <project-directory> [max-iterations]
#
# Schedule it with wiggum-nightly-setup.sh, which installs one crontab entry per
# project so each can run on its own day and time.

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: wiggum-nightly.sh <project-directory> [max-iterations]

Plan a maintenance sweep in one project, then execute the plan it produced.
Writes docs/nightly-<date>.md (the brief it plans from) and
docs/nightly-<date>_plan.md (the plan), then runs it.

  <project-directory>   git repository to work in
  [max-iterations]      implementation iterations wiggum may use (default 25)

Schedule it with wiggum-nightly-setup.sh, which installs one crontab entry per
project so each runs on its own days and time. Edit this script to change the
planning brief or the credential.
USAGE
}

case "${1:-}" in
-h | --help)
    usage
    exit 0
    ;;
"")
    usage >&2
    exit 1
    ;;
esac

PROJECT="$1"
MAX_ITERATIONS="${2:-25}"

# launchd runs a job it missed as soon as the machine next wakes. That is not
# wanted here: a run is for its slot, not for whenever the lid opens. If we are
# firing well after the scheduled time, this is a catch-up, so stand down.
# WIGGUM_NIGHTLY_AT is set by the LaunchAgent; unset it to always run.
if [[ -n ${WIGGUM_NIGHTLY_AT:-} ]]; then
    scheduled=$((10#${WIGGUM_NIGHTLY_AT%%:*} * 60 + 10#${WIGGUM_NIGHTLY_AT##*:}))
    now=$((10#$(date +%H) * 60 + 10#$(date +%M)))
    late=$(((now - scheduled + 1440) % 1440))
    if ((late > ${WIGGUM_NIGHTLY_WINDOW:-10})); then
        printf '[%s] missed the %s slot by %dm -- skipping\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$WIGGUM_NIGHTLY_AT" "$late"
        exit 0
    fi
fi

# cron starts with a bare PATH and no shell rc, so name everything.
export PATH="/usr/local/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"
# node, when it comes from nvm rather than a fixed directory
if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
    # shellcheck source=/dev/null
    . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1 || true
fi
# conda goes last so its bundled python/curl never shadow the system ones
if [[ -d "$HOME/anaconda3/bin" ]]; then
    PATH="$PATH:$HOME/anaconda3/bin"
fi

# cron cannot read the Keychain, so an interactive `claude` login does not carry
# over. Uncomment and fill in ONE of these:
# export CLAUDE_CODE_OAUTH_TOKEN="..."   # from: claude setup-token
# export ANTHROPIC_API_KEY="sk-ant-..."

cd "$PROJECT"
STAMP="$(date '+%Y-%m-%d')"
SEED="docs/nightly-$STAMP.md"
PLAN="docs/nightly-${STAMP}_plan.md"
mkdir -p docs

cat >"$SEED" <<'BRIEF'
Produce a wiggum workplan for this repository.

Pick 5-10 open issues from this repository's issue ledger and docs. Every issue
must be fixable with code and documentation changes alone -- exclude anything
needing data collection, scraping, annotation, or model training/retraining.

Before selecting, run `ls -t docs/*_plan.md | head -30` and read the recent
ones, so you do not re-plan work an existing plan already covers. Read this
repository's CLAUDE.md and follow it.

For each issue, the plan must give:
- what is wrong, in a sentence or two, with its issue id if it has one
- the data flow: where the value enters, what transforms it, where it surfaces
- the exact files to change, with the current code quoted inline
- acceptance criteria: name the test that fails before the fix and passes after

Include tasks to update the issue ledger and the documentation -- marking each
issue shipped with its commit refs and the measured before/after result.

One commit per file. Do not push, do not deploy, and leave other sessions'
uncommitted files alone.
BRIEF

# --plan-file matters: with stdout redirected to a log, wiggum treats the run as
# piped, prints the plan and deletes the file.
wiggum plan "$SEED" --plan-file "$PLAN"
wiggum execute "$PLAN" --max-iterations "$MAX_ITERATIONS"
