import AppKit
import Carbon.HIToolbox

/// User-selectable shortcut for revealing the Pulse tray.
///
/// A single hardcoded ⌘⇧P collided with common apps and failed silently when
/// taken, so the whole feature looked broken. These are the presets; the store
/// reports whether registration actually succeeded.
enum HotkeyChoice: String, CaseIterable, Identifiable {
    case commandShiftP = "cmd_shift_p"
    case commandShiftU = "cmd_shift_u"
    case commandOptionP = "cmd_opt_p"
    case controlOptionP = "ctrl_opt_p"
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .commandShiftP: return "⌘⇧P"
        case .commandShiftU: return "⌘⇧U"
        case .commandOptionP: return "⌘⌥P"
        case .controlOptionP: return "⌃⌥P"
        case .off: return "—"
        }
    }

    /// (virtual key, Carbon modifier mask); `nil` disables the shortcut.
    var binding: (key: UInt32, modifiers: UInt32)? {
        switch self {
        case .commandShiftP: return (UInt32(kVK_ANSI_P), UInt32(cmdKey | shiftKey))
        case .commandShiftU: return (UInt32(kVK_ANSI_U), UInt32(cmdKey | shiftKey))
        case .commandOptionP: return (UInt32(kVK_ANSI_P), UInt32(cmdKey | optionKey))
        case .controlOptionP: return (UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey))
        case .off: return nil
        }
    }
}

/// Global shortcut that reveals the Pulse tray panel.
enum GlobalHotKey {
    private static var hotKeyRef: EventHotKeyRef?
    private static var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x50554C53 // 'PULS'

    private static let callback: EventHandlerUPP = { _, event, _ in
        var hk = EventHotKeyID()
        let err = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hk
        )
        if err == noErr, hk.signature == GlobalHotKey.signature {
            DispatchQueue.main.async {
                // Prefer the Waiting Go-Look path when something needs you;
                // otherwise just open the tray.
                if AppServices.store.snapshot.rows.contains(where: \.waiting)
                    || AppServices.store.allRowsForDisplay.contains(where: \.waiting) {
                    AppServices.store.focusFirstWaiting()
                } else {
                    TrayReveal.show()
                }
            }
        }
        return noErr
    }

    /// Returns true when the shortcut is live. `.off` counts as success —
    /// the user asked for nothing and got nothing.
    @discardableResult
    static func install(choice: HotkeyChoice) -> Bool {
        uninstall()
        guard let binding = choice.binding else { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            nil,
            &handlerRef
        )
        guard handlerStatus == noErr else { return false }

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(
            binding.key,
            binding.modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, ref != nil else {
            // eventHotKeyExistsErr (-9878) means another app owns it.
            RemoveEventHandler(handlerRef)
            handlerRef = nil
            return false
        }
        hotKeyRef = ref
        return true
    }

    static func uninstall() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}
