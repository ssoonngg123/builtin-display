#!/bin/sh
# Build builtin-display, install it to ~/.local/bin, and start a login agent
# that keeps the built-in display off while an external display is connected.
set -eu

cd "$(dirname "$0")"

LABEL="local.builtin-display"
BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/builtin-display"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/builtin-display.log"
DOMAIN="gui/$(id -u)"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc not found. Install the Xcode Command Line Tools first:" >&2
    echo "    xcode-select --install" >&2
    exit 1
fi

mkdir -p "$BIN_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

echo "Building..."
# Build next to the destination and rename, so a running copy is never
# overwritten in place.
swiftc -O builtin-display.swift -o "$BIN.tmp"
mv -f "$BIN.tmp" "$BIN"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$BIN</string>
		<string>watch</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>StandardOutPath</key>
	<string>$LOG</string>
	<key>StandardErrorPath</key>
	<string>$LOG</string>
</dict>
</plist>
EOF

# Replace any agent that is already loaded, waiting for the old one to go.
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    tries=0
    while launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 && [ "$tries" -lt 50 ]; do
        sleep 0.1
        tries=$((tries + 1))
    done
fi
launchctl bootstrap "$DOMAIN" "$PLIST"

echo "Installed $BIN"
echo "Login agent $LABEL is running; log: $LOG"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "Note: $BIN_DIR is not on your PATH. Add it, or run $BIN directly." ;;
esac
