#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/usr/local/bin"
SCRIPT_NAME="wiggum"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_FILE="$SOURCE_DIR/wiggum.sh"

echo "Wiggum installer"
echo ""

# Check source exists
if [[ ! -f "$SOURCE_FILE" ]]; then
    echo "Error: wiggum.sh not found in $SOURCE_DIR"
    exit 1
fi

# Check Claude Code is available
if ! command -v claude &>/dev/null; then
    echo "Warning: 'claude' (Claude Code CLI) not found on PATH."
    echo "Wiggum requires Claude Code to run. Install it from https://claude.com/claude-code"
    echo ""
fi

# Create /usr/local/bin if needed (common on fresh macOS)
if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "Creating $INSTALL_DIR (requires sudo)..."
    sudo mkdir -p "$INSTALL_DIR"
fi

# Install
echo "Installing $SCRIPT_NAME to $INSTALL_DIR..."
if [[ -w "$INSTALL_DIR" ]]; then
    cp "$SOURCE_FILE" "$INSTALL_DIR/$SCRIPT_NAME"
    chmod +x "$INSTALL_DIR/$SCRIPT_NAME"
else
    sudo cp "$SOURCE_FILE" "$INSTALL_DIR/$SCRIPT_NAME"
    sudo chmod +x "$INSTALL_DIR/$SCRIPT_NAME"
fi

# Copy example config to home if no config exists yet
if [[ ! -f "$HOME/.wiggumrc" ]]; then
    if [[ -f "$SOURCE_DIR/.wiggumrc.example" ]]; then
        cp "$SOURCE_DIR/.wiggumrc.example" "$HOME/.wiggumrc"
        echo "Created ~/.wiggumrc from example (edit to match your project)"
    fi
fi

# Verify
if command -v wiggum &>/dev/null; then
    echo ""
    echo "Installed successfully: $(which wiggum)"
    echo "Run 'wiggum --help' to get started."
else
    echo ""
    echo "Installed to $INSTALL_DIR/$SCRIPT_NAME"
    echo "If 'wiggum' is not found, add $INSTALL_DIR to your PATH:"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
fi
