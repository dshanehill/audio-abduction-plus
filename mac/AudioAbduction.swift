// Audio Abduction+ — Mac app shell.
// Shows a Dock icon and a menu bar icon, has a Settings window, and runs receiver.py
// (the part that actually plays the audio) with whatever settings you choose.
import AppKit
import CoreAudio
import SwiftUI

let bundleID = "local.audio-abduction.plus"
let agentPlist = NSHomeDirectory() + "/Library/LaunchAgents/\(bundleID).plist"
let logPath = "/tmp/audio-abduction.log"

enum Key {
    static let enabled = "enabled", port = "port", volume = "volume", buffer = "buffer"
    static let showDock = "showDock", showMenuBar = "showMenuBar"
}

let defaults = UserDefaults.standard
func registerDefaults() {
    defaults.register(defaults: [Key.enabled: true, Key.port: 46000, Key.volume: 100.0,
                                 Key.buffer: 1024, Key.showDock: true, Key.showMenuBar: true])
}

// MARK: - Live status shown in the window and menu

final class Status: ObservableObject {
    @Published var state = "Starting…"
    @Published var streaming = false
    @Published var sender = ""
    @Published var delayMs: Int? = nil
    @Published var outputName = "—"
    @Published var problem: String? = nil
}

func defaultOutputName() -> String {
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr
    else { return "—" }
    var name: Unmanaged<CFString>? = nil
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    addr.mSelector = kAudioObjectPropertyName
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &name) == noErr, let n = name
    else { return "—" }
    return n.takeRetainedValue() as String
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
        guard defaults.bool(forKey: Key.enabled) else {
            status.state = "Off"; status.streaming = false; status.problem = nil
            return
        }
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
        let w = DispatchWorkItem { [weak self] in
            if defaults.bool(forKey: Key.enabled) { self?.start() }
        }
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
    @AppStorage(Key.enabled) var enabled = true
    @AppStorage(Key.volume) var volume = 100.0
    @AppStorage(Key.buffer) var buffer = 1024
    @AppStorage(Key.showDock) var showDock = true
    @AppStorage(Key.showMenuBar) var showMenuBar = true
    @State var startAtLogin = LoginItem.isOn

    var dotColor: Color { !enabled ? .secondary : status.problem != nil ? .red : status.streaming ? .green : .orange }
    var headline: String {
        if !enabled { return "Off" }
        if status.problem != nil { return "Something went wrong" }
        return status.streaming ? "Playing sound from your PC" : "Ready"
    }
    var detail: String {
        if !enabled { return "Turn on Play Sound From PC to hear your PC through this Mac." }
        if status.problem != nil { return "Audio Abduction+ is trying again. If this keeps happening, click Restart." }
        return status.streaming ? "Sound is coming out of \(status.outputName)."
                                : "Waiting for your PC. Start Audio Abduction on the PC to hear it here."
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
                Toggle(isOn: $enabled) {
                    Text("Play Sound From PC")
                    Text("Sound from your PC plays through this Mac's speakers or headphones.")
                }
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

extension Notification.Name { static let restartReceiver = Notification.Name("restartReceiver") }

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let status = Status()
    lazy var receiver = Receiver(status: status)
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
        })
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        tick()
        // Started by hand (not at login)? Show the window so you can see it's working.
        if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != bundleID { showSettings() }
    }

    func config() -> String {
        "\(defaults.bool(forKey: Key.enabled))|\(defaults.integer(forKey: Key.port))|\(defaults.double(forKey: Key.volume))|\(defaults.integer(forKey: Key.buffer))"
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
        updateStatusIcon()
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
        let enabled = defaults.bool(forKey: Key.enabled)
        let s = !enabled ? "off" : status.streaming ? "on" : "idle"
        guard s != lastIconState else { return }
        lastIconState = s
        let symbol = s == "on" ? "dot.radiowaves.left.and.right" : s == "idle" ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Audio Abduction+")
        img?.isTemplate = true
        button.image = img
        button.appearsDisabled = s == "off"
        button.toolTip = "Audio Abduction+ — \(status.state)"
    }

    // Menu bar menu, rebuilt each time it opens so it shows the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let head = NSMenuItem(title: status.state, action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        let out = NSMenuItem(title: "Output: \(status.outputName)", action: nil, keyEquivalent: "")
        out.isEnabled = false
        menu.addItem(out)
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: "Play Sound From PC", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.state = defaults.bool(forKey: Key.enabled) ? .on : .off
        toggle.target = self
        menu.addItem(toggle)
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

    @objc func toggleEnabled() { defaults.set(!defaults.bool(forKey: Key.enabled), forKey: Key.enabled) }
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

    func applicationWillTerminate(_ n: Notification) { receiver.stop() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
