import Foundation

/// 23.0 · the tray's header as a value: the why and the freshness in one
/// line — "2 need you · 3 running · updated 3s ago". Counts carry their
/// state's tone; a scan that stopped arriving says so in orange instead of
/// the freshness ("not updated for 4m"). Pure.
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
    /// "updated 3s ago", or "not updated for 4m" when `stale`.
    var freshness: String
    var stale: Bool

    struct Input {
        /// Every row the last scan produced, not the visible window.
        var rows: [AgentRow]
        var lang: ResolvedLanguage
        var nowMs: Int64
        /// The last scan that landed; nil before the first.
        var lastScanMs: Int64?
        /// The cadence in force; nil while parked.
        var intervalSeconds: Double?
        /// The cadence that scheduled the last scan (`lastScanMs`); nil when
        /// unknown. Opening the tray shortens `intervalSeconds` at once, but
        /// the scan on screen was due by this one.
        var lastScanIntervalSeconds: Double? = nil
        /// The display is asleep or the screen is locked: nothing is read.
        var asleep: Bool = false
    }

    /// A scan is late only past twice its interval — the longer of the one
    /// that scheduled it and the one in force, so opening the tray (which
    /// shortens the interval) does not flash orange before the scan it asked
    /// for lands — and never sooner than this.
    static let minimumStaleSeconds: Double = 30

    static func make(_ input: Input) -> TrayHeaderModel {
        let lang = input.lang
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        let rows = input.rows
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

        let fresh = freshness(input)
        return TrayHeaderModel(lang: lang, counts: counts, title: title, freshness: fresh.text, stale: fresh.stale)
    }

    /// "updated 3s ago" / "not updated for 4m" / "updating…".
    static func freshness(_ input: Input) -> (text: String, stale: Bool) {
        func t(_ key: L10n.Key) -> String { L10n.t(key, input.lang) }
        guard let last = input.lastScanMs, last > 0 else {
            return (t(.headerUpdating), input.asleep)
        }
        let age = max(0, Double(input.nowMs - last) / 1000)
        let interval = max(input.intervalSeconds ?? 0, input.lastScanIntervalSeconds ?? 0)
        let allowed = max(2 * interval, minimumStaleSeconds)
        if input.asleep || age > allowed {
            return (String(format: t(.headerNotUpdated), DurationFormat.label(seconds: age, lang: input.lang)), true)
        }
        if age < 5 { return (t(.headerUpdatedNow), false) }
        return (String(format: t(.headerUpdatedAgo), DurationFormat.label(seconds: age, lang: input.lang)), false)
    }
}

/// 23.0 · the tray's one notice: something on this Mac needs fixing, with
/// the one action that fixes it. At most one, in this order: notifications
/// (a "needs you" cannot reach a closed tray), then a hook missing for a
/// live agent. Pure.
struct TrayNoticeModel: Equatable {
    enum Kind: Equatable {
        case notificationsDenied, notificationsOff, bannerFailed, hooksMissing
    }

    enum Action: Equatable {
        case openNotificationSettings, enableNotifications, installHooks
    }

    var kind: Kind
    var text: String
    var actionTitle: String
    var action: Action
    var systemImage: String
    var tone: PulseTheme.Tone

    struct Input {
        var lang: ResolvedLanguage
        var notifyOnWaiting: Bool
        /// nil: macOS has not been asked yet.
        var notifyAuthorized: Bool?
        /// Notification Center refused the last banner while a wait is open.
        var bannerFailed: Bool
        /// A live agent's hook is not installed.
        var hooksMissing: Bool
    }

    static func pick(_ input: Input) -> TrayNoticeModel? {
        func t(_ key: L10n.Key) -> String { L10n.t(key, input.lang) }
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
        if input.hooksMissing {
            return TrayNoticeModel(
                kind: .hooksMissing, text: t(.hooksNudge),
                actionTitle: t(.installHooks), action: .installHooks,
                systemImage: "link", tone: .idle
            )
        }
        return nil
    }
}

/// 23.0 · no row moves under the pointer. While the tray is open its order
/// is frozen: rows keep the place they had when it opened, a new row is
/// appended, a row that left disappears. The builder's order is applied the
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

    /// The most rows the open tray lists unfiltered while the builder's
    /// window stays folded: room for newcomers beside the rows already shown.
    static let openCap = SnapshotBuilder.maxVisibleRows * 2

    /// What the open tray lists with no filter: every row already on screen
    /// this glance (`pinned`) that still exists, in the frozen order, then
    /// rows that entered the builder's `window` since, in the order they
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
