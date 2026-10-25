import AppKit

/// iTerm2 over AppleScript. A session is matched by its tty, which the hook records from the
/// Claude process: exact, even with many tabs in one folder.
final class ITermAdapter: TerminalAdapter {
    let id = "iterm2"
    let name = "iTerm2"
    let scriptedBundleID: String? = "com.googlecode.iterm2"

    func claims(_ s: SessionState) -> Bool {
        (s.env("TERM_PROGRAM") ?? s.termProgram) == "iTerm.app" || s.env("ITERM_SESSION_ID") != nil
    }

    func paneID(for s: SessionState) -> String? { s.tty }

    func lookedAt(front: FrontApp) -> Set<String> {
        guard front.bundleID == scriptedBundleID,
              let tty = Script.run("""
              with timeout of 2 seconds
                tell application id "com.googlecode.iterm2" to get tty of current session of current window
              end timeout
              """, cacheKey: "iterm2.focused")?.stringValue else { return [] }
        return [tty]
    }

    func focus(paneID: String, session: SessionState) -> Bool {
        Script.run(ITermAdapter.focusScript(tty: paneID))?.stringValue == "ok"
    }

    static func focusScript(tty: String) -> String {
        """
        with timeout of 3 seconds
          tell application id "com.googlecode.iterm2"
            repeat with w in windows
              repeat with t in tabs of w
                repeat with s in sessions of t
                  if tty of s is \(Script.quote(tty)) then
                    select w
                    select t
                    select s
                    activate
                    return "ok"
                  end if
                end repeat
              end repeat
            end repeat
          end tell
        end timeout
        return ""
        """
    }

    func health() -> AdapterHealth {
        Automation.healthFor("com.googlecode.iterm2", appName: "iTerm2",
                             ready: "Finds each session's tab by its terminal device, clears its Clawd when you look, and jumps there on click.")
    }
}

/// Terminal.app over AppleScript, matched by tty like iTerm2.
final class AppleTerminalAdapter: TerminalAdapter {
    let id = "terminal"
    let name = "Terminal"
    let scriptedBundleID: String? = "com.apple.Terminal"

    func claims(_ s: SessionState) -> Bool { (s.env("TERM_PROGRAM") ?? s.termProgram) == "Apple_Terminal" }

    func paneID(for s: SessionState) -> String? { s.tty }

    func lookedAt(front: FrontApp) -> Set<String> {
        guard front.bundleID == scriptedBundleID,
              let tty = Script.run("""
              with timeout of 2 seconds
                tell application id "com.apple.Terminal" to get tty of selected tab of front window
              end timeout
              """, cacheKey: "terminal.focused")?.stringValue else { return [] }
        return [tty]
    }

    func focus(paneID: String, session: SessionState) -> Bool {
        Script.run(AppleTerminalAdapter.focusScript(tty: paneID))?.stringValue == "ok"
    }

    static func focusScript(tty: String) -> String {
        """
        with timeout of 3 seconds
          tell application id "com.apple.Terminal"
            repeat with w in windows
              repeat with t in tabs of w
                if tty of t is \(Script.quote(tty)) then
                  set selected tab of w to t
                  set index of w to 1
                  activate
                  return "ok"
                end if
              end repeat
            end repeat
          end tell
        end timeout
        return ""
        """
    }

    func health() -> AdapterHealth {
        Automation.healthFor("com.apple.Terminal", appName: "Terminal",
                             ready: "Finds each session's tab by its terminal device, clears its Clawd when you look, and jumps there on click.")
    }
}
