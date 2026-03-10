#!/bin/bash
set -e

echo ""
echo "=== OTK Installer ==="
echo ""

# If stdin is a TTY, prompt; otherwise use default
if [ -t 0 ]; then
  printf "Enter your OTK server URL [https://otk.alejandrodelarocha.com/]: "
  read -r _otk_url
else
  _otk_url=""
fi
OTK_SERVER="${_otk_url:-https://otk.alejandrodelarocha.com/}"
OTK_SERVER="${OTK_SERVER%/}"

# Save to config
mkdir -p "$HOME/.config/otk"
CONFIG_FILE="$HOME/.config/otk/config.toml"
if [ -f "$CONFIG_FILE" ]; then
  grep -v "^server_url" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
fi
echo "server_url = \"$OTK_SERVER\"" >> "$CONFIG_FILE"
echo "✓ Server URL saved: $OTK_SERVER"

# Install tiktoken
pip install tiktoken --quiet 2>/dev/null || pip3 install tiktoken --quiet 2>/dev/null || echo "  (tiktoken not installed — will use char estimate)"

# Download otk.py
INSTALL_DIR="$HOME/.local/share/otk"
mkdir -p "$INSTALL_DIR"
curl -sL "$OTK_SERVER/otk.py" -o "$INSTALL_DIR/otk.py"
chmod +x "$INSTALL_DIR/otk.py"

# Make otk globally accessible
mkdir -p "$HOME/.local/bin"
ln -sf "$INSTALL_DIR/otk.py" /usr/local/bin/otk 2>/dev/null || \
  ln -sf "$INSTALL_DIR/otk.py" "$HOME/.local/bin/otk"
echo "✓ OTK client installed"

# Download commands whitelist
curl -sL "$OTK_SERVER/commands.txt" -o "$HOME/.config/otk/commands.txt"
echo "✓ Commands list downloaded ($(wc -l < "$HOME/.config/otk/commands.txt") commands)"

# Install Claude Code hook
mkdir -p "$HOME/.claude/hooks"
curl -sL "$OTK_SERVER/otk-rewrite.sh" -o "$HOME/.claude/hooks/otk-rewrite.sh"
chmod +x "$HOME/.claude/hooks/otk-rewrite.sh"

# Update Claude Code settings
SETTINGS="$HOME/.claude/settings.json"
HOOK_CMD="$HOME/.claude/hooks/otk-rewrite.sh"

if [ -f "$SETTINGS" ]; then
  if command -v jq &>/dev/null; then
    UPDATED=$(jq --arg hook "$HOOK_CMD" '.hooks.PreToolUse = [{"matcher": "Bash", "hooks": [{"type": "command", "command": $hook}]}]' "$SETTINGS")
    echo "$UPDATED" > "$SETTINGS"
  else
    echo "  ⚠ jq not found — please manually add hook to $SETTINGS"
  fi
else
  mkdir -p "$HOME/.claude"
  cat > "$SETTINGS" << SETTINGSEOF
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "$HOOK_CMD"
          }
        ]
      }
    ]
  }
}
SETTINGSEOF
fi
echo "✓ Claude Code hook installed"

# Ping the dashboard
otk ping 2>/dev/null || true

echo ""
echo "✓ OTK fully installed — commands from whitelist will be intercepted"
echo ""
echo "Test it:"
echo "  otk git status"
echo "  otk gain"
