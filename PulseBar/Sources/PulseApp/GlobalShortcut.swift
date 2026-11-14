import Carbon.HIToolbox
import Foundation

/// The one global shortcut — ⌃⌥⌘P unless the person picked another
/// (`ShortcutChoice`): open the tray on the oldest wait (or close it). A Carbon hot key — no Accessibility or Input Monitoring permission,
/// and macOS refuses it (it reports so) when another app holds the chord.
@MainActor
final class GlobalShortcut {
    static let shared = GlobalShortcut()

    /// What the chord does; set by the app delegate.
    var onPress: (() -> Void)?
    /// The chord is registered.
    private(set) var registered = false
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// The Carbon key code and modifiers of a chord.
    static func keys(_ choice: ShortcutChoice) -> (code: UInt32, modifiers: UInt32) {
        switch choice {
        case .controlOptionCommandP: return (UInt32(kVK_ANSI_P), UInt32(cmdKey | optionKey | controlKey))
        case .optionCommandP: return (UInt32(kVK_ANSI_P), UInt32(cmdKey | optionKey))
        case .controlOptionSpace: return (UInt32(kVK_Space), UInt32(optionKey | controlKey))
        }
    }

    /// Register or drop the chord. Returns whether it is registered.
    @discardableResult
    func set(enabled: Bool, choice: ShortcutChoice = .default) -> Bool {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        registered = false
        guard enabled else { return false }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { GlobalShortcut.shared.onPress?() }
                }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x5055_4C53), id: 1) // "PULS"
        var ref: EventHotKeyRef?
        let chord = Self.keys(choice)
        let status = RegisterEventHotKey(chord.code, chord.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        hotKey = status == noErr ? ref : nil
        registered = hotKey != nil
        DebugLog.write("shortcut \(registered ? "registered" : "refused status=\(status)")")
        return registered
    }
}
