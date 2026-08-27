import XCTest
@testable import PulseBar

/// 8.0-α/β (scenes BN/BO) — the value engine and the inbox mapping.
///
/// The engine's one promise: the observation budget decides which line a
/// fact lives on, never whether it exists. The inbox mapping's one promise:
/// a managed turn blocked on a permission ask is a waiting row, with the ask
/// itself as the message.
final class RowValueEngineTests: XCTestCase {

    // MARK: - The pure split

    func testObservationIsTheHistoricalPrefix() {
        let split = RowValueEngine.split(
            outcome: ["e1", "a1"], work: ["m1", "r1", "s1"], volume: ["v1"],
            leadingWork: [], budget: 4
        )
        XCTAssertEqual(split.observation, ["e1", "a1", "m1", "r1"])
        XCTAssertEqual(split.work, ["s1"])
    }

    func testTheBudgetMovesFactsInsteadOfDeletingThem() {
        let work = ["↑12k ↓3k", "context 62%", "Model Claude", "Workflow test"]
        let split = RowValueEngine.split(
            outcome: ["2 errors", "3 files", "+10 −2", "2 of 5"],
            work: work, volume: [], leadingWork: [], budget: 4
        )
        XCTAssertEqual(split.observation.count, 4)
        XCTAssertEqual(split.work, work, "every displaced work fact survives")
    }

    func testEveryWorkFactAppearsOnExactlyOneLine() {
        let work = ["a", "b", "c"]
        let split = RowValueEngine.split(
            outcome: ["o"], work: work, volume: [], leadingWork: [], budget: 2
        )
        for fact in work {
            XCTAssertTrue(
                split.observation.contains(fact) != split.work.contains(fact),
                fact
            )
        }
    }

    func testLeadingWorkLeadsAndNeverEntersObservation() {
        let split = RowValueEngine.split(
            outcome: [], work: ["tokens"], volume: [],
            leadingWork: ["Editing"], budget: 6
        )
        XCTAssertEqual(split.observation, ["tokens"])
        XCTAssertEqual(split.work, ["Editing"], "a shown work fact is not repeated")
    }

    func testZeroBudgetSendsAllWorkFactsToTheWorkLine() {
        let split = RowValueEngine.split(
            outcome: ["o"], work: ["w"], volume: [], leadingWork: [], budget: 0
        )
        XCTAssertEqual(split.observation, [])
        XCTAssertEqual(split.work, ["w"])
    }

    // MARK: - The lines on a real store

    @MainActor
    private func store() -> StatusStore {
        let store = StatusStore()
        store.language = .en
        return store
    }

    private func loadedRow() -> AgentRow {
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.task = "Fix the auth module"
        row.liveProcess = true
        row.harvestMs = Int64(Date().timeIntervalSince1970 * 1000)
        row.observationSource = .session
        row.sessionErrors = 2
        row.changedPaths = 3
        row.insertions = 10
        row.deletions = 2
        row.subTotal = 2
        row.progressDone = 2
        row.progressTotal = 5
        row.tokensIn = 12_000
        row.tokensOut = 3_000
        row.contextPercent = 62
        row.model = "claude-opus"
        return row
    }

    @MainActor
    func testTheWorkLineCarriesWhatTheBudgetDisplaced() {
        let s = store()
        let row = loadedRow()
        let observation = s.rowObservationLine(row)
        let work = s.rowWorkLine(row)
        XCTAssertFalse(observation.isEmpty)
        XCTAssertFalse(
            work.isEmpty,
            "a row this loaded overflows the budget — the overflow must not die"
        )
        let shown = Set(observation.components(separatedBy: " · "))
        for segment in work.components(separatedBy: " · ") {
            XCTAssertFalse(shown.contains(segment), "\(segment) said twice")
        }
    }

    @MainActor
    func testASmallRowPutsEverythingOnTheObservationLine() {
        let s = store()
        var row = AgentRow(rowKey: "claude|s2", agent: .claude)
        row.task = "T"
        row.liveProcess = true
        row.observationSource = .session
        row.tokensOut = 4_200
        XCTAssertTrue(s.rowObservationLine(row).contains("4.2k"))
        XCTAssertEqual(s.rowWorkLine(row), "", "nothing displaced, nothing to say")
    }

    @MainActor
    func testAWaitingRowKeepsBothLinesEmpty() {
        let s = store()
        var row = loadedRow()
        row.waiting = true
        XCTAssertEqual(s.rowObservationLine(row), "")
        XCTAssertEqual(s.rowWorkLine(row), "")
    }

    @MainActor
    func testWorkDetailFactsLabelTheCollectedLayer() {
        let s = store()
        var row = loadedRow()
        row.skill = "product-design:audit"
        row.sessionTokensIn = 30_000
        row.sessionTokensOut = 9_000
        let facts = s.workDetailFacts(row)
        XCTAssertTrue(facts.contains { $0.contains("product-design:audit") }, "\(facts)")
        XCTAssertTrue(facts.contains { $0.contains("30k") }, "\(facts)")
        XCTAssertTrue(facts.contains { $0.contains("62") }, "\(facts)")
    }

    @MainActor
    func testWorkDetailAbsentFactsAreAbsent() {
        let s = store()
        var row = AgentRow(rowKey: "claude|s3", agent: .claude)
        row.observationSource = .session
        XCTAssertTrue(s.workDetailFacts(row).isEmpty)
    }

    // MARK: - The inbox mapping (scene BO)

    private func managedModel() -> ManagedSession.Model {
        ManagedSession.Model(
            id: "m1", task: "t", root: "/tmp/x", isWorktree: false, nowMs: 1_000
        )
    }

    func testAPermissionAskMakesTheManagedRowWait() {
        let ask = ManagedPermission.Request(
            id: "r1", managedID: "m1", toolName: "Bash",
            inputJSON: #"{"command":"npm run build"}"#,
            truncated: false, createdMs: 999
        )
        let row = ManagedSessionSource.row(for: managedModel(), permissionAsk: ask)
        XCTAssertTrue(row.waiting)
        XCTAssertEqual(row.waitKind, "permission")
        XCTAssertTrue(row.waitMessage.contains("Bash"), row.waitMessage)
        XCTAssertTrue(row.waitMessage.contains("npm run build"), row.waitMessage)
        XCTAssertEqual(row.waitSinceMs, 999)
    }

    func testNoAskMeansNoWaiting() {
        XCTAssertFalse(ManagedSessionSource.row(for: managedModel()).waiting)
    }

    // MARK: - The ask summary

    func testSummarySaysTheRequestedThingItself() {
        let line = ManagedPermission.summary(
            toolName: "Bash", inputJSON: #"{"command":"npm run build"}"#
        )
        XCTAssertTrue(line.contains("Bash"), line)
        XCTAssertTrue(line.contains("npm run build"), line)
    }

    func testSummaryFieldOrderFollowsTheVendorTitles() {
        let line = ManagedPermission.summary(
            toolName: "Edit",
            inputJSON: #"{"file_path":"/a/b.swift","command":"x"}"#
        )
        XCTAssertTrue(line.contains("x"), "command outranks file_path: \(line)")
    }

    func testSummaryFallsBackToTheFilePath() {
        let line = ManagedPermission.summary(
            toolName: "Edit", inputJSON: #"{"file_path":"/a/b.swift"}"#
        )
        XCTAssertTrue(line.contains("b.swift"), line)
    }

    func testSummaryOnUnparsableInputIsTheToolNameAlone() {
        XCTAssertEqual(ManagedPermission.summary(toolName: "Bash", inputJSON: "not json"), "Bash")
        XCTAssertEqual(ManagedPermission.summary(toolName: "", inputJSON: "{}"), "tool")
    }

    func testSummaryFlattensNewlines() {
        let line = ManagedPermission.summary(
            toolName: "Bash", inputJSON: #"{"command":"a\nb"}"#
        )
        XCTAssertFalse(line.contains("\n"), line)
    }
}
