#!/usr/bin/env bash
#
# wiggum-cron.sh — example wrapper for running `wiggum run` from cron/launchd.
#
# Cron runs jobs in a minimal, non-login shell, which breaks `claude` in three
# ways this script works around (see the README "Scheduling with cron" section):
#   1. PATH is bare — wiggum, claude, and node are not on it.
#   2. Auth does not carry over — the interactive login lives in the macOS
#      Keychain, which cron cannot read. Supply a key/token via the environment.
#   3. macOS may require Full Disk Access for /usr/sbin/cron.
#
# Usage:
#   cp examples/wiggum-cron.sh ~/bin/wiggum-cron.sh
#   chmod +x ~/bin/wiggum-cron.sh
#   # edit the three lines marked EDIT below, then test in a clean environment:
#   env -i HOME="$HOME" ~/bin/wiggum-cron.sh
#
# Then add a crontab entry (crontab -e), e.g. 9:00 AM daily, logging output:
#   0 9 * * * /Users/you/bin/wiggum-cron.sh >> /Users/you/wiggum-cron.log 2>&1

set -euo pipefail

# (1) EDIT: PATH — add wiggum (/usr/local/bin), claude (~/.local/bin), and node
#     (Homebrew shown). Keep /usr/bin:/bin last.
export PATH="/usr/local/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"

# (2) EDIT: Auth — cron cannot read the Keychain, so pick ONE of these:
export ANTHROPIC_API_KEY="sk-ant-REPLACE-ME"        # API billing
# …or run `claude setup-token` once interactively and export the token here
# instead of the API key above (Claude subscription).

# (3) EDIT: work in your project so wiggum finds .wiggumrc, git, and the
#     session file.
cd "$HOME/path/to/your/project"

# The task. Reusing the same --session-file every run continues one evolving
# session (your "follow up later" workflow). Use an absolute path so it
# persists between runs; pass --new-session to start over.
wiggum run \
    --session-file "$HOME/.wiggum-cron-session" \
    --effort high --permission-mode auto \
    "Summarize commits since the last run and append a bullet to STANDUP.md"
