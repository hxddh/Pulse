import Foundation

/// What the "needs you" banner remembers — in memory only, for this launch.
///
/// Per row: the wait open on it now, and whether its banner is owed, was
/// accepted by Notification Center, or the person dismissed the wait; and
/// when the last banner went out (the rate limit). Nothing here is written
/// to disk: the agents' hooks are the only state that outlives a launch, and
/// the first projection after one is a baseline (a wait already raised is not
/// news), so there is nothing to carry over.
///
/// Pure: `WaitNotifier` owns one and changes it; tests drive it directly.
struct WaitLedger: Equatable {
    struct Wait: Equatable {
        /// When it was raised, by the hook's own clock; 0 unknown.
        var sinceMs: Int64
        /// A banner is owed but not yet accepted (the rate limit, macOS has
        /// not allowed banners yet, or Notification Center refused it).
        var queued = false
        /// Notification Center accepted its banner.
        var notified = false
        /// The person dismissed it.
        var dismissed = false
    }

    /// The wait open on each blocked row, by row key.
    private(set) var waits: [String: Wait] = [:]
    /// When the last banner was accepted — the rate limit's anchor; 0 never.
    private(set) var lastNotificationMs: Int64 = 0

    /// Brings the open waits in line with a projection. A row that is
    /// blocked has exactly one open wait — a fresh one when it is an edge
    /// (`TrayState.newlyBlocked`: a row that was not waiting, or a new raise
    /// on one that was, which inherits nothing from the ask before it); a
    /// row that is not blocked has none, so a wait that resolved is owed no
    /// banner.
    mutating func reconcile(rows: [AgentRow], edges: Set<String>) {
        var next: [String: Wait] = [:]
        for row in rows {
            guard let wait = row.wait, next[row.rowKey] == nil else { continue }
            if let open = waits[row.rowKey], !edges.contains(row.rowKey) {
                next[row.rowKey] = open
            } else {
                next[row.rowKey] = Wait(sinceMs: wait.sinceMs)
            }
        }
        waits = next
    }

    /// The open wait's banner is owed. Returns whether that was news.
    @discardableResult
    mutating func markQueued(_ key: String) -> Bool {
        guard var wait = waits[key], !wait.queued, !wait.notified, !wait.dismissed else { return false }
        wait.queued = true
        waits[key] = wait
        return true
    }

    /// Notification Center accepted the banner. The rate-limit anchor moves
    /// even when the wait resolved meanwhile: the banner was shown.
    mutating func markNotified(_ key: String, nowMs: Int64) {
        if var wait = waits[key] {
            wait.notified = true
            wait.queued = false
            waits[key] = wait
        }
        lastNotificationMs = max(lastNotificationMs, nowMs)
    }

    /// The person dismissed the row's wait: it is owed no banner.
    mutating func dismiss(_ key: String) {
        guard var wait = waits[key] else { return }
        wait.dismissed = true
        wait.queued = false
        waits[key] = wait
    }

    /// Open waits whose banner is still owed.
    var queuedKeys: Set<String> {
        Set(waits.filter { $0.value.queued && !$0.value.notified && !$0.value.dismissed }.keys)
    }

    /// Open waits the person dismissed.
    var dismissedKeys: Set<String> {
        Set(waits.filter { $0.value.dismissed }.keys)
    }

    func canDeliver(nowMs: Int64, minimumIntervalMs: Int64) -> Bool {
        lastNotificationMs == 0 || nowMs - lastNotificationMs >= minimumIntervalMs
    }
}
