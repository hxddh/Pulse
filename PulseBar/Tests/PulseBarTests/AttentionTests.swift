import Foundation
import Testing
import XCTest
@testable import PulseApp
@testable import PulseCore
@testable import PulseHarvest

// Attention: the protocol read into the session book, the hook receiver,
// the event log, the hooks installer.

/// The event log as the book reads it: every complete v6 line, in file
/// order.
final class AttentionBookTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000

    /// Rows are padded to the ten v6 columns (front, pid, landing and tool
    /// empty).
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

    /// A `done` clears exactly what it names: an empty session, only the
    /// session-less entries — never every session of that agent.
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

    /// A dismissal's `done` names the row's folder: it clears the
    /// session-less wait in that folder and leaves the agent's session-less
    /// wait in another folder red.
    func testASessionlessDoneWithAFolderClearsOnlyThatFolder() {
        let b = book(tsv([
            ["gemini", "permission", "\(now - 5000)", "a", "", "/r"],
            ["gemini", "permission", "\(now - 4000)", "b", "", "/q"],
            ["gemini", "done", "\(now - 1000)", "", "", "/r"],
        ]))
        XCTAssertEqual(state(b, RowIdentity.session(agent: .gemini, session: "", cwd: "/r")), "working")
        XCTAssertEqual(state(b, RowIdentity.session(agent: .gemini, session: "", cwd: "/q")), "blocked:permission")
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
        let session = try XCTUnwrap(book(tsv(rows)).sessions["claude|s1"])
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
        let session = try XCTUnwrap(b.sessions["codex|x1"])
        XCTAssertEqual(session.title, "Port the parser to Swift")
        XCTAssertEqual(session.lastPrompt, "continue")
        XCTAssertEqual(session.turnStartMs, now - 2000)
        XCTAssertEqual(session.message, "Ported.", "the last words stay until the next turn says something")
    }

    /// A turn that ended on an error (`tool` = `error`) is the session's
    /// last error — its last words are left alone — until the next prompt.
    func testAFailedTurnIsTheLastErrorUntilTheNextPrompt() throws {
        let failed = tsv([
            ["claude", "turn", "\(now - 9000)", "All green.", "s1", "/p"],
            ["claude", "working", "\(now - 8000)", "Ship it", "s1", "/p"],
            ["claude", "turn", "\(now - 5000)", "API Error: Rate limit reached", "s1", "/p", "", "", "", AttentionRecord.errorTool],
        ])
        let session = try XCTUnwrap(book(failed).sessions["claude|s1"])
        XCTAssertEqual(session.lastError, "API Error: Rate limit reached")
        XCTAssertEqual(session.message, "All green.")
        XCTAssertEqual(HookFeed.word(session.state), "turn", "a failed turn is your turn, never red")
        let next = failed + tsv([["claude", "working", "\(now - 1000)", "Try again", "s1", "/p"]])
        XCTAssertEqual(book(next).sessions["claude|s1"]?.lastError, "")
    }

    func testStopKeepsAFreshPermissionWithinGrace() {
        // The order of Claude's events is not ours; a turn ending moments
        // after a permission was raised must not wipe it.
        let b = book(tsv([
            ["claude", "permission", "\(now - 1000)", "approve", "s1", "/p"],
            ["claude", "turn", "\(now)", "", "s1", ""],
        ]))
        XCTAssertEqual(state(b, "claude|s1"), "blocked:permission", "recent permission survives a Stop")
    }

    func testStopClearsAnAgedPermissionAndLeavesYourTurn() {
        let old = now - SessionBook.stopGraceMs - 5000
        let b = book(tsv([
            ["claude", "permission", "\(old)", "approve", "s1", "/p"],
            ["claude", "turn", "\(now)", "", "s1", ""],
        ]))
        XCTAssertEqual(state(b, "claude|s1"), "turn", "the permission is gone; what is left is not red")
    }

    /// A wait whose process Pulse cannot see is not red forever: past the
    /// idle bound it is shown as recent (the projection's rule).
    func testAnUnprovableWaitGoesQuietAfterTheIdleBound() throws {
        let b = book(tsv([["claude", "permission", "\(now - 1000)", "old", "s1", "/p"]]))
        let session = try XCTUnwrap(b.sessions["claude|s1"])
        XCTAssertEqual(
            TrayState.state(of: session, nowMs: now),
            .blocked(RowWait(kind: "Permission", ask: "old", sinceMs: now - 1000))
        )
        XCTAssertEqual(TrayState.state(of: session, nowMs: now + TrayState.idleBoundMs + 1), .recent)
    }

    func testUnknownKindNeverRaisesWaiting() {
        XCTAssertTrue(book(tsv([["claude", "subagent_start", "\(now)", "", "s1", "/p"]])).sessions.isEmpty)
        let b = book(tsv([["gemini", "totally_fake_kind", "\(now)", "nope", "s1", "/p"]]))
        XCTAssertTrue(b.sessions.isEmpty, "free-text kinds must never light Waiting")
    }

    func testProtocolHeaderIsIgnoredAsComment() {
        let b = book(AttentionProtocol.header(generation: "g1") + tsv([
            ["gemini", "waiting", "\(now - 1000)", "Need choice", "j1", "/w"],
        ]))
        XCTAssertEqual(Array(b.sessions.keys), ["gemini|j1"])
        XCTAssertEqual(state(b, "gemini|j1"), "blocked:waiting")
    }

    func testCommentsAndShortRowsAreSkipped() {
        XCTAssertTrue(book("# header\nclaude\tpermission\n\n").sessions.isEmpty)
    }

    /// v6 is exactly ten columns. A shorter line, or an eleven-column one,
    /// is not read.
    func testALineWithAnotherColumnCountIsNotRead() throws {
        let short = "claude\tpermission\t\(now - 1000)\tapprove\ts1\t/p\t\t\n"
        let eleven = "claude\tpermission\t\(now - 1000)\tBash: ls\ts1\t/p\t\t4242\t/t.jsonl\ttmux:%3\tBash\n"
        XCTAssertTrue(book(short).sessions.isEmpty)
        XCTAssertTrue(book(eleven).sessions.isEmpty)
        let v6 = "claude\tpermission\t\(now - 1000)\tBash: ls\ts1\t/p\t\t4242\ttmux:%3\tBash\n"
        let session = try XCTUnwrap(book(v6).sessions["claude|s1"])
        XCTAssertEqual(session.pid, 4242)
        XCTAssertEqual(session.landing, "tmux:%3")
        XCTAssertEqual(block(book(v6), "claude|s1")?.tool, "Bash")
    }

    /// A hand-written blocked line for an agent whose hooks cannot
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

    /// The lifecycle kinds each say what the session does next.
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
    @discardableResult
    private func deliver(
        _ agent: String, _ event: String, _ payload: String,
        locate: ((AgentID, [String: String]) -> (pid: Int32, landing: String))? = nil
    ) -> Int32 {
        var arguments = ["PulseBar", "--hook", agent]
        if !event.isEmpty { arguments.append(event) }
        return PulseHookReceiver.run(arguments: arguments, stdin: payload, logURL: log, locate: locate ?? located)
    }

    private func records() -> [AttentionRecord] {
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { AttentionRecord(line: $0) }
    }

    /// Everything but the `tool` lines.
    private func blocksAndTurns() -> [AttentionRecord] {
        records().filter { $0.kind != "tool" }
    }

    private func kinds() -> [String] {
        blocksAndTurns().map { $0.kind }
    }

    // MARK: - The protocol's own words

    /// A line's kind is one of the v6 kinds, spelled as written — no alias,
    /// no vendor word, no guess.
    func testTheLogReadsOnlyTheV6Kinds() {
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

    /// v6: ten columns, and a record survives its own line.
    func testAV6RecordRoundTrips() throws {
        let record = AttentionRecord(
            agent: "claude", kind: "permission", ms: 1_800_000_000_000,
            message: "Bash: npm test", session: "s1", cwd: "/w", front: false,
            pid: 4242, landing: "tmux:%3;tty:/dev/ttys004", tool: "Bash"
        )
        let columns = record.line.split(separator: "\t", omittingEmptySubsequences: false)
        XCTAssertEqual(columns.count, 10)
        XCTAssertEqual(columns[8], "tmux:%3;tty:/dev/ttys004", "landing, then tool")
        XCTAssertEqual(columns[9], "Bash")
        XCTAssertEqual(AttentionRecord(line: record.line), record)
        let unknown = AttentionRecord(agent: "codex", kind: "turn", ms: 1)
        XCTAssertEqual(AttentionRecord(line: unknown.line), unknown, "empty columns stay empty")
        XCTAssertNil(AttentionRecord(line: "claude\tpermission\t1\tx\ts\t/p\t\t"), "a short line is not read")
        XCTAssertNil(AttentionRecord(line: "claude\tpermission\t1\tx\ts\t/p\t\t\t\t\t"), "an eleven-column line is not read")
        let header = AttentionProtocol.header(generation: "g42")
        XCTAssertTrue(header.hasPrefix("# pulse-events v6 g42 "))
        XCTAssertTrue(AttentionProtocol.isHeader(header))
        XCTAssertFalse(AttentionProtocol.isHeader("# pulse-events v5 g42 (agent)"))
        XCTAssertNotEqual(header, AttentionProtocol.header(generation: "g43"), "each generation has its own header")
        XCTAssertEqual(AttentionProtocol.kind("tool"), .tool)
        XCTAssertFalse(AttentionKind.tool.isOpen)
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
        XCTAssertEqual(question.kind, "question")
        XCTAssertEqual(question.message, "Which database should the cache use?")
        XCTAssertEqual(question.tool, "AskUserQuestion")
        let plan = try XCTUnwrap(records().first { $0.session == "c3" })
        XCTAssertEqual(plan.kind, "permission")
        XCTAssertEqual(plan.message, "Move the cache to Redis")
        XCTAssertEqual(PulseHookReceiver.planSummary("\n## Move the cache\n- step"), "Move the cache")
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
        XCTAssertEqual(kinds(), ["permission", "question", "question", "idle"], "auth_success says nothing Pulse shows")
    }

    func testClaudeLifecycleAndTurn() {
        deliver("claude", "SessionStart", #"{"session_id":"s1","cwd":"/w","hook_event_name":"SessionStart","source":"startup"}"#)
        deliver("claude", "UserPromptSubmit", #"{"session_id":"s1","cwd":"/w","hook_event_name":"UserPromptSubmit","prompt":"Fix the login"}"#)
        deliver("claude", "PostToolUse", #"{"session_id":"s1","cwd":"/w","hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"/w/a.swift"}}"#)
        deliver("claude", "Stop", #"{"session_id":"s1","cwd":"/w","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"All tests pass."}"#)
        deliver("claude", "SessionEnd", #"{"session_id":"s1","cwd":"/w","hook_event_name":"SessionEnd","reason":"exit"}"#)
        XCTAssertEqual(records().map(\.kind), ["start", "working", "tool", "turn", "end"], "one log, every event in order")
        XCTAssertEqual(records().first { $0.kind == "turn" }?.message, "All tests pass.")
        XCTAssertEqual(records().first { $0.kind == "working" }?.message, "Fix the login", "the prompt is the title's source")
        let tool = try? XCTUnwrap(records().first { $0.kind == "tool" })
        XCTAssertEqual(tool?.tool, "Edit")
        XCTAssertEqual(tool?.message, "/w/a.swift")
        XCTAssertEqual(tool?.pid, 4242, "a tool line names its process too")
        XCTAssertNil(tool?.front, "front is only asked for what is owed")
    }

    /// A failed tool is activity for that tool.
    func testClaudePostToolUseFailureIsAToolLine() throws {
        deliver("claude", "PostToolUseFailure", #"{"session_id":"s1","cwd":"/w","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"npm test"},"error":"exit 1"}"#)
        let line = try XCTUnwrap(records().first)
        XCTAssertEqual(line.kind, "tool")
        XCTAssertEqual(line.tool, "Bash")
        XCTAssertEqual(line.message, "npm test")
    }

    /// A hook whose parent had exited is re-parented to
    /// launchd; pid 1 is never written.
    func testPidOneIsNeverWritten() throws {
        deliver("claude", "Stop", #"{"session_id":"s1","cwd":"/w"}"#, locate: { _, _ in (1, "") })
        let raw = try String(contentsOf: log, encoding: .utf8)
        let line = try XCTUnwrap(raw.split(separator: "\n").first { !$0.hasPrefix("#") })
        XCTAssertEqual(line.split(separator: "\t", omittingEmptySubsequences: false)[7], "")
        XCTAssertEqual(records().first?.pid, 0)
        let parents: [Int32: Int32] = [300: 1]
        XCTAssertEqual(
            HookLanding.agentPID(agent: .claude, start: 1, parentOf: { parents[$0] }, argumentsOf: { _ in nil }),
            0,
            "the chain starts at launchd: unknown"
        )
    }

    /// Claude's StopFailure: your turn, with the error in its own words and
    /// the `error` marker in the tool column.
    func testClaudeStopFailureCarriesItsError() throws {
        deliver("claude", "StopFailure", #"{"session_id":"s1","cwd":"/w","hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":"API Error: Rate limit reached"}"#)
        let line = try XCTUnwrap(records().first)
        XCTAssertEqual(line.kind, "turn")
        XCTAssertEqual(line.tool, AttentionRecord.errorTool)
        XCTAssertEqual(line.message, "API Error: Rate limit reached")
        XCTAssertEqual(PulseHookReceiver.errorMessage(from: ["error": "rate_limit"]), "rate_limit")
        XCTAssertEqual(PulseHookReceiver.errorMessage(from: ["error": ["message": "boom"]]), "boom")
    }

    /// The event is the installed command's argument; an entry that names
    /// none writes nothing — the payload's own name is not read.
    func testAnEntryThatNamesNoEventWritesNothing() {
        deliver("claude", "", #"{"hook_event_name":"PermissionRequest","tool_name":"Edit","tool_input":{"file_path":"/w/a"},"session_id":"c1"}"#)
        XCTAssertEqual(kinds(), [])
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
        XCTAssertEqual(records().first?.message, "Add a retry")
        XCTAssertEqual(records().last?.message, "Done.")
    }

    // MARK: - Gemini CLI (docs/hooks/reference.md)

    func testGeminiToolPermissionNotificationIsABlock() throws {
        deliver("gemini", "BeforeAgent", #"{"session_id":"g1","transcript_path":"/Users/me/.gemini/tmp/h/chats/g1.json","cwd":"/w","hook_event_name":"BeforeAgent","timestamp":"2026-09-29T10:00:00Z","prompt":"Fix it"}"#)
        deliver("gemini", "Notification", #"{"session_id":"g1","transcript_path":"/Users/me/.gemini/tmp/h/chats/g1.json","cwd":"/w","hook_event_name":"Notification","timestamp":"2026-09-29T10:00:05Z","notification_type":"ToolPermission","message":"Allow run_shell_command: npm test?","details":{"tool_name":"run_shell_command"}}"#)
        deliver("gemini", "AfterAgent", #"{"session_id":"g1","cwd":"/w","hook_event_name":"AfterAgent","prompt":"Fix it","prompt_response":"Fixed.","stop_hook_active":false}"#)
        XCTAssertEqual(kinds(), ["working", "permission", "turn"])
        let block = try XCTUnwrap(records().first { $0.kind == "permission" })
        XCTAssertEqual(block.message, "Allow run_shell_command: npm test?")
        XCTAssertEqual(records().first?.message, "Fix it", "BeforeAgent's prompt")
        XCTAssertEqual(records().last?.message, "Fixed.", "AfterAgent's prompt_response")
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
        XCTAssertEqual(lines.map(\.kind), ["working", "tool", "tool", "turn"])
        XCTAssertEqual(lines[0].message, "Run the tests")
        XCTAssertEqual(lines[1].tool, "bash")
        XCTAssertEqual(lines[1].message, "npm test")
        XCTAssertEqual(lines[2].message, "/w/README.md")
        XCTAssertEqual(lines[3].tool, AttentionRecord.errorTool)
        XCTAssertEqual(lines[3].message, "Model unavailable")
        XCTAssertNil(PulseHookReceiver.toolInput(["toolArgs": "not json"]))
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
        // The grace is about the turn: replay the block and the turn alone.
        for record in blocksAndTurns() { book.apply(record, nowMs: nowMs) }
        XCTAssertEqual(HookFeed.word(book.sessions["opencode|ses_1"]?.state), "blocked:question", "an idle moments after a question does not wipe it (stop grace)")
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
        deliver("pi", "tool_execution_start", #"{"session_id":"p2","cwd":"/w"}"#)
        deliver("pi", "turn_end", #"{"session_id":"p2","cwd":"/w"}"#)
        deliver("claude", "PreToolUse", #"{"session_id":"c2","cwd":"/w","tool_name":"Bash"}"#)
        XCTAssertTrue(records().isEmpty, "\(records().map(\.kind))")
    }

    // MARK: - Pi (extension events)

    /// A Pi prompt with no title never says its event's
    /// reason (`ui_prompt`); the extension sends a reason only on shutdown.
    func testAPiPromptNeverSaysItsReason() throws {
        deliver("pi", "ui_prompt_start", #"{"session_id":"p9","cwd":"/w","kind":"input","reason":"ui_prompt"}"#)
        let line = try XCTUnwrap(records().first)
        XCTAssertEqual(line.kind, "question")
        XCTAssertEqual(line.message, "", "not the literal ui_prompt")
        XCTAssertEqual(PulseHookReceiver.genericMessage(from: ["reason": "ui_prompt"], blocked: true), "")
        XCTAssertEqual(PulseHookReceiver.genericMessage(from: ["reason": "rate_limit"]), "rate_limit", "a turn may still say why it ended")
        let module = HookModules.piExtension(launcher: "/x/pulse-hook", events: ["ui_prompt_start", "session_shutdown"])
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

    /// The Pi extension forwards the tool's name and one short argument.
    func testPiToolEventsNameTheirStep() throws {
        deliver("pi", "tool_execution_end", #"{"session_id":"p3","cwd":"/w","tool_name":"bash","tool_input":{"command":"ls -la"}}"#)
        let line = try XCTUnwrap(records().first)
        XCTAssertEqual(line.kind, "tool")
        XCTAssertEqual(line.tool, "bash")
        XCTAssertEqual(line.message, "ls -la")
        let module = HookModules.piExtension(launcher: "/x/pulse-hook", events: ["tool_execution_end"])
        XCTAssertTrue(module.contains("Object.assign(payload, toolSummary(event))"))
        XCTAssertTrue(module.contains("out.tool_input = { [key]: args[key].slice(0, 2000) }"))
    }

    // MARK: - Payloads that do not parse, and credentials at the cut

    /// A payload cut off (at `stdinLimit`, or by a writer that died) is not
    /// JSON: it writes nothing — never a ghost wait whose ask is raw JSON.
    /// Plain text is no payload either.
    func testAPayloadThatDoesNotParseWritesNothing() throws {
        let whole = #"{"session_id":"t1","cwd":"/w","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm test"}}"#
        let cut = String(whole.prefix(60))
        deliver("claude", "PermissionRequest", cut)
        deliver("claude", "", cut)
        deliver("gemini", "Notification", cut)
        deliver("copilot", "notification", cut)
        PulseHookReceiver.run(
            arguments: ["PulseBar", "--hook", "opencode", "permission.asked", #"{"sessionID":"o1","directory":"/w","permis"#],
            stdin: "", logURL: log, locate: located
        )
        XCTAssertTrue(records().isEmpty, "\(records().map(\.message))")
        XCTAssertNil(PulseHookReceiver.parsePayload(stdin: cut, trailingArg: nil))
        // Plain text on stdin writes nothing, whatever the event says.
        deliver("claude", "Stop", "all done")
        deliver("cursor", "stop", "all done")
        deliver("gemini", "permission", "Approve the deploy?")
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
        XCTAssertEqual(written.map(\.kind), ["tool", "permission"])
        for record in written {
            XCTAssertFalse(record.message.contains("tok3n"), record.message)
        }
        XCTAssertFalse(PulseHookReceiver.condenseOneLine(command).contains("tok3n"))
        XCTAssertTrue(PulseHookReceiver.condenseOneLine(command).contains("Bearer ••••"))
    }

    // MARK: - Rejections

    /// Only the agent's own adapter reads an event: the protocol's kind words
    /// (`permission`, `turn`, `done`, …) are not events of any agent.
    func testUnknownEventsAndAgentsWriteNothing() throws {
        XCTAssertEqual(deliver("claude", "made_up_vendor_event", #"{"message":"x","session_id":"x"}"#), 0)
        for word in AttentionKind.allCases.map(\.rawValue) {
            XCTAssertEqual(deliver("claude", word, #"{"message":"x","session_id":"x"}"#), 0)
            XCTAssertEqual(deliver("gemini", word, #"{"message":"x","session_id":"x"}"#), 0)
        }
        XCTAssertEqual(deliver("goose", "permission", #"{"message":"x","session_id":"x"}"#), 0, "not a supported agent")
        XCTAssertEqual(deliver("claude", "", #"{"message":"says nothing about what it is","session_id":"x"}"#), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }

    /// A payload handed as the last argument means stdin is not read at
    /// all, so a pipe nobody closes cannot hold the hook.
    func testAPayloadInArgvSkipsStdin() {
        XCTAssertTrue(PulseHookReceiver.payloadInArguments(
            ["pulse-hook", "--hook", "pi", "agent_settled", #"{"session_id":"p1"}"#]
        ))
        XCTAssertFalse(PulseHookReceiver.payloadInArguments(["pulse-hook", "--hook", "claude"]))
        XCTAssertFalse(PulseHookReceiver.payloadInArguments(["pulse-hook", "--hook", "gemini", "Notification"]))
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
        XCTAssertEqual(record?.kind, "permission")
        XCTAssertEqual(record?.session, "o1")
        XCTAssertEqual(record?.cwd, "/w")
        XCTAssertEqual(record?.message, "bash: npm test")
        let modules = [
            HookModules.openCodePlugin(launcher: "/x/pulse-hook", events: ["session.idle"]),
            HookModules.piExtension(launcher: "/x/pulse-hook", events: ["agent_settled"]),
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
        var bytes = Data(AttentionProtocol.header(generation: "g1").utf8)
        bytes.append(Data("claude\tpermission\t\(now - 1_000)\tBash: make\ts1\t/p\t\t\t\t\n".utf8))
        bytes.append(contentsOf: [0x63, 0x6C, 0xE2, 0x82, 0x0A]) // "cl" + a truncated "€"
        try bytes.write(to: log)
        let chunk = try XCTUnwrap(EventLog.read(at: log, after: nil))
        XCTAssertFalse(chunk.lines.isEmpty)
        var book = SessionBook()
        for line in chunk.lines {
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
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("claude\t") })
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
        let node: [Int32: String] = [300: "sh -c hook", 200: "node /opt/homebrew/bin/gemini", 100: "zsh"]
        XCTAssertEqual(
            HookLanding.agentPID(agent: .gemini, start: 300, parentOf: { parents[$0] }, argumentsOf: { node[$0] }),
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
        bytes += Array("/opt/homebrew/bin/gemini".utf8) + [0]
        bytes += Array("SECRET=env".utf8) + [0]
        XCTAssertEqual(AgentProcesses.parseProcArgv(bytes), ["node", "/opt/homebrew/bin/gemini"], "argc bounds the read: no environment")
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
        let plugin = HookModules.openCodePlugin(
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
        try write(".gemini/settings.json", "{ \"theme\": ")
        let results = try HooksInstaller.install()
        XCTAssertEqual(results.count, AgentID.allCases.count)
        XCTAssertEqual(results.filter { $0.failure != nil }.map(\.agent), [.gemini])
        XCTAssertEqual(results.first { $0.agent == .gemini }?.failure, .invalidJSON)
        for agent in AgentID.priority where agent != .gemini {
            XCTAssertTrue(HooksSupport.isWired(agent), "\(agent.rawValue) is installed although Gemini failed first in line")
        }
        XCTAssertEqual(read(".gemini/settings.json"), "{ \"theme\": ")

        let status = HooksSupport.status(after: results)
        XCTAssertEqual(status.failures, [.gemini: .invalidJSON])
        XCTAssertTrue(status.isInstalled(for: .claude))
        let label = status.label(lang: .zh)
        XCTAssertTrue(label.contains("Gemini"), label)
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
        try write(".gemini/settings.json", #"{"hooks": {"AfterTool": {"command": "x"}}}"#)
        let shape = try HooksInstaller.install(agents: [.gemini])
        XCTAssertEqual(shape.map(\.failure), [.unexpectedShape])
        // A byte-order mark is no reason to refuse.
        try write(".cursor/hooks.json", "\u{FEFF}{\"version\": 1}\n")
        let cursor = try HooksInstaller.install(agents: [.cursor])
        XCTAssertEqual(cursor.map(\.failure), [nil])
        XCTAssertTrue(HooksSupport.isWired(.cursor))
    }

    /// The Settings lines say what is installed, what is not, when a hook
    /// last spoke, and which agents never report a wait; the agents that
    /// are not on this Mac share one line.
    func testSettingsSaysEachAgentsHook() {
        let now: Int64 = 1_800_000_000_000
        let lines = SettingsModel.hookAgents(
            installed: [.claude, .codex], present: [.claude, .codex, .cursor, .gemini],
            lastEventMs: [.claude: now - 12 * 60_000], nowMs: now, lang: .en
        )
        XCTAssertEqual(lines.map(\.agent), [.claude, .codex, .cursor, .gemini])
        let claude = lines[0]
        XCTAssertTrue(claude.installed)
        XCTAssertEqual(claude.lastEvent, String(format: L10n.t(.settingsHookLastEvent, .en), L10n.duration(12 * 60, .en)))
        XCTAssertNil(claude.note)
        let codex = lines.first { $0.agent == .codex }
        XCTAssertEqual(codex?.lastEvent, L10n.t(.settingsHookNoEvent, .en))
        XCTAssertEqual(codex?.note, L10n.t(.settingsHookNoWait, .en))
        XCTAssertEqual(lines.first { $0.agent == .cursor }?.note, L10n.t(.settingsHookNoWait, .en))
        let gemini = lines.first { $0.agent == .gemini }
        XCTAssertEqual(gemini?.state, L10n.t(.hooksMissing, .en))
        XCTAssertEqual(gemini?.lastEvent, "")
        XCTAssertEqual(gemini?.installed, false, "an agent here without its hook says so; Install all fixes it")
        let absent = SettingsModel.absentAgents(installed: [.claude, .codex], present: [.claude, .codex, .cursor, .gemini])
        XCTAssertEqual(absent, [.copilot, .opencode, .pi], "in roster order")
        let line = SettingsModel.absentLine(absent, lang: .en)
        XCTAssertNotNil(line)
        for agent in absent { XCTAssertTrue(line?.contains(agent.displayName) == true, agent.rawValue) }
        XCTAssertNil(SettingsModel.absentLine([], lang: .en), "nothing to say when every agent is here")
    }

    /// A failed install names the agent and why.
    func testAFailedInstallIsItsOwnLine() {
        let lines = SettingsModel.hookAgents(
            installed: [], present: [], lastEventMs: [:], nowMs: 0, lang: .en,
            failed: [.gemini: .invalidJSON]
        )
        XCTAssertEqual(lines.map(\.agent), [.gemini])
        XCTAssertTrue(lines[0].failed)
        XCTAssertTrue(lines[0].state.contains(L10n.t(.hooksFailureInvalidJSON, .en)), lines[0].state)
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
        XCTAssertTrue(text.hasPrefix("# pulse-events v6 "), text)
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
        // v6: all ten columns; front as given (empty = unknown), pid and
        // landing empty.
        let cols = [agent, kind, "\(now - ago)", message, session, cwd, front ?? "", "", "", tool]
        return cols.joined(separator: "\t")
    }

    static func world(_ lines: [String]) -> TrayState {
        let text = AttentionProtocol.header(generation: "g1") + lines.joined(separator: "\n") + "\n"
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
                line("claude", "turn", ago: 61 * second),
                line("claude", "idle", ago: 1 * second),
            ],
            expect: turn
        ),
        Case(
            name: "claude · permission → red, banner",
            lines: [line("claude", "permission", ago: 5 * second, message: "Bash: rm -rf build")],
            expect: Expect(waiting: true, yourTurn: false, red: true, banner: true, waitKind: "Permission")
        ),
        Case(
            name: "claude · question → red, says Input",
            lines: [line("claude", "question", ago: 5 * second, message: "Which database?")],
            expect: Expect(waiting: true, yourTurn: false, red: true, banner: true, waitKind: "Input")
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
            name: "claude · StopFailure (a turn with the error tool) → your turn, never red",
            lines: [line("claude", "turn", ago: 10 * second, message: "rate_limit", tool: AttentionRecord.errorTool)],
            expect: turn
        ),
        Case(
            name: "codex · a word that is not a v6 kind (an approval, a vendor's turn event) → nothing",
            lines: [
                line("codex", "exec_approval_request", ago: 3 * second, message: "git push"),
                line("codex", "agent-turn-complete", ago: 2 * second),
            ],
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
            name: "claude · idle with no turn seen → your turn",
            lines: [line("claude", "idle", ago: 2 * second)],
            expect: turn
        ),
    ]

    /// A finished turn is grey even while its CLI stays open — the
    /// green ring is for a session that is working, and "your turn" is not.
    @Test func aFinishedTurnWithALiveProcessIsAGreyLamp() throws {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: "claude", kind: "turn", ms: Self.now - 2 * Self.second, session: "s1", cwd: "/p", pid: 42), nowMs: Self.now)
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
        if case .post(let rows) = Self.delivery(r.rows) {
            bannered = rows.contains { $0.rowKey == row.rowKey }
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
        let subagent = PulseHookReceiver.interpret(agent: .claude, event: "SubagentStop", payload: [:])
        #expect(stop?.action == .turn)
        #expect(failure?.action == .failedTurn)
        #expect(subagent == nil, "never installed: not read")

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

/// The event log: one append-only file, read from an offset.
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

    private func line(
        _ kind: String, _ ms: Int64, session: String = "s1", message: String = "",
        tool: String = "", cwd: String = "/w", agent: String = "claude"
    ) -> String {
        AttentionRecord(agent: agent, kind: kind, ms: ms, message: message, session: session, cwd: cwd, tool: tool).line
    }

    // MARK: - The receiver's side

    @Test func everyHookEventIsOneLineInOrderAndPrivate() throws {
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
        #expect(chunk.header.hasPrefix("# pulse-events v6 "))
        let records = chunk.lines.compactMap { AttentionRecord(line: $0) }
        let kinds = records.map { $0.kind }
        let tools = records.map { $0.tool }
        let stamps = records.map { $0.ms }
        #expect(kinds == ["working", "tool", "tool", "tool"], "a session-less tool writes nothing")
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
        EventLog.append(line("working", t0), at: home.log, nowMs: t0)
        let first = try #require(EventLog.read(at: home.log, after: nil))
        #expect(first.fresh)
        #expect(first.lines.count == 1)
        // Nothing new.
        let none = try #require(EventLog.read(at: home.log, after: first.cursor))
        #expect(!none.fresh)
        #expect(none.lines.isEmpty)
        // A writer mid-line: the partial line waits for the next read.
        var bytes = try Data(contentsOf: home.log)
        bytes.append(Data("claude\tturn\t\(t0 + 1)".utf8))
        try bytes.write(to: home.log)
        let partial = try #require(EventLog.read(at: home.log, after: first.cursor))
        #expect(partial.lines.isEmpty)
        #expect(partial.end == first.end)
        // The next append starts on its own line.
        EventLog.append(line("tool", t0 + 2, tool: "Read"), at: home.log, nowMs: t0 + 2)
        let next = try #require(EventLog.read(at: home.log, after: first.cursor))
        let kinds = next.lines.compactMap { AttentionRecord(line: $0)?.kind }
        #expect(kinds == ["tool"], "the torn line is dropped, the new one is whole")
    }

    /// A missing file is an empty log — a fresh, empty chunk, so the launch
    /// replay is over and the first wait written after it is news. A file
    /// that exists but cannot be read is a failed read (nil — the caller
    /// keeps its state).
    @Test func aMissingFileIsAnEmptyLogAndAnUnreadableOneAFailedRead() throws {
        let home = Home()
        let fresh = EventLog.read(at: home.log, after: nil)
        #expect(fresh == EventLog.Chunk(header: "", lines: [], end: 0, fresh: true))
        EventLog.append(line("working", t0), at: home.log, nowMs: t0)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: home.log.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.log.path) }
        let unreadable = EventLog.read(at: home.log, after: nil)
        #expect(unreadable == nil)
    }

    /// Lines end at `\n` bytes only: a U+2028, a NEL or a lone `\r` inside a
    /// field (a writer that did not clean it) never splits a record. And the
    /// receiver cleans every kind of line break out of a field.
    @Test func aLineBreakInsideAFieldNeverSplitsARecord() throws {
        let odd = "claude\tpermission\t\(t0)\tBash: a\u{2028}b\u{85}c\rd\ts1\t/w\t\t\t\tBash\n"
        let data = Data((AttentionProtocol.header(generation: "g1") + odd).utf8)
        let chunk = EventLog.parse(data, from: 0, header: "# g1", fresh: true)
        #expect(chunk.lines.count == 1)
        let parsed = chunk.lines.compactMap { AttentionRecord(line: $0) }
        let record = try #require(parsed.first)
        #expect(record.session == "s1")
        #expect(record.tool == "Bash")
        let cleaned = PulseHookReceiver.cleanField("a\u{2028}b\u{0B}c\u{85}d\u{2029}e\u{0C}f\r\ng\th", limit: 100)
        #expect(cleaned == "a b c d e f  g h")
        #expect(AttentionProtocol.flatten("x\u{2028}") == "x")
    }

    /// A rewritten log is matched to what was applied by position: a kept
    /// line is not applied again, and a line written twice is applied twice.
    @Test func unappliedLinesAreMatchedByPositionNotText() {
        #expect(EventLog.unapplied(["A", "B", "A"], after: ["A", "B", "A"]) == [], "the compaction kept everything")
        #expect(EventLog.unapplied(["B", "A"], after: ["A", "B", "A"]) == [], "the compaction kept a subset")
        #expect(EventLog.unapplied(["B", "A", "A"], after: ["A", "B", "A"]) == ["A"], "the same text appended again is new")
        #expect(EventLog.unapplied(["A", "B", "C"], after: ["A", "B"]) == ["C"])
        #expect(EventLog.unapplied(["C", "A"], after: ["A", "B"]) == ["C"], "an unknown line is new; a known one is not")
        #expect(EventLog.unapplied(["A"], after: []) == ["A"])
    }

    /// The last line applied anchors a rewrite: everything after the copy
    /// the compaction kept is new — even a line whose text matches one
    /// applied earlier and dropped. A greedy match took the kept last line
    /// for the earlier copy, then the new line for a dropped one, and
    /// skipped it.
    @Test func aNewLineLikeADroppedAppliedOneIsStillNew() {
        // Applied: A, B, A. The compaction kept the newest A only; B is
        // written again (the same text) after it.
        let fresh = EventLog.unapplied(["A", "B"], after: ["A", "B", "A"])
        #expect(fresh == ["B"])
        // Lines the reader had not reached before the rewrite come after
        // the anchor too.
        let unread = EventLog.unapplied(["X", "C", "D"], after: ["W", "X", "C"])
        #expect(unread == ["D"])
        // With no copy of the last applied line kept, lines are matched in
        // order.
        let noAnchor = EventLog.unapplied(["W", "E"], after: ["W", "X", "C"])
        #expect(noAnchor == ["E"])
    }

    /// A compaction keeps what a replay rebuilds a session's own facts
    /// from: its first clock, the prompt its title came from and its latest
    /// prompt — so after a rewrite and a replay the row says the same title
    /// and the same age.
    @Test func compactionKeepsTheTitleAndTheFirstClock() {
        let now = t0
        let base = now - 5 * Self.hour
        var lines = [
            line("start", base, session: "t"),
            line("working", base + 1_000, session: "t", message: "continue"),
            line("working", base + 2_000, session: "t", message: "Fix the login redirect"),
        ]
        for index in 0..<300 { lines.append(line("tool", base + 10_000 + Int64(index), session: "t", tool: "Read")) }
        lines.append(line("working", base + 20_000, session: "t", message: "Now the logout"))
        for index in 0..<300 { lines.append(line("tool", base + 30_000 + Int64(index), session: "t", tool: "Edit")) }
        func replay(_ text: [String]) -> SessionBook.Session? {
            var book = SessionBook()
            for raw in text {
                if let record = AttentionRecord(line: raw) { book.apply(record, nowMs: now) }
            }
            return book.sessions["claude|t"]
        }
        let kept = EventLog.compact(lines, nowMs: now, budget: 1 << 30)
        #expect(kept.count < lines.count)
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

    /// The record being appended is always in the file after its own
    /// compaction — even one older than the retention window.
    @Test func theAppendedRecordSurvivesItsOwnCompaction() throws {
        let home = Home()
        var ms = t0
        let pad = String(repeating: "y", count: 180)
        while home.size < EventLog.maxBytes - 300 {
            EventLog.append(line("tool", ms, session: "busy", message: pad, tool: "Read"), at: home.log, nowMs: ms)
            ms += 1
        }
        // Longer than the room left, so this append compacts.
        let ancient = line("turn", t0 - 3 * EventLog.retentionMs, session: "late", message: String(repeating: "z", count: 400))
        #expect(EventLog.append(ancient, at: home.log, nowMs: ms))
        let chunk = try #require(EventLog.read(at: home.log, after: nil))
        #expect(chunk.lines.last == ancient)
        #expect(home.size < EventLog.maxBytes)
    }

    @Test func aCursorFromAnotherGenerationReadsTheWholeFileAgain() throws {
        let home = Home()
        EventLog.append(line("working", t0), at: home.log, nowMs: t0)
        let first = try #require(EventLog.read(at: home.log, after: nil))
        let stale = EventLog.Cursor(header: "# pulse-events v6 gOLD", offset: first.end)
        let again = try #require(EventLog.read(at: home.log, after: stale))
        #expect(again.fresh)
        #expect(again.lines == first.lines)
        let past = EventLog.Cursor(header: first.header, offset: first.end + 10_000)
        let shorter = try #require(EventLog.read(at: home.log, after: past))
        #expect(shorter.fresh, "a file shorter than the cursor was rewritten")
    }

    /// A log that is not v6 — an older header, or none — is never read and
    /// never migrated: a read finds it empty, and the next writer (the
    /// launch's `ensureExists`, or an append) starts a fresh v6 log.
    @Test func aLogThatIsNotV6IsTreatedAsAbsentAndStartedOver() throws {
        let home = Home()
        let old = "# pulse-events v5 g1 (agent)\nclaude\tpermission\t\(t0)\tBash: make\ts1\t/w\t\t\t\t\tBash\n"
        try Data(old.utf8).write(to: home.log)
        let unread = try #require(EventLog.read(at: home.log, after: nil))
        #expect(unread.lines.isEmpty)
        #expect(unread.fresh)
        EventLog.ensureExists(at: home.log, nowMs: t0)
        let fresh = String(decoding: try Data(contentsOf: home.log), as: UTF8.self)
        #expect(fresh.hasPrefix(AttentionProtocol.headerPrefix), "\(fresh)")
        #expect(!fresh.contains("Bash: make"), "the old lines are gone, unread")

        let headerless = Home()
        try Data("claude\tturn\t\(t0)\t\ts1\t/w\t\t\t\t\n".utf8).write(to: headerless.log)
        #expect(EventLog.append(line("working", t0 + 1), at: headerless.log, nowMs: t0 + 1))
        let chunk = try #require(EventLog.read(at: headerless.log, after: nil))
        #expect(chunk.header.hasPrefix(AttentionProtocol.headerPrefix))
        let kinds = chunk.lines.compactMap { AttentionRecord(line: $0)?.kind }
        #expect(kinds == ["working"], "only the line appended after the start over")
    }

    /// One invalid byte (a hook cut off mid-character) never erases what
    /// is there: appends never rewrite, and reads are lossy.
    @Test func anInvalidByteDoesNotEraseOpenWaits() throws {
        let home = Home()
        var bytes = Data(AttentionProtocol.header(generation: "g1").utf8)
        bytes.append(Data((line("permission", t0, message: "Bash: npm test") + "\n").utf8))
        bytes.append(Data([0x63, 0x6f, 0xff, 0x0a]))
        try bytes.write(to: home.log)
        EventLog.append(line("done", t0, session: "s2", agent: "codex"), at: home.log, nowMs: t0)
        let text = String(decoding: try Data(contentsOf: home.log), as: UTF8.self)
        #expect(text.contains("claude\tpermission"))
        #expect(text.contains("codex\tdone"))
    }

    // MARK: - Compaction

    /// An append past the bound compacts: a new generation, the newest line
    /// kept, and an open block kept however old.
    @Test func anAppendPastTheBoundCompactsIntoANewGeneration() throws {
        let home = Home()
        let old = t0 - 5 * Self.hour
        EventLog.append(line("permission", old, session: "keep-me", message: "Bash: make", tool: "Bash"), at: home.log, nowMs: old)
        let before = try #require(EventLog.read(at: home.log, after: nil))
        var ms = old + 1
        let pad = String(repeating: "x", count: 180)
        while home.size < EventLog.maxBytes - 400 {
            EventLog.append(line("tool", ms, session: "busy", message: pad, tool: "Read"), at: home.log, nowMs: ms)
            ms += 1
        }
        EventLog.append(line("tool", t0, session: "busy", message: pad, tool: "Read"), at: home.log, nowMs: t0)
        EventLog.append(line("tool", t0 + 1, session: "busy", message: pad, tool: "Read"), at: home.log, nowMs: t0 + 1)
        let after = try #require(EventLog.read(at: home.log, after: before.cursor))
        #expect(after.fresh, "a new generation: the old cursor reads the whole file")
        #expect(after.header != before.header)
        #expect(home.size < EventLog.maxBytes)
        let records = after.lines.compactMap { AttentionRecord(line: $0) }
        let kept = records.contains { $0.session == "keep-me" && $0.kind == "permission" }
        #expect(kept, "an open block is never dropped")
        let newest = records.last?.ms
        #expect(newest == t0 + 1, "the newest line is kept")
    }

    /// Compaction keeps a block together with what answers it, groups a
    /// session-less line by agent and folder, and forgets a
    /// day-old session.
    @Test func compactionKeepsPerSessionHistory() {
        let now = t0
        let base = now - 3 * Self.hour
        var lines: [String] = []
        // An answered block, then a long tail in the same session.
        lines.append(line("permission", base, session: "a", message: "Bash: ls", tool: "Bash"))
        lines.append(line("tool", base + 1_000, session: "a", tool: "Bash"))
        for index in 0..<200 { lines.append(line("tool", base + 2_000 + Int64(index), session: "a", tool: "Read")) }
        // An open block with parallel tools after it that do not answer it.
        lines.append(line("permission", base + 10_000, session: "b", message: "Bash: make", tool: "Bash"))
        for index in 0..<100 { lines.append(line("tool", base + 11_000 + Int64(index), session: "b", tool: "Read")) }
        // Two session-less folders of one agent.
        lines.append(line("permission", base + 20_000, session: "", message: "Allow?", cwd: "/one", agent: "gemini"))
        for index in 0..<100 { lines.append(line("start", base + 21_000 + Int64(index), session: "", cwd: "/two", agent: "gemini")) }
        // A session nobody has heard from for two days.
        lines.append(line("turn", now - 2 * EventLog.retentionMs, session: "gone"))

        let records = EventLog.compact(lines, nowMs: now, budget: 1 << 30).compactMap { AttentionRecord(line: $0) }
        let a = records.filter { $0.session == "a" }
        #expect(a.count == EventLog.linesPerSession + 1, "a session keeps its last lines once nothing in it is open, and its first clock")
        #expect(!a.contains { $0.kind == "permission" }, "an answered block is never kept without its answer")
        let b = records.filter { $0.session == "b" }
        #expect(b.first?.kind == "permission", "an open block is kept, with every line after it")
        #expect(b.count == 101)
        let folder = records.contains { $0.agent == "gemini" && $0.cwd == "/one" }
        #expect(folder, "a session-less wait is not pushed out by another folder's lines")
        let gone = records.contains { $0.session == "gone" }
        #expect(!gone)

        // A tight budget still keeps the open blocks.
        let tight = EventLog.compact(lines, nowMs: now, budget: 1_000).compactMap { AttentionRecord(line: $0) }
        let openB = tight.contains { $0.session == "b" && $0.kind == "permission" }
        let openOne = tight.contains { $0.cwd == "/one" && $0.kind == "permission" }
        #expect(openB)
        #expect(openOne)
        // A dismissal's session-less `done` names its folder: it answers
        // that folder's block only, so another folder's open block stays.
        let dismissed = lines + [line("done", base + 30_000, session: "", cwd: "/two", agent: "gemini")]
        let afterDone = EventLog.compact(dismissed, nowMs: now, budget: 1_000).compactMap { AttentionRecord(line: $0) }
        let stillOpen = afterDone.contains { $0.cwd == "/one" && $0.kind == "permission" }
        #expect(stillOpen, "a done for /two is not an answer in /one")
        // Recent lines all stay.
        let recent = (0..<300).map { line("tool", now - 1_000 + Int64($0), session: "hot", tool: "Read") }
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
        let text = [
            ["claude", "permission", "\(raise)", "Bash: npm test", "s1", "/p", "", "", "", ""],
            ["claude", "turn", "\(raise + 1_000)", "", "s1", "", "", "", "", ""],
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
