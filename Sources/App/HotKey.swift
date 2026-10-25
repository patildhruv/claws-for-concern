import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut through Carbon's RegisterEventHotKey, which needs no Accessibility or
/// Input Monitoring permission. Used for ⌃⌥⌘C: jump to the session that most needs you.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    private static var all: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1

    static let jumpKeyCode = UInt32(kVK_ANSI_C)
    static let jumpModifiers = UInt32(controlKey | optionKey | cmdKey)

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        let id = HotKey.nextID
        HotKey.nextID += 1
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { HotKey.all[hk.id]?.action() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        guard status == noErr else { return nil }
        let hkID = EventHotKeyID(signature: OSType(0x434C_4157), id: id)  // 'CLAW'
        guard RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref) == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
        HotKey.all[id] = self
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
