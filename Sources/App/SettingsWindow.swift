import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications

/// The Settings window: a classic macOS toolbar preferences window with SwiftUI panes.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    static let tabs: [(id: String, title: String, symbol: String, view: AnyView)] = [
        ("general", "General", "gearshape", AnyView(GeneralPane())),
        ("clawds", "Clawds", "bell.badge", AnyView(ClawdsPane())),
        ("appearance", "Appearance", "paintbrush", AnyView(AppearancePane())),
        ("position", "Position", "rectangle.inset.bottomleft.filled", AnyView(PositionPane())),
        ("recaps", "Recaps", "text.bubble", AnyView(RecapsPane())),
        ("integrations", "Integrations", "puzzlepiece.extension", AnyView(IntegrationsPane())),
        ("advanced", "Advanced", "slider.horizontal.3", AnyView(AdvancedPane())),
        ("about", "About", "info.circle", AnyView(AboutPane())),
    ]

    private let tabsController = NSTabViewController()
    /// Wide enough for all eight toolbar tabs without an overflow menu.
    static let size = NSSize(width: 680, height: 580)

    init() {
        tabsController.tabStyle = .toolbar
        for t in SettingsWindowController.tabs {
            let host = NSHostingController(rootView: t.view.frame(width: SettingsWindowController.size.width,
                                                                   height: SettingsWindowController.size.height))
            // Without this the tab controller ignores the pane size and clips it.
            host.sizingOptions = [.preferredContentSize]
            host.preferredContentSize = SettingsWindowController.size
            host.title = t.title
            let item = NSTabViewItem(viewController: host)
            item.label = t.title
            item.identifier = t.id
            item.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title)
            tabsController.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabsController)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(SettingsWindowController.size)
        window.toolbarStyle = .preference
        window.title = "Claws for Concern"
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("ClawsSettings")
        super.init(window: window)
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
    required init?(coder: NSCoder) { fatalError() }

    func show(tab: String? = nil) {
        if let tab, let i = SettingsWindowController.tabs.firstIndex(where: { $0.id == tab }) {
            tabsController.selectedTabViewItemIndex = i
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Live state the panes show

/// Status that is not a preference (hooks, permissions, login item), refreshed while a pane is visible.
final class LiveStatus: ObservableObject {
    @Published var hooks: HooksInstaller.Status = .absent
    @Published var terminals: [TerminalRow] = []
    @Published var notifications: UNAuthorizationStatus = .notDetermined
    @Published var login = false
    @Published var artCount = 0
    @Published var sessions = 0
    @Published var mapped = 0
    @Published var unmapped = 0
    private var timer: Timer?
    private var ticks = 0

    struct TerminalRow: Identifiable, Equatable {
        let id: String
        let name: String
        let health: AdapterHealth
        let sessions: Int
    }

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }
    deinit { timer?.invalidate() }

    func refresh() {
        hooks = HooksInstaller.status()
        // Adapter health runs tools (cmux socket-status…): every third refresh is plenty.
        if ticks % 3 == 0 { Terminals.shared.refreshHealth { [weak self] in self?.fillTerminals() } }
        ticks += 1
        fillTerminals()
        Notifier.shared.authorization { [weak self] s in self?.notifications = s }
        login = SMAppService.mainApp.status == .enabled
        artCount = max(0, SpriteLibrary.shared.sprites.count - 1)
        if let t = AppDelegate.shared?.tracker {
            sessions = t.liveSessionCount
            mapped = t.mappedCount
            unmapped = t.unmappedCount
        }
    }

    private func fillTerminals() {
        let counts = AppDelegate.shared?.tracker.sessionsByTerminal() ?? [:]
        let t = Terminals.shared
        let rows = t.adapters.map { a in
            TerminalRow(id: a.id, name: a.name,
                        health: t.healthByID[a.id] ?? AdapterHealth(level: .limited, detail: "Checking…"),
                        sessions: counts[a.id] ?? 0)
        } + [TerminalRow(id: t.fallback.id, name: t.fallback.name, health: t.fallback.health(), sessions: counts[t.fallback.id] ?? 0)]
        if rows != terminals { terminals = rows }
    }
}

// MARK: - Panes

struct GeneralPane: View {
    @StateObject private var live = LiveStatus()
    @AppStorage(Settings.Key.menuBarIcon) private var menuBarIcon = true
    @AppStorage(Settings.Key.menuBarCount) private var menuBarCount = true
    @AppStorage(Settings.Key.clickAction) private var clickAction = "open"
    @AppStorage(Settings.Key.hotKey) private var hotKey = true
    @AppStorage(Settings.Key.resumeCommand) private var resumeCommand = ""

    var body: some View {
        Form {
            Section {
                Toggle("Open Claws for Concern at login", isOn: Binding(get: { live.login }, set: { on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { AppLog.write("login item: \(error.localizedDescription)") }
                    live.refresh()
                }))
            }
            Section("Menu bar") {
                Toggle("Show the crab in the menu bar", isOn: $menuBarIcon)
                Toggle("Show how many sessions need you", isOn: $menuBarCount).disabled(!menuBarIcon)
                if !menuBarIcon {
                    Text("To get back here, open Claws for Concern again from Applications or Spotlight.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Clicking a Clawd") {
                Picker("Clicking a Clawd", selection: $clickAction) {
                    Text("Opens its session and dismisses it").tag("open")
                    Text("Only dismisses it").tag("dismiss")
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                Text("Right-click any Clawd for Open, Dismiss, Copy Recap and more. Drag one to move them all.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Keyboard shortcut") {
                Toggle("Jump to the session that most needs you", isOn: $hotKey)
                LabeledContent("Shortcut") { ShortcutRecorder().frame(width: 140, height: 24) }
                    .disabled(!hotKey)
            }
            Section {
                TextField("Resume command", text: $resumeCommand, prompt: Text("claude --resume {id}"))
                Text("“Copy Resume Command” puts `cd <folder> && <this>` on the clipboard. {id} becomes the session ID.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("Resuming") }
            Section {
                Button("Preview the Clawds") { AppDelegate.shared?.tracker.showDemo() }
            }
        }
        .formStyle(.grouped)
    }
}

struct ClawdsPane: View {
    @StateObject private var live = LiveStatus()
    @AppStorage(Settings.Key.showQuestions) private var questions = true
    @AppStorage(Settings.Key.showPermissions) private var permissions = true
    @AppStorage(Settings.Key.showPlans) private var plans = true
    @AppStorage(Settings.Key.showInput) private var input = true
    @AppStorage(Settings.Key.showFailed) private var failed = true
    @AppStorage(Settings.Key.showFinished) private var finished = true
    @AppStorage(Settings.Key.expireHours) private var expire = 12
    @AppStorage(Settings.Key.clearOnLook) private var clearOnLook = true
    @AppStorage(Settings.Key.lookSeconds) private var lookSeconds = 1.5
    @AppStorage(Settings.Key.maxClawds) private var maxClawds = 8
    @AppStorage(Settings.Key.sound) private var sound = false
    @AppStorage(Settings.Key.soundName) private var soundName = "Tink"
    @AppStorage(Settings.Key.notify) private var notify = false
    @AppStorage(Settings.Key.notifyFinished) private var notifyFinished = false

    static let sounds: [String] = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        let names = files.map { ($0 as NSString).deletingPathExtension }.sorted()
        return names.isEmpty ? ["Tink"] : names
    }()

    var body: some View {
        Form {
            Section("Show a Clawd when a session…") {
                Toggle("asks you a question", isOn: $questions)
                Toggle("needs a permission", isOn: $permissions)
                Toggle("has a plan for you to approve", isOn: $plans)
                Toggle("waits for other input, such as an MCP server's form", isOn: $input)
                Toggle("stops on an API error (rate limit, overload, sign-in)", isOn: $failed)
                Toggle("finishes while you are looking at something else", isOn: $finished)
                Picker("Forget unseen finished sessions after", selection: $expire) {
                    Text("1 hour").tag(1); Text("4 hours").tag(4); Text("12 hours").tag(12)
                    Text("24 hours").tag(24); Text("Never").tag(0)
                }
                .disabled(!finished)
            }
            Section {
                Toggle("Clear a Clawd once I've looked at its tab", isOn: $clearOnLook)
                Picker("After looking for", selection: $lookSeconds) {
                    Text("Half a second").tag(0.5); Text("A second and a half").tag(1.5); Text("Three seconds").tag(3.0)
                }
                .disabled(!clearOnLook)
            } header: { Text("When you look") } footer: {
                Text("Looking means the session's tab or pane is in front and you are typing or moving the pointer. herdr decides this itself. Needs your terminal's integration (Settings → Integrations).")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Stepper(value: $maxClawds, in: 3...20) { LabeledContent("Show at most", value: "\(maxClawds) Clawds") }
                Text("Any more wait behind a small +N chip; click it for the list.").font(.callout).foregroundStyle(.secondary)
            } header: { Text("Crowd control") }
            Section("Get my attention") {
                Toggle("Play a sound when a new Clawd appears", isOn: $sound)
                HStack {
                    Picker("Sound", selection: $soundName) { ForEach(ClawdsPane.sounds, id: \.self) { Text($0).tag($0) } }
                    Button { NSSound(named: NSSound.Name(soundName))?.play() } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.borderless).help("Play")
                }
                .disabled(!sound)
                Toggle("Show a notification", isOn: Binding(get: { notify }, set: { on in
                    notify = on
                    if on { Notifier.shared.requestAuthorization { _ in live.refresh() } }
                }))
                Toggle("Also for finished sessions", isOn: $notifyFinished).disabled(!notify)
                if notify && live.notifications == .denied {
                    HStack {
                        Label("Notifications are turned off for Claws for Concern.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Notification Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AppearancePane: View {
    @AppStorage(Settings.Key.size) private var size = "small"
    @AppStorage(Settings.Key.opacity) private var opacity = 1.0
    @AppStorage(Settings.Key.animate) private var animate = true
    @AppStorage(Settings.Key.shadows) private var shadows = true
    @AppStorage(Settings.Key.badges) private var badges = true
    @AppStorage(Settings.Key.blockedSprite) private var blockedSprite = "Waving"
    @AppStorage(Settings.Key.failedSprite) private var failedSprite = "CrabWalking"
    @AppStorage(Settings.Key.bubble) private var bubble = true
    @AppStorage(Settings.Key.hoverDelay) private var hoverDelay = 0.08
    @AppStorage(Settings.Key.bubbleTextSize) private var textSize = 12.0
    @AppStorage(Settings.Key.bubbleLines) private var lines = 3
    @AppStorage(Settings.Key.bubbleTitle) private var showTitle = true
    @AppStorage(Settings.Key.bubbleState) private var showState = true
    @AppStorage(Settings.Key.bubbleAge) private var showAge = true
    @State private var disabled: Set<String> = Settings.finishedDisabled

    private var sprites: [String] { SpriteLibrary.shared.sprites.keys.filter { $0 != SpriteLibrary.placeholder }.sorted() }
    private var artPoints: CGFloat { Settings.Size(rawValue: size)?.artPoints ?? 1 }

    var body: some View {
        Form {
            Section("Clawds") {
                Picker("Size", selection: $size) {
                    ForEach(Settings.Size.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                HStack(alignment: .bottom, spacing: 18) {
                    Spacer()
                    SpriteView(name: blockedSprite, artPoints: artPoints, animate: animate).id("b\(size)\(blockedSprite)\(animate)")
                    SpriteView(name: failedSprite, artPoints: artPoints, animate: animate).id("f\(size)\(failedSprite)\(animate)")
                    SpriteView(name: "JumpingHappy", artPoints: artPoints, animate: animate).id("j\(size)\(animate)")
                    Spacer()
                }
                .frame(height: 74)
                .opacity(opacity)
                Toggle("Animate", isOn: $animate)
                Toggle("Soft shadow", isOn: $shadows)
                Toggle("Badges (?, !, ✓, ×)", isOn: $badges)
                LabeledContent("Opacity") {
                    Slider(value: $opacity, in: 0.4...1) { EmptyView() } minimumValueLabel: { Text("40%") } maximumValueLabel: { Text("100%") }
                }
            }
            Section("Animations") {
                Picker("Needs you", selection: $blockedSprite) { ForEach(sprites, id: \.self) { Text($0).tag($0) } }
                Picker("Stopped on an error", selection: $failedSprite) { ForEach(sprites, id: \.self) { Text($0).tag($0) } }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Finished sessions pick from")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                        ForEach(sprites.filter { $0 != blockedSprite && $0 != failedSprite }, id: \.self) { name in
                            let on = !disabled.contains(name)
                            Button {
                                if on { disabled.insert(name) } else { disabled.remove(name) }
                                Settings.set(Array(disabled), Settings.Key.finishedDisabled)
                            } label: {
                                VStack(spacing: 4) {
                                    SpriteView(name: name, artPoints: 1, animate: on).frame(height: 40)
                                    Text(name).font(.caption).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity).padding(6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.accentColor.opacity(0.12) : Color.clear))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Color.accentColor : Color.secondary.opacity(0.3)))
                                .opacity(on ? 1 : 0.45)
                            }
                            .buttonStyle(.plain)
                            .help(on ? "Click to leave \(name) out" : "Click to use \(name)")
                        }
                    }
                }
            }
            Section("Thought bubble") {
                Toggle("Show a bubble when I hover a Clawd", isOn: $bubble)
                Group {
                    LabeledContent("Hover delay") {
                        Slider(value: $hoverDelay, in: 0...1, step: 0.05) { EmptyView() }
                            minimumValueLabel: { Text("None") } maximumValueLabel: { Text("1 s") }
                    }
                    Picker("Text size", selection: $textSize) { Text("11 pt").tag(11.0); Text("12 pt").tag(12.0); Text("13 pt").tag(13.0) }
                        .pickerStyle(.segmented)
                    Stepper(value: $lines, in: 1...4) { LabeledContent("Recap lines", value: "\(lines)") }
                    Toggle("Session title", isOn: $showTitle)
                    Toggle("State (has a question, done…)", isOn: $showState)
                    Toggle("How long ago", isOn: $showAge)
                    BubblePreview(key: "\(textSize)\(lines)\(showTitle)\(showState)\(showAge)").frame(height: 96)
                }
                .disabled(!bubble)
            }
        }
        .formStyle(.grouped)
    }
}

struct PositionPane: View {
    @AppStorage(Settings.Key.screen) private var screen = "follow"
    @AppStorage(Settings.Key.corner) private var corner = "bottomLeft"
    @AppStorage(Settings.Key.snap) private var snap = true
    @AppStorage(Settings.Key.lockPosition) private var lock = false
    @AppStorage(Settings.Key.avoidDock) private var avoidDock = false
    @AppStorage(Settings.Key.edgeMargin) private var margin = 8.0
    @AppStorage(Settings.Key.spacing) private var spacing = 3.0
    @State private var arranged = Placements.all.count

    var body: some View {
        Form {
            Section("Display") {
                Picker("Show the Clawds on", selection: $screen) {
                    Text("The display I'm using").tag("follow")
                    Text("The main display").tag("primary")
                    Divider()
                    ForEach(NSScreen.screens, id: \.self) { s in
                        Text(s.localizedName).tag("display:\(Placements.displayKey(s))")
                    }
                }
                Text("“The display I'm using” follows your pointer, after a moment so passing through does not move them.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                CornerPicker(corner: $corner).frame(height: 132)
            } header: { Text("Default spot") } footer: {
                Text("For displays you have not arranged yourself.").font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Snap to corners and edges", isOn: $snap)
                Toggle("Keep clear of the Dock", isOn: $avoidDock)
                    .help("Off: the Clawds can sit right in the display's corners, over the Dock's strip. The menu bar is always kept clear.")
                Toggle("Lock position", isOn: $lock)
                LabeledContent("Distance from the edge") {
                    Slider(value: $margin, in: 0...40, step: 1) { EmptyView() } minimumValueLabel: { Text("0") } maximumValueLabel: { Text("40") }
                }
                LabeledContent("Space between Clawds") {
                    Slider(value: $spacing, in: 0...12, step: 1) { EmptyView() } minimumValueLabel: { Text("0") } maximumValueLabel: { Text("12") }
                }
                HStack {
                    Text(arranged == 0 ? "No display has its own spot yet." : "\(arranged) display\(arranged == 1 ? " has" : "s have") a spot of \(arranged == 1 ? "its" : "their") own.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset All Displays") { Placements.resetAll(); arranged = 0 }.disabled(arranged == 0)
                }
            } header: { Text("Arranging") } footer: {
                Text("Drag any Clawd to move the whole row. Each display remembers its own spot. The first Clawd stays where you put it; the rest grow to the right, or to the left when there is no room.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { arranged = Placements.all.count }
    }
}

struct RecapsPane: View {
    @AppStorage(Settings.Key.recaps) private var recaps = true
    @AppStorage(Settings.Key.recapModel) private var model = "haiku"
    @AppStorage(Settings.Key.recapLength) private var length = "normal"
    @AppStorage(Settings.Key.recapInstructions) private var instructions = ""
    @AppStorage(Settings.Key.claudePath) private var claudePath = ""
    @State private var sample = "I fixed the flaky login test by waiting for the auth cookie, ran the suite 20 times with no failures, and pushed fix/login-flake. Should the PR go to main or release-2.4?"
    @State private var result = ""
    @State private var running = false

    var body: some View {
        Form {
            Section {
                Toggle("Write a one-line recap of where each session stopped", isOn: $recaps)
                Group {
                    Picker("Model", selection: $model) {
                        Text("Claude Haiku (fast)").tag("haiku")
                        Text("Claude Sonnet (more careful)").tag("sonnet")
                    }
                    Picker("Length", selection: $length) {
                        Text("Short").tag("short"); Text("Normal").tag("normal"); Text("Long").tag("long")
                    }
                    .pickerStyle(.segmented)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your own instructions")
                        TextEditor(text: $instructions)
                            .font(.body).frame(height: 54)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.25)))
                        Text("For example: “Name the branch when there is one.”").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .disabled(!recaps)
            } footer: {
                Text("Recaps go through the Claude Code on this Mac and its sign-in: no API key. Claude's last message of a turn is sent, like any Claude Code request. Changing these settings writes fresh recaps.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Try it") {
                TextEditor(text: $sample).font(.callout).frame(height: 64)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.25)))
                HStack {
                    Button(running ? "Writing…" : "Write a Recap") { test() }.disabled(running || !recaps)
                    if running { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if !result.isEmpty { Text(result).textSelection(.enabled) }
            }
            Section("Claude Code") {
                LabeledContent("Found at", value: Summarizer.claudePath ?? "not found")
                TextField("Use a different claude", text: $claudePath, prompt: Text("/path/to/claude (optional)"))
                Button("Clear Saved Recaps") { AppDelegate.shared?.tracker.clearRecaps() }
            }
        }
        .formStyle(.grouped)
    }

    private func test() {
        running = true
        result = ""
        let text = "Claude's final message for this turn:\n\n" + sample
        DispatchQueue.global().async {
            let start = Date()
            let line = Summarizer.shared.runSync(text)
            let secs = Date().timeIntervalSince(start)
            DispatchQueue.main.async {
                running = false
                result = line.map { "“\($0)”  (\(String(format: "%.1f", secs)) s)" }
                    ?? "Could not write a recap: \(Summarizer.shared.lastError ?? "unknown error")"
            }
        }
    }
}

struct IntegrationsPane: View {
    @StateObject private var live = LiveStatus()

    var body: some View {
        Form {
            Section {
                StatusRow(ok: live.hooks == .installed, title: hooksTitle,
                          detail: "Watching \(live.sessions) Claude Code session\(live.sessions == 1 ? "" : "s").")
                HStack {
                    switch live.hooks {
                    case .installed: Button("Remove Hooks…") { AppDelegate.removeHooksInteractively(); live.refresh() }
                    case .outdated: Button("Repair Hooks") { AppDelegate.installHooksInteractively(quiet: true); live.refresh() }
                    case .absent: Button("Install Hooks") { AppDelegate.installHooksInteractively(quiet: true); live.refresh() }
                    }
                    Spacer()
                    Button("Show settings.json") { NSWorkspace.shared.activateFileViewerSelecting([HooksInstaller.settingsURL]) }
                }
            } header: { Text("Claude Code") } footer: {
                Text("A few hooks in ~/.claude/settings.json run a tiny program that records each session's state. A backup is saved whenever the file changes, and removing them restores it exactly.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                ForEach(live.terminals) { row in TerminalRowView(row: row) { live.refresh() } }
            } header: { Text("Terminals") } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Every terminal gets Clawds and recaps: they come from Claude Code itself. A terminal integration adds finding the session's pane, clearing its Clawd when you look, and jumping there on click.")
                    Link("Yours is missing? Add it in one file →", destination: URL(string: "https://github.com/patildhruv/claws-for-concern/blob/main/docs/adapters.md")!)
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                StatusRow(ok: live.artCount > 0, title: live.artCount > 0 ? "\(live.artCount) Clawd animations ready" : "Clawd art not downloaded yet",
                          detail: "Downloaded once from claude.ai and turned into tiny pixel-exact sprites on this Mac.")
                HStack {
                    Button("Download Again") {
                        try? FileManager.default.removeItem(at: Paths.art)
                        AppDelegate.fetchArt()
                    }
                    Button("Edit Extra Art List…") { Self.openExtraArt() }
                    Spacer()
                }
            } header: { Text("Clawd art") }
        }
        .formStyle(.grouped)
    }

    private var hooksTitle: String {
        switch live.hooks {
        case .installed: return "Hooks installed"
        case .outdated(let why): return "Hooks need repair: \(why)"
        case .absent: return "Hooks not installed"
        }
    }

    static func openExtraArt() {
        let url = Paths.extraArt
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: Paths.root, withIntermediateDirectories: true)
            try? "# More official Clawd GIFs for finished sessions: one claude.ai URL per line.\n".write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }
}

struct AdvancedPane: View {
    @State private var confirmReset = false
    @State private var confirmUninstall = false

    var body: some View {
        Form {
            Section("Files") {
                LabeledContent("Data folder") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.root]) }
                }
                LabeledContent("Log") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.log]) }
                }
            }
            Section {
                Button("Reset All Settings…") { confirmReset = true }
                    .confirmationDialog("Reset every setting, including each display's spot?", isPresented: $confirmReset) {
                        Button("Reset", role: .destructive) { Settings.resetAll() }
                    }
                Button("Uninstall…", role: .destructive) { confirmUninstall = true }
                    .confirmationDialog("Remove the hooks and quit?", isPresented: $confirmUninstall) {
                        Button("Remove Hooks and Quit", role: .destructive) { AppDelegate.uninstall() }
                    } message: {
                        Text("Claude Code goes back to exactly how it was. Then drag Claws for Concern to the Trash.")
                    }
            } header: { Text("Start over") }
        }
        .formStyle(.grouped)
    }
}

struct AboutPane: View {
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 112, height: 112)
            Text("Claws for Concern").font(.system(size: 26, weight: .semibold))
            Text("Version \(version)").foregroundStyle(.secondary)
            Text("Tiny Clawds for the Claude Code sessions that need you.").font(.title3)
            HStack(spacing: 18) {
                Link("GitHub", destination: URL(string: "https://github.com/patildhruv/claws-for-concern")!)
                Link("Report a Problem", destination: URL(string: "https://github.com/patildhruv/claws-for-concern/issues")!)
            }
            Spacer()
            Text("An unofficial fan project, not affiliated with Anthropic. Clawd is Anthropic's character; its art is downloaded from claude.ai on this Mac and never redistributed. MIT licensed.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 60)
            Spacer().frame(height: 18)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Pieces

/// One terminal integration: status, sessions, and the fix it needs if any.
struct TerminalRowView: View {
    let row: LiveStatus.TerminalRow
    let changed: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.title3).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name).fontWeight(.medium)
                    if row.sessions > 0 {
                        Text("\(row.sessions) session\(row.sessions == 1 ? "" : "s")")
                            .font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
                Text(row.health.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let fix = row.health.fix { fixButton(fix) }
            }
            Spacer(minLength: 0)
        }
        .opacity(row.health.level == .unavailable ? 0.6 : 1)
    }

    private var icon: String {
        switch row.health.level {
        case .ready: return "checkmark.circle.fill"
        case .limited: return "exclamationmark.triangle.fill"
        case .unavailable: return "minus.circle"
        }
    }
    private var color: Color {
        switch row.health.level {
        case .ready: return .green
        case .limited: return .orange
        case .unavailable: return .secondary
        }
    }

    @ViewBuilder private func fixButton(_ fix: AdapterHealth.Fix) -> some View {
        switch fix {
        case .allowAutomation:
            Button("Allow Access…") {
                if let a = Terminals.shared.adapter(id: row.id) { Terminals.shared.requestPermission(a) { changed() } }
            }
        case .openAutomationSettings:
            Button("Open Automation Settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
            }
        case let .openApp(bundleID, label):
            Button(label) {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }
            }
        }
    }
}

struct StatusRow: View {
    let ok: Bool
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// A miniature screen with the four corners as buttons.
struct CornerPicker: View {
    @Binding var corner: String
    var body: some View {
        HStack {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12))
                RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.35))
                VStack(spacing: 0) {
                    Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 8)  // menu bar
                    Spacer()
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                ForEach(Settings.Corner.allCases) { c in
                    Button { corner = c.rawValue } label: {
                        Image(nsImage: NSImage(cgImage: PixelCrab.image(cell: 2, body: PixelCrab.clay, eyes: PixelCrab.ink),
                                               size: NSSize(width: 22, height: 16)))
                            .opacity(corner == c.rawValue ? 1 : 0.28)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(corner == c.rawValue ? Color.accentColor.opacity(0.18) : .clear))
                    }
                    .buttonStyle(.plain)
                    .help(c.label)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(c))
                    .padding(.top, c.isBottom ? 0 : 8)
                }
            }
            .frame(width: 200, height: 124)
            Spacer()
        }
    }
    private func alignment(_ c: Settings.Corner) -> Alignment {
        switch c {
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        }
    }
}

/// An animated Clawd at its real on-screen size.
struct SpriteView: NSViewRepresentable {
    let name: String
    let artPoints: CGFloat
    let animate: Bool

    func makeNSView(context: Context) -> NSView {
        let v = SpriteHost()
        v.configure(name: name, artPoints: artPoints, animate: animate)
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        (v as? SpriteHost)?.configure(name: name, artPoints: artPoints, animate: animate)
    }

    final class SpriteHost: NSView {
        private let sprite = CALayer()
        private var size = CGSize(width: 24, height: 17)
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            sprite.magnificationFilter = .nearest
            sprite.contentsGravity = .resize
            layer?.addSublayer(sprite)
        }
        required init?(coder: NSCoder) { fatalError() }
        override var intrinsicContentSize: NSSize { size }

        func configure(name: String, artPoints: CGFloat, animate: Bool) {
            guard let sp = SpriteLibrary.shared[name] else { return }
            size = CGSize(width: CGFloat(sp.width) * artPoints, height: CGFloat(sp.height) * artPoints)
            invalidateIntrinsicContentSize()
            sprite.removeAllAnimations()
            sprite.contents = sp.frames.first
            if animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { sprite.add(sp.animation(), forKey: "frames") }
            needsLayout = true
        }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            sprite.frame = CGRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: size.height)
            CATransaction.commit()
        }
    }
}

/// The real bubble view, with a sample session, rebuilt whenever `key` changes.
struct BubblePreview: NSViewRepresentable {
    let key: String
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ host: NSView, context: Context) {
        host.subviews.forEach { $0.removeFromSuperview() }
        let a = Alert(sessionId: "preview", kind: .blocked, blockedKind: "question", ts: Date().timeIntervalSince1970 - 130,
                      title: "Fix flaky login test", folder: "webapp",
                      recap: "Login fix verified with 20 green runs; PR to main or release-2.4?",
                      recapPending: false, sprite: "Waving", mapped: true)
        let v = BubblePanel.makeView(a, anchorX: 40)
        v.setFrameOrigin(NSPoint(x: 0, y: 0))
        host.addSubview(v)
    }
}

/// Click, then press the new shortcut. Esc cancels.
struct ShortcutRecorder: NSViewRepresentable {
    func makeNSView(context: Context) -> RecorderButton { RecorderButton() }
    func updateNSView(_ v: RecorderButton, context: Context) { v.refresh() }

    final class RecorderButton: NSButton {
        private var recording = false { didSet { refresh() } }
        override init(frame: NSRect) {
            super.init(frame: frame)
            bezelStyle = .rounded
            target = self
            action = #selector(toggle)
            refresh()
        }
        required init?(coder: NSCoder) { fatalError() }
        override var acceptsFirstResponder: Bool { true }

        func refresh() {
            title = recording ? "Type a shortcut…" : HotKey.describe(keyCode: Settings.hotKeyCode, modifiers: Settings.hotKeyMods)
        }
        @objc private func toggle() {
            recording.toggle()
            if recording { window?.makeFirstResponder(self) }
        }
        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            if event.keyCode == 53 { recording = false; return }  // Esc
            let mods = HotKey.carbon(event.modifierFlags.intersection([.command, .option, .control, .shift]))
            // A global shortcut needs Command, Option or Control.
            guard mods & ~UInt32(shiftKeyMask) != 0 else { NSSound.beep(); return }
            Settings.set(Int(event.keyCode), Settings.Key.hotKeyCode)
            Settings.set(Int(mods), Settings.Key.hotKeyMods)
            recording = false
        }
        override func resignFirstResponder() -> Bool { recording = false; return super.resignFirstResponder() }
    }
}

private let shiftKeyMask = 1 << 9
