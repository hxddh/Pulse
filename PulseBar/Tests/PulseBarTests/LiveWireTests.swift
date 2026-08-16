import XCTest
@testable import PulseBar

/// 0.99.2 Live Wire — the rest of the path 0.99.1 只修了一半.
///
/// 0.99.1 fixed how `lsof` output is parsed. These cover what happens to that
/// output afterwards: the gate that decided whether to keep it at all, the
/// subprocess wrapper underneath, and the code downstream that had never once
/// run with a working directory in hand.
final class LiveWireTests: XCTestCase {

    private let now: Int64 = 1_700_000_000_000

    // MARK: - lsof exits 1 while still answering

    /// Measured, not assumed: with one live and one dead PID, `lsof -Ffpn -a
    /// -d cwd -p <live>,<dead>` prints the live process and exits **1**.
    /// Requiring status 0 threw the live answer away.
    func testAnExitCodeOfOneStillCarriesEveryResolvedProcess() {
        let output = """
        p101
        fcwd
        n/Users/me/code/Pulse
        """
        let resolved = ProcessProbe.workingDirectories(
            from: ProcessProbe.Invocation(stdout: output, status: 1)
        )
        XCTAssertEqual(resolved[101], "/Users/me/code/Pulse", "status 1 is not a reason to discard a path")

        // Same bytes, clean exit — the status must make no difference at all.
        XCTAssertEqual(
            resolved,
            ProcessProbe.workingDirectories(
                from: ProcessProbe.Invocation(stdout: output, status: 0)
            )
        )
        XCTAssertTrue(ProcessProbe.workingDirectories(from: nil).isEmpty)
    }

    /// The batch is one PID per agent. A finished agent must not cost every
    /// other agent five minutes of workspace.
    func testADeadProcessAloneDoesNotArmTheBackoff() {
        let deadPid = 999_999
        XCTAssertFalse(ProcessProbe.processExists(deadPid), "pid must be absent for this test")
        XCTAssertFalse(
            ProcessProbe.shouldBackOff(
                ProcessProbe.Invocation(stdout: "", status: 1), pids: [deadPid]
            ),
            "an exited process explains the silence by itself"
        )
    }

    /// Silence about a process that is demonstrably alive is the case backoff
    /// exists for — a denied or unusable lookup.
    func testSilenceAboutALiveProcessStillArmsTheBackoff() {
        let livePid = Int(ProcessInfo.processInfo.processIdentifier)
        XCTAssertTrue(ProcessProbe.processExists(livePid))
        XCTAssertTrue(
            ProcessProbe.shouldBackOff(
                ProcessProbe.Invocation(stdout: "", status: 1), pids: [livePid]
            )
        )
    }

    func testAFailedLaunchAlwaysArmsTheBackoff() {
        XCTAssertTrue(ProcessProbe.shouldBackOff(nil, pids: [999_999]))
    }

    /// Exit 0 with nothing to say is not a PID that vanished; it is a tool
    /// that answered and told us nothing.
    func testACleanButEmptyAnswerArmsTheBackoff() {
        XCTAssertTrue(
            ProcessProbe.shouldBackOff(
                ProcessProbe.Invocation(stdout: "", status: 0), pids: [999_999]
            )
        )
    }

    // MARK: - The subprocess wrapper under it

    /// `lsof` on a dead network mount is the textbook child that ignores
    /// SIGTERM. The wrapper must come back with a verdict rather than asking a
    /// still-running process for an exit status it does not have.
    func testAChildThatIgnoresSigtermStillReturnsAVerdict() throws {
        let result = try XCTUnwrap(
            ProcessIO.run(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; sleep 5"],
                timeout: 0.4
            ),
            "a timeout is a result, not a missing answer"
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertNotEqual(result.status, 0, "a killed child never exited cleanly")
    }

    func testAnOrdinaryChildKeepsItsExitStatus() throws {
        let ok = try XCTUnwrap(
            ProcessIO.run(executable: "/bin/sh", arguments: ["-c", "printf hello"], timeout: 5)
        )
        XCTAssertFalse(ok.timedOut)
        XCTAssertEqual(ok.status, 0)
        XCTAssertEqual(String(data: ok.stdout, encoding: .utf8), "hello")

        let failed = try XCTUnwrap(
            ProcessIO.run(executable: "/bin/sh", arguments: ["-c", "exit 3"], timeout: 5)
        )
        XCTAssertFalse(failed.timedOut)
        XCTAssertEqual(failed.status, 3, "a non-zero exit is information, not a failure to run")
    }

    // MARK: - Downstream: code that had never seen a working directory

    private func context() -> SnapshotBuilder.Context {
        SnapshotBuilder.Context(
            nowMs: now,
            terminal: TerminalFocus.Environment(warpRunning: false, ttyHostRunning: false),
            lang: .en,
            maxSessionsPerAgent: SnapshotBuilder.maxSessionsPerAgent,
            maxVisibleRows: SnapshotBuilder.maxVisibleRows,
            dismissedPendingKeys: [],
            showAllAgents: false,
            snoozedUntilMs: [:],
            stalledSeconds: AgentRow.stalledSeconds
        )
    }

    private func build(
        procs: [ProcessProbe.Hit],
        harvest rows: [ActivityHarvest.Row] = []
    ) -> SnapshotBuilder.Result {
        SnapshotBuilder.build(
            SnapshotBuilder.Input(
                procs: procs, harvest: rows, harvestUnreliable: false, attention: []
            ),
            previous: .init(),
            context: context()
        )
    }

    private func staleRow(_ id: AgentID, session: String, cwd: String, ageMs: Int64) -> ActivityHarvest.Row {
        ActivityHarvest.Row(
            id: id, task: "Wire up the probe", project: "", cwd: cwd, skill: "",
            tool: "", harvestMs: now - ageMs,
            subRunning: 0, subTotal: 0, sessionID: session,
            evidence: .session
        )
    }

    /// A process-only row — an agent with no readable session store — gets its
    /// workspace and project name from the probe. This is the fact 0.99.1's
    /// release notes said had been missing for every such row.
    func testAProcessOnlyRowTakesItsProjectFromTheProbe() throws {
        var probe = ProcessProbe.Hit(id: .aider, count: 1, viaWarp: false, pid: 4242)
        probe.cwd = "/Users/me/code/Pulse"

        let result = build(procs: [probe])
        let row = try XCTUnwrap(result.rows.first { $0.agent == .aider })
        XCTAssertEqual(row.cwd, "/Users/me/code/Pulse")
        XCTAssertEqual(row.project, AgentRow.shortProject("/Users/me/code/Pulse"))
        XCTAssertFalse(row.project.isEmpty, "a process-only row used to have no project at all")
    }

    /// `SnapshotBuilder` picks one stale session per agent to keep, and breaks
    /// the tie with the live process's working directory. Because `hit.cwd` was
    /// always empty, that tie-break had never once executed; from 0.99.1 it
    /// decides which session the user sees.
    func testTheStaleSessionMatchingTheLiveWorkingDirectoryWins() throws {
        let stale: Int64 = 90 * 60 * 1000
        let matching = staleRow(.claude, session: "older-but-here", cwd: "/Users/me/code/Pulse", ageMs: stale + 60_000)
        let newer = staleRow(.claude, session: "newer-elsewhere", cwd: "/Users/me/code/Other", ageMs: stale)

        var probe = ProcessProbe.Hit(id: .claude, count: 1, viaWarp: false, pid: 77)
        probe.cwd = "/Users/me/code/Pulse"

        let rows = build(procs: [probe], harvest: [newer, matching]).rows
            .filter { $0.agent == .claude }
        XCTAssertEqual(rows.count, 1, "one stale fallback per agent")
        XCTAssertEqual(rows.first?.cwd, "/Users/me/code/Pulse")
    }

    /// Without a probe cwd the tie-break must fall back to recency, exactly as
    /// it did before the wire carried anything.
    func testWithoutAProbeWorkingDirectoryTheNewestStaleSessionWins() throws {
        let stale: Int64 = 90 * 60 * 1000
        let older = staleRow(.claude, session: "older", cwd: "/Users/me/code/Pulse", ageMs: stale + 60_000)
        let newer = staleRow(.claude, session: "newer", cwd: "/Users/me/code/Other", ageMs: stale)

        let rows = build(
            procs: [ProcessProbe.Hit(id: .claude, count: 1, viaWarp: false, pid: 77)],
            harvest: [older, newer]
        ).rows.filter { $0.agent == .claude }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.cwd, "/Users/me/code/Other")
    }

    // MARK: - The login item says whether it worked

    @MainActor
    func testTheSupportReportRecordsWhetherLaunchAtLoginWasApplied() {
        let store = StatusStore()
        let report = store.safeSupportReport()
        XCTAssertTrue(
            report.contains("launchAtLogin:"),
            "a toggle whose result is never checked is how this project keeps shipping bugs"
        )
        XCTAssertTrue(report.contains("applied="), report)
    }
}
