import XCTest
@testable import PulseBar

final class AttentionLedgerTests: XCTestCase {
    private func row(_ key: String, agent: AgentID = .codex) -> AgentRow {
        AgentRow(
            rowKey: key,
            agent: agent,
            project: "Pulse",
            task: "Approve release",
            waiting: true,
            waitKind: "Permission"
        )
    }

    func testBaselineAndActiveWaitSurviveRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var ledger = AttentionLedger()
        ledger.reconcile(activeRows: [row("codex|1")], nowMs: 1_700_000_000_000)
        ledger.markBaseline()
        ledger.markNotified(rowKey: "codex|1", nowMs: 1_700_000_000_100)
        ledger.save(to: url)
        let loaded = AttentionLedger.load(from: url)
        XCTAssertTrue(loaded.baselineEstablished)
        XCTAssertEqual(loaded.activeKeys, ["codex|1"])
        XCTAssertEqual(loaded.events.first?.notifiedAtMs, 1_700_000_000_100)
        XCTAssertEqual(loaded.events.first?.id, "codex|1|1700000000000")
    }

    func testReconcileMarksMissingWaitResolvedAndDoesNotKeepSnooze() {
        var ledger = AttentionLedger()
        ledger.reconcile(activeRows: [row("claude|1", agent: .claude)], nowMs: 1_000)
        ledger.snooze(rowKey: "claude|1", untilMs: 9_000)
        ledger.reconcile(activeRows: [], nowMs: 2_000)
        XCTAssertTrue(ledger.activeKeys.isEmpty)
        XCTAssertEqual(ledger.recentResolved.first?.resolvedAtMs, 2_000)
        XCTAssertTrue(ledger.snoozedUntil.isEmpty)
    }

    func testClearResolvedKeepsActiveAttention() {
        var ledger = AttentionLedger()
        ledger.reconcile(activeRows: [row("codex|active")], nowMs: 1_000)
        ledger.reconcile(activeRows: [], nowMs: 2_000)
        ledger.reconcile(activeRows: [row("codex|active")], nowMs: 3_000)
        ledger.reconcile(activeRows: [], nowMs: 4_000)
        ledger.reconcile(activeRows: [row("codex|live")], nowMs: 5_000)
        ledger.clearResolved()
        XCTAssertEqual(ledger.activeKeys, ["codex|live"])
        XCTAssertTrue(ledger.recentResolved.isEmpty)
    }

    func testDuplicateActiveRecordsDoNotCrashSnoozeLookup() {
        var ledger = AttentionLedger()
        ledger.reconcile(activeRows: [row("codex|duplicate")], nowMs: 1_000)
        ledger.events.append(
            AttentionLedger.Event(
                id: "duplicate",
                rowKey: "codex|duplicate",
                agent: "codex",
                session: "duplicate",
                title: "Approve release",
                kind: "Permission",
                project: "Pulse",
                observedAtMs: 1_001,
                lastSeenAtMs: 1_001,
                snoozedUntilMs: 9_000
            )
        )
        ledger.events[0].snoozedUntilMs = 8_000

        XCTAssertEqual(
            ledger.snoozedUntil["codex|duplicate"],
            Date(timeIntervalSince1970: 9),
            "recovery must prefer the latest duplicate deadline"
        )
    }

    func testRemapRowKeyMovesActiveSnooze() {
        var ledger = AttentionLedger()
        ledger.reconcile(activeRows: [row("codex")], nowMs: 1_000)
        ledger.snooze(rowKey: "codex", untilMs: 9_000)
        ledger.remapRowKey(from: "codex", to: "codex|sess")
        XCTAssertEqual(ledger.activeKeys, ["codex|sess"])
        XCTAssertEqual(
            ledger.snoozedUntil["codex|sess"],
            Date(timeIntervalSince1970: 9)
        )
        XCTAssertNil(ledger.snoozedUntil["codex"])
    }
}
