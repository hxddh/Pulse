import Foundation

/// The tray's keyboard, as a pure reducer.
///
/// Every key reaches this one function — the panel's key monitor turns an
/// event into a `Key`, `reduce` returns the next state and at most one
/// effect, and the panel performs the effect. Nothing depends on which view
/// happens to have focus, so Esc works in every state (the detail page, an
/// empty list).
///
/// | key            | list                                   | detail          |
/// | -------------- | -------------------------------------- | --------------- |
/// | ↑ ↓            | select                                 | —               |
/// | ↩              | go: the terminal, else the detail      | go              |
/// | → / Space      | detail                                 | —               |
/// | ← / Esc        | Esc: close                             | back            |
/// | ⌘D / ⌘⌫        | dismiss the selected wait              | dismiss         |
/// | ⌘M             | mute / unmute the selected agent       | mute / unmute   |
/// | ⌘R ⌘, ⌘Q       | refresh · settings · quit              | same            |
/// | ⌘W             | close (as Esc here)                    | close           |
///
/// A bare letter is not the tray's: the tray opens with a row selected, and a
/// bare D or M must never dismiss or mute; the commands carry ⌘. ⌘W is the
/// tray's too: left to the system it would reach `performClose:` on the
/// borderless panel, which has no close button, and beep.
enum TrayKeys {
    enum Key: Equatable {
        case up, down, left, right, space, enter, escape
        /// ⌘D or ⌘⌫
        case dismiss
        /// ⌘M
        case mute
        /// ⌘R
        case refresh
        /// ⌘,
        case settings
        /// ⌘Q
        case quit
        /// ⌘W
        case close
    }

    struct State: Equatable {
        var selected: String?
        /// The row whose detail page is open.
        var detail: String?
    }

    /// What the reducer needs to know about a row on screen.
    struct Row: Equatable {
        var key: String
        var blocked: Bool
        var canFocus: Bool

        init(key: String, blocked: Bool = false, canFocus: Bool = false) {
            self.key = key
            self.blocked = blocked
            self.canFocus = canFocus
        }

        init(_ row: AgentRow) {
            self.init(key: row.rowKey, blocked: row.isBlocked, canFocus: row.canFocusTerminal)
        }
    }

    enum Effect: Equatable {
        case focus(String)
        case dismiss(String)
        case toggleMute(String)
        case refresh
        case openSettings
        case closePanel
        case quit
    }

    struct Outcome: Equatable {
        var state: State
        var effect: Effect?
        /// False: not the tray's key — let the system have it.
        var handled: Bool
    }

    /// One key. `rows` are the rows on screen, in order (and the detail
    /// page's row when one is open).
    static func reduce(_ state: State, _ key: Key, rows: [Row]) -> Outcome {
        var next = state
        func done(_ effect: Effect? = nil) -> Outcome { Outcome(state: next, effect: effect, handled: true) }

        switch key {
        case .refresh: return done(.refresh)
        case .settings: return done(.openSettings)
        case .quit: return done(.quit)
        case .close: return done(.closePanel)
        default: break
        }

        if let open = state.detail {
            let row = rows.first { $0.key == open }
            switch key {
            case .escape, .left:
                next.detail = nil
                next.selected = open
                return done()
            case .enter:
                guard let row, row.canFocus else { return done() }
                return done(.focus(row.key))
            case .dismiss:
                guard let row, row.blocked else { return done() }
                return done(.dismiss(row.key))
            case .mute:
                return done(.toggleMute(open))
            default:
                return done()
            }
        }

        let selected = state.selected.flatMap { key in rows.first { $0.key == key } }
        switch key {
        case .escape:
            return done(.closePanel)
        case .up:
            next.selected = step(from: selected?.key, by: -1, in: rows)
            return done()
        case .down:
            next.selected = step(from: selected?.key, by: 1, in: rows)
            return done()
        case .enter:
            guard let selected else { return done() }
            if selected.canFocus { return done(.focus(selected.key)) }
            next.detail = selected.key
            return done()
        case .right, .space:
            guard let selected else { return done() }
            next.detail = selected.key
            return done()
        case .left:
            return done()
        case .dismiss:
            guard let selected, selected.blocked else { return done() }
            return done(.dismiss(selected.key))
        case .mute:
            guard let selected else { return done() }
            return done(.toggleMute(selected.key))
        case .refresh, .settings, .quit, .close:
            return done()
        }
    }

    /// Keep the selection on a row that is on screen: a selection whose row
    /// left moves to the first row.
    static func normalize(_ state: State, rows: [Row]) -> State {
        var next = state
        if let selected = state.selected, !rows.contains(where: { $0.key == selected }) {
            next.selected = rows.first?.key
        }
        return next
    }

    private static func step(from key: String?, by delta: Int, in rows: [Row]) -> String? {
        guard !rows.isEmpty else { return key }
        guard let key, let index = rows.firstIndex(where: { $0.key == key }) else {
            return delta > 0 ? rows.first?.key : rows.last?.key
        }
        return rows[min(max(index + delta, 0), rows.count - 1)].key
    }

    // MARK: - Events

    /// An event as a `Key`, or nil when it is not the tray's.
    static func key(keyCode: UInt16, characters: String, command: Bool) -> Key? {
        if command {
            if keyCode == 51 { return .dismiss }
            switch characters.lowercased() {
            case "r": return .refresh
            case ",": return .settings
            case "q": return .quit
            case "w": return .close
            case "d": return .dismiss
            case "m": return .mute
            default: return nil
            }
        }
        switch keyCode {
        case 53: return .escape
        case 36, 76: return .enter
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        case 49: return .space
        default: return nil
        }
    }
}

/// Where a click on a "needs you" banner goes: to the terminal and
/// nowhere else when it could be focused (the tray does not pop up over
/// it); to the row's detail in the tray when it could not; to the tray when
/// the row is gone. Pure.
enum BannerRoute: Equatable {
    case terminal
    case detail(String)
    case tray

    static func decide(target: String?, focused: Bool) -> BannerRoute {
        guard let target else { return .tray }
        return focused ? .terminal : .detail(target)
    }
}
