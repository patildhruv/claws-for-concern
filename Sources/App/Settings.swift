import AppKit

/// User preferences (UserDefaults, domain io.github.patildhruv.claws-for-concern). Posting `.settingsChanged`
/// after any change lets the overlay and tracker re-read them.
enum Settings {
    static let d = UserDefaults.standard

    enum Size: String, CaseIterable {
        case small, medium, large
        /// Points per art pixel. Small = 2 device pixels per art pixel on Retina, so a Clawd is
        /// 24 x 17 pt; the overlay snaps this to whole device pixels so the art stays crisp.
        var artPoints: CGFloat { [.small: 1, .medium: 1.5, .large: 2][self]! }
        var label: String { rawValue.capitalized }
    }

    enum Corner: String, CaseIterable {
        case bottomLeft, bottomRight, topLeft, topRight
        var label: String {
            [.bottomLeft: "Bottom Left", .bottomRight: "Bottom Right",
             .topLeft: "Top Left", .topRight: "Top Right"][self]!
        }
        var isLeft: Bool { self == .bottomLeft || self == .topLeft }
        var isBottom: Bool { self == .bottomLeft || self == .bottomRight }
    }

    enum ScreenChoice: String, CaseIterable {
        case primary, mouse
        var label: String { self == .primary ? "Main Display (menu bar)" : "Display With the Pointer" }
    }

    static var size: Size {
        get { Size(rawValue: d.string(forKey: "size") ?? "") ?? .small }
        set { d.set(newValue.rawValue, forKey: "size"); changed() }
    }
    static var corner: Corner {
        get { Corner(rawValue: d.string(forKey: "corner") ?? "") ?? .bottomLeft }
        set { d.set(newValue.rawValue, forKey: "corner"); changed() }
    }
    static var screen: ScreenChoice {
        get { ScreenChoice(rawValue: d.string(forKey: "screen") ?? "") ?? .primary }
        set { d.set(newValue.rawValue, forKey: "screen"); changed() }
    }
    static var showBlocked: Bool { get { bool("showBlocked", true) } set { d.set(newValue, forKey: "showBlocked"); changed() } }
    static var showFinished: Bool { get { bool("showFinished", true) } set { d.set(newValue, forKey: "showFinished"); changed() } }
    static var showFailed: Bool { get { bool("showFailed", true) } set { d.set(newValue, forKey: "showFailed"); changed() } }
    static var recaps: Bool { get { bool("recaps", true) } set { d.set(newValue, forKey: "recaps"); changed() } }
    /// Hide a finished Clawd you never looked at after this many hours (0 = never).
    static var expireHours: Int {
        get { d.object(forKey: "expireHours") == nil ? 12 : d.integer(forKey: "expireHours") }
        set { d.set(newValue, forKey: "expireHours"); changed() }
    }
    /// What "Copy Resume Command" puts on the clipboard; {id} is the session ID.
    /// Change it with: defaults write io.github.patildhruv.claws-for-concern resumeCommand "my-wrapper -r {id}"
    static var resumeCommand: String { d.string(forKey: "resumeCommand") ?? "claude --resume {id}" }
    /// ⌃⌥⌘C jumps to the session that most needs you.
    static var hotKey: Bool { get { bool("hotKey", true) } set { d.set(newValue, forKey: "hotKey"); changed() } }
    static var didAskHooks: Bool { get { d.bool(forKey: "didAskHooks") } set { d.set(newValue, forKey: "didAskHooks") } }
    static var didAskLogin: Bool { get { d.bool(forKey: "didAskLogin") } set { d.set(newValue, forKey: "didAskLogin") } }

    private static func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
    private static func changed() { NotificationCenter.default.post(name: .settingsChanged, object: nil) }
}

extension Notification.Name {
    static let settingsChanged = Notification.Name("ClawsSettingsChanged")
}
