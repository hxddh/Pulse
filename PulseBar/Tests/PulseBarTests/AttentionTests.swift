import Foundation
import Testing
import XCTest
@testable import PulseApp
@testable import PulseKit

// Attention: the protocol read into the session book, the hook receiver,
// the event log, the hooks installer.

/// The event log as the book reads it: every complete v8 line, in order.
final class AttentionBookTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000

    /// v8 lines from rows written `agent kind ms message session cwd front
    /// pid landing tool sub` (missing trailing fields empty), numbered
    /// from 1.
    static func tsv(_ rows: [[String]]) -> String {
        rows.enumerated().map { index, row in
            let c = row + Array(repeating: "", count: max(0, 11 - row.count))
            return [String(index + 1), c[2], c[0], c[1], "", c[4], c[10], c[5], c[7], c[6], c[8], c[9], "", "", c[3]]
                .joined(separator: "\t")
        }.joined(separator: "\n") + "\n"
    }

    private func tsv(_ rows: [[String]]) -> String { Self.tsv(rows) }

    private func book(_ text: String) -> SessionBook {
        var book = SessionBook()
        for line in text.split(whereSeparator: \.isNewline) {
            if let record = AttentionRecord(line: line) { book.apply(record, nowMs: now) }
        }
        return book
    }

    private func state(_ book: SessionBook, _ key: SessionKey) -> String {
        HookFeed.word(book.sessions[key]?.state)
    }

    private func block(_ book: SessionBook, _ key: SessionKey) -> Block? {
        if case .blocked(let block) = book.sessions[key]?.state { return block }
        return nil
    }

    func testTheLatestEventDecidesTheSession() {
        let b = book(tsv([
            ["claude", "permission", "\(now - 5000)", "first", "s1", "/p"],
            ["claude", "question", "\(now - 1000)", "second", "s1", "/p"],
        ]))
        XCTAssertEqual(state(b, SessionKey(.claude, "s1")), "blocked:question")
        XCTAssertEqual(block(b, SessionKey(.claude, "s1"))?.ask, "second")
    }

    func testDoneAnswersTheSession() {
        let b = book(tsv([
            ["claude", "permission", "\(now - 5000)", "approve", "s1", "/p"],
            ["claude", "done", "\(now - 1000)", "", "s1", ""],
        ]))
        XCTAssertEqual(state(b, SessionKey(.claude, "s1")), "working")
    }

    /// A `done` clears exactly what it names: an empty session, only the
    /// session-less entries — never every session of that agent.
    func testASessionlessDoneClearsOnlyTheSessionlessEntry() {
        let b = book(tsv([
            ["claude", "permission", "\(now - 5000)", "a", "s1", "/p"],
            ["claude", "permission", "\(now - 4000)", "b", "s2", "/q"],
            ["claude", "permission", "\(now - 3000)", "c", "", "/r"],
            ["claude", "done", "\(now - 1000)", "", "", ""],
        ]))
        XCTAssertEqual(state(b, SessionKey(.claude, "s1")), "blocked:permission", "the sessions' own waits stay")
        XCTAssertEqual(state(b, SessionKey(.claude, "s2")), "blocked:permission")
        XCTAssertEqual(state(b, SessionKey(.claude, "", cwd: "/r")), "working")
    }

    /// A dismissal's `done` names the row's folder: it clears the
    /// session-less wait in that folder and leaves the agent's session-less
    /// wait in another folder red.
    func testASessionlessDoneWithAFolderClearsOnlyThatFolder() {
        let b = book(tsv([
            ["copilot", "permission", "\(now - 5000)", "a", "", "/r"],
            ["copilot", "permission", "\(now - 4000)", "b", "", "/q"],
            ["copilot", "done", "\(now - 1000)", "", "", "/r"],
        ]))
        XCTAssertEqual(state(b, SessionKey(.copilot, "", cwd: "/r")), "working")
        XCTAssertEqual(state(b, SessionKey(.copilot, "", cwd: "/q")), "blocked:permission")
    }

    /// The steps: the last five tool lines that name a tool, oldest first,
    /// rebuilt by replaying the log; a tool line with no tool (Cursor,
    /// OpenCode activity) is no step.
    func testTheLastFiveToolStepsAreKept() throws {
        var rows = [["claude", "working", "\(now - 60_000)", "Fix the login test", "s1", "/p"]]
        for index in 0..<7 {
            rows.append(["claude", "tool", "\(now - 50_000 + Int64(index) * 1000)", "target \(index)", "s1", "/p", "", "", "", "Tool\(index)"])
        }
        rows.append(["claude", "tool", "\(now - 1000)", "", "s1", "/p"])
        let session = try XCTUnwrap(book(tsv(rows)).sessions[SessionKey(.claude, "s1")])
        XCTAssertEqual(session.steps.map(\.tool), ["Tool2", "Tool3", "Tool4", "Tool5", "Tool6"])
        XCTAssertEqual(session.steps.last?.target, "target 6")
        XCTAssertEqual(session.steps.last?.ms, now - 44_000)
        XCTAssertEqual(session.turnStartMs, now - 60_000, "the prompt started the turn")
        XCTAssertEqual(session.title, "Fix the login test")
        XCTAssertEqual(session.lastPrompt, "Fix the login test")
    }

    /// The title is the first prompt that says something; "continue" is
    /// the latest prompt, never the title. A new prompt starts a new turn.
    func testTheTitleIsTheFirstMeaningfulPrompt() throws {
        let b = book(tsv([
            ["codex", "working", "\(now - 9000)", "继续", "x1", "/p"],
            ["codex", "working", "\(now - 8000)", "Port the parser to Swift", "x1", "/p"],
            ["codex", "turn", "\(now - 5000)", "Ported.", "x1", "/p"],
            ["codex", "working", "\(now - 2000)", "continue", "x1", "/p"],
        ]))
        let session = try XCTUnwrap(b.sessions[SessionKey(.codex, "x1")])
        XCTAssertEqual(session.title, "Port the parser to Swift")
        XCTAssertEqual(session.lastPrompt, "continue")
        XCTAssertEqual(session.turnStartMs, now - 2000)
        XCTAssertEqual(session.message, "Ported.", "the last words stay until the next turn says something")
    }

    /// A `failed` turn is the session's last error — its last words are
    /// left alone — until the next prompt.
    func testAFailedTurnIsTheLastErrorUntilTheNextPrompt() throws {
        let failed = tsv([
            ["claude", "turn", "\(now - 9000)", "All green.", "s1", "/p"],
            ["claude", "working", "\(now - 8000)", "Ship it", "s1", "/p"],
            ["claude", "failed", "\(now - 5000)", "API Error: Rate limit reached", "s1", "/p"],
        ])
        let session = try XCTUnwrap(book(failed).sessions[SessionKey(.claude, "s1")])
        XCTAssertEqual(session.lastError, "API Error: Rate limit reached")
        XCTAssertEqual(session.message, "All green.")
        XCTAssertEqual(HookFeed.word(session.state), "turn", "a failed turn is your turn, never red")
        let next = failed + tsv([["claude", "working", "\(now - 1000)", "Try again", "s1", "/p"]])
        XCTAssertEqual(book(next).sessions[SessionKey(.claude, "s1")]?.lastError, "")
    }

    func testStopKeepsAFreshPermissionWithinGrace() {
        // The order of Claude's events is not ours; a turn ending moments
        // after a permission was raised must not wipe it.
        let b = book(tsv([
            ["claude", "permission", "\(now - 1000)", "approve", "s1", "/p"],
            ["claude", "turn", "\(now)", "", "s1", ""],
        ]))
        XCTAssertEqual(state(b, SessionKey(.claude, "s1")), "blocked:permission", "recent permission survives a Stop")
    }

    func testStopClearsAnAgedPermissionAndLeavesYourTurn() {
        let old = now - SessionBook.stopGraceMs - 5000
        let b = book(tsv([
            ["claude", "permission", "\(old)", "approve", "s1", "/p"],
            ["claude", "turn", "\(now)", "", "s1", ""],
        ]))
        XCTAssertEqual(state(b, SessionKey(.claude, "s1")), "turn", "the permission is gone; what is left is not red")
    }

    /// A wait whose process Pulse cannot see is not red forever: past the
    /// idle bound it is shown as recent (the projection's rule).
    func testAnUnprovableWaitGoesQuietAfterTheIdleBound() throws {
        let b = book(tsv([["claude", "permission", "\(now - 1000)", "old", "s1", "/p"]]))
        let session = try XCTUnwrap(b.sessions[SessionKey(.claude, "s1")])
        XCTAssertEqual(
            TrayState.status(of: session, nowMs: now),
            .needsYou(Block(kind: .permission, ask: "old", sinceMs: now - 1000, tool: "old"))
        )
        XCTAssertEqual(TrayState.status(of: session, nowMs: now + TrayState.idleBoundMs + 1), .recent(.quiet))
    }

    func testUnknownKindNeverRaisesWaiting() {
        XCTAssertTrue(book(tsv([["claude", "subagent_start", "\(now)", "", "s1", "/p"]])).sessions.isEmpty)
        let b = book(tsv([["copilot", "totally_fake_kind", "\(now)", "nope", "s1", "/p"]]))
        XCTAssertTrue(b.sessions.isEmpty, "free-text kinds must never light Waiting")
    }

    func testProtocolHeaderIsIgnoredAsComment() {
        let b = book(AttentionProtocol.Header(next: 1, gen: "g1").line + tsv([
            ["copilot", "waiting", "\(now - 1000)", "Need choice", "j1", "/w"],
        ]))
        XCTAssertEqual(Array(b.sessions.keys), [SessionKey(.copilot, "j1")])
        XCTAssertEqual(state(b, SessionKey(.copilot, "j1")), "blocked:waiting")
    }

    func testCommentsAndShortRowsAreSkipped() {
        XCTAssertTrue(book("# header\nclaude\tpermission\n\n").sessions.isEmpty)
    }

    /// v8 is exactly fifteen columns, with a positive `seq`. A shorter
    /// line (a v7 line of twelve), a longer one, or one without a number is
    /// not read.
    func testALineWithAnotherColumnCountIsNotRead() throws {
        let v8 = "7\t\(now - 1000)\tclaude\tpermission\tPermissionRequest\ts1\t\t/p\t4242\t\ttmux:%3\tBash\t\t\tBash: ls\n"
        let v7 = "7\t\(now - 1000)\tclaude\tpermission\tPermissionRequest\ts1\t/p\t4242\t\ttmux:%3\tBash\tBash: ls\n"
        let long = "7\t\(now - 1000)\tclaude\tpermission\tPermissionRequest\ts1\t\t/p\t4242\t\ttmux:%3\tBash\t\t\tBash: ls\t\n"
        let unnumbered = "0\t\(now - 1000)\tclaude\tpermission\tPermissionRequest\ts1\t\t/p\t4242\t\ttmux:%3\tBash\t\t\tBash: ls\n"
        XCTAssertTrue(book(v7).sessions.isEmpty, "a v7 line is not read")
        XCTAssertTrue(book(long).sessions.isEmpty)
        XCTAssertTrue(book(unnumbered).sessions.isEmpty)
        let session = try XCTUnwrap(book(v8).sessions[SessionKey(.claude, "s1")])
        XCTAssertEqual(session.pid, 4242)
        XCTAssertEqual(session.landing, "tmux:%3")
        XCTAssertEqual(block(book(v8), SessionKey(.claude, "s1"))?.tool, "Bash")
        XCTAssertEqual(block(book(v8), SessionKey(.claude, "s1"))?.ask, "Bash: ls")
    }

    /// A hand-written blocked line for an agent whose hooks cannot
    /// report a block is not a wait; its turn still is its turn.
    func testAWaitingNoneAgentIsNeverBlockedByALine() {
        let b = book(tsv([
            ["codex", "permission", "\(now - 3000)", "approve", "x1", "/p"],
            ["cursor", "question", "\(now - 2000)", "which?", "c1", "/p"],
            ["codex", "turn", "\(now - 1000)", "", "x2", "/p"],
        ]))
        XCTAssertEqual(Array(b.sessions.keys), [SessionKey(.codex, "x2")])
        XCTAssertEqual(state(b, SessionKey(.codex, "x2")), "turn")
    }

    /// The lifecycle kinds each say what the session does next.
    func testStartWorkingAndEndAfterATurn() {
        let expected = ["start": "idle", "working": "working", "end": "ended"]
        for (kind, word) in expected {
            let b = book(tsv([
                ["claude", "turn", "\(now - 5000)", "", "s1", "/p"],
                ["claude", kind, "\(now - 1000)", "", "s1", "/p"],
            ]))
            XCTAssertEqual(state(b, SessionKey(.claude, "s1")), word, kind)
        }
    }

    func testALaterSilentEventDoesNotEraseTheReason() throws {
        // One approval makes Claude raise both Notification and
        // PermissionRequest; only one carries text and the order is not ours.
        let b = book(tsv([
            ["claude", "permission", "\(now - 2000)", "Bash: npm run build", "c1", "/w"],
            ["claude", "permission", "\(now - 1000)", "", "c1", "/w"],
        ]))
        let wait = try XCTUnwrap(block(b, SessionKey(.claude, "c1")))
        XCTAssertEqual(wait.ask, "Bash: npm run build")
        XCTAssertEqual(wait.sinceMs, now - 2000, "a same-kind re-raise inside the grace is the same block — the first raise owns the clock")
    }
}

final class PulseHookReceiverTests: XCTestCase {
    private var tempHome: URL!
    /// This test's own event log — an explicit file, never a global
    /// override (suites run in parallel).
    private var log: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-hook-recv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        log = tempHome.appendingPathComponent(EventLog.fileName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    /// A fixed answer for the agent pid and landing handles.
    private let located: (AgentID, [String: String]) -> (pid: Int32, landing: String) = { _, _ in
        (4242, "tmux:%3;tty:/dev/ttys004")
    }

    /// Run one vendor event through the receiver, as its installed hook does.
    /// `argv`: the agent process's arguments, as the receiver would read
    /// them — never this Mac's real process table.
    @discardableResult
    private func deliver(
        _ agent: String, _ event: String, _ payload: String,
        locate: ((AgentID, [String: String]) -> (pid: Int32, landing: String))? = nil,
        argv: [String]? = nil
    ) -> Int32 {
        var arguments = ["PulseBar", "--hook", agent]
        if !event.isEmpty { arguments.append(event) }
        return PulseHookReceiver.run(
            arguments: arguments, stdin: payload, logURL: log, locate: locate ?? located,
            argumentsOf: { _, _ in argv }
        )
    }

    /// Every line the receiver wrote, `ignored` ones too.
    private func heard() -> [AttentionRecord] {
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { AttentionRecord(line: $0) }
    }

    /// The lines that are state.
    private func records() -> [AttentionRecord] {
        heard().filter { $0.kind != .ignored }
    }

    /// Why each ignored line was ignored.
    private func ignored() -> [String] {
        heard().filter { $0.kind == .ignored }.map(\.message)
    }

    /// Everything but activity.
    private func blocksAndTurns() -> [AttentionRecord] {
        records().filter { !$0.kind.isActivity }
    }

    private func kinds() -> [String] {
        blocksAndTurns().map(\.kind.rawValue)
    }

    // MARK: - The protocol's own words

    /// A line's kind is one of the v8 kinds, spelled as written — no alias,
    /// no vendor word, no guess.
    func testTheLogReadsOnlyTheV8Kinds() {
        for kind in AttentionKind.allCases {
            XCTAssertEqual(AttentionProtocol.kind(kind.rawValue), kind)
        }
        for word in ["stop", "idle_prompt", "elicitation_dialog", "permission_prompt", "agent-turn-complete",
                     "exec_approval_request", "activity", "Permission", " turn", ""] {
            XCTAssertNil(AttentionProtocol.kind(word), word)
        }
        XCTAssertNotEqual(AttentionProtocol.kind("idle")?.isBlocking, true,
                          "Claude's idle_prompt is a 60 s timer after every finished turn — not a block")
    }

    /// v8: fifteen columns — `seq ms agent kind event session sub cwd pid
    /// front landing tool err took message` — and a record survives its own
    /// line.
    func testAV8RecordRoundTrips() throws {
        let record = AttentionRecord(
            agent: .claude, kind: .permission, ms: 1_800_000_000_000,
            message: "Bash: npm test", session: "s1", cwd: "/w", front: false,
            pid: 4242, landing: "tmux:%3;tty:/dev/ttys004", tool: "Bash", event: "PermissionRequest", seq: 42,
            sub: "agent-7"
        )
        let columns = record.line.split(separator: "\t", omittingEmptySubsequences: false)
        XCTAssertEqual(columns.count, AttentionProtocol.columnCount)
        XCTAssertEqual(columns.map(String.init), [
            "42", "1800000000000", "claude", "permission", "PermissionRequest", "s1", "agent-7", "/w", "4242", "0",
            "tmux:%3;tty:/dev/ttys004", "Bash", "", "", "Bash: npm test",
        ])
        XCTAssertEqual(AttentionRecord(line: record.line), record)
        let step = AttentionRecord(agent: .pi, kind: .tool, ms: 1, message: "swift test", session: "p1", tool: "bash", seq: 3, failed: true, tookMs: 1500)
        let stepColumns = step.line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(stepColumns[12], "1", "err")
        XCTAssertEqual(stepColumns[13], "1500", "took")
        XCTAssertEqual(AttentionRecord(line: step.line), step)
        XCTAssertEqual(AttentionRecord(line: "1\t1\tpi\ttool\t\tp\t\t/p\t\t\t\tbash\tyes\t-4\tls")?.failed, false, "only 1 is a failure")
        XCTAssertEqual(AttentionRecord(line: "1\t1\tpi\ttool\t\tp\t\t/p\t\t\t\tbash\tyes\t-4\tls")?.tookMs, 0, "a duration is positive")
        let unknown = AttentionRecord(agent: .codex, kind: .turn, ms: 1, seq: 1)
        XCTAssertEqual(AttentionRecord(line: unknown.line), unknown, "empty columns stay empty")
        XCTAssertNil(AttentionRecord(line: AttentionRecord(agent: .codex, kind: .turn, ms: 1).line), "a line with no seq is not read")
        XCTAssertNil(AttentionRecord(line: "1\t1\tclaude\tpermission\t\ts\t\t/p\t\t\t\t\t\tx"), "a fourteen-column line is not read")
        XCTAssertNil(AttentionRecord(line: "1\t1\tgoose\tpermission\t\ts\t\t/p\t\t\t\t\t\t\tx"), "an unknown agent is not read")
        XCTAssertEqual(AttentionRecord(line: "1\t1\tcursor-agent\tturn\tstop\ts\t\t/p\t\t\t\t\t\t\t")?.agent, .cursor, "an alias reads as its agent")
        let header = AttentionProtocol.Header(next: 43, gen: "g42")
        XCTAssertTrue(header.line.hasPrefix("# pulse-events v8 next=43 gen=g42 "))
        XCTAssertTrue(header.line.hasSuffix("\n"))
        XCTAssertEqual(AttentionProtocol.Header(line: header.line.trimmingCharacters(in: .newlines)), header)
        XCTAssertNil(AttentionProtocol.Header(line: "# pulse-events v7 next=43 gen=g42 (seq)"), "a v7 log has no v8 header")
        XCTAssertNil(AttentionProtocol.Header(line: "# pulse-events v8 gen=g42"), "a header names its next seq")
        XCTAssertEqual(AttentionProtocol.kind("tool"), .tool)
        XCTAssertFalse(AttentionKind.tool.isOpen)
        XCTAssertTrue(AttentionKind.failed.isOpen)
        XCTAssertFalse(AttentionKind.ignored.isOpen)
    }

    // MARK: - Claude (code.claude.com/docs/en/hooks)

    func testClaudePermissionRequestIsABlockThatNamesTheAsk() throws {
        deliver("claude", "PermissionRequest", #"""
        {"session_id":"c9","transcript_path":"/Users/me/.claude/projects/w/c9.jsonl","cwd":"/w",
         "permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"Bash",
         "tool_input":{"command":"npm run build","description":"Build"}}
        """#)
        let record = try XCTUnwrap(records().first)
        XCTAssertEqual(record.kind, .permission)
        XCTAssertEqual(record.event, "PermissionRequest", "the vendor's own event name")
        XCTAssertEqual(record.seq, 1, "the first line of a new log")
        XCTAssertEqual(record.message, "Bash: npm run build")
        XCTAssertEqual(record.session, "c9")
        XCTAssertEqual(record.cwd, "/w")
        XCTAssertFalse(try String(contentsOf: log, encoding: .utf8).contains("c9.jsonl"), "a transcript path is never written")
        XCTAssertEqual(record.pid, 4242)
        XCTAssertEqual(record.landing, "tmux:%3;tty:/dev/ttys004")
    }

    func testClaudeAskUserQuestionIsAQuestion() {
        deliver("claude", "PermissionRequest", #"{"session_id":"c1","cwd":"/w","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{}}"#)
        XCTAssertEqual(kinds(), ["question"])
    }

    /// The question itself, not the tool's name — and the tool
    /// column says which tool will answer it.
    func testClaudeAskUserQuestionSaysTheQuestion() throws {
        deliver("claude", "PermissionRequest", #"""
        {"session_id":"c2","cwd":"/w","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion",
         "tool_input":{"questions":[{"question":"Which database should the cache use?","header":"DB",
         "options":[{"label":"Redis"},{"label":"SQLite"}],"multiSelect":false}]}}
        """#)
        deliver("claude", "PermissionRequest", ##"""
        {"session_id":"c3","cwd":"/w","hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode",
         "tool_input":{"plan":"\n## Move the cache to Redis\n1. Add the client"}}
        """##)
        let question = try XCTUnwrap(records().first { $0.session == "c2" })
        XCTAssertEqual(question.kind, .question)
        XCTAssertEqual(question.message, "Which database should the cache use?")
        XCTAssertEqual(question.tool, "AskUserQuestion")
        let plan = try XCTUnwrap(records().first { $0.session == "c3" })
        XCTAssertEqual(plan.kind, .permission)
        XCTAssertEqual(plan.message, "Move the cache to Redis")
        XCTAssertEqual(Claude.planSummary("\n## Move the cache\n- step"), "Move the cache")
    }

    func testClaudeNotificationTypesMapByMeaning() {
        func note(_ type: String) {
            deliver("claude", "Notification", #"{"session_id":"n-\#(type)","cwd":"/w","hook_event_name":"Notification","message":"Claude needs your input","notification_type":"\#(type)"}"#)
        }
        note("permission_prompt")
        note("elicitation_dialog")
        note("agent_needs_input")
        note("idle_prompt")
        note("auth_success")
        XCTAssertEqual(kinds(), ["permission", "question", "idle"])
        XCTAssertEqual(ignored(), [
            PulseHookReceiver.Ignored.otherSession.rawValue,
            PulseHookReceiver.Ignored.silent.rawValue,
        ], "agent_needs_input may be another session's wait (agent view, a teammate, a billing notice); auth_success says nothing Pulse shows — each says so")
    }

    /// A permission request nobody can be shown — `dontAsk`, or `claude -p`
    /// without a permission host — is denied by Claude itself: an ignored
    /// line, never a red lamp. A `-p` run with `--permission-prompt-tool`
    /// (an SDK host) does ask.
    func testClaudeRequestNobodyCanSeeIsIgnored() {
        let request = #"{"session_id":"p1","cwd":"/w","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#
        let dontAsk = #"{"session_id":"p2","cwd":"/w","hook_event_name":"PermissionRequest","permission_mode":"dontAsk","tool_name":"Bash","tool_input":{"command":"ls"}}"#
        deliver("claude", "PermissionRequest", dontAsk, argv: ["claude"])
        deliver("claude", "PermissionRequest", request, argv: ["claude", "-p", "clean up"])
        deliver("claude", "PermissionRequest", request, argv: ["claude", "--print", "clean up"])
        XCTAssertEqual(kinds(), [])
        XCTAssertEqual(ignored(), Array(repeating: PulseHookReceiver.Ignored.noPrompt.rawValue, count: 3))
        XCTAssertEqual(heard().filter { $0.kind == .ignored }.map(\.session), ["p2", "p1", "p1"], "the session it was about")
        deliver("claude", "PermissionRequest", request, argv: ["claude", "-p", "--permission-prompt-tool", "stdio"])
        deliver("claude", "PermissionRequest", request, argv: ["claude", "--permission-prompt-tool=mcp__host__ask", "-p"])
        deliver("claude", "PermissionRequest", request, argv: ["claude", "--resume"])
        deliver("claude", "PermissionRequest", request, argv: nil)
        XCTAssertEqual(kinds(), ["permission", "permission", "permission", "permission"])
        let rule = AgentID.claude.spec.process
        XCTAssertTrue(rule.cannotPrompt(argv: ["/Users/me/.local/bin/claude", "-p", "hi"]))
        XCTAssertFalse(rule.cannotPrompt(argv: ["claude", "fix -p in the parser"]), "whole arguments only")
        XCTAssertFalse(AgentID.codex.spec.process.cannotPrompt(argv: ["codex", "-p", "work"]), "only an agent that says so")
    }

    /// A tool call that reached Claude as an abort (`is_interrupt`) is the
    /// person stopping the run, not a failed step.
    func testClaudeInterruptedToolIsStopped() throws {
        deliver("claude", "PostToolUseFailure", #"{"session_id":"s1","cwd":"/w","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"sleep 100"},"error":"Interrupted","is_interrupt":true}"#)
        deliver("claude", "PostToolUseFailure", #"{"session_id":"s1","cwd":"/w","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"npm test"},"error":"exit 1","is_interrupt":false}"#)
        XCTAssertEqual(records().map(\.kind), [.stopped, .tool])
        XCTAssertEqual(records().first?.message, "", "no words")
        XCTAssertEqual(records().last?.failed, true)
    }

    /// A step says what ran: an Agent call by its description (else its
    /// type), a Skill by its name, an MCP tool as "server · tool" — the
    /// tool's own name kept whole when the server's is long.
    func testClaudeStepsNameTasksSkillsAndMCPTools() {
        deliver("claude", "PostToolUse", #"{"session_id":"s1","cwd":"/w","tool_name":"Agent","tool_input":{"description":"Find API endpoints","prompt":"Look everywhere","subagent_type":"Explore"}}"#)
        deliver("claude", "PostToolUse", #"{"session_id":"s1","cwd":"/w","tool_name":"Task","tool_input":{"prompt":"Look","subagent_type":"Explore"}}"#)
        deliver("claude", "PostToolUse", #"{"session_id":"s1","cwd":"/w","tool_name":"Skill","tool_input":{"skill":"pdf","args":"report.pdf"}}"#)
        deliver("claude", "PostToolUse", #"{"session_id":"s1","cwd":"/w","tool_name":"mcp__memory__create_entities","tool_input":{"query":"cache"}}"#)
        deliver("claude", "PermissionRequest", #"{"session_id":"s2","cwd":"/w","tool_name":"Agent","tool_input":{"description":"Refactor auth","subagent_type":"general-purpose"}}"#)
        let tools = records().filter { $0.kind == .tool }
        XCTAssertEqual(tools.map(\.tool), ["Agent", "Task", "Skill", "memory · create_entities"])
        XCTAssertEqual(tools.map(\.message), ["Find API endpoints", "Explore", "pdf", "cache"])
        XCTAssertEqual(records().first { $0.kind == .permission }?.message, "Agent: Refactor auth")
        XCTAssertEqual(PulseHookReceiver.toolLabel("Bash"), "Bash")
        XCTAssertEqual(PulseHookReceiver.toolLabel("mcp__"), "mcp__")
        let longServer = "mcp__" + String(repeating: "s", count: 70) + "__download_file_content"
        let label = PulseHookReceiver.toolLabel(longServer)
        XCTAssertTrue(label.hasSuffix(" · download_file_content"), label)
        XCTAssertLessThanOrEqual(label.count, 64)
        XCTAssertEqual(PulseHookReceiver.toolLabel("mcp__x__" + String(repeating: "t", count: 70)).count, 64, "a tool name past the bound is the name alone, bounded")
    }

    /// Auto mode's denial and an automatic compaction are work going on —
    /// status lines with Pulse's own words, no tool column (a status that
    /// names a tool says it runs now) and none of the payload's prose; a
    /// manual `/compact` is the person at the prompt.
    func testClaudeDenialAndCompactionAreStatus() {
        deliver("claude", "PermissionDenied", #"{"session_id":"s1","cwd":"/w","permission_mode":"auto","tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/build"},"reason":"[Irreversible Local Destruction]"}"#)
        deliver("claude", "PostCompact", #"{"session_id":"s1","cwd":"/w","trigger":"auto","compact_summary":"We discussed secrets"}"#)
        deliver("claude", "PostCompact", #"{"session_id":"s1","cwd":"/w","trigger":"manual","compact_summary":"We discussed secrets"}"#)
        let status = records().filter { $0.kind == .status }
        XCTAssertEqual(status.map(\.message), ["auto mode denied Bash", "compacted"])
        XCTAssertEqual(status.map(\.tool), ["", ""])
        XCTAssertEqual(status.map(\.event), ["PermissionDenied", "PostCompact"])
        XCTAssertEqual(ignored(), [PulseHookReceiver.Ignored.silent.rawValue])
        XCTAssertFalse(heard().contains { $0.message.contains("secrets") || $0.message.contains("Irreversible") })
    }

    /// A subagent's own start and end carry its `agent_id` (the line's
    /// sub); one that names none is never the main agent's.
    func testClaudeSubagentLifecycleCarriesItsId() {
        deliver("claude", "SubagentStart", #"{"session_id":"s1","cwd":"/w","agent_id":"agent-abc","agent_type":"Explore"}"#)
        deliver("claude", "SubagentStop", #"{"session_id":"s1","cwd":"/w","agent_id":"agent-abc","agent_type":"Explore","last_assistant_message":"Found 12","background_tasks":[{"id":"t1","type":"shell","status":"running"}]}"#)
        deliver("claude", "SubagentStop", #"{"session_id":"s1","cwd":"/w","agent_type":""}"#)
        XCTAssertEqual(records().map(\.kind), [.start, .turn])
        XCTAssertEqual(records().map(\.sub), ["agent-abc", "agent-abc"])
        XCTAssertEqual(ignored(), [PulseHookReceiver.Ignored.silent.rawValue])
    }

    /// Codex: Interrupt is the person stopping the turn; a subagent's
    /// prompt and its SubagentStop carry its `agent_id` — its own task and
    /// end, never the person's.
    func testCodexInterruptAndSubagents() {
        deliver("codex", "Interrupt", #"{"session_id":"t1","turn_id":"1","cwd":"/w","hook_event_name":"Interrupt","model":"m","permission_mode":"default"}"#)
        deliver("codex", "UserPromptSubmit", #"{"session_id":"t1","turn_id":"2","agent_id":"th-9","agent_type":"worker","cwd":"/w","prompt":"Index the repo"}"#)
        deliver("codex", "SubagentStop", #"{"session_id":"t1","turn_id":"2","agent_id":"th-9","agent_type":"worker","cwd":"/w","stop_hook_active":false,"last_assistant_message":"done"}"#)
        XCTAssertEqual(records().map(\.kind), [.stopped, .working, .turn])
        XCTAssertEqual(records().map(\.sub), ["", "th-9", "th-9"])
        XCTAssertEqual(records().map(\.event), ["Interrupt", "UserPromptSubmit", "SubagentStop"])
    }

    func testClaudeLifecycleAndTurn() {
        deliver("claude", "SessionStart", #"{"session_id":"s1","cwd":"/w","hook_event_name":"SessionStart","source":"startup"}"#)
        deliver("claude", "UserPromptSubmit", #"{"session_id":"s1","cwd":"/w","hook_event_name":"UserPromptSubmit","prompt":"Fix the login"}"#)
        deliver("claude", "PostToolUse", #"{"session_id":"s1","cwd":"/w","hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"/w/a.swift"}}"#)
        deliver("claude", "Stop", #"{"session_id":"s1","cwd":"/w","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"All tests pass."}"#)
        deliver("claude", "SessionEnd", #"{"session_id":"s1","cwd":"/w","hook_event_name":"SessionEnd","reason":"exit"}"#)
        XCTAssertEqual(records().map(\.kind.rawValue), ["start", "working", "tool", "turn", "end"], "one log, every event in order")
        XCTAssertEqual(records().map(\.seq), [1, 2, 3, 4, 5], "numbered in the order the lock granted")
        XCTAssertEqual(records().map(\.event), ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd"])
        XCTAssertEqual(records().first { $0.kind == .turn }?.message, "All tests pass.")
        XCTAssertEqual(records().first { $0.kind == .working }?.message, "Fix the login", "the prompt is the title's source")
        let tool = try? XCTUnwrap(records().first { $0.kind == .tool })
        XCTAssertEqual(tool?.tool, "Edit")
        XCTAssertEqual(tool?.message, "/w/a.swift")
        XCTAssertEqual(tool?.pid, 4242, "a tool line names its process too")
        XCTAssertNil(tool?.front, "front is only asked for what is owed")
    }

    /// A failed tool is activity for that tool.
    func testClaudePostToolUseFailureIsAToolLine() throws {
        deliver("claude", "PostToolUseFailure", #"{"session_id":"s1","cwd":"/w","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"npm test"},"error":"exit 1"}"#)
        let line = try XCTUnwrap(records().first)
        XCTAssertEqual(line.kind, .tool)
        XCTAssertEqual(line.tool, "Bash")
        XCTAssertEqual(line.message, "npm test")
    }

    /// A hook whose parent had exited is re-parented to
    /// launchd; pid 1 is never written.
    func testPidOneIsNeverWritten() throws {
        deliver("claude", "Stop", #"{"session_id":"s1","cwd":"/w"}"#, locate: { _, _ in (1, "") })
        let raw = try String(contentsOf: log, encoding: .utf8)
        let line = try XCTUnwrap(raw.split(separator: "\n").first { !$0.hasPrefix("#") })
        XCTAssertEqual(line.split(separator: "\t", omittingEmptySubsequences: false)[8], "")
        XCTAssertEqual(records().first?.pid, 0)
        let parents: [Int32: Int32] = [300: 1]
        XCTAssertEqual(
            HookLanding.agentPID(agent: .claude, start: 1, parentOf: { parents[$0] }, argumentsOf: { _ in nil }),
            0,
            "the chain starts at launchd: unknown"
        )
    }

    /// Claude's StopFailure: a `failed` turn, with the error in its own
    /// words.
    func testClaudeStopFailureCarriesItsError() throws {
        deliver("claude", "StopFailure", #"{"session_id":"s1","cwd":"/w","hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":"API Error: Rate limit reached"}"#)
        let line = try XCTUnwrap(records().first)
        XCTAssertEqual(line.kind, .failed)
        XCTAssertEqual(line.tool, "")
        XCTAssertEqual(line.message, "API Error: Rate limit reached")
        XCTAssertEqual(PulseHookReceiver.errorMessage(from: ["error": "rate_limit"]), "rate_limit")
        XCTAssertEqual(PulseHookReceiver.errorMessage(from: ["error": ["message": "boom"]]), "boom")
    }

    /// The event is the installed command's argument; an entry that names
    /// none writes nothing — the payload's own name is not read.
    func testAnEntryThatNamesNoEventWritesNothing() {
        deliver("claude", "", #"{"hook_event_name":"PermissionRequest","tool_name":"Edit","tool_input":{"file_path":"/w/a"},"session_id":"c1"}"#)
        XCTAssertEqual(kinds(), [])
        XCTAssertEqual(ignored(), [PulseHookReceiver.Ignored.noEvent.rawValue])
    }

    // MARK: - Codex (openai/codex codex-rs/hooks)

    func testCodexStopIsYourTurnAndItNeverBlocks() {
        deliver("codex", "UserPromptSubmit", #"{"session_id":"x1","turn_id":"t1","cwd":"/w","hook_event_name":"UserPromptSubmit","prompt":"Add a retry"}"#)
        deliver("codex", "Stop", #"{"session_id":"x1","turn_id":"t1","transcript_path":null,"cwd":"/w","hook_event_name":"Stop","model":"gpt-5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":"Done."}"#)
        // Codex's own PermissionRequest fires before its auto-review: never
        // installed, never read — and the protocol's word is not an event.
        deliver("codex", "PermissionRequest", #"{"session_id":"x4","tool_name":"Bash"}"#)
        deliver("codex", "permission", #"{"session_id":"x3","message":"Approve shell"}"#)
        XCTAssertEqual(kinds(), ["working", "turn"])
        XCTAssertEqual(records().map(\.session), ["x1", "x1"])
        XCTAssertEqual(ignored(), [PulseHookReceiver.Ignored.notInstalled.rawValue, PulseHookReceiver.Ignored.notInstalled.rawValue])
        XCTAssertEqual(records().first?.message, "Add a retry")
        XCTAssertEqual(records().last?.message, "Done.")
    }

    // MARK: - Copilot CLI (github/docs hooks-reference.md)

    func testCopilotNotificationsAndStop() {
        deliver("copilot", "notification", #"{"sessionId":"cp1","timestamp":1790000000000,"cwd":"/w","hook_event_name":"Notification","message":"Copilot wants to run: npm test","title":"Permission needed","notification_type":"permission_prompt"}"#)
        deliver("copilot", "notification", #"{"sessionId":"cp1","timestamp":1790000000001,"cwd":"/w","hook_event_name":"Notification","message":"Which branch?","notification_type":"elicitation_dialog"}"#)
        deliver("copilot", "notification", #"{"sessionId":"cp1","timestamp":1790000000002,"cwd":"/w","hook_event_name":"Notification","message":"Background agent idle","notification_type":"agent_idle"}"#)
        deliver("copilot", "agentStop", #"{"sessionId":"cp1","timestamp":1790000000003,"cwd":"/w","transcriptPath":"/Users/me/.copilot/session-state/cp1/events.jsonl","stopReason":"end_turn","stop_hook_active":false}"#)
        XCTAssertEqual(kinds(), ["permission", "question", "turn"], "a background agent's idle is not this session's turn")
        XCTAssertEqual(records().first?.message, "Copilot wants to run: npm test")
    }

    /// Copilot sends `toolArgs` as a JSON string: its command or path is the
    /// step's target. An unrecoverable error ends the turn with its message.
    func testCopilotToolArgsAsAStringNameTheTarget() throws {
        deliver("copilot", "userPromptSubmitted", #"{"sessionId":"cp2","cwd":"/w","prompt":"Run the tests"}"#)
        deliver("copilot", "postToolUse", #"{"sessionId":"cp2","cwd":"/w","toolName":"bash","toolArgs":"{\"command\":\"npm test\",\"description\":\"Run tests\"}"}"#)
        deliver("copilot", "postToolUse", #"{"sessionId":"cp2","cwd":"/w","toolName":"view","toolArgs":"{\"path\":\"/w/README.md\"}"}"#)
        deliver("copilot", "errorOccurred", #"{"sessionId":"cp2","cwd":"/w","recoverable":false,"error":{"message":"Model unavailable","name":"Error"}}"#)
        let lines = records()
        XCTAssertEqual(lines.map(\.kind), [.working, .tool, .tool, .failed])
        XCTAssertEqual(lines[0].message, "Run the tests")
        XCTAssertEqual(lines[1].tool, "bash")
        XCTAssertEqual(lines[1].message, "npm test")
        XCTAssertEqual(lines[2].message, "/w/README.md")
        XCTAssertEqual(lines[3].message, "Model unavailable")
        XCTAssertNil(PulseHookReceiver.toolInput(["toolArgs": "not json"]))
    }

    // MARK: - OpenCode (plugin events, SDK v2)

    func testOpenCodePermissionAskedThenReplied() throws {
        deliver("opencode", "permission.asked", #"{"sessionID":"ses_1","directory":"/w","permission":"bash","patterns":["npm test"]}"#)
        let block = try XCTUnwrap(records().first)
        XCTAssertEqual(block.kind, .permission)
        XCTAssertEqual(block.message, "bash: npm test")
        XCTAssertEqual(block.session, "ses_1")
        XCTAssertEqual(block.cwd, "/w")
        deliver("opencode", "permission.replied", #"{"sessionID":"ses_1","directory":"/w"}"#)
        deliver("opencode", "question.asked", #"{"sessionID":"ses_1","directory":"/w","questions":[{"question":"Which database?","header":"DB"}]}"#)
        deliver("opencode", "session.status", #"{"sessionID":"ses_1","directory":"/w","status":"busy"}"#)
        deliver("opencode", "session.idle", #"{"sessionID":"ses_1","directory":"/w"}"#)
        XCTAssertEqual(kinds(), ["permission", "done", "question", "turn"])
        XCTAssertEqual(records().filter(\.kind.isActivity).map(\.kind), [.status], "busy is work going on — its own kind")
        XCTAssertEqual(records()[2].message, "Which database?")
        var book = SessionBook()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // The grace is about the turn: replay the block and the turn alone.
        for record in blocksAndTurns() { book.apply(record, nowMs: nowMs) }
        XCTAssertEqual(HookFeed.word(book.sessions[SessionKey(.opencode, "ses_1")]?.state), "blocked:question", "an idle moments after a question does not wipe it (stop grace)")
    }

    // MARK: - Cursor (hooks.json, observe-only events)

    func testCursorStopIsYourTurnAndItNeverBlocks() throws {
        deliver("cursor", "stop", #"{"conversation_id":"cu1","generation_id":"g1","model":"gpt-5","hook_event_name":"stop","cursor_version":"1.7","workspace_roots":["/Users/me/app"],"transcript_path":"/Users/me/.cursor/projects/app/cu1.jsonl","status":"completed","loop_count":0}"#)
        deliver("cursor", "permission", #"{"conversation_id":"cu1","message":"approve"}"#)
        deliver("cursor", "beforeShellExecution", #"{"conversation_id":"cu1","command":"rm -rf build"}"#)
        let record = try XCTUnwrap(records().first)
        XCTAssertEqual(kinds(), ["turn"])
        XCTAssertEqual(record.session, "cu1")
        XCTAssertEqual(record.cwd, "/Users/me/app")
        XCTAssertFalse(try String(contentsOf: log, encoding: .utf8).contains("cu1.jsonl"))
    }

    /// Only the events Pulse installs are read: an event it never installs
    /// writes nothing, for Cursor, Pi and Claude alike.
    func testNeverInstalledEventsWriteNothing() {
        deliver("cursor", "afterShellExecution", #"{"conversation_id":"cu2","command":"ls"}"#)
        deliver("cursor", "afterFileEdit", #"{"conversation_id":"cu2","file_path":"/w/a"}"#)
        deliver("pi", "tool_execution_update", #"{"session_id":"p2","cwd":"/w"}"#)
        deliver("pi", "agent_end", #"{"session_id":"p2","cwd":"/w"}"#)
        deliver("pi", "turn_end", #"{"session_id":"p2","cwd":"/w"}"#)
        deliver("claude", "PreToolUse", #"{"session_id":"c2","cwd":"/w","tool_name":"Bash"}"#)
        XCTAssertTrue(records().isEmpty, "\(records().map(\.kind))")
        XCTAssertEqual(ignored(), Array(repeating: PulseHookReceiver.Ignored.notInstalled.rawValue, count: 6), "heard, and said why")
        XCTAssertEqual(heard().map(\.event), ["afterShellExecution", "afterFileEdit", "tool_execution_update", "agent_end", "turn_end", "PreToolUse"])
    }

    // MARK: - Pi (extension events)

    /// A Pi prompt with no title never says its event's
    /// reason (`ui_prompt`); the extension sends a reason only on shutdown.
    func testAPiPromptNeverSaysItsReason() throws {
        deliver("pi", "ui_prompt_start", #"{"session_id":"p9","cwd":"/w","kind":"input","reason":"ui_prompt"}"#)
        let line = try XCTUnwrap(records().first)
        XCTAssertEqual(line.kind, .question)
        XCTAssertEqual(line.message, "", "not the literal ui_prompt")
        XCTAssertEqual(PulseHookReceiver.genericMessage(from: ["reason": "ui_prompt"], blocked: true), "")
        XCTAssertEqual(PulseHookReceiver.genericMessage(from: ["reason": "rate_limit"]), "rate_limit", "a turn may still say why it ended")
        let module = Pi.module(launcher: "/x/pulse-hook", events: ["ui_prompt_start", "session_shutdown"])
        XCTAssertTrue(module.contains(#"if (name === "session_shutdown" && event && typeof event.reason === "string") payload.reason = event.reason"#))
    }

    func testPiUIPromptsAreBlocksUntilTheyEnd() {
        deliver("pi", "agent_start", #"{"session_id":"p1","transcript_path":"/Users/me/.pi/agent/sessions/w/p1.jsonl","cwd":"/w"}"#)
        deliver("pi", "ui_prompt_start", #"{"session_id":"p1","cwd":"/w","kind":"confirm","title":"Allow rm -rf build?"}"#)
        deliver("pi", "ui_prompt_end", #"{"session_id":"p1","cwd":"/w","kind":"confirm","title":"Allow rm -rf build?"}"#)
        deliver("pi", "ui_prompt_start", #"{"session_id":"p1","cwd":"/w","kind":"select","title":"Pick a model"}"#)
        deliver("pi", "agent_settled", #"{"session_id":"p1","cwd":"/w"}"#)
        XCTAssertEqual(kinds(), ["working", "permission", "done", "question", "turn"])
        XCTAssertEqual(records()[1].message, "Allow rm -rf build?")
    }

    /// The Pi extension forwards the tool's name and one short argument —
    /// kept from `tool_execution_start` by the call's id, since
    /// `tool_execution_end` carries no arguments in the current API — chosen
    /// by tool: the command of a shell, the path of a file tool, the pattern
    /// of a search. A call another tool made is folded into its caller.
    func testPiToolEventsNameTheirStep() throws {
        deliver("pi", "tool_execution_end", #"{"session_id":"p3","cwd":"/w","tool_name":"bash","tool_input":{"command":"ls -la"}}"#)
        let line = try XCTUnwrap(records().first)
        XCTAssertEqual(line.kind, .tool)
        XCTAssertEqual(line.tool, "bash")
        XCTAssertEqual(line.message, "ls -la")
        XCTAssertFalse(line.failed)
        let module = Pi.module(launcher: "/x/pulse-hook", events: ["tool_execution_start", "tool_execution_end"])
        XCTAssertTrue(module.contains("ARGS.set(event.toolCallId, input)"))
        XCTAssertTrue(module.contains("const input = ARGS.get(event.toolCallId)"))
        XCTAssertTrue(module.contains("return { [key]: args[key].slice(0, 2000) }"))
        XCTAssertTrue(module.contains(#"["bash", ["command"]]"#))
        XCTAssertTrue(module.contains(#"["read", ["path", "file_path"]]"#))
        XCTAssertTrue(module.contains(#"["grep", ["pattern"]]"#))
        XCTAssertTrue(module.contains("new Map(["), "a Map: a tool named `constructor` finds no keys")
        XCTAssertTrue(module.contains(#"(name === "tool_execution_start" || name === "tool_execution_end") && event && event.parentToolCallId) return"#))
        XCTAssertFalse(module.contains("event.args || event.input"), "the end event has no args any more")
    }

    /// A tool that starts is a `status` line naming it and its target — what
    /// runs now, never a step; its end says whether it failed and how long
    /// it ran.
    func testPiToolStartIsAStatusAndItsEndSaysFailureAndDuration() throws {
        deliver("pi", "tool_execution_start", #"{"session_id":"p5","cwd":"/w","tool_name":"bash","tool_input":{"command":"swift build"}}"#)
        deliver("pi", "tool_execution_end", #"{"session_id":"p5","cwd":"/w","tool_name":"bash","tool_input":{"command":"swift build"},"is_error":true,"duration_ms":1500000}"#)
        let lines = records()
        XCTAssertEqual(lines.map(\.kind), [.status, .tool])
        XCTAssertEqual(lines[0].tool, "bash")
        XCTAssertEqual(lines[0].message, "swift build")
        XCTAssertFalse(lines[0].failed)
        XCTAssertEqual(lines[0].tookMs, 0)
        XCTAssertTrue(lines[1].failed)
        XCTAssertEqual(lines[1].tookMs, 1_500_000)
        let module = Pi.module(launcher: "/x/pulse-hook", events: ["tool_execution_end"])
        XCTAssertTrue(module.contains("payload.is_error = event.isError === true"))
        XCTAssertTrue(module.contains(#"if (typeof event.durationMs === "number" && event.durationMs >= 0) payload.duration_ms = Math.round(event.durationMs)"#))
    }

    /// Pi's `custom` view blocks nothing (Pi's own interactive reporter
    /// never marks it blocked): its start and end are heard and said not to
    /// be a block. A confirm is an approval; a select, an input and an
    /// editor are questions.
    func testAPiCustomViewIsNotABlock() throws {
        deliver("pi", "ui_prompt_start", #"{"session_id":"p6","cwd":"/w","kind":"custom"}"#)
        deliver("pi", "ui_prompt_end", #"{"session_id":"p6","cwd":"/w","kind":"custom"}"#)
        XCTAssertTrue(records().isEmpty, "\(records().map(\.kind))")
        XCTAssertEqual(ignored(), Array(repeating: PulseHookReceiver.Ignored.notABlock.rawValue, count: 2))
        let promptKinds: [(String, AttentionKind)] = [("confirm", .permission), ("select", .question), ("input", .question), ("editor", .question)]
        for (kind, expected) in promptKinds {
            let record = PulseHookReceiver.record(agent: .pi, event: "ui_prompt_start", payload: ["session_id": "p6", "kind": kind, "title": "T"], nowMs: 1)
            XCTAssertEqual(record.kind, expected, kind)
        }
        XCTAssertNotEqual(Connection.reasonText(PulseHookReceiver.Ignored.notABlock.rawValue, lang: .en), L10n.t(.ignoredOther, .en))
    }

    /// The person stopped the run (Escape): a `stopped` line, never "your
    /// turn" with the partial words.
    func testAnAbortedPiRunIsStopped() throws {
        deliver("pi", "agent_settled", #"{"session_id":"p7","cwd":"/w","aborted":true,"last_assistant_message":"I was about to"}"#)
        let line = try XCTUnwrap(records().first)
        XCTAssertEqual(line.kind, .stopped)
        XCTAssertEqual(line.message, "")
        let module = Pi.module(launcher: "/x/pulse-hook", events: ["agent_settled"])
        XCTAssertTrue(module.contains("if (event && event.aborted === true) payload.aborted = true"))
        XCTAssertTrue(module.contains("else Object.assign(payload, lastRun)"))
    }

    /// Pi's own session name is the title: on `session_start` (a resume of
    /// a named session) and on `session_info_changed`. A skill invocation is
    /// sent as `/skill:name args`, never the skill file's path.
    func testPiSessionNameIsATitleLine() throws {
        deliver("pi", "session_start", #"{"session_id":"p8","cwd":"/w","session_name":"Release prep"}"#)
        deliver("pi", "session_info_changed", #"{"session_id":"p8","cwd":"/w","session_name":"Release 31"}"#)
        deliver("pi", "session_info_changed", #"{"session_id":"p8","cwd":"/w","session_name":""}"#)
        let lines = records()
        XCTAssertEqual(lines.map(\.kind), [.start, .title, .title])
        XCTAssertEqual(lines.map(\.message), ["Release prep", "Release 31", ""])
        let module = Pi.module(launcher: "/x/pulse-hook", events: ["session_start", "session_info_changed", "message_start"])
        XCTAssertTrue(module.contains("const name = ctx.sessionManager.getSessionName()"))
        XCTAssertTrue(module.contains(#"if (name === "session_start") payload.session_name = sessionName(ctx)"#))
        XCTAssertTrue(module.contains(#"const SKILL = /^<skill name="([^"]+)" location="[^"]*">\n[\s\S]*?\n<\/skill>(?:\n\n([\s\S]+))?$/"#))
        XCTAssertTrue(module.contains(#"return args ? "/skill:" + m[1] + " " + args : "/skill:" + m[1]"#))
        XCTAssertTrue(module.contains("const prompt = promptText(text(event.message.content).trim())"))
    }

    /// The extension sends one event at a time, in the order Pi emitted
    /// them: the next child is spawned when the one before it exited (or
    /// after a 1.5 s guard), the queue is bounded, and a shutdown flushes it.
    /// A subagent (`--mode json`) or a print run sends nothing; no
    /// transcript path is sent; its own pid rides along.
    func testThePiExtensionSendsInOrderAndOnlyWhenInteractive() {
        let module = Pi.module(launcher: "/x/pulse-hook", events: ["agent_settled", "session_shutdown"])
        XCTAssertTrue(module.contains("const GUARD_MS = 1500"))
        XCTAssertTrue(module.contains("const QUEUE_MAX = 64"))
        XCTAssertTrue(module.contains(#"child.on("exit", finish)"#))
        XCTAssertTrue(module.contains(#"child.on("error", finish)"#))
        XCTAssertTrue(module.contains("timer = setTimeout(finish, GUARD_MS)"))
        XCTAssertTrue(module.contains("let drop = QUEUE.findIndex((item) => !KEEP.has(item[0]))"))
        XCTAssertTrue(module.contains(#"if (name === "session_shutdown") flush()"#))
        XCTAssertTrue(module.contains(#"return !!ctx && (ctx.mode === "json" || ctx.mode === "print")"#))
        XCTAssertTrue(module.contains("if (quiet(ctx)) return"))
        XCTAssertTrue(module.contains("pid: process.pid"))
        XCTAssertTrue(module.contains("child.unref()"))
        XCTAssertFalse(module.contains("transcript_path"), "no transcript path is forwarded")
        XCTAssertFalse(module.contains("getSessionFile"))
        XCTAssertFalse(module.contains("await "), "a handler never awaits")
        XCTAssertTrue(module.contains(#"const PULSE_HOOK = "/x/pulse-hook""#))
        XCTAssertTrue(module.contains(#"const EVENTS = ["agent_settled", "session_shutdown"]"#))
    }

    /// The extension's pid is taken only when it is the hook's own parent
    /// (the extension spawns pulse-hook directly): a payload cannot name
    /// another process, and only an adapter whose module spawns the hook
    /// may claim one.
    func testAPiPidIsTakenOnlyWhenItIsTheHooksParent() throws {
        XCTAssertEqual(PulseHookReceiver.claimedPID(agent: .pi, payload: ["pid": 777], parent: 777), 777)
        XCTAssertEqual(PulseHookReceiver.claimedPID(agent: .pi, payload: ["pid": "777"], parent: 777), 777)
        XCTAssertEqual(PulseHookReceiver.claimedPID(agent: .pi, payload: ["pid": 777], parent: 778), 0)
        XCTAssertEqual(PulseHookReceiver.claimedPID(agent: .pi, payload: ["pid": 1], parent: 1), 0)
        XCTAssertEqual(PulseHookReceiver.claimedPID(agent: .claude, payload: ["pid": 777], parent: 777), 0)
        XCTAssertEqual(PulseHookReceiver.claimedPID(agent: .pi, payload: [:], parent: 777), 0)
        let payload = #"{"session_id":"p9","cwd":"/w","pid":777}"#
        PulseHookReceiver.run(arguments: ["PulseBar", "--hook", "pi", "agent_start", payload], logURL: log, locate: located, parent: 777)
        PulseHookReceiver.run(arguments: ["PulseBar", "--hook", "pi", "agent_start", payload], logURL: log, locate: located, parent: 778)
        XCTAssertEqual(records().map(\.pid), [777, 4242], "its own parent, else the walk's answer")
    }

    /// The person's own message is the prompt (the title); the run's last
    /// assistant words ride on `agent_settled`, and a run that stopped on an
    /// error ends a failed turn with Pi's `errorMessage`.
    func testPiPromptLastWordsAndErrorComeFromTheCurrentEvents() throws {
        deliver("pi", "agent_start", #"{"session_id":"p4","cwd":"/w"}"#)
        deliver("pi", "message_start", #"{"session_id":"p4","cwd":"/w","prompt":"Review this repository"}"#)
        deliver("pi", "agent_settled", #"{"session_id":"p4","cwd":"/w","last_assistant_message":"The build is green."}"#)
        deliver("pi", "agent_settled", #"{"session_id":"p4","cwd":"/w","error":"429 rate limited"}"#)
        let lines = records()
        XCTAssertEqual(lines.map(\.kind), [.working, .working, .turn, .failed])
        XCTAssertEqual(lines[1].message, "Review this repository")
        XCTAssertEqual(lines[2].message, "The build is green.")
        XCTAssertEqual(lines[3].message, "429 rate limited")
        let module = Pi.module(launcher: "/x/pulse-hook", events: ["message_start", "agent_settled"])
        XCTAssertTrue(module.contains(#"if (name === "message_start" && !(event && event.message && event.message.role === "user")) return"#))
        XCTAssertTrue(module.contains(#"pi.on("agent_end", (event, ctx) => {"#))
        XCTAssertTrue(module.contains(#"if (m.stopReason === "error""#))
        XCTAssertTrue(module.contains("else Object.assign(payload, lastRun)"))
        XCTAssertTrue(module.contains(#"(name === "session_start" || name === "session_shutdown") && event && event.reason === "reload""#))
        XCTAssertFalse(module.contains("usage"), "tokens and cost are never read")
    }

    // MARK: - Payloads that do not parse, and credentials at the cut

    /// A payload cut off (at `stdinLimit`, or by a writer that died) is not
    /// JSON: it writes only an `ignored` line that says so — never a ghost
    /// wait whose ask is raw JSON. Plain text is no payload either.
    func testAPayloadThatDoesNotParseWritesNothing() throws {
        let whole = #"{"session_id":"t1","cwd":"/w","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm test"}}"#
        let cut = String(whole.prefix(60))
        deliver("claude", "PermissionRequest", cut)
        deliver("claude", "", cut)
        deliver("copilot", "notification", cut)
        PulseHookReceiver.run(
            arguments: ["PulseBar", "--hook", "opencode", "permission.asked", #"{"sessionID":"o1","directory":"/w","permis"#],
            stdin: "", logURL: log, locate: located
        )
        XCTAssertTrue(records().isEmpty, "\(records().map(\.message))")
        XCTAssertEqual(ignored(), Array(repeating: PulseHookReceiver.Ignored.unparsable.rawValue, count: 4))
        XCTAssertFalse(heard().contains { $0.message.contains("tool_name") }, "never the payload's words")
        XCTAssertNil(PulseHookReceiver.parsePayload(stdin: cut, trailingArg: nil))
        // Plain text on stdin writes nothing, whatever the event says.
        deliver("claude", "Stop", "all done")
        deliver("cursor", "stop", "all done")
        deliver("copilot", "notification", "Approve the deploy?")
        XCTAssertTrue(records().isEmpty)
        XCTAssertNil(PulseHookReceiver.parsePayload(stdin: "Approve the deploy?", trailingArg: nil))
        XCTAssertEqual(PulseHookReceiver.parsePayload(stdin: "", trailingArg: nil)?.isEmpty, true, "no payload is an empty one")
    }

    /// Credentials are redacted from the whole value before it is cut to a
    /// row's length: a token straddling the cut never leaves its head
    /// behind (too short for the redaction to know it after the cut).
    func testACredentialAcrossTheCutIsRedacted() throws {
        // 127 characters, then `Bearer ` ends at 134: the cut at 139 would
        // keep the token's first five characters.
        let lead = "echo " + String(repeating: "a", count: 121) + " "
        XCTAssertEqual(lead.count, 127)
        let command = lead + "Bearer tok3nVALUEabcdef1234"
        let object: [String: Any] = [
            "session_id": "r1", "cwd": "/w", "tool_name": "Bash", "tool_input": ["command": command],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let payload = String(decoding: data, as: UTF8.self)
        deliver("claude", "PostToolUse", payload)
        deliver("claude", "PermissionRequest", payload)
        let written = records()
        XCTAssertEqual(written.map(\.kind), [.tool, .permission])
        for record in written {
            XCTAssertFalse(record.message.contains("tok3n"), record.message)
        }
        XCTAssertFalse(PulseHookReceiver.condenseOneLine(command).contains("tok3n"))
        XCTAssertTrue(PulseHookReceiver.condenseOneLine(command).contains("Bearer ••••"))
    }

    // MARK: - Rejections

    /// Only the agent's own adapter reads an event: the protocol's kind words
    /// (`permission`, `turn`, `done`, …) are not events of any agent. Each is
    /// heard as an `ignored` line; an agent that is not one of the six has
    /// no line at all.
    func testUnknownEventsAndAgentsAreOnlyHeard() throws {
        XCTAssertEqual(deliver("goose", "permission", #"{"message":"x","session_id":"x"}"#), 0, "not a supported agent")
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        XCTAssertEqual(deliver("claude", "made_up_vendor_event", #"{"message":"x","session_id":"x"}"#), 0)
        for word in AttentionKind.allCases.map(\.rawValue) {
            XCTAssertEqual(deliver("claude", word, #"{"message":"x","session_id":"x"}"#), 0)
            XCTAssertEqual(deliver("copilot", word, #"{"message":"x","session_id":"x"}"#), 0)
        }
        XCTAssertEqual(deliver("claude", "", #"{"message":"says nothing about what it is","session_id":"x"}"#), 0)
        XCTAssertTrue(records().isEmpty, "\(records().map(\.kind))")
        XCTAssertEqual(ignored().count, 2 + 2 * AttentionKind.allCases.count)
        XCTAssertFalse(heard().contains { $0.message == "x" }, "never the payload's words")
    }

    /// A blocked event from an agent whose hooks cannot report a wait is
    /// heard and refused, in words: no fake Waiting.
    func testABlockFromAnAgentThatCannotWaitIsRefusedInWords() throws {
        XCTAssertEqual(AgentID.codex.waitingSource, .none)
        let turn = PulseHookReceiver.record(agent: .codex, event: "Stop", payload: ["session_id": "x1"], nowMs: 1)
        XCTAssertEqual(turn.kind, .turn, "an installed event reads as its action")
        let refused = PulseHookReceiver.ignored(.cannotWait, agent: .codex, event: "PermissionRequest", context: HookContext(payload: ["session_id": "x1"]), nowMs: 1)
        XCTAssertEqual(refused.kind, .ignored)
        XCTAssertEqual(refused.message, PulseHookReceiver.Ignored.cannotWait.rawValue)
        XCTAssertEqual(refused.session, "x1")
        XCTAssertEqual(refused.event, "PermissionRequest")
    }

    /// A payload handed as the last argument means stdin is not read at
    /// all, so a pipe nobody closes cannot hold the hook.
    func testAPayloadInArgvSkipsStdin() {
        XCTAssertTrue(PulseHookReceiver.payloadInArguments(
            ["pulse-hook", "--hook", "pi", "agent_settled", #"{"session_id":"p1"}"#]
        ))
        XCTAssertFalse(PulseHookReceiver.payloadInArguments(["pulse-hook", "--hook", "claude"]))
        XCTAssertFalse(PulseHookReceiver.payloadInArguments(["pulse-hook", "--hook", "copilot", "notification"]))
    }

    /// The OpenCode plugin and the Pi extension pass their payload as
    /// the last argument — the event is whole the moment the hook is
    /// spawned, so the one sent as the agent exits is not lost with a pipe.
    func testAModulePayloadInArgvIsRead() {
        let args = [
            "PulseBar", "--hook", "opencode", "permission.asked",
            #"{"sessionID":"o1","directory":"/w","permission":"bash","patterns":["npm test"]}"#,
        ]
        XCTAssertTrue(PulseHookReceiver.payloadInArguments(args))
        PulseHookReceiver.run(arguments: args, stdin: "", logURL: log, locate: located)
        let record = records().first
        XCTAssertEqual(record?.kind, .permission)
        XCTAssertEqual(record?.session, "o1")
        XCTAssertEqual(record?.cwd, "/w")
        XCTAssertEqual(record?.message, "bash: npm test")
        let modules = [
            OpenCode.plugin(launcher: "/x/pulse-hook", events: ["session.idle"]),
            Pi.module(launcher: "/x/pulse-hook", events: ["agent_settled"]),
        ]
        for module in modules {
            XCTAssertTrue(module.contains("event, JSON.stringify(payload)]"), module)
            XCTAssertTrue(module.contains(#"stdio: "ignore""#))
            XCTAssertFalse(module.contains("child.stdin"), "no pipe to flush")
        }
    }

    /// One invalid byte (a hook cut off mid-character) must not read as an
    /// empty file — every wait would vanish.
    func testOneBadByteDoesNotHideEveryWait() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var bytes = Data(AttentionProtocol.Header(next: 2, gen: "g1").line.utf8)
        bytes.append(Data((AttentionRecord(agent: .claude, kind: .permission, ms: now - 1_000, message: "Bash: make", session: "s1", cwd: "/p", seq: 1).line + "\n").utf8))
        bytes.append(contentsOf: [0x63, 0x6C, 0xE2, 0x82, 0x0A]) // "cl" + a truncated "€"
        try bytes.write(to: log)
        let chunk = try XCTUnwrap(EventLog.read(at: log, after: nil))
        XCTAssertFalse(chunk.records.isEmpty)
        var book = SessionBook()
        for record in chunk.records { book.apply(record, nowMs: now) }
        XCTAssertEqual(Array(book.sessions.keys), [SessionKey(.claude, "s1")])
    }

    func testRunnerPathRefusesTestHarnessBinaries() throws {
        HooksInstaller.homeOverride = tempHome
        defer { HooksInstaller.homeOverride = nil }
        HooksInstaller.refreshRunnerPath()
        if let written = try? String(contentsOf: HooksInstaller.runnerPathURL, encoding: .utf8) {
            XCTAssertFalse(
                written.lowercased().contains("xctest"),
                "hook-runner.path must never point at a test harness binary"
            )
        }
    }

    // MARK: - A permission ask must say what is being asked

    func testFilePathAndURLAreNamedWhenThereIsNoCommand() {
        XCTAssertEqual(
            PulseHookReceiver.toolDescriptor(from: [
                "tool_name": "Edit", "tool_input": ["file_path": "/repo/src/main.swift"],
            ]),
            "Edit: /repo/src/main.swift"
        )
        XCTAssertEqual(
            PulseHookReceiver.toolDescriptor(from: [
                "tool_name": "WebFetch", "tool_input": ["url": "https://example.com/x"],
            ]),
            "WebFetch: https://example.com/x"
        )
        XCTAssertEqual(
            PulseHookReceiver.toolDescriptor(from: ["tool_name": "MultiEdit", "tool_input": ["edits": []]]),
            "MultiEdit"
        )
        XCTAssertEqual(PulseHookReceiver.toolDescriptor(from: ["tool_input": ["command": "ls"]]), "")
    }

    func testDescriptorFoldsAndBoundsWhatItShows() {
        XCTAssertEqual(
            PulseHookReceiver.condenseOneLine("git commit \\\n  -m  'two   lines'"),
            "git commit \\ -m 'two lines'"
        )
        let long = PulseHookReceiver.condenseOneLine(String(repeating: "x", count: 400))
        XCTAssertEqual(long.count, 140)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testACredentialInsideACommandIsStillRedacted() throws {
        deliver("claude", "PermissionRequest", #"""
        {"hook_event_name":"PermissionRequest","tool_name":"Bash",
         "tool_input":{"command":"curl -H 'Authorization: Bearer abcdefgh12345678' https://x"},
         "session_id":"c10"}
        """#)
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("Bash: curl"), text)
        XCTAssertFalse(text.contains("abcdefgh12345678"), "naming the ask must not leak the secret in it")
    }

    func testAPermissionRequestIsWrittenAndNeverHeld() throws {
        let started = Date()
        let code = deliver("claude", "PermissionRequest", #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"s1","cwd":"/w"}"#)
        XCTAssertEqual(code, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the receiver exits at once")
        let text = try String(contentsOf: log, encoding: .utf8)
        let line = try XCTUnwrap(text.split(separator: "\n").first { !$0.hasPrefix("#") })
        XCTAssertEqual(line.split(separator: "\t", omittingEmptySubsequences: false).count, AttentionProtocol.columnCount)
    }
}

/// Landing handles and the agent pid, read by the hook itself.
final class HookLandingTests: XCTestCase {
    func testHandlesAreMostSpecificFirst() {
        let env = [
            "TMUX": "/private/tmp/tmux-501/default,123,0",
            "TMUX_PANE": "%3",
            "ITERM_SESSION_ID": "w0t1p0:ABCD-1234",
            "TERM_PROGRAM": "iTerm.app",
        ]
        XCTAssertEqual(
            HookLanding.handles(environment: env, tty: "/dev/ttys004"),
            "tmux:%3;tmuxsock:/private/tmp/tmux-501/default;iterm:w0t1p0:ABCD-1234;tty:/dev/ttys004;term:iTerm.app"
        )
        XCTAssertEqual(HookLanding.handles(environment: ["TERM_PROGRAM": "Apple_Terminal"], tty: "/dev/ttys001"),
                       "tty:/dev/ttys001;term:Apple_Terminal")
        XCTAssertEqual(
            HookLanding.handles(environment: ["TERM_PROGRAM": "vscode", "__CFBundleIdentifier": "com.todesktop.230313mzl4w4u92"], tty: nil),
            "term:vscode;app:com.todesktop.230313mzl4w4u92",
            "the launching app tells Cursor from VS Code"
        )
        XCTAssertEqual(HookLanding.handles(environment: ["TMUX": "/tmp/tmux-501/default,1,0"], tty: nil), "", "no pane, no socket")
        XCTAssertEqual(HookLanding.handles(environment: [:], tty: nil), "")
        XCTAssertEqual(HookLanding.handles(environment: [:], tty: "??"), "", "only a device path is a tty")
    }

    func testAHandleNeverBreaksTheColumn() {
        let handles = HookLanding.handles(environment: ["TERM_PROGRAM": "evil\tprog;x\n"], tty: nil)
        XCTAssertFalse(handles.contains("\t"))
        XCTAssertFalse(handles.contains("\n"))
        XCTAssertEqual(handles, "term:evil prog,x")
    }

    func testTheAgentPidIsTheFirstAncestorThatIsTheAgent() {
        let parents: [Int32: Int32] = [300: 200, 200: 100, 100: 1]
        let argv: [Int32: String] = [
            300: "/bin/sh -c pulse-hook claude Stop",
            200: "/Users/me/.local/bin/claude --resume",
            100: "/bin/zsh -l",
        ]
        XCTAssertEqual(
            HookLanding.agentPID(agent: .claude, start: 300, parentOf: { parents[$0] }, argumentsOf: { argv[$0] }),
            200
        )
        let node: [Int32: String] = [300: "sh -c hook", 200: "node /opt/homebrew/bin/copilot", 100: "zsh"]
        XCTAssertEqual(
            HookLanding.agentPID(agent: .copilot, start: 300, parentOf: { parents[$0] }, argumentsOf: { node[$0] }),
            200
        )
        XCTAssertEqual(
            HookLanding.agentPID(agent: .codex, start: 300, parentOf: { parents[$0] }, argumentsOf: { argv[$0] }),
            0,
            "no ancestor is the agent: unknown, never the dying `sh -c` that ran the hook"
        )
    }

    func testProcArgsParseArgvAndSkipTheExecPath() {
        var bytes: [UInt8] = [2, 0, 0, 0]
        bytes += Array("/usr/local/bin/node".utf8) + [0, 0, 0]
        bytes += Array("node".utf8) + [0]
        bytes += Array("/opt/homebrew/bin/copilot".utf8) + [0]
        bytes += Array("SECRET=env".utf8) + [0]
        XCTAssertEqual(AgentProcesses.parseProcArgv(bytes), ["node", "/opt/homebrew/bin/copilot"], "argc bounds the read: no environment")
        XCTAssertNil(AgentProcesses.parseProcArgv([0, 0]))
    }
}

/// Every agent's documented, non-blocking hook, installed from the
/// catalog and removed byte for byte.
final class HooksInstallerTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-hooks-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        HooksInstaller.homeOverride = tempHome
    }

    override func tearDownWithError() throws {
        HooksInstaller.homeOverride = nil
        try? FileManager.default.removeItem(at: tempHome)
    }

    private func write(_ relative: String, _ text: String) throws {
        let url = tempHome.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ relative: String) -> String? {
        try? String(contentsOf: tempHome.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Every file and directory under the home, outside Pulse's own
    /// Application Support folder, with its bytes.
    private func snapshot() -> [String: Data] {
        var out: [String: Data] = [:]
        let root = tempHome.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(atPath: root) else { return out }
        for case let relative as String in walker where !relative.hasPrefix("Library") {
            var isDirectory: ObjCBool = false
            let path = root + "/" + relative
            _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                out[relative + "/"] = Data()
            } else {
                out[relative] = FileManager.default.contents(atPath: path) ?? Data()
            }
        }
        return out
    }

    /// A Mac with every vendor present, some with configs of their own.
    private func seedVendors() throws {
        for spec in Agents.all {
            try FileManager.default.createDirectory(
                at: tempHome.appendingPathComponent(spec.hooks.home), withIntermediateDirectories: true
            )
        }
        try write(".claude/settings.json", """
        {
            "model": "opus",
          "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "~/bin/guard.sh"}]}]}
        }
        """)
        try write(".codex/config.toml", "model = \"gpt-5\"\n\n[profiles.fast]\nmodel = \"o4-mini\"\n")
        try write(".codex/hooks.json", "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"notify.sh\"}]}]}}")
        try write(".cursor/hooks.json", "{\n  \"version\": 1,\n  \"hooks\": {\"afterFileEdit\": [{\"command\": \"./format.sh\"}]}\n}\n")
    }

    func testEveryAgentInstallsAndUninstallsByteForByte() throws {
        try seedVendors()
        let before = snapshot()
        let report = try HooksInstaller.install()
        XCTAssertEqual(report.count, AgentID.allCases.count)
        XCTAssertTrue(report.allSatisfy { $0.failure == nil }, "\(report.map(\.line))")
        for agent in AgentID.allCases {
            let text = try XCTUnwrap(read(agent.spec.hooks.path), agent.rawValue)
            let events = try XCTUnwrap(HooksInstaller.installedEvents(agent, text: text), agent.rawValue)
            XCTAssertEqual(events, Set(agent.spec.hooks.events.map(\.name)), agent.rawValue)
            XCTAssertTrue(HooksSupport.isWired(agent), agent.rawValue)
        }
        XCTAssertEqual(HooksSupport.probeStatus(), .all)
        XCTAssertNotEqual(snapshot(), before)
        XCTAssertEqual(read(".codex/config.toml"), "model = \"gpt-5\"\n\n[profiles.fast]\nmodel = \"o4-mini\"\n", "Pulse never touches config.toml")

        HooksInstaller.uninstall()
        XCTAssertEqual(snapshot(), before, "every file and directory is back exactly as it was")
        XCTAssertEqual(HooksSupport.probeStatus(), .missing)
    }

    func testAReinstallIsStillReversibleByteForByte() throws {
        try seedVendors()
        let before = snapshot()
        try HooksInstaller.install()
        try HooksInstaller.install()
        HooksInstaller.uninstall()
        XCTAssertEqual(snapshot(), before)
    }

    func testNoGatingEventIsEverInstalled() throws {
        try seedVendors()
        try HooksInstaller.install()
        for agent in AgentID.allCases {
            let text = try XCTUnwrap(read(agent.spec.hooks.path))
            let events = HooksInstaller.installedEvents(agent, text: text) ?? []
            XCTAssertTrue(events.isDisjoint(with: HookContract.gatingEvents), agent.rawValue)
        }
        // The user's own gating hook is theirs and stays; Pulse adds none.
        let claude = try XCTUnwrap(read(".claude/settings.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(claude.utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let pre = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(pre.count, 1)
        XCTAssertFalse(HooksInstaller.containsPulseMarker(String(describing: pre)))
        XCTAssertFalse(read(".codex/hooks.json")?.contains("PermissionRequest") ?? true)
        XCTAssertFalse(read(".cursor/hooks.json")?.contains("beforeSubmitPrompt") ?? true)
    }

    /// Claude and Codex run Pulse's entries in the background, where no
    /// output can decide anything.
    func testClaudeAndCodexEntriesAreAsync() throws {
        try seedVendors()
        try HooksInstaller.install()
        let files: [(String, Set<String>)] = [(".claude/settings.json", []), (".codex/hooks.json", ["SessionEnd"])]
        for (path, exempt) in files {
            let text = try XCTUnwrap(read(path))
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
            for (event, value) in hooks {
                for group in value as? [[String: Any]] ?? [] {
                    for body in group["hooks"] as? [[String: Any]] ?? [] {
                        let command = body["command"] as? String ?? ""
                        guard HooksInstaller.containsPulseMarker(command) else { continue }
                        XCTAssertTrue(command.hasSuffix(" \(event)"), "\(path) \(event): the command names its event")
                        if !exempt.contains(event) {
                            XCTAssertEqual(body["async"] as? Bool, true, "\(path) \(event)")
                        }
                        if path.hasPrefix(".codex"), event == "Interrupt" {
                            XCTAssertEqual(body["timeout"] as? Int, 3, "Codex caps Interrupt at 3 s: written at the cap")
                        }
                    }
                }
            }
        }
    }

    func testAnAbsentVendorGetsNothing() throws {
        try FileManager.default.createDirectory(at: tempHome.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let report = try HooksInstaller.install()
        XCTAssertEqual(report.count, 1)
        XCTAssertNil(read(".codex/hooks.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempHome.appendingPathComponent(".copilot").path))
        XCTAssertEqual(HooksSupport.probeStatus(), .installed([.claude]))
    }

    /// A file the user changed after the install keeps their change: only
    /// Pulse's entries go.
    func testAnEditAfterInstallSurvivesTheUninstall() throws {
        try seedVendors()
        try HooksInstaller.install()
        let url = tempHome.appendingPathComponent(".claude/settings.json")
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        root["theme"] = "dark"
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        HooksInstaller.uninstall(agents: [.claude])
        let after = try XCTUnwrap(read(".claude/settings.json"))
        XCTAssertFalse(HooksInstaller.containsPulseMarker(after))
        XCTAssertTrue(after.contains("\"theme\""))
        XCTAssertTrue(after.contains("guard.sh"), "the user's own hook stays")
    }

    func testAModuleFilePulseDidNotWriteIsNeverReplaced() throws {
        try write(".config/opencode/plugins/pulse.js", "export const Mine = async () => ({})\n")
        let results = try HooksInstaller.install(agents: [.opencode])
        XCTAssertEqual(results.map(\.failure), [.notOurs])
        XCTAssertEqual(read(".config/opencode/plugins/pulse.js"), "export const Mine = async () => ({})\n")
    }

    func testTheModulesObserveAndNeverDecide() throws {
        try seedVendors()
        try HooksInstaller.install()
        let plugin = try XCTUnwrap(read(".config/opencode/plugins/pulse.js"))
        XCTAssertTrue(plugin.contains("event: async ({ event })"))
        XCTAssertTrue(plugin.contains("detached: true"))
        XCTAssertTrue(plugin.contains("child.unref()"))
        XCTAssertFalse(plugin.contains("tool.execute.before"), "never a gating hook")
        XCTAssertFalse(plugin.contains("await spawn"))
        for event in AgentID.opencode.spec.hooks.events {
            XCTAssertTrue(plugin.contains("\"\(event.name)\""), event.name)
        }
        let extensionText = try XCTUnwrap(read(".pi/agent/extensions/pulse.js"))
        XCTAssertTrue(extensionText.contains("export default function (pi)"))
        XCTAssertFalse(extensionText.contains("\"tool_call\""), "never the event that can block a tool")
        XCTAssertTrue(extensionText.contains("\"ui_prompt_start\""))
        let copilot = try XCTUnwrap(read(".copilot/hooks/pulse.json"))
        XCTAssertTrue(copilot.contains("\"version\" : 1"))
        XCTAssertFalse(copilot.contains("preToolUse"))
    }

    /// An OpenCode subagent runs in a child session. Its lifecycle
    /// never reaches Pulse (its idle is not the person's turn, and it is not
    /// a row); its asks block the parent's work and land on the parent.
    func testOpenCodeSubagentsFoldIntoTheirParent() {
        let plugin = OpenCode.plugin(
            launcher: "/x/pulse-hook", events: AgentID.opencode.spec.hooks.events.map(\.name)
        )
        XCTAssertTrue(plugin.contains("if (event.type === \"session.created\" && info.parentID && info.id) {"))
        XCTAssertTrue(plugin.contains("PARENTS.set(info.id, info.parentID)"))
        XCTAssertTrue(plugin.contains("if (child && !ASKS.has(event.type)) {"), "a child's lifecycle is dropped")
        XCTAssertTrue(plugin.contains("sessionID: child ? rootOf(own) : own"), "a child's ask lands on its root session")
        XCTAssertTrue(plugin.contains("PARENTS.size > 512"), "the map is bounded")
        for ask in ["permission.asked", "permission.replied", "question.asked", "question.replied", "question.rejected"] {
            XCTAssertTrue(plugin.contains("\"\(ask)\""), ask)
        }
    }

    /// Codex is hooks.json only: an install and an uninstall never touch
    /// `config.toml`, and a `notify` line there is not a Pulse hook.
    func testCodexIsHooksJSONOnly() throws {
        let config = "model = \"gpt-5\"\nnotify = [\"/x/pulse-hook\", \"codex\"]\n"
        try write(".codex/config.toml", config)
        let report = try HooksInstaller.install(agents: [.codex])
        XCTAssertEqual(report.map(\.failure), [nil])
        XCTAssertEqual(read(".codex/config.toml"), config)
        XCTAssertTrue(HooksInstaller.containsPulseMarker(read(".codex/hooks.json") ?? ""))
        HooksInstaller.uninstall(agents: [.codex])
        XCTAssertEqual(read(".codex/config.toml"), config, "uninstall leaves config.toml alone too")
        XCTAssertFalse(HooksSupport.isWired(.codex), "a notify line in config.toml is not a Pulse hook")
    }

    func testInstallWritesThroughASymlinkedSettingsFile() throws {
        try write("dotfiles/claude-settings.json", "{\"model\": \"opus\"}\n")
        try FileManager.default.createDirectory(at: tempHome.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: tempHome.appendingPathComponent(".claude/settings.json").path,
            withDestinationPath: tempHome.appendingPathComponent("dotfiles/claude-settings.json").path
        )
        try HooksInstaller.install(agents: [.claude])
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: tempHome.appendingPathComponent(".claude/settings.json").path)
        XCTAssertTrue(link.hasSuffix("dotfiles/claude-settings.json"), "the link is still a link")
        XCTAssertTrue(HooksInstaller.containsPulseMarker(read("dotfiles/claude-settings.json") ?? ""))
        HooksInstaller.uninstall(agents: [.claude])
        XCTAssertEqual(read("dotfiles/claude-settings.json"), "{\"model\": \"opus\"}\n")
    }

    func testInstallRefusesInvalidJSON() throws {
        try write(".claude/settings.json", "{ not json")
        let results = try HooksInstaller.install(agents: [.claude])
        XCTAssertEqual(results.map(\.failure), [.invalidJSON])
        XCTAssertEqual(read(".claude/settings.json"), "{ not json", "the user's file is left alone")
    }

    /// One agent's broken config stops that agent only — the others
    /// are installed (and removed) all the same, and the result says which
    /// failed and why, without a path.
    func testOneBrokenConfigDoesNotStopTheOtherAgents() throws {
        try seedVendors()
        try write(".codex/hooks.json", "{ \"theme\": ")
        let results = try HooksInstaller.install()
        XCTAssertEqual(results.count, AgentID.allCases.count)
        XCTAssertEqual(results.filter { $0.failure != nil }.map(\.agent), [.codex])
        XCTAssertEqual(results.first { $0.agent == .codex }?.failure, .invalidJSON)
        for agent in AgentID.priority where agent != .codex {
            XCTAssertTrue(HooksSupport.isWired(agent), "\(agent.rawValue) is installed although Codex failed early in line")
        }
        XCTAssertEqual(read(".codex/hooks.json"), "{ \"theme\": ")

        let status = HooksSupport.status(after: results)
        XCTAssertEqual(status.failures, [.codex: .invalidJSON])
        XCTAssertTrue(status.isInstalled(for: .claude))
        let label = status.label(lang: .zh)
        XCTAssertTrue(label.contains("Codex"), label)
        XCTAssertTrue(label.contains(L10n.t(.hooksFailureInvalidJSON, .zh)), label)
        XCTAssertFalse(label.contains(tempHome.path) || label.contains(".json"), "no path in the UI: \(label)")
        XCTAssertFalse(label.contains("refusing"), "no English installer error in the zh UI: \(label)")

        try write(".cursor/hooks.json", "[\"pulse-hook\"]")
        let removed = HooksInstaller.uninstall()
        XCTAssertEqual(removed.filter { $0.failure != nil }.map(\.agent), [.cursor], "\(removed.map(\.line))")
        XCTAssertFalse(HooksSupport.isWired(.claude), "Claude is removed although Cursor failed")
    }

    /// An install rewrites only `hooks` — every other key, its order
    /// and its formatting stay exactly as the user wrote them.
    func testInstallLeavesEverythingOutsideHooksUntouched() throws {
        let original = """
        {
          "zeta": 1,
          "model":    "opus",
          "alpha": {"b": 2, "a": [1, 2.50, 3]},
          "hooks": {
            "PreToolUse": [
              {"matcher": "Bash", "hooks": [{"type": "command", "command": "~/bin/guard.sh"}]}
            ]
          },
          "env": {"Z": "1", "A": "2"}
        }

        """
        try write(".claude/settings.json", original)
        try HooksInstaller.install(agents: [.claude])
        let installed = try XCTUnwrap(read(".claude/settings.json"))
        let hooksStart = try XCTUnwrap(installed.range(of: "\"hooks\": ")).upperBound
        let head = String(installed[..<hooksStart])
        XCTAssertTrue(original.hasPrefix(head), "every byte before hooks is the user's")
        XCTAssertTrue(installed.hasSuffix(",\n  \"env\": {\"Z\": \"1\", \"A\": \"2\"}\n}\n"), installed)
        XCTAssertTrue(installed.contains(#"{"matcher": "Bash", "hooks": [{"type": "command", "command": "~/bin/guard.sh"}]}"#), "the user's own entry, verbatim")
        let userHook = try XCTUnwrap(installed.range(of: "guard.sh"))
        let pulseHook = try XCTUnwrap(installed.range(of: "claude SessionStart"))
        XCTAssertLessThan(userHook.lowerBound, pulseHook.lowerBound, "the user's events keep their place; Pulse's come after")
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(installed.utf8)) as? [String: Any])
        XCTAssertEqual(HooksInstaller.installedEvents(.claude, text: installed), Set(AgentID.claude.spec.hooks.events.map(\.name)))

        // Stripping after the user edited elsewhere keeps their edit and
        // their formatting; only Pulse's entries leave.
        let edited = installed.replacingOccurrences(of: "\"model\":    \"opus\"", with: "\"model\":    \"sonnet\"")
        try write(".claude/settings.json", edited)
        HooksInstaller.uninstall(agents: [.claude])
        let after = try XCTUnwrap(read(".claude/settings.json"))
        XCTAssertFalse(HooksInstaller.containsPulseMarker(after))
        XCTAssertTrue(after.hasPrefix("{\n  \"zeta\": 1,\n  \"model\":    \"sonnet\",\n  \"alpha\": {\"b\": 2, \"a\": [1, 2.50, 3]},\n  \"hooks\": "), after)
        XCTAssertTrue(after.contains("~/bin/guard.sh"))
        XCTAssertTrue(after.hasSuffix(",\n  \"env\": {\"Z\": \"1\", \"A\": \"2\"}\n}\n"), after)
    }

    /// A `hooks` member left empty by an uninstall goes, with its comma;
    /// a file without one gets it after its last member.
    func testTheHooksMemberIsAddedAndRemovedCleanly() throws {
        let added = try JSONSplice.replacingHooks(
            in: "{\n  \"a\": 1\n}\n", pulse: [("Stop", ["{\"x\": 1}"])],
            isPulse: { _ in false }, ensureVersion: false, dropEmptyHooks: false
        )
        XCTAssertEqual(added, "{\n  \"a\": 1,\n  \"hooks\": {\n    \"Stop\": [\n      {\"x\": 1}\n    ]\n  }\n}\n")
        let removed = try JSONSplice.replacingHooks(
            in: added, pulse: [], isPulse: { $0.contains("\"x\"") }, ensureVersion: false, dropEmptyHooks: true
        )
        XCTAssertEqual(removed, "{\n  \"a\": 1\n}\n")
        let inline = try JSONSplice.replacingHooks(
            in: #"{"theme":"Dracula"}"#, pulse: [("Stop", [#"{"x": 1}"#])],
            isPulse: { _ in false }, ensureVersion: true, dropEmptyHooks: false
        )
        XCTAssertEqual(inline, #"{"theme":"Dracula", "version": 1, "hooks": {"Stop": [{"x": 1}]}}"#)
        XCTAssertThrowsError(try JSONSplice.replacingHooks(in: "[1]", pulse: [], isPulse: { _ in false }, ensureVersion: false, dropEmptyHooks: false))
    }

    /// The launcher as a whole token, never a substring.
    func testMarkersNeverClaimAUsersOwnHook() {
        XCTAssertTrue(HooksInstaller.containsPulseMarker("/x/pulse-hook claude Stop"))
        XCTAssertTrue(HooksInstaller.containsPulseMarker(#""/Users/me/Library/Application Support/Pulse/pulse-hook" claude Stop"#))
        XCTAssertTrue(HooksInstaller.containsPulseMarker(#"{"command": "\"/a b/pulse-hook\" claude Stop"}"#))
        XCTAssertTrue(HooksInstaller.containsPulseMarker(#"{"command":"\/x\/pulse-hook claude"}"#), "JSONSerialization escapes slashes")
        XCTAssertFalse(HooksInstaller.containsPulseMarker("/Applications/Pulse.app/Contents/MacOS/PulseBar --hook claude"),
                       "only the launcher marks an entry as Pulse's")
        XCTAssertFalse(HooksInstaller.containsPulseMarker("mytool --hook-dir /tmp"))
        XCTAssertFalse(HooksInstaller.containsPulseMarker("~/bin/impulse-hook.sh"), "impulse-hook is not pulse-hook")
        XCTAssertFalse(HooksInstaller.containsPulseMarker("/x/pulse-hook.sh"))
        XCTAssertFalse(HooksInstaller.containsPulseMarker("/x/my-pulse-hook claude"))
        XCTAssertFalse(HooksInstaller.containsPulseMarker("PulseBarHelper --hooks"))
    }

    /// A user's `impulse-hook.sh` survives an install and an
    /// uninstall.
    func testAUsersImpulseHookIsNeverRemoved() throws {
        let original = """
        {
          "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "~/bin/impulse-hook.sh"}]}]}
        }

        """
        try write(".claude/settings.json", original)
        try HooksInstaller.install(agents: [.claude])
        XCTAssertTrue(read(".claude/settings.json")?.contains("impulse-hook.sh") == true)
        try write(".claude/settings.json", (read(".claude/settings.json") ?? "").replacingOccurrences(of: "\"hooks\": {", with: "\"theme\": \"dark\",\n  \"hooks\": {"))
        HooksInstaller.uninstall(agents: [.claude])
        let after = try XCTUnwrap(read(".claude/settings.json"))
        XCTAssertTrue(after.contains("~/bin/impulse-hook.sh"), after)
        XCTAssertFalse(HooksInstaller.containsPulseMarker(after))
    }

    /// The edges of a user's JSON — a non-array event, a
    /// user's empty event, CRLF, a byte-order mark, comments.
    func testJSONSpliceEdges() throws {
        let pulse = [("Stop", [#"{"x": 1}"#])]
        let isPulse: (String) -> Bool = { $0.contains(#""x""#) }
        // A non-array event Pulse must add to: refused, never a duplicate key.
        XCTAssertThrowsError(try JSONSplice.replacingHooks(
            in: #"{"hooks": {"Stop": {"hooks": []}}}"#, pulse: pulse, isPulse: isPulse, ensureVersion: false, dropEmptyHooks: false
        )) { error in XCTAssertTrue(error is JSONSplice.UnexpectedShape) }
        XCTAssertThrowsError(try JSONSplice.replacingHooks(
            in: #"{"hooks": []}"#, pulse: pulse, isPulse: isPulse, ensureVersion: false, dropEmptyHooks: false
        ), "a hooks that is not an object is not replaced")
        // A non-array event Pulse does not touch stays as it is.
        let other = try JSONSplice.replacingHooks(
            in: #"{"hooks": {"Custom": "x"}}"#, pulse: pulse, isPulse: isPulse, ensureVersion: false, dropEmptyHooks: false
        )
        XCTAssertEqual(other, #"{"hooks": {"Custom": "x", "Stop": [{"x": 1}]}}"#)
        // The user's own empty event stays through an install and an uninstall.
        let empty = #"{"hooks": {"Stop": [], "Start": []}}"#
        let installed = try JSONSplice.replacingHooks(in: empty, pulse: pulse, isPulse: isPulse, ensureVersion: false, dropEmptyHooks: false)
        XCTAssertEqual(installed, #"{"hooks": {"Stop": [{"x": 1}], "Start": []}}"#)
        let stripped = try JSONSplice.replacingHooks(in: installed, pulse: [], isPulse: isPulse, ensureVersion: false, dropEmptyHooks: true)
        XCTAssertEqual(stripped, #"{"hooks": {"Start": []}}"#)
        XCTAssertEqual(try JSONSplice.replacingHooks(in: empty, pulse: [], isPulse: isPulse, ensureVersion: false, dropEmptyHooks: true), empty)
        // CRLF stays CRLF.
        let crlf = "{\r\n  \"a\": 1\r\n}\r\n"
        let crlfOut = try JSONSplice.replacingHooks(in: crlf, pulse: pulse, isPulse: isPulse, ensureVersion: false, dropEmptyHooks: false)
        XCTAssertEqual(crlfOut, "{\r\n  \"a\": 1,\r\n  \"hooks\": {\r\n    \"Stop\": [\r\n      {\"x\": 1}\r\n    ]\r\n  }\r\n}\r\n")
        XCTAssertFalse(crlfOut.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "no bare LF")
        // A byte-order mark is kept, and the JSON after it read.
        let bom = "\u{FEFF}{\"a\": 1}"
        let bomOut = try JSONSplice.replacingHooks(in: bom, pulse: pulse, isPulse: isPulse, ensureVersion: false, dropEmptyHooks: false)
        XCTAssertEqual(bomOut, "\u{FEFF}{\"a\": 1, \"hooks\": {\"Stop\": [{\"x\": 1}]}}")
        // Comments: found outside strings only.
        XCTAssertTrue(JSONSplice.hasComments("{\n  // mine\n  \"a\": 1\n}"))
        XCTAssertTrue(JSONSplice.hasComments("{ /* mine */ \"a\": 1 }"))
        XCTAssertFalse(JSONSplice.hasComments(#"{"url": "https://example.com/a", "q": "a \" // b"}"#))
    }

    /// A settings file with comments is refused with its own
    /// reason, in the person's language, and left alone.
    func testAJSONCSettingsFileIsRefusedAsHavingComments() throws {
        let jsonc = "{\n  // my theme\n  \"theme\": \"dark\"\n}\n"
        try write(".claude/settings.json", jsonc)
        let results = try HooksInstaller.install(agents: [.claude])
        XCTAssertEqual(results.map(\.failure), [.hasComments])
        XCTAssertEqual(read(".claude/settings.json"), jsonc)
        XCTAssertEqual(HooksSupport.Status.reason(.hasComments, lang: .en), L10n.t(.hooksFailureHasComments, .en))
        XCTAssertNotEqual(L10n.t(.hooksFailureHasComments, .zh), L10n.t(.hooksFailureHasComments, .en))
        try write(".codex/hooks.json", #"{"hooks": {"Stop": {"command": "x"}}}"#)
        let shape = try HooksInstaller.install(agents: [.codex])
        XCTAssertEqual(shape.map(\.failure), [.unexpectedShape])
        // A byte-order mark is no reason to refuse.
        try write(".cursor/hooks.json", "\u{FEFF}{\"version\": 1}\n")
        let cursor = try HooksInstaller.install(agents: [.cursor])
        XCTAssertEqual(cursor.map(\.failure), [nil])
        XCTAssertTrue(HooksSupport.isWired(.cursor))
    }

    /// The Settings lines say each agent's connection — installed, needing
    /// an update or not, what was heard last and when, and which agents
    /// never report a wait; the agents that are not on this Mac share one
    /// line.
    func testSettingsSaysEachAgentsConnection() {
        let now: Int64 = 1_800_000_000_000
        let present: Set<AgentID> = [.claude, .codex, .cursor, .copilot]
        let connections = [
            Connection(agent: .claude, install: .complete, lastHeard: Connection.Heard(event: "Stop", ms: now - 12 * 60_000)),
            Connection(agent: .codex, install: .partial(found: 4, of: 6)),
            Connection(agent: .cursor, install: .complete),
            Connection(agent: .copilot, install: .notInstalled),
            Connection(agent: .opencode, install: .notInstalled),
            Connection(agent: .pi, install: .notInstalled),
        ]
        let lines = SettingsModel.hookAgents(connections: connections, present: present, nowMs: now, lang: .en)
        XCTAssertEqual(lines.map(\.agent), [.claude, .codex, .cursor, .copilot])
        let claude = lines[0]
        XCTAssertTrue(claude.installed)
        XCTAssertEqual(
            claude.detail,
            String(format: L10n.t(.settingsHookHeard, .en), "Stop", L10n.ago(now - 12 * 60_000, nowMs: now, .en))
                + " · " + L10n.t(.settingsHookReportsWaits, .en)
        )
        let codex = lines.first { $0.agent == .codex }
        XCTAssertEqual(codex?.state, String(format: L10n.t(.settingsHookPartial, .en), 4, 6))
        XCTAssertEqual(codex?.detail, L10n.t(.settingsHookNoEvent, .en) + " · " + L10n.t(.settingsHookNoWait, .en))
        XCTAssertTrue(lines.first { $0.agent == .cursor }?.detail.hasSuffix(L10n.t(.settingsHookNoWait, .en)) == true)
        let copilot = lines.first { $0.agent == .copilot }
        XCTAssertEqual(copilot?.state, L10n.t(.hooksMissing, .en))
        XCTAssertEqual(copilot?.detail, L10n.t(.settingsHookReportsWaits, .en), "nothing heard is said only where a hook is")
        XCTAssertEqual(copilot?.installed, false, "an agent here without its hook says so; Install all fixes it")
        let model = SettingsModel(
            lang: .en, launchAtLogin: false, notifications: .allowed, hooksStatus: "", hooksInstalled: true,
            hookAgents: lines, version: ""
        )
        XCTAssertTrue(model.hooksNeedUpdate, "a partial install is said once, under Install all")
        let absent = SettingsModel.absentAgents(connections: connections, present: present)
        XCTAssertEqual(absent, [.opencode, .pi], "in roster order")
        let line = SettingsModel.absentLine(absent, lang: .en)
        XCTAssertNotNil(line)
        for agent in absent { XCTAssertTrue(line?.contains(agent.displayName) == true, agent.rawValue) }
        XCTAssertNil(SettingsModel.absentLine([], lang: .en), "nothing to say when every agent is here")
    }

    /// A failed install names the agent and why.
    func testAFailedInstallIsItsOwnLine() {
        let connections = AgentID.allCases.map { agent in
            Connection.make(
                agent: agent, probed: .notInstalled,
                failure: agent == .opencode ? .invalidJSON : nil, heard: nil, ignored: nil
            )
        }
        let lines = SettingsModel.hookAgents(connections: connections, present: [], nowMs: 0, lang: .en)
        XCTAssertEqual(lines.map(\.agent), [.opencode])
        XCTAssertEqual(lines[0].tone, .warning)
        XCTAssertTrue(lines[0].state.contains(L10n.t(.hooksFailureInvalidJSON, .en)), lines[0].state)
    }

    /// An install read from disk: whole after Install all; partial when an
    /// event is taken out by hand; stale when the launcher is gone; and
    /// Install all makes it whole again.
    func testTheConnectionIsReadFromTheConfig() throws {
        try seedVendors()
        try HooksInstaller.install()
        for agent in AgentID.allCases {
            XCTAssertEqual(HooksSupport.inspect(agent), .complete, agent.rawValue)
        }
        let url = tempHome.appendingPathComponent(".claude/settings.json")
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        hooks.removeValue(forKey: "Stop")
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        let events = Set(AgentID.claude.spec.hooks.events.map(\.name))
        XCTAssertEqual(HooksSupport.inspect(.claude), .partial(found: events.count - 1, of: events.count))
        XCTAssertEqual(HooksSupport.probeStatus().isInstalled(for: .claude), true, "partial still carries the hook")

        try FileManager.default.removeItem(at: HooksInstaller.launcherURL)
        XCTAssertEqual(HooksSupport.inspect(.codex), .staleLauncher, "the launcher its hooks run is gone")

        try HooksInstaller.install()
        XCTAssertEqual(HooksSupport.inspect(.claude), .complete)
        XCTAssertEqual(HooksSupport.inspect(.codex), .complete)
        HooksInstaller.uninstall()
        XCTAssertEqual(HooksSupport.inspect(.claude), .notInstalled)
    }
}

final class AttentionWatcherReArmTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// A deleted file cannot be reopened, so the watch would have stayed dead
    /// for the life of the process: re-arming recreates it, with a header.
    func testAFileThatWasDeletedIsRecreatedWhenTheWatchReArms() throws {
        let file = home.appendingPathComponent(EventLog.fileName)
        let watcher = AttentionWatcher()
        defer { watcher.stop() }
        watcher.start(url: file) {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try FileManager.default.removeItem(at: file)

        watcher.arm()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(AttentionProtocol.headerPrefix), text)
    }
}

/// Turn — vendor event sequences, from the attention file to the lamp.
///
/// Swift Testing. Every sequence is one row of `TurnTruthTests.cases`
/// and one named test in the report, so a failing vendor order reads as
/// "claude · finished turn → your turn, not red" rather than as one assertion
/// buried in a hundred-line method. Each row is a sequence of lines exactly as
/// the hooks write them, read into the real session book and projected by the
/// real projection and builder; the expectations are what the user would see.
@Suite("Turn truth table", .serialized)
struct TurnTruthTests {
    static let now: Int64 = 1_800_000_000_000
    static let second: Int64 = 1_000

    static func line(
        _ agent: String, _ kind: String, ago: Int64, message: String = "",
        session: String = "s1", cwd: String = "/p", front: String? = nil, tool: String = ""
    ) -> String {
        // v8: all fifteen columns, written as the words given — a kind the
        // protocol does not know stays one; front as given (empty =
        // unknown), sub, pid, landing, err and took empty.
        let cols = ["1", "\(now - ago)", agent, kind, "", session, "", cwd, "", front ?? "", "", tool, "", "", message]
        return cols.joined(separator: "\t")
    }

    static func world(_ lines: [String]) -> TrayState {
        let text = AttentionProtocol.Header(next: 2, gen: "g1").line + lines.joined(separator: "\n") + "\n"
        var book = SessionBook()
        for line in text.split(whereSeparator: \.isNewline) {
            if let record = AttentionRecord(line: line) { book.apply(record, nowMs: now) }
        }
        return TrayState.project(
            book: book, processes: [],
            context: TrayState.Context(nowMs: now, lang: .en)
        )
    }

    static func delivery(_ rows: [AgentRow]) -> WaitingDelivery.Plan {
        WaitingDelivery(
            acknowledged: [], inFlight: [], canDeliverNow: true,
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
        var waitKind: AttentionKind? = nil
        var inFront: Bool = false
    }

    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var lines: [String]
        var agent: AgentID = .claude
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
                line("claude", "turn", ago: 61 * second),
                line("claude", "idle", ago: 1 * second),
            ],
            expect: turn
        ),
        Case(
            name: "claude · permission → red, banner",
            lines: [line("claude", "permission", ago: 5 * second, message: "Bash: rm -rf build")],
            expect: Expect(waiting: true, yourTurn: false, red: true, banner: true, waitKind: .permission)
        ),
        Case(
            name: "claude · question → red, says Input",
            lines: [line("claude", "question", ago: 5 * second, message: "Which database?")],
            expect: Expect(waiting: true, yourTurn: false, red: true, banner: true, waitKind: .question)
        ),
        Case(
            name: "claude · turn ends moments after a permission → held; the permission stands for the grace",
            lines: [
                line("claude", "permission", ago: 6 * second, message: "Bash: npm run build"),
                line("claude", "turn", ago: 1 * second),
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
            lines: [line("claude", "turn", ago: 30 * second), line("claude", "done", ago: 2 * second)],
            expect: quiet
        ),
        Case(
            name: "claude · StopFailure (a failed turn) → your turn, never red",
            lines: [line("claude", "failed", ago: 10 * second, message: "rate_limit")],
            expect: turn
        ),
        Case(
            name: "codex · a word that is not a v8 kind (an approval, a vendor's turn event) → nothing",
            lines: [
                line("codex", "exec_approval_request", ago: 3 * second, message: "git push"),
                line("codex", "agent-turn-complete", ago: 2 * second),
            ],
            agent: .codex,
            expect: quiet
        ),
        Case(
            name: "copilot · permission_prompt → red",
            lines: [line("copilot", "permission", ago: 3 * second, message: "Allow bash?")],
            agent: .copilot,
            expect: Expect(waiting: true, yourTurn: false, red: true, banner: true, waitKind: .permission)
        ),
        Case(
            name: "pi · a select prompt → red, says Input",
            lines: [line("pi", "question", ago: 3 * second, message: "Pick a model")],
            agent: .pi,
            expect: Expect(waiting: true, yourTurn: false, red: true, banner: true, waitKind: .question)
        ),
        Case(
            name: "opencode · permission then replied → cleared",
            lines: [
                line("opencode", "permission", ago: 30 * second, message: "bash: npm test"),
                line("opencode", "done", ago: 2 * second),
            ],
            agent: .opencode,
            expect: quiet
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
            name: "claude · idle with no turn seen → your turn",
            lines: [line("claude", "idle", ago: 2 * second)],
            expect: turn
        ),
    ]

    /// A finished turn is grey even while its CLI stays open — the
    /// green ring is for a session that is working, and "your turn" is not.
    @Test func aFinishedTurnWithALiveProcessIsAGreyLamp() throws {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: .claude, kind: .turn, ms: Self.now - 2 * Self.second, session: "s1", cwd: "/p", pid: 42), nowMs: Self.now)
        let r = TrayState.project(
            book: book, processes: [],
            context: TrayState.Context(nowMs: Self.now, lang: .en)
        )
        let row = try #require(r.rows.first)
        #expect(row.isYourTurn)
        #expect(row.liveProcess)
        #expect(r.snapshot.lamp == .idle)
        #expect(r.snapshot.title == "")
        #expect(r.snapshot.tooltip == L10n.t(.lampRuleTurn, .en))
    }

    @Test(arguments: cases)
    func sequence(_ c: Case) throws {
        let r = Self.world(c.lines)
        guard let row = r.rows.first else {
            // A line that is not a protocol kind makes no session at all.
            #expect(!c.expect.waiting && !c.expect.yourTurn && !c.expect.red && !c.expect.banner)
            return
        }
        #expect(row.isBlocked == c.expect.waiting)
        #expect(row.isYourTurn == c.expect.yourTurn)
        #expect((r.snapshot.lamp == .waiting) == c.expect.red)
        let turns = r.rows.filter { $0.isYourTurn }.count
        #expect(turns == (c.expect.yourTurn ? 1 : 0))
        #expect((row.wait?.inFront ?? false) == c.expect.inFront)
        if let kind = c.expect.waitKind { #expect(row.wait?.kind == kind) }
        let bannered: Bool
        if case .post(let first, let later) = Self.delivery(r.rows) {
            bannered = ([first] + later).contains { $0.key == row.key }
        } else {
            bannered = false
        }
        #expect(bannered == c.expect.banner)
    }

    // MARK: - Beyond the table

    @Test func aToolCallAfterTheTurnEndsYourTurn() throws {
        let r = Self.world([
            Self.line("claude", "turn", ago: 30 * Self.second),
            Self.line("claude", "tool", ago: 5 * Self.second, message: "a.swift"),
        ])
        let row = try #require(r.rows.first)
        #expect(!row.isYourTurn)
    }

    @Test func aTurnThatNamesNoSessionMakesNoRow() {
        let r = Self.world([Self.line("claude", "turn", ago: 5 * Self.second, session: "")])
        #expect(r.rows.isEmpty, "with no session there is no row it could belong to")
    }

    @Test func theReceiverWritesTheProtocolKinds() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-turn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // An explicit file, not a global override: suites run in parallel.
        let attention = home.appendingPathComponent(EventLog.fileName)
        defer { try? FileManager.default.removeItem(at: home) }
        let stop = PulseHookReceiver.interpret(agent: .claude, event: "Stop", payload: [:])
        let failure = PulseHookReceiver.interpret(agent: .claude, event: "StopFailure", payload: [:])
        let precompact = PulseHookReceiver.interpret(agent: .claude, event: "PreCompact", payload: [:])
        #expect(stop?.action == .turn)
        #expect(failure?.action == .failedTurn)
        #expect(precompact == nil, "never installed: not read")

        // The installed Claude hooks pass the vendor's event name.
        let here: (AgentID, [String: String]) -> (pid: Int32, landing: String) = { _, _ in (0, "") }
        let t0: Int64 = 1_780_000_000_000
        PulseHookReceiver.run(arguments: ["PulseBar", "--hook", "claude", "Stop"],
                              stdin: #"{"session_id":"s1","cwd":"/p","last_assistant_message":"All tests pass."}"#,
                              logURL: attention, nowMs: t0,
                              locate: here)
        PulseHookReceiver.run(arguments: ["PulseBar", "--hook", "claude", "UserPromptSubmit"],
                              stdin: #"{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/p","prompt":"next"}"#,
                              logURL: attention, nowMs: t0 + 1_000,
                              locate: here)
        let lines = try String(contentsOf: attention, encoding: .utf8)
            .split(separator: "\n").filter { !$0.hasPrefix("#") }
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
        #expect(lines.map { String($0[3]) } == ["turn", "working"])
        #expect(lines.map { String($0[4]) } == ["Stop", "UserPromptSubmit"], "the vendor's event")
        #expect(lines.map { String($0[0]) } == ["1", "2"], "numbered")
        #expect(lines.allSatisfy { $0.count == AttentionProtocol.columnCount })
        #expect(String(lines[0][14]) == "All tests pass.")
    }

    @Test func everyKindHasOneMeaning() {
        for kind in AttentionKind.allCases {
            #expect(AttentionProtocol.kind(kind.rawValue) == kind)
        }
        let blocking = AttentionKind.allCases.filter { $0.isBlocking }
        #expect(blocking == [.permission, .question, .waiting])
        #expect(!AttentionKind.turn.isBlocking)
        #expect(AttentionKind.turn.isOpen)
        let activity = AttentionKind.allCases.filter { $0.isActivity }
        #expect(activity == [.tool, .status])
        let resolutions = AttentionKind.allCases.filter { $0.isResolution }
        #expect(resolutions == [.done, .dismiss])
    }
}

/// The event log: one append-only file of numbered lines, read from an
/// offset.
@Suite("Event log")
struct EventLogTests {
    let t0: Int64 = 1_800_000_000_000
    static let hour: Int64 = 60 * 60 * 1000

    final class Home {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("pulse-events-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        var log: URL { url.appendingPathComponent(EventLog.fileName) }
        var size: Int {
            ((try? FileManager.default.attributesOfItem(atPath: log.path))?[.size] as? NSNumber)?.intValue ?? 0
        }
    }

    private func record(
        _ kind: AttentionKind, _ ms: Int64, session: String = "s1", message: String = "",
        tool: String = "", cwd: String = "/w", agent: AgentID = .claude, seq: Int64 = 0
    ) -> AttentionRecord {
        AttentionRecord(agent: agent, kind: kind, ms: ms, message: message, session: session, cwd: cwd, tool: tool, seq: seq)
    }

    /// Records numbered from 1, as a log holds them.
    private func numbered(_ records: [AttentionRecord]) -> [AttentionRecord] {
        records.enumerated().map { index, record in
            var copy = record
            copy.seq = Int64(index + 1)
            return copy
        }
    }

    // MARK: - The receiver's side

    @Test func everyHookEventIsOneNumberedLineInOrderAndPrivate() throws {
        let home = Home()
        let here: (AgentID, [String: String]) -> (pid: Int32, landing: String) = { _, _ in (4242, "") }
        let events: [(String, String)] = [
            ("UserPromptSubmit", #"{"session_id":"sess-a","cwd":"/repo","prompt":"Fix the login bug"}"#),
            ("PostToolUse", #"{"session_id":"sess-a","cwd":"/repo","tool_name":"Edit","tool_input":{"file_path":"/repo/src/Main.swift"}}"#),
            ("PostToolUse", #"{"session_id":"sess-a","cwd":"/repo","tool_name":"Bash","tool_input":{"command":"swift test"}}"#),
            ("PostToolUse", #"{"tool_name":"Bash"}"#),
            ("PostToolUse", #"{"session_id":"sess-a","tool_name":"Bash","tool_input":{"command":"deploy with Bearer abc123secretvalue"}}"#),
        ]
        for (offset, event) in events.enumerated() {
            PulseHookReceiver.run(arguments: ["PulseBar", "--hook", "claude", event.0], stdin: event.1,
                                  logURL: home.log, nowMs: t0 + Int64(offset), locate: here)
        }
        let chunk = try #require(EventLog.read(at: home.log, after: nil))
        #expect(chunk.headerLine.hasPrefix(AttentionProtocol.headerPrefix))
        let seqs = chunk.records.map(\.seq)
        #expect(seqs == [1, 2, 3, 4, 5], "every heard event is a line, numbered in order")
        let heard = chunk.records.map(\.kind)
        #expect(heard == [.working, .tool, .tool, .ignored, .tool], "a session-less tool is heard, not a step")
        #expect(chunk.records[3].message == PulseHookReceiver.Ignored.noSession.rawValue)
        let records = chunk.records.filter { $0.kind != .ignored }
        let tools = records.map(\.tool)
        let stamps = records.map(\.ms)
        #expect(tools == ["", "Edit", "Bash", "Bash"])
        #expect(stamps == [t0, t0 + 1, t0 + 2, t0 + 4])
        let target = records[1].message
        #expect(target == "/repo/src/Main.swift")
        let secret = records[3].message
        #expect(!secret.contains("abc123secretvalue"), "\(secret)")
        let attrs = try FileManager.default.attributesOfItem(atPath: home.log.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
    }

    // MARK: - Reading from an offset

    @Test func aReaderGetsOnlyWhatIsNewAndNeverAHalfLine() throws {
        let home = Home()
        EventLog.append(record(.working, t0), at: home.log, nowMs: t0)
        let first = try #require(EventLog.read(at: home.log, after: nil))
        #expect(first.records.count == 1)
        let cursor = first.advancing(nil)
        // Nothing new.
        let none = try #require(EventLog.read(at: home.log, after: cursor))
        #expect(none.records.isEmpty)
        // A writer mid-line: the partial line waits for the next read.
        var bytes = try Data(contentsOf: home.log)
        bytes.append(Data("2\t\(t0 + 1)\tclaude\tturn".utf8))
        try bytes.write(to: home.log)
        let partial = try #require(EventLog.read(at: home.log, after: cursor))
        #expect(partial.records.isEmpty)
        #expect(partial.end == first.end)
        // The next append starts on its own line, numbered past the last
        // whole one.
        EventLog.append(record(.tool, t0 + 2, tool: "Read"), at: home.log, nowMs: t0 + 2)
        let next = try #require(EventLog.read(at: home.log, after: cursor))
        let kinds = next.records.map(\.kind)
        #expect(kinds == [.tool], "the torn line is dropped, the new one is whole")
        let seq = next.records.first?.seq
        #expect(seq == 2)
    }

    /// A missing file is an empty log, so the launch replay is over and the
    /// first wait written after it is news. A file that exists but cannot be
    /// read is a failed read (nil — the caller keeps its state).
    @Test func aMissingFileIsAnEmptyLogAndAnUnreadableOneAFailedRead() throws {
        let home = Home()
        let fresh = EventLog.read(at: home.log, after: nil)
        #expect(fresh == EventLog.Chunk.empty)
        EventLog.append(record(.working, t0), at: home.log, nowMs: t0)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: home.log.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.log.path) }
        let unreadable = EventLog.read(at: home.log, after: nil)
        #expect(unreadable == nil)
    }

    /// Lines end at `\n` bytes only: a U+2028, a NEL or a lone `\r` inside a
    /// field (a writer that did not clean it) never splits a record. And the
    /// receiver cleans every kind of line break out of a field.
    @Test func aLineBreakInsideAFieldNeverSplitsARecord() throws {
        let odd = "1\t\(t0)\tclaude\tpermission\tPermissionRequest\ts1\t\t/w\t\t\t\tBash\t\t\tBash: a\u{2028}b\u{85}c\rd\n"
        let data = Data((AttentionProtocol.Header(next: 2, gen: "g1").line + odd).utf8)
        let parsed = EventLog.parse(data, from: 0)
        #expect(parsed.records.count == 1)
        let record = try #require(parsed.records.first)
        #expect(record.session == "s1")
        #expect(record.tool == "Bash")
        let cleaned = PulseHookReceiver.cleanField("a\u{2028}b\u{0B}c\u{85}d\u{2029}e\u{0C}f\r\ng\th", limit: 100)
        #expect(cleaned == "a b c d e f  g h")
        #expect(AttentionProtocol.flatten("x\u{2028}") == "x")
    }

    // MARK: - The numbering

    /// A reader applies the lines numbered past the last it applied — of
    /// the log it read; every line of another log. No log there moves
    /// nothing.
    @Test func aReaderAppliesOnlyWhatIsNumberedPastItsCursor() {
        let header = AttentionProtocol.Header(next: 4, gen: "gA")
        let records = numbered([record(.working, t0), record(.tool, t0 + 1, tool: "Read"), record(.tool, t0 + 2, tool: "Edit")])
        let chunk = EventLog.Chunk(header: header, records: records, end: 300)
        let at2 = EventLog.Cursor(header: "# old", offset: 10, gen: "gA", seq: 2)
        let past2 = chunk.unapplied(after: at2).map { $0.seq }
        #expect(past2 == [3], "a rewrite of the same log: only what is new")
        let fromNothing = chunk.unapplied(after: nil).map { $0.seq }
        #expect(fromNothing == [1, 2, 3])
        let other = EventLog.Cursor(header: "# old", offset: 10, gen: "gB", seq: 9)
        let startedOver = chunk.unapplied(after: other).map { $0.seq }
        #expect(startedOver == [1, 2, 3], "a log started over is new from its first line")
        let moved = chunk.advancing(at2)
        #expect(moved == EventLog.Cursor(header: chunk.headerLine, offset: 300, gen: "gA", seq: 3))
        let stale = EventLog.Chunk(header: header, records: Array(records.prefix(1)), end: 100)
        #expect(stale.advancing(moved)?.seq == 3, "an older chunk never moves the numbering back")
        #expect(EventLog.Chunk.empty.unapplied(after: at2).isEmpty)
        #expect(EventLog.Chunk.empty.advancing(at2) == at2, "no log there moves nothing")
    }

    /// The appender numbers every line under the lock: one past the last,
    /// the header's `next` for the first.
    @Test func appendsAreNumberedUnderTheLock() throws {
        let home = Home()
        for index in 0..<3 {
            #expect(EventLog.append(record(.tool, t0 + Int64(index), tool: "Read", seq: 99), at: home.log, nowMs: t0))
        }
        let chunk = try #require(EventLog.read(at: home.log, after: nil))
        let seqs = chunk.records.map(\.seq)
        #expect(seqs == [1, 2, 3], "a record's own seq is never written")
        EventLog.ensureExists(at: home.log, nowMs: t0)
        let header = try #require(chunk.header)
        let again = try #require(EventLog.read(at: home.log, after: nil))
        #expect(again.header == header, "ensureExists leaves a v8 log alone")
    }

    /// A compaction keeps what a replay rebuilds a session's own facts
    /// from: its first clock, the prompt its title came from and its latest
    /// prompt — so after a rewrite and a replay the row says the same title
    /// and the same age.
    @Test func compactionKeepsTheTitleAndTheFirstClock() {
        let now = t0
        let base = now - 5 * Self.hour
        var lines = [
            record(.start, base, session: "t"),
            record(.working, base + 1_000, session: "t", message: "continue"),
            record(.working, base + 2_000, session: "t", message: "Fix the login redirect"),
        ]
        for index in 0..<300 { lines.append(record(.tool, base + 10_000 + Int64(index), session: "t", tool: "Read")) }
        lines.append(record(.working, base + 20_000, session: "t", message: "Now the logout"))
        for index in 0..<300 { lines.append(record(.tool, base + 30_000 + Int64(index), session: "t", tool: "Edit")) }
        lines = numbered(lines)
        func replay(_ records: [AttentionRecord]) -> SessionBook.Session? {
            var book = SessionBook()
            for record in records { book.apply(record, nowMs: now) }
            return book.sessions[SessionKey(.claude, "t")]
        }
        let kept = EventLog.compact(lines, nowMs: now, budget: 1 << 30)
        #expect(kept.count < lines.count)
        let seqs = kept.map(\.seq)
        #expect(seqs == seqs.sorted(), "kept lines keep their numbers, in order")
        let before = replay(lines)
        let after = replay(kept)
        #expect(before?.title == "Fix the login redirect")
        #expect(after?.title == before?.title)
        #expect(after?.startedMs == before?.startedMs)
        #expect(after?.lastPrompt == before?.lastPrompt)
        #expect(after?.turnStartMs == before?.turnStartMs)
        let state = HookFeed.word(after?.state)
        #expect(state == HookFeed.word(before?.state))
        // A tight budget keeps them too.
        let tight = replay(EventLog.compact(lines, nowMs: now, budget: 1_000))
        #expect(tight?.title == before?.title)
        #expect(tight?.startedMs == before?.startedMs)
    }

    /// A compaction keeps what a replay rebuilds the vendor's name from (the
    /// latest `title` line), never takes a subagent's prompt for the
    /// person's, and keeps a subagent's open block while only another
    /// subagent's tools follow it.
    @Test func compactionKeepsTheNameAndASubagentsOpenBlock() {
        let now = t0
        let base = now - 5 * Self.hour
        var lines = [
            record(.start, base, session: "t", agent: .pi),
            record(.title, base + 500, session: "t", message: "Release 31", agent: .pi),
            record(.working, base + 1_000, session: "t", message: "Bump the version", agent: .pi),
        ]
        var sub = record(.working, base + 1_500, session: "t", message: "Search for version strings", agent: .pi)
        sub.sub = "a1"
        lines.append(sub)
        for index in 0..<300 { lines.append(record(.tool, base + 10_000 + Int64(index), session: "t", tool: "read", agent: .pi)) }
        var raised = record(.permission, base + 20_000, session: "c", message: "Bash: rm -rf build", tool: "Bash")
        raised.sub = "a1"
        lines.append(raised)
        for index in 0..<300 {
            var other = record(.tool, base + 30_000 + Int64(index), session: "c", tool: "Bash")
            other.sub = "a2"
            lines.append(other)
        }
        lines = numbered(lines)
        func replay(_ records: [AttentionRecord]) -> SessionBook {
            var book = SessionBook()
            for record in records { book.apply(record, nowMs: now) }
            return book
        }
        let tight = replay(EventLog.compact(lines, nowMs: now, budget: 1_000))
        let named = tight.sessions[SessionKey(.pi, "t")]
        #expect(named?.shownTitle == "Release 31")
        #expect(named?.title == "Bump the version")
        let blocked = HookFeed.word(tight.sessions[SessionKey(.claude, "c")]?.state)
        #expect(blocked == "blocked:permission", "another subagent's tools do not answer it")
        #expect(HookFeed.word(replay(lines).sessions[SessionKey(.claude, "c")]?.state) == "blocked:permission")
    }

    /// The record being appended is always in the file after its own
    /// compaction — even one older than the retention window.
    @Test func theAppendedRecordSurvivesItsOwnCompaction() throws {
        let home = Home()
        var ms = t0
        let pad = String(repeating: "y", count: 180)
        while home.size < EventLog.maxBytes - 300 {
            EventLog.append(record(.tool, ms, session: "busy", message: pad, tool: "Read"), at: home.log, nowMs: ms)
            ms += 1
        }
        // Longer than the room left, so this append compacts.
        let ancient = record(.turn, t0 - 3 * EventLog.retentionMs, session: "late", message: String(repeating: "z", count: 400))
        #expect(EventLog.append(ancient, at: home.log, nowMs: ms))
        let chunk = try #require(EventLog.read(at: home.log, after: nil))
        let last = try #require(chunk.records.last)
        #expect(last.session == "late")
        #expect(last.message == ancient.message)
        let newest = chunk.records.map { $0.seq }.max()
        #expect(last.seq == newest, "the newest number")
        #expect(home.size < EventLog.maxBytes)
    }

    @Test func aCursorFromAnotherHeaderReadsTheWholeFileAgain() throws {
        let home = Home()
        EventLog.append(record(.working, t0), at: home.log, nowMs: t0)
        let first = try #require(EventLog.read(at: home.log, after: nil))
        let header = try #require(first.header)
        let stale = EventLog.Cursor(header: "# pulse-events v8 next=1 gen=gOLD", offset: first.end, gen: "gOLD", seq: 1)
        let again = try #require(EventLog.read(at: home.log, after: stale))
        #expect(again.records == first.records, "read whole")
        #expect(again.unapplied(after: stale).count == 1, "another log: every line is new")
        let past = EventLog.Cursor(header: first.headerLine, offset: first.end + 10_000, gen: header.gen, seq: 1)
        let shorter = try #require(EventLog.read(at: home.log, after: past))
        #expect(shorter.records == first.records, "a file shorter than the cursor was rewritten: read whole")
        #expect(shorter.unapplied(after: past).isEmpty, "and nothing it already applied is applied again")
    }

    /// A log that is not v8 — an older header, or none — is never read and
    /// never migrated: a read finds it empty, and the next writer (the
    /// launch's `ensureExists`, or an append) starts a fresh v8 log.
    @Test func aLogThatIsNotV7IsTreatedAsAbsentAndStartedOver() throws {
        let home = Home()
        let old = "# pulse-events v6 g1 (agent)\nclaude\tpermission\t\(t0)\tBash: make\ts1\t/w\t\t\t\tBash\n"
        try Data(old.utf8).write(to: home.log)
        let unread = try #require(EventLog.read(at: home.log, after: nil))
        #expect(unread == EventLog.Chunk.empty)
        EventLog.ensureExists(at: home.log, nowMs: t0)
        let fresh = String(decoding: try Data(contentsOf: home.log), as: UTF8.self)
        #expect(fresh.hasPrefix(AttentionProtocol.headerPrefix), "\(fresh)")
        #expect(!fresh.contains("Bash: make"), "the old lines are gone, unread")

        let headerless = Home()
        try Data("claude\tturn\t\(t0)\t\ts1\t/w\t\t\t\t\n".utf8).write(to: headerless.log)
        #expect(EventLog.append(record(.working, t0 + 1), at: headerless.log, nowMs: t0 + 1))
        let chunk = try #require(EventLog.read(at: headerless.log, after: nil))
        #expect(chunk.headerLine.hasPrefix(AttentionProtocol.headerPrefix))
        let kinds = chunk.records.map(\.kind)
        #expect(kinds == [.working], "only the line appended after the start over")
        let seq = chunk.records.first?.seq
        #expect(seq == 1, "a new log numbers from 1")
    }

    /// A log started over while the app reads it is a new `gen`: its lines
    /// are applied from the first, though their numbers start again.
    @Test func aLogStartedOverIsAppliedWhole() throws {
        let home = Home()
        for index in 0..<3 { EventLog.append(record(.tool, t0 + Int64(index), tool: "Read"), at: home.log, nowMs: t0) }
        let first = try #require(EventLog.read(at: home.log, after: nil))
        let cursor = first.advancing(nil)
        try FileManager.default.removeItem(at: home.log)
        EventLog.append(record(.permission, t0 + 10, message: "Bash: make", tool: "Bash"), at: home.log, nowMs: t0 + 10)
        let next = try #require(EventLog.read(at: home.log, after: cursor))
        #expect(next.header?.gen != cursor?.gen)
        let fresh = next.unapplied(after: cursor).map(\.kind)
        #expect(fresh == [.permission])
    }

    /// One invalid byte (a hook cut off mid-character) never erases what
    /// is there: appends never rewrite, and reads are lossy.
    @Test func anInvalidByteDoesNotEraseOpenWaits() throws {
        let home = Home()
        var bytes = Data(AttentionProtocol.Header(next: 2, gen: "g1").line.utf8)
        bytes.append(Data((record(.permission, t0, message: "Bash: npm test", seq: 1).line + "\n").utf8))
        bytes.append(Data([0x63, 0x6f, 0xff, 0x0a]))
        try bytes.write(to: home.log)
        EventLog.append(record(.done, t0, session: "s2", agent: .codex), at: home.log, nowMs: t0)
        let chunk = try #require(EventLog.read(at: home.log, after: nil))
        let kinds = chunk.records.map(\.kind)
        #expect(kinds == [.permission, .done])
        let seqs = chunk.records.map(\.seq)
        #expect(seqs == [1, 2])
    }

    // MARK: - Compaction

    /// An append past the bound compacts: the same log (`gen`), a new
    /// header, every kept line under its own number, the newest line kept,
    /// and an open block kept however old. A reader at its old cursor reads
    /// the file whole and applies only what is new.
    @Test func anAppendPastTheBoundCompactsKeepingTheNumbers() throws {
        let home = Home()
        let old = t0 - 5 * Self.hour
        EventLog.append(record(.permission, old, session: "keep-me", message: "Bash: make", tool: "Bash"), at: home.log, nowMs: old)
        let before = try #require(EventLog.read(at: home.log, after: nil))
        let cursor = try #require(before.advancing(nil))
        var ms = old + 1
        let pad = String(repeating: "x", count: 180)
        while home.size < EventLog.maxBytes - 400 {
            EventLog.append(record(.tool, ms, session: "busy", message: pad, tool: "Read"), at: home.log, nowMs: ms)
            ms += 1
        }
        let full = try #require(EventLog.read(at: home.log, after: nil))
        let appendedBefore = full.records.count
        EventLog.append(record(.tool, t0, session: "busy", message: pad, tool: "Read"), at: home.log, nowMs: t0)
        EventLog.append(record(.tool, t0 + 1, session: "busy", message: pad, tool: "Read"), at: home.log, nowMs: t0 + 1)
        let after = try #require(EventLog.read(at: home.log, after: cursor))
        #expect(after.headerLine != before.headerLine, "a rewrite: the old cursor reads the whole file")
        #expect(after.header?.gen == cursor.gen, "the same log")
        #expect(home.size < EventLog.maxBytes)
        let kept = after.records.first { $0.session == "keep-me" && $0.kind == .permission }
        #expect(kept?.seq == 1, "an open block is never dropped, and keeps its number")
        let newest = after.records.last
        #expect(newest?.ms == t0 + 1, "the newest line is kept")
        #expect(newest?.seq == Int64(appendedBefore + 2))
        let unapplied = after.unapplied(after: cursor)
        #expect(!unapplied.contains { $0.seq <= cursor.seq }, "nothing applied is applied again")
        // The header's `next` is a floor, not a counter: the next line
        // continues after the newest one, whatever the header says.
        EventLog.append(record(.tool, t0 + 2, session: "busy", message: pad, tool: "Read"), at: home.log, nowMs: t0 + 2)
        let last = try #require(EventLog.read(at: home.log, after: nil)).records.last
        #expect(last?.seq == (newest?.seq ?? 0) + 1, "numbers continue after a compaction")
    }

    /// Compaction keeps a block together with what answers it, groups a
    /// session-less line by agent and folder, and forgets a day-old session.
    @Test func compactionKeepsPerSessionHistory() {
        let now = t0
        let base = now - 3 * Self.hour
        var lines: [AttentionRecord] = []
        // An answered block, then a long tail in the same session.
        lines.append(record(.permission, base, session: "a", message: "Bash: ls", tool: "Bash"))
        lines.append(record(.tool, base + 1_000, session: "a", tool: "Bash"))
        for index in 0..<200 { lines.append(record(.tool, base + 2_000 + Int64(index), session: "a", tool: "Read")) }
        // An open block with parallel tools and status after it that do not
        // answer it.
        lines.append(record(.permission, base + 10_000, session: "b", message: "Bash: make", tool: "Bash"))
        for index in 0..<100 { lines.append(record(index % 10 == 0 ? .status : .tool, base + 11_000 + Int64(index), session: "b", tool: index % 10 == 0 ? "" : "Read")) }
        // Two session-less folders of one agent.
        lines.append(record(.permission, base + 20_000, session: "", message: "Allow?", cwd: "/one", agent: .copilot))
        for index in 0..<100 { lines.append(record(.start, base + 21_000 + Int64(index), session: "", cwd: "/two", agent: .copilot)) }
        // A session nobody has heard from for two days.
        lines.append(record(.turn, now - 2 * EventLog.retentionMs, session: "gone"))
        lines = numbered(lines)

        let records = EventLog.compact(lines, nowMs: now, budget: 1 << 30)
        let a = records.filter { $0.session == "a" }
        #expect(a.count == EventLog.linesPerSession + 1, "a session keeps its last lines once nothing in it is open, and its first clock")
        #expect(!a.contains { $0.kind == .permission }, "an answered block is never kept without its answer")
        let b = records.filter { $0.session == "b" }
        #expect(b.first?.kind == .permission, "an open block is kept, with every line after it")
        #expect(b.count == 101)
        let folder = records.contains { $0.agent == .copilot && $0.cwd == "/one" }
        #expect(folder, "a session-less wait is not pushed out by another folder's lines")
        let gone = records.contains { $0.session == "gone" }
        #expect(!gone)

        // A tight budget still keeps the open blocks.
        let tight = EventLog.compact(lines, nowMs: now, budget: 1_000)
        let openB = tight.contains { $0.session == "b" && $0.kind == .permission }
        let openOne = tight.contains { $0.cwd == "/one" && $0.kind == .permission }
        #expect(openB)
        #expect(openOne)
        // A dismissal's session-less `dismiss` names its folder: it answers
        // that folder's block only, so another folder's open block stays.
        let dismissed = lines + [record(.dismiss, base + 30_000, session: "", cwd: "/two", agent: .copilot, seq: 9_999)]
        let afterDismiss = EventLog.compact(dismissed, nowMs: now, budget: 1_000)
        let stillOpen = afterDismiss.contains { $0.cwd == "/one" && $0.kind == .permission }
        #expect(stillOpen, "a dismiss for /two is not an answer in /one")
        // Recent lines all stay.
        let recent = numbered((0..<300).map { record(.tool, now - 1_000 + Int64($0), session: "hot", tool: "Read") })
        #expect(EventLog.compact(recent, nowMs: now, budget: 1 << 30).count == 300)
    }
}

/// The stop grace is a function of the two lines, not of when the file is read.
@Suite("Stop grace")
struct StopGraceTests {
    let now: Int64 = 1_800_000_000_000
    static let minute: Int64 = 60_000

    @Test func theStopGraceDoesNotDependOnWhenTheFileIsRead() {
        let raise = now - 10 * Self.minute
        let text = AttentionBookTests.tsv([
            ["claude", "permission", "\(raise)", "Bash: npm test", "s1", "/p"],
            ["claude", "turn", "\(raise + 1_000)", "", "s1", ""],
        ])
        func read(at nowMs: Int64) -> String {
            var book = SessionBook()
            for line in text.split(whereSeparator: \.isNewline) {
                if let record = AttentionRecord(line: line) { book.apply(record, nowMs: nowMs) }
            }
            return HookFeed.word(book.sessions[SessionKey(.claude, "s1")]?.state)
        }
        #expect(read(at: raise + 2_000) == "blocked:permission")
        #expect(read(at: now) == read(at: raise + 2_000), "re-reading ten minutes later flipped the verdict")
    }
}

/// Codex is wired by its hooks.json alone.
@Suite("Codex hooks detection")
struct CodexHooksDetectionTests {
    // MARK: - Codex hooks.json counts as installed

    @Test func codexHooksJSONAloneCountsAsInstalled() {
        let hooks = #"{"hooks":{"Stop":[{"hooks":[{"command":"/x/pulse-hook codex Stop"}]}]}}"#
        #expect(HooksInstaller.installedEvents(.codex, text: hooks) == ["Stop"])
        #expect(HooksInstaller.installedEvents(.codex, text: "{}") == [])
    }
}
