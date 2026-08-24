#!/usr/bin/env bash
#
# Schedule wiggum-nightly.sh for ONE project. Run it once per project; each gets
# its own crontab entry, so they can run on different days and at different
# times. Re-running it for the same project replaces that project's entry and
# leaves the others alone.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/wiggum-nightly.sh"
DEST="$HOME/bin/wiggum-nightly.sh"
LOG="$HOME/.wiggum-nightly.log"

[[ -t 0 ]] || {
    echo "Run this from a terminal -- it asks questions." >&2
    exit 1
}
[[ -f $SRC ]] || {
    echo "Error: $SRC not found." >&2
    exit 1
}
command -v wiggum >/dev/null || {
    echo "Error: wiggum is not on PATH. Run ./install.sh first." >&2
    exit 1
}

# ---------------------------------------------------------------- questions --

read -r -p "Project directory: " PROJECT
PROJECT="${PROJECT/#\~/$HOME}"
[[ -d "$PROJECT/.git" ]] || {
    echo "Error: not a git repository: $PROJECT" >&2
    exit 1
}
PROJECT="$(cd "$PROJECT" && pwd)"
[[ -f "$PROJECT/.wiggumrc" ]] ||
    echo "Note: no .wiggumrc there, so runs get no verification steps."

read -r -p "Start time, 24h HH:MM [01:00]: " TIME
TIME="${TIME:-01:00}"
[[ $TIME =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || {
    echo "Error: give a time like 01:00." >&2
    exit 1
}
HOUR=$((10#${BASH_REMATCH[1]}))
MIN=$((10#${BASH_REMATCH[2]}))
((HOUR <= 23 && MIN <= 59)) || {
    echo "Error: $TIME is not a real time." >&2
    exit 1
}

echo "Which days? 'daily', 'weekdays', 'weekends', or a cron day list like mon,wed,fri"
read -r -p "Days [daily]: " DAYS
case "$(printf '%s' "${DAYS:-daily}" | tr '[:upper:]' '[:lower:]')" in
daily | every | all) DOW='*' ;;
weekdays) DOW='1-5' ;;
weekends) DOW='0,6' ;;
*) DOW="$DAYS" ;; # cron takes mon,wed,fri and 1,3,5 as-is
esac

read -r -p "Max iterations [25]: " ITERS
ITERS="${ITERS:-25}"
[[ $ITERS =~ ^[0-9]+$ ]] || {
    echo "Error: iterations must be a number." >&2
    exit 1
}

# ------------------------------------------------------------------ install --

if [[ -f $DEST ]]; then
    echo "Using the runner already at $DEST (not overwriting -- it may hold your credential)."
else
    mkdir -p "$(dirname "$DEST")"
    cp "$SRC" "$DEST"
    chmod 755 "$DEST"
    echo "Installed $DEST"
fi

MARKER="# wiggum-nightly:$PROJECT"
LINE="$MIN $HOUR * * $DOW $DEST $(printf '%q' "$PROJECT") $ITERS >> $LOG 2>&1 $MARKER"

# Drop this project's previous entry (exact suffix match, so a project whose
# path is a prefix of another's is left alone), then add the new one.
{
    while IFS= read -r l; do
        [[ $l == *"$MARKER" ]] && continue
        printf '%s\n' "$l"
    done < <(crontab -l 2>/dev/null || true)
    printf '%s\n' "$LINE"
} | crontab -

# ------------------------------------------------------------------- report --

cat <<EOF

Scheduled $(basename "$PROJECT"): $TIME, days=$DOW, $ITERS iterations max.

Your wiggum-nightly schedule now:
EOF
crontab -l 2>/dev/null | grep -F "# wiggum-nightly:" | sed 's/^/  /' || echo "  (none)"

cat <<EOF

Before the first run:
  * Put a credential in $DEST -- cron cannot read the Keychain, so an
    interactive 'claude' login does not carry over. Run 'claude setup-token'
    and uncomment the CLAUDE_CODE_OAUTH_TOKEN line.
  * On macOS, add /usr/sbin/cron under System Settings -> Privacy & Security ->
    Full Disk Access, or the job fires and silently does nothing.

Worth knowing:
  * cron does not wake a sleeping machine. If it is asleep at $TIME, that run is
    skipped -- no run, no catch-up, no error.
  * wiggum commits to the local branch as it goes. Nothing is pushed or deployed.

Try it now:  $DEST $PROJECT $ITERS
Remove one:  crontab -l | grep -v 'wiggum-nightly:$PROJECT' | crontab -
Logs:        $LOG, and docs/nightly-<date>_plan.log inside the project.
EOF
