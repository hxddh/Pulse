import Foundation

/// What a scan's Waiting rows mean for notification delivery — as a value.
///
/// 12.3 δ. `postWaitingNotifications` used to decide and act in one method:
/// which rows qualify, whether the rate limit allows a banner now, whether
/// several sessions collapse into one summary — interleaved with ledger
/// writes, Notification Center calls and a sound. The decision is now this
/// planner, fed only facts; `StatusStore` carries out the plan it returns.
/// Behaviour is unchanged; the rules are testable without a store.
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
    /// `AttentionLedger.canDeliver` for this instant.
    var canDeliverNow: Bool
    var msSinceLastNotification: Int64
    var minimumIntervalMs: Int64

    func plan(_ rows: [AgentRow]) -> Plan {
        let eligible = rows.filter { row in
            row.waiting
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
}
