// FlowLocal — app lifecycle: menu bar, event tap, dictation pipeline, main window.

import Cocoa
import SwiftUI
import AVFoundation

enum AppState { case idle, recording, transcribing }
enum SessionKind { case dictation, rewrite }
enum HotkeySlot { case dictation, rewrite }

final class AppDelegate: NSObject, NSApplicationDelegate {
    var config = Config.load()
    let recorder = Recorder()
    let history = HistoryStore()
    lazy var engine = WhisperEngine { [weak self] in self?.config ?? Config() }
    lazy var llm = OllamaEngine { [weak self] in self?.config ?? Config() }
    let store = AppStore()

    var statusItem: NSStatusItem!
    var window: NSWindow?
    var state: AppState = .idle
    var sessionKind: SessionKind = .dictation
    var capturingHotkey: HotkeySlot?
    var dictationKeyDown = false
    var rewriteKeyDown = false
    var eventTap: CFMachPort?
    var warnedAboutAccessibility = false
    var recordingWatchdog: Timer?
    var currentTargetApp = ""
    var pendingSelection = ""
    let workQueue = DispatchQueue(label: "flowlocal.transcribe", qos: .userInitiated)

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.delegate = self
        resolvePaths()
        applyAppearance()
        setupStatusItem()
        requestPermissions()
        setupEventTap()
        engine.startServer()
        llm.start()
        updateUI()
        showWindow()

        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.store.engineStatus != self.engine.statusText {
                self.store.engineStatus = self.engine.statusText
            }
            if self.store.aiStatus != self.llm.statusText {
                self.store.aiStatus = self.llm.statusText
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown()
        llm.shutdown()
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
            w.setContentSize(NSSize(width: 920, height: 600))
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
            (\Config.ollamaPath, ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]),
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
        NSLog("FlowLocal: event tap active")
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

        if let slot = capturingHotkey {
            if type == .keyDown {
                if keyCode == 53 { finishHotkeyCapture(slot, nil) }
                else { finishHotkeyCapture(slot, keyCode) }
                return nil
            }
            if type == .flagsChanged, modifierKeyCodes.contains(keyCode),
               let flag = modifierFlag(for: keyCode), event.flags.contains(flag) {
                finishHotkeyCapture(slot, keyCode)
                return Unmanaged.passUnretained(event)
            }
            return Unmanaged.passUnretained(event)
        }

        if keyCode == config.hotkeyKeyCode {
            return handleHotkey(slot: .dictation, isModifier: config.hotkeyIsModifier,
                                isDown: &dictationKeyDown, type: type, event: event)
        }
        if keyCode == config.rewriteHotkeyKeyCode {
            return handleHotkey(slot: .rewrite, isModifier: config.rewriteHotkeyIsModifier,
                                isDown: &rewriteKeyDown, type: type, event: event)
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleHotkey(slot: HotkeySlot, isModifier: Bool, isDown: inout Bool,
                              type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if isModifier {
            guard type == .flagsChanged, let flag = modifierFlag(for: keyCode) else {
                return Unmanaged.passUnretained(event)
            }
            let down = event.flags.contains(flag)
            if down && !isDown {
                isDown = true
                hotkeyPressed(slot)
            } else if !down && isDown {
                isDown = false
                hotkeyReleased(slot)
            }
            return Unmanaged.passUnretained(event)   // never swallow modifiers
        } else {
            if type == .keyDown {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !isRepeat { hotkeyPressed(slot) }
                return nil
            }
            if type == .keyUp {
                hotkeyReleased(slot)
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: push-to-talk state machine

    func hotkeyPressed(_ slot: HotkeySlot) {
        DispatchQueue.main.async {
            let kind: SessionKind = (slot == .dictation) ? .dictation : .rewrite
            if self.config.toggleMode && slot == .dictation {
                switch self.state {
                case .idle: self.startRecording(kind: kind)
                case .recording: self.stopAndTranscribe()
                case .transcribing: break
                }
            } else {
                if self.state == .idle { self.startRecording(kind: kind) }
            }
        }
    }

    func hotkeyReleased(_ slot: HotkeySlot) {
        DispatchQueue.main.async {
            if self.config.toggleMode && slot == .dictation { return }
            if self.state == .recording { self.stopAndTranscribe() }
        }
    }

    func startRecording(kind: SessionKind) {
        sessionKind = kind
        currentTargetApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        pendingSelection = ""
        if kind == .rewrite {
            // Grab the selection while the user starts speaking.
            Injector.copySelection { [weak self] sel in
                self?.pendingSelection = sel
                NSLog("FlowLocal: rewrite session — selection of \(sel.count) chars")
            }
        }
        do {
            try recorder.start()
            NSLog("FlowLocal: recording started (\(kind == .dictation ? "dictation" : "rewrite"))")
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
        let kind = sessionKind
        let targetApp = currentTargetApp
        let selection = pendingSelection
        workQueue.async {
            var failure: String?
            var output = ""
            do {
                let wav = Recorder.wavData(samples)
                let raw = try self.engine.transcribe(wav: wav, vocabulary: cfg.dictionary)
                let clean = cleanTranscript(raw, removeFillers: cfg.removeFillers)
                if !clean.isEmpty {
                    output = (kind == .dictation)
                        ? self.processDictation(clean, cfg: cfg, targetApp: targetApp)
                        : self.processRewrite(clean, selection: selection, cfg: cfg)
                }
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
                guard !output.isEmpty else { return }
                // Rewrites replace the still-selected text, so always paste them.
                if cfg.injectByPasting || kind == .rewrite || output.contains("\n") {
                    Injector.paste(output)
                } else {
                    Injector.type(output)
                }
                self.history.add(text: output, duration: duration, appName: targetApp)
                self.store.reloadAll()
            }
        }
    }

    // MARK: AI pipeline

    /// Dictation: snippets → spoken trigger → app rule → active mode → local LLM.
    private func processDictation(_ text: String, cfg: Config, targetApp: String) -> String {
        // Snippet expansion: transcript that *is* a snippet trigger becomes its text.
        let normalized = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
        if let snippet = cfg.snippets.first(where: {
            $0.trigger.lowercased().trimmingCharacters(in: .whitespaces) == normalized && !$0.trigger.isEmpty
        }) {
            NSLog("FlowLocal: expanded snippet '\(snippet.trigger)'")
            return snippet.text
        }

        // Spoken trigger word picks a mode: "tweet …", "reply …"
        var mode: Mode? = nil
        var body = text
        for m in cfg.modes where !m.trigger.isEmpty {
            if let rest = stripTrigger(m.trigger, from: text), !rest.isEmpty {
                mode = m
                body = rest
                NSLog("FlowLocal: spoken trigger '\(m.trigger)' → mode \(m.name)")
                break
            }
        }
        // App rule, then the globally active mode.
        if mode == nil, let ruleID = cfg.appRules[targetApp], let m = cfg.mode(id: ruleID) {
            mode = m
            NSLog("FlowLocal: app rule \(targetApp) → mode \(m.name)")
        }
        let chosen = mode ?? cfg.activeMode

        guard cfg.aiEnabled, !chosen.prompt.isEmpty, llm.available else { return body }
        var system = chosen.prompt
        if !cfg.dictionary.isEmpty {
            system += " Spell these words exactly as given when they occur: \(cfg.dictionary.joined(separator: ", "))."
        }
        system += onlyTextRule
        do {
            let out = try llm.chat(system: system, user: body)
            return out.isEmpty ? body : out
        } catch {
            NSLog("FlowLocal: LLM cleanup failed (\(error.localizedDescription)) — using raw transcript")
            return body
        }
    }

    /// Rewrite: spoken instruction applied to the selected text (or pure generation
    /// when nothing is selected).
    private func processRewrite(_ instruction: String, selection: String, cfg: Config) -> String {
        guard cfg.aiEnabled, llm.available else {
            NSLog("FlowLocal: rewrite requested but local AI is unavailable")
            return ""
        }
        do {
            if selection.isEmpty {
                let system = "Follow the user's spoken instruction and produce the requested text."
                    + onlyTextRule
                return try llm.chat(system: system, user: instruction)
            } else {
                let system = "You are a precise text editor. Apply the instruction to the text. "
                    + "Change only what the instruction requires; keep everything else intact."
                    + onlyTextRule
                return try llm.chat(system: system,
                                    user: "Instruction: \(instruction)\n\nText:\n\(selection)")
            }
        } catch {
            NSLog("FlowLocal: rewrite failed — \(error.localizedDescription)")
            return ""
        }
    }

    // MARK: hotkey capture

    func beginHotkeyCapture(_ slot: HotkeySlot) {
        capturingHotkey = slot
        store.capturingHotkey = true
        updateUI()
    }

    func finishHotkeyCapture(_ slot: HotkeySlot, _ keyCode: Int64?) {
        DispatchQueue.main.async {
            self.capturingHotkey = nil
            self.store.capturingHotkey = false
            if let keyCode = keyCode {
                switch slot {
                case .dictation:
                    self.config.hotkeyKeyCode = keyCode
                    self.config.hotkeyIsModifier = modifierKeyCodes.contains(keyCode)
                    self.config.hotkeyName = keyName(keyCode)
                    self.dictationKeyDown = false
                case .rewrite:
                    self.config.rewriteHotkeyKeyCode = keyCode
                    self.config.rewriteHotkeyIsModifier = modifierKeyCodes.contains(keyCode)
                    self.config.rewriteHotkeyName = keyName(keyCode)
                    self.rewriteKeyDown = false
                }
                self.config.save()
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
        if capturingHotkey != nil {
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
        if capturingHotkey != nil {
            status = "Press any key to assign… (Esc cancels)"
        } else if eventTap == nil {
            status = "⚠️ Grant Accessibility in System Settings"
        } else {
            switch state {
            case .idle: status = config.toggleMode
                ? "Press \(config.hotkeyName) to start/stop dictation"
                : "Hold \(config.hotkeyName) to dictate · \(config.rewriteHotkeyName) to rewrite selection"
            case .recording: status = "Recording…"
            case .transcribing: status = "Working locally…"
            }
        }
        let statusLine = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        // Quick mode switcher
        let modeMenu = NSMenu()
        for m in config.modes {
            let item = NSMenuItem(title: m.name, action: #selector(modeClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = m.id
            item.state = (m.id == config.activeModeID) ? .on : .off
            modeMenu.addItem(item)
        }
        let modeRoot = NSMenuItem(title: "Style: \(config.activeMode.name)", action: nil, keyEquivalent: "")
        modeRoot.submenu = modeMenu
        menu.addItem(modeRoot)

        let openWin = NSMenuItem(title: "Open FlowLocal", action: #selector(openWindowClicked), keyEquivalent: "o")
        openWin.target = self
        menu.addItem(openWin)

        menu.addItem(.separator())
        let privacy = NSMenuItem(title: "100% local — audio never leaves this Mac", action: nil, keyEquivalent: "")
        privacy.isEnabled = false
        menu.addItem(privacy)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit FlowLocal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func openWindowClicked() { showWindow() }
    @objc func modeClicked(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            config.activeModeID = id
            config.save()
            store.syncFromConfig(config)
        }
    }

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
