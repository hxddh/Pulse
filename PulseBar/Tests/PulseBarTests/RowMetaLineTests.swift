import XCTest
@testable import PulseBar

/// 10.0 (scene BS) — the collapsed row's ONE composed meta line: three
/// slots by value (now > outcome > way), project as filler, waiting rows
/// keep the question line instead. The five line accessors it replaces in
/// the collapsed row stay pinned by their own suites and render on the
/// expanded card.
final class RowMetaLineTests: XCTestCase {

    @MainActor
    private func store() -> StatusStore {
        let store = StatusStore()
        store.language = .en
        return store
    }

    private func liveRow() -> AgentRow {
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.task = "Fix the auth module"
        row.project = "Pulse"
        row.liveProcess = true
        row.harvestMs = Int64(Date().timeIntervalSince1970 * 1000)
        row.observationSource = .session
        return row
    }

    @MainActor
    func testAWaitingRowYieldsToItsQuestionLine() {
        var row = liveRow()
        row.waiting = true
        row.sessionErrors = 3
        XCTAssertEqual(store().rowMetaLine(row), "")
    }

    @MainActor
    func testTheNowSlotLeadsWithTheFreshActionAndTarget() {
        var row = liveRow()
        row.tool = "Edit"
        row.liveTool = "Edit"
        row.liveTarget = "/Users/me/Pulse/Sources/Main.swift"
        row.liveAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        row.sessionErrors = 2
        let line = store().rowMetaLine(row)
        let segments = line.components(separatedBy: " · ")
        XCTAssertTrue(line.contains("Edit"), line)
        XCTAssertTrue(line.contains("Main.swift"), line)
        XCTAssertTrue(segments.count >= 2, "outcome joins the now slot: \(line)")
        XCTAssertTrue(line.contains("2"), "the strongest outcome fact rides along: \(line)")
    }

    @MainActor
    func testLoopingOutranksTheFreshAction() {
        var row = liveRow()
        row.loopTool = "Bash"
        row.loopCount = 6
        row.liveTool = "Edit"
        row.liveAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        let line = store().rowMetaLine(row)
        XCTAssertTrue(line.contains("Bash"), "a loop is the more urgent story: \(line)")
    }

    @MainActor
    func testThreeSlotsAtMost() {
        var row = liveRow()
        row.liveTool = "Edit"
        row.tool = "Edit"
        row.liveAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        row.sessionErrors = 1
        row.changedPaths = 3
        row.insertions = 5
        row.deletions = 1
        row.tokensIn = 12_000
        row.tokensOut = 3_000
        row.model = "claude-opus"
        row.contextPercent = 40
        let line = store().rowMetaLine(row)
        // The now slot itself may carry a "Now · tool · target" phrase, so
        // count slots by the facts they lead with, bounded by construction.
        XCTAssertFalse(line.isEmpty)
        XCTAssertLessThanOrEqual(
            line.components(separatedBy: " · ").count, 5,
            "three value slots, never a stacked enumeration: \(line)"
        )
    }

    @MainActor
    func testASparseRowFallsBackToTheProject() {
        let row = liveRow()
        let line = store().rowMetaLine(row)
        XCTAssertTrue(line.contains("Pulse"), "place is the honest filler: \(line)")
    }

    @MainActor
    func testAProcessOnlyRowKeepsItsDetectionSentence() {
        var row = AgentRow(rowKey: "warp|p1", agent: .warpAgent)
        row.liveProcess = true
        row.cwd = "/Users/me/Client"
        row.observationSource = .process
        row.refreshObservationQuality()
        XCTAssertTrue(row.isProcessOnly, "fixture must be a process-only row")
        let line = store().rowMetaLine(row)
        XCTAssertEqual(line, store().rowContextLine(row))
    }
}
