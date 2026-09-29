import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest
@testable import PulseManaged
@testable import PulseRespond

/// 16.0 · Turn — vendor event sequences, from the attention file to the lamp.
///
/// Until 15.0 Claude's `idle_prompt` notification — a 60-second timer that
/// fires after every finished turn — lit the red lamp, so every Claude
/// session that finished its work went red a minute later and stayed red.
/// Each case here is a sequence of lines as the hooks write them, read by the
/// real reader and merged by the real builder; the assertions are on what the
/// user would see: the lamp, the row, the tray count, the banner plan.
final class TurnTruthTests: XCTestCase {
    private let now: Int64 = 1_800_000_000_000
    private let second: Int64 = 1_000

    private func line(
        _ agent: String, _ kind: String, ago: Int64, message: String = "",
        session: String = "s1", cwd: String = "/p", front: String? = nil
    ) -> String {
        var cols = [agent, kind, "\(now - ago)", message, session, cwd]
        if let front { cols += ["", front] }
        return cols.joined(separator: "\t")
    }

    private func session(_ id: AgentID, _ session: String = "s1", ageMs: Int64 = 70_000) -> ActivityHarvest.Row {
        ActivityHarvest.Row(
            id: id, task: "Fix the login flow", project: "p", cwd: "/p", skill: "",
            tool: "", harvestMs: now - ageMs, subRunning: 0, subTotal: 0, sessionID: session,
            evidence: .session
        )
    }

    private func world(
        _ lines: [String],
        harvest: [ActivityHarvest.Row],
        activity: [ActivitySpool.Event] = []
    ) -> SnapshotBuilder.Result {
        let text = AttentionProtocol.header + lines.joined(separator: "\n") + "\n"
        let entries = AttentionReader.parse(text, nowMs: now)
        return SnapshotBuilder.build(
            SnapshotBuilder.Input(procs: [], harvest: harvest, harvestUnreliable: false, attention: entries, activity: activity),
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
    }

    private func delivery(_ rows: [AgentRow]) -> WaitingDelivery.Plan {
        WaitingDelivery(
            muted: [], acknowledged: [], inFlight: [], canDeliverNow: true,
            msSinceLastNotification: 60_000, minimumIntervalMs: 0
        ).plan(rows)
    }

    // MARK: - Claude

    func testAFinishedClaudeTurnIsYourTurnNotRed() throws {
        // Permission answered, work done, Stop; a minute later idle_prompt.
        let r = world([
            line("claude", "permission", ago: 180 * second, message: "Bash: npm test"),
            line("claude", "stop", ago: 61 * second),
            line("claude", "idle_prompt", ago: 1 * second),
        ], harvest: [session(.claude)])
        let row = try XCTUnwrap(r.rows.first)
        XCTAssertFalse(row.waiting, "a finished turn is not blocked")
        XCTAssertTrue(row.yourTurn)
        XCTAssertNotEqual(r.snapshot.glance, .waiting, "the red lamp is for blocked")
        XCTAssertEqual(r.snapshot.turnCount, 1)
        XCTAssertEqual(delivery(r.rows), .nothing, "no banner, no sound for your turn")
    }

    func testAPermissionIsStillRed() throws {
        let r = world([line("claude", "permission", ago: 5 * second, message: "Bash: rm -rf build")],
                      harvest: [session(.claude)])
        let row = try XCTUnwrap(r.rows.first)
        XCTAssertTrue(row.waiting)
        XCTAssertFalse(row.yourTurn)
        XCTAssertEqual(r.snapshot.glance, .waiting)
        XCTAssertEqual(r.snapshot.turnCount, 0)
        if case .post(let rows, _) = delivery(r.rows) {
            XCTAssertEqual(rows.map(\.rowKey), [row.rowKey])
        } else {
            XCTFail("a blocked prompt out of sight gets a banner")
        }
    }

    func testAQuestionIsRedAndSaysInput() throws {
        let r = world([line("claude", "elicitation_dialog", ago: 5 * second, message: "Which database?")],
                      harvest: [session(.claude)])
        let row = try XCTUnwrap(r.rows.first)
        XCTAssertTrue(row.waiting)
        XCTAssertEqual(row.waitKind, "Input")
        XCTAssertEqual(r.snapshot.glance, .waiting)
    }

    func testATurnMomentsAfterAPermissionDoesNotHideIt() throws {
        let r = world([
            line("claude", "permission", ago: 6 * second, message: "Bash: npm run build"),
            line("claude", "stop", ago: 1 * second),
        ], harvest: [session(.claude)])
        let row = try XCTUnwrap(r.rows.first)
        XCTAssertTrue(row.waiting, "inside the grace window the permission stands")
        XCTAssertFalse(row.yourTurn)
    }

    func testATurnTheUserWatchedFinishIsNotOwed() throws {
        let r = world([line("claude", "turn", ago: 2 * second, front: "1")], harvest: [session(.claude)])
        let row = try XCTUnwrap(r.rows.first)
        XCTAssertFalse(row.yourTurn)
        XCTAssertFalse(row.waiting)
        XCTAssertEqual(r.snapshot.turnCount, 0)
    }

    func testASubmittedPromptEndsYourTurn() throws {
        let r = world([
            line("claude", "stop", ago: 30 * second),
            line("claude", "done", ago: 2 * second),
        ], harvest: [session(.claude)])
        XCTAssertFalse(try XCTUnwrap(r.rows.first).yourTurn)
    }

    func testWorkResumingEndsYourTurn() throws {
        // A tool call after the turn ended: the session moved on.
        let tool = ActivitySpool.Event(
            agent: "claude", session: "s1", event: "tool", tool: "Edit", target: "a.swift",
            prompt: "", cwd: "/p", tsMs: now - 5 * second
        )
        let moved = world([line("claude", "stop", ago: 30 * second)], harvest: [session(.claude)], activity: [tool])
        XCTAssertFalse(try XCTUnwrap(moved.rows.first).yourTurn)

        // The transcript growing well after the turn ended: the same.
        let grew = world([line("claude", "stop", ago: 60 * second)], harvest: [session(.claude, ageMs: 10 * second)])
        XCTAssertFalse(try XCTUnwrap(grew.rows.first).yourTurn)

        // The vendor's own last write right after Stop is not new work.
        let settled = world([line("claude", "stop", ago: 60 * second)], harvest: [session(.claude, ageMs: 55 * second)])
        XCTAssertTrue(try XCTUnwrap(settled.rows.first).yourTurn)
    }

    func testAFinishedTurnNeverInventsARow() {
        let r = world([line("claude", "stop", ago: 5 * second, session: "unknown")], harvest: [])
        XCTAssertTrue(r.rows.isEmpty, "a row made only of 'it finished' would have no other evidence")
    }

    // MARK: - Codex

    func testACodexTurnCompleteIsYourTurn() throws {
        let r = world([line("codex", "agent-turn-complete", ago: 10 * second)], harvest: [session(.codex)])
        let row = try XCTUnwrap(r.rows.first)
        XCTAssertTrue(row.yourTurn)
        XCTAssertFalse(row.waiting)
    }

    func testACodexApprovalIsRed() throws {
        let r = world([line("codex", "exec_approval_request", ago: 3 * second, message: "git push")],
                      harvest: [session(.codex)])
        XCTAssertTrue(try XCTUnwrap(r.rows.first).waiting)
        XCTAssertEqual(r.snapshot.glance, .waiting)
    }

    // MARK: - Presence

    func testABlockedPromptAlreadyInFrontLightsTheLampButRaisesNoBanner() throws {
        let r = world([line("claude", "permission", ago: 2 * second, message: "Bash: ls", front: "1")],
                      harvest: [session(.claude)])
        let row = try XCTUnwrap(r.rows.first)
        XCTAssertTrue(row.waiting)
        XCTAssertTrue(row.waitRaisedInFront)
        XCTAssertEqual(r.snapshot.glance, .waiting, "the lamp still says it")
        XCTAssertEqual(delivery(r.rows), .nothing, "the user is looking at it")
    }

    func testUnknownPresenceNeverSilencesABanner() throws {
        let r = world([line("claude", "permission", ago: 2 * second, message: "Bash: ls", front: "")],
                      harvest: [session(.claude)])
        XCTAssertFalse(try XCTUnwrap(r.rows.first).waitRaisedInFront)
        if case .post = delivery(r.rows) {} else { XCTFail("not knowing is not proof the user is looking") }
    }

    // MARK: - The receiver

    func testTheReceiverWritesTheV3Kinds() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-turn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        AttentionIO.pathOverride = home.appendingPathComponent("attention.tsv")
        ActivitySpool.directoryOverride = home.appendingPathComponent("activity.d", isDirectory: true)
        defer {
            AttentionIO.pathOverride = nil
            ActivitySpool.directoryOverride = nil
            try? FileManager.default.removeItem(at: home)
        }
        XCTAssertEqual(PulseHookReceiver.parseKind(from: ["hook_event_name": "Stop"]), "turn")
        XCTAssertEqual(PulseHookReceiver.parseKind(from: ["hook_event_name": "SubagentStop"]), "subagent_stop")

        // The installed Claude Stop hook passes `stop` explicitly.
        PulseHookReceiver.run(arguments: ["PulseBar", "--hook", "claude", "stop"],
                              stdin: #"{"session_id":"s1","cwd":"/p","last_assistant_message":"All tests pass."}"#)
        PulseHookReceiver.run(arguments: ["PulseBar", "--hook", "claude", "prompt"],
                              stdin: #"{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/p","prompt":"next"}"#)
        let lines = try String(contentsOf: AttentionIO.path, encoding: .utf8)
            .split(separator: "\n").filter { !$0.hasPrefix("#") }.map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
        XCTAssertEqual(lines.map { String($0[1]) }, ["turn", "done"])
        XCTAssertTrue(lines.allSatisfy { $0.count == AttentionProtocol.columnCount })
        XCTAssertEqual(String(lines[0][3]), "All tests pass.")
    }

    func testAnOlderHooksIdlePromptLineReadsAsYourTurn() {
        // Documented v3 break: a pre-16.0 hook wrote `idle_prompt` for both
        // Claude's timer and a question. The timer is by far the common case.
        let entries = AttentionReader.parse(
            AttentionProtocol.headerV1 + line("claude", "idle_prompt", ago: 2 * second) + "\n", nowMs: now
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].isTurn)
    }

    func testEveryKindHasOneMeaning() {
        for kind in AttentionKind.allCases {
            XCTAssertEqual(AttentionProtocol.kind(kind.rawValue), kind)
        }
        XCTAssertEqual(AttentionKind.allCases.filter(\.isBlocking), [.permission, .question, .waiting])
        XCTAssertFalse(AttentionKind.turn.isBlocking)
        XCTAssertTrue(AttentionKind.turn.isOpen)
    }
}
