import AppKit
import Carbon.HIToolbox

/// Global ⌘⇧P reveals the Pulse tray panel.
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
                TrayReveal.show()
            }
        }
        return noErr
    }

    static func install() {
        uninstall()
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            nil,
            &handlerRef
        )
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: 1)
        // ⌘⇧P
        RegisterEventHotKey(
            UInt32(kVK_ANSI_P),
            UInt32(cmdKey | shiftKey),
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        hotKeyRef = ref
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
