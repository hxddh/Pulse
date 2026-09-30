import AppKit
import Carbon.HIToolbox

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

    /// Returns true when the shortcut is live. No shortcut counts as
    /// success — the person asked for nothing and got nothing.
    @discardableResult
    static func install(_ hotkey: Hotkey?) -> Bool {
        uninstall()
        guard let hotkey else { return true }

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
            hotkey.keyCode,
            hotkey.modifiers,
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

    /// The shortcuts macOS has turned on for itself (System Settings →
    /// Keyboard → Keyboard Shortcuts: Spotlight, input sources, Mission
    /// Control, screenshots…), read when a combination is recorded. Not
    /// every owner is listed here — another app's shortcut shows only when
    /// registering fails.
    static func systemTaken() -> [Hotkey] {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let array = unmanaged?.takeRetainedValue() else { return [] }
        guard let entries = (array as NSArray) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard (entry["kHISymbolicHotKeyEnabled"] as? NSNumber)?.boolValue == true,
                  let code = (entry["kHISymbolicHotKeyCode"] as? NSNumber)?.uint32Value,
                  let modifiers = (entry["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value
            else { return nil }
            return Hotkey(keyCode: code, modifiers: modifiers)
        }
    }
}

/// Listens for the next key while Settings records a shortcut. The key goes
/// to `onKey` as a virtual key code and a Carbon modifier mask
/// (`HotkeyRecorder.reduce` decides) and to no one else.
@MainActor
final class HotkeyCapture {
    private var monitor: Any?
    var onKey: (UInt32, UInt32) -> Void = { _, _ in }

    var isListening: Bool { monitor != nil }

    func start() {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            self.onKey(UInt32(event.keyCode), Self.carbonModifiers(event.modifierFlags))
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// AppKit's modifier flags as Carbon's mask. Pure.
    nonisolated static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= Hotkey.Modifier.command }
        if flags.contains(.shift) { mask |= Hotkey.Modifier.shift }
        if flags.contains(.option) { mask |= Hotkey.Modifier.option }
        if flags.contains(.control) { mask |= Hotkey.Modifier.control }
        return mask
    }
}
