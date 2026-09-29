import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

/// 0.97 Hero Honesty — tray hero is the user goal; Details/header do not invent.
final class HeroHonestyTests: XCTestCase {
    @MainActor
    func testDetailPhaseDoesNotInventPermissionForInputWait() {
        let store = StatusStore()
        store.language = .en
        var row = AgentRow(rowKey: "k", agent: .claude)
        row.waiting = true
        row.waitKind = "Input"
        row.phase = ""
        let phase = store.detailPhase(row)
        XCTAssertEqual(phase, "Input")
        XCTAssertFalse(phase.lowercased().contains("permission"))
    }

    @MainActor
    func testDetailPhaseKeepsPermissionWhenWaitKindSaysSo() {
        let store = StatusStore()
        store.language = .en
        var row = AgentRow(rowKey: "k", agent: .claude)
        row.waiting = true
        row.waitKind = "Permission"
        row.phase = ""
        XCTAssertEqual(store.detailPhase(row), "Permission")
    }

    @MainActor
    func testReadablePhaseDoesNotSayWaitingPermissionAfterClear() {
        let store = StatusStore()
        store.language = .en
        var row = AgentRow(rowKey: "k", agent: .claude)
        row.waiting = false
        row.phase = "permission_resolved"
        let phase = store.detailPhase(row)
        XCTAssertNotEqual(phase, "Waiting for permission")
    }
}
