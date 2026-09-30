import Foundation
import AppKit
import Testing
import XCTest
@testable import PulseApp
@testable import PulseQA
@testable import PulseCore
@testable import PulseHarvest

// Notifier: banner planning, copy, routing and reveals.

/// 12.3 δ — the Waiting notification decision is a value. No store, no
/// Notification Center, no ledger file: facts in, a plan out.
final class WaitingDeliveryTests: XCTestCase {
    private func waiting(_ key: String, agent: AgentID = .claude) -> AgentRow {
        var row = AgentRow(rowKey: key, agent: agent)
        row.state = .blocked(RowWait(kind: "Permission"))
        return row
    }

    private func planner(
        muted: Set<AgentID> = [],
        acknowledged: Set<String> = [],
        inFlight: Set<String> = [],
        canDeliverNow: Bool = true,
        sinceLast: Int64 = 60_000
    ) -> WaitingDelivery {
        WaitingDelivery(
            muted: muted,
            acknowledged: acknowledged,
            inFlight: inFlight,
            canDeliverNow: canDeliverNow,
            msSinceLastNotification: sinceLast,
            minimumIntervalMs: 10_000
        )
    }

    func testOnlyUnmutedUnacknowledgedWaitingRowsNotInFlightQualify() {
        var idle = AgentRow(rowKey: "idle", agent: .claude)
        idle.state = .running
        let rows = [
            waiting("a"), waiting("muted", agent: .codex), waiting("ack"), waiting("flying"), idle,
        ]
        let plan = planner(muted: [.codex], acknowledged: ["ack"], inFlight: ["flying"]).plan(rows)
        guard case .post(let ready, let summary) = plan else { return XCTFail("\(plan)") }
        XCTAssertEqual(ready.map(\.rowKey), ["a"])
        XCTAssertFalse(summary)
    }

    func testNothingQualifiesMeansNothing() {
        XCTAssertEqual(planner(acknowledged: ["a"]).plan([waiting("a")]), .nothing)
        XCTAssertEqual(planner().plan([]), .nothing)
    }

    func testRateLimitHoldsAndRetriesWhenTheIntervalHasPassed() {
        let plan = planner(canDeliverNow: false, sinceLast: 4_000).plan([waiting("a")])
        guard case .hold(let held, let retry) = plan else { return XCTFail("\(plan)") }
        XCTAssertEqual(held.map(\.rowKey), ["a"])
        XCTAssertEqual(retry, 6_000)
        // Never a busy loop, even when the clock says the interval is over.
        guard case .hold(_, let floor) = planner(canDeliverNow: false, sinceLast: 60_000).plan([waiting("a")])
        else { return XCTFail() }
        XCTAssertEqual(floor, WaitingDelivery.minimumRetryMs)
    }

    func testMoreThanThreeAtOnceBecomeOneSummary() {
        let three = (1...3).map { waiting("k\($0)") }
        let four = (1...4).map { waiting("k\($0)") }
        guard case .post(_, let small) = planner().plan(three),
              case .post(let many, let big) = planner().plan(four)
        else { return XCTFail() }
        XCTAssertFalse(small)
        XCTAssertTrue(big)
        XCTAssertEqual(many.count, 4)
    }

    func testADuplicateRowKeyNeverTraps() {
        let plan = planner().plan([waiting("same"), waiting("same")])
        guard case .post(let ready, _) = plan else { return XCTFail("\(plan)") }
        XCTAssertEqual(ready.count, 1)
    }
}

/// Notification copy — the banner has to say what is wanted.
final class NotificationCopyTests: XCTestCase {
    @MainActor
    func testBodyCarriesReasonAndMessageNotJustNeedsYou() {
        let store = StatusStore()
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.state = .blocked(RowWait(kind: "Permission", ask: "Approve shell command"))
        row.project = "/Users/me/code/Pulse"

        let body = store.notifier.notificationBody(row)
        XCTAssertTrue(body.contains("Approve shell command"))
        XCTAssertTrue(store.notifier.notificationTitle(row).contains("Claude"))
        XCTAssertTrue(store.notifier.notificationTitle(row).contains("Pulse"), "title should locate the work")
    }

    @MainActor
    func testLongMessagesAreTruncated() {
        let store = StatusStore()
        var row = AgentRow(rowKey: "k", agent: .codex)
        row.state = .blocked(RowWait(kind: "", ask: String(repeating: "x", count: 400)))
        XCTAssertLessThanOrEqual(store.notifier.notificationBody(row).count, 160)
    }

    @MainActor
    func testTitleFallsBackToAgentWhenNoProject() {
        let store = StatusStore()
        var row = AgentRow(rowKey: "k", agent: .codex)
        row.state = .blocked(RowWait(kind: "Input"))
        XCTAssertEqual(store.notifier.notificationTitle(row), "Codex")
    }
}

final class BannerRevealTests: XCTestCase {
    /// 19.0 (Swift 6 mode): built per test on the main actor — a
    /// nonisolated `setUp` cannot hand a main-actor store to `self`.
    @MainActor
    private func makeStore() -> StatusStore {
        let store = StatusStore()
        store.installPreviewFixture("status-waiting")
        return store
    }

    @MainActor
    func testFocusAgentSeedsPendingRevealForWaitingRow() {
        let store = makeStore()
        let row = try! XCTUnwrap(store.snapshot.rows.first(where: \.isBlocked) ?? store.allRowsForDisplay.first(where: \.isBlocked))
        store.clearPendingRevealRowKey()
        store.focusAgent(idRaw: row.agent.rawValue, session: row.sessionID, rowKey: row.rowKey)
        XCTAssertEqual(store.pendingRevealRowKey, row.rowKey)
    }

    @MainActor
    func testFocusAgentPrefersExactRowKey() {
        let store = makeStore()
        store.installPreviewFixture("waiting")
        let rows = store.allRowsForDisplay.filter(\.isBlocked)
        guard rows.count >= 2 else {
            // Fixture may be single-wait; still prove exact key wins.
            let row = try! XCTUnwrap(rows.first ?? store.allRowsForDisplay.first)
            store.focusAgent(idRaw: "other", session: "nope", rowKey: row.rowKey)
            XCTAssertEqual(store.pendingRevealRowKey, row.rowKey)
            return
        }
        let target = rows[1]
        store.focusAgent(idRaw: rows[0].agent.rawValue, session: rows[0].sessionID, rowKey: target.rowKey)
        XCTAssertEqual(store.pendingRevealRowKey, target.rowKey, "exact rowKey must not smear onto another wait")
    }

    @MainActor
    func testFocusFirstWaitingSeedsReveal() {
        let store = makeStore()
        store.clearPendingRevealRowKey()
        store.focusFirstWaiting()
        let expected = store.allRowsForDisplay.first(where: \.isBlocked)?.rowKey
        XCTAssertEqual(store.pendingRevealRowKey, expected)
    }

    @MainActor
    func testClearPendingReveal() {
        let store = makeStore()
        store.requestTrayReveal(rowKey: "demo-key")
        XCTAssertEqual(store.pendingRevealRowKey, "demo-key")
        store.clearPendingRevealRowKey()
        XCTAssertNil(store.pendingRevealRowKey)
    }

    @MainActor
    func testStaleRowKeyStillOpensTrayIdentity() {
        let store = makeStore()
        store.clearPendingRevealRowKey()
        store.focusAgent(idRaw: "claude", session: "", rowKey: "missing|session")
        // May resolve to a waiting claude from fixture, or keep the stale key.
        XCTAssertNotNil(store.pendingRevealRowKey)
    }
}

/// Regressions for two defects found by reading 0.99.0.
///
/// Both had the same shape: something that looked verified was not. One test
/// asserted a tool's output format the tool does not produce; one dictionary
/// assumed keys could not collide when two independent lists fed it.
final class DeliveryPlanningTests: XCTestCase {
    // MARK: - Waiting delivery must not trap on a duplicate row key

    /// A queued edge and a fresh edge for the same session used to reach
    /// `Dictionary(uniqueKeysWithValues:)` together and crash the app.
    @MainActor
    func testAQueuedRowAndAFreshEdgeForTheSameSessionDoNotCrash() {
        var queued = AgentRow(rowKey: "codex|abc", agent: .codex)
        queued.state = .blocked(RowWait(kind: "Permission", sinceMs: 1_000))
        queued.task = "the queued copy"

        var fresh = queued
        fresh.state = .blocked(RowWait(kind: "Permission", sinceMs: 9_000))
        fresh.task = "the newer wait"

        let rows = WaitNotifier.waitingDeliveryRows(edges: [fresh], queued: [queued])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.task, "the newer wait", "the fresh edge wins")
    }

    @MainActor
    func testDistinctSessionsAreAllDelivered() {
        var a = AgentRow(rowKey: "codex|a", agent: .codex)
        a.state = .blocked(RowWait(kind: "Permission"))
        var b = AgentRow(rowKey: "claude|b", agent: .claude)
        b.state = .blocked(RowWait(kind: "Permission"))
        var c = AgentRow(rowKey: "cursor|c", agent: .cursor)
        c.state = .blocked(RowWait(kind: "Permission"))

        let rows = WaitNotifier.waitingDeliveryRows(edges: [a, b], queued: [c])
        XCTAssertEqual(Set(rows.map(\.rowKey)), ["codex|a", "claude|b", "cursor|c"])
    }

    @MainActor
    func testNoEdgesAndNoQueueIsEmpty() {
        XCTAssertTrue(WaitNotifier.waitingDeliveryRows(edges: [], queued: []).isEmpty)
    }
}

/// Clarity fixes — each test pins one defect found by reading the code: the
/// value the user would have seen, before and after.
@MainActor
@Suite("Banner routing", .serialized)
struct BannerRoutingTests {
    let now: Int64 = 1_800_000_000_000
    static let minute: Int64 = 60_000

    // MARK: - 12 · a summary banner's click is audited on every wait it counted

    @Test func aSummaryBannerStandsForEveryWait() {
        #expect(PulseNotify.bannerWaitIDs(["a|1", "b|1", "c|1", "b|1", ""]) == ["a|1", "b|1", "c|1"])
        #expect(PulseNotify.bannerWaitIDs(["solo|1"]) == ["solo|1"])
        #expect(PulseNotify.bannerWaitIDs([]).isEmpty)
    }

    // MARK: - 13 / 14 · jumping to a wait

    func waitingRow(_ key: String, _ agent: AgentID, session: String = "", since: Int64) -> AgentRow {
        var row = AgentRow(rowKey: key, agent: agent)
        row.sessionID = session
        row.state = .blocked(RowWait(kind: "Permission", sinceMs: since))
        return row
    }

    /// 23.0: the jump takes the first wait in the builder's order, which
    /// lists the oldest first.
    @Test func theJumpGoesToTheFirstListedWait() {
        let oldest = waitingRow("a", .claude, since: now - 10 * Self.minute)
        let newer = waitingRow("b", .codex, since: now - Self.minute)
        #expect(StatusStore.firstWaitingRow(in: [oldest, newer])?.rowKey == "a")
        #expect(StatusStore.firstWaitingRow(in: []) == nil)
    }

    @Test func aBannerClickStaysInsideItsAgentAndNeedsAUniquePrefix() {
        let codex = waitingRow("codex|s1", .codex, session: "s1-abc", since: now)
        let claudeA = waitingRow("claude|a", .claude, session: "sess-1", since: now)
        let claudeB = waitingRow("claude|b", .claude, session: "sess-12", since: now)
        #expect(StatusStore.focusTarget(in: [codex, claudeA], idRaw: "claude", session: "s1-abc", rowKey: "")?.rowKey == "claude|a",
                "another agent's session is not a match; the agent's own waiting row is")
        #expect(StatusStore.focusTarget(in: [claudeA, claudeB], idRaw: "claude", session: "sess-1", rowKey: "")?.rowKey == "claude|a",
                "exact wins")
        #expect(StatusStore.focusTarget(in: [claudeB], idRaw: "claude", session: "sess-123", rowKey: "")?.rowKey == "claude|b")
        let ambiguous = StatusStore.focusTarget(in: [claudeA, claudeB], idRaw: "claude", session: "sess-1234", rowKey: "")
        #expect(ambiguous?.rowKey == "claude|a", "two prefixes: no session match, fall back to the agent's first wait")
    }
}
