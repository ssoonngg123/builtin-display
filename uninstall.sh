#!/bin/sh
# Stop the login agent, turn the built-in display back on, and remove
# everything install.sh created.
set -eu

LABEL="local.builtin-display"
BIN="$HOME/.local/bin/builtin-display"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/builtin-display.log"

# Stop the watcher first so it cannot turn the display off again.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

if [ -x "$BIN" ]; then
    "$BIN" on || echo "Could not re-enable the built-in display; restarting the Mac will." >&2
fi

rm -f "$BIN" "$PLIST" "$LOG" "$HOME/.builtin-display-id" "$HOME/.builtin-display-keep-on"
echo "builtin-display removed."
