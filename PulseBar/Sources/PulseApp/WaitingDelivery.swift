import Foundation

/// What a scan's Waiting rows mean for notification delivery — as a value.
///
/// Which rows qualify, whether the rate limit allows a banner now, whether
/// several sessions collapse into one summary: this planner is fed only
/// facts, and `WaitNotifier` carries out the plan it returns, so the rules
/// are testable without a store.
struct WaitingDelivery: Equatable {
    enum Plan: Equatable {
        /// No row qualifies.
        case nothing
        /// Rate-limited: queue these and try again after `retryAfterMs`.
        case hold([AgentRow], retryAfterMs: Int64)
        /// Post now — as one summary when more than `summaryAbove` sessions
        /// crossed into Waiting together.
        case post([AgentRow], summary: Bool)
    }

    /// More sessions than this at once become one summary banner.
    static let summaryAbove = 3
    /// Never re-arm a retry sooner than this.
    static let minimumRetryMs: Int64 = 250

    var muted: Set<AgentID>
    /// Row keys whose active Waiting event the user already acknowledged.
    var acknowledged: Set<String>
    /// Row keys Notification Center has not answered for yet.
    var inFlight: Set<String>
    /// `WaitLedger.canDeliver` for this instant.
    var canDeliverNow: Bool
    var msSinceLastNotification: Int64
    var minimumIntervalMs: Int64
    /// Row keys whose in-front hold is over (`WaitLedger.frontDueKeys`):
    /// raised while their prompt was in front, still open, app no longer
    /// in front.
    var frontDue: Set<String> = []

    func plan(_ rows: [AgentRow]) -> Plan {
        let eligible = rows.filter { row in
            row.isBlocked
                // 16.0: the prompt was already in front of the user when it
                // was raised — the lamp says so; a banner and a sound would
                // only interrupt someone who is looking at it — unless
                // it is still open after `deferAfterMs` and its app has left
                // the front (`deferred`).
                && (row.wait?.inFront != true || frontDue.contains(row.rowKey))
                && !muted.contains(row.agent)
                && !acknowledged.contains(row.rowKey)
                && !inFlight.contains(row.rowKey)
        }
        // One per row key, first wins — `Dictionary(uniqueKeysWithValues:)`
        // traps on a duplicate and once took the menu bar down with it.
        let candidates = Array(
            Dictionary(eligible.map { ($0.rowKey, $0) }, uniquingKeysWith: { first, _ in first }).values
        )
        guard !candidates.isEmpty else { return .nothing }
        guard canDeliverNow else {
            return .hold(
                candidates,
                retryAfterMs: max(minimumIntervalMs - msSinceLastNotification, Self.minimumRetryMs)
            )
        }
        return .post(candidates, summary: candidates.count > Self.summaryAbove)
    }

    // MARK: - The deferred banner

    /// How long a wait raised in front of the person is left to them before
    /// it may have a banner.
    static let deferAfterMs: Int64 = 30_000

    /// Waits raised while their prompt was in front that are due a second
    /// look now: still open, announced (not the launch replay's), not
    /// dismissed, never bannered, unmuted, and at least `deferAfterMs` old
    /// by the hook's clock (the ledger's first sight when the hook's is
    /// unknown). The caller asks whether their app is still in front and
    /// marks the ones that are not `frontDue`; they get one banner. Pure.
    static func deferred(rows: [AgentRow], ledger: WaitLedger, muted: Set<AgentID>, nowMs: Int64) -> [AgentRow] {
        rows.filter { row in
            guard let wait = row.wait, wait.inFront, !muted.contains(row.agent),
                  let open = ledger.waits[row.rowKey],
                  open.announce, !open.frontDue, !open.notified, !open.dismissed
            else { return false }
            let since = wait.sinceMs > 0 ? wait.sinceMs : open.seenMs
            return since > 0 && nowMs - since >= deferAfterMs
        }
    }
}
