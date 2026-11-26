// Audio Abduction+ — Mac app shell.
// Shows a Dock icon and a menu bar icon, has a Settings window, and runs receiver.py
// (the part that actually plays the PC's audio) with whatever settings you choose.
//
// Forward to Linux / Forward to Mac: which way sound goes, shared with the Linux PC.
//   "mac"   : the PC's sound plays on this Mac (receiver.py)
//   "linux" : this Mac's sound plays on the PC (Forwarder: a system audio tap, sent as RTP)
//   "off"   : each computer plays its own sound
// Both computers send "AAMODE <mode> <time chosen>" to each other on UDP 46002 every 2 s
// and straight away after a click; the most recent choice wins.
import AppKit
import AudioToolbox
import CoreAudio
import SwiftUI

let bundleID = "local.audio-abduction.plus"
let agentPlist = NSHomeDirectory() + "/Library/LaunchAgents/\(bundleID).plist"
let logPath = "/tmp/audio-abduction.log"

enum Key {
    static let port = "port", volume = "volume", buffer = "buffer"
    static let showDock = "showDock", showMenuBar = "showMenuBar"
    static let mode = "mode", modeStamp = "modeStamp", linuxHost = "linuxHost"
}

let defaults = UserDefaults.standard
func registerDefaults() {
    defaults.register(defaults: [Key.port: 46000, Key.volume: 100.0, Key.mode: "mac",
                                 Key.modeStamp: 0.0, Key.buffer: 1024, Key.showDock: true,
                                 Key.showMenuBar: true])
}

let modes = ["mac", "linux", "off"]
let controlPort: UInt16 = 46002
var currentMode: String { defaults.string(forKey: Key.mode) ?? "mac" }
/// Where the Forward button sends sound next, from this Mac's point of view.
func forwardTarget(_ mode: String) -> String { mode == "linux" ? "mac" : "linux" }
func forwardLabel(_ mode: String) -> String { forwardTarget(mode) == "linux" ? "Forward to Linux" : "Forward to Mac" }

// MARK: - Live status shown in the window and menu

final class Status: ObservableObject {
    @Published var state = "Starting…"
    @Published var streaming = false
    @Published var sender = ""
    @Published var delayMs: Int? = nil
    @Published var outputName = "—"
    @Published var problem: String? = nil
    @Published var peerLast: Date? = nil        // when the PC last checked in
    @Published var forwarding = false           // this Mac's sound is being sent to the PC
    @Published var forwardProblem: String? = nil
    var peerOK: Bool { peerLast.map { Date().timeIntervalSince($0) < 6 } ?? false }
}

func globalAddr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

func defaultOutputDevice() -> AudioDeviceID {
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = globalAddr(kAudioHardwarePropertyDefaultOutputDevice)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr
    else { return 0 }
    return dev
}

func deviceString(_ dev: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String? {
    guard dev != 0 else { return nil }
    var addr = globalAddr(sel)
    var value: Unmanaged<CFString>? = nil
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr, let v = value
    else { return nil }
    return v.takeRetainedValue() as String
}

func defaultOutputName() -> String { deviceString(defaultOutputDevice(), kAudioObjectPropertyName) ?? "—" }

func sockaddrFor(_ ip: String, _ port: UInt16) -> sockaddr_in? {
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian
    return inet_pton(AF_INET, ip, &a.sin_addr) == 1 ? a : nil
}

// MARK: - Talks to the PC about which way sound goes (UDP 46002)

final class Control {
    private let fd: Int32
    private var source: DispatchSourceRead?
    var onMessage: ((String, Double, String) -> Void)?  // mode, time chosen, PC's address

    init?() {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = controlPort.bigEndian
        a.sin_addr.s_addr = INADDR_ANY
        let r = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard r == 0 else { close(fd); return nil }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.read() }
        src.resume()
        source = src
    }

    private func read() {
        var buf = [UInt8](repeating: 0, count: 256)
        var from = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
        }
        guard n > 0 else { return }
        let parts = String(decoding: buf[0..<n], as: UTF8.self).split(separator: " ").map(String.init)
        guard parts.count == 3, parts[0] == "AAMODE", modes.contains(parts[1]), let stamp = Double(parts[2])
        else { return }
        var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &from.sin_addr, &ip, socklen_t(INET_ADDRSTRLEN))
        onMessage?(parts[1], stamp, String(cString: ip))
    }

    func send(_ mode: String, _ stamp: Double, to ip: String) {
        guard var a = sockaddrFor(ip, controlPort) else { return }
        let msg = Array("AAMODE \(mode) \(String(format: "%.3f", stamp))".utf8)
        _ = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, msg, msg.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

// MARK: - Sends this Mac's sound to the PC ("Forward to Linux")

/// Taps everything the Mac plays (muting it here), turns it into 16-bit stereo RTP,
/// and sends it to the PC's UDP 46000. The PC plays it with pacat.
final class Forwarder {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var agg = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var fd: Int32 = -1
    private var dest = sockaddr_in()
    private var seq = UInt16.random(in: 0...UInt16.max)
    private var ts = UInt32.random(in: 0...UInt32.max)
    private let ssrc = UInt32.random(in: 0...UInt32.max)
    private var payloadType: UInt8 = 96
    private var pending = [UInt8]()
    private static let framesPerPacket = 240  // 5 ms at 48 kHz: fits easily in one packet
    private(set) var host = ""
    private(set) var device: AudioDeviceID = 0
    var running: Bool { ioProc != nil }

    /// Returns nil when it started, or a plain-language reason when it couldn't.
    func start(to host: String, port: UInt16) -> String? {
        stop()
        guard let d = sockaddrFor(host, port) else { return "Your PC's address isn't known yet." }
        dest = d
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return "Couldn't open a network connection." }

        // Everything the Mac plays except this app, muted here while it's being forwarded.
        var me = AudioObjectID(kAudioObjectUnknown)
        var pid = getpid()
        var addr = globalAddr(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                   UInt32(MemoryLayout<pid_t>.size), &pid, &size, &me)
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: me == kAudioObjectUnknown ? [] : [me])
        desc.name = "Audio Abduction+"
        desc.isPrivate = true
        desc.muteBehavior = .muted
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else {
            stop(); return "macOS didn't allow capturing this Mac's sound."
        }

        var fmt = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        addr = globalAddr(kAudioTapPropertyFormat)
        guard AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &fmt) == noErr,
              fmt.mFormatID == kAudioFormatLinearPCM, fmt.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              fmt.mBitsPerChannel == 32
        else { stop(); return "This Mac's sound is in a format that can't be sent." }
        switch Int(fmt.mSampleRate) {
        case 44100: payloadType = 10
        case 96000: payloadType = 97
        case 88200: payloadType = 98
        default: payloadType = 96  // 48 kHz
        }

        device = defaultOutputDevice()
        guard let outUID = deviceString(device, kAudioDevicePropertyDeviceUID) else {
            stop(); return "Couldn't find this Mac's sound output."
        }
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Audio Abduction+ Forward",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg) == noErr else {
            stop(); return "Couldn't set up sound capture."
        }

        pending.removeAll(keepingCapacity: true)
        var procID: AudioDeviceIOProcID?
        let err = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil) { [unowned self] _, input, _, _, _ in
            self.send(input)
        }
        guard err == noErr, let p = procID else { stop(); return "Couldn't set up sound capture." }
        ioProc = p
        guard AudioDeviceStart(agg, p) == noErr else { stop(); return "Couldn't start sound capture." }
        self.host = host
        return nil
    }

    func stop() {
        if let p = ioProc {
            AudioDeviceStop(agg, p)
            AudioDeviceDestroyIOProcID(agg, p)
            ioProc = nil
        }
        if agg != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(agg); agg = AudioObjectID(kAudioObjectUnknown) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap); tap = AudioObjectID(kAudioObjectUnknown) }
        if fd >= 0 { close(fd); fd = -1 }
        host = ""
    }

    /// Runs on Core Audio's thread: float samples in, 16-bit big-endian RTP packets out.
    private func send(_ input: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = abl.first, first.mNumberChannels > 0, let base = first.mData else { return }
        let interleaved = abl.count == 1
        let chans = Int(first.mNumberChannels)
        let frames = Int(first.mDataByteSize) / (4 * chans)
        let left = base.assumingMemoryBound(to: Float.self)
        let right: UnsafeMutablePointer<Float>? = interleaved ? nil
            : abl.count > 1 ? abl[1].mData?.assumingMemoryBound(to: Float.self) : nil
        func pcm(_ x: Float) -> Int16 { Int16(max(-1, min(1, x)) * 32767) }
        for i in 0..<frames {
            let l: Float, r: Float
            if interleaved {
                l = left[i * chans]; r = chans > 1 ? left[i * chans + 1] : l
            } else {
                l = left[i]; r = right?[i] ?? l
            }
            let ul = UInt16(bitPattern: pcm(l)), ur = UInt16(bitPattern: pcm(r))
            pending.append(UInt8(ul >> 8)); pending.append(UInt8(ul & 0xFF))
            pending.append(UInt8(ur >> 8)); pending.append(UInt8(ur & 0xFF))
        }
        let bytes = Forwarder.framesPerPacket * 4
        while pending.count >= bytes {
            var pkt: [UInt8] = [0x80, payloadType, UInt8(seq >> 8), UInt8(seq & 0xFF),
                                UInt8(ts >> 24), UInt8((ts >> 16) & 0xFF), UInt8((ts >> 8) & 0xFF), UInt8(ts & 0xFF),
                                UInt8(ssrc >> 24), UInt8((ssrc >> 16) & 0xFF), UInt8((ssrc >> 8) & 0xFF), UInt8(ssrc & 0xFF)]
            pkt.append(contentsOf: pending[0..<bytes])
            pending.removeFirst(bytes)
            _ = withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, pkt, pkt.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            seq &+= 1
            ts &+= UInt32(Forwarder.framesPerPacket)
        }
    }
}

// MARK: - Runs receiver.py

final class Receiver {
    let status: Status
    private var proc: Process?
    private var stopping = false
    private var buffer = Data()
    private var restartWork: DispatchWorkItem?

    init(status: Status) { self.status = status }

    var script: String { Bundle.main.resourcePath! + "/receiver.py" }

    func apply() {  // (re)start with current settings
        stop()
        start()
    }

    private func start() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script]
        var env = ProcessInfo.processInfo.environment
        env["MAC_AUDIO_PORT"] = String(defaults.integer(forKey: Key.port))
        env["AA_VOLUME"] = String(format: "%.3f", defaults.double(forKey: Key.volume) / 100)
        env["AA_BUFFER"] = String(defaults.integer(forKey: Key.buffer))
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        if let log = FileHandle(forWritingAtPath: logPath) ?? {
            FileManager.default.createFile(atPath: logPath, contents: nil)
            return FileHandle(forWritingAtPath: logPath)
        }() {
            log.seekToEndOfFile()
            p.standardError = log
        }
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(d) }
        }
        p.terminationHandler = { [weak self] t in
            DispatchQueue.main.async { self?.died(t) }
        }
        stopping = false
        do {
            try p.run()
            proc = p
            status.state = "Starting…"; status.problem = nil
        } catch {
            status.state = "Couldn't start"
            status.problem = "Couldn't run python3: \(error.localizedDescription)"
        }
    }

    func stop() {
        restartWork?.cancel()
        guard let p = proc else { return }
        stopping = true
        proc = nil
        if p.isRunning {
            p.terminate()
            p.waitUntilExit()
        }
        status.streaming = false
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            let parts = line.split(separator: " ").map(String.init)
            guard parts.first == "STATUS", parts.count >= 2 else { continue }
            status.problem = nil
            switch parts[1] {
            case "listening":
                status.state = "Ready — waiting for your PC"
                status.streaming = false
            case "streaming":
                status.streaming = true
                status.sender = parts.count > 2 ? parts[2] : ""
                let ms = parts.count > 3 ? Int(parts[3]) ?? -1 : -1
                status.delayMs = ms >= 0 ? ms : nil
                status.state = "Playing sound from your PC"
            default: break
            }
        }
    }

    private func died(_ t: Process) {
        guard t === proc || proc == nil else { return }
        if stopping { return }
        proc = nil
        status.streaming = false
        status.state = "Reconnecting…"
        status.problem = "exit \(t.terminationStatus)"
        let w = DispatchWorkItem { [weak self] in self?.start() }
        restartWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }
}

// MARK: - Start at login (the LaunchAgent)

enum LoginItem {
    static var isOn: Bool { FileManager.default.fileExists(atPath: agentPlist) }

    static func set(_ on: Bool) {
        if on {
            let exe = Bundle.main.executablePath!
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>Label</key><string>\(bundleID)</string>
              <key>ProgramArguments</key><array><string>\(exe)</string></array>
              <key>AssociatedBundleIdentifiers</key><array><string>\(bundleID)</string></array>
              <key>RunAtLoad</key><true/>
              <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
              <key>ProcessType</key><string>Interactive</string>
              <key>StandardErrorPath</key><string>\(logPath)</string>
            </dict></plist>
            """
            try? FileManager.default.createDirectory(atPath: (agentPlist as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            try? plist.write(toFile: agentPlist, atomically: true, encoding: .utf8)
        } else {
            // Removing the file stops it starting at next login without quitting the running app.
            try? FileManager.default.removeItem(atPath: agentPlist)
        }
    }
}

// MARK: - Settings window (laid out like a System Settings pane)

struct SettingsView: View {
    @ObservedObject var status: Status
    @AppStorage(Key.mode) var mode = "mac"
    @AppStorage(Key.volume) var volume = 100.0
    @AppStorage(Key.buffer) var buffer = 1024
    @AppStorage(Key.showDock) var showDock = true
    @AppStorage(Key.showMenuBar) var showMenuBar = true
    @State var startAtLogin = LoginItem.isOn

    var dotColor: Color {
        switch mode {
        case "off": return .secondary
        case "linux": return status.forwardProblem != nil ? .red : status.forwarding && status.peerOK ? .green : .orange
        default: return status.problem != nil ? .red : status.streaming ? .green : .orange
        }
    }
    var headline: String {
        switch mode {
        case "off": return "Not forwarding"
        case "linux":
            if status.forwardProblem != nil { return "Can't send this Mac's sound" }
            return status.forwarding && status.peerOK ? "Sending this Mac's sound to your PC" : "Waiting for your PC"
        default:
            if status.problem != nil { return "Something went wrong" }
            return status.streaming ? "Playing sound from your PC" : "Ready for your PC's sound"
        }
    }
    var detail: String {
        switch mode {
        case "off": return "Each computer plays its own sound."
        case "linux":
            if let p = status.forwardProblem { return p }
            return status.peerOK
                ? "Everything this Mac plays comes out of your PC. If the PC hears nothing, allow Audio Abduction+ in System Settings › Privacy & Security › Screen & System Audio Recording."
                : "Your PC isn't answering. Make sure Audio Abduction+ is running on the PC."
        default:
            if status.problem != nil { return "Audio Abduction+ is trying again. If this keeps happening, click Restart." }
            return status.streaming ? "Sound is coming out of \(status.outputName)."
                                    : "Waiting for your PC. Start Audio Abduction on the PC to hear it here."
        }
    }
    var whereText: String {
        switch mode {
        case "linux": return "Your PC. This Mac's sound comes out of the PC's speakers."
        case "off": return "Each computer plays its own sound."
        default: return "This Mac. Sound from your PC plays through this Mac."
        }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Circle().fill(dotColor).frame(width: 8, height: 8)
                            Text(headline).font(.title3.weight(.semibold))
                        }
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }

            Section {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sound Goes To")
                        Text(whereText).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if mode != "off" {
                        Button("Stop") { NotificationCenter.default.post(name: .setMode, object: "off") }
                    }
                    Button(forwardLabel(mode)) {
                        NotificationCenter.default.post(name: .setMode, object: forwardTarget(mode))
                    }
                    .buttonStyle(.borderedProminent)
                }
            } footer: {
                Text("Forward to Linux plays this Mac's sound on your PC. Forward to Mac plays your PC's sound on this Mac. Clicking either one, here or on the PC, switches both computers.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Volume") {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $volume, in: 10...100)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 240)
                }
                LabeledContent("Output", value: status.outputName)
                Picker(selection: $buffer) {
                    Text("Fastest").tag(512)
                    Text("Balanced").tag(1024)
                    Text("Most Reliable").tag(4096)
                } label: {
                    Text("Connection")
                    Text("Choose Most Reliable if the sound skips or cuts out.")
                }
            } header: {
                Text("Sound")
            } footer: {
                Text("To change where sound plays, choose a speaker or headphones in Control Center or Sound settings.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Open at Login", isOn: $startAtLogin)
                    .onChange(of: startAtLogin) { _, on in LoginItem.set(on) }
                Toggle("Show in Menu Bar", isOn: $showMenuBar)
                    .disabled(!showDock)
                Toggle("Show in Dock", isOn: $showDock)
                    .disabled(!showMenuBar)
            }

            Section {
                HStack {
                    Text("Having trouble?")
                    Spacer()
                    Button("Show Log") { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }
                    Button("Restart") { NotificationCenter.default.post(name: .restartReceiver, object: nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension Notification.Name {
    static let restartReceiver = Notification.Name("restartReceiver")
    static let setMode = Notification.Name("setMode")
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let status = Status()
    lazy var receiver = Receiver(status: status)
    let forwarder = Forwarder()
    var control: Control?
    var beat = 0
    var statusItem: NSStatusItem?
    var window: NSWindow?
    var lastConfig = ""
    var applyWork: DispatchWorkItem?
    var observers: [Any] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        registerDefaults()
        // Only one copy at a time (e.g. login item already running and you open it from Finder).
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != getpid() }
        if let other = others.first {
            other.activate()
            DistributedNotificationCenter.default().postNotificationName(.init("\(bundleID).show"), object: nil,
                                                                          deliverImmediately: true)
            exit(0)
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("\(bundleID).show"), object: nil,
                                                            queue: .main) { [weak self] _ in self?.showSettings() }
        buildMainMenu()
        applyAppearance()
        lastConfig = config()
        receiver.apply()
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.settingsChanged()
        })
        observers.append(NotificationCenter.default.addObserver(forName: .restartReceiver, object: nil,
                                                                queue: .main) { [weak self] _ in
            self?.receiver.apply()
            if currentMode == "linux" { self?.applyMode(restart: true) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .setMode, object: nil,
                                                                queue: .main) { [weak self] n in
            if let m = n.object as? String { self?.setMode(m) }
        })
        control = Control()
        if control == nil { status.forwardProblem = "Couldn't listen for the PC (port \(controlPort) is busy)." }
        control?.onMessage = { [weak self] m, stamp, ip in self?.heard(m, stamp, ip) }
        applyMode()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        tick()
        // Started by hand (not at login)? Show the window so you can see it's working.
        if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != bundleID { showSettings() }
    }

    func config() -> String {
        "\(defaults.integer(forKey: Key.port))|\(defaults.double(forKey: Key.volume))|\(defaults.integer(forKey: Key.buffer))"
    }

    func settingsChanged() {
        applyAppearance()
        let c = config()
        guard c != lastConfig else { return }
        lastConfig = c
        applyWork?.cancel()  // wait until you stop dragging the slider
        let w = DispatchWorkItem { [weak self] in self?.receiver.apply() }
        applyWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func tick() {
        let name = defaultOutputName()
        if status.outputName != name { status.outputName = name }
        // Headphones plugged in etc.: capture from the new output.
        if forwarder.running && forwarder.device != defaultOutputDevice() { applyMode(restart: true) }
        if currentMode == "linux" && !forwarder.running && beat % 5 == 0 { applyMode() }  // retry
        beat += 1
        if beat % 2 == 0, let host = defaults.string(forKey: Key.linuxHost) {
            control?.send(currentMode, defaults.double(forKey: Key.modeStamp), to: host)
        }
        objectWillChangePeer()
        updateStatusIcon()
    }

    /// The status window shows "PC answering" from a time, so nudge it once a second.
    func objectWillChangePeer() { status.objectWillChange.send() }

    // MARK: Which way sound goes

    func setMode(_ m: String, stamp: Double = Date().timeIntervalSince1970, fromPeer: Bool = false) {
        guard modes.contains(m) else { return }
        defaults.set(m, forKey: Key.mode)
        defaults.set(stamp, forKey: Key.modeStamp)
        applyMode()
        if !fromPeer { announce() }
        lastIconState = ""
        updateStatusIcon()
    }

    /// The PC told us its choice (and where it is).
    func heard(_ m: String, _ stamp: Double, _ ip: String) {
        status.peerLast = Date()
        if defaults.string(forKey: Key.linuxHost) != ip {
            defaults.set(ip, forKey: Key.linuxHost)
            if currentMode == "linux" { applyMode(restart: true) }
        }
        if stamp > defaults.double(forKey: Key.modeStamp) + 0.0005 { setMode(m, stamp: stamp, fromPeer: true) }
    }

    func announce() {
        guard let host = defaults.string(forKey: Key.linuxHost) else { return }
        let m = currentMode, st = defaults.double(forKey: Key.modeStamp)
        for wait in [0.0, 0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.control?.send(m, st, to: host) }
        }
    }

    func applyMode(restart: Bool = false) {
        guard currentMode == "linux" else {
            forwarder.stop()
            status.forwarding = false; status.forwardProblem = nil
            return
        }
        guard let host = defaults.string(forKey: Key.linuxHost) else {
            status.forwarding = false
            status.forwardProblem = "This Mac hasn't heard from your PC yet. Make sure Audio Abduction+ is running on the PC."
            return
        }
        if forwarder.running && forwarder.host == host && !restart { return }
        let err = forwarder.start(to: host, port: UInt16(defaults.integer(forKey: Key.port)))
        status.forwarding = err == nil
        status.forwardProblem = err
    }

    func applyAppearance() {
        var dock = defaults.bool(forKey: Key.showDock)
        let bar = defaults.bool(forKey: Key.showMenuBar) || !dock
        if !bar && !dock { dock = true }
        let policy: NSApplication.ActivationPolicy = dock ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            if policy == .regular { NSApp.applicationIconImage = nil }
            if window?.isVisible == true { NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil) }
        }
        if bar && statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
            updateStatusIcon()
        } else if !bar, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    var lastIconState = ""
    func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let m = currentMode
        let s = m == "off" ? "off" : (m == "mac" ? status.streaming : status.forwarding && status.peerOK) ? "on" : "idle"
        guard s != lastIconState else { return }
        lastIconState = s
        let symbol = s == "on" ? "dot.radiowaves.left.and.right" : s == "idle" ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Audio Abduction+")
        img?.isTemplate = true
        button.image = img
        button.appearsDisabled = s == "off"
        button.toolTip = "Audio Abduction+ — \(modeStatus())"
    }

    func modeStatus() -> String {
        switch currentMode {
        case "off": return "Not forwarding"
        case "linux":
            if status.forwardProblem != nil { return "Can't send this Mac's sound" }
            return status.peerOK ? "This Mac's sound plays on your PC" : "Waiting for your PC"
        default: return status.state
        }
    }

    // Menu bar menu, rebuilt each time it opens so it shows the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let head = NSMenuItem(title: modeStatus(), action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        let out = NSMenuItem(title: "Output: \(status.outputName)", action: nil, keyEquivalent: "")
        out.isEnabled = false
        menu.addItem(out)
        menu.addItem(.separator())
        menu.addItem(item(forwardLabel(currentMode), #selector(forward), ""))
        if currentMode != "off" { menu.addItem(item("Stop Forwarding", #selector(stopForwarding), "")) }
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings), ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Audio Abduction+", #selector(quit), "q"))
    }

    func item(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(item("Settings…", #selector(showSettings), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Audio Abduction+", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit Audio Abduction+", #selector(quit), "q"))
        appItem.submenu = appMenu
        let winItem = NSMenuItem()
        main.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        winMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        winItem.submenu = winMenu
        NSApp.mainMenu = main
    }

    @objc func forward() { setMode(forwardTarget(currentMode)) }
    @objc func stopForwarding() { setMode("off") }
    @objc func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func showSettings() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(status: status)))
            w.title = "Audio Abduction+"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // Clicking the Dock icon opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ n: Notification) { receiver.stop(); forwarder.stop() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
