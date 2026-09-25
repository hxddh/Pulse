import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest
@testable import PulseRespond

/// 12.3 δ — the Waiting notification decision is a value. No store, no
/// Notification Center, no ledger file: facts in, a plan out.
final class WaitingDeliveryTests: XCTestCase {
    private func waiting(_ key: String, agent: AgentID = .claude) -> AgentRow {
        var row = AgentRow(rowKey: key, agent: agent)
        row.waiting = true
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
        idle.waiting = false
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
