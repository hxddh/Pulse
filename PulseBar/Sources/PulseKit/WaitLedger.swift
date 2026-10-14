import Foundation

/// What the "needs you" banner remembers — in memory only, for this launch.
///
/// Per row: the wait open on it now, and whether its banner is owed, was
/// accepted by Notification Center (and under which id, so it can be
/// withdrawn), or the person dismissed the wait; and when the last banner
/// went out (the rate limit). Nothing here is written to disk: the agents'
/// hooks are the only state that outlives a launch, and the first
/// projection after one is a baseline (a wait already raised is not news),
/// so there is nothing to carry over.
///
/// Pure: `WaitNotifier` owns one and changes it; tests drive it directly.
/// Every change that closes a banner's wait returns the banner ids to
/// withdraw — a banner lives exactly as long as some open wait it names.
package struct WaitLedger: Equatable {
    package struct Wait: Equatable {
        /// When it was raised, by the hook's own clock; 0 unknown.
        package var sinceMs: Int64
        /// When this ledger first saw it (the projection's clock) — the
        /// deferred banner's clock when the hook's is unknown.
        package var seenMs: Int64 = 0
        /// Raised after Pulse was watching: a wait found by the launch
        /// replay is not news, now or later.
        package var announce = true
        /// A banner is owed but not yet accepted (the rate limit, macOS has
        /// not allowed banners yet, or Notification Center refused it).
        package var queued = false
        /// Notification Center accepted its banner.
        package var notified = false
        /// The person dismissed it.
        package var dismissed = false
        /// Its prompt was in front when it was raised, and it has stayed
        /// open past `WaitingDelivery.deferAfterMs` while its app is not in
        /// front: it may have its one banner now.
        package var frontDue = false
        /// The id of the banner that announces it; nil while none is shown.
        package var bannerID: String?
    }

    /// The wait open on each blocked row, by row key.
    package private(set) var waits: [String: Wait] = [:]
    /// When the last banner was accepted — the rate limit's anchor; 0 never.
    package private(set) var lastNotificationMs: Int64 = 0

    package init() {}

    // MARK: - Banner ids (pure)

    /// One banner per row: a later ask on the same row replaces it.
    package static func bannerID(rowKey: String) -> String {
        let safe = rowKey
            .replacingOccurrences(of: "|", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        return "pulse-waiting-\(safe)"
    }

    // MARK: - Changes

    /// Brings the open waits in line with a projection. A row that is
    /// blocked has exactly one open wait — a fresh one when it is an edge
    /// (`TrayState.newlyBlocked`: a row that was not waiting, or a new raise
    /// on one that was, which inherits nothing from the ask before it); a
    /// row that is not blocked has none, so a wait that resolved is owed no
    /// banner. `baseline`: the launch replay's projection — its waits are
    /// never announced. Returns the banner ids whose waits all closed.
    @discardableResult
    package mutating func reconcile(rows: [AgentRow], edges: Set<String>, nowMs: Int64 = 0, baseline: Bool = false) -> Set<String> {
        var next: [String: Wait] = [:]
        for row in rows {
            guard let wait = row.wait, next[row.rowKey] == nil else { continue }
            if let open = waits[row.rowKey], !edges.contains(row.rowKey) {
                next[row.rowKey] = open
            } else {
                next[row.rowKey] = Wait(sinceMs: wait.sinceMs, seenMs: nowMs, announce: !baseline)
            }
        }
        let closed = Set(waits.compactMap { key, wait in next[key] == wait ? nil : wait.bannerID })
        waits = next
        return withdrawable(closed)
    }

    /// The open wait's banner is owed. Returns whether that was news.
    @discardableResult
    package mutating func markQueued(_ key: String) -> Bool {
        guard var wait = waits[key], !wait.queued, !wait.notified, !wait.dismissed else { return false }
        wait.queued = true
        waits[key] = wait
        return true
    }

    /// Notification Center accepted the banner `bannerID`. The rate-limit
    /// anchor moves even when the wait resolved meanwhile: the banner was
    /// shown. Returns `[bannerID]` when no open wait it names is left — the
    /// wait was answered while the request was in flight, and the banner
    /// goes as soon as it came.
    @discardableResult
    package mutating func markNotified(_ key: String, nowMs: Int64, bannerID: String = "") -> Set<String> {
        lastNotificationMs = max(lastNotificationMs, nowMs)
        guard var wait = waits[key], !wait.dismissed else {
            return bannerID.isEmpty ? [] : withdrawable([bannerID])
        }
        wait.notified = true
        wait.queued = false
        if !bannerID.isEmpty { wait.bannerID = bannerID }
        waits[key] = wait
        return []
    }

    /// The person dismissed the row's wait: it is owed no banner, and the
    /// banner it had is withdrawn.
    @discardableResult
    package mutating func dismiss(_ key: String) -> Set<String> {
        guard var wait = waits[key] else { return [] }
        let shown = wait.bannerID
        wait.dismissed = true
        wait.queued = false
        wait.bannerID = nil
        waits[key] = wait
        guard let shown else { return [] }
        return withdrawable([shown])
    }

    /// The in-front hold on this wait is over: it may have its one banner.
    package mutating func markFrontDue(_ key: String) {
        guard var wait = waits[key], !wait.frontDue else { return }
        wait.frontDue = true
        waits[key] = wait
    }

    // MARK: - Reading

    /// `ids` minus any still naming an open, undismissed wait.
    package func withdrawable(_ ids: Set<String>) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let live = Set(waits.values.compactMap { $0.dismissed ? nil : $0.bannerID })
        return ids.subtracting(live)
    }

    /// Whether a banner click has somewhere to go: its wait is still open
    /// and not ignored. False when it was answered — the click opens the
    /// tray instead of routing to a prompt that is gone.
    package func isOpen(_ rowKey: String) -> Bool {
        guard !rowKey.isEmpty, let wait = waits[rowKey] else { return false }
        return !wait.dismissed
    }

    /// Open waits whose banner is still owed.
    package var queuedKeys: Set<String> {
        Set(waits.filter { $0.value.queued && !$0.value.notified && !$0.value.dismissed }.keys)
    }

    /// Open waits the person dismissed.
    package var dismissedKeys: Set<String> {
        Set(waits.filter { $0.value.dismissed }.keys)
    }

    /// Open waits whose in-front hold is over.
    package var frontDueKeys: Set<String> {
        Set(waits.filter { $0.value.frontDue }.keys)
    }

    package func canDeliver(nowMs: Int64, minimumIntervalMs: Int64) -> Bool {
        lastNotificationMs == 0 || nowMs - lastNotificationMs >= minimumIntervalMs
    }
}
