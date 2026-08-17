import XCTest
@testable import PulseBar

/// 1.2 Substance — the facts 1.1 could compute but nobody could see.
///
/// The digest already held a tool histogram, session-wide error and token
/// totals, and the repeated-tool signal. All of it stayed in the support
/// report, because putting a fact on a tray row spends one of the four slots
/// EXPERIENCE allows. This is that spend, made deliberately.
final class LoopSignalTests: XCTestCase {

    private let now: Int64 = 1_800_000_000_000

    private func row(loop: String = "Edit", count: Int = 4) -> AgentRow {
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.task = "Fix the auth module"
        row.loopTool = loop
        row.loopCount = count
        row.liveProcess = true
        row.harvestMs = now
        return row
    }

    // MARK: - When it counts as a loop

    func testThreeInARowIsALoopAndTwoIsNot() {
        XCTAssertTrue(row(count: 3).isLooping)
        XCTAssertTrue(row(count: 9).isLooping)
        XCTAssertFalse(row(count: 2).isLooping)
        XCTAssertFalse(row(loop: "", count: 9).isLooping, "no tool name, no claim")
    }

    // MARK: - What the row says

    /// The lamp cannot express this: the agent is running and its clock is
    /// moving. Only the story line can.
    @MainActor
    func testTheStoryLineNamesTheToolAndTheRun() {
        let store = StatusStore()
        store.language = .en
        let line = store.rowStoryLine(row())
        XCTAssertTrue(line.contains("Edit"), line)
        XCTAssertTrue(line.contains("4"), line)
    }

    @MainActor
    func testChineseKeepsTheAgentNameInEnglishAndTheRestLocalised() {
        let store = StatusStore()
        store.language = .zh
        let line = store.rowStoryLine(row())
        XCTAssertTrue(line.contains("Edit"), "a vendor tool name is not translated")
        XCTAssertTrue(line.contains("4"), line)
    }

    /// Waiting outranks everything. Someone being asked a question does not
    /// need to be told the agent repeated a tool before it stopped.
    @MainActor
    func testWaitingStillOwnsTheRow() {
        let store = StatusStore()
        store.language = .en
        var waiting = row()
        waiting.waiting = true
        waiting.waitKind = "Permission"
        waiting.waitMessage = "Approve deploy?"
        XCTAssertFalse(
            store.rowStoryLine(waiting).contains("in a row"),
            "the question is the point, not how it got there"
        )
    }

    /// A remote row has no transcript here at all, so it cannot have a loop —
    /// and its own line (last heard / lost contact) must keep priority.
    @MainActor
    func testARemoteRowKeepsItsOwnStory() {
        let store = StatusStore()
        store.language = .en
        var remote = row()
        remote.host = "devbox"
        remote.observationSource = .remote
        remote.lastHeardMs = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let line = store.rowStoryLine(remote)
        XCTAssertFalse(line.contains("in a row"))
    }

    @MainActor
    func testAnOrdinaryRowIsUnaffected() {
        let store = StatusStore()
        store.language = .en
        var quiet = row(loop: "", count: 0)
        quiet.phase = "running"
        XCTAssertFalse(store.rowStoryLine(quiet).contains("in a row"))
    }

    // MARK: - The bounded tool summary

    func testToolSummaryIsOrderedByUseAndBounded() {
        let line = SessionDigestSummary.line([
            "Edit": 12, "Bash": 5, "Read": 3, "Grep": 2, "Glob": 1, "Task": 1,
        ])
        XCTAssertTrue(line.hasPrefix("Edit 12"), line)
        XCTAssertEqual(
            line.components(separatedBy: " · ").count,
            SessionDigestSummary.maxEntries,
            "Details has room for a line, not a paragraph"
        )
        XCTAssertFalse(line.contains("Glob"), "the long tail is dropped, not summarised")
    }

    func testAnEmptyHistogramProducesNothingRatherThanAPlaceholder() {
        XCTAssertEqual(SessionDigestSummary.line([:]), "")
    }

    // MARK: - Carried, never re-derived

    /// The builder copies digest facts straight through. Anything that tried to
    /// recompute them from the window would be guessing at bytes it never read.
    func testTheBuilderCarriesDigestFactsOntoTheRow() throws {
        var harvest = ActivityHarvest.Row(
            id: .claude, task: "Fix the auth module", project: "", cwd: "/Users/me/code/Pulse",
            skill: "", tool: "", harvestMs: now,
            subRunning: 0, subTotal: 0, sessionID: "s1", evidence: .session
        )
        harvest.loopTool = "Edit"
        harvest.loopCount = 5
        harvest.sessionErrors = 3
        harvest.toolSummary = "Edit 5 · Bash 2"

        let result = SnapshotBuilder.build(
            SnapshotBuilder.Input(
                procs: [], harvest: [harvest], harvestUnreliable: false, attention: []
            ),
            previous: .init(),
            context: SnapshotBuilder.Context(
                nowMs: now,
                terminal: TerminalFocus.Environment(warpRunning: false, ttyHostRunning: false),
                lang: .en
            )
        )
        let row = try XCTUnwrap(result.rows.first { $0.agent == .claude })
        XCTAssertEqual(row.loopTool, "Edit")
        XCTAssertEqual(row.loopCount, 5)
        XCTAssertEqual(row.sessionErrors, 3)
        XCTAssertEqual(row.toolSummary, "Edit 5 · Bash 2")
        XCTAssertTrue(row.isLooping)
    }
}
