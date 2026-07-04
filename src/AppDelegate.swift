// FlowLocal — app lifecycle: menu bar, event tap, dictation pipeline, main window.

import Cocoa
import SwiftUI
import AVFoundation

enum AppState { case idle, recording, transcribing }

final class AppDelegate: NSObject, NSApplicationDelegate {
    var config = Config.load()
    let recorder = Recorder()
    let history = HistoryStore()
    lazy var engine = WhisperEngine { [weak self] in self?.config ?? Config() }
    let store = AppStore()

    var statusItem: NSStatusItem!
    var window: NSWindow?
    var state: AppState = .idle
    var capturingHotkey = false
    var hotkeyIsDown = false
    var eventTap: CFMachPort?
    var warnedAboutAccessibility = false
    var recordingWatchdog: Timer?
    var currentTargetApp = ""
    let workQueue = DispatchQueue(label: "flowlocal.transcribe", qos: .userInitiated)

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.delegate = self
        resolvePaths()
        applyAppearance()
        setupStatusItem()
        requestPermissions()
        setupEventTap()
        engine.startServer()
        updateUI()
        showWindow()

        // Keep the engine status line in the UI fresh (it changes as the model warms up).
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.store.engineStatus != self.engine.statusText {
                self.store.engineStatus = self.engine.statusText
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    // MARK: window

    func showWindow() {
        if window == nil {
            let hosting = NSHostingController(rootView: ContentView().environmentObject(store))
            let w = NSWindow(contentViewController: hosting)
            w.title = "FlowLocal"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 880, height: 580))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        store.reloadAll()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func applyAppearance() {
        switch config.appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
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
        for (keyPath, candidates) in [
            (\Config.whisperCliPath, ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]),
            (\Config.whisperServerPath, ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]),
        ] as [(WritableKeyPath<Config, String>, [String])] {
            if !fm.fileExists(atPath: config[keyPath: keyPath]),
               let found = candidates.first(where: { fm.fileExists(atPath: $0) }) {
                config[keyPath: keyPath] = found
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
                                   text: "FlowLocal needs the microphone to hear you. Grant access in System Settings → Privacy & Security → Microphone.")
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
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
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
                return nil
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
        currentTargetApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
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
        let duration = Double(samples.count) / 16000.0
        NSLog("FlowLocal: recording stopped — %.1fs of audio", duration)
        if config.soundFeedback { NSSound(named: "Bottle")?.play() }

        guard duration >= 0.3 else {
            state = .idle
            updateUI()
            return
        }
        state = .transcribing
        updateUI()

        let cfg = config
        let targetApp = currentTargetApp
        workQueue.async {
            var text = ""
            var failure: String?
            do {
                let wav = Recorder.wavData(samples)
                text = cleanTranscript(try self.engine.transcribe(wav: wav), removeFillers: cfg.removeFillers)
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
                self.history.add(text: text, duration: duration, appName: targetApp)
                self.store.reloadAll()
            }
        }
    }

    // MARK: hotkey capture

    func beginHotkeyCapture() {
        capturingHotkey = true
        store.capturingHotkey = true
        updateUI()
    }

    func finishHotkeyCapture(_ keyCode: Int64?) {
        DispatchQueue.main.async {
            self.capturingHotkey = false
            self.store.capturingHotkey = false
            if let keyCode = keyCode {
                self.config.hotkeyKeyCode = keyCode
                self.config.hotkeyIsModifier = modifierKeyCodes.contains(keyCode)
                self.config.hotkeyName = keyName(keyCode)
                self.config.save()
                self.hotkeyIsDown = false
                self.store.syncFromConfig(self.config)
            }
            self.updateUI()
        }
    }

    // MARK: menu bar

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙️"
        statusItem.behavior = []
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
    }

    func updateUI() {
        guard let button = statusItem?.button else { return }
        if capturingHotkey {
            button.title = "⌨️?"
            store.dictationState = "Assign key…"
        } else if eventTap == nil {
            button.title = "🎙️⚠️"
            store.dictationState = "No keyboard access"
        } else {
            switch state {
            case .idle: button.title = "🎙️"; store.dictationState = "Idle"
            case .recording: button.title = "🔴"; store.dictationState = "Recording…"
            case .transcribing: button.title = "✍️"; store.dictationState = "Transcribing…"
            }
        }
    }

    func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let status: String
        if capturingHotkey {
            status = "Press any key to assign… (Esc cancels)"
        } else if eventTap == nil {
            status = "⚠️ Grant Accessibility in System Settings"
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

        let openWin = NSMenuItem(title: "Open FlowLocal", action: #selector(openWindowClicked), keyEquivalent: "o")
        openWin.target = self
        menu.addItem(openWin)

        let setKey = NSMenuItem(title: "Set Push-to-Talk Key…  (now: \(config.hotkeyName))",
                                action: #selector(setHotkeyClicked), keyEquivalent: "")
        setKey.target = self
        menu.addItem(setKey)

        menu.addItem(.separator())
        let privacy = NSMenuItem(title: "100% local — audio never leaves this Mac", action: nil, keyEquivalent: "")
        privacy.isEnabled = false
        menu.addItem(privacy)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit FlowLocal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func openWindowClicked() { showWindow() }
    @objc func setHotkeyClicked() { beginHotkeyCapture() }

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
