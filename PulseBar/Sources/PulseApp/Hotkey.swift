import Foundation

/// The global shortcut that opens the tray: a virtual key code and a Carbon
/// modifier mask — what `RegisterEventHotKey` takes, and what
/// `settings.json` stores (`globalShortcut`). Registering one needs no
/// privacy permission. Pure.
struct Hotkey: Equatable, Codable, Sendable {
    /// Carbon's modifier bits (`Carbon.HIToolbox`: `cmdKey`, `shiftKey`,
    /// `optionKey`, `controlKey`), spelled here so this file needs no
    /// framework; a test holds them equal to Carbon's.
    enum Modifier {
        static let command: UInt32 = 0x0100
        static let shift: UInt32 = 0x0200
        static let option: UInt32 = 0x0800
        static let control: UInt32 = 0x1000
        static let all: UInt32 = command | shift | option | control
    }

    var keyCode: UInt32
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Modifier.all
    }

    private enum CodingKeys: String, CodingKey { case keyCode, modifiers }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            keyCode: try c.decode(UInt32.self, forKey: .keyCode),
            modifiers: try c.decode(UInt32.self, forKey: .modifiers)
        )
    }

    /// ⌘, ⌃ or ⌥ is held: a global shortcut is never a bare key, nor one
    /// with ⇧ alone — that would swallow a letter everywhere.
    var hasCommandModifier: Bool {
        modifiers & (Modifier.command | Modifier.control | Modifier.option) != 0
    }

    /// The combination as macOS writes it: ⌃⌥⇧⌘, then the key.
    var label: String {
        var text = ""
        if modifiers & Modifier.control != 0 { text += "⌃" }
        if modifiers & Modifier.option != 0 { text += "⌥" }
        if modifiers & Modifier.shift != 0 { text += "⇧" }
        if modifiers & Modifier.command != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    /// The two shortcuts the setting used to offer, by the names
    /// `settings.json` saved them under; anything else is off.
    static func legacy(_ name: String) -> Hotkey? {
        switch name {
        case "ctrl_opt_space": return Hotkey(keyCode: KeyCode.space, modifiers: Modifier.control | Modifier.option)
        case "cmd_opt_p": return Hotkey(keyCode: 35, modifiers: Modifier.command | Modifier.option)
        default: return nil
        }
    }

    /// Virtual key codes with a meaning of their own here.
    enum KeyCode {
        static let space: UInt32 = 49
        static let escape: UInt32 = 53
        static let delete: UInt32 = 51
        static let forwardDelete: UInt32 = 117
    }

    /// A key's name: its letter or digit on the ANSI layout, a glyph for
    /// the keys macOS draws as one, the F-keys by number.
    static func keyName(_ code: UInt32) -> String {
        if let name = names[code] { return name }
        return "#\(code)"
    }

    private static let names: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 50: "`",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
}

/// The Settings shortcut recorder, as a pure reducer: a click starts it,
/// the next key decides. Esc cancels, Delete clears the shortcut, a bare key
/// (or ⇧ alone) keeps listening and says a modifier is needed, and a
/// combination with ⌘, ⌃ or ⌥ is taken — unless macOS keeps it for itself
/// (`reserved`, and the system's own list the store reads), in which case it
/// is refused and the old shortcut stays.
enum HotkeyRecorder {
    /// What the Settings row shows.
    struct State: Equatable {
        var recording = false
        var problem: Problem?
    }

    enum Problem: Equatable {
        /// The key pressed had no ⌘, ⌃ or ⌥.
        case needsModifier
        /// macOS (or another app) owns it, or it would not register.
        case cantUse
    }

    enum Outcome: Equatable {
        case cancel
        case clear
        case needsModifier
        case record(Hotkey)
    }

    /// One key while recording. Pure.
    static func reduce(keyCode: UInt32, modifiers: UInt32) -> Outcome {
        let hotkey = Hotkey(keyCode: keyCode, modifiers: modifiers)
        if hotkey.modifiers == 0 {
            switch keyCode {
            case Hotkey.KeyCode.escape: return .cancel
            case Hotkey.KeyCode.delete, Hotkey.KeyCode.forwardDelete: return .clear
            default: break
            }
        }
        guard hotkey.hasCommandModifier else { return .needsModifier }
        return .record(hotkey)
    }

    /// Combinations macOS keeps for itself whatever its settings say, or
    /// that every app answers: they are never offered. The system's own
    /// configurable list (Spotlight, input sources, Mission Control…) is
    /// read at the moment of recording and passed as `systemTaken`.
    static let reserved: [Hotkey] = {
        let cmd = Hotkey.Modifier.command, shift = Hotkey.Modifier.shift
        let opt = Hotkey.Modifier.option, ctrl = Hotkey.Modifier.control
        return [
            Hotkey(keyCode: 12, modifiers: cmd),              // ⌘Q quit
            Hotkey(keyCode: 13, modifiers: cmd),              // ⌘W close
            Hotkey(keyCode: 4, modifiers: cmd),               // ⌘H hide
            Hotkey(keyCode: 46, modifiers: cmd),              // ⌘M minimize
            Hotkey(keyCode: 48, modifiers: cmd),              // ⌘⇥ app switcher
            Hotkey(keyCode: 48, modifiers: cmd | shift),      // ⌘⇧⇥
            Hotkey(keyCode: 50, modifiers: cmd),              // ⌘` window cycle
            Hotkey(keyCode: 49, modifiers: cmd),              // ⌘Space Spotlight
            Hotkey(keyCode: 49, modifiers: ctrl),             // ⌃Space input source
            Hotkey(keyCode: 49, modifiers: ctrl | cmd),       // ⌃⌘Space characters
            Hotkey(keyCode: 49, modifiers: opt | cmd),        // ⌥⌘Space Finder search
            Hotkey(keyCode: 53, modifiers: opt | cmd),        // ⌥⌘⎋ force quit
            Hotkey(keyCode: 12, modifiers: ctrl | cmd),       // ⌃⌘Q lock screen
            Hotkey(keyCode: 20, modifiers: cmd | shift),      // ⌘⇧3 screenshot
            Hotkey(keyCode: 21, modifiers: cmd | shift),      // ⌘⇧4
            Hotkey(keyCode: 23, modifiers: cmd | shift),      // ⌘⇧5
        ]
    }()

    /// Whether `hotkey` may be registered: not one macOS keeps. Whether it
    /// actually registers is the next question, asked of the system.
    static func usable(_ hotkey: Hotkey, systemTaken: [Hotkey]) -> Bool {
        hotkey.hasCommandModifier && !reserved.contains(hotkey) && !systemTaken.contains(hotkey)
    }
}
