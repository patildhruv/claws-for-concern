import Foundation

/// Which parts of a transcript a search looks at. Stored as bits on every index posting.
struct Scope: OptionSet, Hashable {
    let rawValue: UInt8
    static let prompts = Scope(rawValue: 1)
    static let replies = Scope(rawValue: 2)
    static let toolCalls = Scope(rawValue: 4)
    static let meta = Scope(rawValue: 8)        // name, folder, session id, branch: always searched
    static let subagents = Scope(rawValue: 16)
    static let standard: Scope = [.prompts, .replies, .toolCalls, .subagents]
}

/// The list's order. Cost and Context put the highest first and sessions without figures last
/// (`UsageRank`); the raw value is what the Sort setting stores.
enum SortMode: String, CaseIterable {
    case relevance, recent, cost, context

    var title: String {
        switch self {
        case .relevance: return "Relevance"
        case .recent: return "Recent"
        case .cost: return "Cost"
        case .context: return "Context"
        }
    }

    /// Sorted by a usage figure, so the order changes when the figures do.
    var usesFigures: Bool { self == .cost || self == .context }
}

struct Message {
    enum Kind: UInt8 { case prompt, reply, toolCall }
    let kind: Kind
    let subagent: Bool
    let text: String
    let timestamp: String?

    var scope: Scope {
        if subagent { return .subagents }
        switch kind {
        case .prompt: return .prompts
        case .reply: return .replies
        case .toolCall: return .toolCalls
        }
    }
}

/// Where the session's display name came from, in the order Claude Code's /resume picks it.
enum TitleSource: String {
    case agentName = "agent name"
    case customTitle = "/rename"
    case aiTitle = "auto-generated title"
    case summary = "summary"
    case firstPrompt = "first prompt"
    case fallback = "session id"
}

struct Session: Identifiable {
    let id: String
    let file: URL
    let projectDir: String
    /// Where the session was started, i.e. the folder its transcript is filed under. `claude --resume`
    /// looks in the project folder for the directory it runs in, so this is where to resume from.
    let cwd: String?
    /// The first working directory recorded inside the transcript, when it differs from `cwd`
    /// (branched sessions carry the original's lines; moved projects keep their old paths).
    let recordedCwd: String?
    /// True when no recorded directory matches the project folder and it couldn't be found on disk.
    let cwdUncertain: Bool
    /// True when `cwd` is a folder recorded in the transcript (not found by walking the disk): the only
    /// kind Claws for Concern reads back for itself before it opens a tab there.
    let folderRecorded: Bool
    let title: String
    let titleSource: TitleSource
    let altTitles: [String]
    let firstPrompt: String?
    let gitBranch: String?
    let entrypoint: String?
    let created: Date?
    let modified: Date
    let fileSize: Int
    let subagentCount: Int
    let promptCount: Int
    let messages: [Message]

    /// Text that is always searchable: names, folder, id, branch.
    var metaText: String {
        ([title] + altTitles + [cwd ?? projectDir, id, gitBranch ?? ""]).joined(separator: "\n")
    }

    var displayCwd: String { cwd.map(Paths.abbreviate) ?? projectDir }

    /// A session ID (title-only `<uuid>.orphaned-…` stubs are not), a folder from the transcript, and
    /// that folder not known to be gone.
    var canResume: Bool { whyNotResumable == nil }

    var whyNotResumable: String? {
        if !ResumeRequest.isSessionID(id) { return "Not a session Claude Code can resume" }
        if !folderRecorded { return "Its folder is not recorded in the transcript" }
        if folderMissing == true { return "Its folder no longer exists" }
        return nil
    }

    /// `cd <folder> && <Claws for Concern's resume command>`, for the clipboard; nil unless the ID is
    /// a session ID.
    /// Under `--demo` the default template, never your own (it may hold a personal alias).
    func resumeCommand(template: String = Demo.active ? ResumeCommand.defaultTemplate : ResumeCommand.template()) -> String? {
        guard ResumeRequest.isSessionID(id) else { return nil }
        let run = ResumeCommand.expand(template, id: Shell.quote(id))
        guard let cwd else { return run }
        return "cd \(Shell.quote(cwd)) && \(run)"
    }

    /// nil when the folder can't be checked without a privacy prompt (Documents, Desktop, ...).
    var folderMissing: Bool? {
        guard let cwd, !Paths.isPrivacyProtected(cwd) else { return nil }
        return !FileManager.default.fileExists(atPath: cwd)
    }
}

// The encoding itself is in ResumeRequest.swift, which the app compiles too.
extension ProjectDirs {
    /// The folder a project folder name stands for, found by walking the disk. Never lists a
    /// privacy-protected folder, so it can't trigger a permission prompt.
    static func resolve(_ dirName: String) -> String? {
        guard dirName.hasPrefix("-"), dirName.count <= limit else { return nil }
        let fm = FileManager.default
        func isDir(_ p: String) -> Bool {
            var d: ObjCBool = false
            return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue
        }
        func walk(_ dir: String, _ rest: Substring) -> String? {
            guard !Paths.isPrivacyProtected(dir), let kids = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
            for kid in kids.sorted() {
                let piece = "-" + encode(kid)
                let path = dir == "/" ? "/" + kid : dir + "/" + kid
                // Before isDir, which follows a link: one into ~/Documents would raise the prompt.
                guard rest == piece || rest.hasPrefix(piece + "-"), !Paths.isPrivacyProtected(path) else { continue }
                if rest == piece {
                    if isDir(path) { return path }
                } else if isDir(path), let found = walk(path, rest.dropFirst(piece.count)) {
                    return found
                }
            }
            return nil
        }
        return walk("/", Substring(dirName))
    }
}

enum Paths {
    static let realHome = NSHomeDirectory()
    /// Your home folder, or the made-up one under `--demo`. The loader's ~/.claude/projects, the folder
    /// checks and `~` in what is shown all follow it.
    static var home = realHome

    static func abbreviate(_ path: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Folders where even a stat makes macOS ask for permission on behalf of this app (other apps'
    /// containers ask too), also under the data volume's firmlinked path. Your real home's stay
    /// protected under `--demo`.
    static var protectedRoots: [String] {
        let mine = Set([realHome, home]).flatMap { h in
            ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage",
             "Library/Containers", "Library/Group Containers"].map { h + "/" + $0 }
        }
        return mine + mine.map { "/System/Volumes/Data" + $0 } + ["/Volumes"]
    }

    /// True for a path in a protected folder, also when a symbolic link along it leads into one. Each
    /// prefix is looked at with lstat and destinationOfSymbolicLink, which never follow a link, and
    /// only once the text says the whole path is outside every protected folder.
    static func isPrivacyProtected(_ path: String) -> Bool { isProtected(path, hops: 0) }

    private static func isProtected(_ path: String, hops: Int) -> Bool {
        if protectedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        guard hops < 16 else { return true }    // a link loop: leave it alone
        let parts = path.split(separator: "/").map(String.init)
        var prefix = ""
        for (i, part) in parts.enumerated() {
            prefix += "/" + part
            var st = stat()
            guard lstat(prefix, &st) == 0 else { return false }    // nothing there, so no link to follow
            guard st.st_mode & S_IFMT == S_IFLNK else { continue }
            guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: prefix) else { return true }
            let base = dest.hasPrefix("/") ? dest : (prefix as NSString).deletingLastPathComponent + "/" + dest
            return isProtected(normalize(([base] + parts[(i + 1)...]).joined(separator: "/")), hops: hops + 1)
        }
        return false
    }

    /// `.`, `..` and repeated slashes removed by text alone (`standardizingPath` may look on disk).
    static func normalize(_ path: String) -> String {
        var out: [Substring] = []
        for c in path.split(separator: "/") where c != "." {
            if c == ".." { _ = out.popLast() } else { out.append(c) }
        }
        return "/" + out.joined(separator: "/")
    }
}

enum Shell {
    /// Quotes a path for zsh. Plain paths stay readable, with the home folder as ~.
    static func quote(_ path: String) -> String {
        if path.range(of: #"^[A-Za-z0-9_./+@:,-]+$"#, options: .regularExpression) != nil {
            return Paths.abbreviate(path)
        }
        return "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
