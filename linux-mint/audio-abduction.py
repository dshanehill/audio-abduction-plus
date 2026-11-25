#!/usr/bin/env python3
"""Audio Abduction+ (Mint side) — a tray icon that sends all audio to your Mac.

Left-click the tray icon to toggle. Right-click for the menu.
ON  : loads a network (RTP) sink pointed at the Mac and makes it the default output.
OFF : removes it and restores your previous output.

Phone and tablet audio: plug an Android phone or tablet (Android 11+, USB debugging
on) into this PC and its sound plays here through scrcpy, in audio-only mode with no
window. It goes wherever this PC's sound goes, so while beaming is on it reaches the Mac.
"""
import ctypes
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time

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
CACHE_DIR = os.path.expanduser("~/.cache/mac-audio")
PREV_FILE = os.path.join(CACHE_DIR, "prev_sink")
APP_NAME = "Audio Abduction+"
ICON_DIR = os.path.expanduser("~/.local/share/audio-abduction")
ICON_ON = os.path.join(ICON_DIR, "audio-abduction-on.png")
ICON_OFF = os.path.join(ICON_DIR, "audio-abduction-off.png")
SCRCPY_DIR = os.path.join(ICON_DIR, "scrcpy")  # static scrcpy build (includes adb)


def sh(*args):
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout).strip() or f"{args[0]} failed")
    return r.stdout.strip()


def notify(msg):
    subprocess.run(["notify-send", "-i", ICON_ON, APP_NAME, msg])


def read_config():
    cfg = {}
    try:
        with open(CONFIG) as f:
            for line in f:
                if "=" in line:
                    k, v = line.rstrip("\n").split("=", 1)
                    cfg[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return cfg


def set_config(key, value):
    cfg = read_config()
    cfg[key] = value
    os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
    with open(CONFIG, "w") as f:
        f.writelines(f"{k}={v}\n" for k, v in cfg.items())


def mac_host():
    host = read_config().get("MAC_HOST")
    if not host:
        raise RuntimeError(f"MAC_HOST not set in {CONFIG}")
    return host


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


# ---------------------------------------------------------------------------
# Phone and tablet audio (scrcpy over USB)
# ---------------------------------------------------------------------------

def tool(name):
    """Prefer the scrcpy build the installer put in ~/.local/share; fall back to PATH."""
    path = os.path.join(SCRCPY_DIR, name)
    return path if os.access(path, os.X_OK) else shutil.which(name)


def parse_adb_devices(text):
    """`adb devices` output -> {serial: state}. USB devices only (no Wi-Fi adb)."""
    found = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 2 or line.startswith(("List of", "*")):
            continue
        serial, state = parts[0], parts[1]
        if ":" in serial or "._tcp" in serial:  # wireless debugging, not plugged in
            continue
        found[serial] = state
    return found


def parse_getprop(text):
    return dict(re.findall(r"^\[([^\]]+)\]: \[(.*)\]$", text, re.M))


def device_name(props, serial):
    for key in ("ro.product.marketname", "ro.vendor.oplus.market.name",
                "ro.product.vendor.marketname", "ro.config.marketing_name"):
        if props.get(key):
            return props[key]
    maker = props.get("ro.product.manufacturer", "").strip().capitalize()
    model = props.get("ro.product.model", "").strip()
    return " ".join(p for p in (maker, model) if p) or f"Device {serial}"


def parse_sink_inputs(text):
    """`pactl list sink-inputs` -> [(input_id, sink_index, process_id)]."""
    out = []
    for block in re.split(r"^Sink Input #", text, flags=re.M)[1:]:
        sid = block.split("\n", 1)[0].strip()
        sink = re.search(r"^\s*Sink: (\d+)", block, re.M)
        pid = re.search(r'application\.process\.id = "(\d+)"', block)
        if sink and pid:
            out.append((sid, sink.group(1), int(pid.group(1))))
    return out


def _die_with_parent():
    """Make scrcpy stop if the tray app dies, so no audio is left running."""
    try:
        ctypes.CDLL("libc.so.6").prctl(1, signal.SIGTERM)  # PR_SET_PDEATHSIG
    except OSError:
        pass


class DeviceWatcher:
    """Every 2 s: start scrcpy (audio only) for each plugged-in device, stop it on unplug."""

    MIN_SDK = 30      # Android 11: first version scrcpy can capture audio on
    DUP_SDK = 33      # Android 13: needed to keep playing on the device too
    MAX_FAILS = 3

    def __init__(self, on_change):
        cfg = read_config()
        self.enabled = cfg.get("PHONE_AUDIO", "1") == "1"
        self.dup = cfg.get("AUDIO_DUP", "0") == "1"
        self._on_change = on_change
        self.devices = {}          # serial -> state dict
        self.warned = set()        # serials we already told to tap "Allow"
        self.lock = threading.Lock()
        self.stopping = threading.Event()
        self.problem = ""          # shown in the menu when phone audio can't work

    def on_change(self):
        """Ask the GTK thread to redraw the menu once (safe from any thread)."""
        GLib.idle_add(lambda: self._on_change() and False)

    # -- public, called from the GTK thread --
    def start(self):
        threading.Thread(target=self._loop, daemon=True).start()

    def set_enabled(self, value):
        self.enabled = value
        set_config("PHONE_AUDIO", "1" if value else "0")
        if not value:
            self.stop_all()

    def set_dup(self, value):
        self.dup = value
        set_config("AUDIO_DUP", "1" if value else "0")
        with self.lock:  # restart each device's capture with the new setting
            for d in self.devices.values():
                self._stop_proc(d)
                d.update(fails=0, gave_up=False, dup_ok=True, last_start=0)

    def names(self):
        with self.lock:
            return [d["name"] for d in self.devices.values() if d["proc"]]

    def stop_all(self):
        with self.lock:
            for d in self.devices.values():
                self._stop_proc(d)
            self.devices.clear()
        self.on_change()

    def shutdown(self):
        self.stopping.set()
        self.stop_all()

    # -- background thread --
    def _loop(self):
        while not self.stopping.is_set():
            try:
                self._poll()
            except Exception as e:  # never let the watcher die
                print(f"device watcher: {e}", file=sys.stderr)
            self.stopping.wait(2)

    def _poll(self):
        if not self.enabled:
            return
        adb, scrcpy = tool("adb"), tool("scrcpy")
        problem = "" if adb and scrcpy else "scrcpy not installed: re-run install.sh"
        if problem != self.problem:
            self.problem = problem
            self.on_change()
        if problem:
            return
        try:
            r = subprocess.run([adb, "devices"], capture_output=True, text=True, timeout=10)
            present = parse_adb_devices(r.stdout)
        except (subprocess.TimeoutExpired, OSError):
            return
        changed = False
        with self.lock:
            for serial in list(self.devices):
                if present.get(serial) != "device":
                    d = self.devices.pop(serial)
                    self._stop_proc(d)
                    notify(f"{d['name']} unplugged")
                    changed = True
            for serial, state in present.items():
                if state == "unauthorized":
                    if serial not in self.warned:
                        self.warned.add(serial)
                        notify("A phone or tablet is plugged in. Unlock it and tap Allow "
                               "to trust this computer, then its audio will start.")
                    continue
                if state != "device":
                    continue
                self.warned.discard(serial)
                d = self.devices.get(serial)
                if d is None:
                    d = self._new_device(adb, serial)
                    if d is None:
                        continue
                    self.devices[serial] = d
                    changed = True
                changed |= self._keep_running(adb, scrcpy, serial, d)
            pids = {d["proc"].pid for d in self.devices.values() if d["proc"]}
        if pids:
            self._route(pids)
        if changed:
            self.on_change()

    def _new_device(self, adb, serial):
        try:
            r = subprocess.run([adb, "-s", serial, "shell", "getprop"],
                               capture_output=True, text=True, timeout=10)
        except (subprocess.TimeoutExpired, OSError):
            return None
        if r.returncode != 0:
            return None
        props = parse_getprop(r.stdout)
        sdk = int(props.get("ro.build.version.sdk", "0") or 0)
        d = dict(name=device_name(props, serial), sdk=sdk, proc=None, log=None, fails=0,
                 gave_up=False, dup_ok=True, last_start=0, announced=False)
        if sdk and sdk < self.MIN_SDK:
            d["gave_up"] = True
            notify(f"{d['name']} runs Android {props.get('ro.build.version.release', '?')}. "
                   "Sending its audio needs Android 11 or newer.")
        return d

    def _keep_running(self, adb, scrcpy, serial, d):
        """Start or restart scrcpy for one device. Returns True if the menu should update."""
        proc = d["proc"]
        if proc and proc.poll() is None:
            if not d["announced"] and time.time() - d["last_start"] > 2:
                d["announced"] = True
                where = "to your Mac" if is_on() else "on this computer"
                notify(f"{d['name']} connected. Its audio is playing {where}.")
            if time.time() - d["last_start"] > 30:
                d["fails"] = 0  # it ran fine for a while: forget earlier hiccups
            return False
        if d["gave_up"] or time.time() - d["last_start"] < 3:
            return False
        if proc:  # it exited by itself
            d["proc"] = None
            if time.time() - d["last_start"] < 10:
                d["fails"] += 1
                if d["dup_ok"] and self.dup:
                    d["dup_ok"] = False  # try again without "also play on device"
            if d["fails"] >= self.MAX_FAILS:
                d["gave_up"] = True
                notify(f"Couldn't get audio from {d['name']}. Unplug it and plug it back in "
                       f"to try again. Details: {d['log']}")
                return True
        self._start_proc(adb, scrcpy, serial, d)
        return True

    def _start_proc(self, adb, scrcpy, serial, d):
        cmd = [scrcpy, "-s", serial, "--no-video", "--no-window", "--require-audio",
               "--audio-codec=raw", "--no-power-on",
               # scrcpy's default is 50 ms; 30 ms tested clean on a Galaxy Tab
               f"--audio-buffer={read_config().get('AUDIO_BUFFER', '30')}"]
        if self.dup and d["dup_ok"] and d["sdk"] >= self.DUP_SDK:
            cmd.append("--audio-dup")
        os.makedirs(CACHE_DIR, exist_ok=True)
        d["log"] = os.path.join(CACHE_DIR, "scrcpy-" + re.sub(r"\W", "_", serial) + ".log")
        with open(d["log"], "w") as log:
            d["proc"] = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=log,
                                         stderr=subprocess.STDOUT,
                                         env=dict(os.environ, ADB=adb),
                                         preexec_fn=_die_with_parent)
        d["last_start"] = time.time()

    @staticmethod
    def _stop_proc(d):
        proc, d["proc"] = d["proc"], None
        if proc and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(3)
            except subprocess.TimeoutExpired:
                proc.kill()

    @staticmethod
    def _route(pids):
        """Keep phone/tablet audio on the current default output (the Mac, while beaming).

        PipeWire may remember an old output for a returning stream; this overrides that.
        """
        try:
            default = sh("pactl", "get-default-sink")
            sinks = {p[1]: p[0] for p in (l.split("\t") for l in
                     sh("pactl", "list", "short", "sinks").splitlines()) if len(p) > 1}
            target = sinks.get(default)
            for sid, sink, pid in parse_sink_inputs(sh("pactl", "list", "sink-inputs")):
                if pid in pids and target and sink != target:
                    subprocess.run(["pactl", "move-sink-input", sid, default],
                                   capture_output=True)
        except RuntimeError:
            pass


# ---------------------------------------------------------------------------
# Tray icon
# ---------------------------------------------------------------------------

class App:
    def __init__(self):
        self.watcher = DeviceWatcher(self.refresh)

        self.menu = Gtk.Menu()
        self.check = Gtk.CheckMenuItem(label="Beam audio to Mac")
        self.check_handler = self.check.connect("toggled", lambda *_: self.toggle())

        self.phone_check = Gtk.CheckMenuItem(label="Phone and tablet audio")
        self.phone_check.set_active(self.watcher.enabled)
        self.phone_check.connect("toggled", self.on_phone_toggled)
        self.dup_check = Gtk.CheckMenuItem(label="Also play on the phone or tablet")
        self.dup_check.set_active(self.watcher.dup)
        self.dup_check.connect("toggled", lambda w: self.watcher.set_dup(w.get_active()))
        self.devices_item = Gtk.MenuItem(label="No phone or tablet connected")
        self.devices_item.set_sensitive(False)

        quit_item = Gtk.MenuItem(label="Quit")
        quit_item.connect("activate", lambda *_: self.quit())
        for item in (self.check, Gtk.SeparatorMenuItem(), self.phone_check, self.dup_check,
                     self.devices_item, Gtk.SeparatorMenuItem(), quit_item):
            self.menu.append(item)
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
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, self.quit)
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, self.quit)
        self.watcher.start()

    def quit(self, *_):
        self.watcher.shutdown()
        Gtk.main_quit()
        return False

    def on_click(self, _icon, button, _time):
        if button == 1:
            self.toggle()

    def on_phone_toggled(self, widget):
        self.watcher.set_enabled(widget.get_active())
        self.refresh()

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
        names = self.watcher.names()
        extra = f" + {', '.join(names)}" if names else ""
        if XApp is not None:
            self.icon.set_icon_name(ICON_ON if on else ICON_OFF)
            self.icon.set_tooltip_text(
                f"{APP_NAME}: beaming to Mac{extra} (click to stop)" if on
                else f"{APP_NAME}: audio here{extra} (click to beam to Mac)")
        else:
            self.icon.set_from_file(ICON_ON if on else ICON_OFF)
            self.icon.set_tooltip_text(f"{APP_NAME}: {'on' if on else 'off'}{extra}")
        self.check.handler_block(self.check_handler)
        self.check.set_active(on)
        self.check.handler_unblock(self.check_handler)

        if not self.watcher.enabled:
            label = "Phone and tablet audio is off"
        elif self.watcher.problem:
            label = self.watcher.problem
        elif names:
            label = "Connected: " + ", ".join(names)
        else:
            label = "No phone or tablet connected"
        self.devices_item.set_label(label)
        self.dup_check.set_sensitive(self.watcher.enabled)
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
    os.makedirs(CACHE_DIR, exist_ok=True)
    _lock = open(os.path.join(CACHE_DIR, "app.lock"), "w")
    try:
        fcntl.flock(_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        notify("Already running: look for the alien in your panel")
        sys.exit(0)
    App()
    Gtk.main()
