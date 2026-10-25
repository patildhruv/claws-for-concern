import AppKit

/// The menu bar crab: how many sessions need you, the sessions themselves, and quick actions.
/// Everything configurable lives in the Settings window.
final class StatusMenu: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let tracker: Tracker
    private let menu = NSMenu()
    var onPreview: (() -> Void)?

    init(tracker: Tracker) {
        self.tracker = tracker
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        refresh()
    }

    /// Creates or removes the status item to match the settings, and updates the count.
    func refresh() {
        if !Settings.menuBarIcon {
            if let item { NSStatusBar.system.removeStatusItem(item); self.item = nil }
            return
        }
        if item == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            it.button?.image = PixelCrab.menuBarImage()
            it.button?.imagePosition = .imageLeading
            it.button?.setAccessibilityLabel("Claws for Concern")
            it.menu = menu
            item = it
        }
        let n = tracker.alerts.count
        let paused = Settings.pausedUntil != nil
        item?.button?.title = Settings.menuBarCount && n > 0 && !paused ? " \(n)" : ""
        item?.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        item?.button?.appearsDisabled = paused
        item?.button?.toolTip = paused ? "Claws for Concern (paused)" : "Claws for Concern"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let alerts = tracker.alerts
        if let until = Settings.pausedUntil {
            let f = DateFormatter()
            f.timeStyle = .short
            f.dateStyle = Calendar.current.isDateInToday(until) ? .none : .short
            menu.addItem(disabled("Paused until \(f.string(from: until))"))
            menu.addItem(BlockItem("Resume Now") { Settings.pausedUntil = nil })
            menu.addItem(.separator())
        }
        menu.addItem(disabled(alerts.isEmpty ? "No sessions need you"
                              : "\(alerts.count) session\(alerts.count == 1 ? "" : "s") need\(alerts.count == 1 ? "s" : "") you"))
        for a in alerts.prefix(12) {
            let it = BlockItem(a.title) { [weak self] in self?.tracker.open(a.sessionId) }
            let text = NSMutableAttributedString(string: a.title + "\n", attributes: [.font: NSFont.menuFont(ofSize: 13)])
            text.append(NSAttributedString(string: "\(BubbleView.stateWord(a)) · \(BubbleView.age(a.ts)) — \(a.recap)",
                                           attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            it.attributedTitle = text
            if let sp = SpriteLibrary.shared[a.sprite] {
                it.image = NSImage(cgImage: sp.frames[0], size: NSSize(width: CGFloat(sp.width) * 0.75, height: CGFloat(sp.height) * 0.75))
            }
            menu.addItem(it)
        }
        if !alerts.isEmpty {
            let jump = BlockItem("Jump to the Most Urgent") { [weak self] in self?.tracker.openMostUrgent() }
            if Settings.hotKey, let key = HotKey.menuKeyEquivalent(Settings.hotKeyCode) {
                jump.keyEquivalent = key
                jump.keyEquivalentModifierMask = HotKey.cocoa(Settings.hotKeyMods)
            }
            menu.addItem(jump)
            menu.addItem(BlockItem("Dismiss All") { [weak self] in self?.tracker.acknowledgeAll() })
        }
        menu.addItem(.separator())

        if Settings.pausedUntil == nil {
            let pause = NSMenu()
            for (title, minutes) in [("For 15 Minutes", 15), ("For 1 Hour", 60), ("For 3 Hours", 180)] {
                pause.addItem(BlockItem(title) { Settings.pausedUntil = Date().addingTimeInterval(Double(minutes) * 60) })
            }
            pause.addItem(BlockItem("Until Tomorrow Morning") {
                let cal = Calendar.current
                Settings.pausedUntil = cal.date(bySettingHour: 9, minute: 0, second: 0,
                                                of: cal.date(byAdding: .day, value: 1, to: Date())!)
            })
            let pauseItem = NSMenuItem(title: "Pause Clawds", action: nil, keyEquivalent: "")
            pauseItem.submenu = pause
            menu.addItem(pauseItem)
        }
        menu.addItem(BlockItem("Preview the Clawds") { [weak self] in self?.onPreview?() })
        menu.addItem(.separator())
        menu.addItem(BlockItem("Settings…", key: ",") { AppDelegate.shared?.openSettings() })
        menu.addItem(BlockItem("About Claws for Concern") { AppDelegate.shared?.openSettings(tab: "about") })
        menu.addItem(BlockItem("Quit Claws for Concern", key: "q") { NSApp.terminate(nil) })
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }
}
