import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

final class OperationalClosureTests: XCTestCase {
    private func waitingRow(_ key: String = "codex|session-1") -> AgentRow {
        var row = AgentRow(rowKey: key, agent: .codex)
        row.sessionID = "session-1"
        row.task = "Approve test command"
        row.state = .blocked(RowWait(kind: "permission", signal: .hooks))
        row.project = "Pulse"
        return row
    }

    func testSessionLogPersistsQueueDismissalAndRateLimit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("session-log-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var log = SessionLog()
        log.reconcileWaits(rows: [waitingRow()], released: [], nowMs: 100)
        log.markQueued("codex|session-1", nowMs: 110)
        XCTAssertTrue(log.queuedKeys.contains("codex|session-1"))
        log.markNotified("codex|session-1", nowMs: 200)
        XCTAssertFalse(log.queuedKeys.contains("codex|session-1"), "a shown banner is no longer owed")
        XCTAssertFalse(log.canDeliver(nowMs: 1_000, minimumIntervalMs: 3_000))
        log.dismiss(waitingRow(), soft: false, nowMs: 300)
        SessionLogFile.save(log, to: url, nowMs: 400)
        let restored = SessionLogFile.load(from: url, nowMs: 500)
        XCTAssertTrue(restored.dismissedKeys.contains("codex|session-1"))
        XCTAssertEqual(restored.openWait("codex|session-1")?.notifiedMs, 200)
        XCTAssertEqual(restored.openWait("codex|session-1")?.queuedMs, 110, "the audit keeps when it was queued")
    }

    func testSessionLogNeverEvictsOpenWaits() {
        var log = SessionLog()
        let rows = (0..<300).map { index in
            waitingRow("codex|session-\(index)")
        }
        log.reconcileWaits(rows: rows, released: [], nowMs: 100)
        log.prune(nowMs: 100)

        XCTAssertEqual(log.waitingKeys.count, 300, "a live wait is product state, not history")
    }

    func testSupervisorBacksOffOnlyFailedAdapterAndRecovers() {
        var supervisor = HarvestSupervisor()
        let now: Int64 = 1_000
        let failed = ActivityHarvest.CollectorHealth(
            id: .cursor, state: .failed, durationMs: 6_000, rowCount: 0,
            sourcePresent: true, errorKind: "timeout"
        )
        supervisor.record([failed], nowMs: now)
        let plan = supervisor.plan(nowMs: now + 100, agents: [.cursor, .codex])
        XCTAssertFalse(plan.attempted.contains(.cursor))
        XCTAssertTrue(plan.attempted.contains(.codex))
        XCTAssertTrue(plan.deferred.contains(.cursor))
        supervisor.record([.init(id: .cursor, state: .observed, durationMs: 1, rowCount: 1, sourcePresent: true, errorKind: "")], nowMs: now + 2_000)
        XCTAssertEqual(supervisor.state(for: .cursor).consecutiveFailures, 0)
        XCTAssertTrue(supervisor.plan(nowMs: now + 2_001, agents: [.cursor]).attempted.contains(.cursor))
    }

    func testSupervisorOpensCircuitAfterThreeFailuresAndAllowsHalfOpenProbe() {
        var supervisor = HarvestSupervisor()
        let failed = ActivityHarvest.CollectorHealth(
            id: .amp, state: .failed, durationMs: 10, rowCount: 0,
            sourcePresent: true, errorKind: "locked"
        )
        for index in 0..<3 { supervisor.record([failed], nowMs: Int64(index * 10_000)) }
        let blocked = supervisor.plan(nowMs: 30_001, agents: [.amp, .codex])
        XCTAssertTrue(blocked.deferred.contains(.amp))
        XCTAssertTrue(blocked.attempted.contains(.codex))
        let probe = supervisor.plan(nowMs: 60_001, agents: [.amp])
        XCTAssertTrue(probe.attempted.contains(.amp))
    }

    @MainActor
    func testSupervisorDeferralDoesNotMakeHealthyPartialScanUnreliable() {
        var supervisor = HarvestSupervisor()
        let failure = ActivityHarvest.CollectorHealth(
            id: .amp, state: .failed, durationMs: 10, rowCount: 0,
            sourcePresent: true, errorKind: "locked"
        )
        supervisor.record([failure], nowMs: 1_000)
        let plan = supervisor.plan(nowMs: 1_100, agents: [.amp, .codex])
        let healthyCodex = ActivityHarvest.CollectorHealth(
            id: .codex, state: .observed, durationMs: 10, rowCount: 1,
            sourcePresent: true, errorKind: ""
        )

        XCTAssertTrue(
            ScanEngine.isIntentionalSupervisorPartial(
                health: [healthyCodex],
                plan: plan
            )
        )

        let failedCodex = ActivityHarvest.CollectorHealth(
            id: .codex, state: .failed, durationMs: 10, rowCount: 0,
            sourcePresent: true, errorKind: "timeout"
        )
        XCTAssertFalse(
            ScanEngine.isIntentionalSupervisorPartial(
                health: [failedCodex],
                plan: plan
            )
        )

        let store = StatusStore()
        store.engine.recordCollectorHealth([healthyCodex], complete: false, intentionalPartial: true)
        XCTAssertFalse(store.collectorScanIncomplete)
        store.engine.recordCollectorHealth([failedCodex], complete: false, intentionalPartial: false)
        XCTAssertTrue(store.collectorScanIncomplete)
    }

    func testSupervisorFailureTimelineOrdersNewestFirst() {
        var supervisor = HarvestSupervisor()
        let now: Int64 = 100_000
        supervisor.record(
            [
                .init(
                    id: .codex,
                    state: .failed,
                    durationMs: 10,
                    rowCount: 0,
                    sourcePresent: true,
                    errorKind: "locked"
                )
            ],
            nowMs: now
        )
        supervisor.record(
            [
                .init(
                    id: .claude,
                    state: .failed,
                    durationMs: 10,
                    rowCount: 0,
                    sourcePresent: true,
                    errorKind: "native_timeout"
                )
            ],
            nowMs: now + 5_000
        )
        let timeline = supervisor.failureTimeline(nowMs: now + 6_000)
        XCTAssertEqual(timeline.map(\.agent), [.claude, .codex])
        XCTAssertEqual(timeline.map(\.error), ["native_timeout", "locked"])
    }
}
