import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

final class OperationalClosureTests: XCTestCase {
    private func waitingRow(_ key: String = "codex|session-1") -> AgentRow {
        var row = AgentRow(rowKey: key, agent: .codex)
        row.sessionID = "session-1"
        row.task = "Approve test command"
        row.waiting = true
        row.waitKind = "permission"
        row.project = "Pulse"
        return row
    }

    func testAttentionLedgerPersistsQueueAcknowledgementAndRateLimit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var ledger = AttentionLedger()
        ledger.reconcile(activeRows: [waitingRow()], nowMs: 100)
        ledger.markQueued(rowKey: "codex|session-1", nowMs: 110)
        XCTAssertTrue(ledger.queuedKeys.contains("codex|session-1"))
        ledger.markNotified(rowKey: "codex|session-1", nowMs: 200)
        XCTAssertFalse(ledger.canDeliver(nowMs: 1_000, minimumIntervalMs: 3_000))
        ledger.acknowledge(rowKey: "codex|session-1", nowMs: 300)
        ledger.save(to: url)
        let restored = AttentionLedger.load(from: url)
        XCTAssertTrue(restored.isAcknowledged(rowKey: "codex|session-1"))
        XCTAssertTrue(restored.events.contains { $0.notifiedAtMs == 200 })
    }

    func testAttentionLedgerNeverEvictsActiveWaitingEvents() {
        var ledger = AttentionLedger()
        let rows = (0..<300).map { index in
            waitingRow("codex|session-\(index)")
        }
        ledger.reconcile(activeRows: rows, nowMs: 100)
        ledger.prune(nowMs: 100)

        XCTAssertEqual(ledger.activeKeys.count, 300)
        XCTAssertEqual(ledger.events.count, 300)
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
            StatusStore.isIntentionalSupervisorPartial(
                health: [healthyCodex],
                plan: plan
            )
        )

        let failedCodex = ActivityHarvest.CollectorHealth(
            id: .codex, state: .failed, durationMs: 10, rowCount: 0,
            sourcePresent: true, errorKind: "timeout"
        )
        XCTAssertFalse(
            StatusStore.isIntentionalSupervisorPartial(
                health: [failedCodex],
                plan: plan
            )
        )

        let store = StatusStore()
        store.recordCollectorHealth([healthyCodex], complete: false, intentionalPartial: true)
        XCTAssertFalse(store.collectorScanIncomplete)
        store.recordCollectorHealth([failedCodex], complete: false, intentionalPartial: false)
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
