import Foundation

/// The tray's header as a value: the why in one line of counts — "2 need
/// you · 3 running" — each count in its state's tone. Pure.
struct TrayHeaderModel: Equatable {
    struct Count: Equatable {
        var count: Int
        var label: String
        var tone: PulseTheme.Tone
    }

    var lang: ResolvedLanguage
    /// Needs you, running, stalled, your turn — only the ones that are not 0.
    var counts: [Count]
    /// Said when no count applies ("3 recent", "No coding agents").
    var title: String

    /// `rows`: every row the last scan produced, not the visible window.
    static func make(rows: [AgentRow], lang: ResolvedLanguage) -> TrayHeaderModel {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        let blocked = rows.filter(\.isBlocked).count
        let running = rows.filter { $0.state == .running && !$0.isStalled }.count
        let stalled = rows.filter { $0.state == .running && $0.isStalled }.count
        let turns = rows.filter(\.isYourTurn).count

        var counts: [Count] = []
        if blocked > 0 {
            counts.append(Count(count: blocked, label: t(blocked == 1 ? .waiting1 : .waitingN), tone: .waiting))
        }
        if running > 0 { counts.append(Count(count: running, label: t(.runningN), tone: .running)) }
        if stalled > 0 { counts.append(Count(count: stalled, label: t(.stalledN), tone: .attention)) }
        if turns > 0 { counts.append(Count(count: turns, label: t(.yourTurnN), tone: .idle)) }

        let processOnly = rows.filter(\.isProcessOnly).count
        let recent = rows.filter(\.isRecent).count
        let title: String
        if !counts.isEmpty {
            title = ""
        } else if processOnly > 0 {
            title = "\(processOnly) \(t(.processOnlyN))"
        } else if recent > 0 {
            title = "\(recent) \(t(.recentN))"
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
/// 3. an agent whose install failed, and why ("Gemini: its settings file is
///    not valid JSON — fix it, then install again") — never offered again as
///    "Connect", which would fail the same way;
/// 4. notifications denied, then not yet asked (a "needs you" cannot reach
///    a closed tray);
/// 5. the last banner refused while a wait is open.
///
/// Pure.
struct TrayNoticeModel: Equatable {
    enum Kind: Equatable {
        case setup, setupDone, setupFailed, notificationsDenied, notificationsOff, bannerFailed
    }

    enum Action: Equatable {
        case connect, dismissSetup, openHooksSettings, openNotificationSettings, enableNotifications
    }

    var kind: Kind
    var text: String
    var actionTitle: String
    var action: Action
    var systemImage: String
    var tone: PulseTheme.Tone
    /// What is left to do, one line each — the setup card's follow-up.
    var steps: [String] = []

    struct Input {
        var lang: ResolvedLanguage
        var notifyOnWaiting: Bool
        /// nil: macOS has not been asked yet.
        var notifyAuthorized: Bool?
        /// Notification Center refused the last banner while a wait is open.
        var bannerFailed: Bool
        /// Agents on this Mac whose hook is not installed and whose last
        /// install did not fail, in roster order — empty once the person
        /// removed the hooks on purpose.
        var unconnected: [AgentID] = []
        /// Why the last install failed for some agents
        /// (`HooksSupport.Status.failureText`); "" when none did.
        var installFailure: String = ""
        /// The agents the setup card just connected (never empty); nil when
        /// it has no follow-up to show.
        var justConnected: [AgentID]? = nil
    }

    static func pick(_ input: Input) -> TrayNoticeModel? {
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
                systemImage: "exclamationmark.triangle", tone: .attention
            )
        }
        if input.notifyOnWaiting, input.notifyAuthorized == false {
            return TrayNoticeModel(
                kind: .notificationsDenied, text: t(.noticeNotificationsDenied),
                actionTitle: t(.openNotificationSettings), action: .openNotificationSettings,
                systemImage: "bell.slash", tone: .attention
            )
        }
        if input.notifyOnWaiting, input.notifyAuthorized == nil {
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
                systemImage: "bell.slash", tone: .attention
            )
        }
        return nil
    }
}

/// No row moves under the pointer. While the tray is open its order
/// is frozen: rows keep the place they had when it opened, a new row is
/// appended, a row that left disappears. The projection's order is applied the
/// next time the tray opens. Pure.
enum TrayOrder {
    /// `rows` in the frozen order; rows it does not know follow, in the
    /// order they came.
    static func arrange(_ rows: [AgentRow], frozen: [String]) -> [AgentRow] {
        var position: [String: Int] = [:]
        for (index, key) in frozen.enumerated() where position[key] == nil { position[key] = index }
        let known = rows.filter { position[$0.rowKey] != nil }
            .sorted { (position[$0.rowKey] ?? 0) < (position[$1.rowKey] ?? 0) }
        let newcomers = rows.filter { position[$0.rowKey] == nil }
        return known + newcomers
    }

    /// The most rows the open tray lists while the projection's window stays
    /// folded: room for newcomers beside the rows already shown.
    static let openCap = TrayState.maxVisibleRows * 2

    /// What the open tray lists: every row already on screen this glance
    /// (`pinned`) that still exists, in the frozen order, then rows that
    /// entered the projection's `window` since, in the order they
    /// came. A new wait is appended; it never pushes a row the person is
    /// looking at out of the list. Newcomers stop at `cap`; pinned rows
    /// never do. Pure.
    static func openWindow(
        all: [AgentRow], window: [AgentRow], pinned: Set<String>, frozen: [String], cap: Int
    ) -> [AgentRow] {
        let windowKeys = Set(window.map(\.rowKey))
        let kept = arrange(all.filter { pinned.contains($0.rowKey) }, frozen: frozen)
        let newcomers = arrange(
            all.filter { !pinned.contains($0.rowKey) && windowKeys.contains($0.rowKey) },
            frozen: frozen
        )
        return kept + newcomers.prefix(max(0, cap - kept.count))
    }

    /// The frozen order with newcomers appended, so a row keeps the place it
    /// was given when it first appeared.
    static func extend(_ frozen: [String], with rows: [AgentRow]) -> [String] {
        var seen = Set(frozen)
        var out = frozen
        for row in rows where seen.insert(row.rowKey).inserted { out.append(row.rowKey) }
        return out
    }
}
