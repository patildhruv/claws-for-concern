import AppKit
import ServiceManagement

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst()).filter { $0.hasPrefix("--") || !$0.hasPrefix("-") }
        if let cmd = args.first {
            exit(CLI.run(cmd, Array(args.dropFirst())))
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    let tracker = Tracker()
    private var overlay: OverlayController!
    private var status: StatusMenu!
    private var jumpKey: HotKey?
    private var jumpKeyCombo: (UInt32, UInt32)?
    private var settingsWindow: SettingsWindowController?
    private var settingsPostPending = false

    func applicationDidFinishLaunching(_ n: Notification) {
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0.processIdentifier != me.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        AppDelegate.shared = self
        try? FileManager.default.createDirectory(at: Paths.sessions, withIntermediateDirectories: true)
        // 1.0 stored "mouse" for what is now "follow".
        if UserDefaults.standard.string(forKey: Settings.Key.screen) == "mouse" { Settings.set("follow", Settings.Key.screen) }
        NSApp.mainMenu = AppDelegate.makeMainMenu()
        overlay = OverlayController(tracker: tracker)
        status = StatusMenu(tracker: tracker)
        status.onPreview = { [weak self] in self?.tracker.showDemo() }
        tracker.onChange = { [weak self] alerts in
            self?.overlay.update(alerts)
            self?.status.refresh()
        }
        Terminals.shared.start()
        tracker.start()
        updateHotKey()
        Notifier.shared.setUp()
        // `ClawsForConcern --open-settings <tab>` from a script or the docs tooling.
        DistributedNotificationCenter.default().addObserver(forName: AppDelegate.openSettingsNote, object: nil,
                                                            queue: .main) { [weak self] note in
            self?.openSettings(tab: note.object as? String)
        }
        Notifier.shared.onOpen = { [weak self] sid in self?.tracker.open(sid) }
        // Every defaults change (Settings window, menus, drags) becomes one coalesced .settingsChanged.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.settingsPostPending else { return }
            self.settingsPostPending = true
            DispatchQueue.main.async {
                self.settingsPostPending = false
                NotificationCenter.default.post(name: .settingsChanged, object: nil)
            }
        }
        NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateHotKey()
            self?.status.refresh()
        }
        AppDelegate.fetchArt()

        // Hooks pointing at a copy of the app that is gone (moved, renamed): fix quietly. A second
        // copy that still exists (a dev build) is left alone; Settings offers Repair instead.
        if case .outdated = HooksInstaller.status(), HooksInstaller.pointsAtMissingCopy { _ = try? HooksInstaller.install() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.firstRun() }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                          object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let id = app?.bundleIdentifier,
                  Terminals.shared.adapters.contains(where: { $0.scriptedBundleID == id }) else { return }
            // A terminal that was not running when we checked: learn whether we may script it now.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if id == GhosttyAdapter.bundleID { AppDelegate.askGhosttyPermissionIfNeeded() } else { Terminals.shared.refreshHealth() }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again while it runs (the way back when the menu bar crab is hidden).
        openSettings()
        return false
    }

    static let openSettingsNote = Notification.Name("io.github.patildhruv.claws-for-concern.openSettings")

    func openSettings(tab: String? = nil) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController()
            settingsWindow?.onClose = {
                // Back to a menu bar app: no Dock icon once Settings is closed.
                DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
            }
        }
        // While Settings is open the app is a regular app: Dock icon, ⌘-Tab, menu bar.
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.show(tab: tab)
    }

    /// The menu bar shown while Settings is open. Edit makes copy and paste work in the text fields.
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            it.submenu = m
            main.addItem(it)
        }
        func item(_ t: String, _ a: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            return i
        }
        sub("Claws for Concern", [
            BlockItem("About Claws for Concern") { AppDelegate.shared?.openSettings(tab: "about") },
            .separator(),
            BlockItem("Settings…", key: ",") { AppDelegate.shared?.openSettings() },
            .separator(),
            item("Hide Claws for Concern", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit Claws for Concern", #selector(NSApplication.terminate(_:)), "q"),
        ])
        sub("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        sub("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        return main
    }

    /// Settings → Advanced → Uninstall: hooks out, login item off, quit.
    static func uninstall() {
        do { try HooksInstaller.remove() } catch { AppLog.write("uninstall: \(error)") }
        try? SMAppService.mainApp.unregister()
        NSApp.terminate(nil)
    }

    private func updateHotKey() {
        let combo = (Settings.hotKeyCode, Settings.hotKeyMods)
        guard Settings.hotKey else { jumpKey = nil; jumpKeyCombo = nil; return }
        if jumpKey != nil, let c = jumpKeyCombo, c == combo { return }
        jumpKey = nil
        jumpKey = HotKey(keyCode: combo.0, modifiers: combo.1) { [weak self] in self?.tracker.openMostUrgent() }
        jumpKeyCombo = jumpKey == nil ? nil : combo
        if jumpKey == nil { AppLog.write("hotkey: \(HotKey.describe(keyCode: combo.0, modifiers: combo.1)) is taken by another app") }
    }

    private func firstRun() {
        if !Settings.didAskHooks, HooksInstaller.status() == .absent {
            Settings.didAskHooks = true
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Let the Clawds watch your Claude Code sessions?"
            a.informativeText = """
            Claws for Concern adds a few hooks to ~/.claude/settings.json (a backup is saved next to it). \
            They run a tiny program that records each session's status on this Mac. \
            The one-line recaps are written by Claude Haiku through your own Claude Code login.
            """
            a.addButton(withTitle: "Install Hooks")
            a.addButton(withTitle: "Not Now")
            let login = NSButton(checkboxWithTitle: "Open Claws for Concern at login", target: nil, action: nil)
            login.state = .on
            a.accessoryView = login
            if a.runModal() == .alertFirstButtonReturn {
                AppDelegate.installHooksInteractively(quiet: true)
                if login.state == .on { try? SMAppService.mainApp.register() }
            }
        }
        AppDelegate.askGhosttyPermissionIfNeeded()
    }

    static func fetchArt() {
        Art.fetchMissing { added, failed in
            if !added.isEmpty {
                SpriteLibrary.shared.reload()
                NotificationCenter.default.post(name: .settingsChanged, object: nil)
            }
            if !failed.isEmpty { AppLog.write("art: missing \(failed.joined(separator: ", "))") }
        }
    }

    static func askGhosttyPermissionIfNeeded() {
        // Ghostty is the terminal most people here use: ask up front. iTerm2 and Terminal are asked
        // the first time one of their sessions gets a Clawd.
        let t = Terminals.shared
        guard let g = t.adapter(id: "ghostty") else { return }
        t.refreshHealth {
            if Automation.cached(GhosttyAdapter.bundleID) == .undetermined { t.requestPermission(g) }
        }
    }

    static func askGhosttyPermission() {
        if let g = Terminals.shared.adapter(id: "ghostty") { Terminals.shared.requestPermission(g) }
    }

    static func installHooksInteractively(quiet: Bool = false) {
        do {
            let backup = try HooksInstaller.install()
            guard !quiet else { return }
            let a = NSAlert()
            a.messageText = "Hooks installed"
            a.informativeText = "Running Claude Code sessions pick them up automatically."
                + (backup.map { "\n\nBackup: \($0.path)" } ?? "")
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
        }
    }

    static func removeHooksInteractively() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Remove Claws for Concern's hooks?"
        a.informativeText = "Only its own entries in ~/.claude/settings.json are removed. The Clawds stop appearing until you install them again."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do { try HooksInstaller.remove() } catch { NSAlert(error: error).runModal() }
    }
}

/// `ClawsForConcern --<command>` for scripting and the self-test.
enum CLI {
    static func run(_ cmd: String, _ rest: [String]) -> Int32 {
        switch cmd {
        case "--install-hooks":
            do {
                let b = try HooksInstaller.install()
                print("installed hooks -> \(HooksInstaller.hookPath)" + (b.map { "\nbackup: \($0.path)" } ?? ""))
                return 0
            } catch { print("error: \(error)"); return 1 }
        case "--remove-hooks":
            do { try HooksInstaller.remove(); print("removed"); return 0 } catch { print("error: \(error)"); return 1 }
        case "--hooks-status":
            print(HooksInstaller.status()); return 0
        case "--fetch-art":
            let sem = DispatchSemaphore(value: 0)
            var code: Int32 = 0
            DispatchQueue.global().async {
                Art.fetchMissing { added, failed in
                    print("added: \(added.sorted().joined(separator: ", "))")
                    if !failed.isEmpty { print("failed: \(failed.joined(separator: ", "))"); code = 1 }
                    for (k, m) in Art.loadMeta().sorted(by: { $0.key < $1.key }) {
                        print("  \(k.padding(toLength: 14, withPad: " ", startingAt: 0)) \(m.frames) frames  \(m.w)x\(m.h) at (\(m.x),\(m.y))  \(m.delays.reduce(0, +)) ms")
                    }
                    sem.signal()
                }
            }
            while sem.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return code
        case "--recap":
            // Same code path the app uses; handy for checking the Claude Code login works.
            let text = rest.isEmpty ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) : rest.joined(separator: " ")
            let start = Date()
            if let line = Summarizer.shared.runSync(text) {
                print(line); print(String(format: "(%.1f s)", Date().timeIntervalSince(start))); return 0
            }
            print("error: \(Summarizer.shared.lastError ?? "unknown")"); return 1
        case "--selftest":
            return SelfTest.run()
        case "--open-settings":
            DistributedNotificationCenter.default().postNotificationName(AppDelegate.openSettingsNote, object: rest.first,
                                                                         userInfo: nil, deliverImmediately: true)
            return 0
        case "--terminals":
            return Diagnostics.terminals()
        case "--open-session":
            return Diagnostics.open(rest.first ?? "")
        case "--displays":
            _ = NSApplication.shared
            let saved = Placements.all
            for s in NSScreen.screens {
                let key = Placements.displayKey(s)
                let p = saved[key].map { $0.corner ?? String(format: "free %.3f, %.3f", $0.fx, $0.fy) } ?? "default (\(Settings.corner.label))"
                print("\(s.localizedName)  \(key)  \(Int(s.frame.width))x\(Int(s.frame.height))  spot: \(p)")
            }
            return 0
        case "--snapshot-settings":
            return Snapshot.settings(outDir: rest.first ?? "screenshots")
        case "--snapshot":
            return Snapshot.run(outDir: rest.first ?? "screenshots")
        case "--version":
            print(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"); return 0
        default:
            print("""
            Claws for Concern — tiny Clawds for Claude Code sessions that need you.
              (no arguments)    run the menu bar app
              --install-hooks   add the hooks to ~/.claude/settings.json (backup saved)
              --remove-hooks    remove them again
              --hooks-status    installed / outdated / absent
              --fetch-art       download and convert the Clawd art now
              --recap TEXT      write a one-line recap of TEXT the way the app does
              --terminals       which terminal each live session is in, its pane, and what you are looking at
              --open-session ID jump to a session the way a click does (ID prefix is enough)
              --displays        list displays and each one's saved spot
              --open-settings [TAB]  open the running app's Settings (general, clawds, appearance, …)
              --selftest        run the built-in checks (prints ALL PASS)
              --snapshot DIR    render the README images into DIR
            """)
            return cmd == "--help" ? 0 : 2
        }
    }
}
