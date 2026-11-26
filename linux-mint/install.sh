#!/usr/bin/env bash
# Installs the Audio Abduction+ tray toggle on Linux Mint (run as your normal user).
set -euo pipefail
cd "$(dirname "$0")"

# android-sdk-platform-tools-common: USB permission rules so phones/tablets can be used
NEED=""
for pkg in python3-gi gir1.2-xapp-1.0 pulseaudio-utils libnotify-bin curl \
           android-sdk-platform-tools-common; do
  dpkg -s "$pkg" >/dev/null 2>&1 || NEED="$NEED $pkg"
done
if [ -n "$NEED" ]; then
  sudo apt install -y $NEED
  sudo udevadm control --reload-rules && sudo udevadm trigger || true
fi

# Virtual sound card for beaming. Unlike a plain virtual speaker it can carry a delay
# value, so video players hold the picture back to stay in step with the sound.
if ! lsmod | grep -q snd_aloop; then
  sudo modprobe snd-aloop
fi
[ -f /etc/modules-load.d/audio-abduction-aloop.conf ] || \
  echo snd-aloop | sudo tee /etc/modules-load.d/audio-abduction-aloop.conf >/dev/null
mkdir -p ~/.config/wireplumber/main.lua.d
if ! cmp -s wireplumber/51-audio-abduction.lua ~/.config/wireplumber/main.lua.d/51-audio-abduction.lua; then
  install -m 644 wireplumber/51-audio-abduction.lua ~/.config/wireplumber/main.lua.d/
  systemctl --user restart wireplumber || true
  sleep 2
fi

if ! pactl info | grep -qi pipewire; then
  echo "Warning: this system isn't using PipeWire (Mint 22+ needed)." >&2
fi

mkdir -p ~/.config/mac-audio ~/.local/bin ~/.config/autostart \
         ~/.local/share/audio-abduction ~/.local/share/applications
CFG=~/.config/mac-audio/config
if [ -z "${MAC_HOST:-}" ]; then
  MAC_HOST=$(sed -n 's/^MAC_HOST=//p' "$CFG" 2>/dev/null || true)
  [ -n "$MAC_HOST" ] || read -rp "Your Mac's hostname or IP: " MAC_HOST
fi
# Keep other settings (phone audio on/off etc.) and just set MAC_HOST.
{ grep -v '^MAC_HOST=' "$CFG" 2>/dev/null || true; echo "MAC_HOST=$MAC_HOST"; } > "$CFG.new"
mv "$CFG.new" "$CFG"

# scrcpy (2.0+ needed for audio; Mint's apt version is too old). Official static build,
# checked against its published SHA-256. It includes its own adb.
SCRCPY_VER=3.3.4
SCRCPY_SHA=0305d98c06178c67e12427bbf340c436d0d58c9e2a39bf9ffbbf8f54d7ef95a5
SCRCPY_DIR=~/.local/share/audio-abduction/scrcpy
if [ "$(uname -m)" = x86_64 ]; then
  if ! "$SCRCPY_DIR/scrcpy" --version 2>/dev/null | grep -q "scrcpy $SCRCPY_VER"; then
    echo "Downloading scrcpy $SCRCPY_VER for phone and tablet audio..."
    TMP=$(mktemp -d)
    curl -fsSL -o "$TMP/scrcpy.tar.gz" \
      "https://github.com/Genymobile/scrcpy/releases/download/v$SCRCPY_VER/scrcpy-linux-x86_64-v$SCRCPY_VER.tar.gz"
    echo "$SCRCPY_SHA  $TMP/scrcpy.tar.gz" | sha256sum -c --quiet -
    rm -rf "$SCRCPY_DIR" && mkdir -p "$SCRCPY_DIR"
    tar -xzf "$TMP/scrcpy.tar.gz" -C "$SCRCPY_DIR" --strip-components=1
    rm -rf "$TMP"
  fi
else
  echo "Note: no ready-made scrcpy for $(uname -m). For phone audio, install scrcpy 2.0+ yourself." >&2
fi

install -m 644 audio-abduction-on.png audio-abduction-off.png ~/.local/share/audio-abduction/
install -m 755 audio-abduction.py ~/.local/bin/audio-abduction
install -m 644 aa_settings.py ~/.local/share/audio-abduction/

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
# Keep "Open at Login" off if it was turned off in Settings.
if grep -q '^X-GNOME-Autostart-enabled=false' ~/.config/autostart/audio-abduction.desktop 2>/dev/null; then
  echo "$DESKTOP" | sed 's/^X-GNOME-Autostart-enabled=true/X-GNOME-Autostart-enabled=false/' \
    > ~/.config/autostart/audio-abduction.desktop
else
  echo "$DESKTOP" > ~/.config/autostart/audio-abduction.desktop
fi
# The menu entry opens the Settings window.
echo "$DESKTOP" | sed "s|^Exec=.*|Exec=$HOME/.local/bin/audio-abduction --settings|" \
  > ~/.local/share/applications/audio-abduction.desktop

sleep 1
nohup ~/.local/bin/audio-abduction >/dev/null 2>&1 &
echo "Audio Abduction+ installed. Click the alien in your panel to toggle."
echo "Right-click it and choose Settings… (or open Audio Abduction+ from the menu) to change settings."
echo "Plug in an Android phone or tablet (USB debugging on) and its audio comes along too."
