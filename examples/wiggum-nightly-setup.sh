#!/usr/bin/env bash
#
# Configure and schedule wiggum-nightly.sh. Asks for the projects, the time and
# the iteration limit, writes a configured copy, and installs the cron entry.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/wiggum-nightly.sh"
DEST="$HOME/bin/wiggum-nightly.sh"
LOG="$HOME/.wiggum-nightly.log"
MARKER="# wiggum-nightly"

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

read -r -p "Project directories, space separated: " -a DIRS
[[ ${#DIRS[@]} -gt 0 ]] || {
    echo "Error: give at least one directory." >&2
    exit 1
}

QUOTED=""
for d in "${DIRS[@]}"; do
    d="${d/#\~/$HOME}"
    [[ -d "$d/.git" ]] || {
        echo "Error: not a git repository: $d" >&2
        exit 1
    }
    QUOTED+=" $(printf '%q' "$(cd "$d" && pwd)")"
done

read -r -p "Start time, 24h HH:MM [01:00]: " TIME
TIME="${TIME:-01:00}"
[[ $TIME =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || {
    echo "Error: give a time like 01:00." >&2
    exit 1
}
HOUR=$((10#${BASH_REMATCH[1]}))
MIN=$((10#${BASH_REMATCH[2]}))

read -r -p "Max iterations [25]: " ITERS
ITERS="${ITERS:-25}"

read -r -p "Where to install it [$DEST]: " REPLY_DEST
DEST="${REPLY_DEST:-$DEST}"
DEST="${DEST/#\~/$HOME}"

# ------------------------------------------------------------------ install --

mkdir -p "$(dirname "$DEST")"
sed -e "s|^PROJECTS=.*|PROJECTS=(${QUOTED# })|" \
    -e "s|^MAX_ITERATIONS=.*|MAX_ITERATIONS=$ITERS|" \
    "$SRC" >"$DEST"
chmod 755 "$DEST"

LINE="$MIN $HOUR * * * $DEST >> $LOG 2>&1 $MARKER"
{
    crontab -l 2>/dev/null | grep -v -F "$MARKER" || true
    echo "$LINE"
} | crontab -

# ------------------------------------------------------------------- report --

cat <<EOF

Installed $DEST
Scheduled $LINE

Before it can run:
  * Put a credential in $DEST -- cron cannot read the Keychain, so an
    interactive 'claude' login does not carry over. Run 'claude setup-token'
    and uncomment the CLAUDE_CODE_OAUTH_TOKEN line.
  * On macOS, add /usr/sbin/cron under System Settings -> Privacy & Security ->
    Full Disk Access, or the job fires and silently does nothing.

Worth knowing:
  * cron does not wake a sleeping machine. If it is asleep at $TIME, that night
    is skipped -- no run, no catch-up, no error.
  * wiggum commits to the local branch as it goes. Nothing is pushed or deployed.

Check it:  bash -n $DEST && crontab -l
Logs:      $LOG, and docs/nightly-<date>_plan.log in whichever project it picked.
EOF
