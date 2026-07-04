// FlowLocal — inserts transcribed text into the focused app.

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
