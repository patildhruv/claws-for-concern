import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Builds the Clawd sprite sheets on first launch from the GIFs claude.ai serves. The art is
/// Anthropic's, so it is never committed or bundled: each install downloads and converts it.
///
/// Every official Clawd GIF draws on the same 55 x 37 art-pixel canvas (50 px per art pixel at
/// 2750 x 1850, ~21.6 px at 1189 x 800). Sampling each cell's centre recovers the art at exactly
/// 1 px per art pixel, which the overlay scales back up with nearest-neighbour filtering.
enum Art {
    static let gridW = 55, gridH = 37

    /// The Clawd animations claude.ai itself uses.
    static let builtIn: [(name: String, path: String)] = [
        ("Waving", "/images/clawd/core/Clawd-Waving.gif"),
        ("CrabWalking", "/images/clawd/core/Clawd-CrabWalking.gif"),
        ("JumpingHappy", "/images/home-page-assets/Clawd-JumpingHappy.gif"),
        ("Dancing", "/images/spotlights/claude-code-celebration/Clawd-Dancing.gif"),
        ("RacingCar", "/images/clawd/persona/Clawd-RacingCar.gif"),
        ("Cloud-once", "/images/clawd/persona/Clawd-Cloud-once.gif"),
    ]

    static var sources: [(name: String, url: URL)] {
        var out = builtIn.map { ($0.name, URL(string: "https://claude.ai" + $0.path)!) }
        if let text = try? String(contentsOf: Paths.extraArt, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let s = line.trimmingCharacters(in: .whitespaces)
                guard !s.hasPrefix("#"), let u = URL(string: s), u.scheme == "https" else { continue }
                var name = (u.lastPathComponent as NSString).deletingPathExtension
                if name.hasPrefix("Clawd-") { name.removeFirst(6) }
                if !out.contains(where: { $0.0 == name }) { out.append((name, u)) }
            }
        }
        return out
    }

    struct Meta: Codable { var w: Int; var h: Int; var frames: Int; var delays: [Int]; var x: Int; var y: Int }

    static var metaURL: URL { Paths.art.appendingPathComponent("sprites.json") }

    static func loadMeta() -> [String: Meta] {
        guard let d = try? Data(contentsOf: metaURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Meta].self, from: d)) ?? [:]
    }

    static var missing: [(name: String, url: URL)] {
        let have = loadMeta()
        return sources.filter { s in
            have[s.name] != nil && FileManager.default.fileExists(atPath: Paths.art.appendingPathComponent("\(s.name).png").path) ? false : true
        }
    }

    /// Downloads and converts whatever is missing. Runs off the main thread; `done` on main.
    static func fetchMissing(done: @escaping (_ added: [String], _ failed: [String]) -> Void) {
        let todo = missing
        guard !todo.isEmpty else { done([], []); return }
        DispatchQueue.global(qos: .utility).async {
            var added: [String] = [], failed: [String] = []
            try? FileManager.default.createDirectory(at: Paths.art, withIntermediateDirectories: true)
            var meta = loadMeta()
            for s in todo {
                guard let data = download(s.url), let sheet = convert(data) else {
                    failed.append(s.name)
                    AppLog.write("art: could not fetch or convert \(s.url.absoluteString)")
                    continue
                }
                let png = Paths.art.appendingPathComponent("\(s.name).png")
                guard writePNG(sheet.image, to: png) else { failed.append(s.name); continue }
                meta[s.name] = sheet.meta
                added.append(s.name)
            }
            if !added.isEmpty, let d = try? JSONEncoder().encode(meta) { try? d.write(to: metaURL, options: .atomic) }
            DispatchQueue.main.async { done(added, failed) }
        }
    }

    private static func download(_ url: URL) -> Data? {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("image/gif,image/*", forHTTPHeaderField: "Accept")
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode == 200,
               (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("gif") { result = data }
            sem.signal()
        }.resume()
        sem.wait()
        return result
    }

    /// GIF -> one horizontal strip of frames, cropped to the union of all frames' pixels.
    static func convert(_ gif: Data) -> (image: CGImage, meta: Meta)? {
        guard let src = CGImageSourceCreateWithData(gif as CFData, nil) else { return nil }
        let n = CGImageSourceGetCount(src)
        guard n > 0 else { return nil }
        var grids: [[UInt8]] = []
        var delays: [Int] = []
        var buf: [UInt8] = []
        for i in 0..<n {
            guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { return nil }
            let w = img.width, h = img.height
            if buf.count != w * h * 4 { buf = [UInt8](repeating: 0, count: w * h * 4) }
            let ok: Bool = buf.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.interpolationQuality = .none
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { return nil }
            var grid = [UInt8](repeating: 0, count: gridW * gridH * 4)
            for gy in 0..<gridH {
                let y = min(h - 1, Int((Double(gy) + 0.5) * Double(h) / Double(gridH)))
                for gx in 0..<gridW {
                    let x = min(w - 1, Int((Double(gx) + 0.5) * Double(w) / Double(gridW)))
                    let s = (y * w + x) * 4, d = (gy * gridW + gx) * 4
                    if buf[s + 3] >= 128 { grid[d] = buf[s]; grid[d + 1] = buf[s + 1]; grid[d + 2] = buf[s + 2]; grid[d + 3] = 255 }
                }
            }
            grids.append(grid)
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gifProps = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gifProps?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gifProps?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.08
            delays.append(max(20, Int((delay * 1000).rounded())))
        }
        var x0 = gridW, y0 = gridH, x1 = -1, y1 = -1
        for g in grids {
            for y in 0..<gridH { for x in 0..<gridW where g[(y * gridW + x) * 4 + 3] != 0 {
                x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
            } }
        }
        guard x1 >= x0, y1 >= y0 else { return nil }
        let cw = x1 - x0 + 1, ch = y1 - y0 + 1
        let sw = cw * grids.count
        var sheet = [UInt8](repeating: 0, count: sw * ch * 4)
        for (f, g) in grids.enumerated() {
            for y in 0..<ch {
                let s = ((y0 + y) * gridW + x0) * 4
                let d = (y * sw + f * cw) * 4
                sheet.replaceSubrange(d..<d + cw * 4, with: g[s..<s + cw * 4])
            }
        }
        guard let provider = CGDataProvider(data: Data(sheet) as CFData),
              let image = CGImage(width: sw, height: ch, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: sw * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return (image, Meta(w: cw, h: ch, frames: grids.count, delays: delays, x: x0, y: y0))
    }

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}
