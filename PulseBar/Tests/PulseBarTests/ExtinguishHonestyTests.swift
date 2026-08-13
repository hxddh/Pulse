import XCTest
@testable import PulseBar

/// 0.95 Extinguish Honesty — false Waiting must not light; clear stays clear
/// until genuine new evidence.
@MainActor
final class ExtinguishHonestyTests: XCTestCase {
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
        ageMs: Int64 = 1_000
    ) -> ActivityHarvest.Row {
        ActivityHarvest.Row(
            id: id, task: task, project: "", cwd: cwd, skill: skill,
            tool: tool, harvestMs: now - ageMs,
            subRunning: 0, subTotal: 0, sessionID: session,
            evidence: evidence
        )
    }

    private func build(
        harvest rows: [ActivityHarvest.Row] = [],
        attention entries: [AttentionReader.Entry] = [],
        dismissed: Set<String> = [],
        unreliable: Bool = false
    ) -> SnapshotBuilder.Result {
        SnapshotBuilder.build(
            SnapshotBuilder.Input(
                procs: [], harvest: rows, harvestUnreliable: unreliable, attention: entries
            ),
            previous: .init(),
            context: context(dismissed: dismissed)
        )
    }

    // MARK: Answered ask / terminal veto

    func testAnsweredAskWithStaleAskToolDoesNotStampPending() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-extinguish-answered-\(UUID().uuidString)")
        let goose = home.appendingPathComponent(".config/goose/session.json")
        try fm.createDirectory(at: goose.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"""
        {"sessionId":"g-ans","title":"Answered","cwd":"/tmp/g","status":"running",
         "ask":"followup","askResponse":"messageResponse","currentTool":"ask_followup_question"}
        """#.write(to: goose, atomically: true, encoding: .utf8)
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.goose])
        let row = try XCTUnwrap(result.rows.first { $0.id == .goose })
        XCTAssertNotEqual(row.skill, "pending", "askResponse must veto ask-tool pending")
    }

    func testCompletedStatusWithAskToolDoesNotStampPending() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-extinguish-done-\(UUID().uuidString)")
        let goose = home.appendingPathComponent(".config/goose/session.json")
        try fm.createDirectory(at: goose.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"""
        {"sessionId":"g-done","title":"Done","cwd":"/tmp/g","status":"completed",
         "currentTool":"ask_user_question"}
        """#.write(to: goose, atomically: true, encoding: .utf8)
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.goose])
        let row = try XCTUnwrap(result.rows.first { $0.id == .goose })
        XCTAssertNotEqual(row.skill, "pending")
    }

    func testConflictingBoolFlagsAnyTrueWins() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-extinguish-flags-\(UUID().uuidString)")
        let goose = home.appendingPathComponent(".config/goose/session.json")
        try fm.createDirectory(at: goose.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"""
        {"sessionId":"g-flag","title":"Block","cwd":"/tmp/g","status":"running",
         "needsApproval":false,"isBlockedOnUser":true}
        """#.write(to: goose, atomically: true, encoding: .utf8)
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.goose])
        let row = try XCTUnwrap(result.rows.first { $0.id == .goose })
        XCTAssertEqual(row.skill, "pending")
    }

    // MARK: Cascade / Windsurf arbitration

    func testSharedWindsurfRootDoesNotDoubleRaiseCascadeAndWindsurf() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-extinguish-cascade-\(UUID().uuidString)")
        let windsurf = home.appendingPathComponent(".windsurf/session.json")
        try fm.createDirectory(at: windsurf.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"""
        {"sessionId":"ws-dup","title":"Need you","cwd":"/tmp/ws","status":"running",
         "isWaitingForResponse":true,"currentTool":"ask_clarifying_question"}
        """#.write(to: windsurf, atomically: true, encoding: .utf8)
        let result = NativeActivityHarvest.scan(home: home)
        let cascade = result.rows.filter { $0.id == .cascade }
        let wind = result.rows.filter { $0.id == .windsurf }
        XCTAssertFalse(cascade.isEmpty, "Cascade should claim the shared root")
        XCTAssertTrue(wind.isEmpty, "Windsurf shell must not duplicate when Cascade observed")
        XCTAssertEqual(cascade.first?.skill, "pending")
    }

    // MARK: Soft-dismiss absence / unreliable

    func testDismissedKeyClearsWhenHarvestAbsentOnReliableScan() {
        let key = ActivityHarvest.sessionKey(
            id: .cline, sessionID: "cl-gone", project: "", cwd: "/Users/me/Pulse"
        )
        let gone = build(harvest: [], dismissed: [key], unreliable: false)
        XCTAssertTrue(gone.clearedPendingKeys.contains(key))
    }

    func testDismissedKeySurvivesUnreliableHarvestAbsence() {
        let key = ActivityHarvest.sessionKey(
            id: .cline, sessionID: "cl-keep", project: "", cwd: "/Users/me/Pulse"
        )
        let kept = build(harvest: [], dismissed: [key], unreliable: true)
        XCTAssertFalse(kept.clearedPendingKeys.contains(key))
    }

    func testAbsentThenPendingCanReraiseAfterTombstoneCleared() {
        let pending = harvest(.cline, session: "cl-reraise", skill: "pending")
        let key = ActivityHarvest.sessionKey(
            id: .cline, sessionID: "cl-reraise", project: "", cwd: "/Users/me/Pulse"
        )
        let absent = build(harvest: [], dismissed: [key])
        XCTAssertTrue(absent.clearedPendingKeys.contains(key))
        let again = build(harvest: [pending], dismissed: [])
        XCTAssertTrue(again.rows[0].waiting)
    }

    // MARK: Attention match uniqueness

    func testAmbiguousSessionPrefixDoesNotSmearAttention() {
        let lit = build(
            harvest: [
                harvest(.zcode, task: "A", session: "sess-aaa"),
                harvest(.zcode, task: "B", session: "sess-bbb"),
            ],
            attention: [
                AttentionReader.Entry(
                    id: .zcode, kind: "Permission", message: "approve",
                    tsMs: now - 500, session: "sess", cwd: ""
                )
            ]
        )
        XCTAssertFalse(lit.rows.contains(where: \.waiting), "ambiguous prefix must not smear")
    }

    func testExactSessionAttentionStillLights() {
        let lit = build(
            harvest: [
                harvest(.zcode, task: "A", session: "sess-aaa"),
                harvest(.zcode, task: "B", session: "sess-bbb"),
            ],
            attention: [
                AttentionReader.Entry(
                    id: .zcode, kind: "Permission", message: "approve",
                    tsMs: now - 500, session: "sess-bbb", cwd: ""
                )
            ]
        )
        let waiting = lit.rows.filter(\.waiting)
        XCTAssertEqual(waiting.count, 1)
        XCTAssertEqual(waiting[0].sessionID, "sess-bbb")
    }

    // MARK: Stop grace for Waiting kind

    func testGenericWaitingSurvivesImmediateStopWithinGrace() {
        let nowMs = now
        let text = [
            "agent\tkind\tms\tmessage\tsession\tcwd",
            "zcode\twaiting\t\(nowMs - 1_000)\tNeed you\tz-1\t/tmp",
            "zcode\tstop\t\(nowMs)\t\tz-1\t/tmp",
        ].joined(separator: "\n") + "\n"
        let entries = AttentionReader.parse(text, nowMs: nowMs)
        XCTAssertEqual(entries.count, 1, "Waiting + Stop within grace must keep the raise")
        XCTAssertEqual(entries[0].kind, "Waiting")
    }

    // MARK: Waiting-none Reach hover honesty

    func testWaitingNoneNeedsReachHelperStillTrue() {
        let store = StatusStore()
        var row = AgentRow(rowKey: "zcode|live", agent: .zcode)
        row.liveProcess = true
        row.waiting = false
        XCTAssertTrue(store.isWaitingNoneNeedsReach(row))
    }

    // MARK: Look Closure EN copy

    func testLookClosureEnglishSaysChangedNotMoved() {
        XCTAssertEqual(L10n.t(.whileAwayNamedMoved, .en), "%@ changed")
        XCTAssertEqual(L10n.t(.lookMovedMark, .en), "Changed while away")
    }
}
