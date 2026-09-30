import AppKit
import Carbon.HIToolbox

/// User-selectable shortcut for revealing the Pulse tray.
///
/// A single hardcoded ⌘⇧P collided with common apps and failed silently when
/// taken, so the whole feature looked broken. Only combinations
/// the editors people run agents in leave free — ⌘⇧P (the command palette)
/// and ⌘⇧U (VS Code's output panel) went; a saved one reads as `.off`. The
/// store reports whether registration actually succeeded.
enum HotkeyChoice: String, CaseIterable, Identifiable {
    case controlOptionSpace = "ctrl_opt_space"
    case optionCommandP = "cmd_opt_p"  // the same keys ⌘⌥P always saved as
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .controlOptionSpace: return "⌃⌥Space"
        case .optionCommandP: return "⌥⌘P"
        case .off: return "—"
        }
    }

    /// (virtual key, Carbon modifier mask); `nil` disables the shortcut.
    var binding: (key: UInt32, modifiers: UInt32)? {
        switch self {
        case .controlOptionSpace: return (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .optionCommandP: return (UInt32(kVK_ANSI_P), UInt32(cmdKey | optionKey))
        case .off: return nil
        }
    }
}

/// Global shortcut that reveals the Pulse tray panel.
enum GlobalHotKey {
    nonisolated(unsafe) private static var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private static var handlerRef: EventHandlerRef?
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
            // One gesture — the shortcut toggles the tray exactly as
            // a menu-bar click does, opening on the oldest wait. It never
            // jumps to a terminal on its own.
            TrayReveal.toggle()
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
