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

/// The inbox watch is how a remote raise wakes Pulse at once instead of on the
/// next poll. Re-arming attention.tsv used to tear it down (U-4).
final class AttentionWatcherReArmTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        AttentionIO.pathOverride = home.appendingPathComponent("attention.tsv")
    }

    override func tearDownWithError() throws {
        AttentionIO.pathOverride = nil
        try? FileManager.default.removeItem(at: home)
    }

    func testReArmingTheFileWatchLeavesTheInboxWatchAlone() {
        let watcher = AttentionWatcher()
        defer { watcher.stop() }
        watcher.start {}
        XCTAssertTrue(watcher.isWatchingFile)
        XCTAssertTrue(watcher.isWatchingInbox)

        // What the delete/rename handler does after an atomic replace — which
        // is what every hook write looks like from the outside.
        watcher.arm()
        XCTAssertTrue(watcher.isWatchingFile)
        XCTAssertTrue(
            watcher.isWatchingInbox,
            "attention.d/ must keep waking Pulse after attention.tsv is replaced"
        )
    }

    func testReArmingTheInboxLeavesTheFileWatchAlone() {
        let watcher = AttentionWatcher()
        defer { watcher.stop() }
        watcher.start {}
        watcher.armInbox()
        XCTAssertTrue(watcher.isWatchingFile)
        XCTAssertTrue(watcher.isWatchingInbox)
    }

    /// A deleted file cannot be reopened, so the watch would have stayed dead
    /// for the life of the process.
    func testAFileThatWasDeletedIsRecreatedAndWatchedAgain() throws {
        let watcher = AttentionWatcher()
        defer { watcher.stop() }
        watcher.start {}
        let file = try XCTUnwrap(AttentionIO.pathOverride)
        try FileManager.default.removeItem(at: file)

        watcher.arm()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(watcher.isWatchingFile)
        XCTAssertTrue(watcher.isWatchingInbox)
    }

    func testStopTearsDownBothWatches() {
        let watcher = AttentionWatcher()
        watcher.start {}
        watcher.stop()
        XCTAssertFalse(watcher.isWatchingFile)
        XCTAssertFalse(watcher.isWatchingInbox)
    }
}
