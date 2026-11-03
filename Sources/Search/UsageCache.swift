import Foundation

/// Each session's figures on disk, so a reopen reads only transcripts that changed: one file in the
/// helper's own cache folder (`~/Library/Caches/<helper bundle ID>/usage.json`, never under ~/.claude),
/// keyed by transcript path, with the size and modification time of the transcript and each of its
/// subagent files. Anything else that changes the figures starts it afresh: the format, the price
/// table and the time zone (days and hours are local).
struct UsageCache {
    /// Bump when `SessionUsage` or the reader's rules change.
    static let version = 1

    struct Stamp: Codable, Equatable {
        var path: String
        var size: Int
        var mtime: Double
    }

    struct Entry: Codable {
        var stamps: [Stamp]
        var usage: SessionUsage
    }

    private struct File: Codable {
        var key: String
        var entries: [String: Entry]
    }

    let url: URL
    /// The zone the stored days and hours are in: the reader's (`Calendar.usage`).
    var timeZone = TimeZone.current

    /// `CLAWS_SEARCH_CACHE` moves it, for timing a first read without touching the real one.
    static var folder: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAWS_SEARCH_CACHE"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches", isDirectory: true)
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.github.patildhruv.claws-for-concern.search",
                                             isDirectory: true)
    }

    init(url: URL = UsageCache.folder.appendingPathComponent("usage.json"), timeZone: TimeZone = .current) {
        self.url = url
        self.timeZone = timeZone
    }

    /// What the stored figures depend on besides the files themselves.
    var key: String { "\(Self.version) prices \(Pricing.checked) tz \(timeZone.identifier)" }

    func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: url), let file = try? Self.decoder.decode(File.self, from: data),
              file.key == key else { return [:] }
        return file.entries
    }

    func save(_ entries: [String: Entry]) {
        guard let data = try? Self.encoder.encode(File(key: key, entries: entries)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

extension Calendar {
    /// Days and hours for the figures: Gregorian, so "yyyy-MM-dd" means what it says, in your time zone.
    static var usage: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }
}
