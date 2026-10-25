// Draws AppIcon.icns: our own pixel crab, slightly worried, under a thought bubble.
// Usage: xcrun swift tools/make-icon.swift <output dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources", isDirectory: true)
let crab = [
    ".#########.",
    ".#########.",
    "##o#####o##",
    "###########",
    ".#########.",
    ".#########.",
    ".#.#...#.#.",
    ".#.#...#.#.",
]
let clay = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
let ink = NSColor(srgbRed: 0.078, green: 0.078, blue: 0.075, alpha: 1)

func drawIcon(_ s: CGFloat) {
    // macOS icon grid: 824/1024 body, centred, with a soft drop shadow.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset * 1.12, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.225
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = NSColor(white: 0, alpha: 0.28)
    sh.shadowBlurRadius = s * 0.022
    sh.shadowOffset = NSSize(width: 0, height: -s * 0.010)
    sh.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.995, green: 0.975, blue: 0.945, alpha: 1),
                        NSColor(srgbRed: 0.935, green: 0.885, blue: 0.815, alpha: 1)])!
        .draw(in: body, angle: -90)
    // Ground shadow under the crab.
    let shadowRect = NSRect(x: body.midX - body.width * 0.30, y: body.minY + body.height * 0.155,
                            width: body.width * 0.60, height: body.height * 0.05)
    NSColor(srgbRed: 0.55, green: 0.40, blue: 0.30, alpha: 0.16).setFill()
    NSBezierPath(ovalIn: shadowRect).fill()

    // The crab: 11 x 8 cells.
    let cell = (body.width * 0.56 / 11).rounded()
    let cw = cell * 11, chh = cell * 8
    let ox = (body.midX - cw / 2).rounded(), oy = (body.minY + body.height * 0.175).rounded()
    for (r, row) in crab.enumerated() {
        for (c, ch) in row.enumerated() where ch != "." {
            let rect = NSRect(x: ox + CGFloat(c) * cell, y: oy + CGFloat(7 - r) * cell, width: cell, height: cell)
            (ch == "o" ? ink : clay).setFill()
            rect.fill()
        }
    }

    // Thought bubble with a pixel "!".
    let bubble = NSRect(x: body.minX + body.width * 0.52, y: oy + chh + body.height * 0.115,
                        width: body.width * 0.36, height: body.width * 0.27)
    let bubblePath = NSBezierPath(roundedRect: bubble, xRadius: bubble.height * 0.5, yRadius: bubble.height * 0.5)
    let t1 = NSBezierPath(ovalIn: NSRect(x: bubble.minX + bubble.width * 0.05, y: bubble.minY - body.width * 0.062,
                                         width: body.width * 0.065, height: body.width * 0.065))
    let t2 = NSBezierPath(ovalIn: NSRect(x: bubble.minX - body.width * 0.025, y: bubble.minY - body.width * 0.098,
                                         width: body.width * 0.038, height: body.width * 0.038))
    NSGraphicsContext.saveGraphicsState()
    let bs = NSShadow()
    bs.shadowColor = NSColor(srgbRed: 0.45, green: 0.30, blue: 0.20, alpha: 0.22)
    bs.shadowBlurRadius = s * 0.012
    bs.shadowOffset = NSSize(width: 0, height: -s * 0.004)
    bs.set()
    NSColor.white.setFill()
    bubblePath.fill(); t1.fill(); t2.fill()
    NSGraphicsContext.restoreGraphicsState()
    // A pixel "!": a 1 x 3 bar and a dot, centred.
    let px = (bubble.height * 0.13).rounded()
    let bx = (bubble.midX - px / 2).rounded()
    let top = (bubble.midY + px * 1.9).rounded()
    clay.setFill()
    NSRect(x: bx, y: top - px * 3, width: px, height: px * 3).fill()
    NSRect(x: bx, y: top - px * 4.6, width: px, height: px).fill()
    NSGraphicsContext.restoreGraphicsState()
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = pt * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .none
    drawIcon(CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: out.appendingPathComponent("AppIcon-1024.png"))
try? FileManager.default.copyItem(at: iconset.appendingPathComponent("icon_512x512@2x.png"),
                                  to: out.appendingPathComponent("AppIcon-1024.png"))
print("wrote \(out.path)/AppIcon.icns")
