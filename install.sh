#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/usr/local/lib/wiggum"
BIN_DIR="/usr/local/bin"
SCRIPT_NAME="wiggum"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Wiggum installer"
echo ""

# Check source exists
if [[ ! -f "$SOURCE_DIR/wiggum.sh" || ! -f "$SOURCE_DIR/lib/wiggum.sh" ]]; then
    echo "Error: wiggum.sh and lib/wiggum.sh must both exist in $SOURCE_DIR"
    exit 1
fi

# Check Claude Code is available
if ! command -v claude &>/dev/null; then
    echo "Warning: 'claude' (Claude Code CLI) not found on PATH."
    echo "Wiggum requires Claude Code to run. Install it from https://claude.com/claude-code"
    echo ""
fi

# Helper: run with sudo only if needed
run_privileged() {
    if [[ -w "$(dirname "$1")" ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

# Install lib + CLI (safe to re-run for updates)
if [[ -f "$INSTALL_DIR/wiggum.sh" ]]; then
    echo "Updating existing installation..."
else
    echo "Installing to $INSTALL_DIR..."
fi
run_privileged mkdir -p "$INSTALL_DIR/lib"
run_privileged cp "$SOURCE_DIR/wiggum.sh" "$INSTALL_DIR/wiggum.sh"
run_privileged cp "$SOURCE_DIR/lib/wiggum.sh" "$INSTALL_DIR/lib/wiggum.sh"
run_privileged chmod +x "$INSTALL_DIR/wiggum.sh"

# Symlink into bin
echo "Linking $BIN_DIR/$SCRIPT_NAME..."
run_privileged mkdir -p "$BIN_DIR"
run_privileged ln -sf "$INSTALL_DIR/wiggum.sh" "$BIN_DIR/$SCRIPT_NAME"

# Install shell completions
ZSH_COMP_DIR=""
if [[ -d "/opt/homebrew/share/zsh/site-functions" ]]; then
    ZSH_COMP_DIR="/opt/homebrew/share/zsh/site-functions"
elif [[ -d "/usr/local/share/zsh/site-functions" ]]; then
    ZSH_COMP_DIR="/usr/local/share/zsh/site-functions"
fi
if [[ -n "$ZSH_COMP_DIR" && -f "$SOURCE_DIR/completions/wiggum.zsh" ]]; then
    run_privileged cp "$SOURCE_DIR/completions/wiggum.zsh" "$ZSH_COMP_DIR/_wiggum"
    echo "Installed zsh completions to $ZSH_COMP_DIR/_wiggum"
fi

BASH_COMP_DIR=""
if [[ -d "/opt/homebrew/etc/bash_completion.d" ]]; then
    BASH_COMP_DIR="/opt/homebrew/etc/bash_completion.d"
elif [[ -d "/usr/local/etc/bash_completion.d" ]]; then
    BASH_COMP_DIR="/usr/local/etc/bash_completion.d"
fi
if [[ -n "$BASH_COMP_DIR" && -f "$SOURCE_DIR/completions/wiggum.bash" ]]; then
    run_privileged cp "$SOURCE_DIR/completions/wiggum.bash" "$BASH_COMP_DIR/wiggum"
    echo "Installed bash completions to $BASH_COMP_DIR/wiggum"
fi

# Copy example config to home if no config exists yet
if [[ ! -f "$HOME/.wiggumrc" ]]; then
    if [[ -f "$SOURCE_DIR/.wiggumrc.example" ]]; then
        cp "$SOURCE_DIR/.wiggumrc.example" "$HOME/.wiggumrc"
        echo "Created ~/.wiggumrc from example (edit to match your project)"
    fi
fi

# Install /wiggum skill globally for Claude Code
SKILL_DIR="$HOME/.claude/skills/wiggum"
SKILL_SRC="$SOURCE_DIR/.claude/skills/wiggum/SKILL.md"
if [[ -f "$SKILL_SRC" ]]; then
    mkdir -p "$SKILL_DIR"
    cp "$SKILL_SRC" "$SKILL_DIR/SKILL.md"
    echo "Installed /wiggum skill to $SKILL_DIR/SKILL.md"
fi

# Verify
if command -v wiggum &>/dev/null; then
    echo ""
    echo "Installed successfully: $(which wiggum)"
    echo "Run 'wiggum --help' to get started."
else
    echo ""
    echo "Installed to $INSTALL_DIR"
    echo "If 'wiggum' is not found, add $BIN_DIR to your PATH:"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
fi
