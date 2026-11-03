import AppKit
import SwiftUI

/// `--snapshot-usage <png> [--range today|7d|30d|all] [--appearance light|dark] [--currency INR]
/// [--select first] [--size WxH] [--scroll Y]`: reads the figures, renders the Usage window offscreen
/// and quits. Like `--snapshot`, it never shows a window or takes focus. With `--demo`, made-up sessions
/// only (the README's pictures); without it, your own, which stay on your Mac (never commit them).
/// The second currency: `--currency` picks the demo's made-up rate; without `--demo` your own setting
/// and its cached rate are shown, and nothing is fetched.
enum UsageSnapshot {
    @MainActor
    static func run(_ args: [String]) -> Int32 {
        guard let path = CLI.value(args, "--snapshot-usage") else {
            print("usage: ClawsSearch [--demo] --snapshot-usage <out.png> [--range today|7d|30d|all] [--appearance light|dark]"
                  + " [--currency INR] [--select first] [--size WxH] [--scroll Y]")
            return 2
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

        if Demo.active { SecondCurrencySetting.shared.useDemo(code: CLI.value(args, "--currency")) }
        else { SecondCurrencySetting.shared.useDefaults(UserDefaults.standard, fetcher: nil) }
        let model = AppModel()
        let usage = UsageModel()
        let started = Date()
        while (model.indexing || usage.updated == nil) && Date().timeIntervalSince(started) < 120 { wait(0.2) }

        var size = NSSize(width: 1280, height: 860)     // the window's default size
        if let s = CLI.value(args, "--size")?.split(separator: "x").compactMap({ Double($0) }), s.count == 2 {
            size = NSSize(width: s[0], height: s[1])
        }
        let filter = UsageFilter(range: CLI.value(args, "--range").flatMap(UsageRange.init(rawValue:)) ?? .month)
        let root = UsageWindow(filter: filter, selectFirst: CLI.value(args, "--select") == "first")
            .environmentObject(model)
            .environmentObject(usage)
            .environment(\.controlActiveState, .key)
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: root)
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = Snapshot.KeyLookingWindow(contentRect: NSRect(origin: .zero, size: size),
                                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                               backing: .buffered, defer: false)
        if let a = CLI.value(args, "--appearance") { window.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua) }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        wait(2)     // the running sessions, the charts and the table
        if let y = CLI.value(args, "--scroll").flatMap(Double.init), let scroll = pageScroller(in: host) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            wait(0.5)
        }
        guard let frame = window.contentView?.superview else { return 1 }
        // Not the search field: as the window looks while you read it.
        window.makeFirstResponder(nil)
        frame.layoutSubtreeIfNeeded()
        wait(0.5)
        hideCutouts(frame.layer)
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return 1 }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: path))) != nil else { return 1 }
        print("wrote \(path)")
        return 0
    }

    /// The page's own scroll view: the biggest one that does not hold a table.
    @MainActor
    private static func pageScroller(in view: NSView) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, !(s.documentView is NSTableView) { found.append(s) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found.max { $0.frame.height < $1.frame.height }
    }

    /// As in `Snapshot`: a segmented control's selected segment sits on a destOut cut-out that
    /// `cacheDisplay` draws as a black block.
    private static func hideCutouts(_ layer: CALayer?) {
        func walk(_ l: CALayer) {
            if l.compositingFilter.map({ String(describing: $0) }) == "destOut" { l.isHidden = true }
            l.sublayers?.forEach(walk)
        }
        layer.map(walk)
    }
}
