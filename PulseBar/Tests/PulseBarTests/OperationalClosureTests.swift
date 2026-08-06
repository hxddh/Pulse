import XCTest
@testable import PulseBar

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

    func testLaunchRecoveryMarksUncleanThenClean() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = LaunchRecovery.begin(nowMs: 10, at: url, bootID: "boot-a")
        XCTAssertFalse(first.wasUnclean)
        XCTAssertEqual(first.kind, .clean)
        let second = LaunchRecovery.begin(nowMs: 20, at: url, bootID: "boot-a")
        XCTAssertTrue(second.wasUnclean)
        XCTAssertEqual(second.kind, .crash)
        second.state.markCleanShutdown(at: url)
        let third = LaunchRecovery.begin(nowMs: 30, at: url, bootID: "boot-a")
        XCTAssertFalse(third.wasUnclean)
        XCTAssertEqual(third.kind, .clean)
    }

    func testLaunchRecoveryDistinguishesSystemRestartAndUpdateReplace() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = LaunchRecovery.begin(nowMs: 10, at: url, bootID: "boot-a")
        _ = first
        let afterReboot = LaunchRecovery.begin(nowMs: 20, at: url, bootID: "boot-b")
        XCTAssertTrue(afterReboot.wasUnclean)
        XCTAssertEqual(afterReboot.kind, .systemRestart)

        afterReboot.state.markIntendedExit(.updateReplace, at: url)
        let afterUpdate = LaunchRecovery.begin(nowMs: 30, at: url, bootID: "boot-b")
        XCTAssertFalse(afterUpdate.wasUnclean)
        XCTAssertEqual(afterUpdate.kind, .updateReplace)
    }

    func testLaunchRecoveryForceQuitMarkerSurvivesCleanShutdownHook() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = LaunchRecovery.begin(nowMs: 10, at: url, bootID: "boot-a")
        first.state.markIntendedExit(.forceQuit, at: url)
        // applicationWillTerminate still calls markCleanShutdown; intent must stick.
        first.state.markCleanShutdown(at: url)
        let second = LaunchRecovery.begin(nowMs: 20, at: url, bootID: "boot-a")
        XCTAssertTrue(second.wasUnclean)
        XCTAssertEqual(second.kind, .forceQuit)
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

    func testJSONIsDefaultAndTSVRequiresExplicitCompatibilityReader() {
        let tsv = "codex\tTask\t1\t2\ttool\t\tPulse\t/tmp\t100\t0\t0\ts\n"
        XCTAssertTrue(ActivityHarvest.parse(tsv).isEmpty)
        XCTAssertEqual(ActivityHarvest.parseLegacyTSV(tsv).count, 1)
    }

    func testUpdateReplacementKeepsRollbackCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("update-\(UUID().uuidString)")
        let target = root.appendingPathComponent("Pulse.app")
        let staged = root.appendingPathComponent("staged/Pulse.app")
        let rollback = root.appendingPathComponent("rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApp(target, version: "0.47.0", marker: "old")
        try makeApp(staged, version: "0.49.0", marker: "new")
        try UpdateInstaller.replace(stagedApp: staged, targetApp: target, backupRoot: rollback)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("Contents/MacOS/PulseBar")), "new")
        let backups = try FileManager.default.contentsOfDirectory(at: rollback, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: backups[0].appendingPathComponent("Contents/MacOS/PulseBar")), "old")
    }

    func testIncompleteUpdateRecoversBackupOnNextLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recover-\(UUID().uuidString)")
        let target = root.appendingPathComponent("Pulse.app")
        let backup = root.appendingPathComponent("rollback/Pulse-old.app")
        let stateURL = root.appendingPathComponent("rollback/current.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApp(backup, version: "0.48.0", marker: "recover-me")
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let state = UpdateInstaller.InstallTransaction(
            target: target.path,
            backup: backup.path,
            version: "0.49.0",
            phase: "replacing"
        )
        try JSONEncoder().encode(state).write(to: stateURL)
        XCTAssertTrue(UpdateInstaller.recoverIfNeeded(at: target, backupRoot: stateURL.deletingLastPathComponent()))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("Contents/MacOS/PulseBar")), "recover-me")
    }

    private func makeApp(_ app: URL, version: String, marker: String) throws {
        let fm = FileManager.default
        let contents = app.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.pulse.app</string><key>CFBundleExecutable</key><string>PulseBar</string><key>CFBundleShortVersionString</key><string>\(version)</string></dict></plist>
        """
        try plist.data(using: .utf8)!.write(to: contents.appendingPathComponent("Info.plist"))
        try marker.data(using: .utf8)!.write(to: macOS.appendingPathComponent("PulseBar"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: macOS.appendingPathComponent("PulseBar").path)
    }
}
