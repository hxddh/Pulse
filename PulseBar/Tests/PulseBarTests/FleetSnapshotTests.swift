import XCTest
@testable import PulseBar

/// 2.7 Fleet — the rest of each remote machine, not just its doorbell.
///
/// Since 1.0 a remote agent existed only while it was asking for something.
/// These tests hold the two disciplines that make the wider view safe to
/// ship: nothing here may invent Waiting, and no remote fact may be quoted
/// past its freshness.
final class FleetSnapshotTests: XCTestCase {

    private let now: Int64 = 1_800_000_000_000
    /// The disk tests must use the wall clock: a report's age is measured
    /// against the file's real mtime, and a fixed fake "now" made every file
    /// look 140 days old — the reader correctly dropped it, the test then
    /// indexed into an empty array, and the crash took the whole test process
    /// (and every suite after it) down with it.
    private var wallNow: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-fleet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FleetSnapshot.directoryOverride = directory
    }

    override func tearDownWithError() throws {
        FleetSnapshot.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func localRow(
        key: String = "claude|s1",
        task: String = "Fix the auth module",
        cwd: String = "/Users/me/work/repo"
    ) -> AgentRow {
        var row = AgentRow(rowKey: key, agent: .claude)
        row.task = task
        row.sessionID = "s1"
        row.cwd = cwd
        row.liveProcess = true
        row.harvestMs = now
        row.observationSource = .session
        row.tool = "Edit"
        row.changedPaths = 7
        row.insertions = 142
        row.deletions = 38
        return row
    }

    // MARK: - Building and writing this Mac's snapshot

    func testTheSnapshotCarriesCountsAndShortNamesOnly() {
        let file = FleetSnapshot.build(host: "thismac", rows: [localRow()], sentAtMs: now)
        XCTAssertEqual(file.rows.count, 1)
        let row = file.rows[0]
        XCTAssertEqual(row.project, "repo", "a leaf name, never a path")
        XCTAssertFalse(row.project.contains("/"))
        XCTAssertEqual(row.changedPaths, 7)
        XCTAssertEqual(row.task, "Fix the auth module")
    }

    func testARemoteRowNeverRoundTrips() {
        // Relaying devbox's rows under this Mac's name would double every
        // agent the moment two machines sync with each other.
        var remote = localRow(key: "claude|s9@devbox")
        remote.host = "devbox"
        remote.observationSource = .remote
        let file = FleetSnapshot.build(host: "thismac", rows: [localRow(), remote], sentAtMs: now)
        XCTAssertEqual(file.rows.count, 1)
    }

    func testTheSnapshotIsBoundedAndSanitized() {
        let rows = (0..<40).map { localRow(key: "claude|s\($0)") }
        var noisy = localRow()
        noisy.task = "Deploy with key Bearer abc123secretvalue " + String(repeating: "x", count: 400)
        let file = FleetSnapshot.build(host: "thismac", rows: [noisy] + rows, sentAtMs: now)
        XCTAssertEqual(file.rows.count, FleetSnapshot.maxRows)
        XCTAssertLessThanOrEqual(file.rows[0].task.count, FleetSnapshot.maxTaskLength)
        XCTAssertFalse(file.rows[0].task.contains("abc123secretvalue"), file.rows[0].task)
    }

    func testWriteThenReadRoundTrips() throws {
        XCTAssertTrue(FleetSnapshot.write(
            FleetSnapshot.build(host: "devbox", rows: [localRow()], sentAtMs: now)
        ))
        let url = directory.appendingPathComponent("devbox.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let reports = FleetSnapshot.readReports(selfHost: "thismac", nowMs: wallNow)
        let report = try XCTUnwrap(reports.first, "one fresh file, one report")
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(report.host, "devbox")
        XCTAssertEqual(report.rows.first?.changedPaths, 7)
        XCTAssertGreaterThan(report.receivedAtMs, 0, "age comes from this disk's clock")
    }

    func testOurOwnFileIsNeverReadBack() {
        FleetSnapshot.write(FleetSnapshot.build(host: "thismac", rows: [localRow()], sentAtMs: now))
        XCTAssertTrue(FleetSnapshot.readReports(selfHost: "thismac", nowMs: wallNow).isEmpty)
    }

    func testAFileClaimingAnotherHostIsRefused() throws {
        // The filename decides which machine this is; a body that disagrees
        // is somebody being clever — same rule as the respond spool.
        var file = FleetSnapshot.build(host: "impostor", rows: [localRow()], sentAtMs: now)
        file.host = "impostor"
        let encoder = JSONEncoder()
        try encoder.encode(file).write(to: directory.appendingPathComponent("devbox.json"))
        XCTAssertTrue(FleetSnapshot.readReports(selfHost: "thismac", nowMs: wallNow).isEmpty)
    }

    func testAnAncientFileIsGoneNotLost() throws {
        FleetSnapshot.write(FleetSnapshot.build(host: "devbox", rows: [localRow()], sentAtMs: now))
        let reports = FleetSnapshot.readReports(
            selfHost: "thismac",
            nowMs: wallNow + FleetSnapshot.dropAfterMs + 60_000
        )
        XCTAssertTrue(reports.isEmpty, "an hour of silence is absence, not a row")
    }

    // MARK: - The builder's side: what a report may become

    private func report(
        ageMs: Int64 = 0,
        sentAheadMs: Int64 = 0,
        rows: [FleetSnapshot.Row]? = nil
    ) -> FleetSnapshot.Report {
        FleetSnapshot.Report(
            host: "devbox",
            sentAtMs: now - ageMs + sentAheadMs,
            receivedAtMs: now - ageMs,
            rows: rows ?? [FleetSnapshot.Row(
                agent: "claude", session: "s1", task: "Migrate the schema",
                project: "repo", tool: "Bash", model: "", phase: "",
                activityAtMs: now - ageMs - 5_000,
                cpuPercent: 42, changedPaths: 3, insertions: 10, deletions: 2
            )]
        )
    }

    private func build(
        fleet: [FleetSnapshot.Report],
        attention: [AttentionReader.Entry] = []
    ) -> [AgentRow] {
        SnapshotBuilder.build(
            SnapshotBuilder.Input(attention: attention, fleet: fleet),
            previous: SnapshotBuilder.Previous(),
            context: SnapshotBuilder.Context(
                nowMs: now,
                terminal: TerminalFocus.Environment(
                    warpRunning: false, ttyHostRunning: false, allowTTYAutomation: false
                ),
                lang: .en
            )
        ).rows
    }

    func testAFreshReportBecomesARunningInfoRow() {
        let rows = build(fleet: [report()])
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertEqual(row.rowKey, "claude|s1@devbox")
        XCTAssertEqual(row.host, "devbox")
        XCTAssertFalse(row.waiting, "Waiting never comes from a snapshot")
        XCTAssertFalse(row.lostContact)
        XCTAssertEqual(row.task, "Migrate the schema")
        XCTAssertEqual(row.changedPaths, 3)
        XCTAssertEqual(row.cpuPercent, 42)
        XCTAssertFalse(row.liveProcess, "no process claim about another machine")
        XCTAssertNil(row.focusTier, "nothing on this Mac to focus")
        XCTAssertTrue(row.workspaceRoot.isEmpty, "remote rows never join collision counting")
    }

    func testAStaleReportGoesLostContactAndStopsQuotingFacts() {
        let rows = build(fleet: [report(ageMs: FleetSnapshot.staleAfterMs + 1_000)])
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertTrue(row.lostContact)
        XCTAssertEqual(row.changedPaths, -1, "counts nobody is refreshing are not quoted")
        XCTAssertFalse(row.hasCPUSample)
        XCTAssertEqual(row.task, "Migrate the schema", "identity stays; substance goes")
    }

    func testAnAncientReportIsDropped() {
        XCTAssertTrue(build(fleet: [report(ageMs: FleetSnapshot.dropAfterMs + 1)]).isEmpty)
    }

    func testAnUnknownAgentIsSkippedNeverGuessed() {
        var row = report().rows[0]
        row.agent = "some-future-agent"
        XCTAssertTrue(build(fleet: [report(rows: [row])]).isEmpty)
    }

    func testAFastRemoteClockCannotDateActivityInTheFuture() {
        var fleetRow = report().rows[0]
        fleetRow.activityAtMs = now + 10 * 60 * 1000
        let rows = build(fleet: [report(rows: [fleetRow])])
        XCTAssertLessThanOrEqual(rows[0].harvestMs, now)
    }

    func testAnAttentionWaitAndItsSnapshotShareOneRow() {
        // The same session on the same host: the raise brings the wait, the
        // snapshot brings the substance. Two keys would put a "running" row
        // beside its own "waiting" row.
        let att = AttentionReader.Entry(
            id: .claude, kind: "permission", message: "Bash: rm -rf build",
            tsMs: now - 30_000, session: "s1", cwd: "/work/repo",
            host: "devbox", receivedAtMs: now - 30_000
        )
        let rows = build(fleet: [report()], attention: [att])
        XCTAssertEqual(rows.count, 1, "\(rows.map(\.rowKey))")
        let row = rows[0]
        XCTAssertTrue(row.waiting, "the wait is the attention protocol's, untouched")
        XCTAssertEqual(row.waitMessage, "Bash: rm -rf build")
        XCTAssertEqual(row.changedPaths, 3, "and the substance is the snapshot's")
    }

    func testAProjectThatArrivesAsAPathIsReducedToItsLeaf() {
        var fleetRow = report().rows[0]
        fleetRow.project = "/Users/other/secret-client/repo"
        let rows = build(fleet: [report(rows: [fleetRow])])
        XCTAssertEqual(rows[0].project, "repo")
    }

    // MARK: - 2.8: the current step rides, ages, and degrades additively

    func testTheCurrentStepRidesTheSnapshotAndItsAbsenceIsAbsent() {
        var planning = localRow()
        planning.planStep = "Running the gates"
        planning.progressDone = 2
        planning.progressTotal = 4
        let file = FleetSnapshot.build(host: "thismac", rows: [planning], sentAtMs: now)
        XCTAssertEqual(file.rows[0].step, "Running the gates")
        XCTAssertEqual(file.rows[0].stepDone, 2)
        XCTAssertEqual(file.rows[0].stepTotal, 4)
        let bare = FleetSnapshot.build(host: "thismac", rows: [localRow()], sentAtMs: now)
        XCTAssertNil(bare.rows[0].step, "no plan, no key — a 2.7 reader still sees the 2.7 shape")
        XCTAssertNil(bare.rows[0].stepTotal)
    }

    func testAFreshReportCarriesTheRemoteStepAndAStaleOneDropsIt() {
        var fleetRow = report().rows[0]
        fleetRow.step = "Running the gates"
        fleetRow.stepDone = 2
        fleetRow.stepTotal = 4
        let fresh = build(fleet: [report(rows: [fleetRow])])
        XCTAssertEqual(fresh[0].planStep, "Running the gates")
        XCTAssertEqual(fresh[0].progressDone, 2)
        XCTAssertEqual(fresh[0].progressTotal, 4)
        let stale = build(fleet: [report(ageMs: FleetSnapshot.staleAfterMs + 1_000, rows: [fleetRow])])
        XCTAssertEqual(stale[0].planStep, "", "a step nobody is refreshing is not quoted")
        XCTAssertEqual(stale[0].progressTotal, 0)
    }

    func testATwoSevenFileWithoutStepKeysStillDecodes() throws {
        let body = """
        {"v":1,"host":"devbox","sent_at_ms":\(now),"rows":[{"agent":"claude","session":"s1",\
        "task":"Old","project":"repo","tool":"","model":"","phase":"",\
        "activity_at_ms":\(now),"cpu_percent":-1,"changed_paths":-1,"insertions":-1,"deletions":-1}]}
        """
        try XCTUnwrap(body.data(using: .utf8))
            .write(to: directory.appendingPathComponent("devbox.json"))
        let reports = FleetSnapshot.readReports(selfHost: "thismac", nowMs: wallNow)
        let report = try XCTUnwrap(reports.first, "additive fields must not orphan 2.7 files")
        XCTAssertEqual(report.rows.first?.task, "Old")
        XCTAssertNil(report.rows.first?.step)
    }

    func testTheBroadcastSettingRoundTripsAndDefaultsOff() {
        var settings = PulseSettings()
        XCTAssertFalse(settings.broadcastFleet, "content leaving the machine is opt-in")
        settings.broadcastFleet = true
        XCTAssertTrue(PulseSettings.parse(settings.serialized()).broadcastFleet)
    }
}
