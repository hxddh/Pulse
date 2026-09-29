import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

/// The observation line picks facts by what they carry, and never states a
/// fact nobody measured. (23.0 removed the session digest and the evidence
/// card it fed; the rules for the line that remains stay pinned here.)
final class EvidenceSurfaceTests: XCTestCase {

    @MainActor
    private func store(_ lang: AppLanguage = .en) -> StatusStore {
        let store = StatusStore()
        store.language = lang
        return store
    }

    private func liveRow() -> AgentRow {
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.task = "Fix the auth module"
        row.liveProcess = true
        row.harvestMs = Int64(Date().timeIntervalSince1970 * 1000)
        row.observationSource = .session
        return row
    }

    /// Whatever changes as work happens outranks whatever was fixed when the
    /// session opened.
    @MainActor
    func testDynamicFactsOutrankStandingOnes() {
        var row = liveRow()
        row.errors = 3                 // fault
        row.progressDone = 2
        row.progressTotal = 5          // advance
        row.tokensIn = 12_000
        row.tokensOut = 3_000          // motion
        row.contextPercent = 42        // reach
        row.model = "claude-opus"      // standing
        row.mode = "agent"             // standing

        let line = store().rowObservationLine(row)
        let parts = line.components(separatedBy: " · ")
        func at(_ needle: String) -> Int {
            parts.firstIndex { $0.contains(needle) } ?? -1
        }

        XCTAssertEqual(at("error"), 0, "a fault changes what you do next: \(line)")
        // 8.1: the work facts live on their own line, value-ordered, and
        // never compete with outcome for the budget again.
        let work = store().rowWorkLine(row)
        let workParts = work.components(separatedBy: " · ")
        func wat(_ needle: String) -> Int {
            workParts.firstIndex { $0.contains(needle) } ?? -1
        }
        XCTAssertLessThan(wat("↑"), wat("Model"), work)
        XCTAssertLessThan(wat("Model"), wat("Context"), work)
        XCTAssertFalse(line.contains("↑"), "one fact, one line: \(line)")
        XCTAssertFalse(line.contains("Model"), "one fact, one line: \(line)")
    }

    /// `EXPERIENCE.md`: a position that carries no information either gets real
    /// information or gets deleted. Zero is not a fact.
    @MainActor
    func testZeroAndUnknownFactsNeverAppear() {
        XCTAssertEqual(store().rowObservationLine(liveRow()), "", "nothing known, nothing said")

        var partial = liveRow()
        partial.tokensIn = 12_000
        let work = store().rowWorkLine(partial)
        XCTAssertTrue(work.contains("12k"), work)
        XCTAssertFalse(work.contains("Model"), "no model was reported: \(work)")
        XCTAssertFalse(work.contains("Context"), "context was never reported: \(work)")
        let line = store().rowObservationLine(partial)
        XCTAssertFalse(line.contains("events"), "zero records is not a record count: \(line)")
        XCTAssertFalse(line.contains("complete"), "zero progress is not progress: \(line)")
    }

    @MainActor
    func testAWaitingRowStillCarriesNoObservationFactsAtAll() {
        var waiting = liveRow()
        waiting.errors = 2
        waiting.waiting = true
        waiting.waitKind = "Permission"
        XCTAssertEqual(store().rowObservationLine(waiting), "", "the question is the point")
    }
}

/// 2.2 Momentum — compute is the fact that separates thinking from stopped.
final class ComputeSurfaceTests: XCTestCase {
    @MainActor
    private func liveRow() -> AgentRow {
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.liveProcess = true
        row.processCount = 1
        row.task = "Build the thing"
        return row
    }

    @MainActor
    func testUnknownComputeIsNeverRenderedAsZero() {
        let store = StatusStore()
        var row = liveRow()
        XCTAssertEqual(row.cpuPercent, -1, "no sample yet is the default")
        XCTAssertFalse(row.hasCPUSample)
        XCTAssertEqual(store.evidenceCPU(row), "—", "unknown must not read as 0%")

        row.cpuPercent = 0
        XCTAssertTrue(row.hasCPUSample, "measured idle is an answer")
        XCTAssertNotEqual(store.evidenceCPU(row), "—")
    }

    @MainActor
    func testTheNoteSaysWhyComputeIsMissing() {
        let store = StatusStore()
        var row = liveRow()
        let unknown = store.evidenceCPUNote(row)
        row.cpuPercent = 42
        XCTAssertNotEqual(store.evidenceCPUNote(row), unknown, "two states, two sentences")
        XCTAssertFalse(unknown.isEmpty)
    }

    @MainActor
    func testAnIdleOrUnsampledProcessSpendsNoSlotOnCPU() {
        let store = StatusStore()
        var row = liveRow()
        XCTAssertFalse(store.rowObservationLine(row).contains("CPU"), "unknown says nothing")
        row.cpuPercent = 3
        XCTAssertFalse(store.rowObservationLine(row).contains("CPU"), "idle is not worth a slot")
    }

    @MainActor
    func testMemoryDisappearsRatherThanShowingZero() {
        let store = StatusStore()
        var row = liveRow()
        XCTAssertNil(store.evidenceMemory(row))
        row.rssBytes = 512 * 1024 * 1024
        XCTAssertNotNil(store.evidenceMemory(row))
    }

    @MainActor
    func testAStalledSessionThatIsBusySaysSo() {
        let store = StatusStore()
        var row = liveRow()
        row.isStalled = true
        row.harvestMs = 1
        let quiet = store.rowStoryLine(row)
        row.cpuPercent = 200
        let busy = store.rowStoryLine(row)
        XCTAssertNotEqual(quiet, busy, "a pinned process is not the same story as a dead one")
    }
}

/// A workspace the disk could not confirm must not be offered as a landing.
final class BestEffortWorkspaceTests: XCTestCase {
    @MainActor
    func testAnUnverifiedWorkspaceDropsToAppPrecision() {
        let env = TerminalFocus.Environment(
            warpRunning: true,
            ttyHostRunning: true,
            allowTTYAutomation: true
        )
        let verified = TerminalFocus.focusTier(
            tty: "", viaWarp: false, hostApp: .cursor,
            workspace: "/Users/me/my-project", workspaceVerified: true, env: env
        )
        let guessed = TerminalFocus.focusTier(
            tty: "", viaWarp: false, hostApp: .cursor,
            workspace: "/Users/me/my/project", workspaceVerified: false, env: env
        )
        if case .hostWorkspace = verified {} else {
            XCTFail("a confirmed path still lands on the workspace: \(String(describing: verified))")
        }
        if case .hostApp = guessed {} else {
            XCTFail("an unconfirmed decode must not open a folder: \(String(describing: guessed))")
        }
    }
}
