import AppKit
import QuartzCore

/// The always-on-top strip of Clawds in a screen corner, one per session that needs you.
final class OverlayController {
    let panel: StripPanel
    private let tracker: Tracker
    private let bubble = BubblePanel()
    private var cells: [String: ClawdCell] = [:]
    private var order: [String] = []
    private var alerts: [String: Alert] = [:]
    private var hovered: String?
    private var hideBubbleWork: DispatchWorkItem?
    private let lib = SpriteLibrary.shared

    static let margin: CGFloat = 8
    static let gap: CGFloat = 3
    static let headroom: CGFloat = 7   // space above the tallest sprite for the badge

    init(tracker: Tracker) {
        self.tracker = tracker
        panel = StripPanel()
        let nc = NotificationCenter.default
        nc.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in self?.relayout(rebuildCells: true) }
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.relayout(rebuildCells: true)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.relayout(rebuildCells: true) }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in self?.relayout() }
    }

    // MARK: Updates

    func update(_ list: [Alert]) {
        let newIDs = list.map(\.sessionId)
        let gone = order.filter { !newIDs.contains($0) }
        for id in gone {
            guard let c = cells.removeValue(forKey: id) else { continue }
            if hovered == id { hideBubble(now: true) }
            c.animateOut()
        }
        alerts = Dictionary(uniqueKeysWithValues: list.map { ($0.sessionId, $0) })
        for a in list {
            if let c = cells[a.sessionId] {
                c.configure(a, artPt: artPoints)
            } else {
                let c = ClawdCell(alert: a, controller: self)
                c.configure(a, artPt: artPoints)
                cells[a.sessionId] = c
                panel.contentView?.addSubview(c)
                c.pendingAppear = true
            }
        }
        order = newIDs
        relayout()
        if let h = hovered, let a = alerts[h], let c = cells[h] { bubble.show(a, above: c, headTop: c.headTop, corner: Settings.corner) }
    }

    private var screen: NSScreen {
        if Settings.screen == .mouse {
            let p = NSEvent.mouseLocation
            if let s = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) { return s }
        }
        return NSScreen.screens.first ?? NSScreen.main!
    }

    /// Points per art pixel, snapped so every art pixel is a whole number of device pixels.
    var artPoints: CGFloat {
        let scale = screen.backingScaleFactor
        return max(1, (Settings.size.artPoints * scale).rounded()) / scale
    }

    func relayout(rebuildCells: Bool = false) {
        let art = artPoints
        if rebuildCells { for (id, c) in cells { if let a = alerts[id] { c.configure(a, artPt: art, force: true) } } }
        guard !order.isEmpty else {
            if panel.isVisible { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if self?.order.isEmpty == true { self?.panel.orderOut(nil) } } }
            return
        }
        let corner = Settings.corner
        let height = CGFloat(lib.maxHeight) * art + OverlayController.headroom
        let widths = order.map { cells[$0]?.preferredWidth(artPt: art) ?? 0 }
        let total = widths.reduce(0, +) + OverlayController.gap * CGFloat(max(0, order.count - 1))
        let vf = screen.visibleFrame
        let x = corner.isLeft ? vf.minX + OverlayController.margin : vf.maxX - OverlayController.margin - total
        let y = corner.isBottom ? vf.minY + OverlayController.margin : vf.maxY - OverlayController.margin - height
        panel.setFrame(NSRect(x: x, y: y, width: total, height: height), display: false)

        var cx: CGFloat = corner.isLeft ? 0 : total
        for (i, id) in order.enumerated() {
            guard let c = cells[id] else { continue }
            let w = widths[i]
            if !corner.isLeft { cx -= w }
            let f = NSRect(x: cx, y: 0, width: w, height: height)
            if c.pendingAppear {
                c.frame = f
                c.pendingAppear = false
                c.animateIn()
            } else if c.frame != f {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.22
                    ctx.allowsImplicitAnimation = true
                    c.animator().frame = f
                }
            }
            if corner.isLeft { cx += w + OverlayController.gap } else { cx -= OverlayController.gap }
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    // MARK: Hover, click

    func hoverBegan(_ cell: ClawdCell) {
        hideBubbleWork?.cancel()
        hovered = cell.sessionId
        if let a = alerts[cell.sessionId] { bubble.show(a, above: cell, headTop: cell.headTop, corner: Settings.corner) }
    }

    func hoverEnded(_ cell: ClawdCell) {
        guard hovered == cell.sessionId else { return }
        hideBubble(now: false)
    }

    private func hideBubble(now: Bool) {
        hideBubbleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hovered = nil
            self?.bubble.hide()
        }
        hideBubbleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0 : 0.12), execute: work)
    }

    func clicked(_ cell: ClawdCell) {
        hideBubble(now: true)
        tracker.open(cell.sessionId)
    }

    func menu(for cell: ClawdCell) -> NSMenu {
        let m = NSMenu()
        let sid = cell.sessionId
        let mapped = alerts[sid]?.mapped ?? false
        m.addItem(BlockItem(mapped ? "Open in Ghostty" : "Bring Ghostty Forward") { [weak self] in self?.tracker.open(sid) })
        m.addItem(BlockItem("Dismiss") { [weak self] in self?.tracker.acknowledge(sid) })
        if let a = alerts[sid] {
            m.addItem(BlockItem("Copy Recap") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(a.recap, forType: .string)
            })
        }
        if let s = tracker.state(sid) {
            m.addItem(BlockItem("Copy Resume Command") {
                NSPasteboard.general.clearContents()
                let resume = Settings.resumeCommand.replacingOccurrences(of: "{id}", with: s.sessionId)
                NSPasteboard.general.setString("cd \(s.rootCwd.shellQuoted) && \(resume)", forType: .string)
            })
        }
        m.addItem(.separator())
        m.addItem(BlockItem("Dismiss All") { [weak self] in self?.tracker.acknowledgeAll() })
        return m
    }
}

extension String {
    var shellQuoted: String {
        range(of: "^[A-Za-z0-9_/.,:@%+=-]+$", options: .regularExpression) != nil ? self
            : "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// NSMenuItem that runs a closure.
final class BlockItem: NSMenuItem {
    private let block: () -> Void
    init(_ title: String, key: String = "", state: NSControl.StateValue = .off, _ block: @escaping () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        self.state = state
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { block() }
}

/// Borderless, transparent, never takes focus, follows you across Spaces and full-screen apps.
final class StripPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        acceptsMouseMovedEvents = true
        let v = NSView()
        v.wantsLayer = true
        contentView = v
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One Clawd: the animated sprite, plus a small badge when it needs you or failed.
final class ClawdCell: NSView {
    let sessionId: String
    private weak var controller: OverlayController?
    private let spriteLayer = CALayer()
    private let badge = CALayer()
    private let badgeText = CATextLayer()
    private var spriteName = ""
    private var artPt: CGFloat = 1
    private var kind: Alert.Kind = .finished
    private var blockedKind: String?
    var pendingAppear = false

    init(alert: Alert, controller: OverlayController) {
        sessionId = alert.sessionId
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        spriteLayer.magnificationFilter = .nearest
        spriteLayer.minificationFilter = .nearest
        spriteLayer.contentsGravity = .resize
        spriteLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
        // A soft outline shadow keeps a tiny Clawd readable over busy terminal text and
        // light or dark wallpapers alike.
        spriteLayer.shadowColor = NSColor.black.cgColor
        spriteLayer.shadowOpacity = 0.32
        spriteLayer.shadowRadius = 1.6
        spriteLayer.shadowOffset = CGSize(width: 0, height: -0.75)
        layer?.addSublayer(spriteLayer)
        badge.backgroundColor = NSColor(srgbRed: 0.85, green: 0.27, blue: 0.22, alpha: 1).cgColor
        badge.borderColor = NSColor.white.cgColor
        badge.borderWidth = 1
        badgeText.alignmentMode = .center
        badgeText.foregroundColor = NSColor.white.cgColor
        badgeText.font = NSFont.systemFont(ofSize: 8, weight: .heavy)
        badge.addSublayer(badgeText)
        badge.isHidden = true
        layer?.addSublayer(badge)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Top of the Clawd (its tallest frame) above the bottom of the cell.
    var headTop: CGFloat { CGFloat(SpriteLibrary.shared[spriteName]?.height ?? 17) * artPt }

    func preferredWidth(artPt: CGFloat) -> CGFloat {
        let w = SpriteLibrary.shared[spriteName]?.width ?? 24
        return CGFloat(w) * artPt + 4
    }

    private var spoken = ""

    func configure(_ a: Alert, artPt: CGFloat, force: Bool = false) {
        spoken = "\(a.title), \(BubbleView.stateWord(a)). \(a.recap)"
        let changed = force || a.sprite != spriteName || artPt != self.artPt || a.kind != kind || a.blockedKind != blockedKind
        guard changed else { return }
        kind = a.kind
        blockedKind = a.blockedKind
        self.artPt = artPt
        if a.sprite != spriteName || force, let sp = SpriteLibrary.shared[a.sprite] {
            spriteName = a.sprite
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            spriteLayer.removeAllAnimations()
            spriteLayer.contents = sp.frames.first
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                spriteLayer.add(sp.animation(), forKey: "frames")
            }
            CATransaction.commit()
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        guard let sp = SpriteLibrary.shared[spriteName] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let w = CGFloat(sp.width) * artPt, h = CGFloat(sp.height) * artPt
        spriteLayer.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        spriteLayer.position = CGPoint(x: (bounds.width / 2).rounded(), y: 0)
        spriteLayer.contentsScale = window?.backingScaleFactor ?? 2

        let symbol: String?
        switch kind {
        case .blocked: symbol = blockedKind == "question" ? "?" : blockedKind == "plan" ? "✓" : "!"
        case .failed: symbol = "×"
        case .finished: symbol = nil
        }
        badge.isHidden = symbol == nil
        if let symbol {
            let d: CGFloat = artPt >= 1.5 ? 11 : 9
            badge.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            badge.cornerRadius = d / 2
            // Top-right of the Clawd's body (frame 0 bounds).
            badge.position = CGPoint(x: min(bounds.width - d / 2, (bounds.width + w) / 2 - d * 0.2),
                                     y: min(bounds.height - d / 2, h + d * 0.15))
            badgeText.string = symbol
            badgeText.fontSize = d * 0.78
            badgeText.frame = CGRect(x: 0, y: (d - d * 0.98) / 2 - 0.5, width: d, height: d * 0.98)
            badgeText.contentsScale = window?.backingScaleFactor ?? 2
            badge.backgroundColor = (kind == .failed ? NSColor(srgbRed: 0.45, green: 0.44, blue: 0.42, alpha: 1)
                                     : NSColor(srgbRed: 0.85, green: 0.27, blue: 0.22, alpha: 1)).cgColor
        }
        CATransaction.commit()
    }

    func animateIn() {
        guard let l = layer else { return }
        l.opacity = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.25
        let hop = CASpringAnimation(keyPath: "transform.translation.y")
        hop.fromValue = -10; hop.toValue = 0
        hop.damping = 9; hop.stiffness = 180; hop.mass = 0.6
        hop.duration = hop.settlingDuration
        l.add(fade, forKey: "in-fade")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { l.add(hop, forKey: "in-hop") }
    }

    func animateOut() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            self.animator().alphaValue = 0
        }, completionHandler: { self.removeFromSuperview() })
    }

    override func mouseEntered(with event: NSEvent) {
        controller?.hoverBegan(self)
        NSCursor.pointingHand.set()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        spriteLayer.transform = CATransform3DMakeTranslation(0, max(1, artPt), 0)
        CATransaction.commit()
    }

    override func mouseExited(with event: NSEvent) {
        controller?.hoverEnded(self)
        NSCursor.arrow.set()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        spriteLayer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        controller?.clicked(self)
    }

    // VoiceOver: each Clawd is a button that opens its session.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { spoken }
    override func accessibilityHelp() -> String? { "Opens this Claude Code session in Ghostty" }
    override func accessibilityPerformPress() -> Bool { controller?.clicked(self); return true }

    override func rightMouseDown(with event: NSEvent) {
        guard let m = controller?.menu(for: self) else { return }
        NSMenu.popUpContextMenu(m, with: event, for: self)
    }
}
