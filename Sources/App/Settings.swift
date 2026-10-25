import AppKit

/// Every preference, backed by UserDefaults (domain io.github.patildhruv.claws-for-concern).
/// The Settings window binds to the same keys with @AppStorage; AppDelegate turns any defaults
/// change into one `.settingsChanged` notification, which the overlay, tracker and menu observe.
enum Settings {
    static let d = UserDefaults.standard

    enum Key {
        static let size = "size", corner = "corner", screen = "screen"
        static let edgeMargin = "edgeMargin", spacing = "spacing", opacity = "opacity"
        static let animate = "animate", shadows = "shadows", badges = "badges"
        static let blockedSprite = "blockedSprite", failedSprite = "failedSprite", finishedDisabled = "finishedDisabled"
        static let showQuestions = "showQuestions", showPermissions = "showPermissions", showPlans = "showPlans"
        static let showInput = "showInput", showFailed = "showFailed", showFinished = "showFinished"
        static let expireHours = "expireHours", maxClawds = "maxClawds"
        static let clearOnLook = "clearOnLook", lookSeconds = "lookSeconds"
        static let sound = "sound", soundName = "soundName", notify = "notify", notifyFinished = "notifyFinished"
        static let bubble = "bubble", hoverDelay = "hoverDelay", bubbleTextSize = "bubbleTextSize"
        static let bubbleLines = "bubbleLines", bubbleTitle = "bubbleTitle", bubbleState = "bubbleState", bubbleAge = "bubbleAge"
        static let recaps = "recaps", recapModel = "recapModel", recapLength = "recapLength"
        static let recapInstructions = "recapInstructions", claudePath = "claudePath"
        static let clickAction = "clickAction", hotKey = "hotKey", hotKeyCode = "hotKeyCode", hotKeyMods = "hotKeyMods"
        static let resumeCommand = "resumeCommand", menuBarIcon = "menuBarIcon", menuBarCount = "menuBarCount"
        static let pausedUntil = "pausedUntil", didAskHooks = "didAskHooks"
        static let lockPosition = "lockPosition", snap = "snap", avoidDock = "avoidDock"
    }

    // MARK: Appearance

    enum Size: String, CaseIterable, Identifiable {
        case small, medium, large
        var id: String { rawValue }
        /// Points per art pixel. Small = 2 device pixels per art pixel on Retina, so a Clawd is
        /// 24 x 17 pt; the overlay snaps this to whole device pixels so the art stays crisp.
        var artPoints: CGFloat { [.small: 1, .medium: 1.5, .large: 2][self]! }
        var label: String { rawValue.capitalized }
    }

    enum Corner: String, CaseIterable, Identifiable {
        case bottomLeft, bottomRight, topLeft, topRight
        var id: String { rawValue }
        var label: String {
            [.bottomLeft: "Bottom Left", .bottomRight: "Bottom Right", .topLeft: "Top Left", .topRight: "Top Right"][self]!
        }
        var isLeft: Bool { self == .bottomLeft || self == .topLeft }
        var isBottom: Bool { self == .bottomLeft || self == .bottomRight }
    }

    static var size: Size { Size(rawValue: string(Key.size)) ?? .small }
    /// The default spot on displays you have not arranged yourself.
    static var corner: Corner { Corner(rawValue: string(Key.corner)) ?? .bottomLeft }
    /// "follow" (the display you are using), "primary", or "display:<display UUID>".
    static var screen: String {
        let v = d.string(forKey: Key.screen) ?? "follow"
        return v == "mouse" ? "follow" : v
    }
    /// Dragging the strip is switched off.
    static var lockPosition: Bool { bool(Key.lockPosition, false) }
    static var snap: Bool { bool(Key.snap, true) }
    /// Stay above (or beside) the Dock instead of using the display right to its edges.
    static var avoidDock: Bool { bool(Key.avoidDock, false) }
    static var edgeMargin: CGFloat { CGFloat(double(Key.edgeMargin, 8)) }
    static var spacing: CGFloat { CGFloat(double(Key.spacing, 3)) }
    static var opacity: CGFloat { CGFloat(double(Key.opacity, 1)) }
    static var animate: Bool { bool(Key.animate, true) }
    static var shadows: Bool { bool(Key.shadows, true) }
    static var badges: Bool { bool(Key.badges, true) }
    static var blockedSprite: String { d.string(forKey: Key.blockedSprite) ?? "Waving" }
    static var failedSprite: String { d.string(forKey: Key.failedSprite) ?? "CrabWalking" }
    /// Finished-pool sprites the user switched off (so new art is on by default).
    static var finishedDisabled: Set<String> { Set(d.stringArray(forKey: Key.finishedDisabled) ?? []) }

    // MARK: Which sessions get a Clawd

    static var showQuestions: Bool { bool(Key.showQuestions, true) }
    static var showPermissions: Bool { bool(Key.showPermissions, true) }
    static var showPlans: Bool { bool(Key.showPlans, true) }
    static var showInput: Bool { bool(Key.showInput, true) }
    static var showFailed: Bool { bool(Key.showFailed, true) }
    static var showFinished: Bool { bool(Key.showFinished, true) }
    /// Forget a finished Clawd you never looked at after this many hours (0 = never).
    static var expireHours: Int { d.object(forKey: Key.expireHours) == nil ? 12 : d.integer(forKey: Key.expireHours) }
    static var maxClawds: Int { d.object(forKey: Key.maxClawds) == nil ? 8 : max(1, d.integer(forKey: Key.maxClawds)) }
    static var clearOnLook: Bool { bool(Key.clearOnLook, true) }
    /// How long a session's tab must be in front, with you active, before its Clawd leaves.
    static var lookSeconds: Double { double(Key.lookSeconds, 1.5) }
    static var sound: Bool { bool(Key.sound, false) }
    static var soundName: String { d.string(forKey: Key.soundName) ?? "Tink" }
    static var notify: Bool { bool(Key.notify, false) }
    static var notifyFinished: Bool { bool(Key.notifyFinished, false) }
    static var pausedUntil: Date? {
        get { (d.object(forKey: Key.pausedUntil) as? Date).flatMap { $0 > Date() ? $0 : nil } }
        set { d.set(newValue, forKey: Key.pausedUntil) }
    }

    // MARK: Bubble

    static var bubble: Bool { bool(Key.bubble, true) }
    static var hoverDelay: Double { double(Key.hoverDelay, 0.08) }
    static var bubbleTextSize: CGFloat { CGFloat(double(Key.bubbleTextSize, 12)) }
    static var bubbleLines: Int { d.object(forKey: Key.bubbleLines) == nil ? 3 : max(1, d.integer(forKey: Key.bubbleLines)) }
    static var bubbleTitle: Bool { bool(Key.bubbleTitle, true) }
    static var bubbleState: Bool { bool(Key.bubbleState, true) }
    static var bubbleAge: Bool { bool(Key.bubbleAge, true) }

    // MARK: Recaps

    static var recaps: Bool { bool(Key.recaps, true) }
    /// "haiku" or "sonnet" (Claude Code model aliases).
    static var recapModel: String { d.string(forKey: Key.recapModel) ?? "haiku" }
    /// "short" (~50 characters), "normal" (~80), "long" (~120).
    static var recapLength: String { d.string(forKey: Key.recapLength) ?? "normal" }
    static var recapInstructions: String { d.string(forKey: Key.recapInstructions) ?? "" }
    static var claudePath: String { d.string(forKey: Key.claudePath) ?? "" }

    // MARK: Click, keys, menu bar

    /// "open": jump to the session and dismiss; "dismiss": only dismiss.
    static var clickAction: String { d.string(forKey: Key.clickAction) ?? "open" }
    static var hotKey: Bool { bool(Key.hotKey, true) }
    static var hotKeyCode: UInt32 { d.object(forKey: Key.hotKeyCode) == nil ? HotKey.defaultKeyCode : UInt32(d.integer(forKey: Key.hotKeyCode)) }
    static var hotKeyMods: UInt32 { d.object(forKey: Key.hotKeyMods) == nil ? HotKey.defaultModifiers : UInt32(d.integer(forKey: Key.hotKeyMods)) }
    /// What "Copy Resume Command" puts on the clipboard; {id} is the session ID.
    static var resumeCommand: String { nonEmpty(Key.resumeCommand) ?? "claude --resume {id}" }
    static var menuBarIcon: Bool { bool(Key.menuBarIcon, true) }
    static var menuBarCount: Bool { bool(Key.menuBarCount, true) }

    static var didAskHooks: Bool { get { d.bool(forKey: Key.didAskHooks) } set { d.set(newValue, forKey: Key.didAskHooks) } }

    /// Writes a value; AppDelegate's defaults observer posts `.settingsChanged`.
    static func set(_ value: Any?, _ key: String) { d.set(value, forKey: key) }

    /// Back to defaults, keeping only the first-run flag.
    static func resetAll() {
        let keep = d.bool(forKey: Key.didAskHooks)
        if let domain = Bundle.main.bundleIdentifier { d.removePersistentDomain(forName: domain) }
        d.set(keep, forKey: Key.didAskHooks)
    }

    private static func string(_ k: String) -> String { d.string(forKey: k) ?? "" }
    private static func nonEmpty(_ k: String) -> String? { d.string(forKey: k).flatMap { $0.isEmpty ? nil : $0 } }
    private static func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
    private static func double(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
}

extension Notification.Name {
    static let settingsChanged = Notification.Name("ClawsSettingsChanged")
}
