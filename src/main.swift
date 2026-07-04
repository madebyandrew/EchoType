// FlowLocal — a private, fully-local push-to-talk dictation app for macOS.
// Hold your assigned key anywhere, speak, release: text appears at your cursor.
// Audio never leaves this machine. No cloud, no screenshots, no telemetry.

import Cocoa
import AVFoundation

// MARK: - Config

struct Config: Codable {
    var hotkeyKeyCode: Int64 = 61          // Right Option by default
    var hotkeyIsModifier: Bool = true
    var hotkeyName: String = "Right ⌥"
    var toggleMode: Bool = false           // false = hold to talk, true = press to start/stop
    var injectByPasting: Bool = false      // false = type it in, true = paste via ⌘V
    var removeFillers: Bool = true
    var soundFeedback: Bool = true
    var whisperCliPath: String = "/opt/homebrew/bin/whisper-cli"
    var modelPath: String = ""
    var language: String = "en"
    var maxRecordingSeconds: Double = 300

    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlowLocal")
    }
    static var path: URL { dir.appendingPathComponent("config.json") }

    static func load() -> Config {
        if let data = try? Data(contentsOf: path),
           let cfg = try? JSONDecoder().decode(Config.self, from: data) {
            return cfg
        }
        return Config()
    }

    func save() {
        try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: Config.path)
        }
    }
}

// MARK: - Key names

let keyNames: [Int64: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
    11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
    34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
    18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
    27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 42: "\\", 50: "`",
    36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape", 76: "Keypad Enter",
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
    101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
    106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    123: "←", 124: "→", 125: "↓", 126: "↑",
    115: "Home", 116: "Page Up", 119: "End", 121: "Page Down", 117: "Fwd Delete",
    54: "Right ⌘", 55: "⌘", 56: "⇧", 57: "Caps Lock", 58: "⌥", 59: "⌃",
    60: "Right ⇧", 61: "Right ⌥", 62: "Right ⌃", 63: "Fn",
]

let modifierKeyCodes: Set<Int64> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

func modifierFlag(for keyCode: Int64) -> CGEventFlags? {
    switch keyCode {
    case 54, 55: return .maskCommand
    case 56, 60: return .maskShift
    case 58, 61: return .maskAlternate
    case 59, 62: return .maskControl
    case 63: return .maskSecondaryFn
    case 57: return .maskAlphaShift
    default: return nil
    }
}

func keyName(_ keyCode: Int64) -> String {
    keyNames[keyCode] ?? "Key #\(keyCode)"
}

// MARK: - Audio recorder (16 kHz mono WAV, all in memory until saved)

final class Recorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false

    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16000, channels: 1, interleaved: false)!

    func start() throws {
        guard !isRecording else { return }
        samples.removeAll(keepingCapacity: true)
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "FlowLocal", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone input available."])
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, let converter = self.converter else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: capacity) else { return }
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard err == nil, out.frameLength > 0, let ch = out.floatChannelData else { return }
            self.lock.lock()
            self.samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
            self.lock.unlock()
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops and returns the captured audio; empty if too short.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        converter = nil
        lock.lock()
        let result = samples
        samples.removeAll()
        lock.unlock()
        return result
    }

    var durationSoFar: Double {
        lock.lock()
        let n = samples.count
        lock.unlock()
        return Double(n) / 16000.0
    }

    static func writeWAV(_ samples: [Float], to url: URL) throws {
        var data = Data()
        let sampleRate: UInt32 = 16000
        let dataSize = UInt32(samples.count * 2)
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))               // PCM, mono
        append(sampleRate); append(sampleRate * 2)          // byte rate
        append(UInt16(2)); append(UInt16(16))               // block align, bits
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            append(Int16(clamped * 32767.0))
        }
        try data.write(to: url)
    }
}

// MARK: - Transcriber (shells out to local whisper-cli; nothing ever leaves the machine)

final class Transcriber {
    let cliPath: String
    let modelPath: String
    let language: String

    init(cliPath: String, modelPath: String, language: String) {
        self.cliPath = cliPath
        self.modelPath = modelPath
        self.language = language
    }

    func transcribe(wavURL: URL) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cliPath)
        proc.arguments = [
            "-m", modelPath,
            "-f", wavURL.path,
            "--language", language,
            "--no-timestamps",
            "--no-prints",
            "-t", "\(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))",
        ]
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = Pipe()   // swallow backend chatter
        try proc.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "FlowLocal", code: Int(proc.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "whisper-cli exited with status \(proc.terminationStatus)"])
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}

// MARK: - Text cleanup

func cleanTranscript(_ raw: String, removeFillers: Bool) -> String {
    var text = raw
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    // Drop whisper's non-speech annotations: [BLANK_AUDIO], (music), [inaudible], etc.
    for pattern in ["\\[[^\\]]*\\]", "\\([^)]*\\)", "♪[^♪]*♪"] {
        text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    if removeFillers {
        text = text.replacingOccurrences(
            of: "(?i)(^|[\\s,])(um+|uh+|uhm+|erm+|hmm+)([\\s,.!?]|$)",
            with: "$1$3", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+([,.!?])", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "([,.!?])\\1+", with: "$1", options: .regularExpression)
    }
    text = text.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return text
}

// MARK: - Text injection

let injectionMagic: Int64 = 0x464C4F57  // "FLOW" — marks our own synthetic events

final class Injector {
    static func type(_ text: String) {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        src.userData = injectionMagic
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 20, units.count)])
            var buf = chunk
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: &buf)
                down.post(tap: .cgSessionEventTap)
            }
            if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                up.post(tap: .cgSessionEventTap)
            }
            usleep(8000)
            i += 20
        }
    }

    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let d = item.data(forType: t) { copy[t] = d } }
            return copy.isEmpty ? nil : copy
        } ?? []

        pb.clearContents()
        pb.setString(text, forType: .string)

        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        src.userData = injectionMagic
        if let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true) {  // V
            down.flags = .maskCommand
            down.post(tap: .cgSessionEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) {
            up.flags = .maskCommand
            up.post(tap: .cgSessionEventTap)
        }
        // Restore the previous clipboard after the paste lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            pb.clearContents()
            for itemData in saved {
                let item = NSPasteboardItem()
                for (t, d) in itemData { item.setData(d, forType: t) }
                pb.writeObjects([item])
            }
        }
    }
}

// MARK: - App

enum AppState { case idle, recording, transcribing }

final class AppDelegate: NSObject, NSApplicationDelegate {
    var config = Config.load()
    let recorder = Recorder()
    var statusItem: NSStatusItem!
    var state: AppState = .idle
    var capturingHotkey = false
    var hotkeyIsDown = false
    var eventTap: CFMachPort?
    var warnedAboutAccessibility = false
    var recordingWatchdog: Timer?
    let workQueue = DispatchQueue(label: "flowlocal.transcribe", qos: .userInitiated)

    func applicationDidFinishLaunching(_ notification: Notification) {
        resolvePaths()
        setupStatusItem()
        requestPermissions()
        setupEventTap()
        updateUI()
    }

    // MARK: paths

    func resolvePaths() {
        let fm = FileManager.default
        if config.modelPath.isEmpty || !fm.fileExists(atPath: config.modelPath) {
            let candidates = [
                Bundle.main.bundlePath + "/Contents/Resources/ggml-base.en.bin",
                NSHomeDirectory() + "/Clone of Wispr Flow/models/ggml-base.en.bin",
                Config.dir.appendingPathComponent("ggml-base.en.bin").path,
            ]
            if let found = candidates.first(where: { fm.fileExists(atPath: $0) }) {
                config.modelPath = found
            }
        }
        if !fm.fileExists(atPath: config.whisperCliPath) {
            let candidates = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli",
                              "/opt/homebrew/bin/whisper-cpp", "/usr/local/bin/whisper-cpp"]
            if let found = candidates.first(where: { fm.fileExists(atPath: $0) }) {
                config.whisperCliPath = found
            }
        }
        config.save()
    }

    // MARK: permissions

    func requestPermissions() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                DispatchQueue.main.async {
                    self.showAlert(title: "Microphone access needed",
                                   text: "FlowLocal needs the microphone to hear you. Grant access in System Settings → Privacy & Security → Microphone, then relaunch.")
                }
            }
        }
    }

    // MARK: event tap

    func setupEventTap() {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }

        eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                     place: .headInsertEventTap,
                                     options: .defaultTap,
                                     eventsOfInterest: mask,
                                     callback: callback,
                                     userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap = eventTap else {
            // No Accessibility permission yet: keep retrying so no relaunch is
            // needed after the user grants it in System Settings.
            if !warnedAboutAccessibility {
                warnedAboutAccessibility = true
                DispatchQueue.main.async {
                    self.showAlert(title: "One more step: Accessibility",
                                   text: "To hear your push-to-talk key and type text for you, enable FlowLocal in System Settings → Privacy & Security → Accessibility. It will start working the moment you flip the switch — no relaunch needed.")
                }
            }
            NSLog("FlowLocal: event tap creation FAILED — Accessibility permission missing or stale")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.setupEventTap() }
            updateUI()
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("FlowLocal: event tap active — listening for hotkey keycode \(config.hotkeyKeyCode)")
        updateUI()
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables taps that stall; re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Ignore our own injected events.
        if event.getIntegerValueField(.eventSourceUserData) == injectionMagic {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if capturingHotkey {
            if type == .keyDown {
                if keyCode == 53 {  // Escape cancels
                    finishHotkeyCapture(nil)
                } else {
                    finishHotkeyCapture(keyCode)
                }
                return nil
            }
            if type == .flagsChanged, modifierKeyCodes.contains(keyCode),
               let flag = modifierFlag(for: keyCode), event.flags.contains(flag) {
                finishHotkeyCapture(keyCode)
                return Unmanaged.passUnretained(event)
            }
            return Unmanaged.passUnretained(event)
        }

        guard keyCode == config.hotkeyKeyCode else { return Unmanaged.passUnretained(event) }

        if config.hotkeyIsModifier {
            guard type == .flagsChanged, let flag = modifierFlag(for: config.hotkeyKeyCode) else {
                return Unmanaged.passUnretained(event)
            }
            let down = event.flags.contains(flag)
            if down && !hotkeyIsDown {
                hotkeyIsDown = true
                hotkeyPressed()
            } else if !down && hotkeyIsDown {
                hotkeyIsDown = false
                hotkeyReleased()
            }
            return Unmanaged.passUnretained(event)   // never swallow modifiers
        } else {
            if type == .keyDown {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !isRepeat { hotkeyPressed() }
                return nil                            // swallow so it doesn't type
            }
            if type == .keyUp {
                hotkeyReleased()
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: push-to-talk state machine

    func hotkeyPressed() {
        DispatchQueue.main.async {
            if self.config.toggleMode {
                switch self.state {
                case .idle: self.startRecording()
                case .recording: self.stopAndTranscribe()
                case .transcribing: break
                }
            } else {
                if self.state == .idle { self.startRecording() }
            }
        }
    }

    func hotkeyReleased() {
        DispatchQueue.main.async {
            guard !self.config.toggleMode else { return }
            if self.state == .recording { self.stopAndTranscribe() }
        }
    }

    func startRecording() {
        do {
            try recorder.start()
            NSLog("FlowLocal: recording started")
            state = .recording
            if config.soundFeedback { NSSound(named: "Pop")?.play() }
            recordingWatchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                if self.recorder.durationSoFar >= self.config.maxRecordingSeconds {
                    self.stopAndTranscribe()
                }
            }
        } catch {
            showAlert(title: "Couldn't start recording", text: error.localizedDescription)
            state = .idle
        }
        updateUI()
    }

    func stopAndTranscribe() {
        recordingWatchdog?.invalidate()
        recordingWatchdog = nil
        let samples = recorder.stop()
        NSLog("FlowLocal: recording stopped — %.1fs of audio", Double(samples.count) / 16000.0)
        if config.soundFeedback { NSSound(named: "Bottle")?.play() }

        guard Double(samples.count) / 16000.0 >= 0.3 else {  // too short to mean anything
            state = .idle
            updateUI()
            return
        }
        state = .transcribing
        updateUI()

        let cfg = config
        workQueue.async {
            let wav = FileManager.default.temporaryDirectory
                .appendingPathComponent("flowlocal-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            var text = ""
            var failure: String?
            do {
                try Recorder.writeWAV(samples, to: wav)
                let t = Transcriber(cliPath: cfg.whisperCliPath, modelPath: cfg.modelPath, language: cfg.language)
                text = cleanTranscript(try t.transcribe(wavURL: wav), removeFillers: cfg.removeFillers)
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.state = .idle
                self.updateUI()
                if let failure = failure {
                    NSLog("FlowLocal: transcription FAILED — \(failure)")
                    self.showAlert(title: "Transcription failed", text: failure)
                    return
                }
                NSLog("FlowLocal: transcribed \(text.count) characters")
                guard !text.isEmpty else { return }
                if cfg.injectByPasting { Injector.paste(text) } else { Injector.type(text) }
            }
        }
    }

    // MARK: hotkey capture

    func beginHotkeyCapture() {
        capturingHotkey = true
        updateUI()
    }

    func finishHotkeyCapture(_ keyCode: Int64?) {
        DispatchQueue.main.async {
            self.capturingHotkey = false
            if let keyCode = keyCode {
                self.config.hotkeyKeyCode = keyCode
                self.config.hotkeyIsModifier = modifierKeyCodes.contains(keyCode)
                self.config.hotkeyName = keyName(keyCode)
                self.config.save()
                self.hotkeyIsDown = false
            }
            self.updateUI()
        }
    }

    // MARK: UI

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙️"   // visible immediately, even if a launch alert blocks updateUI
        statusItem.behavior = []           // not removable by drag
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
    }

    func updateUI() {
        guard let button = statusItem?.button else { return }
        if capturingHotkey {
            button.title = "⌨️?"
        } else if eventTap == nil {
            button.title = "🎙️⚠️"          // no keyboard access yet
        } else {
            switch state {
            case .idle: button.title = "🎙️"
            case .recording: button.title = "🔴"
            case .transcribing: button.title = "✍️"
            }
        }
    }

    func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let status: String
        if capturingHotkey {
            status = "Press any key to assign… (Esc cancels)"
        } else {
            switch state {
            case .idle: status = config.toggleMode
                ? "Press \(config.hotkeyName) to start/stop dictation"
                : "Hold \(config.hotkeyName) and speak"
            case .recording: status = "Recording…"
            case .transcribing: status = "Transcribing locally…"
            }
        }
        let statusLine = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let setKey = NSMenuItem(title: "Set Push-to-Talk Key…  (now: \(config.hotkeyName))",
                                action: #selector(setHotkeyClicked), keyEquivalent: "")
        setKey.target = self
        menu.addItem(setKey)

        let toggle = NSMenuItem(title: "Toggle Mode (press instead of hold)",
                                action: #selector(toggleModeClicked), keyEquivalent: "")
        toggle.target = self
        toggle.state = config.toggleMode ? .on : .off
        menu.addItem(toggle)

        let paste = NSMenuItem(title: "Insert by Pasting (⌘V) instead of typing",
                               action: #selector(pasteModeClicked), keyEquivalent: "")
        paste.target = self
        paste.state = config.injectByPasting ? .on : .off
        menu.addItem(paste)

        let fillers = NSMenuItem(title: "Remove Filler Words (um, uh…)",
                                 action: #selector(fillersClicked), keyEquivalent: "")
        fillers.target = self
        fillers.state = config.removeFillers ? .on : .off
        menu.addItem(fillers)

        let sound = NSMenuItem(title: "Sound Feedback",
                               action: #selector(soundClicked), keyEquivalent: "")
        sound.target = self
        sound.state = config.soundFeedback ? .on : .off
        menu.addItem(sound)

        menu.addItem(.separator())
        let openCfg = NSMenuItem(title: "Open Config File", action: #selector(openConfigClicked), keyEquivalent: "")
        openCfg.target = self
        menu.addItem(openCfg)

        let privacy = NSMenuItem(title: "100% local — audio never leaves this Mac", action: nil, keyEquivalent: "")
        privacy.isEnabled = false
        menu.addItem(privacy)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit FlowLocal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc func setHotkeyClicked() { beginHotkeyCapture() }
    @objc func toggleModeClicked() { config.toggleMode.toggle(); config.save(); updateUI() }
    @objc func pasteModeClicked() { config.injectByPasting.toggle(); config.save() }
    @objc func fillersClicked() { config.removeFillers.toggle(); config.save() }
    @objc func soundClicked() { config.soundFeedback.toggle(); config.save() }
    @objc func openConfigClicked() { NSWorkspace.shared.open(Config.path) }

    func showAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { rebuildMenu(menu) }
}

// MARK: - main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
