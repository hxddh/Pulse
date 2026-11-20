import Carbon.HIToolbox
import Foundation

/// Global Carbon hot keys — no Accessibility or Input Monitoring permission,
/// and macOS refuses any chord another app holds:
///
/// 1. Open/close tray on the oldest wait (`ShortcutChoice`, default ⌃⌥⌘P).
/// 2. Optional direct jump straight to the oldest blocked terminal (⌃⌥⌘↩).
@MainActor
final class GlobalShortcut {
    static let shared = GlobalShortcut()

    private static let signature = OSType(0x5055_4C53) // "PULS"
    private static let trayHotKeyID: UInt32 = 1
    private static let directJumpHotKeyID: UInt32 = 2

    /// Open/close tray chord; set by the store.
    var onPress: (() -> Void)?
    /// Direct jump chord (⌃⌥⌘↩); set by the store.
    var onDirectJump: (() -> Void)?
    /// Whether the tray chord is registered.
    private(set) var registered = false
    /// Whether the direct-jump chord is registered.
    private(set) var directJumpRegistered = false
    private var hotKey: EventHotKeyRef?
    private var directJumpHotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// The Carbon key code and modifiers of a chord.
    static func keys(_ choice: ShortcutChoice) -> (code: UInt32, modifiers: UInt32) {
        switch choice {
        case .controlOptionCommandP: return (UInt32(kVK_ANSI_P), UInt32(cmdKey | optionKey | controlKey))
        case .optionCommandP: return (UInt32(kVK_ANSI_P), UInt32(cmdKey | optionKey))
        case .controlOptionSpace: return (UInt32(kVK_Space), UInt32(optionKey | controlKey))
        }
    }

    private func ensureHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            let id = status == noErr ? hotKeyID.id : GlobalShortcut.trayHotKeyID
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch id {
                    case GlobalShortcut.directJumpHotKeyID:
                        GlobalShortcut.shared.onDirectJump?()
                    default:
                        GlobalShortcut.shared.onPress?()
                    }
                }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// Register or drop the tray chord. Returns whether it is registered.
    @discardableResult
    func set(enabled: Bool, choice: ShortcutChoice = .default) -> Bool {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        registered = false
        guard enabled else { return false }
        ensureHandler()
        let id = EventHotKeyID(signature: Self.signature, id: Self.trayHotKeyID)
        var ref: EventHotKeyRef?
        let chord = Self.keys(choice)
        let status = RegisterEventHotKey(chord.code, chord.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        hotKey = status == noErr ? ref : nil
        registered = hotKey != nil
        DebugLog.write("shortcut \(registered ? "registered" : "refused status=\(status)")")
        return registered
    }

    /// Register or drop the optional direct-jump chord (⌃⌥⌘↩).
    @discardableResult
    func setDirectJump(enabled: Bool) -> Bool {
        if let directJumpHotKey {
            UnregisterEventHotKey(directJumpHotKey)
            self.directJumpHotKey = nil
        }
        directJumpRegistered = false
        guard enabled else { return false }
        ensureHandler()
        let id = EventHotKeyID(signature: Self.signature, id: Self.directJumpHotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Return),
            UInt32(cmdKey | optionKey | controlKey),
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        directJumpHotKey = status == noErr ? ref : nil
        directJumpRegistered = directJumpHotKey != nil
        DebugLog.write("direct jump shortcut \(directJumpRegistered ? "registered" : "refused status=\(status)")")
        return directJumpRegistered
    }
}
