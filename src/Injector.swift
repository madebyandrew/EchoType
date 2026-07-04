// EchoType — inserts transcribed text into the focused app.

import Cocoa

let injectionMagic: Int64 = 0x464C4F57  // "FLOW" — marks our own synthetic events

enum Injector {
    static func type(_ text: String) {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        src.userData = injectionMagic
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            var buf = Array(units[i..<min(i + 20, units.count)])
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

    /// Presses a key (with optional modifiers) `times` times — used by voice
    /// commands for Return, Backspace, ⌘Z, etc.
    static func sendKey(_ keyCode: CGKeyCode, flags: CGEventFlags = [], times: Int = 1) {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        src.userData = injectionMagic
        for _ in 0..<max(0, times) {
            if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) {
                down.flags = flags
                down.post(tap: .cgSessionEventTap)
            }
            if let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
                up.flags = flags
                up.post(tap: .cgSessionEventTap)
            }
            usleep(6000)
        }
    }

    static func backspace(_ count: Int) {
        sendKey(51, times: min(count, 4000))
    }

    /// Copies the current selection in the frontmost app (simulated ⌘C) and
    /// hands it to `completion`; empty string when nothing is selected.
    /// The user's clipboard is restored afterwards.
    static func copySelection(completion: @escaping (String) -> Void) {
        let pb = NSPasteboard.general
        let savedItems = pb.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let d = item.data(forType: t) { copy[t] = d } }
            return copy.isEmpty ? nil : copy
        } ?? []
        let beforeCount = pb.changeCount
        pb.clearContents()

        guard let src = CGEventSource(stateID: .combinedSessionState) else { completion(""); return }
        src.userData = injectionMagic
        if let down = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true) {  // C
            down.flags = .maskCommand
            down.post(tap: .cgSessionEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false) {
            up.flags = .maskCommand
            up.post(tap: .cgSessionEventTap)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let selection = pb.changeCount > beforeCount + 1
                ? (pb.string(forType: .string) ?? "") : ""
            pb.clearContents()
            for itemData in savedItems {
                let item = NSPasteboardItem()
                for (t, d) in itemData { item.setData(d, forType: t) }
                pb.writeObjects([item])
            }
            completion(selection)
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
