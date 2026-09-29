import Foundation
import Testing
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

/// 16.0 · Turn — vendor event sequences, from the attention file to the lamp.
///
/// 18.0: Swift Testing. Every sequence is one row of `TurnTruthTests.cases`
/// and one named test in the report, so a failing vendor order reads as
/// "claude · finished turn → your turn, not red" rather than as one assertion
/// buried in a hundred-line method. Each row is a sequence of lines exactly as
/// the hooks write them, read by the real reader and merged by the real
/// builder; the expectations are what the user would see.
@Suite("Turn truth table", .serialized)
struct TurnTruthTests {
    static let now: Int64 = 1_800_000_000_000
    static let second: Int64 = 1_000

    static func line(
        _ agent: String, _ kind: String, ago: Int64, message: String = "",
        session: String = "s1", cwd: String = "/p", front: String? = nil
    ) -> String {
        // v3: all eight columns; host empty, front as given (empty = unknown).
        let cols = [agent, kind, "\(now - ago)", message, session, cwd, "", front ?? ""]
        return cols.joined(separator: "\t")
    }

    static func session(_ id: AgentID, _ session: String = "s1", ageMs: Int64 = 70_000) -> ActivityHarvest.Row {
        ActivityHarvest.Row(
            id: id, task: "Fix the login flow", project: "p", cwd: "/p", skill: "",
            tool: "", harvestMs: now - ageMs, subRunning: 0, subTotal: 0, sessionID: session,
            evidence: .session
        )
    }

    static func world(
        _ lines: [String],
        harvest: [ActivityHarvest.Row],
        activity: [ActivitySpool.Event] = []
    ) -> SnapshotBuilder.Result {
        let text = AttentionProtocol.header + lines.joined(separator: "\n") + "\n"
        let entries = AttentionReader.parse(text, nowMs: now)
        return SnapshotBuilder.build(
            SnapshotBuilder.Input(procs: [], harvest: harvest, attention: entries, activity: activity),
            previous: .init(),
            context: SnapshotBuilder.Context(
                nowMs: now,
                terminal: TerminalFocus.Environment(warpRunning: false, ttyHostRunning: false),
                lang: .en,
                maxSessionsPerAgent: SnapshotBuilder.maxSessionsPerAgent,
                maxVisibleRows: SnapshotBuilder.maxVisibleRows,
                dismissedPendingKeys: [],
                showAllAgents: false,
                stalledSeconds: AgentRow.stalledSeconds
            )
        )
    }

    static func delivery(_ rows: [AgentRow]) -> WaitingDelivery.Plan {
        WaitingDelivery(
            muted: [], acknowledged: [], inFlight: [], canDeliverNow: true,
            msSinceLastNotification: 60_000, minimumIntervalMs: 0
        ).plan(rows)
    }

    // MARK: - The table

    /// What the user should see after a sequence.
    struct Expect: Sendable {
        var waiting: Bool
        var yourTurn: Bool
        var red: Bool
        var banner: Bool
        var waitKind: String? = nil
        var inFront: Bool = false
    }

    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var lines: [String]
        var agent: AgentID = .claude
        var harvestAgeMs: Int64 = 70_000
        var expect: Expect
        var testDescription: String { name }
    }

    static let blocked = Expect(waiting: true, yourTurn: false, red: true, banner: true)
    static let turn = Expect(waiting: false, yourTurn: true, red: false, banner: false)
    static let quiet = Expect(waiting: false, yourTurn: false, red: false, banner: false)

    static let cases: [Case] = [
        Case(
            name: "claude · finished turn, idle_prompt a minute later → your turn, not red",
            lines: [
                line("claude", "permission", ago: 180 * second, message: "Bash: npm test"),
                line("claude", "stop", ago: 61 * second),
                line("claude", "idle_prompt", ago: 1 * second),
            ],
            expect: turn
        ),
        Case(
            name: "claude · permission → red, banner",
            lines: [line("claude", "permission", ago: 5 * second, message: "Bash: rm -rf build")],
            expect: Expect(waiting: true, yourTurn: false, red: true, banner: true, waitKind: "Permission")
        ),
        Case(
            name: "claude · elicitation question → red, says Input",
            lines: [line("claude", "elicitation_dialog", ago: 5 * second, message: "Which database?")],
            expect: Expect(waiting: true, yourTurn: false, red: true, banner: true, waitKind: "Input")
        ),
        Case(
            name: "claude · URL elicitation (18.0) → red, says Input",
            lines: [line("claude", "elicitation_url_dialog", ago: 5 * second, message: "Sign in to continue")],
            expect: Expect(waiting: true, yourTurn: false, red: true, banner: true, waitKind: "Input")
        ),
        Case(
            name: "claude · turn ends moments after a permission → the permission stands",
            lines: [
                line("claude", "permission", ago: 6 * second, message: "Bash: npm run build"),
                line("claude", "stop", ago: 1 * second),
            ],
            expect: blocked
        ),
        Case(
            name: "claude · turn watched finishing (front = 1) → nothing owed",
            lines: [line("claude", "turn", ago: 2 * second, front: "1")],
            expect: quiet
        ),
        Case(
            name: "claude · submitted prompt after a turn → cleared",
            lines: [line("claude", "stop", ago: 30 * second), line("claude", "done", ago: 2 * second)],
            expect: quiet
        ),
        Case(
            name: "claude · transcript grew well after the turn → work resumed",
            lines: [line("claude", "stop", ago: 60 * second)],
            harvestAgeMs: 10 * second,
            expect: quiet
        ),
        Case(
            name: "claude · vendor's last write right after Stop → still your turn",
            lines: [line("claude", "stop", ago: 60 * second)],
            harvestAgeMs: 55 * second,
            expect: turn
        ),
        Case(
            name: "claude · StopFailure (18.0) → your turn, never red",
            lines: [line("claude", "stop_failure", ago: 10 * second, message: "rate_limit")],
            expect: turn
        ),
        Case(
            name: "codex · agent-turn-complete → your turn",
            lines: [line("codex", "agent-turn-complete", ago: 10 * second)],
            agent: .codex,
            expect: turn
        ),
        Case(
            name: "codex · exec approval → red",
            lines: [line("codex", "exec_approval_request", ago: 3 * second, message: "git push")],
            agent: .codex,
            expect: blocked
        ),
        Case(
            name: "presence · blocked prompt already in front → lamp, no banner",
            lines: [line("claude", "permission", ago: 2 * second, message: "Bash: ls", front: "1")],
            expect: Expect(waiting: true, yourTurn: false, red: true, banner: false, inFront: true)
        ),
        Case(
            name: "presence · unknown → banner as usual",
            lines: [line("claude", "permission", ago: 2 * second, message: "Bash: ls", front: "")],
            expect: blocked
        ),
        Case(
            name: "legacy · an older hook's idle_prompt line reads as your turn",
            lines: [line("claude", "idle_prompt", ago: 2 * second)],
            expect: turn
        ),
    ]

    @Test(arguments: cases)
    func sequence(_ c: Case) throws {
        let r = Self.world(c.lines, harvest: [Self.session(c.agent, ageMs: c.harvestAgeMs)])
        let row = try #require(r.rows.first)
        #expect(row.isBlocked == c.expect.waiting)
        #expect(row.isYourTurn == c.expect.yourTurn)
        #expect((r.snapshot.glance == .waiting) == c.expect.red)
        #expect(r.snapshot.turnCount == (c.expect.yourTurn ? 1 : 0))
        #expect((row.wait?.inFront ?? false) == c.expect.inFront)
        if let kind = c.expect.waitKind { #expect(row.wait?.kind == kind) }
        let bannered: Bool
        if case .post(let rows, _) = Self.delivery(r.rows) {
            bannered = rows.contains { $0.rowKey == row.rowKey }
        } else {
            bannered = false
        }
        #expect(bannered == c.expect.banner)
    }

    // MARK: - Beyond the table

    @Test func aToolCallAfterTheTurnEndsYourTurn() throws {
        let tool = ActivitySpool.Event(
            agent: "claude", session: "s1", event: "tool", tool: "Edit", target: "a.swift",
            prompt: "", cwd: "/p", tsMs: Self.now - 5 * Self.second
        )
        let r = Self.world([Self.line("claude", "stop", ago: 30 * Self.second)], harvest: [Self.session(.claude)], activity: [tool])
        let row = try #require(r.rows.first)
        #expect(!row.isYourTurn)
    }

    @Test func aFinishedTurnNeverInventsARow() {
        let r = Self.world([Self.line("claude", "stop", ago: 5 * Self.second, session: "unknown")], harvest: [])
        #expect(r.rows.isEmpty, "a row made only of 'it finished' would have no other evidence")
    }

    @Test func theReceiverWritesTheV3Kinds() throws {
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
        #expect(PulseHookReceiver.parseKind(from: ["hook_event_name": "Stop"]) == "turn")
        #expect(PulseHookReceiver.parseKind(from: ["hook_event_name": "StopFailure"]) == "stop_failure")
        #expect(PulseHookReceiver.parseKind(from: ["hook_event_name": "SubagentStop"]) == "subagent_stop")

        // The installed Claude Stop hook passes `stop` explicitly.
        PulseHookReceiver.run(arguments: ["PulseBar", "--hook", "claude", "stop"],
                              stdin: #"{"session_id":"s1","cwd":"/p","last_assistant_message":"All tests pass."}"#)
        PulseHookReceiver.run(arguments: ["PulseBar", "--hook", "claude", "prompt"],
                              stdin: #"{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/p","prompt":"next"}"#)
        let lines = try String(contentsOf: AttentionIO.path, encoding: .utf8)
            .split(separator: "\n").filter { !$0.hasPrefix("#") }
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
        #expect(lines.map { String($0[1]) } == ["turn", "done"])
        #expect(lines.allSatisfy { $0.count == AttentionProtocol.columnCount })
        #expect(String(lines[0][3]) == "All tests pass.")
    }

    @Test func everyKindHasOneMeaning() {
        for kind in AttentionKind.allCases {
            #expect(AttentionProtocol.kind(kind.rawValue) == kind)
        }
        #expect(AttentionKind.allCases.filter(\.isBlocking) == [.permission, .question, .waiting])
        #expect(!AttentionKind.turn.isBlocking)
        #expect(AttentionKind.turn.isOpen)
    }
}
