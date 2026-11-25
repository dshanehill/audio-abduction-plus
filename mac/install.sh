#!/usr/bin/env bash
# Installs the Audio Abduction+ receiver on your Mac (run as your normal user).
# Builds ~/Applications/Audio Abduction+.app and starts it at login with a LaunchAgent.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -x /opt/homebrew/bin/play ]; then
  if command -v brew >/dev/null; then
    brew install sox
  else
    echo "Please install Homebrew (https://brew.sh), then run: brew install sox" >&2
    exit 1
  fi
fi

APP="$HOME/Applications/Audio Abduction+.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$HOME/Library/LaunchAgents"
cp Info.plist "$APP/Contents/"
install -m 755 launcher.sh "$APP/Contents/MacOS/AudioAbduction"
cp Resources/receiver.py Resources/AudioAbduction.icns "$APP/Contents/Resources/"

PLIST="$HOME/Library/LaunchAgents/local.audio-abduction.plus.plist"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.audio-abduction.plus</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/AudioAbduction</string></array>
  <key>AssociatedBundleIdentifiers</key><array><string>local.audio-abduction.plus</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>/tmp/audio-abduction.log</string>
</dict></plist>
EOF

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Audio Abduction+ is listening on UDP port 46000."
echo "If macOS asks whether Python may accept incoming connections, click Allow."
