import AppKit
import ServiceManagement

/// The menu bar crab: a count of sessions waiting on you, and every setting.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let tracker: Tracker
    private let menu = NSMenu()
    var onPreview: (() -> Void)?

    init(tracker: Tracker) {
        self.tracker = tracker
        super.init()
        item.button?.image = PixelCrab.menuBarImage()
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = "Claws for Concern"
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refresh()
    }

    func refresh() {
        let n = tracker.alerts.count
        item.button?.title = n > 0 ? " \(n)" : ""
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let alerts = tracker.alerts
        let header = NSMenuItem(title: alerts.isEmpty ? "No sessions need you" :
                                    "\(alerts.count) session\(alerts.count == 1 ? "" : "s") need\(alerts.count == 1 ? "s" : "") you",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for a in alerts.prefix(12) {
            let it = BlockItem(a.title) { [weak self] in self?.tracker.open(a.sessionId) }
            let sub = NSMutableAttributedString(string: a.title + "\n", attributes: [.font: NSFont.menuFont(ofSize: 13)])
            sub.append(NSAttributedString(string: "\(BubbleView.stateWord(a)) · \(BubbleView.age(a.ts)) — \(a.recap)",
                                          attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            it.attributedTitle = sub
            it.image = SpriteLibrary.shared[a.sprite].map { NSImage(cgImage: $0.frames[0], size: NSSize(width: CGFloat($0.width) * 0.75, height: CGFloat($0.height) * 0.75)) }
            menu.addItem(it)
        }
        if !alerts.isEmpty {
            let jump = BlockItem("Jump to the Most Urgent") { [weak self] in self?.tracker.openMostUrgent() }
            if Settings.hotKey {
                jump.keyEquivalent = "c"
                jump.keyEquivalentModifierMask = [.control, .option, .command]
            }
            menu.addItem(jump)
            menu.addItem(BlockItem("Dismiss All") { [weak self] in self?.tracker.acknowledgeAll() })
        }
        menu.addItem(.separator())

        let show = NSMenu()
        show.addItem(BlockItem("Sessions That Need You", state: Settings.showBlocked ? .on : .off) { Settings.showBlocked.toggle() })
        show.addItem(BlockItem("Finished While You Were Away", state: Settings.showFinished ? .on : .off) { Settings.showFinished.toggle() })
        show.addItem(BlockItem("Stopped on an Error", state: Settings.showFailed ? .on : .off) { Settings.showFailed.toggle() })
        show.addItem(.separator())
        let hideTitle = NSMenuItem(title: "Forget Unseen Finished Sessions After", action: nil, keyEquivalent: "")
        hideTitle.isEnabled = false
        show.addItem(hideTitle)
        for h in [1, 4, 12, 24, 0] {
            show.addItem(BlockItem(h == 0 ? "Never" : "\(h) hour\(h == 1 ? "" : "s")", state: Settings.expireHours == h ? .on : .off) {
                Settings.expireHours = h
            })
        }
        menu.addItem(submenu("Show", show))

        let look = NSMenu()
        for s in Settings.Size.allCases {
            look.addItem(BlockItem(s.label, state: Settings.size == s ? .on : .off) { Settings.size = s })
        }
        look.addItem(.separator())
        for c in Settings.Corner.allCases {
            look.addItem(BlockItem(c.label, state: Settings.corner == c ? .on : .off) { Settings.corner = c })
        }
        look.addItem(.separator())
        for s in Settings.ScreenChoice.allCases {
            look.addItem(BlockItem(s.label, state: Settings.screen == s ? .on : .off) { Settings.screen = s })
        }
        menu.addItem(submenu("Size and Position", look))

        menu.addItem(BlockItem("One-Line Recaps by Claude Haiku", state: Settings.recaps ? .on : .off) { Settings.recaps.toggle() })
        menu.addItem(BlockItem("Preview the Clawds", key: "p") { [weak self] in self?.onPreview?() })
        menu.addItem(.separator())

        menu.addItem(submenu("Setup", setupMenu()))
        menu.addItem(BlockItem("Quit Claws for Concern", key: "q") { NSApp.terminate(nil) })
    }

    private func setupMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        switch HooksInstaller.status() {
        case .installed:
            m.addItem(disabled("Claude Code hooks: installed"))
            m.addItem(BlockItem("Remove Hooks…") { AppDelegate.removeHooksInteractively() })
        case .outdated(let why):
            m.addItem(disabled("Claude Code hooks: \(why)"))
            m.addItem(BlockItem("Repair Hooks") { AppDelegate.installHooksInteractively() })
        case .absent:
            m.addItem(disabled("Claude Code hooks: not installed"))
            m.addItem(BlockItem("Install Hooks…") { AppDelegate.installHooksInteractively() })
        }
        m.addItem(.separator())
        let perm = Ghostty.shared.permission
        Ghostty.shared.refreshPermission()  // for next time the menu opens
        let permText: String = [.granted: "allowed", .denied: "denied", .undetermined: "not asked yet",
                                .notRunning: "Ghostty is not running"][perm]!
        m.addItem(disabled("Ghostty tab access: \(permText)"))
        if perm == .undetermined {
            m.addItem(BlockItem("Allow Ghostty Tab Access…") { AppDelegate.askGhosttyPermission() })
        }
        if perm == .denied {
            m.addItem(BlockItem("Open Automation Settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
            })
        }
        if tracker.unmappedCount > 0 {
            m.addItem(disabled("\(tracker.unmappedCount) Clawd\(tracker.unmappedCount == 1 ? "" : "s") not yet matched to a tab"))
        }
        m.addItem(.separator())
        m.addItem(BlockItem("Keyboard Shortcut ⌃⌥⌘C", state: Settings.hotKey ? .on : .off) { Settings.hotKey.toggle() })
        let login = SMAppService.mainApp.status == .enabled
        m.addItem(BlockItem("Open at Login", state: login ? .on : .off) {
            do { if login { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() } }
            catch { AppLog.write("login item: \(error.localizedDescription)") }
        })
        if !SpriteLibrary.shared.hasArt {
            m.addItem(BlockItem("Download Clawd Art Again") { AppDelegate.fetchArt() })
        }
        m.addItem(.separator())
        if let err = Summarizer.shared.lastError { m.addItem(disabled("Last recap error: \(err.prefix(60))")) }
        m.addItem(disabled("Watching \(tracker.liveSessionCount) Claude Code session\(tracker.liveSessionCount == 1 ? "" : "s")"))
        m.addItem(BlockItem("Show Log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.log]) })
        m.addItem(BlockItem("About Claws for Concern") { StatusMenu.showAbout() })
        return m
    }

    static func showAbout() {
        let credits = NSMutableAttributedString()
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
                                                   .paragraphStyle: center]
        credits.append(NSAttributedString(string: "Tiny Clawds for the Claude Code sessions that need you.\n\n", attributes: body))
        credits.append(NSAttributedString(string: "github.com/patildhruv/claws-for-concern",
                                          attributes: body.merging([.link: URL(string: "https://github.com/patildhruv/claws-for-concern")!]) { $1 }))
        credits.append(NSAttributedString(string: "\n\nAn unofficial fan project. Clawd is Anthropic's character; " +
                                          "its art is downloaded from claude.ai on this Mac.", attributes: body))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = sub
        return it
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }
}
