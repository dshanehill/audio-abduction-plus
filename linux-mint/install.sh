#!/usr/bin/env bash
# Installs the Audio Abduction+ tray toggle on Linux Mint (run as your normal user).
set -euo pipefail
cd "$(dirname "$0")"

NEED=""
for pkg in python3-gi gir1.2-xapp-1.0 pulseaudio-utils libnotify-bin; do
  dpkg -s "$pkg" >/dev/null 2>&1 || NEED="$NEED $pkg"
done
if [ -n "$NEED" ]; then sudo apt install -y $NEED; fi

if ! pactl info | grep -qi pipewire; then
  echo "Warning: this system isn't using PipeWire (Mint 22+ needed)." >&2
fi

[ -n "${MAC_HOST:-}" ] || read -rp "Your Mac's hostname or IP: " MAC_HOST
mkdir -p ~/.config/mac-audio ~/.local/bin ~/.config/autostart \
         ~/.local/share/audio-abduction ~/.local/share/applications
echo "MAC_HOST=$MAC_HOST" > ~/.config/mac-audio/config

install -m 644 audio-abduction-on.png audio-abduction-off.png ~/.local/share/audio-abduction/
install -m 755 audio-abduction.py ~/.local/bin/audio-abduction

# Retire the earlier unbranded version.
pkill -f mac-audio-toggle || true
pkill -f "bin/audio-abduction" || true
rm -f ~/.local/bin/mac-audio-toggle ~/.config/autostart/mac-audio-toggle.desktop

DESKTOP="[Desktop Entry]
Type=Application
Name=Audio Abduction+
Comment=Beam this computer's audio to your Mac
Exec=$HOME/.local/bin/audio-abduction
Icon=$HOME/.local/share/audio-abduction/audio-abduction-on.png
Categories=AudioVideo;Audio;
X-GNOME-Autostart-enabled=true"
echo "$DESKTOP" > ~/.config/autostart/audio-abduction.desktop
echo "$DESKTOP" > ~/.local/share/applications/audio-abduction.desktop

nohup ~/.local/bin/audio-abduction >/dev/null 2>&1 &
echo "Audio Abduction+ installed. Click the alien in your panel to toggle."
