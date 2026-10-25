import AppKit

/// `--snapshot DIR`: renders the README images offscreen (no screen recording needed).
///   hero-light.png / hero-dark.png  a desktop corner with the Clawds and a thought bubble
///   bubble-light.png / bubble-dark.png  the bubble close up
///   frames/strip-NNN.png  80 frames of the strip, for tools/make-readme-media.sh to turn into a GIF
enum Snapshot {
    static let scale: CGFloat = 2

    struct Item { let alert: Alert; let x: CGFloat }

    static func demoAlerts() -> [Alert] {
        let now = Date().timeIntervalSince1970
        func a(_ id: String, _ k: Alert.Kind, _ bk: String?, _ age: Double, _ title: String, _ recap: String, _ sprite: String) -> Alert {
            Alert(sessionId: id, kind: k, blockedKind: bk, ts: now - age, title: title, folder: "", recap: recap,
                  recapPending: false, sprite: sprite, mapped: true)
        }
        return [
            a("1", .blocked, "question", 130, "Fix flaky login test",
              "Login fix verified with 20 green runs; PR to main or release-2.4?", "Waving"),
            a("2", .failed, nil, 420, "Nightly data export", "Stopped: API Error: Rate limit reached", "CrabWalking"),
            a("3", .finished, nil, 300, "Budget alerts for all clouds",
              "Budgets live on all 3 accounts; alerts go to finance from tomorrow", "JumpingHappy"),
            a("4", .finished, nil, 900, "Office 365 licence comparison",
              "Comparison table done; recommends Business Premium for field staff", "Dancing"),
            a("5", .finished, nil, 1500, "Release notes 2.4", "Draft ready in docs/release-2.4.md, waiting for your edits", "RacingCar"),
        ]
    }

    static func run(outDir: String) -> Int32 {
        _ = NSApplication.shared
        let lib = SpriteLibrary.shared
        guard lib.hasArt else { print("no art yet: run --fetch-art first"); return 1 }
        let dir = URL(fileURLWithPath: outDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("frames"), withIntermediateDirectories: true)

        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            write(hero(dark: dark), dir.appendingPathComponent("hero-\(suffix).png"))
            write(bubbleCloseup(dark: dark), dir.appendingPathComponent("bubble-\(suffix).png"))
        }
        for i in 0..<80 {
            let img = strip(dark: false, time: Double(i) / 20)
            write(img, dir.appendingPathComponent(String(format: "frames/strip-%03d.png", i)))
        }
        print("wrote \(dir.path)")
        return 0
    }

    // MARK: Scenes

    /// A corner of a desktop: wallpaper, a terminal window, the Clawds and one thought bubble.
    static func hero(dark: Bool) -> CGImage {
        let size = CGSize(width: 1280, height: 720)
        return render(size) { ctx in
            wallpaper(ctx, size, dark: dark)
            terminal(ctx, CGRect(x: 250, y: 150, width: 900, height: 500), dark: dark)
            let alerts = demoAlerts()
            let art: CGFloat = 2
            let items = layout(alerts, origin: CGPoint(x: 24, y: 22), art: art)
            drawStrip(ctx, items, art: art, time: 0.5)
            drawBubble(ctx, alerts[0], over: items[0], art: art, dark: dark)
        }
    }

    static func bubbleCloseup(dark: Bool) -> CGImage {
        let size = CGSize(width: 520, height: 190)
        return render(size) { ctx in
            ctx.setFillColor(dark ? NSColor(srgbRed: 0.12, green: 0.118, blue: 0.11, alpha: 1).cgColor
                                  : NSColor(srgbRed: 0.94, green: 0.933, blue: 0.902, alpha: 1).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            let alerts = Array(demoAlerts().prefix(3))
            let art: CGFloat = 2
            let items = layout(alerts, origin: CGPoint(x: 28, y: 20), art: art)
            drawStrip(ctx, items, art: art, time: 0.5)
            drawBubble(ctx, alerts[0], over: items[0], art: art, dark: dark)
        }
    }

    /// The README GIF: the strip animating, with the bubble on the first Clawd.
    static func strip(dark: Bool, time: Double) -> CGImage {
        let size = CGSize(width: 560, height: 200)
        return render(size) { ctx in
            wallpaper(ctx, size, dark: dark)
            let alerts = demoAlerts()
            let art: CGFloat = 2
            let items = layout(alerts, origin: CGPoint(x: 22, y: 18), art: art)
            drawStrip(ctx, items, art: art, time: time)
            drawBubble(ctx, alerts[0], over: items[0], art: art, dark: dark)
        }
    }

    // MARK: Pieces

    static func layout(_ alerts: [Alert], origin: CGPoint, art: CGFloat) -> [Item] {
        var x = origin.x
        var out: [Item] = []
        for a in alerts {
            let w = CGFloat(SpriteLibrary.shared[a.sprite]?.width ?? 24) * art + 4
            out.append(Item(alert: a, x: x))
            x += w + OverlayController.gap
        }
        return out.map { Item(alert: $0.alert, x: $0.x) }
    }

    static var stripY: CGFloat = 22

    static func drawStrip(_ ctx: CGContext, _ items: [Item], art: CGFloat, time: Double) {
        ctx.interpolationQuality = .none
        for it in items {
            guard let sp = SpriteLibrary.shared[it.alert.sprite] else { continue }
            var t = time.truncatingRemainder(dividingBy: sp.duration), idx = 0
            for (i, d) in sp.delays.enumerated() { if t < d { idx = i; break }; t -= d; idx = i }
            let w = CGFloat(sp.width) * art, h = CGFloat(sp.height) * art
            let cellW = w + 4
            let r = CGRect(x: it.x + (cellW - w) / 2, y: stripY, width: w, height: h)
            ctx.draw(sp.frames[idx], in: r)
            let symbol: String? = it.alert.kind == .blocked ? (it.alert.blockedKind == "question" ? "?" : "!")
                : it.alert.kind == .failed ? "×" : nil
            if let symbol {
                let d: CGFloat = 11
                let c = CGPoint(x: r.maxX - d * 0.2, y: r.minY + min(r.height, CGFloat(SpriteLibrary.shared.maxHeight) * art) + d * 0.15)
                let badge = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
                ctx.setFillColor(it.alert.kind == .failed ? NSColor(srgbRed: 0.45, green: 0.44, blue: 0.42, alpha: 1).cgColor
                                                          : NSColor(srgbRed: 0.85, green: 0.27, blue: 0.22, alpha: 1).cgColor)
                ctx.fillEllipse(in: badge)
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(1)
                ctx.strokeEllipse(in: badge.insetBy(dx: 0.5, dy: 0.5))
                text(ctx, symbol, at: CGPoint(x: badge.midX, y: badge.midY), font: .systemFont(ofSize: 8.5, weight: .heavy),
                     color: .white, centered: true)
            }
        }
    }

    static func drawBubble(_ ctx: CGContext, _ a: Alert, over it: Item, art: CGFloat, dark: Bool) {
        let v = BubbleView()
        v.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        v.configure(a, below: false)
        v.frame = NSRect(origin: .zero, size: v.fittingSize)
        let w = CGFloat(SpriteLibrary.shared[a.sprite]?.width ?? 24) * art + 4
        v.anchorX = BubbleView.shadowPad + 6 + w / 2
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        rep.size = v.bounds.size
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            v.cacheDisplay(in: v.bounds, to: rep)
        }
        guard let img = rep.cgImage else { return }
        let top = stripY + CGFloat(SpriteLibrary.shared[a.sprite]?.height ?? 17) * art + 2
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: it.x - 6 - BubbleView.shadowPad, y: top - BubbleView.shadowPad - 2,
                                 width: v.bounds.width, height: v.bounds.height))
    }

    static func wallpaper(_ ctx: CGContext, _ size: CGSize, dark: Bool) {
        let colors = dark
            ? [NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1), NSColor(srgbRed: 0.20, green: 0.13, blue: 0.11, alpha: 1)]
            : [NSColor(srgbRed: 0.96, green: 0.92, blue: 0.86, alpha: 1), NSColor(srgbRed: 0.90, green: 0.70, blue: 0.60, alpha: 1)]
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [NSColor(white: 1, alpha: dark ? 0.06 : 0.35).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                              locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: size.width * 0.25, y: size.height * 0.85), startRadius: 0,
                               endCenter: CGPoint(x: size.width * 0.25, y: size.height * 0.85), endRadius: size.width * 0.6, options: [])
    }

    static func terminal(_ ctx: CGContext, _ r: CGRect, dark: Bool) {
        let bg = NSColor(srgbRed: 0.118, green: 0.114, blue: 0.106, alpha: 1)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: NSColor(white: 0, alpha: 0.35).cgColor)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.setFillColor(bg.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.clip()
        // Title bar with tabs.
        let bar = CGRect(x: r.minX, y: r.maxY - 40, width: r.width, height: 40)
        ctx.setFillColor(NSColor(srgbRed: 0.16, green: 0.155, blue: 0.145, alpha: 1).cgColor)
        ctx.fill(bar)
        for (i, c) in [NSColor.systemRed, NSColor.systemYellow, NSColor.systemGreen].enumerated() {
            ctx.setFillColor(c.withAlphaComponent(0.9).cgColor)
            ctx.fillEllipse(in: CGRect(x: r.minX + 16 + CGFloat(i) * 20, y: bar.midY - 6, width: 12, height: 12))
        }
        let tabs = ["✳ Fix flaky login test", "✳ Budget alerts for all clouds", "◐ Migrate billing service", "✳ Release notes 2.4"]
        var tx = r.minX + 86
        for (i, t) in tabs.enumerated() {
            let tw: CGFloat = 196
            if i == 2 {
                ctx.setFillColor(bg.cgColor)
                ctx.addPath(CGPath(roundedRect: CGRect(x: tx, y: bar.minY + 5, width: tw, height: 30), cornerWidth: 7, cornerHeight: 7, transform: nil))
                ctx.fillPath()
            }
            text(ctx, t, at: CGPoint(x: tx + 12, y: bar.midY), font: .systemFont(ofSize: 12, weight: i == 2 ? .semibold : .regular),
                 color: NSColor(white: 1, alpha: i == 2 ? 0.92 : 0.5))
            tx += tw + 6
        }
        // A session at work.
        let lines: [(String, NSColor)] = [
            ("> move the billing service off the legacy queue, keep the API the same", NSColor(white: 1, alpha: 0.88)),
            ("", .clear),
            ("⏺ I'll read the queue adapter first, then swap the transport behind it.", NSColor(white: 1, alpha: 0.82)),
            ("", .clear),
            ("⏺ Read(src/billing/queue.ts)", NSColor(srgbRed: 0.55, green: 0.80, blue: 0.62, alpha: 1)),
            ("  ⎿  Read 214 lines", NSColor(white: 1, alpha: 0.45)),
            ("⏺ Update(src/billing/transport.ts)", NSColor(srgbRed: 0.55, green: 0.80, blue: 0.62, alpha: 1)),
            ("  ⎿  Updated with 38 additions and 61 removals", NSColor(white: 1, alpha: 0.45)),
            ("⏺ Bash(npm test -- billing)", NSColor(srgbRed: 0.55, green: 0.80, blue: 0.62, alpha: 1)),
            ("  ⎿  Running…", NSColor(white: 1, alpha: 0.45)),
            ("", .clear),
            ("✻ Migrating… (2m 14s · ↓ 3.1k tokens)", PixelCrab.clay),
        ]
        var y = bar.minY - 34
        for (s, c) in lines {
            if !s.isEmpty { text(ctx, s, at: CGPoint(x: r.minX + 24, y: y), font: .monospacedSystemFont(ofSize: 13, weight: .regular), color: c) }
            y -= 24
        }
        ctx.restoreGState()
    }

    static func text(_ ctx: CGContext, _ s: String, at p: CGPoint, font: NSFont, color: NSColor, centered: Bool = false) {
        let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        let size = attr.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        attr.draw(at: CGPoint(x: centered ? p.x - size.width / 2 : p.x, y: p.y - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    static func render(_ size: CGSize, _ draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        draw(ctx)
        return ctx.makeImage()!
    }

    static func write(_ img: CGImage, _ url: URL) { _ = Art.writePNG(img, to: url) }
}
