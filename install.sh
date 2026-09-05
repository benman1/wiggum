#!/usr/bin/env bash
set -euo pipefail

PREFIX="${WIGGUM_PREFIX:-/usr/local}"
INSTALL_DIR="$PREFIX/lib/wiggum"
BIN_DIR="$PREFIX/bin"
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

# Whether writing into DIR needs sudo, decided on the nearest directory that
# actually exists: /usr/local/lib/wiggum may not be there yet, and it is
# whoever owns /usr/local that says whether we may create it.
needs_sudo() {
    local dir="$1"
    while [[ ! -d "$dir" ]]; do
        case "$dir" in
            */*) dir="${dir%/*}"; [[ -n "$dir" ]] || dir="/" ;;
            *)   dir="."; break ;;
        esac
    done
    [[ ! -w "$dir" ]]
}

# Run a command that writes into DIR, escalating only for that destination.
# The directory has to be named: the decision cannot be read off the argv,
# and one global answer would sudo the copies into $HOME too, leaving the
# user root-owned files in their own home directory.
run_privileged() {
    local dir="$1"
    shift
    if needs_sudo "$dir"; then
        sudo "$@"
    else
        "$@"
    fi
}

# Put a file in place by rename, never by rewriting the file that is there.
#
# A wiggum run holds its script open for hours, and bash reads a script by byte
# offset as it goes: overwrite that inode mid-run and bash resumes at an offset
# that has moved, then dies on whatever fragment it lands in -- "syntax error
# near unexpected token" and exit 2, on a run that was doing fine. rename(2)
# swaps the directory entry instead, so the live run keeps the file it started
# with and only the next run sees the new one.
install_file() {
    local src="$1" dest="$2" dir
    dir="$(dirname "$dest")"
    run_privileged "$dir" cp "$src" "$dest.new"
    run_privileged "$dir" mv -f "$dest.new" "$dest"
}

# The first completion directory that exists. Homebrew keeps its own tree, but
# only a default install may look outside the prefix -- a test prefix has to
# write nothing beyond itself.
first_existing_dir() {
    local rel="$1" d
    local -a candidates=()
    [[ "$PREFIX" == "/usr/local" ]] && candidates+=("/opt/homebrew/$rel")
    candidates+=("$PREFIX/$rel")
    for d in "${candidates[@]}"; do
        if [[ -d "$d" ]]; then
            printf '%s\n' "$d"
            return 0
        fi
    done
    return 0
}

# Install lib + CLI (safe to re-run for updates)
if [[ -f "$INSTALL_DIR/wiggum.sh" ]]; then
    echo "Updating existing installation..."
else
    echo "Installing to $INSTALL_DIR..."
fi
run_privileged "$INSTALL_DIR/lib" mkdir -p "$INSTALL_DIR/lib"
install_file "$SOURCE_DIR/wiggum.sh" "$INSTALL_DIR/wiggum.sh"
install_file "$SOURCE_DIR/lib/wiggum.sh" "$INSTALL_DIR/lib/wiggum.sh"
run_privileged "$INSTALL_DIR" chmod +x "$INSTALL_DIR/wiggum.sh"

# Symlink into bin
echo "Linking $BIN_DIR/$SCRIPT_NAME..."
run_privileged "$BIN_DIR" mkdir -p "$BIN_DIR"
run_privileged "$BIN_DIR" ln -sf "$INSTALL_DIR/wiggum.sh" "$BIN_DIR/$SCRIPT_NAME"

# Install shell completions
ZSH_COMP_DIR="$(first_existing_dir "share/zsh/site-functions")"
if [[ -n "$ZSH_COMP_DIR" && -f "$SOURCE_DIR/completions/wiggum.zsh" ]]; then
    install_file "$SOURCE_DIR/completions/wiggum.zsh" "$ZSH_COMP_DIR/_wiggum"
    echo "Installed zsh completions to $ZSH_COMP_DIR/_wiggum"
fi

BASH_COMP_DIR="$(first_existing_dir "etc/bash_completion.d")"
if [[ -n "$BASH_COMP_DIR" && -f "$SOURCE_DIR/completions/wiggum.bash" ]]; then
    install_file "$SOURCE_DIR/completions/wiggum.bash" "$BASH_COMP_DIR/wiggum"
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
    install_file "$SKILL_SRC" "$SKILL_DIR/SKILL.md"
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
