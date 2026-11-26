#!/usr/bin/env bash
# Installs Audio Abduction+ on your Mac (run as your normal user).
# Builds ~/Applications/Audio Abduction+.app (Dock icon, menu bar icon and Settings window)
# and starts it at login with a LaunchAgent.
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

if ! command -v swiftc >/dev/null; then
  echo "Building the app needs Apple's command line tools. Installing them now;" >&2
  echo "run this script again when that finishes." >&2
  xcode-select --install || true
  exit 1
fi

APP="$HOME/Applications/Audio Abduction+.app"
PLIST="$HOME/Library/LaunchAgents/local.audio-abduction.plus.plist"
BUILD=$(mktemp -d)
echo "Building Audio Abduction+..."
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos14.2" \
  -o "$BUILD/AudioAbduction" AudioAbduction.swift

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$HOME/Library/LaunchAgents"
cp Info.plist "$APP/Contents/"
install -m 755 "$BUILD/AudioAbduction" "$APP/Contents/MacOS/AudioAbduction"
cp Resources/receiver.py Resources/AudioAbduction.icns "$APP/Contents/Resources/"
rm -rf "$BUILD"
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true

# Starts at login. Quitting from the app keeps it quit; it's restarted only if it crashes.
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.audio-abduction.plus</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/AudioAbduction</string></array>
  <key>AssociatedBundleIdentifiers</key><array><string>local.audio-abduction.plus</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>/tmp/audio-abduction.log</string>
</dict></plist>
PL
launchctl bootstrap "gui/$(id -u)" "$PLIST"
open "$APP"
echo "Audio Abduction+ is running. Click its Dock icon to open Settings."
echo "If macOS asks whether Python may accept incoming connections, click Allow."
