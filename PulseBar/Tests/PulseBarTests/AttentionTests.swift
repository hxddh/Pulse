import Foundation
import Testing
import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

// Attention: the protocol read into the session book, the hook receiver and
// activity spool, the hooks installer.

/// 24.0 · the attention file as the book reads it: every complete v4 line,
/// in file order. (It was `AttentionReader`, a last-event-wins map with a
/// TTL; the book keeps sessions, and the time rules live in the projection.)
final class AttentionBookTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000

    /// Rows are padded to the ten v4 columns (front, pid, transcript and
    /// landing empty).
    private func tsv(_ rows: [[String]]) -> String {
        rows.map { row in
            (row + Array(repeating: "", count: max(0, AttentionProtocol.columnCount - row.count)))
                .joined(separator: "\t")
        }.joined(separator: "\n") + "\n"
    }

    private func book(_ text: String) -> SessionBook {
        var book = SessionBook()
        for line in text.split(whereSeparator: \.isNewline) {
            if let record = AttentionRecord(line: line) { book.apply(record, nowMs: now) }
        }
        return book
    }

    private func state(_ book: SessionBook, _ key: String) -> String {
        HookFeed.word(book.sessions[key]?.state)
    }

    private func block(_ book: SessionBook, _ key: String) -> SessionBook.Block? {
        if case .blocked(let block) = book.sessions[key]?.state { return block }
        return nil
    }

    func testTheLatestEventDecidesTheSession() {
        let b = book(tsv([
            ["claude", "permission", "\(now - 5000)", "first", "s1", "/p"],
            ["claude", "question", "\(now - 1000)", "second", "s1", "/p"],
        ]))
        XCTAssertEqual(state(b, "claude|s1"), "blocked:question")
        XCTAssertEqual(block(b, "claude|s1")?.ask, "second")
    }

    func testDoneAnswersTheSession() {
        let b = book(tsv([
            ["claude", "permission", "\(now - 5000)", "approve", "s1", "/p"],
            ["claude", "done", "\(now - 1000)", "", "s1", ""],
        ]))
        XCTAssertEqual(state(b, "claude|s1"), "working")
    }

    /// 23.0 bug: dismissing a session-less hook wait wrote a session-less
    /// `done`, which cleared every session of that agent. A `done` clears
    /// exactly what it names: an empty session, only session-less entries.
    func testASessionlessDoneClearsOnlyTheSessionlessEntry() {
        let b = book(tsv([
            ["claude", "permission", "\(now - 5000)", "a", "s1", "/p"],
            ["claude", "permission", "\(now - 4000)", "b", "s2", "/q"],
            ["claude", "permission", "\(now - 3000)", "c", "", "/r"],
            ["claude", "done", "\(now - 1000)", "", "", ""],
        ]))
        XCTAssertEqual(state(b, "claude|s1"), "blocked:permission", "the sessions' own waits stay")
        XCTAssertEqual(state(b, "claude|s2"), "blocked:permission")
        XCTAssertEqual(state(b, RowIdentity.session(agent: .claude, session: "", cwd: "/r")), "working")
    }

    func testStopKeepsAFreshPermissionWithinGrace() {
        // The order of Claude's events is not ours; a turn ending moments
        // after a permission was raised must not wipe it.
        let b = book(tsv([
            ["claude", "permission", "\(now - 1000)", "approve", "s1", "/p"],
            ["claude", "stop", "\(now)", "", "s1", ""],
        ]))
        XCTAssertEqual(state(b, "claude|s1"), "blocked:permission", "recent permission survives a Stop")
    }

    func testStopClearsAnAgedPermissionAndLeavesYourTurn() {
        let old = now - SessionBook.stopGraceMs - 5000
        let b = book(tsv([
            ["claude", "permission", "\(old)", "approve", "s1", "/p"],
            ["claude", "stop", "\(now)", "", "s1", ""],
        ]))
        XCTAssertEqual(state(b, "claude|s1"), "turn", "the permission is gone; what is left is not red")
    }

    /// A wait whose process Pulse cannot see is not red forever: past the
    /// idle bound it is shown as recent (the projection's rule).
    func testAnUnprovableWaitGoesQuietAfterTheIdleBound() throws {
        let b = book(tsv([["claude", "permission", "\(now - 1000)", "old", "s1", "/p"]]))
        let session = try XCTUnwrap(b.sessions["claude|s1"])
        XCTAssertEqual(
            SessionProjection.state(of: session, nowMs: now),
            .blocked(RowWait(kind: "Permission", ask: "old", sinceMs: now - 1000))
        )
        XCTAssertEqual(SessionProjection.state(of: session, nowMs: now + SessionProjection.idleBoundMs + 1), .recent)
    }

    func testSubagentEventsNeverRaiseWaiting() {
        XCTAssertTrue(book(tsv([["claude", "subagent_start", "\(now)", "", "s1", "/p"]])).sessions.isEmpty)
    }

    func testUnknownKindNeverRaisesWaiting() {
        let b = book(tsv([["gemini", "totally_fake_kind", "\(now)", "nope", "s1", "/p"]]))
        XCTAssertTrue(b.sessions.isEmpty, "free-text kinds must never light Waiting")
    }

    func testProtocolHeaderIsIgnoredAsComment() {
        let b = book(AttentionProtocol.header + tsv([
            ["gemini", "waiting", "\(now - 1000)", "Need choice", "j1", "/w"],
        ]))
        XCTAssertEqual(Array(b.sessions.keys), ["gemini|j1"])
        XCTAssertEqual(state(b, "gemini|j1"), "blocked:waiting")
    }

    func testCommentsAndShortRowsAreSkipped() {
        XCTAssertTrue(book("# header\nclaude\tpermission\n\n").sessions.isEmpty)
    }

    /// 24.0: v4 needs all ten columns. A v3 (eight-column) line is not read.
    func testAnOlderShorterLineIsNotRead() throws {
        let v1 = "claude\tpermission\t\(now - 1000)\tapprove\ts1\t/p\n"
        let v3 = "claude\tpermission\t\(now - 1000)\tapprove\ts1\t/p\t\t\n"
        XCTAssertTrue(book(v1).sessions.isEmpty)
        XCTAssertTrue(book(v3).sessions.isEmpty)
        let v4 = "claude\tpermission\t\(now - 1000)\tapprove\ts1\t/p\t\t4242\t/t.jsonl\ttmux:%3\n"
        let session = try XCTUnwrap(book(v4).sessions["claude|s1"])
        XCTAssertEqual(session.pid, 4242)
        XCTAssertEqual(session.transcript, "/t.jsonl")
        XCTAssertEqual(session.landing, "tmux:%3")
    }

    /// 24.0: a hand-written blocked line for an agent whose hooks cannot
    /// report a block is not a wait; its turn still is its turn.
    func testAWaitingNoneAgentIsNeverBlockedByALine() {
        let b = book(tsv([
            ["codex", "permission", "\(now - 3000)", "approve", "x1", "/p"],
            ["cursor", "question", "\(now - 2000)", "which?", "c1", "/p"],
            ["codex", "turn", "\(now - 1000)", "", "x2", "/p"],
        ]))
        XCTAssertEqual(Array(b.sessions.keys), ["codex|x2"])
        XCTAssertEqual(state(b, "codex|x2"), "turn")
    }

    /// 24.0: the lifecycle kinds each say what the session does next.
    func testStartWorkingAndEndAfterATurn() {
        let expected = ["start": "idle", "working": "working", "end": "ended"]
        for (kind, word) in expected {
            let b = book(tsv([
                ["claude", "turn", "\(now - 5000)", "", "s1", "/p"],
                ["claude", kind, "\(now - 1000)", "", "s1", "/p"],
            ]))
            XCTAssertEqual(state(b, "claude|s1"), word, kind)
        }
    }

    func testALaterSilentEventDoesNotEraseTheReason() throws {
        // One approval makes Claude raise both Notification and
        // PermissionRequest; only one carries text and the order is not ours.
        let b = book(tsv([
            ["claude", "permission", "\(now - 2000)", "Bash: npm run build", "c1", "/w"],
            ["claude", "permission", "\(now - 1000)", "", "c1", "/w"],
        ]))
        let wait = try XCTUnwrap(block(b, "claude|c1"))
        XCTAssertEqual(wait.ask, "Bash: npm run build")
        XCTAssertEqual(wait.sinceMs, now - 1000, "the newer event still owns the clock")
    }

    /// The grace is measured between the two lines, not against the clock
    /// the file is read at.
    func testAStopStillClearsAPermissionPastTheGraceWindow() {
        let old = now - 60_000
        let b = book([
            "claude\tpermission\t\(old)\tBash: npm run build\tsession-10\t/Users/me/Pulse\t\t\t\t",
            "claude\tstop\t\(old + SessionBook.stopGraceMs + 1)\t\tsession-10\t\t\t\t\t",
        ].joined(separator: "\n") + "\n")
        XCTAssertEqual(state(b, "claude|session-10"), "turn")
    }
}

final class PulseHookReceiverTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-hook-recv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        AttentionIO.pathOverride = tempHome.appendingPathComponent("attention.tsv")
        ActivitySpool.directoryOverride = tempHome.appendingPathComponent("activity.d", isDirectory: true)
    }

    override func tearDownWithError() throws {
        AttentionIO.pathOverride = nil
        ActivitySpool.directoryOverride = nil
        try? FileManager.default.removeItem(at: tempHome)
    }

    /// A fixed answer for the agent pid and landing handles.
    private let located: (AgentID, [String: String]) -> (pid: Int32, landing: String) = { _, _ in
        (4242, "tmux:%3;tty:/dev/ttys004")
    }

    /// Run one vendor event through the receiver, as its installed hook does.
    @discardableResult
    private func deliver(_ agent: String, _ event: String, _ payload: String) -> Int32 {
        var arguments = ["PulseBar", "--hook", agent]
        if !event.isEmpty { arguments.append(event) }
        return PulseHookReceiver.run(arguments: arguments, stdin: payload, locate: located)
    }

    private func records() -> [AttentionRecord] {
        let text = (try? String(contentsOf: AttentionIO.path, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { AttentionRecord(line: $0) }
    }

    private func kinds() -> [String] {
        records().map { $0.kind }
    }

    // MARK: - The protocol's own words

    func testTheProtocolSeparatesAQuestionFromYourTurn() {
        XCTAssertEqual(AttentionProtocol.normalizeKind("elicitation_dialog"), "question")
        XCTAssertEqual(AttentionProtocol.normalizeKind("permission_prompt"), "permission")
        XCTAssertEqual(AttentionProtocol.normalizeKind("agent-turn-complete"), "turn")
        XCTAssertEqual(AttentionProtocol.normalizeKind("idle_prompt"), "turn",
                       "Claude's idle_prompt is a 60 s timer after every finished turn")
        XCTAssertEqual(AttentionProtocol.normalizeKind("stop"), "turn")
        XCTAssertEqual(AttentionProtocol.normalizeKind("session_start"), "start")
        XCTAssertEqual(AttentionProtocol.normalizeKind("prompt"), "working")
        XCTAssertEqual(AttentionProtocol.normalizeKind("session_end"), "end")
        XCTAssertNotEqual(AttentionProtocol.kind("idle_prompt")?.isBlocking, true)
        XCTAssertTrue(AttentionProtocol.acceptsWrite(kind: "permission"))
        XCTAssertFalse(AttentionProtocol.acceptsWrite(kind: "totally_made_up_kind"))
        // 24.0: no free-text guessing — "…approval…" is not a permission.
        XCTAssertFalse(AttentionProtocol.acceptsWrite(kind: "exec_approval_request"))
        XCTAssertTrue(AttentionKind.start.clears && AttentionKind.working.clears && AttentionKind.end.clears)
    }

    /// v4: ten columns, and a record survives its own line.
    func testAV4RecordRoundTrips() throws {
        let record = AttentionRecord(
            agent: "claude", kind: "permission", ms: 1_800_000_000_000,
            message: "Bash: npm test", session: "s1", cwd: "/w", front: false,
            pid: 4242, transcript: "/Users/me/.claude/projects/w/s1.jsonl",
            landing: "tmux:%3;tty:/dev/ttys004"
        )
        XCTAssertEqual(record.line.split(separator: "\t", omittingEmptySubsequences: false).count, 10)
        XCTAssertEqual(AttentionRecord(line: record.line), record)
        let unknown = AttentionRecord(agent: "codex", kind: "turn", ms: 1)
        XCTAssertEqual(AttentionRecord(line: unknown.line), unknown, "empty columns stay empty")
        XCTAssertNil(AttentionRecord(line: "claude\tpermission\t1\tx\ts\t/p\t\t"), "a v3 line is not read")
        XCTAssertTrue(AttentionProtocol.header.hasPrefix("# pulse-attention v4"))
    }

    // MARK: - Claude (code.claude.com/docs/en/hooks)

    func testClaudePermissionRequestIsABlockThatNamesTheAsk() throws {
        deliver("claude", "PermissionRequest", #"""
        {"session_id":"c9","transcript_path":"/Users/me/.claude/projects/w/c9.jsonl","cwd":"/w",
         "permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"Bash",
         "tool_input":{"command":"npm run build","description":"Build"}}
        """#)
        let record = try XCTUnwrap(records().first)
        XCTAssertEqual(record.kind, "permission")
        XCTAssertEqual(record.message, "Bash: npm run build")
        XCTAssertEqual(record.session, "c9")
        XCTAssertEqual(record.cwd, "/w")
        XCTAssertEqual(record.transcript, "/Users/me/.claude/projects/w/c9.jsonl")
        XCTAssertEqual(record.pid, 4242)
        XCTAssertEqual(record.landing, "tmux:%3;tty:/dev/ttys004")
    }

    func testClaudeAskUserQuestionIsAQuestion() {
        deliver("claude", "PermissionRequest", #"{"session_id":"c1","cwd":"/w","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{}}"#)
        XCTAssertEqual(kinds(), ["question"])
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
        XCTAssertEqual(kinds(), ["permission", "question", "question", "turn"], "auth_success says nothing Pulse shows")
    }

    func testClaudeLifecycleAndTurn() {
        deliver("claude", "SessionStart", #"{"session_id":"s1","cwd":"/w","hook_event_name":"SessionStart","source":"startup"}"#)
        deliver("claude", "UserPromptSubmit", #"{"session_id":"s1","cwd":"/w","hook_event_name":"UserPromptSubmit","prompt":"Fix the login"}"#)
        deliver("claude", "PostToolUse", #"{"session_id":"s1","cwd":"/w","hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"/w/a.swift"}}"#)
        deliver("claude", "Stop", #"{"session_id":"s1","cwd":"/w","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"All tests pass."}"#)
        deliver("claude", "SessionEnd", #"{"session_id":"s1","cwd":"/w","hook_event_name":"SessionEnd","reason":"exit"}"#)
        XCTAssertEqual(kinds(), ["start", "working", "turn", "end"], "a tool call is activity, never an attention line")
        XCTAssertEqual(records().first { $0.kind == "turn" }?.message, "All tests pass.")
        let spool = ActivitySpool.readEvents(nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        XCTAssertEqual(spool.first?.tool, "Edit")
    }

    /// A 23.0 entry names no event; the payload does.
    func testALegacyClaudeEntryIsReadFromItsPayload() {
        deliver("claude", "", #"{"hook_event_name":"PermissionRequest","tool_name":"Edit","tool_input":{"file_path":"/w/a"},"session_id":"c1"}"#)
        XCTAssertEqual(kinds(), ["permission"])
    }

    // MARK: - Codex (openai/codex codex-rs/hooks)

    func testCodexStopAndNotifyAreYourTurnAndItNeverBlocks() {
        deliver("codex", "Stop", #"{"session_id":"x1","turn_id":"t1","transcript_path":null,"cwd":"/w","hook_event_name":"Stop","model":"gpt-5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":"Done."}"#)
        let notify = #"{"type":"agent-turn-complete","thread-id":"x2","turn-id":"1","cwd":"/w","input-messages":["go"],"last-assistant-message":"Shipped."}"#
        PulseHookReceiver.run(arguments: ["pulse-hook", "--hook", "codex", notify], locate: located)
        // A bridge that says Codex is blocked is refused: Codex's own
        // PermissionRequest fires before its auto-review.
        deliver("codex", "permission", #"{"session_id":"x3","message":"Approve shell"}"#)
        deliver("codex", "PermissionRequest", #"{"session_id":"x4","tool_name":"Bash"}"#)
        XCTAssertEqual(kinds(), ["turn", "turn"])
        XCTAssertEqual(records().map(\.session), ["x1", "x2"])
        XCTAssertEqual(records().last?.message, "Shipped.")
    }

    // MARK: - Gemini CLI (docs/hooks/reference.md)

    func testGeminiToolPermissionNotificationIsABlock() throws {
        deliver("gemini", "BeforeAgent", #"{"session_id":"g1","transcript_path":"/Users/me/.gemini/tmp/h/chats/g1.json","cwd":"/w","hook_event_name":"BeforeAgent","timestamp":"2026-09-29T10:00:00Z","prompt":"Fix it"}"#)
        deliver("gemini", "Notification", #"{"session_id":"g1","transcript_path":"/Users/me/.gemini/tmp/h/chats/g1.json","cwd":"/w","hook_event_name":"Notification","timestamp":"2026-09-29T10:00:05Z","notification_type":"ToolPermission","message":"Allow run_shell_command: npm test?","details":{"tool_name":"run_shell_command"}}"#)
        deliver("gemini", "AfterAgent", #"{"session_id":"g1","cwd":"/w","hook_event_name":"AfterAgent","prompt":"Fix it","prompt_response":"Fixed.","stop_hook_active":false}"#)
        XCTAssertEqual(kinds(), ["working", "permission", "turn"])
        let block = try XCTUnwrap(records().first { $0.kind == "permission" })
        XCTAssertEqual(block.message, "Allow run_shell_command: npm test?")
        XCTAssertEqual(block.transcript, "/Users/me/.gemini/tmp/h/chats/g1.json")
    }

    // MARK: - Copilot CLI (github/docs hooks-reference.md)

    func testCopilotNotificationsAndStop() {
        deliver("copilot", "notification", #"{"sessionId":"cp1","timestamp":1790000000000,"cwd":"/w","hook_event_name":"Notification","message":"Copilot wants to run: npm test","title":"Permission needed","notification_type":"permission_prompt"}"#)
        deliver("copilot", "notification", #"{"sessionId":"cp1","timestamp":1790000000001,"cwd":"/w","hook_event_name":"Notification","message":"Which branch?","notification_type":"elicitation_dialog"}"#)
        deliver("copilot", "notification", #"{"sessionId":"cp1","timestamp":1790000000002,"cwd":"/w","hook_event_name":"Notification","message":"Background agent idle","notification_type":"agent_idle"}"#)
        deliver("copilot", "agentStop", #"{"sessionId":"cp1","timestamp":1790000000003,"cwd":"/w","transcriptPath":"/Users/me/.copilot/session-state/cp1/events.jsonl","stopReason":"end_turn","stop_hook_active":false}"#)
        XCTAssertEqual(kinds(), ["permission", "question", "turn"], "a background agent's idle is not this session's turn")
        XCTAssertEqual(records().first?.message, "Copilot wants to run: npm test")
        XCTAssertEqual(records().last?.transcript, "/Users/me/.copilot/session-state/cp1/events.jsonl")
    }

    // MARK: - OpenCode (plugin events, SDK v2)

    func testOpenCodePermissionAskedThenReplied() throws {
        deliver("opencode", "permission.asked", #"{"sessionID":"ses_1","directory":"/w","permission":"bash","patterns":["npm test"]}"#)
        let block = try XCTUnwrap(records().first)
        XCTAssertEqual(block.kind, "permission")
        XCTAssertEqual(block.message, "bash: npm test")
        XCTAssertEqual(block.session, "ses_1")
        XCTAssertEqual(block.cwd, "/w")
        deliver("opencode", "permission.replied", #"{"sessionID":"ses_1","directory":"/w"}"#)
        deliver("opencode", "question.asked", #"{"sessionID":"ses_1","directory":"/w","questions":[{"question":"Which database?","header":"DB"}]}"#)
        deliver("opencode", "session.status", #"{"sessionID":"ses_1","directory":"/w","status":"busy"}"#)
        deliver("opencode", "session.idle", #"{"sessionID":"ses_1","directory":"/w"}"#)
        XCTAssertEqual(kinds(), ["permission", "done", "question", "turn"])
        XCTAssertEqual(records()[2].message, "Which database?")
        var book = SessionBook()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        for record in records() { book.apply(record, nowMs: nowMs) }
        XCTAssertEqual(HookFeed.word(book.sessions["opencode|ses_1"]?.state), "blocked:question", "an idle moments after a question does not wipe it (stop grace)")
    }

    // MARK: - Cursor (hooks.json, observe-only events)

    func testCursorStopIsYourTurnAndItNeverBlocks() throws {
        deliver("cursor", "stop", #"{"conversation_id":"cu1","generation_id":"g1","model":"gpt-5","hook_event_name":"stop","cursor_version":"1.7","workspace_roots":["/Users/me/app"],"transcript_path":"/Users/me/.cursor/projects/app/cu1.jsonl","status":"completed","loop_count":0}"#)
        deliver("cursor", "permission", #"{"conversation_id":"cu1","message":"approve"}"#)
        let record = try XCTUnwrap(records().first)
        XCTAssertEqual(kinds(), ["turn"])
        XCTAssertEqual(record.session, "cu1")
        XCTAssertEqual(record.cwd, "/Users/me/app")
        XCTAssertEqual(record.transcript, "/Users/me/.cursor/projects/app/cu1.jsonl")
    }

    // MARK: - Pi (extension events)

    func testPiUIPromptsAreBlocksUntilTheyEnd() {
        deliver("pi", "agent_start", #"{"session_id":"p1","transcript_path":"/Users/me/.pi/agent/sessions/w/p1.jsonl","cwd":"/w"}"#)
        deliver("pi", "ui_prompt_start", #"{"session_id":"p1","cwd":"/w","kind":"confirm","title":"Allow rm -rf build?"}"#)
        deliver("pi", "ui_prompt_end", #"{"session_id":"p1","cwd":"/w","kind":"confirm","title":"Allow rm -rf build?"}"#)
        deliver("pi", "ui_prompt_start", #"{"session_id":"p1","cwd":"/w","kind":"select","title":"Pick a model"}"#)
        deliver("pi", "agent_settled", #"{"session_id":"p1","cwd":"/w"}"#)
        XCTAssertEqual(kinds(), ["working", "permission", "done", "question", "turn"])
        XCTAssertEqual(records()[1].message, "Allow rm -rf build?")
    }

    // MARK: - Rejections

    func testUnknownEventsAndAgentsWriteNothing() throws {
        XCTAssertEqual(deliver("claude", "made_up_vendor_event", #"{"message":"x","session_id":"x"}"#), 0)
        XCTAssertEqual(deliver("goose", "permission", #"{"message":"x","session_id":"x"}"#), 0, "not a supported agent")
        XCTAssertEqual(deliver("claude", "", #"{"message":"says nothing about what it is","session_id":"x"}"#), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AttentionIO.path.path))
        XCTAssertFalse(PulseHookReceiver.appendEvent(agent: "claude", kind: "", message: "nope"))
        XCTAssertEqual(AttentionProtocol.normalizeKind("   "), "")
    }

    func testGrokRunningClaudesHooksIsRefused() {
        let code = PulseHookReceiver.run(
            arguments: ["PulseBar", "--hook", "claude", "PermissionRequest"],
            stdin: #"{"session_id":"g","tool_name":"Bash"}"#,
            environment: ["GROK_HOOK_EVENT": "PermissionRequest"],
            locate: located
        )
        XCTAssertEqual(code, 0)
        XCTAssertTrue(records().isEmpty)
    }

    /// Codex `notify` hands its JSON as the last argument; stdin is then not
    /// read at all, so a pipe nobody closes cannot hold the hook.
    func testAPayloadInArgvSkipsStdin() {
        XCTAssertTrue(PulseHookReceiver.payloadInArguments(
            ["pulse-hook", "--hook", "codex", #"{"type":"agent-turn-complete"}"#]
        ))
        XCTAssertFalse(PulseHookReceiver.payloadInArguments(["pulse-hook", "--hook", "claude"]))
        XCTAssertFalse(PulseHookReceiver.payloadInArguments(["pulse-hook", "--hook", "gemini", "Notification"]))
    }

    func testSelfTestDoesNotNeedPython() {
        // Route seedAssets away from the real support dir: the self-test must
        // never rewrite the user's hook-runner.path to the xctest binary.
        HooksInstaller.homeOverride = tempHome
        defer { HooksInstaller.homeOverride = nil }
        let before = AttentionIO.pathOverride
        let result = HooksSupport.selfTest()
        guard case .passed = result else {
            XCTFail("native self-test must pass: \(result)")
            return
        }
        XCTAssertEqual(AttentionIO.pathOverride, before)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: AttentionIO.path.path),
            "the self-test's lines never reach the attention file a scan reads"
        )
    }

    /// One invalid byte (a hook cut off mid-character) must not read as an
    /// empty file — every wait would vanish.
    func testOneBadByteDoesNotHideEveryWait() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var bytes = Data(AttentionIO.header.utf8)
        bytes.append(Data("claude\tpermission\t\(now - 1_000)\tBash: make\ts1\t/p\t\t\t\t\n".utf8))
        bytes.append(contentsOf: [0x63, 0x6C, 0xE2, 0x82, 0x0A]) // "cl" + a truncated "€"
        try bytes.write(to: AttentionIO.path)
        let text = AttentionIO.readText()
        XCTAssertFalse(text.isEmpty)
        var book = SessionBook()
        for line in text.split(whereSeparator: \.isNewline) {
            if let record = AttentionRecord(line: line) { book.apply(record, nowMs: now) }
        }
        XCTAssertEqual(Array(book.sessions.keys), ["claude|s1"])
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
        let text = try String(contentsOf: AttentionIO.path, encoding: .utf8)
        XCTAssertTrue(text.contains("Bash: curl"), text)
        XCTAssertFalse(text.contains("abcdefgh12345678"), "naming the ask must not leak the secret in it")
    }

    func testAPermissionRequestIsWrittenAndNeverHeld() throws {
        let started = Date()
        let code = deliver("claude", "PermissionRequest", #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"s1","cwd":"/w"}"#)
        XCTAssertEqual(code, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the receiver exits at once")
        let text = try String(contentsOf: AttentionIO.path, encoding: .utf8)
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("claude\t") })
        XCTAssertEqual(line.split(separator: "\t", omittingEmptySubsequences: false).count, AttentionProtocol.columnCount)
    }
}

/// 24.0 · landing handles and the agent pid, read by the hook itself.
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
        let node: [Int32: String] = [300: "sh -c hook", 200: "node /opt/homebrew/bin/gemini", 100: "zsh"]
        XCTAssertEqual(
            HookLanding.agentPID(agent: .gemini, start: 300, parentOf: { parents[$0] }, argumentsOf: { node[$0] }),
            200
        )
        XCTAssertEqual(
            HookLanding.agentPID(agent: .codex, start: 300, parentOf: { parents[$0] }, argumentsOf: { argv[$0] }),
            300,
            "no ancestor is the agent: the direct parent"
        )
    }

    func testProcArgsParseArgvAndSkipTheExecPath() {
        var bytes: [UInt8] = [2, 0, 0, 0]
        bytes += Array("/usr/local/bin/node".utf8) + [0, 0, 0]
        bytes += Array("node".utf8) + [0]
        bytes += Array("/opt/homebrew/bin/gemini".utf8) + [0]
        bytes += Array("SECRET=env".utf8) + [0]
        XCTAssertEqual(AgentProcesses.parseProcArgs(bytes), "node /opt/homebrew/bin/gemini", "argc bounds the read: no environment")
        XCTAssertNil(AgentProcesses.parseProcArgs([0, 0]))
    }
}

/// 24.0 · every agent's documented, non-blocking hook, installed from the
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
        for spec in AgentCatalog.all {
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
        try write(".gemini/settings.json", "{\"theme\":\"Dracula\",\"hooks\":{\"AfterTool\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"lint.sh\"}]}]}}")
        try write(".cursor/hooks.json", "{\n  \"version\": 1,\n  \"hooks\": {\"afterFileEdit\": [{\"command\": \"./format.sh\"}]}\n}\n")
    }

    func testEveryAgentInstallsAndUninstallsByteForByte() throws {
        try seedVendors()
        let before = snapshot()
        let report = try HooksInstaller.install()
        XCTAssertEqual(report.count, AgentID.allCases.count)
        for agent in AgentID.allCases {
            let text = try XCTUnwrap(read(agent.spec.hooks.path), agent.rawValue)
            let events = try XCTUnwrap(HooksInstaller.installedEvents(agent, text: text), agent.rawValue)
            XCTAssertEqual(events, Set(agent.spec.hooks.events.map(\.name)), agent.rawValue)
            XCTAssertTrue(HooksSupport.isWired(agent), agent.rawValue)
        }
        XCTAssertEqual(HooksSupport.probeStatus(), .all)
        XCTAssertNotEqual(snapshot(), before)

        try HooksInstaller.uninstall()
        XCTAssertEqual(snapshot(), before, "every file and directory is back exactly as it was")
        XCTAssertEqual(HooksSupport.probeStatus(), .missing)
    }

    func testAReinstallIsStillReversibleByteForByte() throws {
        try seedVendors()
        let before = snapshot()
        try HooksInstaller.install()
        try HooksInstaller.install()
        try HooksInstaller.uninstall()
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
                    }
                }
            }
        }
    }

    func testAnAbsentVendorGetsNothing() throws {
        try FileManager.default.createDirectory(at: tempHome.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let report = try HooksInstaller.install()
        XCTAssertEqual(report.count, 1)
        XCTAssertNil(read(".gemini/settings.json"))
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
        try HooksInstaller.uninstall(agents: [.claude])
        let after = try XCTUnwrap(read(".claude/settings.json"))
        XCTAssertFalse(HooksInstaller.containsPulseMarker(after))
        XCTAssertTrue(after.contains("\"theme\""))
        XCTAssertTrue(after.contains("guard.sh"), "the user's own hook stays")
    }

    func testAModuleFilePulseDidNotWriteIsNeverReplaced() throws {
        try write(".config/opencode/plugins/pulse.js", "export const Mine = async () => ({})\n")
        XCTAssertThrowsError(try HooksInstaller.install(agents: [.opencode]))
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

    func testInstallNeverOverwritesTheUsersOwnCodexNotify() throws {
        try write(".codex/config.toml", "notify = [\"/usr/local/bin/my-notifier\"]\n")
        let report = try HooksInstaller.install(agents: [.codex])
        XCTAssertTrue(report.joined().contains("kept your own notify"))
        let text = try XCTUnwrap(read(".codex/config.toml"))
        XCTAssertTrue(text.contains("my-notifier"))
        XCTAssertFalse(text.contains("pulse-hook"))
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
        try HooksInstaller.uninstall(agents: [.claude])
        XCTAssertEqual(read("dotfiles/claude-settings.json"), "{\"model\": \"opus\"}\n")
    }

    func testInstallRefusesInvalidJSON() throws {
        try write(".claude/settings.json", "{ not json")
        XCTAssertThrowsError(try HooksInstaller.install(agents: [.claude]))
        XCTAssertEqual(read(".claude/settings.json"), "{ not json", "the user's file is left alone")
    }

    func testRootTableEndFindsFirstSection() {
        let text = "model = \"o3\"\n\n[profiles.x]\nmodel = \"y\"\n"
        let end = HooksInstaller.rootTableEnd(text)
        XCTAssertEqual(String(text.prefix(end)), "model = \"o3\"\n\n")
    }

    func testMarkersNeverClaimAUsersOwnHook() {
        XCTAssertTrue(HooksInstaller.containsPulseMarker("/x/pulse-hook claude Stop"))
        XCTAssertTrue(HooksInstaller.containsPulseMarker("/Applications/Pulse.app/Contents/MacOS/PulseBar --hook claude"))
        XCTAssertFalse(HooksInstaller.containsPulseMarker("mytool --hook-dir /tmp"))
    }

    /// The Settings lines say what is installed, what is not there, when a
    /// hook last spoke, and which agents never report a wait.
    func testSettingsSaysEachAgentsHook() {
        let now: Int64 = 1_800_000_000_000
        let lines = SettingsModel.hookAgents(
            installed: [.claude, .codex], present: [.claude, .codex, .gemini],
            lastEventMs: [.claude: now - 12_000], nowMs: now, lang: .en
        )
        XCTAssertEqual(lines.map(\.agent), AgentID.priority)
        let claude = lines[0]
        XCTAssertTrue(claude.installed)
        XCTAssertEqual(claude.lastEvent, String(format: L10n.t(.settingsHookLastEvent, .en), DurationFormat.label(seconds: 12, lang: .en)))
        XCTAssertNil(claude.note)
        let codex = lines.first { $0.agent == .codex }
        XCTAssertEqual(codex?.lastEvent, L10n.t(.settingsHookNoEvent, .en))
        XCTAssertEqual(codex?.note, L10n.t(.settingsHookNoWait, .en))
        XCTAssertEqual(lines.first { $0.agent == .cursor }?.note, L10n.t(.settingsHookNoWait, .en))
        XCTAssertEqual(lines.first { $0.agent == .gemini }?.state, L10n.t(.hooksMissing, .en))
        XCTAssertEqual(lines.first { $0.agent == .pi }?.state, L10n.t(.settingsHookNotFound, .en))
        XCTAssertEqual(lines.first { $0.agent == .pi }?.lastEvent, "")
    }
}

final class AttentionWatcherReArmTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        AttentionIO.pathOverride = home.appendingPathComponent("attention.tsv")
    }

    override func tearDownWithError() throws {
        AttentionIO.pathOverride = nil
        try? FileManager.default.removeItem(at: home)
    }

    func testReArmingTheFileWatchLeavesTheActivityWatchAlone() {
        let watcher = AttentionWatcher()
        defer { watcher.stop() }
        watcher.start(onChange: {}, onActivity: {})
        XCTAssertTrue(watcher.isWatchingFile)
        XCTAssertTrue(watcher.isWatchingActivity)

        // What the delete/rename handler does after an atomic replace — which
        // is what every hook write looks like from the outside.
        watcher.arm()
        XCTAssertTrue(watcher.isWatchingFile)
        XCTAssertTrue(
            watcher.isWatchingActivity,
            "activity.d/ must keep waking Pulse after attention.tsv is replaced"
        )
    }

    func testReArmingTheActivityWatchLeavesTheFileWatchAlone() {
        let watcher = AttentionWatcher()
        defer { watcher.stop() }
        watcher.start(onChange: {}, onActivity: {})
        watcher.armActivity()
        XCTAssertTrue(watcher.isWatchingFile)
        XCTAssertTrue(watcher.isWatchingActivity)
    }

    /// A deleted file cannot be reopened, so the watch would have stayed dead
    /// for the life of the process.
    func testAFileThatWasDeletedIsRecreatedAndWatchedAgain() throws {
        let watcher = AttentionWatcher()
        defer { watcher.stop() }
        watcher.start {}
        let file = try XCTUnwrap(AttentionIO.pathOverride)
        try FileManager.default.removeItem(at: file)

        watcher.arm()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(watcher.isWatchingFile)
    }

    func testStopTearsDownEveryWatch() {
        let watcher = AttentionWatcher()
        watcher.start(onChange: {}, onActivity: {})
        watcher.stop()
        XCTAssertFalse(watcher.isWatchingFile)
        XCTAssertFalse(watcher.isWatchingActivity)
    }
}

/// 16.0 · Turn — vendor event sequences, from the attention file to the lamp.
///
/// 18.0: Swift Testing. Every sequence is one row of `TurnTruthTests.cases`
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
        session: String = "s1", cwd: String = "/p", front: String? = nil
    ) -> String {
        // v4: all ten columns; front as given (empty = unknown), pid,
        // transcript and landing empty.
        let cols = [agent, kind, "\(now - ago)", message, session, cwd, front ?? "", "", "", ""]
        return cols.joined(separator: "\t")
    }

    static func world(
        _ lines: [String],
        activity: [ActivitySpool.Event] = []
    ) -> SnapshotBuilder.Result {
        let text = AttentionProtocol.header + lines.joined(separator: "\n") + "\n"
        var book = SessionBook()
        for line in text.split(whereSeparator: \.isNewline) {
            if let record = AttentionRecord(line: line) { book.apply(record, nowMs: now) }
        }
        for event in activity { book.apply(activity: event, nowMs: now) }
        let rows = SessionProjection.rows(
            book: book, processes: [], transcripts: [:],
            context: SessionProjection.Context(
                nowMs: now
            )
        ).rows
        return SnapshotBuilder.build(rows: rows, previous: .init(), context: SnapshotBuilder.Context(nowMs: now, lang: .en))
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
            name: "codex · an approval word is not a protocol kind → not red",
            lines: [line("codex", "exec_approval_request", ago: 3 * second, message: "git push")],
            agent: .codex,
            expect: quiet
        ),
        Case(
            name: "gemini · ToolPermission → red",
            lines: [line("gemini", "permission", ago: 3 * second, message: "Allow run_shell_command?")],
            agent: .gemini,
            expect: Expect(waiting: true, yourTurn: false, red: true, banner: true, waitKind: "Permission")
        ),
        Case(
            name: "pi · a select prompt → red, says Input",
            lines: [line("pi", "question", ago: 3 * second, message: "Pick a model")],
            agent: .pi,
            expect: Expect(waiting: true, yourTurn: false, red: true, banner: true, waitKind: "Input")
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
            name: "legacy · an older hook's idle_prompt line reads as your turn",
            lines: [line("claude", "idle_prompt", ago: 2 * second)],
            expect: turn
        ),
    ]

    /// 23.0: a finished turn is grey even while its CLI stays open — the
    /// green ring is for a session that is working, and "your turn" is not.
    @Test func aFinishedTurnWithALiveProcessIsAGreyLamp() throws {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: "claude", kind: "turn", ms: Self.now - 2 * Self.second, session: "s1", cwd: "/p", pid: 42), nowMs: Self.now)
        let rows = SessionProjection.rows(
            book: book, processes: [], transcripts: [:],
            context: SessionProjection.Context(nowMs: Self.now)
        ).rows
        let r = SnapshotBuilder.build(rows: rows, previous: .init(), context: SnapshotBuilder.Context(nowMs: Self.now, lang: .en))
        let row = try #require(r.rows.first)
        #expect(row.isYourTurn)
        #expect(row.liveProcess)
        #expect(r.snapshot.glance == .idle)
        #expect(r.snapshot.lamp == LampFace(shape: .hollow, tone: .idle))
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
        #expect((r.snapshot.glance == .waiting) == c.expect.red)
        let turns = r.rows.filter { $0.isYourTurn }.count
        #expect(turns == (c.expect.yourTurn ? 1 : 0))
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
        let r = Self.world([Self.line("claude", "stop", ago: 30 * Self.second)], activity: [tool])
        let row = try #require(r.rows.first)
        #expect(!row.isYourTurn)
    }

    @Test func aTurnThatNamesNoSessionMakesNoRow() {
        let r = Self.world([Self.line("claude", "stop", ago: 5 * Self.second, session: "")])
        #expect(r.rows.isEmpty, "with no session there is no row it could belong to")
    }

    @Test func theReceiverWritesTheV4Kinds() throws {
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
        let stop = PulseHookReceiver.interpret(agent: .claude, event: "Stop", payload: [:])
        let failure = PulseHookReceiver.interpret(agent: .claude, event: "StopFailure", payload: [:])
        let subagent = PulseHookReceiver.interpret(agent: .claude, event: "SubagentStop", payload: [:])
        #expect(stop?.action == .turn)
        #expect(failure?.action == .turn)
        #expect(subagent?.action == .ignore)

        // The installed Claude hooks pass the vendor's event name.
        let here: (AgentID, [String: String]) -> (pid: Int32, landing: String) = { _, _ in (0, "") }
        PulseHookReceiver.run(arguments: ["PulseBar", "--hook", "claude", "Stop"],
                              stdin: #"{"session_id":"s1","cwd":"/p","last_assistant_message":"All tests pass."}"#,
                              locate: here)
        PulseHookReceiver.run(arguments: ["PulseBar", "--hook", "claude", "UserPromptSubmit"],
                              stdin: #"{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/p","prompt":"next"}"#,
                              locate: here)
        let lines = try String(contentsOf: AttentionIO.path, encoding: .utf8)
            .split(separator: "\n").filter { !$0.hasPrefix("#") }
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
        #expect(lines.map { String($0[1]) } == ["turn", "working"])
        #expect(lines.allSatisfy { $0.count == AttentionProtocol.columnCount })
        #expect(String(lines[0][3]) == "All tests pass.")
    }

    @Test func everyKindHasOneMeaning() {
        for kind in AttentionKind.allCases {
            #expect(AttentionProtocol.kind(kind.rawValue) == kind)
        }
        let blocking = AttentionKind.allCases.filter { $0.isBlocking }
        #expect(blocking == [.permission, .question, .waiting])
        #expect(!AttentionKind.turn.isBlocking)
        #expect(AttentionKind.turn.isOpen)
    }
}

final class ActivitySpoolTests: XCTestCase {
    private var wallNow: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ActivitySpool.directoryOverride = directory
        // A prompt also writes a `working` line: never into the real file.
        AttentionIO.pathOverride = directory.appendingPathComponent("attention.tsv")
    }

    override func tearDownWithError() throws {
        ActivitySpool.directoryOverride = nil
        AttentionIO.pathOverride = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - The receiver's side: what an event becomes on disk

    func testAPreToolUseEventBecomesAStateFileAndNeverAttention() throws {
        let stdin = #"""
        {"hook_event_name":"PreToolUse","session_id":"sess-a","tool_name":"Edit",
         "tool_input":{"file_path":"/repo/src/Main.swift"},"cwd":"/repo"}
        """#
        _ = PulseHookReceiver.run(arguments: ["--hook", "claude", "activity"], stdin: stdin)
        let events = ActivitySpool.readEvents(nowMs: wallNow)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(event.agent, "claude")
        XCTAssertEqual(event.session, "sess-a")
        XCTAssertEqual(event.event, "tool")
        XCTAssertEqual(event.tool, "Edit")
        XCTAssertEqual(event.target, "/repo/src/Main.swift")
        let url = directory.appendingPathComponent("claude-sess-a.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testTheEventNameAloneDispatchesWithoutAKindArgument() throws {
        let stdin = #"{"hook_event_name":"UserPromptSubmit","session_id":"sess-b","prompt":"Fix the login bug\nsecond line"}"#
        _ = PulseHookReceiver.run(arguments: ["--hook", "claude"], stdin: stdin)
        let event = try XCTUnwrap(ActivitySpool.readEvents(nowMs: wallNow).first)
        XCTAssertEqual(event.event, "prompt")
        XCTAssertEqual(event.prompt, "Fix the login bug second line")
        XCTAssertEqual(event.tool, "")
    }

    func testLatestEventWinsBecauseActivityIsAStateNotALedger() throws {
        for (kind, body) in [
            ("activity", #"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Edit","tool_input":{"file_path":"/a"}}"#),
            ("activity", #"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Bash","tool_input":{"command":"swift test"}}"#),
        ] {
            _ = PulseHookReceiver.run(arguments: ["--hook", "claude", kind], stdin: body)
        }
        let events = ActivitySpool.readEvents(nowMs: wallNow)
        XCTAssertEqual(events.count, 1, "one session, one state file")
        XCTAssertEqual(events.first?.tool, "Bash")
    }

    func testASessionlessEventWritesNothing() {
        _ = PulseHookReceiver.run(
            arguments: ["--hook", "claude", "activity"],
            stdin: #"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#
        )
        XCTAssertTrue(ActivitySpool.readEvents(nowMs: wallNow).isEmpty)
    }

    func testSecretsNeverReachTheSpool() throws {
        let stdin = #"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Bash","tool_input":{"command":"deploy with Bearer abc123secretvalue"}}"#
        _ = PulseHookReceiver.run(arguments: ["--hook", "claude", "activity"], stdin: stdin)
        let event = try XCTUnwrap(ActivitySpool.readEvents(nowMs: wallNow).first)
        XCTAssertFalse(event.target.contains("abc123secretvalue"), event.target)
    }

    // MARK: - The reader's side: identity and age

    func testABodyThatDisagreesWithItsFilenameIsRefused() throws {
        let body: [String: Any] = [
            "v": 1, "agent": "claude", "session": "other",
            "event": "tool", "tool": "Edit", "target": "", "prompt": "",
            "cwd": "", "ts_ms": wallNow,
        ]
        try JSONSerialization.data(withJSONObject: body)
            .write(to: directory.appendingPathComponent("claude-sess-x.json"))
        XCTAssertTrue(ActivitySpool.readEvents(nowMs: wallNow).isEmpty,
                      "the filename decides who this is; a disagreeing body is somebody being clever")
    }

    func testAnAncientEventIsNotServedAndAFutureStampIsClamped() throws {
        _ = ActivitySpool.write(ActivitySpool.Event(
            agent: "claude", session: "old", event: "tool",
            tool: "Edit", target: "", prompt: "", cwd: "",
            tsMs: wallNow - ActivitySpool.maxAgeMs - 60_000
        ))
        XCTAssertTrue(ActivitySpool.readEvents(nowMs: wallNow).isEmpty)

        _ = ActivitySpool.write(ActivitySpool.Event(
            agent: "claude", session: "future", event: "tool",
            tool: "Edit", target: "", prompt: "", cwd: "",
            tsMs: wallNow + 10 * 60 * 1000
        ))
        let event = try XCTUnwrap(ActivitySpool.readEvents(nowMs: wallNow).first)
        XCTAssertLessThanOrEqual(event.tsMs, wallNow,
                                 "the writer is this machine — a future stamp is a broken clock")
    }
}

/// 0.96 Return Truth — Glance width and Attention compact. (23.0: the rekey
/// and story-honesty tests went with the remap and `RowNarrator`.)
final class AttentionCompactTests: XCTestCase {
    // MARK: P1 identity / compact

    @MainActor
    func testAttentionCompactKeepsUnresolvedRaise() {
        var lines: [String] = []
        for index in 0..<90 {
            lines.append("copilot\tdone\t\(1_700_000_000_000 + index)\tok\tsess-\(index)\t/tmp\t\t\t\t")
        }
        lines.insert("copilot\tpermission\t1\tapprove\tkeep-me\t/tmp\t\t\t\t", at: 0)
        let compacted = AttentionIO.compactLines(lines, cap: 80)
        XCTAssertEqual(compacted.count, 80)
        XCTAssertTrue(
            compacted.contains(where: { $0.contains("keep-me") }),
            "unresolved permission must survive the 80-line cap"
        )
    }
}

/// Clarity fixes — each test pins one defect found by reading the code: the
/// value the user would have seen, before and after.
@MainActor
@Suite("Attention fixes", .serialized)
struct AttentionFixTests {
    let now: Int64 = 1_800_000_000_000
    static let minute: Int64 = 60_000

    // MARK: - Harness

    final class Home {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("pulse-clarity-\(UUID().uuidString)", isDirectory: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        @discardableResult
        func write(_ relative: String, _ text: String, modified: Date? = nil) throws -> URL {
            let file = url.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
            if let modified {
                try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
            }
            return file
        }
    }

    // MARK: - 2 · the stop grace is a function of the two lines

    @Test func theStopGraceDoesNotDependOnWhenTheFileIsRead() {
        let raise = now - 10 * Self.minute
        let text = [
            ["claude", "permission", "\(raise)", "Bash: npm test", "s1", "/p", "", "", "", ""],
            ["claude", "stop", "\(raise + 1_000)", "", "s1", "", "", "", "", ""],
        ].map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n"
        func read(at nowMs: Int64) -> String {
            var book = SessionBook()
            for line in text.split(whereSeparator: \.isNewline) {
                if let record = AttentionRecord(line: line) { book.apply(record, nowMs: nowMs) }
            }
            return HookFeed.word(book.sessions["claude|s1"]?.state)
        }
        #expect(read(at: raise + 2_000) == "blocked:permission")
        #expect(read(at: now) == read(at: raise + 2_000), "re-reading ten minutes later flipped the verdict")
    }

    // MARK: - 17 · one bad byte never erases the attention file

    @Test func anInvalidByteDoesNotEraseOpenWaits() throws {
        let home = Home()
        let file = home.url.appendingPathComponent("attention.tsv")
        try FileManager.default.createDirectory(at: home.url, withIntermediateDirectories: true)
        var bytes = Data(AttentionIO.header.utf8)
        bytes.append(Data("claude\tpermission\t\(now)\tBash: npm test\ts1\t/p\t\t\t\t\n".utf8))
        bytes.append(Data([0x63, 0x6f, 0xff, 0x0a]))
        try bytes.write(to: file)
        AttentionIO.pathOverride = file
        defer { AttentionIO.pathOverride = nil }

        AttentionIO.appendRawLine("codex\tdone\t\(now)\t\ts2\t\t\t\t\t")
        let written = try Data(contentsOf: file)
        let text = String(decoding: written, as: UTF8.self)
        #expect(text.contains("claude\tpermission"), "the rewrite used to start from an empty decode")
        #expect(text.contains("codex\tdone"))
    }
}

/// 22.x · Lamp fixes — each pins one defect with the pure function that
/// decides it.
@Suite("Codex hooks detection")
struct CodexHooksDetectionTests {
    // MARK: - Codex hooks.json counts as installed

    @Test func codexHooksJSONAloneCountsAsInstalled() {
        let hooks = #"{"hooks":{"Stop":[{"hooks":[{"command":"/x/pulse-hook --agent codex"}]}]}}"#
        #expect(HooksSupport.codexHooked(configTOML: nil, hooksJSON: hooks))
        #expect(HooksSupport.codexHooked(configTOML: "notify = [\"/x/pulse-hook\"]", hooksJSON: nil))
        #expect(!HooksSupport.codexHooked(configTOML: "model = \"o3\"", hooksJSON: "{}"))
    }
}
