import AppKit

/// The thought bubble shown while you hover a Clawd: session title, state, age, and the recap.
final class BubblePanel: NSPanel {
    private let bubble = BubbleView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = bubble
    }
    override var canBecomeKey: Bool { false }

    /// `headTop`: height of the Clawd's head above the bottom of its cell, so the tail points at it.
    func show(_ a: Alert, above cell: NSView, headTop: CGFloat, corner: Settings.Corner) {
        guard let win = cell.window else { return }
        let cellRect = win.convertToScreen(cell.convert(cell.bounds, to: nil))
        let screen = win.screen?.visibleFrame ?? NSScreen.screens[0].visibleFrame
        bubble.configure(a, below: !corner.isBottom)
        let size = bubble.fittingSize
        let pad = BubbleView.shadowPad
        var x: CGFloat = corner.isLeft ? cellRect.minX - 6 - pad : cellRect.maxX + 6 + pad - size.width
        x = min(max(x, screen.minX - pad + 2), screen.maxX + pad - 2 - size.width)
        let y: CGFloat = corner.isBottom ? cellRect.minY + headTop + 2 - pad : cellRect.minY - size.height + pad - 2
        let frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
        // Tail points at the Clawd's head.
        bubble.anchorX = cellRect.midX - frame.minX
        setFrame(frame, display: true)
        bubble.needsDisplay = true
        if !isVisible || alphaValue < 1 {
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
        }
    }

    func hide() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.08; animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in
            if self?.alphaValue == 0 { self?.orderOut(nil) }
        })
    }

    /// For --snapshot: the bubble view on its own.
    static func makeView(_ a: Alert, anchorX: CGFloat, below: Bool = false) -> BubbleView {
        let v = BubbleView()
        v.configure(a, below: below)
        v.frame = NSRect(origin: .zero, size: v.fittingSize)
        v.anchorX = anchorX
        return v
    }
}

final class BubbleView: NSView {
    static let shadowPad: CGFloat = 10
    static let tail: CGFloat = 15
    static let maxText: CGFloat = 330

    private let titleLabel = NSTextField(labelWithString: "")
    private let recapLabel = NSTextField(wrappingLabelWithString: "")
    var anchorX: CGFloat = 20 { didSet { needsDisplay = true } }
    private var below = false

    private static let fill = NSColor(name: nil) { $0.isDark ? NSColor(srgbRed: 0.17, green: 0.165, blue: 0.155, alpha: 0.98)
                                                             : NSColor(srgbRed: 1, green: 1, blue: 0.995, alpha: 0.98) }
    private static let stroke = NSColor(name: nil) { $0.isDark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.09) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        recapLabel.font = .systemFont(ofSize: 12)
        recapLabel.maximumNumberOfLines = 3
        recapLabel.lineBreakMode = .byWordWrapping
        recapLabel.cell?.truncatesLastVisibleLine = true
        recapLabel.preferredMaxLayoutWidth = BubbleView.maxText
        for l in [titleLabel, recapLabel] { l.translatesAutoresizingMaskIntoConstraints = true; addSubview(l) }
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ a: Alert, below: Bool) {
        self.below = below
        titleLabel.stringValue = "\(a.title)  ·  \(BubbleView.stateWord(a))  ·  \(BubbleView.age(a.ts))"
        recapLabel.stringValue = a.recap
        recapLabel.textColor = a.recapPending ? .secondaryLabelColor : .labelColor
        layoutLabels()
    }

    static func stateWord(_ a: Alert) -> String {
        switch a.kind {
        case .finished: return "done"
        case .failed: return "stopped"
        case .blocked:
            switch a.blockedKind {
            case "question": return "has a question"
            case "plan": return "plan to approve"
            case "permission": return "needs permission"
            default: return "needs input"
            }
        }
    }

    static func age(_ ts: Double) -> String {
        let s = max(0, Date().timeIntervalSince1970 - ts)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }

    private var textWidth: CGFloat = 0
    private var bubbleHeight: CGFloat = 0

    private func layoutLabels() {
        // Measure with TextKit directly: NSTextField's own sizing does not wrap reliably offscreen.
        func measure(_ f: NSTextField, width: CGFloat, maxLines: Int) -> NSSize {
            let font = f.font ?? .systemFont(ofSize: 12)
            let r = NSAttributedString(string: f.stringValue, attributes: [.font: font])
                .boundingRect(with: NSSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
            let line = ceil(font.ascender - font.descender + font.leading)
            return NSSize(width: ceil(r.width) + 2, height: min(ceil(r.height), line * CGFloat(maxLines)))
        }
        let title = measure(titleLabel, width: 10_000, maxLines: 1)
        let recapOneLine = measure(recapLabel, width: 10_000, maxLines: 1)
        // Hug the text: as wide as the longest wrapped line, not the wrap limit.
        let wrapped = measure(recapLabel, width: BubbleView.maxText, maxLines: 3)
        textWidth = min(BubbleView.maxText, max(title.width, min(recapOneLine.width, wrapped.width), 140))
        let rh = measure(recapLabel, width: textWidth, maxLines: 3).height
        let th = title.height
        recapLabel.preferredMaxLayoutWidth = textWidth
        bubbleHeight = (8 + th + 3 + rh + 9).rounded(.up)
        let p = BubbleView.shadowPad
        let base = below ? p : p + BubbleView.tail
        recapLabel.frame = NSRect(x: p + 12, y: base + 9, width: textWidth + 2, height: rh)
        titleLabel.frame = NSRect(x: p + 12, y: base + 9 + rh + 3, width: textWidth + 2, height: th)
    }

    override var fittingSize: NSSize {
        NSSize(width: textWidth + 26 + 2 * BubbleView.shadowPad, height: bubbleHeight + BubbleView.tail + 2 * BubbleView.shadowPad)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = BubbleView.shadowPad
        let rect = NSRect(x: p, y: below ? p : p + BubbleView.tail, width: bounds.width - 2 * p, height: bubbleHeight)
        let body = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)
        // Thought-bubble tail: two shrinking circles toward the Clawd.
        let ax = min(max(anchorX, rect.minX + 10), rect.maxX - 10)
        let dir: CGFloat = below ? 1 : -1
        let edge = below ? rect.maxY : rect.minY
        let big = NSBezierPath(ovalIn: NSRect(x: ax - 4.5, y: edge + dir * 4.5 - 4.5, width: 9, height: 9))
        let small = NSBezierPath(ovalIn: NSRect(x: ax - 2.75 - 2, y: edge + dir * 12 - 2.75, width: 5.5, height: 5.5))

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: effectiveAppearance.isDark ? 0.5 : 0.16)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        BubbleView.fill.setFill()
        body.fill(); big.fill(); small.fill()
        NSGraphicsContext.restoreGraphicsState()

        BubbleView.stroke.setStroke()
        for path in [body, big, small] { path.lineWidth = 0.5; path.stroke() }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
