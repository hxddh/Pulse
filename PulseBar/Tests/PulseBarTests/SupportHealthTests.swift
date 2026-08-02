import XCTest
@testable import PulseBar

final class SupportHealthTests: XCTestCase {
    private func health(
        agent: AgentID = .codex,
        evidence: ObservationSource? = .session,
        processDetected: Bool = false,
        goal: Bool = true,
        workspace: Bool = true,
        activity: Bool = true,
        progress: Bool = false,
        waitingReady: Bool = true
    ) -> AgentSupportHealth {
        AgentSupportHealth(
            agent: agent,
            collectorState: .observed,
            collectorDurationMs: 12,
            collectorRows: 1,
            sourcePresent: true,
            collectorErrorKind: "",
            processDetected: processDetected,
            processEvidence: processDetected ? .executable : nil,
            evidence: evidence,
            lastSuccessfulReadMs: 1_700_000_000_000,
            lastWaitingSignalMs: 0,
            hasGoal: goal,
            hasWorkspace: workspace,
            hasActivity: activity,
            hasProgress: progress,
            waitingSignalReady: waitingReady
        )
    }

    func testCoreCoverageIsGoalWorkspaceActivityAndEvidence() {
        let item = health(progress: false, waitingReady: false)
        XCTAssertEqual(item.observedFactCount, 4)
        XCTAssertEqual(item.missingCapabilities, [.waitingSignal])
    }

    func testAgentWithoutWaitingContractIsNotPermanentlyIncomplete() {
        let item = health(agent: .devin, progress: true, waitingReady: false)
        XCTAssertTrue(item.missingCapabilities.isEmpty)
        XCTAssertEqual(item.usefulFactCount, 4)
        XCTAssertEqual(item.usefulFactTotal, 4)
        XCTAssertEqual(item.disposition, .healthy)
    }

    func testProcessOnlyEvidenceAdmitsMissingActivityFeed() {
        let item = health(
            evidence: .process,
            processDetected: true,
            goal: false,
            workspace: false,
            activity: false
        )
        XCTAssertEqual(
            item.missingCapabilities,
            [.activityFeed, .goal, .workspace]
        )
        XCTAssertEqual(item.disposition, .limited)
    }

    func testHealthyRequiresAllFiveUsefulSignals() {
        let item = health(progress: true, waitingReady: true)
        XCTAssertEqual(item.usefulFactCount, 5)
        XCTAssertEqual(item.disposition, .healthy)
        XCTAssertEqual(item.repair, .none)
    }

    func testTranscriptRecordCountDoesNotPretendToBeExecutionProgress() {
        let item = health(progress: false, waitingReady: true)
        XCTAssertFalse(item.hasProgress)
        XCTAssertEqual(item.usefulFactCount, 4)
    }

    func testMissingHooksIsActionable() {
        let item = health(agent: .codex, progress: true, waitingReady: false)
        XCTAssertEqual(item.disposition, .needsAction)
        XCTAssertEqual(item.repair, .installHooks)
    }

    func testAdapterFailureOffersRetry() {
        var item = health(progress: true)
        item.collectorState = .schemaMismatch
        XCTAssertEqual(item.disposition, .needsAction)
        XCTAssertEqual(item.repair, .retry)
    }

    @MainActor
    func testCursorAgentAliasDoesNotCreateDuplicateSupportEntry() {
        let store = StatusStore()
        store.installPreviewFixture("coverage")
        let agents = Set(store.supportHealth.map(\.agent))
        XCTAssertTrue(agents.contains(.cursor))
        XCTAssertFalse(agents.contains(.cursorAgent))
    }

    @MainActor
    func testObservedSupportLinePrioritizesMeaningfulFactsOverRecordCount() {
        let store = StatusStore()
        store.installPreviewFixture("coverage")
        guard let item = store.supportHealth.first(where: { $0.agent == .cursor }) else {
            return XCTFail("coverage fixture should include Cursor")
        }
        let observed = store.supportObservedDetail(item)
        XCTAssertTrue(observed.contains("Refine adapter coverage"), observed)
        XCTAssertTrue(observed.contains("Turn complete"), observed)
        XCTAssertFalse(observed.localizedCaseInsensitiveContains("events"), observed)
    }
}
