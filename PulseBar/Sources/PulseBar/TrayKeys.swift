import Foundation

/// 23.0 · the tray's keyboard, as a pure reducer.
///
/// Every key reaches this one function — the panel's key monitor turns an
/// event into a `Key`, `reduce` returns the next state and at most one
/// effect, and the panel performs the effect. Nothing depends on which view
/// happens to have focus, so Esc works in every state (the detail page, a
/// filter with no matches, an empty list) and ⌫ only ever edits the filter.
///
/// | key            | list                                   | detail          |
/// | -------------- | -------------------------------------- | --------------- |
/// | ↑ ↓            | select                                 | —               |
/// | ↩              | go: the terminal, else the detail      | go              |
/// | → / Space      | detail (Space types when filtering)    | —               |
/// | ← / Esc        | Esc: clear the filter, else close      | back            |
/// | ⌘D / ⌘⌫        | dismiss the selected wait              | dismiss         |
/// | ⌘M             | mute / unmute the selected agent       | mute / unmute   |
/// | ⌫              | edit the filter                        | —               |
/// | any letter     | type to filter                         | —               |
/// | ⌘R ⌘, ⌘Q       | refresh · settings · quit              | same            |
///
/// 23.0: a bare letter is always the filter's. The tray opens with a row
/// selected, so a bare D or M used to dismiss or mute when someone simply
/// started typing a name; the commands carry ⌘.
enum TrayKeys {
    enum Key: Equatable {
        case up, down, left, right, space, enter, escape, backspace
        /// Printable text typed without ⌘, ⌃ or ⌥.
        case character(String)
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
    }

    struct State: Equatable {
        var query = ""
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

    /// One key. `rows` are the rows on screen, in order (the filtered list,
    /// and the detail page's row when one is open).
    static func reduce(_ state: State, _ key: Key, rows: [Row]) -> Outcome {
        var next = state
        func done(_ effect: Effect? = nil) -> Outcome { Outcome(state: next, effect: effect, handled: true) }

        switch key {
        case .refresh: return done(.refresh)
        case .settings: return done(.openSettings)
        case .quit: return done(.quit)
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
            if !state.query.isEmpty {
                next.query = ""
                return done()
            }
            return done(.closePanel)
        case .backspace:
            if !next.query.isEmpty { next.query.removeLast() }
            return done()
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
        case .right:
            guard let selected else { return done() }
            next.detail = selected.key
            return done()
        case .space:
            if !state.query.isEmpty {
                next.query += " "
                return done()
            }
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
        case .character(let text):
            next.query += text
            next.selected = nil
            return done()
        case .refresh, .settings, .quit:
            return done()
        }
    }

    /// Keep the selection on a row that is on screen. A filter selects its
    /// first match; a selection whose row left moves to the first row.
    static func normalize(_ state: State, rows: [Row]) -> State {
        var next = state
        if let selected = state.selected, !rows.contains(where: { $0.key == selected }) {
            next.selected = rows.first?.key
        } else if state.selected == nil, !state.query.isEmpty {
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
    static func key(keyCode: UInt16, characters: String, command: Bool, control: Bool, option: Bool) -> Key? {
        if command {
            if keyCode == 51 { return .dismiss }
            switch characters.lowercased() {
            case "r": return .refresh
            case ",": return .settings
            case "q": return .quit
            case "d": return .dismiss
            case "m": return .mute
            default: return nil
            }
        }
        switch keyCode {
        case 53: return .escape
        case 51: return .backspace
        case 36, 76: return .enter
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        case 49: return .space
        default: break
        }
        guard !control, !option, !characters.isEmpty else { return nil }
        let printable = characters.unicodeScalars.allSatisfy { scalar in
            // Function keys arrive in the private-use block U+F700–U+F8FF.
            !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
        }
        return printable ? .character(characters) : nil
    }

    // MARK: - Filter

    /// Type-to-filter over every retained row (not only the visible window).
    static func filter(_ rows: [AgentRow], query: String) -> [AgentRow] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return rows }
        return rows.filter { row in
            [
                row.agent.displayName, row.agent.rawValue, row.task, row.project,
                row.cwd, row.sessionID, row.model, row.lastWord,
            ].contains { $0.localizedCaseInsensitiveContains(text) }
        }
    }
}

/// 23.0 · where a click on a "needs you" banner goes: to the terminal and
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
