import Foundation
import AppKit
import Testing
import XCTest
@testable import PulseApp
@testable import PulseQA
@testable import PulseCore
@testable import PulseHarvest

// Notifier: the in-memory wait ledger, banner planning, copy, routing and
// reveals.

/// The Waiting notification decision is a value. No store, no
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

/// What the banner remembers, in memory: the wait open on each row, whether
/// its banner is owed, went out or was dismissed, and the rate limit. The
/// edges come from the projection (`TrayState.newlyBlocked`).
@Suite("Wait ledger")
struct WaitLedgerTests {
    let now: Int64 = 1_800_000_000_000
    let minute: Int64 = 60_000

    private func running(_ key: String, _ agent: AgentID = .claude) -> AgentRow {
        var row = AgentRow(rowKey: key, agent: agent)
        row.sessionID = key
        row.task = "Fix the login test"
        row.liveProcess = true
        row.state = .running
        row.lastEventMs = now - minute
        return row
    }

    private func waiting(_ key: String, _ agent: AgentID = .claude, since: Int64? = nil, ask: String = "") -> AgentRow {
        var row = running(key, agent)
        row.state = .blocked(RowWait(kind: "Permission", ask: ask, sinceMs: since ?? now - minute))
        return row
    }

    /// The projection's edges against the waits it had before.
    private func edges(_ rows: [AgentRow], previous: [String: Int64]) -> Set<String> {
        let state = TrayState.assemble(rows: rows, context: TrayState.Context(nowMs: now, previousWaits: previous))
        return Set(state.newlyBlocked.map(\.rowKey))
    }

    @Test func aWaitThatResolvedLeavesTheQueue() {
        var ledger = WaitLedger()
        ledger.reconcile(rows: [waiting("claude|a")], edges: ["claude|a"])
        ledger.markQueued("claude|a")
        #expect(ledger.queuedKeys == ["claude|a"])
        ledger.reconcile(rows: [running("claude|a")], edges: [])
        #expect(ledger.queuedKeys.isEmpty, "a resolved wait is owed no banner")
        #expect(ledger.waits.isEmpty)
    }

    @Test func owedBannersAreRebuiltFromThisScansRows() {
        let fresh = waiting("claude|a", ask: "Bash: npm test")
        let rows = [fresh, running("codex|b", .codex), waiting("cursor|c", .cursor)]
        let owed = WaitNotifier.queuedDeliveryRows(
            queued: ["claude|a", "codex|b", "gone|x", "cursor|c"],
            rows: rows,
            muted: [.cursor]
        )
        let keys = owed.map { $0.rowKey }
        #expect(keys == ["claude|a"], "only a key waiting now, unmuted, in a current row")
        #expect(owed.first?.wait?.ask == "Bash: npm test", "the current row, not a frozen copy")
    }

    /// A second permission on a row that is still waiting is its own wait:
    /// its own edge, and no dismissal of the first carries over.
    @Test func aSecondAskOnTheSameRowIsItsOwnWait() {
        var ledger = WaitLedger()
        let first = waiting("claude|a", since: now - minute)
        ledger.reconcile(rows: [first], edges: edges([first], previous: [:]))
        ledger.dismiss("claude|a")
        #expect(ledger.dismissedKeys == ["claude|a"])

        var second = waiting("claude|a", since: now + minute)
        second.activityMs = now + 50_000 // the next tool call began the second ask
        let edge = edges([second], previous: ["claude|a": now - minute])
        #expect(edge == ["claude|a"])
        ledger.reconcile(rows: [second], edges: edge)
        #expect(ledger.waits["claude|a"]?.sinceMs == now + minute)
        #expect(ledger.dismissedKeys.isEmpty, "the new ask inherits no dismissal")
    }

    /// Claude's Notification lands a second after its PermissionRequest,
    /// with nothing done in between: one wait, one banner.
    @Test func theSameAskSaidTwiceIsOneWait() {
        var ledger = WaitLedger()
        let raise = waiting("claude|a", since: now - minute)
        ledger.reconcile(rows: [raise], edges: ["claude|a"])
        ledger.markNotified("claude|a", nowMs: now)
        let echo = waiting("claude|a", since: now - minute + 1_000)
        #expect(!TrayState.isNewRaise(echo, previousSinceMs: now - minute))
        let edge = edges([echo], previous: ["claude|a": now - minute])
        #expect(edge.isEmpty)
        ledger.reconcile(rows: [echo], edges: edge)
        #expect(ledger.waits["claude|a"]?.notified == true, "the echo is the wait that already had its banner")
    }

    @Test func aRowThatWasNotWaitingIsAnEdge() {
        #expect(edges([waiting("a")], previous: [:]) == ["a"])
        #expect(edges([waiting("a")], previous: ["a": now - minute]).isEmpty, "still the same wait")
        #expect(edges([running("a")], previous: ["a": now - minute]).isEmpty, "a resolved wait is no edge")
    }

    @Test func queuingTwiceIsOneChange() {
        var ledger = WaitLedger()
        ledger.reconcile(rows: [waiting("claude|a")], edges: ["claude|a"])
        let first = ledger.markQueued("claude|a")
        let second = ledger.markQueued("claude|a")
        #expect(first)
        #expect(!second)
        let unknown = ledger.markQueued("gone|x")
        #expect(!unknown, "no open wait, nothing owed")
    }

    @Test func aDismissalIsOwedNoBanner() {
        var ledger = WaitLedger()
        ledger.reconcile(rows: [waiting("claude|a")], edges: ["claude|a"])
        ledger.markQueued("claude|a")
        ledger.dismiss("claude|a")
        #expect(ledger.dismissedKeys == ["claude|a"])
        #expect(ledger.queuedKeys.isEmpty, "a dismissed wait is owed no banner")
        let requeued = ledger.markQueued("claude|a")
        #expect(!requeued)
    }

    @Test func theRateLimitCountsFromTheLastAcceptedBanner() {
        var ledger = WaitLedger()
        #expect(ledger.canDeliver(nowMs: now, minimumIntervalMs: 3_000), "no banner yet")
        ledger.reconcile(rows: [waiting("claude|a")], edges: ["claude|a"])
        ledger.markNotified("claude|a", nowMs: now)
        #expect(!ledger.canDeliver(nowMs: now + 1_000, minimumIntervalMs: 3_000))
        #expect(ledger.canDeliver(nowMs: now + 3_000, minimumIntervalMs: 3_000))
        // A banner shown for a wait that resolved meanwhile still counts.
        ledger.markNotified("gone|x", nowMs: now + 5_000)
        #expect(ledger.lastNotificationMs == now + 5_000)
    }
}

/// A banner lives exactly as long as its wait: answered, dismissed or
/// ended, it is withdrawn; a click on one whose wait is gone opens the tray.
@Suite("Banner withdrawal")
struct BannerWithdrawalTests {
    let now: Int64 = 1_800_000_000_000
    let minute: Int64 = 60_000

    private func running(_ key: String) -> AgentRow {
        var row = AgentRow(rowKey: key, agent: .claude)
        row.state = .running
        return row
    }

    private func waiting(_ key: String, since: Int64? = nil, inFront: Bool = false) -> AgentRow {
        var row = AgentRow(rowKey: key, agent: .claude)
        row.state = .blocked(RowWait(kind: "Permission", ask: "Bash: make", sinceMs: since ?? now - minute, inFront: inFront))
        return row
    }

    @Test func anAnsweredWaitWithdrawsItsBanner() {
        var ledger = WaitLedger()
        ledger.reconcile(rows: [waiting("claude|a")], edges: ["claude|a"], nowMs: now)
        let id = WaitLedger.bannerID(rowKey: "claude|a")
        let stale = ledger.markNotified("claude|a", nowMs: now, bannerID: id)
        #expect(stale.isEmpty, "the wait is open: its banner stays")
        let still = ledger.reconcile(rows: [waiting("claude|a")], edges: [], nowMs: now + 1_000)
        #expect(still.isEmpty)
        let answered = ledger.reconcile(rows: [running("claude|a")], edges: [], nowMs: now + 2_000)
        #expect(answered == [id])
    }

    @Test func aSessionThatEndedWithdrawsItsBanner() {
        var ledger = WaitLedger()
        ledger.reconcile(rows: [waiting("claude|a")], edges: ["claude|a"], nowMs: now)
        ledger.markNotified("claude|a", nowMs: now, bannerID: WaitLedger.bannerID(rowKey: "claude|a"))
        let gone = ledger.reconcile(rows: [], edges: [], nowMs: now + 1_000)
        #expect(gone == [WaitLedger.bannerID(rowKey: "claude|a")])
    }

    @Test func aDismissalWithdrawsItsBanner() {
        var ledger = WaitLedger()
        ledger.reconcile(rows: [waiting("claude|a")], edges: ["claude|a"], nowMs: now)
        ledger.markNotified("claude|a", nowMs: now, bannerID: WaitLedger.bannerID(rowKey: "claude|a"))
        let first = ledger.dismiss("claude|a")
        let second = ledger.dismiss("claude|a")
        #expect(first == [WaitLedger.bannerID(rowKey: "claude|a")])
        #expect(second.isEmpty, "withdrawn once")
    }

    /// A summary names several waits: it goes when the last of them does.
    @Test func aSummaryStaysWhileAnyOfItsWaitsIsOpen() {
        var ledger = WaitLedger()
        let keys = ["claude|a", "claude|b"]
        ledger.reconcile(rows: keys.map { waiting($0) }, edges: Set(keys), nowMs: now)
        let id = WaitLedger.summaryID(rowKeys: keys)
        for key in keys { ledger.markNotified(key, nowMs: now, bannerID: id) }
        let one = ledger.reconcile(rows: [running("claude|a"), waiting("claude|b")], edges: [], nowMs: now + 1_000)
        #expect(one.isEmpty, "claude|b still waits under that summary")
        let both = ledger.reconcile(rows: [running("claude|a"), running("claude|b")], edges: [], nowMs: now + 2_000)
        #expect(both == [id])
    }

    /// Answered while Notification Center was still accepting it: the
    /// banner goes as it came.
    @Test func aBannerAcceptedAfterItsWaitResolvedIsWithdrawnAtOnce() {
        var ledger = WaitLedger()
        ledger.reconcile(rows: [waiting("claude|a")], edges: ["claude|a"], nowMs: now)
        ledger.reconcile(rows: [running("claude|a")], edges: [], nowMs: now + 500)
        let id = WaitLedger.bannerID(rowKey: "claude|a")
        let stale = ledger.markNotified("claude|a", nowMs: now + 900, bannerID: id)
        #expect(stale == [id])
        #expect(ledger.lastNotificationMs == now + 900, "it was shown: the rate limit counts it")
    }

    @Test func aClickOnABannerWhoseWaitIsGoneOpensTheTray() {
        var ledger = WaitLedger()
        ledger.reconcile(rows: [waiting("claude|a"), waiting("codex|b")], edges: ["claude|a", "codex|b"], nowMs: now)
        #expect(ledger.openWait(rowKey: "claude|a", summaryRowKeys: []) == "claude|a")
        ledger.dismiss("claude|a")
        #expect(ledger.openWait(rowKey: "claude|a", summaryRowKeys: []) == nil, "dismissed: the tray, not the prompt")
        #expect(ledger.openWait(rowKey: "claude|a", summaryRowKeys: ["claude|a", "codex|b"]) == "codex|b",
                "a summary goes to the wait of its that is still open")
        ledger.reconcile(rows: [], edges: [], nowMs: now + 1_000)
        #expect(ledger.openWait(rowKey: "codex|b", summaryRowKeys: []) == nil)
    }

    @MainActor
    @Test func theNotifierRoutesAStaleClickToTheTray() {
        let store = StatusStore()
        store.installPreviewFixture("status-waiting")
        store.clearPendingRevealRowKey()
        store.notifier.handleBannerClick(agent: "claude", session: "gone", rowKey: "claude|gone", summaryRowKeys: [])
        #expect(store.pendingRevealRowKey == nil, "no stale routing: the tray opens on its own selection")
    }

    // MARK: - The deferred banner

    @Test func aWaitRaisedInFrontIsDueAfterThirtySeconds() {
        var ledger = WaitLedger()
        let row = waiting("claude|a", since: now, inFront: true)
        ledger.reconcile(rows: [row], edges: ["claude|a"], nowMs: now)
        let early = WaitingDelivery.deferred(rows: [row], ledger: ledger, muted: [], nowMs: now + 29_000)
        #expect(early.isEmpty)
        let due = WaitingDelivery.deferred(rows: [row], ledger: ledger, muted: [], nowMs: now + 30_000)
        #expect(due.map(\.rowKey) == ["claude|a"])
        let muted = WaitingDelivery.deferred(rows: [row], ledger: ledger, muted: [.claude], nowMs: now + 30_000)
        #expect(muted.isEmpty)
        let notInFront = waiting("claude|b", since: now)
        ledger.reconcile(rows: [row, notInFront], edges: ["claude|b"], nowMs: now)
        let onlyFront = WaitingDelivery.deferred(rows: [row, notInFront], ledger: ledger, muted: [], nowMs: now + 60_000)
        #expect(onlyFront.map(\.rowKey) == ["claude|a"], "a wait not raised in front had its banner at once")
    }

    @Test func aDeferredBannerIsPostedOnce() {
        var ledger = WaitLedger()
        let row = waiting("claude|a", since: now, inFront: true)
        ledger.reconcile(rows: [row], edges: ["claude|a"], nowMs: now)
        ledger.markFrontDue("claude|a")
        #expect(WaitingDelivery.deferred(rows: [row], ledger: ledger, muted: [], nowMs: now + 40_000).isEmpty,
                "already due: asked once")
        // The planner lets it through now — and only it.
        let plan = WaitingDelivery(
            muted: [], acknowledged: [], inFlight: [], canDeliverNow: true,
            msSinceLastNotification: 60_000, minimumIntervalMs: 0, frontDue: ledger.frontDueKeys
        ).plan([row, waiting("claude|b", since: now, inFront: true)])
        guard case .post(let ready, _) = plan else {
            Issue.record("\(plan)")
            return
        }
        #expect(ready.map(\.rowKey) == ["claude|a"])
        ledger.markNotified("claude|a", nowMs: now + 40_000, bannerID: WaitLedger.bannerID(rowKey: "claude|a"))
        var answeredLedger = ledger
        answeredLedger.reconcile(rows: [running("claude|a")], edges: [], nowMs: now + 50_000)
        #expect(answeredLedger.waits.isEmpty)
    }

    /// A wait the launch replay found is not news — not even thirty seconds
    /// later.
    @Test func aWaitFromTheLaunchReplayIsNeverDeferredIntoABanner() {
        var ledger = WaitLedger()
        let row = waiting("claude|a", since: now - 10 * minute, inFront: true)
        ledger.reconcile(rows: [row], edges: ["claude|a"], nowMs: now, baseline: true)
        #expect(WaitingDelivery.deferred(rows: [row], ledger: ledger, muted: [], nowMs: now + minute).isEmpty)
    }

    /// The notifier asks whether the app is in front only once the hold is
    /// over, and posts nothing while it is.
    @MainActor
    @Test func theNotifierHoldsADeferredBannerWhileItsAppIsInFront() {
        let store = StatusStore()
        store.notifyAuthorized = nil
        var asked = 0
        var front = true
        store.notifier.promptInFront = { _ in
            asked += 1
            return front
        }
        let row = waiting("claude|a", since: now, inFront: true)
        let raised = TrayState.assemble(rows: [row], context: TrayState.Context(nowMs: now))
        store.notifier.scanLanded(raised, nowMs: now, baseline: false)
        #expect(asked == 0, "no question before the hold is over")
        let later = TrayState.assemble(rows: [row], context: TrayState.Context(nowMs: now + 31_000, previousWaits: raised.waitingSince))
        store.notifier.scanLanded(later, nowMs: now + 31_000, baseline: false)
        #expect(asked == 1)
        let queuedWhileFront = store.notifier.ledger.queuedKeys
        #expect(queuedWhileFront.isEmpty, "its app is in front: still no banner")
        front = false
        store.notifier.scanLanded(later, nowMs: now + 36_000, baseline: false)
        let owed = store.notifier.ledger.queuedKeys
        #expect(owed == ["claude|a"], "its app left the front: its one banner is owed")
        store.notifier.scanLanded(later, nowMs: now + 41_000, baseline: false)
        #expect(asked == 2, "due once: never asked again")
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
    /// Swift 6 mode: built per test on the main actor — a
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

/// Regressions for two defects found by reading the code.
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

/// Where a banner click goes: the first wait, and never another agent's.
@MainActor
@Suite("Banner routing", .serialized)
struct BannerRoutingTests {
    let now: Int64 = 1_800_000_000_000
    static let minute: Int64 = 60_000

    // MARK: - Jumping to a wait

    func waitingRow(_ key: String, _ agent: AgentID, session: String = "", since: Int64) -> AgentRow {
        var row = AgentRow(rowKey: key, agent: agent)
        row.sessionID = session
        row.state = .blocked(RowWait(kind: "Permission", sinceMs: since))
        return row
    }

    /// The jump takes the first wait in the builder's order, which
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
