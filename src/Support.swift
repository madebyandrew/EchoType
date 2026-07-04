// FlowLocal — shared config, key maps, and transcript cleanup.

import Cocoa

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
    var whisperServerPath: String = "/opt/homebrew/bin/whisper-server"
    var serverPort: Int = 18027
    var modelPath: String = ""
    var language: String = "en"
    var maxRecordingSeconds: Double = 300
    var appearance: String = "system"      // system | light | dark

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

// MARK: - Transcript cleanup

func cleanTranscript(_ raw: String, removeFillers: Bool) -> String {
    var text = raw
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    // Drop whisper's non-speech annotations: [BLANK_AUDIO], (music), etc.
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
