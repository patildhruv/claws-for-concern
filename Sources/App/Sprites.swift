import AppKit
import QuartzCore

/// One Clawd animation at 1 px per art pixel (see `Art`). Drawn with nearest-neighbour scaling.
struct Sprite {
    let name: String
    let width: Int
    let height: Int
    let frames: [CGImage]
    let delays: [Double]  // seconds

    var duration: Double { delays.reduce(0, +) }

    /// A Core Animation loop over the frames. Runs in the render server: no CPU per frame.
    func animation() -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: "contents")
        a.values = frames
        var t = 0.0
        var times: [NSNumber] = []
        for d in delays { times.append(NSNumber(value: t / max(duration, 0.001))); t += d }
        a.keyTimes = times
        a.calculationMode = .discrete
        a.duration = max(duration, 0.1)
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        return a
    }
}

final class SpriteLibrary {
    static let shared = SpriteLibrary()

    /// Waving reads as "hey, over here": it is reserved for sessions that need you.
    static let blocked = "Waving"
    /// Shown with a grey badge when a turn died on an API error.
    static let failed = "CrabWalking"
    /// Stand-in until the art has been downloaded (our own drawing, not Anthropic's).
    static let placeholder = "Placeholder"
    /// Finished sessions get one of these (plus any extra art), stable per session.
    static let finishedDefaults = ["JumpingHappy", "Dancing", "Cloud-once", "RacingCar"]

    private(set) var sprites: [String: Sprite] = [:]
    /// Tallest sprite, so the strip height never jumps as Clawds come and go.
    private(set) var maxHeight = 16

    init(directory: URL = Paths.art) { reload(directory: directory) }

    func reload(directory: URL = Paths.art) {
        var out: [String: Sprite] = [SpriteLibrary.placeholder: SpriteLibrary.makePlaceholder()]
        let metaURL = directory.appendingPathComponent("sprites.json")
        if let data = try? Data(contentsOf: metaURL),
           let metas = try? JSONDecoder().decode([String: Art.Meta].self, from: data) {
            for (name, m) in metas {
                guard let src = CGImageSourceCreateWithURL(directory.appendingPathComponent("\(name).png") as CFURL, nil),
                      let sheet = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
                let frames = (0..<m.frames).compactMap { sheet.cropping(to: CGRect(x: $0 * m.w, y: 0, width: m.w, height: m.h)) }
                guard frames.count == m.frames, m.delays.count == m.frames else { continue }
                out[name] = Sprite(name: name, width: m.w, height: m.h, frames: frames, delays: m.delays.map { Double($0) / 1000 })
            }
        }
        sprites = out
        maxHeight = out.values.map(\.height).max() ?? 16
    }

    var hasArt: Bool { sprites.count > 1 }

    subscript(name: String) -> Sprite? { sprites[name] ?? sprites[SpriteLibrary.placeholder] }

    /// Every animation finished sessions may use: not the "needs you" or "error" ones, not those you
    /// switched off in Settings (unless you switched off all of them).
    var finishedPool: [String] {
        let reserved: Set<String> = [SpriteLibrary.placeholder, "Lurking", Settings.blockedSprite, Settings.failedSprite]
        let extras = sprites.keys.filter { !reserved.contains($0) && !SpriteLibrary.finishedDefaults.contains($0) }.sorted()
        let all = (SpriteLibrary.finishedDefaults + extras).filter { sprites[$0] != nil && !reserved.contains($0) }
        let on = all.filter { !Settings.finishedDisabled.contains($0) }
        return on.isEmpty ? all : on
    }

    /// A finished-pool sprite for `sessionId`, avoiding ones already on screen when possible.
    func finishedSprite(for sessionId: String, avoiding used: Set<String>) -> String {
        let pool = finishedPool
        guard !pool.isEmpty else { return SpriteLibrary.placeholder }
        var h: UInt32 = 2166136261
        for b in sessionId.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        let start = Int(h % UInt32(pool.count))
        for k in 0..<pool.count where !used.contains(pool[(start + k) % pool.count]) {
            return pool[(start + k) % pool.count]
        }
        return pool[start]
    }

    private static func makePlaceholder() -> Sprite {
        let a = PixelCrab.image(cell: 2, body: PixelCrab.clay, eyes: PixelCrab.ink)
        let b = PixelCrab.image(cell: 2, body: PixelCrab.clay, eyes: PixelCrab.ink, blink: true)
        return Sprite(name: placeholder, width: a.width, height: a.height, frames: [a, a, a, b], delays: [1.2, 1.2, 1.2, 0.15])
    }
}

// `PixelCrab`, our own crab (menu bar, stand-in sprite), is in Sources/Search/Brand.swift, which the
// search helper compiles too.
