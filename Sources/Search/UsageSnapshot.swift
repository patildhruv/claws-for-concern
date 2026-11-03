import AppKit
import SwiftUI

/// `--snapshot-usage <png> [--range today|7d|30d|all] [--appearance light|dark] [--currency INR]
/// [--select first] [--size WxH] [--part breakdown] [--model NAME] [--find TEXT]`: reads the figures, renders the Usage window
/// offscreen and quits. `--part breakdown` renders only its last row (by project, by model, when Claude
/// works), at the given width. Like `--snapshot`, it never shows a window or takes focus. With
/// `--demo`, made-up sessions only (the README's pictures); without it, your own, which stay on your
/// Mac (never commit them). The second currency: `--currency` picks the demo's made-up rate; without
/// `--demo` your own setting and its cached rate are shown, and nothing is fetched.
enum UsageSnapshot {
    @MainActor
    static func run(_ args: [String]) -> Int32 {
        guard let path = CLI.value(args, "--snapshot-usage") else {
            print("usage: ClawsSearch [--demo] --snapshot-usage <out.png> [--range today|7d|30d|all] [--appearance light|dark]"
                  + " [--currency INR] [--select first] [--size WxH] [--part breakdown] [--model NAME] [--find TEXT]")
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
        var filter = UsageFilter(range: CLI.value(args, "--range").flatMap(UsageRange.init(rawValue:)) ?? .month)
        filter.model = CLI.value(args, "--model")
        filter.find = CLI.value(args, "--find") ?? ""
        let appearance = CLI.value(args, "--appearance").map { NSAppearance(named: $0 == "dark" ? .darkAqua : .aqua) }

        let view: NSView
        if CLI.value(args, "--part") == "breakdown" {
            let vm = UsageWindowModel(filter: filter, remember: nil)
            vm.attach(app: model, usage: usage)
            wait(1)
            let root = UsageBreakdown()
                .padding(20)
                .frame(width: size.width)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color(nsColor: .windowBackgroundColor))
                .environmentObject(vm)
                .environmentObject(usage)
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: size.width, height: 400)),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = appearance ?? nil
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            window.setContentSize(host.fittingSize)
            wait(1)
            view = host
        } else {
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
            window.appearance = appearance ?? nil
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            wait(2)     // the running sessions, the charts and the table
            guard let frame = window.contentView?.superview else { return 1 }
            // Not the search field: as the window looks while you read it.
            window.makeFirstResponder(nil)
            frame.layoutSubtreeIfNeeded()
            wait(0.5)
            view = frame
        }
        hideCutouts(view.layer)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 1 }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: path))) != nil else { return 1 }
        print("wrote \(path)")
        return 0
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
