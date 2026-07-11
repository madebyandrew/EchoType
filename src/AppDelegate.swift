// EchoType — app lifecycle: menu bar, event tap, dictation pipeline, main window.

import Cocoa
import SwiftUI
import AVFoundation
import QuartzCore

// App background, shared with SwiftUI via appBackground in UI.swift:
// near-black with a green tint (#060E0A) in dark mode, white in light mode.
let appBackgroundNSColor = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 6 / 255, green: 14 / 255, blue: 10 / 255, alpha: 1)
        : NSColor.white
}

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
    var lastInjectedText = ""
    var lastSamples: [Float] = []
    let previewHUD = PreviewHUD()
    var previewTimer: Timer?
    var previewInflight = false
    let workQueue = DispatchQueue(label: "echotype.transcribe", qos: .userInitiated)

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
            w.title = "EchoType"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.titlebarAppearsTransparent = true
            w.backgroundColor = appBackgroundNSColor
            w.setContentSize(NSSize(width: 920, height: 600))
            w.isReleasedWhenClosed = false
            // Follow the user: reopen on whatever Space/desktop they are on now,
            // not the one the window was last closed on.
            w.collectionBehavior = [.moveToActiveSpace]
            w.center()
            window = w
        }
        store.reloadAll()
        // Accessory apps can be denied activation while another app is frontmost
        // (cooperative activation, macOS 14+), which leaves the window buried
        // behind the active app when the user reopens EchoType. Force activation,
        // and briefly float the window above all normal windows so it is visible
        // even when activation is refused.
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        window?.makeKeyAndOrderFront(nil)
        window?.level = .floating
        window?.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.window?.level = .normal
        }
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
        if config.multilingualModelPath.isEmpty || !fm.fileExists(atPath: config.multilingualModelPath) {
            let candidates = [
                Bundle.main.bundlePath + "/Contents/Resources/ggml-small.bin",
                NSHomeDirectory() + "/Clone of Wispr Flow/models/ggml-small.bin",
                Config.dir.appendingPathComponent("ggml-small.bin").path,
            ]
            if let found = candidates.first(where: { fm.fileExists(atPath: $0) }) {
                config.multilingualModelPath = found
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
                                   text: "EchoType needs the microphone to hear you. Grant access in System Settings → Privacy & Security → Microphone.")
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
                                   text: "To hear your push-to-talk key and type text for you, enable EchoType in System Settings → Privacy & Security → Accessibility. It will start working the moment you flip the switch — no relaunch needed.")
                }
            }
            NSLog("EchoType: event tap creation FAILED — Accessibility permission missing or stale")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.setupEventTap() }
            updateUI()
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("EchoType: event tap active")
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
                NSLog("EchoType: rewrite session — selection of \(sel.count) chars")
            }
        }
        do {
            try recorder.start()
            NSLog("EchoType: recording started (\(kind == .dictation ? "dictation" : "rewrite"))")
            state = .recording
            if config.soundFeedback { NSSound(named: "Pop")?.play() }
            if config.livePreview {
                previewHUD.show(kind == .dictation ? "Listening…" : "Speak your instruction…")
                previewTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                    self?.updatePreview()
                }
            }
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
        previewTimer?.invalidate()
        previewTimer = nil
        let samples = recorder.stop()
        NSLog("EchoType: recording stopped — %.1fs of audio", Double(samples.count) / 16000.0)
        if config.soundFeedback { NSSound(named: "Bottle")?.play() }

        guard Double(samples.count) / 16000.0 >= 0.3 else {
            state = .idle
            updateUI()
            previewHUD.hide()
            return
        }
        processSamples(samples, kind: sessionKind, selection: pendingSelection,
                       targetApp: currentTargetApp, allowCommands: true)
    }

    private func processSamples(_ samples: [Float], kind: SessionKind, selection: String,
                                targetApp: String, allowCommands: Bool) {
        let duration = Double(samples.count) / 16000.0
        state = .transcribing
        updateUI()
        if config.livePreview { previewHUD.show("Working locally…") }

        let cfg = config
        workQueue.async {
            var failure: String?
            var clean = ""
            do {
                let raw = try self.engine.transcribe(wav: Recorder.wavData(samples), vocabulary: cfg.dictionary)
                clean = cleanTranscript(raw, removeFillers: cfg.removeFillers)
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                if let failure = failure {
                    self.state = .idle
                    self.updateUI()
                    self.previewHUD.hide()
                    NSLog("EchoType: transcription FAILED — \(failure)")
                    self.showAlert(title: "Transcription failed", text: failure)
                    return
                }
                // Whole-utterance voice commands act instead of typing.
                if allowCommands, kind == .dictation, cfg.voiceCommandsEnabled,
                   self.executeVoiceCommand(clean) {
                    self.state = .idle
                    self.updateUI()
                    self.previewHUD.hide()
                    return
                }
                self.workQueue.async {
                    var output = ""
                    if !clean.isEmpty {
                        output = (kind == .dictation)
                            ? self.processDictation(clean, cfg: cfg, targetApp: targetApp)
                            : self.processRewrite(clean, selection: selection, cfg: cfg)
                    }
                    DispatchQueue.main.async {
                        self.state = .idle
                        self.updateUI()
                        self.previewHUD.hide()
                        guard !output.isEmpty else { return }
                        // Rewrites replace the still-selected text, so always paste them.
                        if cfg.injectByPasting || kind == .rewrite || output.contains("\n") {
                            Injector.paste(output)
                        } else {
                            Injector.type(output)
                        }
                        if kind == .dictation {
                            self.lastInjectedText = output
                            self.lastSamples = samples
                        }
                        self.history.add(text: output, duration: duration, appName: targetApp)
                        self.store.reloadAll()
                    }
                }
            }
        }
    }

    // MARK: live preview

    private func updatePreview() {
        guard state == .recording, config.livePreview, !previewInflight else { return }
        let samples = recorder.snapshot()
        guard Double(samples.count) / 16000.0 > 0.8 else { return }
        previewInflight = true
        let cfg = config
        workQueue.async {
            let raw = (try? self.engine.transcribe(wav: Recorder.wavData(samples), vocabulary: cfg.dictionary)) ?? ""
            DispatchQueue.main.async {
                self.previewInflight = false
                guard self.state == .recording else { return }
                let text = cleanTranscript(raw, removeFillers: false)
                if !text.isEmpty {
                    self.previewHUD.show("…" + String(text.suffix(110)))
                }
            }
        }
    }

    // MARK: voice commands

    /// Handles utterances that are commands rather than content. Returns true
    /// when the utterance was consumed.
    private func executeVoiceCommand(_ text: String) -> Bool {
        let cmd = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
        switch cmd {
        case "new paragraph":
            Injector.sendKey(36, times: 2)
            lastInjectedText = ""
        case "new line", "newline":
            Injector.sendKey(36)
            lastInjectedText = ""
        case "press enter", "hit enter":
            Injector.sendKey(36)
            lastInjectedText = ""
        case "press tab":
            Injector.sendKey(48)
        case "undo":
            Injector.sendKey(6, flags: .maskCommand)   // ⌘Z
        case "scratch that", "delete that":
            guard !lastInjectedText.isEmpty else { return true }
            Injector.backspace(lastInjectedText.count)
            lastInjectedText = ""
        case "delete last sentence":
            guard !lastInjectedText.isEmpty else { return true }
            let sentence = lastSentence(of: lastInjectedText)
            Injector.backspace(sentence.count)
            lastInjectedText = String(lastInjectedText.dropLast(sentence.count))
        case "retry", "try again":
            guard !lastSamples.isEmpty else { return true }
            Injector.backspace(lastInjectedText.count)
            lastInjectedText = ""
            let samples = lastSamples
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.processSamples(samples, kind: .dictation, selection: "",
                                    targetApp: self.currentTargetApp, allowCommands: false)
            }
        default:
            return false
        }
        NSLog("EchoType: voice command — \(cmd)")
        return true
    }

    private func lastSentence(of text: String) -> String {
        guard !text.isEmpty else { return "" }
        var boundary = text.startIndex
        var seenContent = false
        var i = text.index(before: text.endIndex)
        while true {
            let ch = text[i]
            if seenContent, ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                boundary = text.index(after: i)
                break
            }
            if !ch.isWhitespace && ch != "." && ch != "!" && ch != "?" { seenContent = true }
            if i == text.startIndex { break }
            i = text.index(before: i)
        }
        return String(text[boundary...])
    }

    // MARK: AI pipeline

    /// Dictation: snippets → spoken trigger → app rule → active mode → local LLM.
    private func processDictation(_ text: String, cfg: Config, targetApp: String) -> String {
        // Snippet expansion: transcript that *is* a snippet trigger becomes its text.
        let normalized = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
        if let snippet = cfg.snippets.first(where: {
            $0.trigger.lowercased().trimmingCharacters(in: .whitespaces) == normalized && !$0.trigger.isEmpty
        }) {
            NSLog("EchoType: expanded snippet '\(snippet.trigger)'")
            return snippet.text
        }

        // Spoken trigger word picks a mode: "tweet …", "reply …"
        var mode: Mode? = nil
        var body = text
        for m in cfg.modes where !m.trigger.isEmpty {
            if let rest = stripTrigger(m.trigger, from: text), !rest.isEmpty {
                mode = m
                body = rest
                NSLog("EchoType: spoken trigger '\(m.trigger)' → mode \(m.name)")
                break
            }
        }
        // App rule, then the globally active mode.
        if mode == nil, let ruleID = cfg.appRules[targetApp], let m = cfg.mode(id: ruleID) {
            mode = m
            NSLog("EchoType: app rule \(targetApp) → mode \(m.name)")
        }
        let chosen = mode ?? cfg.activeMode

        guard cfg.aiEnabled, !chosen.prompt.isEmpty, llm.available else { return body }
        var system = chosen.prompt
        if !cfg.dictionary.isEmpty {
            system += " Spell these words exactly as given when they occur: \(cfg.dictionary.joined(separator: ", "))."
        }
        system += transcriptIsDataRule + " Keep the output in the same language the transcript was spoken in." + onlyTextRule
        // Few-shot example: a question stays a question. This anchors small
        // models against replying to the transcript.
        let example = ("um so how do I fix this bug in the login page and uh where should I look first",
                       "How do I fix this bug in the login page, and where should I look first?")
        do {
            let out = try llm.chat(system: system, user: body, example: example)
            guard !out.isEmpty else { return body }
            // Safety net: built-in styles preserve the speaker's words. If the
            // output barely shares vocabulary with the input — or balloons past
            // it — the model answered the transcript instead of transforming it.
            if chosen.builtin, chosen.id != "raw" {
                let inWords = body.split { $0.isWhitespace }.count
                let outWords = out.split { $0.isWhitespace }.count
                let overlap = wordOverlap(body, out)
                if overlap < 0.4 || outWords > Int(Double(inWords) * 1.4) + 5 {
                    NSLog("EchoType: LLM output diverged (overlap %.2f, %d→%d words) — model likely replied to the transcript; using raw transcript", overlap, inWords, outWords)
                    return body
                }
            }
            return out
        } catch {
            NSLog("EchoType: LLM cleanup failed (\(error.localizedDescription)) — using raw transcript")
            return body
        }
    }

    /// Rewrite: spoken instruction applied to the selected text (or pure generation
    /// when nothing is selected).
    private func processRewrite(_ instruction: String, selection: String, cfg: Config) -> String {
        guard cfg.aiEnabled, llm.available else {
            NSLog("EchoType: rewrite requested but local AI is unavailable")
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
            NSLog("EchoType: rewrite failed — \(error.localizedDescription)")
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
        if let button = statusItem?.button, let appIcon = NSApplication.shared.applicationIconImage,
           let icon = appIcon.copy() as? NSImage {
            icon.size = NSSize(width: 18, height: 18)
            button.image = icon
            button.imagePosition = .imageLeft
        }
        statusItem.behavior = []
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
    }

    func updateUI() {
        guard let button = statusItem?.button else { return }
        if capturingHotkey != nil {
            store.dictationState = "Assign key…"
            button.title = " ?"
        } else if eventTap == nil {
            store.dictationState = "No keyboard access"
            button.title = " ⚠︎"
        } else {
            switch state {
            case .idle:
                store.dictationState = "Idle"
                button.title = ""
            case .recording:
                store.dictationState = "Recording…"
                button.attributedTitle = NSAttributedString(
                    string: " ●",
                    attributes: [.foregroundColor: NSColor.systemRed,
                                 .font: NSFont.systemFont(ofSize: 12, weight: .bold)])
            case .transcribing:
                store.dictationState = "Transcribing…"
                button.title = " …"
            }
        }
        button.toolTip = "EchoType — \(store.dictationState)"
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

        let openWin = NSMenuItem(title: "Open EchoType", action: #selector(openWindowClicked), keyEquivalent: "o")
        openWin.target = self
        menu.addItem(openWin)

        menu.addItem(.separator())
        let privacy = NSMenuItem(title: "100% local — audio never leaves this Mac", action: nil, keyEquivalent: "")
        privacy.isEnabled = false
        menu.addItem(privacy)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit EchoType", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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

// MARK: - Live preview HUD (floating pill near the bottom of the screen)

final class PreviewHUD {
    private let panel: NSPanel
    private let label: NSTextField

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 52),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 480, height: 52))
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 26
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1.5
        effect.layer?.borderColor = NSColor(srgbRed: 141 / 255, green: 220 / 255, blue: 175 / 255, alpha: 0.85).cgColor

        // Deep-green glass tint over the blur.
        let tint = CALayer()
        tint.frame = effect.bounds
        tint.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        tint.backgroundColor = NSColor(srgbRed: 8 / 255, green: 46 / 255, blue: 27 / 255, alpha: 0.6).cgColor
        effect.layer?.addSublayer(tint)

        // Gloss highlight fading down from the top edge.
        let gloss = CAGradientLayer()
        gloss.frame = effect.bounds
        gloss.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        gloss.colors = [NSColor.white.withAlphaComponent(0.28).cgColor,
                        NSColor.white.withAlphaComponent(0.06).cgColor,
                        NSColor.clear.cgColor]
        gloss.locations = [0, 0.35, 1]
        gloss.startPoint = CGPoint(x: 0.5, y: 0)
        gloss.endPoint = CGPoint(x: 0.5, y: 1)
        effect.layer?.addSublayer(gloss)

        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 2
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])
        panel.contentView?.addSubview(effect)
    }

    func show(_ text: String) {
        label.stringValue = text
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let w: CGFloat = 480, h: CGFloat = 52
            panel.setFrame(NSRect(x: f.midX - w / 2, y: f.minY + 70, width: w, height: h), display: true)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        panel.orderOut(nil)
    }
}
