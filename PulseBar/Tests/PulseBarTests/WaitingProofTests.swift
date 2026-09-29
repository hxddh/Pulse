import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

/// 0.94 Waiting Proof — harvest ask → tray Waiting → dismiss → clear → re-raise,
/// Attention raise→clear for Waiting-none, and honesty guards (no fake Waiting).
final class WaitingProofTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000

    @MainActor
    private var bareTerminal: TerminalFocus.Environment {
        TerminalFocus.Environment(warpRunning: false, ttyHostRunning: false)
    }

    @MainActor
    private func context(dismissed: Set<String> = []) -> SnapshotBuilder.Context {
        SnapshotBuilder.Context(
            nowMs: now,
            terminal: bareTerminal,
            lang: .en,
            dismissedPendingKeys: dismissed
        )
    }

    @MainActor
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

    @MainActor
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

    @MainActor
    private func build(
        harvest rows: [ActivityHarvest.Row] = [],
        attention entries: [AttentionReader.Entry] = [],
        dismissed: Set<String> = []
    ) -> SnapshotBuilder.Result {
        SnapshotBuilder.build(
            SnapshotBuilder.Input(
                procs: [], harvest: rows, attention: entries
            ),
            previous: .init(),
            context: context(dismissed: dismissed)
        )
    }

    // MARK: P0-1 harvest → Waiting → dismiss → re-raise

    @MainActor
    func testClinePendingRaisesWaitingAndSoftDismissSuppresses() {
        let pending = harvest(.cline, session: "cl-1", skill: "pending")
        let key = RowIdentity.session(agent: .cline, sessionID: "cl-1")
        let lit = build(harvest: [pending])
        XCTAssertTrue(lit.rows[0].isBlocked)
        XCTAssertEqual(lit.rows[0].wait?.signal, .pending)
        XCTAssertEqual(lit.snapshot.glance, .waiting)

        let dismissed = build(harvest: [pending], dismissed: [key])
        XCTAssertFalse(dismissed.rows[0].isBlocked, "soft-dismiss must suppress harvest pending")

        let cleared = harvest(.cline, session: "cl-1", skill: "")
        let afterClear = build(harvest: [cleared], dismissed: [key])
        XCTAssertTrue(afterClear.clearedPendingKeys.contains(key))

        let again = build(harvest: [pending])
        XCTAssertTrue(again.rows[0].isBlocked, "new pending after natural clear can re-raise")
    }

    @MainActor
    func testRooAskToolPendingRaisesWaiting() {
        let row = harvest(.roo, session: "roo-1", skill: "pending", tool: "ask_followup_question")
        let lit = build(harvest: [row])
        XCTAssertTrue(lit.rows[0].isBlocked)
        XCTAssertEqual(lit.rows[0].wait?.signal, .pending)
        XCTAssertEqual(lit.rows[0].wait?.kind, "Input", "a follow-up question is an ask, not a permission")
    }

    @MainActor
    func testUnverifiedCascadePendingDoesNotRaiseWaiting() {
        // 23.0: Windsurf/Cascade formats are unverified — `waiting: .none`.
        let row = harvest(
            .windsurf, session: "ws-1", skill: "pending", tool: "ask_clarifying_question"
        )
        let lit = build(harvest: [row])
        XCTAssertFalse(lit.rows[0].isBlocked)
        XCTAssertEqual(lit.rows[0].source, .cache)
    }

    @MainActor
    func testUnverifiedCursorBlockingFlagDoesNotRaiseWaiting() {
        // 23.0: Cursor's format is unverified — `waiting: .none`.
        let row = harvest(.cursor, session: "composer-1", skill: "pending", evidence: .session)
        let lit = build(harvest: [row])
        XCTAssertFalse(lit.rows[0].isBlocked)
    }

    @MainActor
    func testDependingNeverRaisesWaiting() {
        let row = harvest(.goose, session: "g-dep", skill: "", phase: "depending")
        let lit = build(harvest: [row])
        XCTAssertFalse(lit.rows[0].isBlocked)
    }

    // MARK: P0-2 harvest stamp honesty

    @MainActor
    func testBlockedOnUserFlagStampsPending() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-proof-blocked-\(UUID().uuidString)")
        let goose = home.appendingPathComponent(".copilot/session.json")
        try fm.createDirectory(at: goose.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"{"sessionId":"g-block","title":"Need you","cwd":"/tmp/g","status":"running","isBlockedOnUser":true}"#
            .write(to: goose, atomically: true, encoding: .utf8)
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.copilot])
        let row = try XCTUnwrap(result.rows.first { $0.id == .copilot })
        XCTAssertEqual(row.skill, "pending")
    }

    @MainActor
    func testAskUserQuestionToolStampsPending() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-proof-asktool-\(UUID().uuidString)")
        let goose = home.appendingPathComponent(".copilot/session.json")
        try fm.createDirectory(at: goose.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"{"sessionId":"g-ask","title":"Question","cwd":"/tmp/g","status":"running","currentTool":"ask_user_question"}"#
            .write(to: goose, atomically: true, encoding: .utf8)
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.copilot])
        let row = try XCTUnwrap(result.rows.first { $0.id == .copilot })
        XCTAssertEqual(row.skill, "pending")
    }

    @MainActor
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

    @MainActor
    func testAttentionRaiseLightsExactSessionThenDoneClears() {
        let lit = build(
            harvest: [
                harvest(.zcode, task: "A", session: "z-a", skill: ""),
                harvest(.zcode, task: "B", session: "z-b", skill: ""),
            ],
            attention: [attention(.zcode, session: "z-b")]
        )
        let waiting = lit.rows.filter(\.isBlocked)
        XCTAssertEqual(waiting.count, 1)
        XCTAssertEqual(waiting[0].sessionID, "z-b")
        XCTAssertEqual(waiting[0].wait?.signal, .hooks)

        let cleared = build(
            harvest: [
                harvest(.zcode, task: "A", session: "z-a", skill: ""),
                harvest(.zcode, task: "B", session: "z-b", skill: ""),
            ],
            attention: []
        )
        XCTAssertFalse(cleared.rows.contains(where: \.isBlocked))
    }

    // MARK: P0-4 Waiting-none Reach

    @MainActor
    func testWaitingNoneNeedsReachAndOpenSettings() {
        let store = StatusStore()
        var row = AgentRow(rowKey: "zcode|live", agent: .zcode)
        row.liveProcess = true
        row.state = .running
        XCTAssertTrue(store.isWaitingNoneNeedsReach(row))
        store.openWaitingReach(for: row)
        XCTAssertEqual(store.settingsFocus.target, .waitingSignals)
    }

    @MainActor
    func testHarvestPendingDoesNotNeedWaitingNoneReach() {
        let store = StatusStore()
        var row = AgentRow(rowKey: "cline|live", agent: .cline)
        row.liveProcess = true
        row.state = .running
        XCTAssertFalse(store.isWaitingNoneNeedsReach(row))
    }
}
