# Handover: Audio Abduction+ phone and tablet audio

Written 2026-11-25. For Shane and any agent that picks this up.

## Where the code is

- **Repo:** https://github.com/dshanehill/audio-abduction-plus
- **Branch:** `phone-tablet-audio`, committed in the original Claude session's workspace at `/home/claude/audio-abduction-plus`. It is **not on GitHub yet**: this session's push got a 403 because Claude doesn't have GitHub access to this repo. The fix is to reconnect GitHub at https://claude.ai/customize/connectors?auth_start=github&auth_start_force=1, or install the Claude GitHub App at https://github.com/apps/claude/installations/select_target.
- **Backup copy:** `phone-tablet-audio.patch` was sent to Shane in the chat. To apply it to a fresh clone of `main`:
  ```bash
  git clone https://github.com/dshanehill/audio-abduction-plus.git
  cd audio-abduction-plus
  git checkout -b phone-tablet-audio
  git am /path/to/phone-tablet-audio.patch
  git push -u origin phone-tablet-audio
  ```
- **First job for the next agent:** push this branch to GitHub. Shane wants code changes pushed right away.

## What was built

When you plug an Android phone or tablet into the **Linux Mint PC** by USB, its audio plays on the Linux PC, so while beaming is on it reaches the Mac. The Mac side is unchanged.

Shane's devices: a **Realme C85** phone and a **Samsung tablet**, both with USB debugging on. He'll unlock them before plugging in.

### Files changed
- `linux-mint/audio-abduction.py`: adds a `DeviceWatcher` class running on a background thread.
  - Every 2 s it runs `adb devices` (USB only; Wi-Fi adb is ignored).
  - For each new device it reads `getprop` for the name and Android version (needs SDK 30+), then starts:
    `scrcpy -s SERIAL --no-video --no-window --require-audio --audio-codec=raw --no-power-on [--audio-dup]`
  - scrcpy plays into the default PipeWire output. `_route()` moves scrcpy's streams onto the current default sink in case PipeWire remembered an old output.
  - On unplug it stops that device's scrcpy. If a start fails 3 times within 10 s it gives up and notifies; it also retries without `--audio-dup`.
  - Notifications cover: tap Allow (unauthorized), connected, unplugged, failed, and Android too old.
  - scrcpy is stopped if the tray app dies (PR_SET_PDEATHSIG), and also on quit, SIGTERM or SIGINT.
  - Two new menu options are saved in `~/.config/mac-audio/config`: **Phone and tablet audio** (`PHONE_AUDIO`, default on) and **Also play on the phone or tablet** (`AUDIO_DUP`, default off, Android 13+). A label in the menu lists the connected devices.
  - scrcpy logs go to `~/.cache/mac-audio/scrcpy-SERIAL.log`.
- `linux-mint/install.sh`: installs `android-sdk-platform-tools-common` (USB udev rules) and `curl`. It downloads the static **scrcpy 3.3.4** into `~/.local/share/audio-abduction/scrcpy/`, checks it against SHA-256 `0305d98c06178c67e12427bbf340c436d0d58c9e2a39bf9ffbbf8f54d7ef95a5`, and uses scrcpy's bundled adb. Mint's apt scrcpy is too old for audio. It now keeps existing config settings and only updates `MAC_HOST`.
- `README.md`: adds a "Phone and tablet audio" section.

## Status
- Parsers and the start/stop/retry logic were tested in the cloud with fake `adb` and `scrcpy`, and all of it passed.
- **Tested on the Linux Mint PC on 2026-11-25** (over SSH as `david@100.104.209.20`) with the Samsung tablet (SM-T738U, Android 14):
  - The installer's scrcpy download and checksum passed; adb is bundled.
  - Tablet audio played into the Mac beaming output, moved to the PC speakers when beaming was turned off, and moved back when it was turned on.
  - "Also play on the phone or tablet" ran scrcpy with `--audio-dup`; audio reached the PC and kept playing on the tablet.
  - A 4 s tone at 50 ms and 20 ms buffers had no dropouts. Default is now 30 ms (`AUDIO_BUFFER` in the config).
  - The tablet worked without `android-sdk-platform-tools-common`, but the **Realme C85 (RMX5566, Android 16) needs it**: without its udev rules the phone's USB node is root-only and adb can't see it. Shane installed it on 2026-11-25.
  - Realme audio reached the PC and the Mac. Its media volume was 0, which makes the capture silent too; set to 10/16.
  - Both devices streamed at the same time. After an adb server restart, both came back and the app restarted their audio automatically.
  - Both devices are set to "Always allow" for this PC.
  - New: when a device connects, the app turns on Android's "Stay awake" while charging if it is off (`KEEP_AWAKE=0` in the config disables this).
- **Not tested on hardware:** physically unplugging a device (covered only by the fake-adb tests).

## Next steps
1. Push the branch to GitHub.
2. On the Linux Mint PC, pull the branch and run `linux-mint/install.sh`. Shane wants Claude to do the hands-on steps itself; don't ask him to click through screens.
3. Plug in the Realme, then the Samsung tablet. Check that audio reaches the Mac with beaming on, and that it plays on the Linux PC with beaming off. Check unplugging, both devices playing at once, and the "Also play on device" option.
4. Check the static scrcpy tarball. It's assumed to contain `scrcpy` and `adb` at the top level once `--strip-components=1` is applied. If adb isn't bundled, use the system `adb` (the code already falls back to PATH).
5. Try lowering delay with `--audio-buffer=20` or `30` (scrcpy's default is 50 ms). Check for crackling.
6. ~~Merge into `main` and push.~~ Done 2026-11-25.

## Decisions and scope
- **Target machine: the Linux Mint PC.** Shane said not to concern ourselves with the Zorin machine.
- **No internet over USB** (reverse tethering). Shane ruled it out.
- Known limits: Android 11+ only; phone calls can't be captured; some apps block capture; the device goes quiet unless "Also play" is on.

## Video in step with the sound (added 2026-11-25)
Shane asked that sound is never delayed; instead video waits for it.
- **Linux PC:** beaming now goes through a `snd-aloop` virtual sound card (kernel module loaded at boot via `/etc/modules-load.d/audio-abduction-aloop.conf`). Its port latency offset tells players the real delay, so they hold video back. A null sink can't carry an offset on PipeWire 1.0.5 (ProcessLatency, Props latencyOffsetNsec and a pw-loopback were all tried and ignored).
- **Mac receiver** reports its output delay (CoreAudio latency + safety offset + buffer + stream latency, +15 ms for itself) to the sender on UDP 46001 every second, and reopens the player when the Mac's default output changes. Soundcore Life Q20 over Bluetooth reports 240 ms.
- Offset = Mac delay + 35 ms (Linux side + network) − 50 ms (the virtual card's own buffer, which players already count but the RTP monitor isn't delayed by). Headphones → 225 ms offset; it tracks output changes within about a second. `AV_DELAY_MS` in the config overrides the total.
- Checked: players see the extra delay (a PulseAudio client's reported latency rose by the offset); phone and tablet audio flow through the card. **Not checked by eye** with a real video.
- **Android:** no way without root to make apps delay their video; documented the VLC per-video workaround.
