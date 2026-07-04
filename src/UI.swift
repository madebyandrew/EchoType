// FlowLocal — the main window: sidebar, Home, History, Settings.

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
    @Published var capturingHotkey = false
    @Published var engineStatus = "starting…"
    @Published var dictationState = "Idle"

    @Published var toggleMode = false
    @Published var injectByPasting = false
    @Published var removeFillers = true
    @Published var soundFeedback = true
    @Published var appearance = "system"

    func syncFromConfig(_ c: Config) {
        hotkeyName = c.hotkeyName
        toggleMode = c.toggleMode
        injectByPasting = c.injectByPasting
        removeFillers = c.removeFillers
        soundFeedback = c.soundFeedback
        appearance = c.appearance
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
        engineStatus = delegate.engine.statusText
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
    case home, history, settings

    var label: String {
        switch self {
        case .home: return "Home"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house"
        case .history: return "clock.arrow.circlepath"
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
                    Text("FlowLocal").font(.title3.bold())
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
                case .history: HistoryView()
                case .settings: SettingsView()
                }
            }
            .frame(minWidth: 520, minHeight: 420)
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
                         : "Hold \(store.hotkeyName) anywhere, speak, release — your words land at the cursor.")
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 14) {
                    StatCard(value: formatted(store.stats.totalWords), label: "total words", icon: "text.word.spacing")
                    StatCard(value: "\(store.stats.wordsPerMinute)", label: "words / min", icon: "speedometer")
                    StatCard(value: "\(store.stats.dayStreak)", label: "day streak", icon: "flame")
                    StatCard(value: formatted(store.stats.totalDictations), label: "dictations", icon: "waveform")
                }

                HStack(spacing: 8) {
                    Image(systemName: "cpu")
                        .foregroundStyle(.secondary)
                    Text("Engine: \(store.engineStatus)")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Text(store.dictationState)
                        .font(.callout.bold())
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(store.dictationState == "Idle"
                                                   ? Color.secondary.opacity(0.15)
                                                   : Color.red.opacity(0.18)))
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

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            Section("Push-to-Talk") {
                HStack {
                    Text("Shortcut")
                    Spacer()
                    Text(store.capturingHotkey ? "Press any key… (Esc cancels)" : store.hotkeyName)
                        .foregroundStyle(store.capturingHotkey ? .orange : .secondary)
                    Button(store.capturingHotkey ? "Waiting…" : "Change…") {
                        store.delegate?.beginHotkeyCapture()
                    }
                    .disabled(store.capturingHotkey)
                }
                Toggle("Toggle mode — press to start, press to stop", isOn: bind(\.toggleMode) { $0.toggleMode = $1 })
            }

            Section("Insertion") {
                Toggle("Insert by pasting (⌘V) instead of typing", isOn: bind(\.injectByPasting) { $0.injectByPasting = $1 })
                Text("Pasting is faster for long dictations; your previous clipboard is restored automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Transcription") {
                Toggle("Remove filler words (um, uh…)", isOn: bind(\.removeFillers) { $0.removeFillers = $1 })
                Toggle("Sound feedback", isOn: bind(\.soundFeedback) { $0.soundFeedback = $1 })
                HStack {
                    Text("Engine")
                    Spacer()
                    Text(store.engineStatus).foregroundStyle(.secondary)
                }
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
                Text("Model, language, port, and recording limits live in the config file.")
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
