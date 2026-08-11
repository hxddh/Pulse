import XCTest
@testable import PulseBar

@MainActor
final class GoLookClosureTests: XCTestCase {
    private var store: StatusStore!

    override func setUp() {
        store = StatusStore()
        store.installPreviewFixture("status-waiting")
    }

    func testFocusAgentSeedsPendingRevealForWaitingRow() {
        let row = try! XCTUnwrap(store.snapshot.rows.first(where: \.waiting) ?? store.allRowsForDisplay.first(where: \.waiting))
        store.clearPendingRevealRowKey()
        store.focusAgent(idRaw: row.agent.rawValue, session: row.sessionID, rowKey: row.rowKey)
        XCTAssertEqual(store.pendingRevealRowKey, row.rowKey)
    }

    func testFocusAgentPrefersExactRowKey() {
        store.installPreviewFixture("waiting")
        let rows = store.allRowsForDisplay.filter(\.waiting)
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

    func testFocusFirstWaitingSeedsReveal() {
        store.clearPendingRevealRowKey()
        store.focusFirstWaiting()
        let expected = store.allRowsForDisplay.first(where: \.waiting)?.rowKey
        XCTAssertEqual(store.pendingRevealRowKey, expected)
    }

    func testFocusOldestWaitUsesRevealPath() {
        store.clearPendingRevealRowKey()
        store.focusOldestWait()
        XCTAssertNotNil(store.pendingRevealRowKey)
        XCTAssertEqual(store.pendingRevealRowKey, store.oldestWait?.rowKey)
    }

    func testClearPendingReveal() {
        store.requestTrayReveal(rowKey: "demo-key")
        XCTAssertEqual(store.pendingRevealRowKey, "demo-key")
        store.clearPendingRevealRowKey()
        XCTAssertNil(store.pendingRevealRowKey)
    }

    func testStaleRowKeyStillOpensTrayIdentity() {
        store.clearPendingRevealRowKey()
        store.focusAgent(idRaw: "claude", session: "", rowKey: "missing|session")
        // May resolve to a waiting claude from fixture, or keep the stale key.
        XCTAssertNotNil(store.pendingRevealRowKey)
    }

    func testLookClosureActivateReusesGoLookReveal() {
        store.installPreviewFixture("status-running")
        let prior = store.captureLookFingerprint()
        store.installPreviewFixture("status-waiting")
        store.applyLookContinuity(prior: prior, closedAt: prior.closedAt)
        store.clearPendingRevealRowKey()
        store.activateLookContinuity()
        XCTAssertEqual(store.pendingRevealRowKey, "status-fixture")
        XCTAssertTrue(store.lookContinuityNotice.isEmpty)
    }
}
