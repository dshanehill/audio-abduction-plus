#!/usr/bin/env python3
"""Audio Abduction+ (Mint side) — a tray icon that sends all audio to your Mac.

Left-click the tray icon to toggle. Right-click for the menu.
ON  : loads a network (RTP) sink pointed at the Mac and makes it the default output.
OFF : removes it and restores your previous output.
"""
import os
import socket
import subprocess
import sys

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # noqa: E402

try:
    gi.require_version("XApp", "1.0")
    from gi.repository import XApp  # Mint's native tray icon (left-click = activate)
except (ValueError, ImportError):
    XApp = None

SINK_NAME = "mac_audio"
CONFIG = os.path.expanduser("~/.config/mac-audio/config")
PREV_FILE = os.path.expanduser("~/.cache/mac-audio/prev_sink")
APP_NAME = "Audio Abduction+"
ICON_DIR = os.path.expanduser("~/.local/share/audio-abduction")
ICON_ON = os.path.join(ICON_DIR, "audio-abduction-on.png")
ICON_OFF = os.path.join(ICON_DIR, "audio-abduction-off.png")


def sh(*args):
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout).strip() or f"{args[0]} failed")
    return r.stdout.strip()


def notify(msg):
    subprocess.run(["notify-send", "-i", ICON_ON, APP_NAME, msg])


def mac_host():
    with open(CONFIG) as f:
        for line in f:
            if line.startswith("MAC_HOST="):
                return line.split("=", 1)[1].strip()
    raise RuntimeError(f"MAC_HOST not set in {CONFIG}")


PORT = 46000


def our_module_ids():
    """Modules we loaded: the 'Mac' null sink and the RTP sender reading its monitor."""
    ids = []
    for line in sh("pactl", "list", "short", "modules").splitlines():
        parts = line.split("\t")
        if len(parts) > 2 and parts[1] in ("module-null-sink", "module-rtp-send") \
                and SINK_NAME in parts[2]:
            ids.append(parts[0])
    return ids


def is_on():
    try:
        return bool(our_module_ids())
    except RuntimeError:
        return False


def move_all_streams(sink):
    for line in sh("pactl", "list", "short", "sink-inputs").splitlines():
        sid = line.split("\t")[0]
        subprocess.run(["pactl", "move-sink-input", sid, sink], capture_output=True)


def turn_on():
    ip = socket.gethostbyname(mac_host())  # works with names like my-mac.local
    prev = sh("pactl", "get-default-sink")
    if prev != SINK_NAME:
        os.makedirs(os.path.dirname(PREV_FILE), exist_ok=True)
        with open(PREV_FILE, "w") as f:
            f.write(prev)
    sh("pactl", "load-module", "module-null-sink", f"sink_name={SINK_NAME}",
       "sink_properties=device.description=Audio-Abduction+", "rate=48000", "channels=2")
    sh("pactl", "load-module", "module-rtp-send", f"source={SINK_NAME}.monitor",
       f"destination_ip={ip}", f"port={PORT}", "loop=0")
    sh("pactl", "set-default-sink", SINK_NAME)
    move_all_streams(SINK_NAME)


def turn_off():
    for mid in reversed(our_module_ids()):
        subprocess.run(["pactl", "unload-module", mid], capture_output=True)
    try:
        with open(PREV_FILE) as f:
            prev = f.read().strip()
    except FileNotFoundError:
        prev = ""
    if prev:
        subprocess.run(["pactl", "set-default-sink", prev], capture_output=True)
        move_all_streams(prev)


class App:
    def __init__(self):
        self.menu = Gtk.Menu()
        self.check = Gtk.CheckMenuItem(label="Beam audio to Mac")
        self.check_handler = self.check.connect("toggled", lambda *_: self.toggle())
        quit_item = Gtk.MenuItem(label="Quit")
        quit_item.connect("activate", lambda *_: Gtk.main_quit())
        self.menu.append(self.check)
        self.menu.append(Gtk.SeparatorMenuItem())
        self.menu.append(quit_item)
        self.menu.show_all()

        if XApp is not None:
            self.icon = XApp.StatusIcon()
            self.icon.set_name("audio-abduction")
            self.icon.set_secondary_menu(self.menu)
            self.icon.connect("activate", self.on_click)
        else:  # fallback for non-Cinnamon desktops
            self.icon = Gtk.StatusIcon()
            self.icon.connect("activate", lambda *_: self.toggle())
            self.icon.connect("popup-menu", lambda i, b, t: self.menu.popup(
                None, None, Gtk.StatusIcon.position_menu, i, b, t))

        self.refresh()
        GLib.timeout_add_seconds(2, self.refresh)

    def on_click(self, _icon, button, _time):
        if button == 1:
            self.toggle()

    def toggle(self):
        try:
            if is_on():
                turn_off()
                notify("Audio back on this computer")
            else:
                turn_on()
                notify("Audio beamed up to your Mac 🛸")
        except Exception as e:  # show the reason instead of failing silently
            notify(f"Couldn't switch: {e}")
            turn_off()
        self.refresh()

    def refresh(self):
        on = is_on()
        if XApp is not None:
            self.icon.set_icon_name(ICON_ON if on else ICON_OFF)
            self.icon.set_tooltip_text(f"{APP_NAME}: beaming to Mac (click to stop)" if on
                                       else f"{APP_NAME}: audio here (click to beam to Mac)")
        else:
            self.icon.set_from_file(ICON_ON if on else ICON_OFF)
            self.icon.set_tooltip_text(f"{APP_NAME}: on" if on else f"{APP_NAME}: off")
        self.check.handler_block(self.check_handler)
        self.check.set_active(on)
        self.check.handler_unblock(self.check_handler)
        return True


if __name__ == "__main__":
    if "--toggle" in sys.argv:  # also usable from a keyboard shortcut
        try:
            turn_off() if is_on() else turn_on()
        except Exception as e:
            notify(f"Couldn't switch: {e}")
            turn_off()
        sys.exit(0)
    import fcntl  # only one tray copy at a time (the menu entry may be clicked while running)
    os.makedirs(os.path.dirname(PREV_FILE), exist_ok=True)
    _lock = open(os.path.join(os.path.dirname(PREV_FILE), "app.lock"), "w")
    try:
        fcntl.flock(_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        notify("Already running: look for the alien in your panel")
        sys.exit(0)
    App()
    Gtk.main()
