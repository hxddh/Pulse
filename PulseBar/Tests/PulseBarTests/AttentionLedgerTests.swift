import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

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

    func testReconcileMarksMissingWaitResolved() {
        var ledger = AttentionLedger()
        ledger.reconcile(activeRows: [row("claude|1", agent: .claude)], nowMs: 1_000)
        ledger.reconcile(activeRows: [], nowMs: 2_000)
        XCTAssertTrue(ledger.activeKeys.isEmpty)
        XCTAssertEqual(ledger.latestEvent(rowKey: "claude|1")?.resolvedAtMs, 2_000)
    }

    func testRemapRowKeyMovesTheActiveEvent() {
        var ledger = AttentionLedger()
        ledger.reconcile(activeRows: [row("codex")], nowMs: 1_000)
        ledger.remapRowKey(from: "codex", to: "codex|sess")
        XCTAssertEqual(ledger.activeKeys, ["codex|sess"])
        XCTAssertNil(ledger.eventID(for: "codex"))
    }
}

/// Re-arming attention.tsv used to tear down every other watch with it
/// (U-4). Since 22.0 removed the remote inbox the other watch is the
/// activity spool, and the rule is the same: each watch re-arms alone.
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

    func testReArmingTheFileWatchLeavesTheActivityWatchAlone() {
        let watcher = AttentionWatcher()
        defer { watcher.stop() }
        watcher.start(onChange: {}, onActivity: {})
        XCTAssertTrue(watcher.isWatchingFile)
        XCTAssertTrue(watcher.isWatchingActivity)

        // What the delete/rename handler does after an atomic replace — which
        // is what every hook write looks like from the outside.
        watcher.arm()
        XCTAssertTrue(watcher.isWatchingFile)
        XCTAssertTrue(
            watcher.isWatchingActivity,
            "activity.d/ must keep waking Pulse after attention.tsv is replaced"
        )
    }

    func testReArmingTheActivityWatchLeavesTheFileWatchAlone() {
        let watcher = AttentionWatcher()
        defer { watcher.stop() }
        watcher.start(onChange: {}, onActivity: {})
        watcher.armActivity()
        XCTAssertTrue(watcher.isWatchingFile)
        XCTAssertTrue(watcher.isWatchingActivity)
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
    }

    func testStopTearsDownEveryWatch() {
        let watcher = AttentionWatcher()
        watcher.start(onChange: {}, onActivity: {})
        watcher.stop()
        XCTAssertFalse(watcher.isWatchingFile)
        XCTAssertFalse(watcher.isWatchingActivity)
    }
}
