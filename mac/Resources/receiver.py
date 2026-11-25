#!/usr/bin/env python3
"""Audio Abduction+ (Mac side): plays RTP audio (L16, 48 kHz stereo) sent by the Mint toggle, with minimal buffering.

Listens on UDP 46000, strips the RTP header and pipes raw PCM to sox's `play`, which
outputs to the Mac's current default device (speakers or headphones).
Late packets are dropped rather than queued, so delay never builds up.

Every 2 s while audio is arriving, it tells the sender how long the Mac's current output
(speakers, Bluetooth headphones...) takes to play sound, so video players on the Linux PC
can hold the picture back by the same amount and stay in step with the sound.
"""
import ctypes
import os
import socket
import subprocess
import sys
import time

PORT = int(os.environ.get("MAC_AUDIO_PORT", "46000"))
RATE, CHANNELS = 48000, 2
PLAY = "/opt/homebrew/bin/play"
IDLE_RESTART = 1.0  # seconds of no packets -> close the player so it re-opens fresh
REPORT_PORT = PORT + 1  # where the Linux PC listens for our delay reports
REPORT_EVERY = 1.0
PLAYER_MS = 15  # this receiver's own buffering (sox chunk + pipe), roughly


def _fourcc(s):
    return int.from_bytes(s.encode(), "big")


class _Addr(ctypes.Structure):
    _fields_ = [("selector", ctypes.c_uint32), ("scope", ctypes.c_uint32),
                ("element", ctypes.c_uint32)]


try:
    _ca = ctypes.CDLL("/System/Library/Frameworks/CoreAudio.framework/CoreAudio")
except OSError:
    _ca = None


def _get(obj, sel, scope, ctype):
    val, size = ctype(), ctypes.c_uint32(ctypes.sizeof(ctype))
    addr = _Addr(_fourcc(sel), _fourcc(scope), 0)
    err = _ca.AudioObjectGetPropertyData(obj, ctypes.byref(addr), 0, None,
                                         ctypes.byref(size), ctypes.byref(val))
    return None if err else val.value


def default_output():
    return _get(1, "dOut", "glob", ctypes.c_uint32) if _ca else None


def output_delay_ms():
    """How long the Mac's current default output takes to play a sound, in ms."""
    if _ca is None:
        return None
    dev = _get(1, "dOut", "glob", ctypes.c_uint32)  # 1 = the system object
    if not dev:
        return None
    rate = _get(dev, "nsrt", "glob", ctypes.c_double) or 48000.0
    frames = sum(_get(dev, sel, scope, ctypes.c_uint32) or 0 for sel, scope in
                 (("ltnc", "outp"), ("saft", "outp"), ("fsiz", "glob")))
    stream = _get(dev, "stm#", "outp", ctypes.c_uint32)  # first output stream
    if stream:
        frames += _get(stream, "ltnc", "glob", ctypes.c_uint32) or 0
    return round(frames / rate * 1000) + PLAYER_MS


def start_player():
    # --buffer is bytes per sox I/O chunk; small = low latency.
    return subprocess.Popen(
        [PLAY, "-q", "--buffer", "1024", "-t", "raw", "-e", "signed-integer",
         "-b", "16", "-B", "-r", str(RATE), "-c", str(CHANNELS), "-"],
        stdin=subprocess.PIPE, bufsize=0)


def payload(pkt):
    if len(pkt) < 12 or pkt[0] >> 6 != 2:
        return None
    off = 12 + 4 * (pkt[0] & 0x0F)
    if pkt[0] & 0x10:  # header extension
        off += 4 + 4 * int.from_bytes(pkt[off + 2:off + 4], "big")
    data = pkt[off:]
    if pkt[0] & 0x20 and data:  # padding
        data = data[:-data[-1]]
    return data


def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", PORT))
    sock.settimeout(IDLE_RESTART)
    player = None
    last_seq = None
    last_report = 0.0
    out_dev = default_output()
    while True:
        try:
            pkt, sender = sock.recvfrom(4096)
        except socket.timeout:
            if player:  # stream stopped: release the audio device
                player.stdin.close()
                player.wait()
                player = None
                last_seq = None
            continue
        data = payload(pkt)
        if not data:
            continue
        seq = int.from_bytes(pkt[2:4], "big")
        if last_seq is not None and ((seq - last_seq) & 0xFFFF) > 0x8000:
            continue  # out-of-order/late packet: drop it
        last_seq = seq
        now = time.monotonic()
        if now - last_report > REPORT_EVERY:
            last_report = now
            dev = default_output()
            if dev != out_dev:  # you switched outputs (jack, USB, Bluetooth...)
                out_dev = dev
                if player:  # reopen on the new output so sound and delay both follow
                    player.stdin.close()
                    player.wait()
                    player = None
            ms = output_delay_ms()
            if ms is not None:
                try:
                    sock.sendto(f"AALAT {ms}".encode(), (sender[0], REPORT_PORT))
                except OSError:
                    pass
        if player is None or player.poll() is not None:
            player = start_player()
        try:
            player.stdin.write(data)
        except BrokenPipeError:
            player = None


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
