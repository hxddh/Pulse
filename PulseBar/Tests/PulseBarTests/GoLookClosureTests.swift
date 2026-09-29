import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

final class GoLookClosureTests: XCTestCase {
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
    func testFocusOldestWaitUsesRevealPath() {
        let store = makeStore()
        store.clearPendingRevealRowKey()
        store.focusOldestWait()
        XCTAssertNotNil(store.pendingRevealRowKey)
        XCTAssertEqual(store.pendingRevealRowKey, store.oldestWait?.rowKey)
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
