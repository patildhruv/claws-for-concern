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

enum SortMode: String { case relevance, recent }

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

    /// Claude Code's resume menu lists these; title-only `<uuid>.orphaned-…` stubs it cannot resume.
    var canResume: Bool { cwd != nil && ResumeRequest.isSessionID(id) }

    /// `cd <folder> && <Claws for Concern's resume command>`, for the clipboard.
    func resumeCommand(template: String = ResumeCommand.template()) -> String {
        let run = ResumeCommand.expand(template, id: id)
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
                if rest == piece {
                    if isDir(path) { return path }
                } else if rest.hasPrefix(piece + "-"), isDir(path), let found = walk(path, rest.dropFirst(piece.count)) {
                    return found
                }
            }
            return nil
        }
        return walk("/", Substring(dirName))
    }
}

enum Paths {
    static let home = NSHomeDirectory()

    static func abbreviate(_ path: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Folders where even a stat makes macOS ask for permission on behalf of this app.
    static func isPrivacyProtected(_ path: String) -> Bool {
        let roots = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"].map { home + "/" + $0 } + ["/Volumes"]
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
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
