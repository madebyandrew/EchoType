// EchoType — the main window: sidebar, Home, History, Styles, Dictionary, Snippets, Settings.

import SwiftUI

// MARK: - Store (bridges AppDelegate ↔ SwiftUI)

final class AppStore: ObservableObject {
    weak var delegate: AppDelegate?

    @Published var stats = Stats()
    @Published var entries: [Dictation] = []
    @Published var search = "" {
        didSet { reloadEntries() }
    }
    @Published var hotkeyName = "Right ⌥"
    @Published var rewriteHotkeyName = "Right ⌘"
    @Published var capturingHotkey = false
    @Published var engineStatus = "starting…"
    @Published var aiStatus = "starting…"
    @Published var dictationState = "Idle"

    @Published var toggleMode = false
    @Published var injectByPasting = false
    @Published var removeFillers = true
    @Published var soundFeedback = true
    @Published var appearance = "system"
    @Published var aiEnabled = true
    @Published var language = "en"
    @Published var voiceCommandsEnabled = true
    @Published var livePreview = true
    @Published var wordsPerDay: [DayWords] = []
    @Published var topApps: [(String, Int)] = []
    @Published var activeModeID = "cleanup"
    @Published var modes: [Mode] = []
    @Published var dictionary: [String] = []
    @Published var snippets: [Snippet] = []
    @Published var appRules: [String: String] = [:]

    func syncFromConfig(_ c: Config) {
        hotkeyName = c.hotkeyName
        rewriteHotkeyName = c.rewriteHotkeyName
        toggleMode = c.toggleMode
        injectByPasting = c.injectByPasting
        removeFillers = c.removeFillers
        soundFeedback = c.soundFeedback
        appearance = c.appearance
        aiEnabled = c.aiEnabled
        language = c.language
        voiceCommandsEnabled = c.voiceCommandsEnabled
        livePreview = c.livePreview
        activeModeID = c.activeModeID
        modes = c.modes
        dictionary = c.dictionary
        snippets = c.snippets
        appRules = c.appRules
    }

    func updateConfig(_ mutate: (inout Config) -> Void) {
        guard let delegate = delegate else { return }
        mutate(&delegate.config)
        delegate.config.save()
        syncFromConfig(delegate.config)
        delegate.applyAppearance()
    }

    func reloadEntries() {
        guard let delegate = delegate else { return }
        entries = delegate.history.recent(search: search)
    }

    func reloadAll() {
        guard let delegate = delegate else { return }
        stats = delegate.history.stats()
        entries = delegate.history.recent(search: search)
        wordsPerDay = delegate.history.wordsPerDay()
        topApps = delegate.history.topApps()
        engineStatus = delegate.engine.statusText
        aiStatus = delegate.llm.statusText
        syncFromConfig(delegate.config)
    }

    func delete(_ d: Dictation) {
        delegate?.history.delete(id: d.id)
        reloadAll()
    }

    func copyText(_ d: Dictation) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(d.text, forType: .string)
    }
}

// MARK: - Root

enum SidebarItem: String, Hashable, CaseIterable {
    case home, insights, history, modes, dictionary, snippets, settings

    var label: String {
        switch self {
        case .home: return "Home"
        case .insights: return "Insights"
        case .history: return "History"
        case .modes: return "Styles"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house"
        case .insights: return "chart.bar"
        case .history: return "clock.arrow.circlepath"
        case .modes: return "wand.and.stars"
        case .dictionary: return "character.book.closed"
        case .snippets: return "text.badge.plus"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @State private var selection: SidebarItem? = .home

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(SidebarItem.allCases, id: \.self) { item in
                        Label(item.label, systemImage: item.icon).tag(item)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 8) {
                    Text("🎙️").font(.title2)
                    Text("EchoType").font(.title3.bold())
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 7, height: 7)
                        Text("100% local").font(.caption.bold())
                    }
                    Text("Your voice never leaves this Mac.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.12)))
                .padding(10)
            }
        } detail: {
            Group {
                switch selection ?? .home {
                case .home: HomeView()
                case .insights: InsightsView()
                case .history: HistoryView()
                case .modes: ModesView()
                case .dictionary: DictionaryView()
                case .snippets: SnippetsView()
                case .settings: SettingsView()
                }
            }
            .frame(minWidth: 540, minHeight: 440)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.updateConfig { c in
                        c.appearance = (store.appearance == "dark") ? "light" : "dark"
                    }
                } label: {
                    Image(systemName: store.appearance == "dark" ? "sun.max" : "moon")
                }
                .help(store.appearance == "dark" ? "Switch to light mode" : "Switch to dark mode")
            }
        }
        .onAppear { store.reloadAll() }
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var store: AppStore

    private var firstName: String {
        NSFullUserName().components(separatedBy: " ").first ?? "there"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome back, \(firstName)")
                        .font(.system(size: 28, weight: .bold))
                    Text(store.toggleMode
                         ? "Press \(store.hotkeyName) anywhere to start and stop dictating."
                         : "Hold \(store.hotkeyName) to dictate · hold \(store.rewriteHotkeyName) over selected text to rewrite it with your voice.")
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 14) {
                    StatCard(value: formatted(store.stats.totalWords), label: "total words", icon: "text.word.spacing")
                    StatCard(value: "\(store.stats.wordsPerMinute)", label: "words / min", icon: "speedometer")
                    StatCard(value: "\(store.stats.dayStreak)", label: "day streak", icon: "flame")
                    StatCard(value: formatted(store.stats.totalDictations), label: "dictations", icon: "waveform")
                }

                // Style picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Writing style").font(.headline)
                    HStack(spacing: 8) {
                        ForEach(store.modes) { m in
                            Button {
                                store.updateConfig { $0.activeModeID = m.id }
                            } label: {
                                Text(m.name)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(Capsule().fill(m.id == store.activeModeID
                                                               ? Color.accentColor.opacity(0.25)
                                                               : Color.primary.opacity(0.06)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform").foregroundStyle(.secondary).frame(width: 16)
                        Text("Speech: \(store.engineStatus)")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Text(store.dictationState)
                            .font(.callout.bold())
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(store.dictationState == "Idle"
                                                       ? Color.secondary.opacity(0.15)
                                                       : Color.red.opacity(0.18)))
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "brain").foregroundStyle(.secondary).frame(width: 16)
                        Text("AI: \(store.aiStatus)")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }

                if !store.entries.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recent").font(.headline)
                        ForEach(store.entries.prefix(5)) { d in
                            DictationRow(dictation: d, compact: true)
                        }
                    }
                }
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func formatted(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

struct StatCard: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .bold, design: .rounded))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - Insights

struct InsightsView: View {
    @EnvironmentObject var store: AppStore

    private var timeSavedMinutes: Int {
        // Typing the same words at ~40 wpm vs the time actually spent speaking.
        let typingMinutes = Double(store.stats.totalWords) / 40.0
        let spokenMinutes = store.stats.totalSeconds / 60.0
        return max(0, Int(typingMinutes - spokenMinutes))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Insights").font(.system(size: 28, weight: .bold))

                HStack(spacing: 14) {
                    StatCard(value: "\(timeSavedMinutes) min", label: "saved vs typing (40 wpm)", icon: "clock.badge.checkmark")
                    StatCard(value: "\(store.stats.wordsPerMinute)", label: "your speaking wpm", icon: "speedometer")
                    StatCard(value: "\(store.stats.dayStreak)", label: "day streak", icon: "flame")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Words per day — last 14 days").font(.headline)
                    let maxWords = max(store.wordsPerDay.map(\.words).max() ?? 1, 1)
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(store.wordsPerDay) { day in
                            VStack(spacing: 4) {
                                Text(day.words > 0 ? "\(day.words)" : "")
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(day.words > 0 ? Color.accentColor : Color.primary.opacity(0.08))
                                    .frame(height: max(4, CGFloat(day.words) / CGFloat(maxWords) * 120))
                                Text(day.label.prefix(1))
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 160, alignment: .bottom)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
                }

                if !store.topApps.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Where you dictate").font(.headline)
                        let maxApp = max(store.topApps.map(\.1).max() ?? 1, 1)
                        VStack(spacing: 8) {
                            ForEach(store.topApps, id: \.0) { app, words in
                                HStack {
                                    Text(app).frame(width: 140, alignment: .leading).lineLimit(1)
                                    GeometryReader { geo in
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(Color.accentColor.opacity(0.7))
                                            .frame(width: max(4, geo.size.width * CGFloat(words) / CGFloat(maxApp)))
                                    }
                                    .frame(height: 14)
                                    Text("\(words)").font(.caption).foregroundStyle(.secondary)
                                        .frame(width: 60, alignment: .trailing)
                                }
                            }
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
                    }
                }
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { store.reloadAll() }
    }
}

// MARK: - History

struct HistoryView: View {
    @EnvironmentObject var store: AppStore

    private var grouped: [(String, [Dictation])] {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.doesRelativeDateFormatting = true
        var order: [String] = []
        var buckets: [String: [Dictation]] = [:]
        for d in store.entries {
            let key = fmt.string(from: d.date)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(d)
        }
        return order.map { ($0, buckets[$0]!) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search your dictations…", text: $store.search)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .padding([.horizontal, .top], 16)

            if store.entries.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "waveform.slash").font(.largeTitle).foregroundStyle(.secondary)
                    Text(store.search.isEmpty ? "Nothing dictated yet" : "No matches")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(grouped, id: \.0) { day, items in
                        Section(day.uppercased()) {
                            ForEach(items) { d in
                                DictationRow(dictation: d, compact: false)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear { store.reloadEntries() }
    }
}

struct DictationRow: View {
    @EnvironmentObject var store: AppStore
    let dictation: Dictation
    let compact: Bool
    @State private var copied = false

    private var time: String {
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        return fmt.string(from: dictation.date)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(time)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(dictation.text)
                    .lineLimit(compact ? 2 : nil)
                if !compact && !dictation.appName.isEmpty {
                    Text(dictation.appName)
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button {
                store.copyText(dictation)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
            if !compact {
                Button {
                    store.delete(dictation)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete")
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Styles (modes, spoken triggers, app rules)

struct ModesView: View {
    @EnvironmentObject var store: AppStore
    @State private var newRuleApp = ""
    @State private var newRuleModeID = "cleanup"

    var body: some View {
        Form {
            Section {
                Text("The active style shapes every dictation. Say a style's trigger word first (\"tweet …\") to use it just once. All processing runs on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Styles") {
                ForEach(store.modes) { m in
                    ModeEditor(mode: m)
                }
                Button {
                    store.updateConfig {
                        $0.modes.append(Mode(name: "New style", prompt: "Rewrite the dictated text as…"))
                    }
                } label: {
                    Label("Add style", systemImage: "plus")
                }
            }

            Section("App rules — pick a style automatically per app") {
                ForEach(store.appRules.sorted(by: { $0.key < $1.key }), id: \.key) { app, modeID in
                    HStack {
                        Text(app)
                        Spacer()
                        Text(store.modes.first { $0.id == modeID }?.name ?? "?")
                            .foregroundStyle(.secondary)
                        Button { store.updateConfig { $0.appRules[app] = nil } } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("App name (e.g. Slack, Mail)", text: $newRuleApp)
                    Picker("", selection: $newRuleModeID) {
                        ForEach(store.modes) { m in Text(m.name).tag(m.id) }
                    }
                    .frame(width: 150)
                    Button("Add") {
                        let app = newRuleApp.trimmingCharacters(in: .whitespaces)
                        guard !app.isEmpty else { return }
                        store.updateConfig { $0.appRules[app] = newRuleModeID }
                        newRuleApp = ""
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ModeEditor: View {
    @EnvironmentObject var store: AppStore
    let mode: Mode
    @State private var expanded = false

    private var isActive: Bool { store.activeModeID == mode.id }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if mode.id != "raw" {
                    TextField("Spoken trigger word (optional, e.g. tweet)", text: Binding(
                        get: { store.modes.first { $0.id == mode.id }?.trigger ?? "" },
                        set: { v in store.updateConfig { c in
                            if let i = c.modes.firstIndex(where: { $0.id == mode.id }) { c.modes[i].trigger = v }
                        }}))
                    TextEditor(text: Binding(
                        get: { store.modes.first { $0.id == mode.id }?.prompt ?? "" },
                        set: { v in store.updateConfig { c in
                            if let i = c.modes.firstIndex(where: { $0.id == mode.id }) { c.modes[i].prompt = v }
                        }}))
                        .font(.callout)
                        .frame(minHeight: 60)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1)))
                } else {
                    Text("Raw skips the AI entirely — you get exactly what Whisper heard.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !mode.builtin {
                    Button(role: .destructive) {
                        store.updateConfig { c in
                            c.modes.removeAll { $0.id == mode.id }
                            if c.activeModeID == mode.id { c.activeModeID = "cleanup" }
                        }
                    } label: {
                        Label("Delete style", systemImage: "trash")
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Button {
                    store.updateConfig { $0.activeModeID = mode.id }
                } label: {
                    Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                Text(mode.name)
                if let t = store.modes.first(where: { $0.id == mode.id })?.trigger, !t.isEmpty {
                    Text("“\(t)”").font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
            }
        }
    }
}

// MARK: - Dictionary

struct DictionaryView: View {
    @EnvironmentObject var store: AppStore
    @State private var newWord = ""

    var body: some View {
        Form {
            Section {
                Text("Names, acronyms, and jargon listed here bias speech recognition and are spelled exactly as written. Example: AuraMint, Cherian, Vaishnav.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Words") {
                ForEach(store.dictionary, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button { store.updateConfig { c in c.dictionary.removeAll { $0 == word } } } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Add a word or name…", text: $newWord)
                        .onSubmit(addWord)
                    Button("Add", action: addWord)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addWord() {
        let w = newWord.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        store.updateConfig { c in
            if !c.dictionary.contains(w) { c.dictionary.append(w) }
        }
        newWord = ""
    }
}

// MARK: - Snippets

struct SnippetsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            Section {
                Text("Say a snippet's trigger phrase on its own and EchoType types the full text. Example: say “meeting notes” to insert your meeting template.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Snippets") {
                ForEach(store.snippets) { s in
                    SnippetEditor(snippet: s)
                }
                Button {
                    store.updateConfig { $0.snippets.append(Snippet(trigger: "trigger phrase", text: "Expanded text…")) }
                } label: {
                    Label("Add snippet", systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct SnippetEditor: View {
    @EnvironmentObject var store: AppStore
    let snippet: Snippet
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Spoken trigger phrase", text: Binding(
                    get: { store.snippets.first { $0.id == snippet.id }?.trigger ?? "" },
                    set: { v in store.updateConfig { c in
                        if let i = c.snippets.firstIndex(where: { $0.id == snippet.id }) { c.snippets[i].trigger = v }
                    }}))
                TextEditor(text: Binding(
                    get: { store.snippets.first { $0.id == snippet.id }?.text ?? "" },
                    set: { v in store.updateConfig { c in
                        if let i = c.snippets.firstIndex(where: { $0.id == snippet.id }) { c.snippets[i].text = v }
                    }}))
                    .font(.callout)
                    .frame(minHeight: 70)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1)))
                Button(role: .destructive) {
                    store.updateConfig { c in c.snippets.removeAll { $0.id == snippet.id } }
                } label: {
                    Label("Delete snippet", systemImage: "trash")
                }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Text(store.snippets.first { $0.id == snippet.id }?.trigger ?? "")
                Spacer()
                Text(store.snippets.first { $0.id == snippet.id }?.text.prefix(40) ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            Section("Shortcuts") {
                HStack {
                    Text("Dictate")
                    Spacer()
                    Text(store.capturingHotkey ? "Press any key… (Esc cancels)" : store.hotkeyName)
                        .foregroundStyle(store.capturingHotkey ? .orange : .secondary)
                    Button("Change…") { store.delegate?.beginHotkeyCapture(.dictation) }
                        .disabled(store.capturingHotkey)
                }
                HStack {
                    Text("Rewrite selection / AI command")
                    Spacer()
                    Text(store.capturingHotkey ? "Press any key… (Esc cancels)" : store.rewriteHotkeyName)
                        .foregroundStyle(store.capturingHotkey ? .orange : .secondary)
                    Button("Change…") { store.delegate?.beginHotkeyCapture(.rewrite) }
                        .disabled(store.capturingHotkey)
                }
                Toggle("Toggle mode — press to start, press to stop", isOn: bind(\.toggleMode) { $0.toggleMode = $1 })
            }

            Section("Local AI") {
                Toggle("AI cleanup and styles (via Ollama, on this Mac)", isOn: bind(\.aiEnabled) { $0.aiEnabled = $1 })
                HStack {
                    Text("Status")
                    Spacer()
                    Text(store.aiStatus).foregroundStyle(.secondary)
                }
                Text("With AI off (or the Raw style), you get Whisper's transcript with basic regex cleanup only.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Insertion") {
                Toggle("Insert by pasting (⌘V) instead of typing", isOn: bind(\.injectByPasting) { $0.injectByPasting = $1 })
                Text("Pasting is faster for long dictations; your previous clipboard is restored automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Transcription") {
                Picker("Language", selection: Binding(
                    get: { store.language },
                    set: { v in
                        store.updateConfig { $0.language = v }
                        store.delegate?.engine.restart()
                    })) {
                    Text("English (fastest)").tag("en")
                    Text("Auto-detect — any language").tag("auto")
                }
                Text("Auto-detect uses a larger multilingual model: speak English, French, Spanish… no switching. Slightly slower than English-only.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Live preview while speaking", isOn: bind(\.livePreview) { $0.livePreview = $1 })
                Toggle("Voice commands (new paragraph, scratch that…)", isOn: bind(\.voiceCommandsEnabled) { $0.voiceCommandsEnabled = $1 })
                Toggle("Remove filler words (um, uh…)", isOn: bind(\.removeFillers) { $0.removeFillers = $1 })
                Toggle("Sound feedback", isOn: bind(\.soundFeedback) { $0.soundFeedback = $1 })
                HStack {
                    Text("Engine")
                    Spacer()
                    Text(store.engineStatus).foregroundStyle(.secondary)
                }
            }

            Section("Voice commands") {
                Text("Say one of these on its own while dictating: “new paragraph”, “new line”, “press enter”, “press tab”, “undo”, “scratch that”, “delete last sentence”, “retry”.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Appearance") {
                Picker("Theme", selection: Binding(
                    get: { store.appearance },
                    set: { v in store.updateConfig { $0.appearance = v } })) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }

            Section("Advanced") {
                Button("Open config file") {
                    NSWorkspace.shared.open(Config.path)
                }
                Text("Whisper model, Ollama model, language, ports, and recording limits live in the config file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func bind(_ get: KeyPath<AppStore, Bool>, _ set: @escaping (inout Config, Bool) -> Void) -> Binding<Bool> {
        Binding(get: { store[keyPath: get] },
                set: { v in store.updateConfig { set(&$0, v) } })
    }
}
