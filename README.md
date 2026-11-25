<p align="center"><img src="icon.png" alt="Audio Abduction+ icon: a grey alien wearing headphones, standing in a beam of light from above" width="200"></p>

# Audio Abduction+: Hear Your Linux PC Through Your Mac

*One click on the little alien in your Linux Mint panel, and every sound from the Linux PC is beamed over to your Mac and plays through the Mac's speakers or headphones.*

---

## A companion to Mouse Jumper+

Audio Abduction+ is a companion app to **[Mouse Jumper+](https://github.com/dshanehill/mouse-jumper-plus)**, which lets a Mac and a Linux Mint PC share one keyboard and mouse.

Mouse Jumper+ moves your keyboard and mouse between the two computers. Audio Abduction+ does the same for sound: it forwards the audio from the Linux machine to the Mac. Together they let you sit at the Mac and use both computers without moving your hands or your headphones.

You don't need Mouse Jumper+ to use Audio Abduction+, but they were built to work side by side.

## Why send Linux audio to the Mac?

**Your headphones stay on the Mac.** If you wear Bluetooth headphones with your Mac, you don't have to pair them with the Linux PC too, or keep switching them back and forth between computers.

**You skip Linux Bluetooth trouble.** Bluetooth audio on Linux is well known for being unreliable: headphones that won't reconnect, drop out, stutter, or get stuck in low-quality "headset" mode. Audio Abduction+ avoids all of that. The Linux PC sends its sound over your network, and the Mac, whose Bluetooth audio just works, plays it.

**One set of controls.** The Mac's volume keys and output choice (speakers, headphones, AirPods) cover both computers. Whatever the Mac is playing through, the Linux audio plays through too.

## How it works

| | Linux Mint PC | Mac |
|---|---|---|
| **What runs** | A tray icon (the alien) in the panel | A small background receiver that starts at login |
| **What it does** | Creates a virtual "Audio-Abduction+" speaker, makes it the default output, and streams it over the network | Listens for the stream and plays it on the Mac's current output |

- **Click the alien** to beam audio to the Mac. Click it again to bring audio back to the Linux PC's own speakers. Right-click for a menu.
- When you switch it on, any audio that's already playing moves over straight away. When you switch it off, your previous output is restored.
- The receiver is tuned for low delay: late network packets are dropped instead of queued, so lag never builds up. When the stream stops, the Mac releases the audio device.
- You can also toggle it from a keyboard shortcut by running `audio-abduction --toggle`.

## Phone and tablet audio

Plug an Android phone or tablet into the Linux PC with a USB cable and its sound plays on the Linux PC. While beaming is on, that means it reaches your Mac along with the Linux PC's own audio. Plug in more than one device and you hear them all together.

- The device needs **Android 11 or newer** with **USB debugging** turned on. The first time you plug it in, unlock it and tap **Allow** when it asks whether to trust this computer.
- You get a notification when a device connects or unplugs. Its audio stops when you unplug it.
- By default, the sound moves off the device, so its own speaker goes quiet. To keep it playing on the device as well, turn on **Also play on the phone or tablet** in the alien's right-click menu (Android 13 or newer).
- To turn the feature off, untick **Phone and tablet audio** in the same menu.
- While a device is plugged in, its screen won't time out: if Android's **Stay awake** (while charging) setting is off, Audio Abduction+ turns it on. To leave your devices' settings alone, add `KEEP_AWAKE=0` to `~/.config/mac-audio/config`.
- Keep the device's media volume above zero: Android sends the audio at the device's own volume level.
- Phone calls can't be captured because Android doesn't allow it. A few apps also block audio capture.

This uses [scrcpy](https://github.com/Genymobile/scrcpy) in audio-only mode (no window, no screen mirroring), sending uncompressed audio over USB for low delay. The installer downloads the official scrcpy build and checks it against its published checksum. If a device's audio won't start, the notification names a log file in `~/.cache/mac-audio/`.

## Under the hood

Under the hood, the Linux side uses PipeWire's PulseAudio modules (`module-null-sink` and `module-rtp-send`) to send uncompressed 48 kHz stereo audio over RTP to UDP port 46000. The Mac side uses [SoX](https://sox.sourceforge.net) to play it.

## What you need

- A Mac with [Homebrew](https://brew.sh) (the installer adds SoX)
- A PC running Linux Mint 22 or later (Cinnamon) with PipeWire. Other desktops get a basic tray icon.
- Both computers on the same network, or connected through [Tailscale](https://tailscale.com)

## Install

### 1. On the Mac

```bash
git clone https://github.com/dshanehill/audio-abduction-plus.git
cd audio-abduction-plus/mac
./install.sh
```

This builds **Audio Abduction+.app** in `~/Applications` and starts it at login. If macOS asks whether Python may accept incoming network connections, click **Allow**.

### 2. On the Linux Mint PC

```bash
git clone https://github.com/dshanehill/audio-abduction-plus.git
cd audio-abduction-plus/linux-mint
./install.sh
```

When asked, type your Mac's hostname (for example `my-mac.local`) or its IP address, such as its Tailscale address. The alien appears in your panel and starts automatically at login.

## Troubleshooting

- **No sound on the Mac:** check that the receiver is running with `launchctl list | grep audio-abduction` and look at `/tmp/audio-abduction.log`. Make sure nothing (such as a firewall) is blocking UDP port 46000.
- **Wrong Mac address:** edit `~/.config/mac-audio/config` on the Linux PC and change the `MAC_HOST=` line.
- **"Couldn't switch" message:** the notification includes the reason. Audio stays on the Linux PC until it's fixed.

## Uninstall

**Mac:**

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/local.audio-abduction.plus.plist; rm -rf ~/Library/LaunchAgents/local.audio-abduction.plus.plist "$HOME/Applications/Audio Abduction+.app"
```

**Linux Mint:**

```bash
pkill -f bin/audio-abduction; rm -rf ~/.local/bin/audio-abduction ~/.config/autostart/audio-abduction.desktop ~/.local/share/applications/audio-abduction.desktop ~/.local/share/audio-abduction ~/.config/mac-audio ~/.cache/mac-audio
```

## Security note

The audio stream is not encrypted. On a home network that's usually fine. If you're on a shared network, connect the two computers through Tailscale, which encrypts the traffic.

## License

Audio Abduction+ is free and open source under the [MIT License](LICENSE).
