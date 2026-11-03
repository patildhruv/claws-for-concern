import AppKit

// Compiled into both the app and the search helper, so Search looks like part of Claws for Concern.
// Only our own drawing: the crab is ours, no Anthropic artwork.

/// Our own crab, used for the icon's look, the menu bar and the Settings window, and Search's empty states.
enum PixelCrab {
    static let grid = [
        ".#########.",
        ".#########.",
        "##o#####o##",
        "###########",
        ".#########.",
        ".#########.",
        ".#.#...#.#.",
        ".#.#...#.#.",
    ]
    static let clay = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)   // #D97757
    static let ink = NSColor(srgbRed: 0.078, green: 0.078, blue: 0.075, alpha: 1)    // #141413

    static func image(cell: Int, body: NSColor, eyes: NSColor?, blink: Bool = false) -> CGImage {
        let w = grid[0].count * cell, h = grid.count * cell
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (r, row) in grid.enumerated() {
            for (c, ch) in row.enumerated() where ch != "." {
                let isEye = ch == "o"
                if isEye && eyes == nil { continue }
                let color = isEye && !blink ? eyes! : body
                ctx.setFillColor(color.cgColor)
                ctx.fill(CGRect(x: c * cell, y: (grid.count - 1 - r) * cell, width: cell, height: cell))
            }
        }
        return ctx.makeImage()!
    }

    /// Template image for the menu bar: the crab with see-through eyes.
    static func menuBarImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { rect in
            let cell = rect.width / CGFloat(grid[0].count)
            NSColor.black.setFill()
            for (r, row) in grid.enumerated() {
                for (c, ch) in row.enumerated() where ch == "#" {
                    NSRect(x: CGFloat(c) * cell, y: CGFloat(grid.count - 1 - r) * cell, width: cell, height: cell).fill()
                }
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// Clay and ink from the crab, and the recap bubble's look. Text colours meet WCAG AA (4.5:1) on the
/// backgrounds Search draws on, and AAA (7:1) with Increase Contrast (docs/search.md has the ratios).
enum Brand {
    static let clay = PixelCrab.clay
    static let ink = PixelCrab.ink
    /// Clay as text. Clay itself is 2.7:1 on white and 4.5:1 on dark grey: too faint for small text.
    static let clayText = adaptive(light: 0xA34E30, dark: 0xE08A6C, lightHigh: 0x7A3820, darkHigh: 0xEDAE97)
    /// The selected row: a clay tint (16% light, 26% dark), stronger with Increase Contrast.
    static let selection = adaptive(light: 0xF9E9E4, dark: 0x4F352D, lightHigh: 0xF2D1C6, darkHigh: 0x784939)
    /// Matched words: a stronger tint than the selection, so they still show in the selected row.
    static let highlight = adaptive(light: 0xF2D1C6, dark: 0x784939, lightHigh: 0xEAB9A7, darkHigh: 0x784939)
    /// Quiet text (labels, notes, "est."). The system's secondary grey is 3.95:1 on white, under AA.
    /// Light #666666: 5.74:1 on white, 5.04:1 on #F0F0F0. Dark #9A9A9A: 5.92:1 on #1E1E1E, 5.24:1 on the
    /// panes' #282828, 4.96:1 on #2C2C2C. Increase Contrast: #4D4D4D 7.42:1 / #BDBDBD 7.43:1 at worst.
    static let quietText = adaptive(light: 0x666666, dark: 0x9A9A9A, lightHigh: 0x4D4D4D, darkHigh: 0xBDBDBD)

    /// The Clawds' thought bubble (Bubble.swift), for Search's empty states too.
    static let bubbleFill = NSColor(name: nil) {
        dark($0) ? NSColor(srgbRed: 0.17, green: 0.165, blue: 0.155, alpha: 0.98) : NSColor(srgbRed: 1, green: 1, blue: 0.995, alpha: 0.98)
    }
    static let bubbleStroke = NSColor(name: nil) { dark($0) ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.09) }

    private static func dark(_ a: NSAppearance) -> Bool {
        a.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
    }

    private static func adaptive(light: Int, dark: Int, lightHigh: Int, darkHigh: Int) -> NSColor {
        func rgb(_ v: Int) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
        }
        return NSColor(name: nil) { a in
            switch a.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua?: return rgb(dark)
            case .accessibilityHighContrastAqua?: return rgb(lightHigh)
            case .accessibilityHighContrastDarkAqua?: return rgb(darkHigh)
            default: return rgb(light)
            }
        }
    }
}
