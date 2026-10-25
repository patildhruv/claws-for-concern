import AppKit
import QuartzCore

// MARK: - Where the strip lives

/// The strip's spot on one display: snapped to a corner, or exactly where you dropped it.
struct Placement: Codable, Equatable {
    /// A `Settings.Corner` raw value when snapped to a corner; nil when placed freely.
    var corner: String?
    /// Free placement: the leading Clawd's bottom-left, as a fraction of the display's visible frame
    /// (fractions survive resolution changes).
    var fx: Double = 0
    var fy: Double = 0
}

/// Placements are remembered per display, keyed by the display's UUID (stable across reconnects).
enum Placements {
    static let key = "placements"

    static func displayKey(_ s: NSScreen) -> String {
        guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return "unknown" }
        let id = CGDirectDisplayID(n.uint32Value)
        if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
           let str = CFUUIDCreateString(nil, uuid) { return str as String }
        return "display-\(id)"
    }

    static var all: [String: Placement] {
        guard let d = Settings.d.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Placement].self, from: d)) ?? [:]
    }

    static func get(_ s: NSScreen) -> Placement { all[displayKey(s)] ?? Placement(corner: Settings.corner.rawValue) }
    static func isCustom(_ s: NSScreen) -> Bool { all[displayKey(s)] != nil }

    static func set(_ p: Placement?, for s: NSScreen) {
        var a = all
        a[displayKey(s)] = p
        Settings.set(try? JSONEncoder().encode(a), key)
    }

    static func resetAll() { Settings.set(nil, key) }
}

extension NSScreen {
    /// Where the Clawds may go: the whole display down to its very edges, Dock area included, but
    /// never over the menu bar. "Keep clear of the Dock" in Settings narrows it to the visible frame.
    var clawdArea: CGRect {
        if Settings.avoidDock { return visibleFrame }
        return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: visibleFrame.maxY - frame.minY)
    }
}

/// Pure geometry, kept free of AppKit state so the self-test can drive it.
enum StripGeometry {
    struct Result {
        var frames: [CGRect]
        var rect: CGRect
        var growsRight: Bool
        var bubbleBelow: Bool
    }

    /// Lays out cells of `widths` for a placement. The leading (most urgent) Clawd sits exactly at
    /// the placement; the rest grow to the right, or to the left when the right would run off-screen.
    static func layout(widths: [CGFloat], height: CGFloat, placement: Placement, in vf: CGRect,
                       margin: CGFloat, gap: CGFloat) -> Result {
        guard let w0 = widths.first else { return Result(frames: [], rect: .zero, growsRight: true, bubbleBelow: false) }
        let total = widths.reduce(0, +) + gap * CGFloat(widths.count - 1)
        var ax: CGFloat, ay: CGFloat
        var prefersRight = true
        if let c = placement.corner.flatMap(Settings.Corner.init) {
            ax = c.isLeft ? vf.minX + margin : vf.maxX - margin - w0
            ay = c.isBottom ? vf.minY + margin : vf.maxY - margin - height
            prefersRight = c.isLeft
        } else {
            ax = vf.minX + CGFloat(placement.fx) * vf.width
            ay = vf.minY + CGFloat(placement.fy) * vf.height
        }
        ax = min(max(ax, vf.minX), vf.maxX - w0)
        ay = min(max(ay, vf.minY), vf.maxY - height)

        let roomRight = vf.maxX - ax, roomLeft = ax + w0 - vf.minX
        let fitsRight = total <= roomRight, fitsLeft = total <= roomLeft
        let growsRight: Bool
        if prefersRight { growsRight = fitsRight || (!fitsLeft && roomRight >= roomLeft) }
        else { growsRight = !fitsLeft && (fitsRight || roomRight > roomLeft) }

        var frames: [CGRect] = []
        if growsRight {
            var x = fitsRight ? ax : max(vf.minX, vf.maxX - total)   // neither side fits: shift as little as possible
            for w in widths { frames.append(CGRect(x: x, y: ay, width: w, height: height)); x += w + gap }
        } else {
            var right = fitsLeft ? ax + w0 : min(vf.maxX, vf.minX + total)
            for w in widths { frames.append(CGRect(x: right - w, y: ay, width: w, height: height)); right -= w + gap }
        }
        let rect = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
        return Result(frames: frames, rect: rect, growsRight: growsRight, bubbleBelow: rect.midY > vf.midY)
    }

    static let cornerSnap: CGFloat = 48
    static let edgeSnap: CGFloat = 20

    /// The placement for a strip dropped with its leading Clawd at `lead` and overall extent `strip`.
    static func placement(lead: CGRect, strip: CGRect, in vf: CGRect, margin: CGFloat, snap: Bool) -> Placement {
        let dl = abs(strip.minX - (vf.minX + margin)), dr = abs(strip.maxX - (vf.maxX - margin))
        let db = abs(strip.minY - (vf.minY + margin)), dt = abs(strip.maxY - (vf.maxY - margin))
        if snap {
            let c = cornerSnap
            if db < c && dl < c { return Placement(corner: Settings.Corner.bottomLeft.rawValue) }
            if db < c && dr < c { return Placement(corner: Settings.Corner.bottomRight.rawValue) }
            if dt < c && dl < c { return Placement(corner: Settings.Corner.topLeft.rawValue) }
            if dt < c && dr < c { return Placement(corner: Settings.Corner.topRight.rawValue) }
        }
        var x = lead.minX, y = lead.minY
        if snap {
            let e = edgeSnap
            if dl < e { x += (vf.minX + margin) - strip.minX } else if dr < e { x += (vf.maxX - margin) - strip.maxX }
            if db < e { y += (vf.minY + margin) - strip.minY } else if dt < e { y += (vf.maxY - margin) - strip.maxY }
        }
        return Placement(corner: nil, fx: Double((x - vf.minX) / vf.width), fy: Double((y - vf.minY) / vf.height))
    }
}

// MARK: - The strip

/// The always-on-top strip of Clawds, one per session that needs you.
final class OverlayController {
    let panel = StripPanel()
    private let tracker: Tracker
    private let bubble = BubblePanel()
    private let lib = SpriteLibrary.shared
    private var items: [String: StripItem] = [:]
    private var order: [String] = []
    private var alerts: [String: Alert] = [:]
    private var hidden: [Alert] = []          // behind the "+N" chip
    private var latest: [Alert] = []
    private var geometry = StripGeometry.Result(frames: [], rect: .zero, growsRight: true, bubbleBelow: false)
    private var generation = 0
    private var hovered: String?
    private var hoverWork: DispatchWorkItem?
    private var displayKey: String?
    private var pointerElsewhereSince: Date?
    private var wasPaused = false
    private var timer: Timer?

    // Dragging the strip.
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint = .zero
    private(set) var dragging = false

    static let overflowID = "__overflow__"
    static let headroom: CGFloat = 7   // above the tallest sprite, for the badge

    init(tracker: Tracker) {
        self.tracker = tracker
        let nc = NotificationCenter.default
        nc.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in self?.reapply() }
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reapply()
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reapply()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.1
    }

    // MARK: Screens

    /// The display the strip is on: the main one, a chosen one, or (by default) the one you are using.
    var screen: NSScreen {
        let mode = Settings.screen
        if mode.hasPrefix("display:") {
            let key = String(mode.dropFirst(8))
            if let s = NSScreen.screens.first(where: { Placements.displayKey($0) == key }) { return s }
        }
        if mode == "follow", let key = displayKey, let s = NSScreen.screens.first(where: { Placements.displayKey($0) == key }) {
            return s
        }
        if mode == "follow" { return pointerScreen }
        return NSScreen.screens.first ?? NSScreen.main!
    }

    private var pointerScreen: NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.screens.first ?? NSScreen.main!
    }

    /// Points per art pixel, snapped so every art pixel is a whole number of device pixels.
    var artPoints: CGFloat {
        let scale = screen.backingScaleFactor
        return max(1, (Settings.size.artPoints * scale).rounded()) / scale
    }

    private func tick() {
        // Pause ending.
        let paused = Settings.pausedUntil != nil
        if paused != wasPaused { wasPaused = paused; update(latest) }
        // Follow the pointer to another display, after a moment so passing through does not move it.
        guard Settings.screen == "follow", !dragging, !order.isEmpty else { pointerElsewhereSince = nil; return }
        let p = Placements.displayKey(pointerScreen)
        if displayKey == nil { displayKey = p }
        if p == displayKey { pointerElsewhereSince = nil; return }
        if let since = pointerElsewhereSince {
            if Date().timeIntervalSince(since) > 1.2 { moveToDisplay(p) }
        } else {
            pointerElsewhereSince = Date()
        }
    }

    private func moveToDisplay(_ key: String) {
        pointerElsewhereSince = nil
        hideBubble(now: true)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 }, completionHandler: {
            self.displayKey = key
            self.relayout(animated: false)
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; self.panel.animator().alphaValue = Settings.opacity }
        })
    }

    // MARK: Updates

    private var look = ""

    private func reapply() {
        let now = "\(artPoints)|\(Settings.animate)|\(Settings.shadows)|\(Settings.badges)|\(lib.sprites.count)|" +
            "\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)"
        if now != look {
            look = now
            for (id, item) in items { if let c = item as? ClawdCell, let a = alerts[id] { c.configure(a, artPt: artPoints, force: true) } }
        }
        update(latest)
    }

    func update(_ list: [Alert]) {
        latest = list
        var shown = Settings.pausedUntil == nil ? list : []
        let cap = Settings.maxClawds
        hidden = []
        if shown.count > cap {
            hidden = Array(shown[(cap - 1)...])
            shown = Array(shown[..<(cap - 1)])
        }
        let ids = shown.map(\.sessionId) + (hidden.isEmpty ? [] : [OverlayController.overflowID])

        for id in order where !ids.contains(id) {
            guard let item = items.removeValue(forKey: id) else { continue }
            if hovered == id { hideBubble(now: true) }
            item.animateOut()
        }
        alerts = Dictionary(uniqueKeysWithValues: shown.map { ($0.sessionId, $0) })
        for a in shown {
            if let c = items[a.sessionId] as? ClawdCell {
                c.configure(a, artPt: artPoints)
            } else {
                let c = ClawdCell(alert: a, controller: self)
                c.configure(a, artPt: artPoints)
                add(c, id: a.sessionId)
            }
        }
        if !hidden.isEmpty {
            let chip = (items[OverlayController.overflowID] as? OverflowChip) ?? {
                let c = OverflowChip(controller: self)
                add(c, id: OverlayController.overflowID)
                return c
            }()
            chip.configure(count: hidden.count, artPt: artPoints)
        }
        order = ids
        relayout(animated: true)
        if let h = hovered, let a = alerts[h], let c = items[h] { showBubble(a, over: c) }
    }

    private func add(_ item: StripItem, id: String) {
        items[id] = item
        item.pendingAppear = true
        panel.contentView?.addSubview(item)
    }

    /// Places every item; with `animated`, items glide from where they were to where they go.
    func relayout(animated: Bool) {
        generation += 1
        let gen = generation
        guard !order.isEmpty else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.order.isEmpty, gen == self.generation else { return }
                self.panel.orderOut(nil)
            }
            return
        }
        let art = artPoints
        let s = screen
        if displayKey == nil { displayKey = Placements.displayKey(s) }
        let height = CGFloat(max(lib.maxHeight, 17)) * art + OverlayController.headroom
        let widths = order.map { items[$0]?.preferredWidth(artPt: art) ?? 0 }
        geometry = StripGeometry.layout(widths: widths, height: height, placement: Placements.get(s), in: s.clawdArea,
                                        margin: Settings.edgeMargin, gap: Settings.spacing)
        let target = Dictionary(uniqueKeysWithValues: zip(order, geometry.frames))
        panel.alphaValue = Settings.opacity

        let canAnimate = animated && panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Start from the union of where things are and where they go, so nothing is clipped mid-flight.
        var old: [String: CGRect] = [:]
        if canAnimate {
            for (id, item) in items where item.superview != nil && !item.pendingAppear {
                old[id] = panel.convertToScreen(item.frame)
            }
        }
        let frame = old.values.reduce(geometry.rect) { $0.union($1) }
        panel.setFrame(frame.integral, display: false)
        let origin = panel.frame.origin
        func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -origin.x, dy: -origin.y) }

        for id in order {
            guard let item = items[id], let t = target[id] else { continue }
            if item.pendingAppear {
                item.frame = local(t)
                item.pendingAppear = false
                item.animateIn()
            } else if let o = old[id] {
                item.frame = local(o)
            } else {
                item.frame = local(t)
            }
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
        guard canAnimate, !old.isEmpty else { settle(gen); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            for id in order { if let item = items[id], let t = target[id] { item.animator().frame = local(t) } }
        }, completionHandler: { [weak self] in self?.settle(gen) })
    }

    /// After an animation: shrink the panel back to the strip itself.
    private func settle(_ gen: Int) {
        guard gen == generation, !order.isEmpty else { return }
        panel.setFrame(geometry.rect.integral, display: false)
        let origin = panel.frame.origin
        for (id, f) in zip(order, geometry.frames) {
            items[id]?.frame = f.offsetBy(dx: -origin.x, dy: -origin.y)
        }
    }

    // MARK: Dragging

    func dragBegan(_ event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = panel.frame.origin
    }

    /// Returns true once the mouse has moved far enough to count as a drag.
    @discardableResult
    func dragMoved(_ event: NSEvent) -> Bool {
        guard let start = dragStartMouse, !Settings.lockPosition else { return false }
        let p = NSEvent.mouseLocation
        if !dragging, hypot(p.x - start.x, p.y - start.y) < 4 { return false }
        if !dragging {
            dragging = true
            hideBubble(now: true)
            settle(generation)
            dragStartOrigin = panel.frame.origin
            NSCursor.closedHand.push()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.1; panel.animator().alphaValue = Settings.opacity * 0.85 }
        }
        panel.setFrameOrigin(NSPoint(x: dragStartOrigin.x + p.x - start.x, y: dragStartOrigin.y + p.y - start.y))
        return true
    }

    /// Ends a drag; returns false if it was a plain click.
    func dragEnded() -> Bool {
        defer { dragStartMouse = nil }
        guard dragging else { return false }
        dragging = false
        NSCursor.pop()
        guard let leadID = order.first, let lead = items[leadID] else { return true }
        let leadRect = panel.convertToScreen(lead.frame)
        let stripRect = panel.frame
        let center = NSPoint(x: leadRect.midX, y: leadRect.midY)
        let target = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? pointerScreen
        let place = StripGeometry.placement(lead: leadRect, strip: stripRect, in: target.clawdArea,
                                            margin: Settings.edgeMargin, snap: Settings.snap)
        let key = Placements.displayKey(target)
        // Dropped on another display while pinned to one: the strip moves there.
        if Settings.screen.hasPrefix("display:") || (Settings.screen == "primary" && target != NSScreen.screens.first) {
            Settings.set("display:\(key)", Settings.Key.screen)
        }
        displayKey = key
        Placements.set(place, for: target)   // posts .settingsChanged, which relayouts
        relayout(animated: true)
        return true
    }

    func resetPosition() {
        Placements.set(nil, for: screen)
        relayout(animated: true)
    }

    // MARK: Hover, bubble, click

    func hoverBegan(_ item: StripItem) {
        guard !dragging, let a = alerts[item.id], Settings.bubble else { return }
        hoverWork?.cancel()
        hovered = item.id
        let work = DispatchWorkItem { [weak self] in self?.showBubble(a, over: item) }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Settings.hoverDelay, execute: work)
    }

    func hoverEnded(_ item: StripItem) {
        guard hovered == item.id else { return }
        hideBubble(now: false)
    }

    private func showBubble(_ a: Alert, over item: StripItem) {
        guard !dragging else { return }
        bubble.show(a, above: item, headTop: (item as? ClawdCell)?.headTop ?? item.bounds.height,
                    below: geometry.bubbleBelow, alignLeft: geometry.growsRight)
    }

    private func hideBubble(now: Bool) {
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hovered = nil
            self?.bubble.hide()
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0 : 0.12), execute: work)
    }

    func clicked(_ item: StripItem) {
        hideBubble(now: true)
        if item.id == OverlayController.overflowID {
            if let chip = item as? OverflowChip { NSMenu.popUpContextMenu(overflowMenu(), with: NSApp.currentEvent ?? NSEvent(), for: chip) }
            return
        }
        if Settings.clickAction == "dismiss" { tracker.acknowledge(item.id) } else { tracker.open(item.id) }
    }

    func menu(for item: StripItem) -> NSMenu {
        if item.id == OverlayController.overflowID { return overflowMenu() }
        let m = NSMenu()
        let sid = item.id
        let label = tracker.terminalName(sid).map { $0 == "Other terminals" ? "Bring Terminal Forward" : "Open in \($0)" }
        m.addItem(BlockItem(label ?? "Open") { [weak self] in self?.tracker.open(sid) })
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
        m.addItem(.separator())
        if Placements.isCustom(screen) {
            m.addItem(BlockItem("Move Back to \(Settings.corner.label)") { [weak self] in self?.resetPosition() })
        }
        m.addItem(BlockItem("Lock Position", state: Settings.lockPosition ? .on : .off) {
            Settings.set(!Settings.lockPosition, Settings.Key.lockPosition)
        })
        m.addItem(BlockItem("Settings…") { AppDelegate.shared?.openSettings() })
        return m
    }

    private func overflowMenu() -> NSMenu {
        let m = NSMenu()
        for a in hidden {
            let it = BlockItem("\(a.title) — \(BubbleView.stateWord(a))") { [weak self] in self?.tracker.open(a.sessionId) }
            it.toolTip = a.recap
            m.addItem(it)
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

// MARK: - Items

/// Anything in the strip: hover, click, drag-to-move, context menu, entrance and exit.
class StripItem: NSView {
    let id: String
    weak var controller: OverlayController?
    var pendingAppear = false

    init(id: String, controller: OverlayController) {
        self.id = id
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func preferredWidth(artPt: CGFloat) -> CGFloat { 24 * artPt }
    func hoverChanged(_ inside: Bool) {}

    override func mouseEntered(with event: NSEvent) {
        guard controller?.dragging != true else { return }
        controller?.hoverBegan(self)
        NSCursor.pointingHand.set()
        hoverChanged(true)
    }

    override func mouseExited(with event: NSEvent) {
        controller?.hoverEnded(self)
        if controller?.dragging != true { NSCursor.arrow.set() }
        hoverChanged(false)
    }

    override func mouseDown(with event: NSEvent) { controller?.dragBegan(event) }
    override func mouseDragged(with event: NSEvent) { controller?.dragMoved(event) }

    override func mouseUp(with event: NSEvent) {
        if controller?.dragEnded() == true { return }
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        controller?.clicked(self)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let m = controller?.menu(for: self) else { return }
        NSMenu.popUpContextMenu(m, with: event, for: self)
    }

    func animateIn() {
        guard let l = layer else { return }
        l.opacity = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.25
        l.add(fade, forKey: "in-fade")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let hop = CASpringAnimation(keyPath: "transform.translation.y")
        hop.fromValue = -10; hop.toValue = 0
        hop.damping = 9; hop.stiffness = 180; hop.mass = 0.6
        hop.duration = hop.settlingDuration
        l.add(hop, forKey: "in-hop")
    }

    func animateOut() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            self.animator().alphaValue = 0
        }, completionHandler: { self.removeFromSuperview() })
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool { controller?.clicked(self); return true }
}

/// One Clawd: the animated sprite, plus a small badge when it needs you or failed.
final class ClawdCell: StripItem {
    private let spriteLayer = CALayer()
    private let badge = CALayer()
    private let badgeText = CATextLayer()
    private var spriteName = ""
    private var artPt: CGFloat = 1
    private var kind: Alert.Kind = .finished
    private var blockedKind: String?
    private var spoken = ""

    var sessionId: String { id }

    init(alert: Alert, controller: OverlayController) {
        super.init(id: alert.sessionId, controller: controller)
        spriteLayer.magnificationFilter = .nearest
        spriteLayer.minificationFilter = .nearest
        spriteLayer.contentsGravity = .resize
        spriteLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
        // A soft outline shadow keeps a tiny Clawd readable over busy terminal text and
        // light or dark wallpapers alike.
        spriteLayer.shadowColor = NSColor.black.cgColor
        spriteLayer.shadowRadius = 1.6
        spriteLayer.shadowOffset = CGSize(width: 0, height: -0.75)
        layer?.addSublayer(spriteLayer)
        badge.borderColor = NSColor.white.cgColor
        badge.borderWidth = 1
        badgeText.alignmentMode = .center
        badgeText.foregroundColor = NSColor.white.cgColor
        badgeText.font = NSFont.systemFont(ofSize: 8, weight: .heavy)
        badge.addSublayer(badgeText)
        badge.isHidden = true
        layer?.addSublayer(badge)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Top of the Clawd (its tallest frame) above the bottom of the cell.
    var headTop: CGFloat { CGFloat(SpriteLibrary.shared[spriteName]?.height ?? 17) * artPt }

    override func preferredWidth(artPt: CGFloat) -> CGFloat {
        CGFloat(SpriteLibrary.shared[spriteName]?.width ?? 24) * artPt + 4
    }

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
            if Settings.animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                spriteLayer.add(sp.animation(), forKey: "frames")
            }
            spriteLayer.shadowOpacity = Settings.shadows ? 0.32 : 0
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

        var symbol: String?
        switch kind {
        case .blocked: symbol = blockedKind == "question" ? "?" : blockedKind == "plan" ? "✓" : "!"
        case .failed: symbol = "×"
        case .finished: symbol = nil
        }
        if !Settings.badges { symbol = nil }
        badge.isHidden = symbol == nil
        if let symbol {
            let d: CGFloat = artPt >= 1.5 ? 11 : 9
            badge.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            badge.cornerRadius = d / 2
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

    override func hoverChanged(_ inside: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        spriteLayer.transform = inside ? CATransform3DMakeTranslation(0, max(1, artPt), 0) : CATransform3DIdentity
        CATransaction.commit()
    }

    override func accessibilityLabel() -> String? { spoken }
    override func accessibilityHelp() -> String? { "Opens this Claude Code session" }
}

/// "+3": the sessions beyond the strip's limit. Click for the list.
final class OverflowChip: StripItem {
    private let pill = CALayer()
    private let label = CATextLayer()
    private var count = 0
    private var artPt: CGFloat = 1

    init(controller: OverlayController) {
        super.init(id: OverlayController.overflowID, controller: controller)
        pill.backgroundColor = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 0.95).cgColor
        pill.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        pill.borderWidth = 1
        pill.shadowColor = NSColor.black.cgColor
        pill.shadowOpacity = 0.25
        pill.shadowRadius = 1.5
        pill.shadowOffset = CGSize(width: 0, height: -0.75)
        label.alignmentMode = .center
        label.foregroundColor = NSColor.white.cgColor
        label.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        pill.addSublayer(label)
        layer?.addSublayer(pill)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(count: Int, artPt: CGFloat) {
        self.count = count
        self.artPt = artPt
        needsLayout = true
    }

    override func preferredWidth(artPt: CGFloat) -> CGFloat { max(26, 16 * artPt) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let h = max(14, 9 * artPt)
        pill.frame = CGRect(x: 2, y: (8 * artPt - h / 2).rounded(), width: bounds.width - 4, height: h)
        pill.cornerRadius = h / 2
        label.string = "+\(count)"
        label.fontSize = max(10, h * 0.62)
        label.frame = CGRect(x: 0, y: (h - label.fontSize * 1.25) / 2, width: pill.bounds.width, height: label.fontSize * 1.25)
        label.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    override func accessibilityLabel() -> String? { "\(count) more sessions" }
}
