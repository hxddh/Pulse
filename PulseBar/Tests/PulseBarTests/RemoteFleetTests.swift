import XCTest
@testable import PulseBar

/// 1.0 Remote Fleet — agents that are not on this Mac.
///
/// Every assertion here is about the same thing: a machine Pulse cannot probe
/// must not borrow the confidence of one it can. The lamp may say less about a
/// remote agent; it must never say more.
final class RemoteFleetTests: XCTestCase {

    private let now: Int64 = 1_800_000_000_000
    private let minute: Int64 = 60_000

    private func line(
        _ agent: String = "claude",
        _ kind: String = "permission",
        ms: Int64,
        message: String = "Approve deploy?",
        session: String = "s1",
        cwd: String = "/Users/me/code/Pulse",
        host: String? = nil
    ) -> String {
        var columns = [agent, kind, String(ms), message, session, cwd]
        if let host { columns.append(host) }
        return columns.joined(separator: "\t")
    }

    // MARK: - Protocol v2 stays readable by v1 writers

    func testAVersionOneLineIsStillALocalEvent() throws {
        let entries = AttentionReader.parse(line(ms: now - minute), nowMs: now)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.host, "", "six columns means this machine, as it always did")
        XCTAssertFalse(entry.isRemote)
    }

    func testTheSeventhColumnNamesTheMachine() throws {
        let entries = AttentionReader.parse(line(ms: now - minute, host: "devbox"), nowMs: now)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.host, "devbox")
        XCTAssertTrue(entry.isRemote)
    }

    /// A remote box still running a v1 hook has no host column. The file it
    /// arrived in is then the only identity there is, and it is enough.
    func testTheFileNameNamesTheMachineWhenTheLineDoesNot() throws {
        let entries = AttentionReader.parse(
            line(ms: now - minute),
            nowMs: now,
            defaultHost: "buildbox",
            receivedAtMs: now - minute
        )
        XCTAssertEqual(try XCTUnwrap(entries.first).host, "buildbox")
    }

    func testAHostLabelCannotCarryAKeySeparator() {
        XCTAssertEqual(AttentionProtocol.normalizeHost("dev|box"), "dev-box")
        XCTAssertEqual(AttentionProtocol.normalizeHost("devbox.local"), "devbox")
        XCTAssertEqual(AttentionProtocol.normalizeHost("  devbox  "), "devbox")
        XCTAssertEqual(AttentionProtocol.normalizeHost(""), "", "empty means this machine")
    }

    // MARK: - Two machines are two waits

    func testTheSameAgentOnTwoMachinesDoesNotCollapseIntoOneWait() {
        let text = [
            line(ms: now - minute, session: "s1", host: "alpha"),
            line(ms: now - minute, session: "s1", host: "beta"),
        ].joined(separator: "\n")
        let entries = AttentionReader.parse(text, nowMs: now, receivedAtMs: now - minute)
        XCTAssertEqual(Set(entries.map(\.host)), ["alpha", "beta"])
        XCTAssertEqual(Set(entries.map(\.mapKey)).count, 2)
    }

    /// An agent-level `done` used to clear by key prefix. With two hosts in one
    /// file that would let a finished agent on one machine close an open
    /// permission on another.
    func testOneMachinesDoneDoesNotClearAnothersOpenPermission() throws {
        let text = [
            line(ms: now - 2 * minute, session: "s1", host: "alpha"),
            line(ms: now - 2 * minute, session: "s2", host: "beta"),
            line("claude", "done", ms: now - minute, session: "", host: "alpha"),
        ].joined(separator: "\n")
        let entries = AttentionReader.parse(text, nowMs: now, receivedAtMs: now - minute)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(try XCTUnwrap(entries.first).host, "beta")
    }

    // MARK: - The clock belongs to the other machine

    func testAnEventFromASkewedClockIsMeasuredFromArrivalInsteadOfDropped() throws {
        // Sender's clock is 40 minutes fast: before 1.0 this was dropped and
        // nothing anywhere said why.
        let entries = AttentionReader.parse(
            line(ms: now + 40 * minute, host: "skewbox"),
            nowMs: now,
            receivedAtMs: now - minute
        )
        let entry = try XCTUnwrap(entries.first)
        XCTAssertTrue(entry.clockSuspect)
        XCTAssertEqual(entry.effectiveMs, now - minute, "arrival is the clock we own")
        XCTAssertFalse(entry.lostContact)
    }

    func testAPlausibleRemoteClockIsUsedAsIs() throws {
        let entries = AttentionReader.parse(
            line(ms: now - 2 * minute, host: "devbox"),
            nowMs: now,
            receivedAtMs: now - 2 * minute
        )
        let entry = try XCTUnwrap(entries.first)
        XCTAssertFalse(entry.clockSuspect)
        XCTAssertEqual(entry.effectiveMs, now - 2 * minute)
    }

    func testTheLocalClockRuleIsUnchanged() {
        XCTAssertEqual(
            AttentionReader.clockVerdict(eventMs: now, arrivalMs: 0, isRemote: false),
            .trustEvent
        )
        XCTAssertEqual(
            AttentionReader.clockVerdict(eventMs: 0, arrivalMs: 0, isRemote: false),
            .unusable
        )
    }

    // MARK: - Going quiet is not finishing

    func testARemoteWaitThatGoesQuietLosesTheLampButKeepsTheRow() throws {
        let entries = AttentionReader.parse(
            line(ms: now - 45 * minute, host: "devbox"),
            nowMs: now,
            receivedAtMs: now - 45 * minute
        )
        let entry = try XCTUnwrap(entries.first, "a quiet remote wait must not vanish")
        XCTAssertTrue(entry.lostContact)
    }

    func testALocalWaitPastItsTtlStillDisappears() {
        // The process probe is the witness a remote row does not have.
        XCTAssertTrue(
            AttentionReader.parse(line(ms: now - 45 * minute), nowMs: now).isEmpty
        )
    }

    func testLostContactIsNotForever() {
        XCTAssertTrue(
            AttentionReader.parse(
                line(ms: now - 3 * 60 * minute, host: "devbox"),
                nowMs: now,
                receivedAtMs: now - 3 * 60 * minute
            ).isEmpty,
            "after long enough, 'nothing heard' stops being news"
        )
    }

    // MARK: - What the tray is allowed to claim

    private func build(_ entries: [AttentionReader.Entry]) -> SnapshotBuilder.Result {
        SnapshotBuilder.build(
            SnapshotBuilder.Input(
                procs: [], harvest: [], harvestUnreliable: false, attention: entries
            ),
            previous: .init(),
            context: SnapshotBuilder.Context(
                nowMs: now,
                terminal: TerminalFocus.Environment(warpRunning: true, ttyHostRunning: true),
                lang: .en,
                maxSessionsPerAgent: SnapshotBuilder.maxSessionsPerAgent,
                maxVisibleRows: SnapshotBuilder.maxVisibleRows,
                dismissedPendingKeys: [],
                showAllAgents: false,
                snoozedUntilMs: [:],
                stalledSeconds: AgentRow.stalledSeconds
            )
        )
    }

    private func remoteEntry(
        host: String = "devbox",
        session: String = "s1",
        lost: Bool = false,
        kind: String = "Permission"
    ) -> AttentionReader.Entry {
        var entry = AttentionReader.Entry(
            id: .claude, kind: kind, message: "Approve deploy?",
            tsMs: now - minute, session: session, cwd: "/Users/me/code/Pulse"
        )
        entry.host = host
        entry.receivedAtMs = now - minute
        entry.lostContact = lost
        return entry
    }

    func testARemoteRowNeverClaimsAProcessOrAFocusHandle() throws {
        let row = try XCTUnwrap(build([remoteEntry()]).rows.first)
        XCTAssertTrue(row.isRemote)
        XCTAssertEqual(row.host, "devbox")
        XCTAssertEqual(row.observationSource, .remote)
        XCTAssertFalse(row.liveProcess, "there is no process table on the other machine")
        XCTAssertEqual(row.processCount, 0)
        XCTAssertNil(row.focusTier, "Pulse can show it, not reach it")
        XCTAssertTrue(row.waiting)
    }

    func testALostRemoteRowStaysVisibleWithTheLampDown() throws {
        let row = try XCTUnwrap(build([remoteEntry(lost: true)]).rows.first)
        XCTAssertTrue(row.lostContact)
        XCTAssertFalse(row.waiting, "an unrefreshed wait is not evidence of an open wait")
        XCTAssertTrue(row.waitMessage.isEmpty)
        XCTAssertEqual(row.lastHeardMs, now - minute, "what we do know is when we last heard")
    }

    func testTwoHostsProduceTwoRows() {
        let rows = build([
            remoteEntry(host: "alpha"),
            remoteEntry(host: "beta"),
        ]).rows
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.rowKey)).count, 2, "snooze and dismiss follow rowKey")
    }

    /// A remote wait must not attach itself to a local session that happens to
    /// share an id — that would point Focus, snooze and dismiss at the wrong
    /// machine's work.
    func testARemoteWaitDoesNotAdoptALocalSession() throws {
        let local = ActivityHarvest.Row(
            id: .claude, task: "Local work", project: "", cwd: "/Users/me/code/Pulse",
            skill: "", tool: "", harvestMs: now - 1000,
            subRunning: 0, subTotal: 0, sessionID: "s1", evidence: .session
        )
        let result = SnapshotBuilder.build(
            SnapshotBuilder.Input(
                procs: [], harvest: [local], harvestUnreliable: false,
                attention: [remoteEntry(session: "s1")]
            ),
            previous: .init(),
            context: SnapshotBuilder.Context(
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
        )
        let localRow = try XCTUnwrap(result.rows.first { !$0.isRemote })
        XCTAssertFalse(localRow.waiting, "the local session was never asked anything")
        XCTAssertTrue(result.rows.contains { $0.isRemote && $0.waiting })
    }

    // MARK: - It says so out loud

    @MainActor
    func testTheSupportReportNamesRemoteSources() {
        let store = StatusStore()
        XCTAssertTrue(store.safeSupportReport().contains("remoteFleet:"))
    }

    @MainActor
    func testTheStoryLineSaysWhenWeLastHeardRatherThanWhatItIsDoing() throws {
        let store = StatusStore()
        store.language = .en
        var row = AgentRow(rowKey: "claude|s1@devbox", agent: .claude)
        row.host = "devbox"
        row.observationSource = .remote
        row.lastHeardMs = now - 3 * minute
        row.waiting = true
        // Against a fixed clock the line quotes the real gap.
        let line = try XCTUnwrap(store.remoteStatusLine(row, nowMs: now))
        XCTAssertTrue(line.contains("3"), line)

        // The story line reads the live clock, so compare it against the same
        // clock rather than the fixture's.
        var live = row
        live.lastHeardMs = Int64(Date().timeIntervalSince1970 * 1000) - 3 * minute
        XCTAssertEqual(
            store.rowStoryLine(live),
            store.remoteStatusLine(live),
            "the remote story outranks every local template"
        )
        XCTAssertTrue(store.rowSourceLabel(row)?.contains("devbox") == true, "name the machine")
    }

    // MARK: - Inbox reads keep the newest bytes

    func testAnOversizedInboxFileKeepsItsNewestEvents() throws {
        // Regression: the inbox used to read the FIRST 256KB of an
        // append-only TSV, so once a busy remote host's file grew past the
        // budget, its fresh raises were exactly the bytes that got dropped.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temp.appendingPathComponent("attention.d"),
            withIntermediateDirectories: true
        )
        AttentionIO.pathOverride = temp.appendingPathComponent("attention.tsv")
        defer {
            AttentionIO.pathOverride = nil
            try? FileManager.default.removeItem(at: temp)
        }

        let oldest = line("claude", "permission", ms: now - 60 * minute,
                          message: "stale ask", session: "old-1")
        let newest = line("claude", "permission", ms: now - minute,
                          message: "fresh ask", session: "new-1")
        let padding = String(repeating: "# sync noise\n", count: (AttentionIO.maxInboxBytesPerFile / 13) + 200)
        let file = temp.appendingPathComponent("attention.d/devbox.tsv")
        try (oldest + "\n" + padding + newest + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let sources = AttentionIO.readInbox()
        let devbox = try XCTUnwrap(sources.first { $0.host == "devbox" })
        XCTAssertTrue(devbox.text.contains("fresh ask"), "the newest event must survive truncation")
        XCTAssertFalse(devbox.text.contains("stale ask"), "the oldest bytes are the ones to drop")
        XCTAssertFalse(devbox.text.hasPrefix("ync noise"), "a partial first line must not survive the seek")
    }
}
