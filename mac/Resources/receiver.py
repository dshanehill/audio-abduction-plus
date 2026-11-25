#!/usr/bin/env python3
"""Audio Abduction+ (Mac side): plays RTP audio (L16, 48 kHz stereo) sent by the Mint toggle, with minimal buffering.

Listens on UDP 46000, strips the RTP header and pipes raw PCM to sox's `play`, which
outputs to the Mac's current default device (speakers or headphones).
Late packets are dropped rather than queued, so delay never builds up.
"""
import os
import socket
import subprocess
import sys
import time

PORT = int(os.environ.get("MAC_AUDIO_PORT", "46000"))
RATE, CHANNELS = 48000, 2
PLAY = "/opt/homebrew/bin/play"
IDLE_RESTART = 1.0  # seconds of no packets -> close the player so it re-opens fresh


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
    while True:
        try:
            pkt = sock.recv(4096)
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
