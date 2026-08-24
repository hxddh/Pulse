import XCTest
@testable import PulseBar

/// 2.6 Effect — what actually changed on disk.
///
/// Every other fact Pulse has is the agent's account of itself or the bare
/// existence of a process. This is the first one neither the vendor nor the
/// agent gets to author, and the first that needs no adapter: a working copy
/// belongs to nobody in particular.
final class WorkspaceEffectTests: XCTestCase {

    private let now: Int64 = 1_800_000_000_000

    override func tearDown() {
        WorkspaceEffect.runner = { directory, command in
            ProcessIO.run(
                executable: WorkspaceEffect.executable,
                arguments: WorkspaceEffect.arguments(for: command, in: directory),
                environment: WorkspaceEffect.environment(),
                timeout: WorkspaceEffect.timeout,
                outputLimit: WorkspaceEffect.outputLimit
            )
        }
        super.tearDown()
    }

    private func ok(_ text: String) -> ProcessIO.Result {
        ProcessIO.Result(stdout: Data(text.utf8), stderr: Data(), status: 0, timedOut: false)
    }
    private let failed = ProcessIO.Result(
        stdout: Data(), stderr: Data("not a git repository".utf8), status: 128, timedOut: false
    )

    // MARK: - Parsing what git actually prints

    func testTheFullShortstatLine() {
        let parsed = WorkspaceEffect.parseShortstat(" 7 files changed, 142 insertions(+), 38 deletions(-)")
        XCTAssertEqual(parsed?.files, 7)
        XCTAssertEqual(parsed?.insertions, 142)
        XCTAssertEqual(parsed?.deletions, 38)
    }

    func testEveryClauseAfterTheFirstIsOptional() {
        // A pure addition, a pure deletion, and a mode-only change all print
        // a shortstat missing one or both counts. An absent clause is 0 for
        // that clause: the line is git's complete statement about the diff.
        XCTAssertEqual(WorkspaceEffect.parseShortstat(" 1 file changed, 9 insertions(+)")?.deletions, 0)
        XCTAssertEqual(WorkspaceEffect.parseShortstat(" 1 file changed, 9 deletions(-)")?.insertions, 0)
        let modeOnly = WorkspaceEffect.parseShortstat(" 2 files changed")
        XCTAssertEqual(modeOnly?.files, 2)
        XCTAssertEqual(modeOnly?.insertions, 0)
        XCTAssertEqual(modeOnly?.deletions, 0)
    }

    func testSingularAndPluralBothParse() {
        XCTAssertEqual(WorkspaceEffect.parseShortstat(" 1 file changed, 1 insertion(+), 1 deletion(-)")?.insertions, 1)
    }

    func testNothingUsableIsNil() {
        XCTAssertNil(WorkspaceEffect.parseShortstat(""))
        XCTAssertNil(WorkspaceEffect.parseShortstat("fatal: not a git repository"))
    }

    func testPorcelainCountsEveryChangedPathIncludingNewFiles() {
        let out = " M src/main.swift\nA  src/added.swift\n?? notes.md\n"
        XCTAssertEqual(WorkspaceEffect.parsePorcelainCount(out), 3, "a new file is work too")
        XCTAssertEqual(WorkspaceEffect.parsePorcelainCount(""), 0)
        XCTAssertEqual(WorkspaceEffect.parsePorcelainCount("\n\n"), 0)
    }

    func testOnlyAnAbsolutePathIsARoot() {
        XCTAssertEqual(WorkspaceEffect.parseToplevel("/Users/me/repo\n"), "/Users/me/repo")
        XCTAssertNil(WorkspaceEffect.parseToplevel("fatal: not a git repository"))
        XCTAssertNil(WorkspaceEffect.parseToplevel("/"))
        XCTAssertNil(WorkspaceEffect.parseToplevel(""))
    }

    // MARK: - Measuring

    func testAMeasuredCleanRepositoryIsZeroNotUnknown() {
        // The distinction this whole axis exists for: "measured, and nothing
        // has landed" is the fact; "not measured" must never wear its clothes.
        WorkspaceEffect.runner = { [ok] _, arguments in
            arguments.first == "status" ? ok("") : ok(" 0 files changed")
        }
        let measurement = WorkspaceEffect.measure(root: "/repo", nowMs: now)
        XCTAssertTrue(measurement.isKnown)
        XCTAssertTrue(measurement.nothingLanded)
        XCTAssertEqual(measurement.insertions, 0)
    }

    func testARepositoryThatCannotAnswerIsUnknown() {
        WorkspaceEffect.runner = { [failed] _, _ in failed }
        let measurement = WorkspaceEffect.measure(root: "/repo", nowMs: now)
        XCTAssertFalse(measurement.isKnown)
        XCTAssertEqual(measurement.changedPaths, -1, "-1, never 0")
    }

    func testATimeoutIsUnknownRatherThanEmpty() {
        WorkspaceEffect.runner = { _, _ in
            ProcessIO.Result(stdout: Data(), stderr: Data(), status: -1, timedOut: true)
        }
        XCTAssertFalse(WorkspaceEffect.measure(root: "/repo", nowMs: now).isKnown)
    }

    func testUntrackedOnlyWorkStillCounts() {
        // Brand-new files have changed paths and no diff against HEAD. That
        // is not a failure, and the line counts stay unknown rather than 0.
        WorkspaceEffect.runner = { [ok, failed] _, arguments in
            arguments.first == "status" ? ok("?? new.swift\n?? other.swift\n") : failed
        }
        let measurement = WorkspaceEffect.measure(root: "/repo", nowMs: now)
        XCTAssertEqual(measurement.changedPaths, 2)
        XCTAssertEqual(measurement.insertions, -1, "no diff against HEAD is not zero lines")
    }

    func testEveryCommandRefusesToTouchTheIndex() {
        // `git status` refreshes and writes back the index stat cache unless
        // told not to — that would break the read-only rule and contend for
        // index.lock with the user's own git. The flag is not decoration, so
        // the argv construction every invocation goes through is asserted
        // rather than described.
        var commands: [[String]] = []
        WorkspaceEffect.runner = { [ok] _, command in
            commands.append(command)
            return ok("")
        }
        _ = WorkspaceEffect.measure(root: "/repo", nowMs: now)
        _ = WorkspaceEffect.repositoryRoot(of: "/repo")
        XCTAssertFalse(commands.isEmpty)
        for command in commands {
            let argv = WorkspaceEffect.arguments(for: command, in: "/repo")
            XCTAssertEqual(argv.first, "--no-optional-locks", "\(argv)")
            XCTAssertEqual(argv[1], "-C")
        }
        // The flag alone was NOT enough: the first real-machine run caught
        // `git diff` rewriting the index despite it. The environment variable
        // is the half that covers diff, so it is asserted, not assumed.
        XCTAssertEqual(WorkspaceEffect.environment()["GIT_OPTIONAL_LOCKS"], "0")
        XCTAssertNotNil(
            WorkspaceEffect.environment()["PATH"],
            "the parent environment is inherited, not replaced"
        )
    }

    func testOnlyReadingCommandsAreEverRun() {
        // The read-only rule, stated as a set. Anything that could mutate a
        // repository — add, stash, checkout, commit — must never appear.
        var commands: [[String]] = []
        WorkspaceEffect.runner = { [ok] _, command in
            commands.append(command)
            return ok("")
        }
        _ = WorkspaceEffect.measure(root: "/repo", nowMs: now)
        _ = WorkspaceEffect.repositoryRoot(of: "/repo")
        // `diff` is deliberately absent: the porcelain command rewrites the
        // index on a stale stat cache and nothing in the optional-locks
        // machinery stops it — RealGitTests caught it on the first real run.
        // The plumbing `diff-index` prints the same shortstat and never
        // refreshes.
        let allowed: Set<String> = ["status", "diff-index", "rev-parse"]
        for command in commands {
            XCTAssertTrue(allowed.contains(command.first ?? ""), "\(command)")
        }
    }

    // MARK: - Who else is standing in this working copy

    private func liveRow(_ key: String, root: String, remote: Bool = false) -> AgentRow {
        var row = AgentRow(rowKey: key, agent: .claude)
        row.liveProcess = true
        row.workspaceRoot = root
        if remote { row.host = "devbox" }
        return row
    }

    func testTwoAgentsInOneCheckoutAreACollision() {
        let counts = WorkspaceEffect.collisionCounts([
            liveRow("a", root: "/repo"),
            liveRow("b", root: "/repo"),
            liveRow("c", root: "/other"),
        ])
        XCTAssertEqual(counts["/repo"], 2)
        XCTAssertNil(counts["/other"], "one agent alone is not a collision")
    }

    func testARemoteRowNeverCollides() {
        // Its path describes another machine's disk; a collision there would
        // be pure invention.
        let counts = WorkspaceEffect.collisionCounts([
            liveRow("a", root: "/repo"),
            liveRow("b", root: "/repo", remote: true),
        ])
        XCTAssertTrue(counts.isEmpty)
    }

    func testAFinishedSessionDoesNotCollide() {
        var done = liveRow("b", root: "/repo")
        done.liveProcess = false
        XCTAssertTrue(
            WorkspaceEffect.collisionCounts([liveRow("a", root: "/repo"), done]).isEmpty
        )
    }

    // MARK: - Cadence, dedup and the slow-repository circuit

    func testAFreshMeasurementIsNotTakenAgain() {
        var store = WorkspaceEffectStore()
        store.record(
            WorkspaceEffect.Measurement(root: "/repo", changedPaths: 3, measuredAtMs: now),
            tookMs: 10,
            nowMs: now
        )
        XCTAssertTrue(store.due(roots: ["/repo"], nowMs: now + 1_000).isEmpty)
        XCTAssertEqual(
            store.due(roots: ["/repo"], nowMs: now + WorkspaceEffectStore.freshnessMs),
            ["/repo"]
        )
    }

    func testOnlySoManyRootsPerTick() {
        let store = WorkspaceEffectStore()
        let roots = (0..<20).map { "/repo\($0)" }
        XCTAssertEqual(
            store.due(roots: roots, nowMs: now).count,
            WorkspaceEffectStore.maxRootsPerTick,
            "a dozen agents must not turn one scan into two dozen forks"
        )
    }

    func testASlowRepositoryIsPutDownForAWhile() {
        var store = WorkspaceEffectStore()
        store.record(
            WorkspaceEffect.Measurement(root: "/monorepo", changedPaths: 4, measuredAtMs: now),
            tookMs: WorkspaceEffect.slowMeasurementMs,
            nowMs: now
        )
        XCTAssertTrue(store.isInBackoff("/monorepo", nowMs: now + 1_000))
        XCTAssertTrue(store.due(roots: ["/monorepo"], nowMs: now + 60_000).isEmpty)
        XCTAssertFalse(
            store.isInBackoff("/monorepo", nowMs: now + WorkspaceEffect.backoffMs + 1),
            "the penalty expires; a repository is not condemned for ever"
        )
    }

    func testASlowAnswerIsStillRecorded() {
        // Dropping it would report unknown for something that was measured.
        var store = WorkspaceEffectStore()
        store.record(
            WorkspaceEffect.Measurement(root: "/monorepo", changedPaths: 4, measuredAtMs: now),
            tookMs: WorkspaceEffect.slowMeasurementMs,
            nowMs: now
        )
        XCTAssertEqual(store.measurement(for: "/monorepo")?.changedPaths, 4)
    }

    func testOneWorkingCopyIsMeasuredOnceHoweverManyRowsShareIt() {
        var statusCalls = 0
        WorkspaceEffect.runner = { [ok] _, arguments in
            if arguments.first == "rev-parse" { return ok("/repo\n") }
            if arguments.first == "status" { statusCalls += 1 }
            return ok("")
        }
        var store = WorkspaceEffectStore()
        let table = store.refresh(
            directories: ["/repo", "/repo/sub", "/repo/deeper/still"],
            nowMs: now
        )
        XCTAssertEqual(statusCalls, 1, "three rows, one working copy, one measurement")
        XCTAssertEqual(table.count, 3, "and every directory still gets an answer")
        XCTAssertEqual(table["/repo/sub"]?.root, "/repo")
    }

    func testANonRepositoryIsRememberedSoItIsNotAskedEveryScan() {
        var revParseCalls = 0
        WorkspaceEffect.runner = { [failed] _, arguments in
            if arguments.first == "rev-parse" { revParseCalls += 1 }
            return failed
        }
        var store = WorkspaceEffectStore()
        _ = store.refresh(directories: ["/plain/folder"], nowMs: now)
        _ = store.refresh(directories: ["/plain/folder"], nowMs: now + 60_000)
        XCTAssertEqual(revParseCalls, 1, "a folder does not become a repository")
    }

    // MARK: 2.7 audit — a commit is something landing (G-1)

    func testAMovedHeadIsRememberedForTheCommitWindow() {
        var store = WorkspaceEffectStore()
        store.record(
            WorkspaceEffect.Measurement(
                root: "/repo", changedPaths: 3, measuredAtMs: now,
                head: String(repeating: "a", count: 40)
            ),
            tookMs: 5, nowMs: now
        )
        let later = now + WorkspaceEffectStore.freshnessMs
        store.record(
            WorkspaceEffect.Measurement(
                root: "/repo", changedPaths: 0, measuredAtMs: later,
                head: String(repeating: "b", count: 40)
            ),
            tookMs: 5, nowMs: later
        )
        XCTAssertTrue(store.headMovedRecently(root: "/repo", nowMs: later))
        XCTAssertTrue(
            store.headMovedRecently(
                root: "/repo", nowMs: later + WorkspaceEffect.recentCommitWindowMs - 1
            ),
            "a commit counts as landing for the whole window, not one tick"
        )
        XCTAssertFalse(
            store.headMovedRecently(
                root: "/repo", nowMs: later + WorkspaceEffect.recentCommitWindowMs
            )
        )
    }

    func testAFailedHeadReadIsNotEvidenceOfACommit() {
        var store = WorkspaceEffectStore()
        store.record(
            WorkspaceEffect.Measurement(root: "/repo", changedPaths: 3, measuredAtMs: now, head: ""),
            tookMs: 5, nowMs: now
        )
        store.record(
            WorkspaceEffect.Measurement(
                root: "/repo", changedPaths: 0, measuredAtMs: now + 10_000,
                head: String(repeating: "b", count: 40)
            ),
            tookMs: 5, nowMs: now + 10_000
        )
        XCTAssertFalse(store.headMovedRecently(root: "/repo", nowMs: now + 10_000))
    }

    // MARK: 2.7 audit — bounds the first version forgot (G-2, G-3)

    func testDirectoryResolutionObeysThePerTickCap() {
        var revParses = 0
        WorkspaceEffect.runner = { [failed] _, command in
            if command.first == "rev-parse", command.contains("--show-toplevel") { revParses += 1 }
            return failed
        }
        var store = WorkspaceEffectStore()
        _ = store.refresh(directories: (0..<40).map { "/dir\($0)" }, nowMs: now)
        XCTAssertEqual(
            revParses, WorkspaceEffectStore.maxRootsPerTick,
            "a burst of new sessions must not fan out unbounded forks in one tick"
        )
    }

    func testTheDirectoryCacheIsBounded() {
        WorkspaceEffect.runner = { [failed] _, _ in failed }
        var store = WorkspaceEffectStore()
        for batch in 0..<300 {
            _ = store.refresh(directories: ["/never-a-repo-\(batch)"], nowMs: now + Int64(batch))
        }
        let table = store.refresh(directories: ["/never-a-repo-0"], nowMs: now + 10_000)
        XCTAssertTrue(table.isEmpty, "still functional after far more directories than the cap")
    }

    // MARK: 2.7 audit — stale must not wear fresh clothes (G-4)

    func testAMeasurementOlderThanTheServeAgeIsServedAsUnknown() {
        WorkspaceEffect.runner = { [ok] _, command in
            command.first == "rev-parse" && command.contains("--show-toplevel")
                ? ok("/repo\n") : ok(" M a\n")
        }
        var store = WorkspaceEffectStore()
        store.record(
            WorkspaceEffect.Measurement(root: "/repo", changedPaths: 9, measuredAtMs: now),
            tookMs: WorkspaceEffect.slowMeasurementMs,   // backed off, so no re-measure
            nowMs: now
        )
        let table = store.refresh(
            directories: ["/repo"],
            nowMs: now + WorkspaceEffectStore.maxServeAgeMs + WorkspaceEffect.backoffMs + 1_000
        )
        XCTAssertNotEqual(
            table["/repo"]?.changedPaths, 9,
            "this tick must not quote an hours-old number as current"
        )
    }

    func testABackedOffRootReportsUnknownRatherThanAStaleNumber() {
        WorkspaceEffect.runner = { [ok] _, arguments in
            arguments.first == "rev-parse" ? ok("/repo\n") : ok(" M a\n")
        }
        var store = WorkspaceEffectStore()
        store.record(
            WorkspaceEffect.Measurement(root: "/repo", changedPaths: 9, measuredAtMs: now),
            tookMs: WorkspaceEffect.slowMeasurementMs,
            nowMs: now
        )
        let table = store.refresh(directories: ["/repo"], nowMs: now + 20_000)
        XCTAssertEqual(table["/repo"]?.changedPaths, -1, "unknown beats a number nobody is refreshing")
    }
}

/// The row's side of the same axis: what it is allowed to say, and when it
/// must stay quiet.
@MainActor
final class WorkspaceEffectRowTests: XCTestCase {

    private func store() -> StatusStore {
        let store = StatusStore()
        store.language = .en
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

    func testWhatLandedAppearsOnTheRow() {
        let s = store()
        var row = liveRow()
        row.changedPaths = 7
        row.insertions = 142
        row.deletions = 38
        let line = s.rowObservationLine(row)
        XCTAssertTrue(line.contains("7"), line)
        XCTAssertTrue(line.contains("142"), line)
        XCTAssertTrue(line.contains("38"), line)
    }

    func testAnUnmeasuredWorkspaceSaysNothingAtAll() {
        let s = store()
        let row = liveRow()   // changedPaths defaults to -1
        XCTAssertFalse(row.hasWorkspaceEffect)
        XCTAssertFalse(s.rowObservationLine(row).contains("files"), s.rowObservationLine(row))
    }

    func testMeasuredAndCleanDoesNotOccupyASlot() {
        // Zero is a real answer, but "0 files touched" is not worth a slot on
        // a line that ranks facts by what they carry — the story line says it
        // in words instead.
        let s = store()
        var row = liveRow()
        row.changedPaths = 0
        XCTAssertFalse(s.rowObservationLine(row).contains("0 files"), s.rowObservationLine(row))
    }

    func testBusyWithNothingLandedIsSaidOutLoud() {
        let s = store()
        var row = liveRow()
        row.changedPaths = 0
        row.cpuPercent = 80          // busy by CPU
        XCTAssertTrue(row.isComputing)
        XCTAssertEqual(s.rowStoryLine(row), s.tr(.movingNothingLanded))
    }

    func testAnUnmeasuredBusyRowIsNotAccusedOfProducingNothing() {
        let s = store()
        var row = liveRow()
        row.cpuPercent = 80          // busy, workspace unknown
        XCTAssertNotEqual(s.rowStoryLine(row), s.tr(.movingNothingLanded))
    }

    func testAnIdleCleanRowIsNotAccusedEither() {
        // Nothing is moving, so "moving, but nothing has landed" would be
        // false on its first word.
        let s = store()
        var row = liveRow()
        row.changedPaths = 0
        XCTAssertNotEqual(s.rowStoryLine(row), s.tr(.movingNothingLanded))
    }

    func testACollisionIsNamedOnTheRow() {
        let s = store()
        var row = liveRow()
        row.workspaceRoot = "/repo"
        row.workspacePeers = 1
        XCTAssertTrue(s.rowSignalLine(row).contains("1"), s.rowSignalLine(row))
    }

    func testAloneInAWorkingCopyIsNotWorthSaying() {
        let s = store()
        var row = liveRow()
        row.workspaceRoot = "/repo"
        row.workspacePeers = 0
        let stem = String(s.tr(.workspaceShared).prefix(while: { $0 != "%" }))
        XCTAssertFalse(stem.isEmpty)
        XCTAssertFalse(s.rowSignalLine(row).contains(stem), s.rowSignalLine(row))
    }

    func testTheSettingRoundTrips() {
        var settings = PulseSettings()
        XCTAssertTrue(settings.measureWorkspaceEffect, "on by default")
        settings.measureWorkspaceEffect = false
        XCTAssertFalse(PulseSettings.parse(settings.serialized()).measureWorkspaceEffect)
    }
}
