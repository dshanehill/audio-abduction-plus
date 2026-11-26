"""Audio Abduction+ settings window (Linux Mint side).

A plain-language window in the style of a Mac settings pane: grouped rows, switches
on the right, short explanations under each setting. It controls what the Linux side
does: which way sound goes (this PC to the Mac, or the Mac to this PC), which Mac to send to, phone and tablet sound,
and keeping video in step with the sound.

`app` is the running tray App from audio-abduction; `aa` is that script's module, so
this file uses its functions (is_on, read_config, set_av_delay...) rather than copying them.
"""
import os
import socket
import time

from gi.repository import Gdk, GdkPixbuf, GLib, Gtk

CSS = b"""
.aa-window { background-color: shade(@theme_bg_color, 0.97); }
.aa-heading { font-weight: bold; font-size: 0.92em; color: alpha(@theme_fg_color, 0.62);
              margin: 16px 6px 6px 6px; }
.aa-footer { font-size: 0.86em; color: alpha(@theme_fg_color, 0.58); margin: 6px 6px 0 6px; }
.aa-group { background-color: @theme_base_color; border-radius: 10px;
            border: 1px solid alpha(@theme_fg_color, 0.12); }
.aa-group row { padding: 9px 14px; background-color: transparent; }
.aa-group row:hover { background-color: transparent; }
.aa-group row:not(:last-child) { border-bottom: 1px solid alpha(@theme_fg_color, 0.08); }
.aa-title { font-size: 1.35em; font-weight: bold; }
.aa-sub { font-size: 0.9em; color: alpha(@theme_fg_color, 0.62); }
.aa-error { font-size: 0.9em; color: #d70015; }
.aa-ok { font-size: 0.9em; color: #248a3d; }
"""

GREEN, ORANGE, RED, GREY = "#34c759", "#ff9500", "#ff3b30", "#8e8e93"
BUFFERS = [("Fastest", "20"), ("Balanced", "30"), ("Most Reliable", "50")]
AUTOSTART = os.path.expanduser("~/.config/autostart/audio-abduction.desktop")


def _label(text, cls=None, wrap=True, xalign=0.0):
    lab = Gtk.Label(label=text, xalign=xalign)
    lab.set_line_wrap(wrap)
    lab.set_max_width_chars(52)
    if cls:
        lab.get_style_context().add_class(cls)
    return lab


def _row(title, subtitle=None, widget=None):
    """One settings row: title (and grey explanation) on the left, control on the right."""
    row = Gtk.ListBoxRow(activatable=False, selectable=False)
    box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
    text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
    title_lab = _label(title)
    text.pack_start(title_lab, False, False, 0)
    sub_lab = None
    if subtitle is not None:
        sub_lab = _label(subtitle, "aa-sub")
        text.pack_start(sub_lab, False, False, 0)
    box.pack_start(text, True, True, 0)
    if widget is not None:
        widget.set_valign(Gtk.Align.CENTER)
        box.pack_end(widget, False, False, 0)
    row.add(box)
    row.title_lab, row.sub_lab = title_lab, sub_lab
    return row


def _group(*rows):
    lb = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
    lb.get_style_context().add_class("aa-group")
    for r in rows:
        lb.add(r)
    return lb


def _dot(color):
    return f'<span foreground="{color}">●</span>'


class SettingsWindow(Gtk.Window):
    def __init__(self, app, aa):
        super().__init__(title="Audio Abduction+")
        self.app, self.aa = app, aa
        self._quiet = False  # True while we set controls ourselves (no feedback loops)
        self._delay_timer = None

        prov = Gtk.CssProvider()
        prov.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), prov,
                                                 Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.get_style_context().add_class("aa-window")
        self.set_default_size(540, -1)
        self.set_resizable(False)
        self.set_position(Gtk.WindowPosition.CENTER)
        try:
            self.set_icon_from_file(aa.ICON_ON)
        except GLib.Error:
            pass
        self.connect("delete-event", lambda *_: self.hide() or True)

        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        page.set_border_width(20)

        # --- Header: what's happening right now, in one sentence ---
        head = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=14)
        self.head_icon = Gtk.Image()
        head.pack_start(self.head_icon, False, False, 0)
        htext = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        htext.set_valign(Gtk.Align.CENTER)
        self.headline = _label("", "aa-title")
        self.headline.set_use_markup(True)
        self.detail = _label("", "aa-sub")
        htext.pack_start(self.headline, False, False, 0)
        htext.pack_start(self.detail, False, False, 0)
        head.pack_start(htext, True, True, 0)
        page.pack_start(head, False, False, 4)

        # --- Which way sound goes (shared with the Mac) ---
        self.forward_btn = Gtk.Button(label="Forward to Mac")
        self.forward_btn.get_style_context().add_class("suggested-action")
        self.forward_btn.connect("clicked", lambda *_: self.app.forward())
        self.stop_btn = Gtk.Button(label="Stop")
        self.stop_btn.connect("clicked", lambda *_: self.app.set_mode("off"))
        fbox = Gtk.Box(spacing=8)
        fbox.pack_start(self.stop_btn, False, False, 0)
        fbox.pack_start(self.forward_btn, False, False, 0)
        self.forward_row = _row("Sound Goes To", "", fbox)
        page.pack_start(Gtk.Box(), False, False, 6)
        page.pack_start(_group(self.forward_row), False, False, 0)
        page.pack_start(_label("Forward to Mac plays this PC's sound on your Mac. Forward to "
                               "Linux plays your Mac's sound on this PC. Clicking either one, "
                               "here or on the Mac, switches both computers.", "aa-footer"),
                        False, False, 0)

        # --- Your Mac ---
        self.host = Gtk.Entry(width_chars=18)
        self.host.set_placeholder_text("e.g. my-mac.local")
        self.host.connect("activate", self.on_host_apply)
        self.host.connect("changed", lambda *_: self._host_dirty())
        self.host_btn = Gtk.Button(label="Use This Mac")
        self.host_btn.connect("clicked", self.on_host_apply)
        hbox = Gtk.Box(spacing=8)
        hbox.pack_start(self.host, False, False, 0)
        hbox.pack_start(self.host_btn, False, False, 0)
        self.mac_row = _row("Mac", "", None)
        self.mac_status = self.mac_row.sub_lab
        page.pack_start(_label("Your Mac", "aa-heading"), False, False, 0)
        page.pack_start(_group(_row("Mac Name or Address",
                                    "The name or IP address of the Mac that plays the sound.",
                                    hbox), self.mac_row), False, False, 0)

        # --- Phones and tablets ---
        self.phone = Gtk.Switch()
        self.phone.connect("notify::active", self.on_phone)
        self.dup = Gtk.Switch()
        self.dup.connect("notify::active", self.on_dup)
        self.awake = Gtk.Switch()
        self.awake.connect("notify::active", self.on_awake)
        self.buffer = Gtk.ComboBoxText()
        for name, val in BUFFERS:
            self.buffer.append(val, name)
        self.buffer.connect("changed", self.on_buffer)
        self.dup_row = _row("Also Play on the Phone or Tablet",
                            "Keep the sound on the device's own speaker too. Needs Android 13 "
                            "or newer.", self.dup)
        self.awake_row = _row("Keep Screen On While Plugged In",
                              "Stops the device going to sleep, which would stop its sound.",
                              self.awake)
        self.buffer_row = _row("Connection",
                               "Choose Most Reliable if the phone's sound skips or crackles.",
                               self.buffer)
        page.pack_start(_label("Phones and Tablets", "aa-heading"), False, False, 0)
        page.pack_start(_group(_row("Play Phone and Tablet Sound",
                                    "Plug an Android phone or tablet into this PC with a USB "
                                    "cable and its sound plays here.", self.phone),
                               self.dup_row, self.awake_row, self.buffer_row), False, False, 0)
        page.pack_start(_label("Connected", "aa-heading"), False, False, 0)
        self.devices = _group()
        page.pack_start(self.devices, False, False, 0)
        page.pack_start(_label("First time? Turn on USB debugging on the device, plug it in, "
                               "unlock it and tap Allow.", "aa-footer"), False, False, 0)

        # --- Video ---
        self.auto = Gtk.Switch()
        self.auto.connect("notify::active", self.on_auto)
        adj = Gtk.Adjustment(value=250, lower=0, upper=600, step_increment=10,
                             page_increment=50)
        self.delay = Gtk.Scale(orientation=Gtk.Orientation.HORIZONTAL, adjustment=adj)
        self.delay.set_digits(0)
        self.delay.set_draw_value(False)
        self.delay.set_size_request(220, -1)
        self.delay.connect("value-changed", self.on_delay)
        self.delay_row = _row("Video Delay", "", self.delay)
        page.pack_start(_label("Video", "aa-heading"), False, False, 0)
        page.pack_start(_group(_row("Match Video to Sound Automatically",
                                    "Video players on this PC hold the picture back so lips "
                                    "match the words you hear from the Mac.", self.auto),
                               self.delay_row), False, False, 0)
        page.pack_start(_label("Turn off automatic matching only if the picture is still ahead "
                               "of or behind the sound. Works in web browsers, VLC and mpv.",
                               "aa-footer"), False, False, 0)

        # --- General ---
        self.login = Gtk.Switch()
        self.login.connect("notify::active", self.on_login)
        restart = Gtk.Button(label="Restart Phone Sound")
        restart.connect("clicked", lambda *_: self.app.watcher.restart_all())
        page.pack_start(_label("General", "aa-heading"), False, False, 0)
        page.pack_start(_group(_row("Open at Login", None, self.login),
                               _row("Having Trouble?",
                                    "Reconnects every plugged-in phone and tablet.", restart)),
                        False, False, 0)

        self.add(page)
        page.show_all()
        GLib.timeout_add_seconds(1, self._tick)

    # ------------------------------------------------------------------ showing
    def present_settings(self):
        self.load()
        self.refresh()
        self.show()
        self.present()

    def _tick(self):
        if self.get_visible():
            self.refresh()
        return True

    def load(self):
        """Put saved settings into the controls (only when the window opens)."""
        cfg = self.aa.read_config()
        self._quiet = True
        self.host.set_text(cfg.get("MAC_HOST", ""))
        self.phone.set_active(self.app.watcher.enabled)
        self.dup.set_active(self.app.watcher.dup)
        self.awake.set_active(cfg.get("KEEP_AWAKE", "1") == "1")
        buf = cfg.get("AUDIO_BUFFER", "30")
        self.buffer.set_active_id(buf if buf in dict((v, n) for n, v in BUFFERS) else "30")
        manual = cfg.get("AV_DELAY_MS")
        self.auto.set_active(not manual)
        self.delay.set_value(int(manual) if manual else self.aa.av_delay_ms())
        self.login.set_active(self._login_enabled())
        self._quiet = False
        self._host_dirty()

    def refresh(self):
        """Update the live parts: status, Mac connection, connected devices."""
        aa, mode = self.aa, self.app.mode
        on = mode == "mac"
        self.forward_btn.set_label(aa.forward_label(mode))
        self.stop_btn.set_visible(mode != "off")
        peer_ok = aa._peer_last and time.time() - aa._peer_last < 6
        self.forward_row.sub_lab.set_text({
            "mac": "Your Mac. Everything this PC plays, including plugged-in phones and "
                   "tablets, comes out of the Mac.",
            "linux": "This PC. Your Mac's sound comes out of this PC's speakers.",
            "off": "Each computer plays its own sound."}[mode])

        mac_age = time.time() - aa._mac_last if aa._mac_last else None
        mac_ok = mac_age is not None and mac_age < 5
        try:
            self.head_icon.set_from_pixbuf(GdkPixbuf.Pixbuf.new_from_file_at_size(
                aa.ICON_ON if mode != "off" else aa.ICON_OFF, 56, 56))
        except GLib.Error:
            pass
        if mode == "linux" and self.app.mac_sound.playing():
            self.headline.set_markup(f"{_dot(GREEN)}  Playing your Mac's sound")
            self.detail.set_text("Everything you play on the Mac comes out of this PC.")
        elif mode == "linux":
            self.headline.set_markup(f"{_dot(ORANGE)}  Waiting for your Mac's sound")
            self.detail.set_text("Nothing is arriving yet. Play something on the Mac. If it "
                                 "stays quiet, make sure Audio Abduction+ is open on the Mac." if
                                 peer_ok else "Your Mac isn't answering. Make sure Audio "
                                 "Abduction+ is open on the Mac.")
        elif on and mac_ok:
            self.headline.set_markup(f"{_dot(GREEN)}  Sending sound to your Mac")
            self.detail.set_text("Everything you play on this PC comes out of the Mac.")
        elif on:
            self.headline.set_markup(f"{_dot(ORANGE)}  Waiting for your Mac")
            self.detail.set_text("Sound is being sent, but the Mac isn't answering. Make sure "
                                 "Audio Abduction+ is open on the Mac.")
        else:
            self.headline.set_markup(f"{_dot(GREY)}  Playing on this PC")
            self.detail.set_text("Click Forward to Mac to hear this PC through your Mac.")

        linked = mac_ok or peer_ok
        if linked:
            self.mac_status.set_text("Connected. Your Mac is answering.")
        elif mode == "off":
            self.mac_status.set_text("Your Mac isn't answering. That's fine while nothing is "
                                     "being forwarded.")
        else:
            self.mac_status.set_text("No answer from the Mac yet.")
        self.mac_row.title_lab.set_markup(
            f"{_dot(GREEN if linked else ORANGE if mode != 'off' else GREY)}  Connection")

        # Devices
        for child in self.devices.get_children():
            self.devices.remove(child)
        items = self.app.watcher.summary()
        w = self.app.watcher
        if not w.enabled:
            items = [("Phone and tablet sound is off", None, GREY)]
        elif w.problem:
            items = [("Phone sound isn't set up", "Run the installer again to fix it.", RED)]
        elif not items:
            items = [("No phone or tablet plugged in", None, GREY)]
        for name, state, color in items:
            r = _row(name, state)
            r.title_lab.set_markup(f"{_dot(color)}  {GLib.markup_escape_text(name)}")
            self.devices.add(r)
        self.devices.show_all()

        for wdg in (self.dup_row, self.awake_row, self.buffer_row):
            wdg.set_sensitive(w.enabled)
        self.delay_row.set_sensitive(not self.auto.get_active())
        ms = int(self.delay.get_value()) if not self.auto.get_active() else aa.av_delay_ms()
        if self.auto.get_active():
            self.delay_row.sub_lab.set_text(f"Set automatically: {ms / 1000:.2f} seconds")
            self._quiet = True
            self.delay.set_value(ms)
            self._quiet = False
        else:
            self.delay_row.sub_lab.set_text(f"Picture held back by {ms / 1000:.2f} seconds")

    # ------------------------------------------------------------------ handlers
    def _host_dirty(self):
        saved = self.aa.read_config().get("MAC_HOST", "")
        text = self.host.get_text().strip()
        self.host_btn.set_sensitive(bool(text) and text != saved)

    def on_host_apply(self, *_):
        host = self.host.get_text().strip()
        if not host:
            return
        try:
            socket.gethostbyname(host)
        except OSError:
            self.mac_status.set_text(f"Can't find “{host}”. Check the name, or use the "
                                     "Mac's IP address.")
            return
        self.aa.set_config("MAC_HOST", host)
        if self.aa.is_on():  # re-aim the stream at the new Mac
            self.aa.turn_off()
            try:
                self.aa.turn_on()
            except Exception as e:
                self.mac_status.set_text(f"Couldn't switch: {e}")
                self.aa.turn_off()
        self.app.refresh()
        self._host_dirty()
        self.refresh()

    def on_phone(self, sw, _):
        if not self._quiet:
            self.app.watcher.set_enabled(sw.get_active())
            self.app.refresh()
            self.refresh()

    def on_dup(self, sw, _):
        if not self._quiet:
            self.app.watcher.set_dup(sw.get_active())

    def on_awake(self, sw, _):
        if not self._quiet:
            self.aa.set_config("KEEP_AWAKE", "1" if sw.get_active() else "0")

    def on_buffer(self, combo):
        if not self._quiet and combo.get_active_id():
            self.aa.set_config("AUDIO_BUFFER", combo.get_active_id())
            self.app.watcher.restart_all()

    def on_auto(self, sw, _):
        if self._quiet:
            return
        if sw.get_active():
            self.aa.del_config("AV_DELAY_MS")
        else:
            self.aa.set_config("AV_DELAY_MS", str(int(self.delay.get_value())))
        self.aa.set_av_delay(self.aa.av_delay_ms())
        self.refresh()

    def on_delay(self, scale):
        if self._quiet or self.auto.get_active():
            return
        self.delay_row.sub_lab.set_text(f"Picture held back by {scale.get_value() / 1000:.2f} "
                                        "seconds")
        if self._delay_timer:
            GLib.source_remove(self._delay_timer)
        self._delay_timer = GLib.timeout_add(300, self._save_delay)

    def _save_delay(self):
        self._delay_timer = None
        ms = int(self.delay.get_value())
        self.aa.set_config("AV_DELAY_MS", str(ms))
        self.aa.set_av_delay(ms)
        return False

    # Open at login = the autostart entry the installer writes.
    @staticmethod
    def _login_enabled():
        try:
            with open(AUTOSTART) as f:
                text = f.read()
        except FileNotFoundError:
            return False
        return "X-GNOME-Autostart-enabled=false" not in text and "Hidden=true" not in text

    def on_login(self, sw, _):
        if self._quiet:
            return
        try:
            with open(AUTOSTART) as f:
                lines = [l for l in f.read().splitlines()
                         if not l.startswith(("X-GNOME-Autostart-enabled=", "Hidden="))]
        except FileNotFoundError:
            lines = ["[Desktop Entry]", "Type=Application", "Name=Audio Abduction+",
                     f"Exec={os.path.expanduser('~/.local/bin/audio-abduction')}",
                     f"Icon={self.aa.ICON_ON}"]
        lines.append(f"X-GNOME-Autostart-enabled={'true' if sw.get_active() else 'false'}")
        os.makedirs(os.path.dirname(AUTOSTART), exist_ok=True)
        with open(AUTOSTART, "w") as f:
            f.write("\n".join(lines) + "\n")
