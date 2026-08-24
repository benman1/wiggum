#!/usr/bin/env bash
#
# Schedule wiggum-nightly.sh for ONE project, using whichever scheduler the
# platform provides: cron on Linux, a LaunchAgent on macOS. Run it once per
# project; re-running it for the same project replaces that project's entry.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/wiggum-nightly.sh"
DEST="$HOME/bin/wiggum-nightly.sh"
LOG="$HOME/.wiggum-nightly.log"
AGENT_DIR="$HOME/Library/LaunchAgents"
OS="$(uname -s)"

usage() {
    cat <<'USAGE'
Usage: wiggum-nightly-setup.sh [-h|--help]

Schedule wiggum-nightly.sh for ONE project, interactively. Asks for the project
directory, start time, days and iteration limit, installs the schedule, and
copies the runner to ~/bin if it is not already there.

  Linux   a crontab entry.
  macOS   a LaunchAgent, NOT a cron job. Claude Code keeps its login in the
          Keychain, and a cron job has no security session, so it cannot unlock
          it -- `claude` reports "not logged in" and the run dies. A LaunchAgent
          runs inside your desktop session and uses the browser login you
          already have. No token, no API key, no environment variables.
  Windows not implemented.

Run it once per project. Each gets its own schedule, so projects can run on
different days and times.

  Linux:  crontab -l | grep wiggum-nightly
  macOS:  ls ~/Library/LaunchAgents/com.wiggum.nightly.*

Takes no arguments -- it asks.
USAGE
}

case "${1:-}" in
-h | --help)
    usage
    exit 0
    ;;
"") ;;
*)
    printf 'Error: unknown argument %s\n\n' "$1" >&2
    usage >&2
    exit 1
    ;;
esac

die() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

case "$OS" in
Darwin | Linux) ;;
*) die "$OS is not supported. Windows is not implemented -- see the README." ;;
esac

[[ -t 0 ]] || die "run this from a terminal -- it asks questions."
[[ -f $SRC ]] || die "$SRC not found."
command -v wiggum >/dev/null || die "wiggum is not on PATH. Run ./install.sh first."
[[ $OS == Linux ]] && { command -v crontab >/dev/null || die "crontab not found."; }

# ---------------------------------------------------------------- questions --

read -r -p "Project directory: " PROJECT
PROJECT="${PROJECT/#\~/$HOME}"
[[ -d "$PROJECT/.git" ]] || die "not a git repository: $PROJECT"
PROJECT="$(cd "$PROJECT" && pwd)"

# wiggum reads ./.wiggumrc if it exists, otherwise ~/.wiggumrc -- never both.
RC="$PROJECT/.wiggumrc"
[[ -f $RC ]] || RC="$HOME/.wiggumrc"
if ! grep -qE '^[[:space:]]*(verify|autofix)[[:space:]]*=' "$RC" 2>/dev/null; then
    cat >&2 <<MSG
Warning: $RC defines no verify or autofix commands,
so scheduled runs will commit without running tests, type checks or lint.
Run 'wiggum init' in the project first if you want verification.

MSG
fi

read -r -p "Start time, 24h HH:MM [01:00]: " TIME
TIME="${TIME:-01:00}"
[[ $TIME =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || die "give a time like 01:00."
HOUR=$((10#${BASH_REMATCH[1]}))
MIN=$((10#${BASH_REMATCH[2]}))
((HOUR <= 23 && MIN <= 59)) || die "$TIME is not a real time."
TIME="$(printf '%02d:%02d' "$HOUR" "$MIN")"

echo "Which days? 'daily', 'weekdays', 'weekends', or a list like mon,wed,fri"
read -r -p "Days [daily]: " DAYS
DAYS="$(printf '%s' "${DAYS:-daily}" | tr '[:upper:]' '[:lower:]')"
WEEKDAYS=()
case "$DAYS" in
daily | every | all) ;;
weekdays) WEEKDAYS=(1 2 3 4 5) ;;
weekends) WEEKDAYS=(0 6) ;;
*)
    IFS=', ' read -r -a parts <<<"$DAYS"
    for d in ${parts[@]+"${parts[@]}"}; do
        case "$d" in
        sun | sunday | 0 | 7) WEEKDAYS+=(0) ;;
        mon | monday | 1) WEEKDAYS+=(1) ;;
        tue | tues | tuesday | 2) WEEKDAYS+=(2) ;;
        wed | weds | wednesday | 3) WEEKDAYS+=(3) ;;
        thu | thur | thurs | thursday | 4) WEEKDAYS+=(4) ;;
        fri | friday | 5) WEEKDAYS+=(5) ;;
        sat | saturday | 6) WEEKDAYS+=(6) ;;
        *) die "unrecognised day '$d' -- use names like mon,wed,fri or 0-6." ;;
        esac
    done
    ;;
esac

read -r -p "Max iterations [25]: " ITERS
ITERS="${ITERS:-25}"
[[ $ITERS =~ ^[0-9]+$ ]] || die "iterations must be a number."

# ------------------------------------------------------------- the runner ----

if [[ -f $DEST ]]; then
    echo "Using the runner already at $DEST (not overwriting your edits)."
else
    mkdir -p "$(dirname "$DEST")"
    cp "$SRC" "$DEST"
    chmod 755 "$DEST"
    echo "Installed $DEST"
fi

# --------------------------------------------------------------- schedule ----

install_cron() {
    local dow tmp marker line
    if [[ ${#WEEKDAYS[@]} -eq 0 ]]; then
        dow='*'
    else
        dow="$(
            IFS=,
            echo "${WEEKDAYS[*]}"
        )"
    fi
    marker="# wiggum-nightly:$PROJECT"
    line="$MIN $HOUR * * $dow WIGGUM_NIGHTLY_AT=$TIME $DEST $(printf '%q' "$PROJECT") $ITERS >> $LOG 2>&1 $marker"
    tmp="$(mktemp)"
    # Drop this project's previous entry (exact suffix match, so a project whose
    # path is a prefix of another's is left alone), then add the new one.
    while IFS= read -r l; do
        [[ $l == *"$marker" ]] && continue
        printf '%s\n' "$l"
    done < <(crontab -l 2>/dev/null || true) >"$tmp"
    printf '%s\n' "$line" >>"$tmp"
    crontab "$tmp"
    rm -f "$tmp"
    WHERE="crontab entry"
    REMOVE="crontab -l | grep -v 'wiggum-nightly:$PROJECT' | crontab -"
}

install_launchagent() {
    local slug label plist w
    # Escape the characters that are not legal as XML text.
    xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
    slug="$(basename "$PROJECT")"
    slug="${slug//[^A-Za-z0-9._-]/-}"
    label="com.wiggum.nightly.$slug"
    plist="$AGENT_DIR/$label.plist"
    mkdir -p "$AGENT_DIR"
    {
        cat <<PLIST_HEAD
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$(xml "$label")</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml "$DEST")</string>
    <string>$(xml "$PROJECT")</string>
    <string>$ITERS</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>WIGGUM_NIGHTLY_AT</key><string>$TIME</string></dict>
  <key>StandardOutPath</key><string>$(xml "$LOG")</string>
  <key>StandardErrorPath</key><string>$(xml "$LOG")</string>
  <key>StartCalendarInterval</key>
PLIST_HEAD
        if [[ ${#WEEKDAYS[@]} -eq 0 ]]; then
            printf '  <dict><key>Hour</key><integer>%d</integer><key>Minute</key><integer>%d</integer></dict>\n' "$HOUR" "$MIN"
        else
            printf '  <array>\n'
            for w in "${WEEKDAYS[@]}"; do
                printf '    <dict><key>Weekday</key><integer>%d</integer><key>Hour</key><integer>%d</integer><key>Minute</key><integer>%d</integer></dict>\n' "$w" "$HOUR" "$MIN"
            done
            printf '  </array>\n'
        fi
        printf '</dict>\n</plist>\n'
    } >"$plist"
    plutil -lint "$plist" >/dev/null || die "generated plist is invalid: $plist"
    launchctl unload "$plist" 2>/dev/null || true
    launchctl load "$plist" || die "launchctl could not load $plist"
    WHERE="LaunchAgent at $plist"
    REMOVE="launchctl unload $plist && rm $plist"
}

if [[ $OS == Darwin ]]; then
    install_launchagent
else
    install_cron
fi

# ----------------------------------------------------------------- report ----

cat <<EOF

Scheduled $(basename "$PROJECT") at $TIME ($DAYS), $ITERS iterations max.
  via:  $WHERE
  log:  $LOG
EOF

if [[ $OS == Darwin ]]; then
    cat <<EOF

This is a LaunchAgent rather than a cron job because Claude Code keeps its login
in the Keychain, and a cron job has no security session to unlock it with. The
agent runs in your desktop session, so the browser login you already have just
works -- nothing to paste, no secret on disk. It does need you logged in to the
desktop; asleep and screen-locked are both fine, fully logged out is not.

If the Mac is asleep at $TIME, launchd runs the job when it next wakes -- but the
runner checks the clock and stands down if the slot has passed, so a missed run
stays missed. Widen that with WIGGUM_NIGHTLY_WINDOW (minutes, default 10).
EOF
else
    cat <<EOF

On Linux the credential is a plain file (~/.claude/.credentials.json) that your
cron job can read directly, so a normal crontab entry is all this needs.

If you set CLAUDE_CONFIG_DIR in your shell rc, add it to the crontab too -- cron
does not read your rc, and the job would look in the default location.
EOF
fi

cat <<EOF

Try it now:  $DEST $PROJECT 3
Remove this: $REMOVE
EOF
