#!/bin/bash
set -e

echo ""
echo "=== OTK Installer ==="
echo ""

# Prompt for VPS URL
printf "Enter your OTK server URL [https://saveonllm.tech/]: "
read -r _otk_url
OTK_SERVER="${_otk_url:-https://saveonllm.tech/}"
OTK_SERVER="${OTK_SERVER%/}"  # strip trailing slash

# Save to config
mkdir -p "$HOME/.config/otk"
CONFIG_FILE="$HOME/.config/otk/config.toml"
if [ -f "$CONFIG_FILE" ]; then
  # Update existing server_url
  grep -v "^server_url" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
fi
echo "server_url = \"$OTK_SERVER\"" >> "$CONFIG_FILE"
echo "✓ Server URL saved: $OTK_SERVER"

# Install tiktoken for accurate token counting
pip install tiktoken --quiet 2>/dev/null || pip3 install tiktoken --quiet 2>/dev/null || echo "  (tiktoken not installed — will use char estimate)"

# Determine install dir
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Make otk globally accessible
chmod +x "$SCRIPT_DIR/otk.py"
ln -sf "$SCRIPT_DIR/otk.py" /usr/local/bin/otk 2>/dev/null || \
  ln -sf "$SCRIPT_DIR/otk.py" "$HOME/.local/bin/otk" 2>/dev/null || \
  { mkdir -p "$HOME/.local/bin" && ln -sf "$SCRIPT_DIR/otk.py" "$HOME/.local/bin/otk"; }

chmod +x "$SCRIPT_DIR/hook.sh"

echo "✓ OTK installed"
echo ""
echo "Test it:"
echo "  otk git status"
echo "  otk gain"
echo ""
echo "To use as a Claude Code hook, add to ~/.claude/settings.json:"
echo '  "hooks": { "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "~/.claude/hooks/otk-hook.sh"}]}] }'
