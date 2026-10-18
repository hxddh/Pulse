import Foundation

/// The tray's header as a value: the why in one line of counts — "2 need
/// you · 3 running" — each count in its state's tone. Pure.
package struct TrayHeaderModel: Equatable {
    package struct Count: Equatable {
        package var count: Int
        package var label: String
        package var tone: Lamp
    }

    package var lang: ResolvedLanguage
    /// Needs you, running, stalled, your turn — only the ones that are not 0.
    package var counts: [Count]
    /// Said when no count applies ("3 recent", "No coding agents").
    package var title: String

    /// `counts`: the projection's one count (`PulseSnapshot.counts`) —
    /// every row.
    package static func make(counts all: TrayState.Counts, lang: ResolvedLanguage) -> TrayHeaderModel {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        var counts: [Count] = []
        if all.blocked > 0 {
            counts.append(Count(count: all.blocked, label: t(all.blocked == 1 ? .waiting1 : .waitingN), tone: .waiting))
        }
        if all.running > 0 { counts.append(Count(count: all.running, label: t(.runningN), tone: .running)) }
        if all.stalled > 0 { counts.append(Count(count: all.stalled, label: t(.stalledN), tone: .stalled)) }
        if all.yourTurn > 0 { counts.append(Count(count: all.yourTurn, label: t(.yourTurnN), tone: .idle)) }

        let title: String
        if !counts.isEmpty {
            title = ""
        } else if all.processOnly > 0 {
            title = "\(all.processOnly) \(t(.processOnlyN))"
        } else if all.recent > 0 {
            title = "\(all.recent) \(t(.recentN))"
        } else {
            title = t(.noAgents)
        }
        return TrayHeaderModel(lang: lang, counts: counts, title: title)
    }
}

/// The tray's one notice: something on this Mac needs doing, with the one
/// action that does it. At most one, in this order:
///
/// 1. the setup card's remaining steps, right after it connected agents
///    ("Codex: run /hooks…", "Sessions already running appear after their
///    next step") until the person says "Got it";
/// 2. the setup card: agents on this Mac that are not connected — "Found
///    Claude, Codex — Connect" installs their hooks, then asks macOS to allow
///    banners. It comes first: without a hook there is nothing to notify;
/// 3. an agent whose install failed, and why ("Cursor: its hooks file is
///    not valid JSON — fix it, then install again") — never offered again as
///    "Connect", which would fail the same way;
/// 4. notifications denied, then not yet asked (a "needs you" cannot reach
///    a closed tray);
/// 5. the last banner refused while a wait is open.
///
/// Pure.
package struct TrayNoticeModel: Equatable {
    package enum Kind: Equatable {
        case setup, setupDone, setupFailed, notificationsDenied, notificationsOff, bannerFailed
    }

    package enum Action: Equatable {
        case connect, dismissSetup, openHooksSettings, openNotificationSettings, enableNotifications
    }

    package var kind: Kind
    package var text: String
    package var actionTitle: String
    package var action: Action
    package var systemImage: String
    package var tone: Lamp
    /// What is left to do, one line each — the setup card's follow-up.
    package var steps: [String] = []

    package struct Input {
        package var lang: ResolvedLanguage
        /// nil: macOS has not been asked yet.
        package var notifyAuthorized: Bool?
        /// Notification Center refused the last banner while a wait is open.
        package var bannerFailed: Bool
        /// Agents on this Mac whose hook is not installed and whose last
        /// install did not fail, in roster order — empty once the person
        /// removed the hooks on purpose.
        package var unconnected: [AgentID] = []
        /// Why the last install failed for some agents
        /// (`HooksSupport.failureText`); "" when none did.
        package var installFailure: String = ""
        /// The agents the setup card just connected (never empty); nil when
        /// it has no follow-up to show.
        package var justConnected: [AgentID]? = nil

        package init(
            lang: ResolvedLanguage,
            notifyAuthorized: Bool? = nil,
            bannerFailed: Bool,
            unconnected: [AgentID] = [],
            installFailure: String = "",
            justConnected: [AgentID]? = nil
        ) {
            self.lang = lang
            self.notifyAuthorized = notifyAuthorized
            self.bannerFailed = bannerFailed
            self.unconnected = unconnected
            self.installFailure = installFailure
            self.justConnected = justConnected
        }
    }

    /// Agents on this Mac whose hook is not installed, in roster order:
    /// the setup card's "Found …". Only agents whose vendor folder is here
    /// — exactly the ones "Connect" installs — and never one whose last
    /// install failed (the card says why instead: `installFailure`). Empty
    /// once the person removed the hooks on purpose, while an install runs,
    /// or when the last one could not write anything (Settings says why).
    package static func unconnected(
        present: Set<AgentID>, connections: [Connection], hooks: HooksSupport.Status, nudgeOff: Bool
    ) -> [AgentID] {
        if nudgeOff || hooks.isWorking { return [] }
        if case .launcherFailed = hooks { return [] }
        return AgentID.priority.filter { agent in
            present.contains(agent) && (connections.first { $0.agent == agent }?.install ?? .notInstalled) == .notInstalled
        }
    }

    /// Why the last install failed for some agents, in the failure copy
    /// Settings uses; "" when none did or the person removed the hooks on
    /// purpose.
    package static func installFailure(connections: [Connection], nudgeOff: Bool, lang: ResolvedLanguage) -> String {
        if nudgeOff { return "" }
        var failed: [AgentID: HooksInstaller.Failure] = [:]
        for connection in connections {
            if case .failed(let failure) = connection.install { failed[connection.agent] = failure }
        }
        return HooksSupport.failureText(failed, lang: lang)
    }

    package static func pick(_ input: Input) -> TrayNoticeModel? {
        func t(_ key: L10n.Key) -> String { L10n.t(key, input.lang) }
        func names(_ agents: [AgentID]) -> String { L10n.joinNames(agents.map(\.displayName), input.lang) }
        if let connected = input.justConnected {
            var steps: [String] = []
            if connected.contains(.codex) { steps.append(t(.setupStepCodex)) }
            steps.append(t(.setupStepRestart))
            return TrayNoticeModel(
                kind: .setupDone,
                text: String(format: t(.setupDone), names(connected)),
                actionTitle: t(.setupGotIt), action: .dismissSetup,
                systemImage: "checkmark.circle", tone: .idle, steps: steps
            )
        }
        if !input.unconnected.isEmpty {
            return TrayNoticeModel(
                kind: .setup, text: String(format: t(.setupFound), names(input.unconnected)),
                actionTitle: t(.setupConnect), action: .connect,
                systemImage: "link", tone: .idle
            )
        }
        if !input.installFailure.isEmpty {
            return TrayNoticeModel(
                kind: .setupFailed, text: input.installFailure,
                actionTitle: t(.setupFailedAction), action: .openHooksSettings,
                systemImage: "exclamationmark.triangle", tone: .stalled
            )
        }
        if input.notifyAuthorized == false {
            return TrayNoticeModel(
                kind: .notificationsDenied, text: t(.noticeNotificationsDenied),
                actionTitle: t(.openNotificationSettings), action: .openNotificationSettings,
                systemImage: "bell.slash", tone: .stalled
            )
        }
        if input.notifyAuthorized == nil {
            return TrayNoticeModel(
                kind: .notificationsOff, text: t(.noticeNotificationsOff),
                actionTitle: t(.enableNotifications), action: .enableNotifications,
                systemImage: "bell.badge", tone: .idle
            )
        }
        if input.bannerFailed {
            return TrayNoticeModel(
                kind: .bannerFailed, text: t(.waitingBannerFailed),
                actionTitle: t(.openNotificationSettings), action: .openNotificationSettings,
                systemImage: "bell.slash", tone: .stalled
            )
        }
        return nil
    }
}

/// No row moves under the pointer. While the tray is open its order
/// is frozen: rows keep the place they had when it opened, a new row is
/// appended, a row that left disappears. The projection's order is applied the
/// next time the tray opens. Pure.
package enum TrayOrder {
    /// `rows` in the frozen order; rows it does not know follow, in the
    /// order they came.
    package static func arrange(_ rows: [AgentRow], frozen: [SessionKey]) -> [AgentRow] {
        var position: [SessionKey: Int] = [:]
        for (index, key) in frozen.enumerated() where position[key] == nil { position[key] = index }
        let known = rows.filter { position[$0.key] != nil }
            .sorted { (position[$0.key] ?? 0) < (position[$1.key] ?? 0) }
        let newcomers = rows.filter { position[$0.key] == nil }
        return known + newcomers
    }

    /// What the open tray lists: every row already on screen this glance
    /// (`pinned`) that still exists, in the frozen order, then rows that
    /// came since, in the order they came. A new wait is appended; it never
    /// pushes a row the person is looking at out of the list, nor moves one.
    /// Pure.
    package static func openList(all: [AgentRow], pinned: Set<SessionKey>, frozen: [SessionKey]) -> [AgentRow] {
        arrange(all.filter { pinned.contains($0.key) }, frozen: frozen)
            + arrange(all.filter { !pinned.contains($0.key) }, frozen: frozen)
    }

    /// The frozen order with newcomers appended, so a row keeps the place it
    /// was given when it first appeared.
    package static func extend(_ frozen: [SessionKey], with rows: [AgentRow]) -> [SessionKey] {
        var seen = Set(frozen)
        var out = frozen
        for row in rows where seen.insert(row.key).inserted { out.append(row.key) }
        return out
    }
}

/// The tray's keyboard, as a pure reducer.
///
/// Every key reaches this one function — the tray's key monitor turns an
/// event into a `Key`, `reduce` returns the next state and at most one
/// effect, and `TrayUI` performs the effect. Nothing depends on which view
/// happens to have focus, so Esc works in every state (the detail page, an
/// empty list).
///
/// | key            | list                                   | detail          |
/// | -------------- | -------------------------------------- | --------------- |
/// | ↑ ↓            | select                                 | —               |
/// | ↩              | go: the terminal, else the detail      | go              |
/// | → / Space      | detail                                 | —               |
/// | ← / Esc        | Esc: close                             | back            |
/// | ⌘D / ⌘⌫        | ignore the selected wait               | ignore          |
/// | ⌘R ⌘, ⌘Q       | refresh · settings · quit              | same            |
/// | ⌘W             | close (as Esc here)                    | close           |
///
/// A bare letter is not the tray's: the tray opens with a row selected, and a
/// bare D must never ignore a wait; the commands carry ⌘. ⌘W is the
/// tray's too: left to the system it would reach `performClose:` on the
/// popover's window, which has no close button, and beep.
package enum TrayKeys {
    package enum Key: Equatable {
        case up, down, left, right, space, enter, escape
        /// ⌘D or ⌘⌫
        case dismiss
        /// ⌘R
        case refresh
        /// ⌘,
        case settings
        /// ⌘Q
        case quit
        /// ⌘W
        case close
    }

    package struct State: Equatable {
        package var selected: SessionKey?
        /// The row whose detail page is open.
        package var detail: SessionKey?

        package init(selected: SessionKey? = nil, detail: SessionKey? = nil) {
            self.selected = selected
            self.detail = detail
        }
    }

    /// What the reducer needs to know about a row on screen.
    package struct Row: Equatable {
        package var key: SessionKey
        package var blocked: Bool
        package var canFocus: Bool

        package init(key: SessionKey, blocked: Bool = false, canFocus: Bool = false) {
            self.key = key
            self.blocked = blocked
            self.canFocus = canFocus
        }

        package init(_ row: AgentRow) {
            self.init(key: row.key, blocked: row.isBlocked, canFocus: row.canFocusTerminal)
        }
    }

    package enum Effect: Equatable {
        case focus(SessionKey)
        case dismiss(SessionKey)
        case refresh
        case openSettings
        case closeTray
        case quit
    }

    package struct Outcome: Equatable {
        package var state: State
        package var effect: Effect?
        /// False: not the tray's key — let the system have it.
        package var handled: Bool
    }

    /// One key. `rows` are the rows on screen, in order (and the detail
    /// page's row when one is open).
    package static func reduce(_ state: State, _ key: Key, rows: [Row]) -> Outcome {
        var next = state
        func done(_ effect: Effect? = nil) -> Outcome { Outcome(state: next, effect: effect, handled: true) }

        switch key {
        case .refresh: return done(.refresh)
        case .settings: return done(.openSettings)
        case .quit: return done(.quit)
        case .close: return done(.closeTray)
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
            default:
                return done()
            }
        }

        let selected = state.selected.flatMap { key in rows.first { $0.key == key } }
        switch key {
        case .escape:
            return done(.closeTray)
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
        case .refresh, .settings, .quit, .close:
            return done()
        }
    }

    /// Keep the selection on a row that is on screen: a selection whose row
    /// left moves to the first row.
    package static func normalize(_ state: State, rows: [Row]) -> State {
        var next = state
        if let selected = state.selected, !rows.contains(where: { $0.key == selected }) {
            next.selected = rows.first?.key
        }
        return next
    }

    private static func step(from key: SessionKey?, by delta: Int, in rows: [Row]) -> SessionKey? {
        guard !rows.isEmpty else { return key }
        guard let key, let index = rows.firstIndex(where: { $0.key == key }) else {
            return delta > 0 ? rows.first?.key : rows.last?.key
        }
        return rows[min(max(index + delta, 0), rows.count - 1)].key
    }

    // MARK: - Events

    /// An event as a `Key`, or nil when it is not the tray's.
    package static func key(keyCode: UInt16, characters: String, command: Bool) -> Key? {
        if command {
            if keyCode == 51 { return .dismiss }
            switch characters.lowercased() {
            case "r": return .refresh
            case ",": return .settings
            case "q": return .quit
            case "w": return .close
            case "d": return .dismiss
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

/// What a response to a "needs you" banner asks for: its "Ignore" button
/// dismisses the waits it names — the tray's ⌘D, the same `dismiss` line,
/// never an answer to the vendor; macOS's own
/// dismissal (the ✕, a swipe) is nothing; a click on the banner or its
/// "Go" goes (`BannerRoute`). Pure.
package enum BannerIntent: Equatable {
    case go
    case ignore
    case nothing

    /// The banner's buttons, by their `UNNotificationAction` ids.
    package static let goActionID = "pulse.focus"
    package static let ignoreActionID = "pulse.ignore"

    /// `dismissActionID`: the system's own dismiss id
    /// (`UNNotificationDismissActionIdentifier`), passed in so this stays
    /// free of the framework.
    package static func decide(actionID: String, dismissActionID: String) -> BannerIntent {
        switch actionID {
        case ignoreActionID: return .ignore
        case dismissActionID: return .nothing
        default: return .go
        }
    }

    /// The row an "Ignore" dismisses: the banner's wait, when it is still
    /// open now. A wait answered, ended or already ignored meanwhile is
    /// left alone. `rowKey` is the banner's `SessionKey.description`.
    package static func ignoreTarget(rowKey: String, rows: [AgentRow]) -> AgentRow? {
        guard !rowKey.isEmpty else { return nil }
        return rows.first { $0.key.description == rowKey && $0.isBlocked }
    }
}

/// Where a click on a "needs you" banner goes: to the terminal and
/// nowhere else when it could be focused (the tray does not pop up over
/// it); to the row's detail in the tray when it could not; to the tray when
/// the row is gone. Pure.
package enum BannerRoute: Equatable {
    case terminal
    case detail(SessionKey)
    case tray

    /// The row a banner names: its exact key (`rowKey`, the banner's
    /// `SessionKey.description`), else its session — inside the named agent,
    /// and a prefix only when exactly one row fits, so a truncated id cannot
    /// send a click to the wrong row — else the agent's first wait, else its
    /// first row.
    package static func target(in rows: [AgentRow], idRaw: String, session: String, rowKey: String) -> AgentRow? {
        if !rowKey.isEmpty, let row = rows.first(where: { $0.key.description == rowKey }) {
            return row
        }
        let agent = Agents.agent(named: idRaw)
        if !session.isEmpty {
            let sameAgent = rows.filter { !$0.session.isEmpty && (agent == nil || $0.agent == agent) }
            if let exact = sameAgent.first(where: { $0.session == session }) { return exact }
            let prefixed = sameAgent.filter {
                session.hasPrefix($0.session) || $0.session.hasPrefix(session)
            }
            if prefixed.count == 1 { return prefixed[0] }
        }
        guard let agent else { return nil }
        let own = rows.filter { $0.agent == agent }
        return own.first(where: \.isBlocked) ?? own.first
    }

    package static func decide(target: SessionKey?, focused: Bool) -> BannerRoute {
        guard let target else { return .tray }
        return focused ? .terminal : .detail(target)
    }
}
