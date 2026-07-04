// EchoType — entry point.

import Cocoa

// One-time migration from when the app was called FlowLocal: keep the user's
// config and dictation history across the rename.
do {
    let fm = FileManager.default
    let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let old = appSupport.appendingPathComponent("FlowLocal")
    let new = appSupport.appendingPathComponent("EchoType")
    if fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path) {
        try? fm.moveItem(at: old, to: new)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
