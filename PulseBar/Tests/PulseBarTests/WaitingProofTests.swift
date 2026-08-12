import XCTest
@testable import PulseBar

/// 0.94 Waiting Proof — harvest ask → tray Waiting → dismiss → clear → re-raise,
/// Attention raise→clear for Waiting-none, and honesty guards (no fake Waiting).
@MainActor
final class WaitingProofTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000

    private var bareTerminal: TerminalFocus.Environment {
        TerminalFocus.Environment(warpRunning: false, ttyHostRunning: false)
    }

    private func context(dismissed: Set<String> = []) -> SnapshotBuilder.Context {
        SnapshotBuilder.Context(
            nowMs: now,
            terminal: bareTerminal,
            lang: .en,
            dismissedPendingKeys: dismissed
        )
    }

    private func harvest(
        _ id: AgentID,
        task: String = "Ask",
        session: String = "s1",
        cwd: String = "/Users/me/Pulse",
        skill: String = "",
        tool: String = "",
        evidence: ObservationSource = .cache,
        ageMs: Int64 = 1_000,
        phase: String = ""
    ) -> ActivityHarvest.Row {
        var row = ActivityHarvest.Row(
            id: id, task: task, project: "", cwd: cwd, skill: skill,
            tool: tool, harvestMs: now - ageMs,
            subRunning: 0, subTotal: 0, sessionID: session,
            evidence: evidence
        )
        row.phase = phase
        return row
    }

    private func attention(
        _ id: AgentID,
        kind: String = "Permission",
        message: String = "approve",
        session: String = "",
        cwd: String = "",
        ageMs: Int64 = 500
    ) -> AttentionReader.Entry {
        AttentionReader.Entry(
            id: id, kind: kind, message: message,
            tsMs: now - ageMs, session: session, cwd: cwd
        )
    }

    private func build(
        harvest rows: [ActivityHarvest.Row] = [],
        attention entries: [AttentionReader.Entry] = [],
        dismissed: Set<String> = []
    ) -> SnapshotBuilder.Result {
        SnapshotBuilder.build(
            SnapshotBuilder.Input(
                procs: [], harvest: rows, harvestUnreliable: false, attention: entries
            ),
            previous: .init(),
            context: context(dismissed: dismissed)
        )
    }

    // MARK: P0-1 harvest → Waiting → dismiss → re-raise

    func testClinePendingRaisesWaitingAndSoftDismissSuppresses() {
        let pending = harvest(.cline, session: "cl-1", skill: "pending")
        let key = ActivityHarvest.sessionKey(
            id: .cline, sessionID: "cl-1", project: "", cwd: "/Users/me/Pulse"
        )
        let lit = build(harvest: [pending])
        XCTAssertTrue(lit.rows[0].waiting)
        XCTAssertEqual(lit.rows[0].waitSignal, .pending)
        XCTAssertEqual(lit.snapshot.glance, .waiting)

        let dismissed = build(harvest: [pending], dismissed: [key])
        XCTAssertFalse(dismissed.rows[0].waiting, "soft-dismiss must suppress harvest pending")

        let cleared = harvest(.cline, session: "cl-1", skill: "")
        let afterClear = build(harvest: [cleared], dismissed: [key])
        XCTAssertTrue(afterClear.clearedPendingKeys.contains(key))

        let again = build(harvest: [pending])
        XCTAssertTrue(again.rows[0].waiting, "new pending after natural clear can re-raise")
    }

    func testRooAskToolPendingRaisesWaiting() {
        let row = harvest(.roo, session: "roo-1", skill: "pending", tool: "ask_followup_question")
        let lit = build(harvest: [row])
        XCTAssertTrue(lit.rows[0].waiting)
        XCTAssertEqual(lit.rows[0].waitSignal, .pending)
        XCTAssertEqual(lit.rows[0].tool, "ask_followup_question")
    }

    func testCascadePendingRaisesWaiting() {
        let row = harvest(
            .windsurf, session: "ws-1", skill: "pending", tool: "ask_clarifying_question"
        )
        let lit = build(harvest: [row])
        XCTAssertTrue(lit.rows[0].waiting)
        XCTAssertEqual(lit.rows[0].waitSignal, .pending)
        XCTAssertEqual(lit.rows[0].observationSource, .cache)
    }

    func testCursorBlockingFlagPendingRaisesWaiting() {
        let row = harvest(.cursor, session: "composer-1", skill: "pending", evidence: .session)
        let lit = build(harvest: [row])
        XCTAssertTrue(lit.rows[0].waiting)
        XCTAssertEqual(lit.rows[0].waitSignal, .pending)
    }

    func testDependingNeverRaisesWaiting() {
        let row = harvest(.goose, session: "g-dep", skill: "", phase: "depending")
        let lit = build(harvest: [row])
        XCTAssertFalse(lit.rows[0].waiting)
        XCTAssertNotEqual(lit.rows[0].skill, "pending")
    }

    // MARK: P0-2 harvest stamp honesty

    func testBlockedOnUserFlagStampsPending() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-proof-blocked-\(UUID().uuidString)")
        let goose = home.appendingPathComponent(".config/goose/session.json")
        try fm.createDirectory(at: goose.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"{"sessionId":"g-block","title":"Need you","cwd":"/tmp/g","status":"running","isBlockedOnUser":true}"#
            .write(to: goose, atomically: true, encoding: .utf8)
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.goose])
        let row = try XCTUnwrap(result.rows.first { $0.id == .goose })
        XCTAssertEqual(row.skill, "pending")
    }

    func testAskUserQuestionToolStampsPending() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-proof-asktool-\(UUID().uuidString)")
        let goose = home.appendingPathComponent(".config/goose/session.json")
        try fm.createDirectory(at: goose.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"{"sessionId":"g-ask","title":"Question","cwd":"/tmp/g","status":"running","currentTool":"ask_user_question"}"#
            .write(to: goose, atomically: true, encoding: .utf8)
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.goose])
        let row = try XCTUnwrap(result.rows.first { $0.id == .goose })
        XCTAssertEqual(row.skill, "pending")
    }

    func testWaitingNoneStillNeverStampsHarvestPending() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-proof-none-\(UUID().uuidString)")
        let zcode = home.appendingPathComponent(".zcode/session.json")
        try fm.createDirectory(at: zcode.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"{"sessionId":"z-1","title":"ZCode work","status":"awaiting_user","currentTool":"ask_followup_question","isWaitingForResponse":true}"#
            .write(to: zcode, atomically: true, encoding: .utf8)
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.zcode])
        let row = try XCTUnwrap(result.rows.first { $0.id == .zcode })
        XCTAssertNotEqual(row.skill, "pending")
    }

    // MARK: P0-3 Attention raise → clear

    func testAttentionRaiseLightsExactSessionThenDoneClears() {
        let lit = build(
            harvest: [
                harvest(.zcode, task: "A", session: "z-a", skill: ""),
                harvest(.zcode, task: "B", session: "z-b", skill: ""),
            ],
            attention: [attention(.zcode, session: "z-b")]
        )
        let waiting = lit.rows.filter(\.waiting)
        XCTAssertEqual(waiting.count, 1)
        XCTAssertEqual(waiting[0].sessionID, "z-b")
        XCTAssertEqual(waiting[0].waitSignal, .hooks)

        let cleared = build(
            harvest: [
                harvest(.zcode, task: "A", session: "z-a", skill: ""),
                harvest(.zcode, task: "B", session: "z-b", skill: ""),
            ],
            attention: []
        )
        XCTAssertFalse(cleared.rows.contains(where: \.waiting))
    }

    // MARK: P0-4 Waiting-none Reach

    func testWaitingNoneNeedsReachAndOpenSettings() {
        let store = StatusStore()
        var row = AgentRow(rowKey: "zcode|live", agent: .zcode)
        row.liveProcess = true
        row.waiting = false
        XCTAssertTrue(store.isWaitingNoneNeedsReach(row))
        store.openWaitingReach(for: row)
        XCTAssertTrue(store.settingsFocusWaitingSignals)
        XCTAssertEqual(store.settingsFocusWaitingAgent, .zcode)
    }

    func testHarvestPendingDoesNotNeedWaitingNoneReach() {
        let store = StatusStore()
        var row = AgentRow(rowKey: "cline|live", agent: .cline)
        row.liveProcess = true
        row.waiting = false
        XCTAssertFalse(store.isWaitingNoneNeedsReach(row))
    }
}
