import Foundation
import SQLite3
import Testing
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

// Vendor formats: fixtures built from each vendor's own source (docs/vendor-formats.json).

/// 20.0 Drift — every fixture here is built from the vendor's own serializer
/// or schema (the commit read is in docs/vendor-formats.json), and each test
/// asserts the value the tray would show. The ones marked "invariant" were
/// fake Waiting before 20.0.
@Suite("Vendor drift", .serialized)
struct VendorDriftTests {
    let now = Int64(Date().timeIntervalSince1970 * 1000)

    // MARK: - Harness

    final class Home {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("pulse-drift-\(UUID().uuidString)", isDirectory: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        func write(_ relative: String, _ text: String) throws {
            let file = url.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }

        func database(_ relative: String, _ statements: [String]) throws {
            let file = url.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var db: OpaquePointer?
            guard sqlite3_open(file.path, &db) == SQLITE_OK, let db else { throw CocoaError(.fileWriteUnknown) }
            defer { sqlite3_close(db) }
            for sql in statements {
                guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "drift", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db)) + " — " + sql])
                }
            }
        }

        func rows(_ id: AgentID) -> [ActivityHarvest.Row] {
            NativeActivityHarvest.scan(
                allowAppData: true, appDataAgents: [id], home: url, agentFilter: [id]
            ).rows.filter { $0.id == id }
        }
    }

    // MARK: - Gemini

    @Test func geminiCheckpointsRewindsAndSubagents() throws {
        let home = Home()
        let chats = ".gemini/tmp/app/chats"
        try home.write(".gemini/tmp/app/.project_root", "/Users/me/app")
        try home.write("\(chats)/session-2026-09-29T10-15-1a2b3c4d.jsonl", [
            #"{"sessionId":"1a2b3c4d","projectHash":"h","startTime":"2026-09-29T10:15:02.114Z","lastUpdated":"2026-09-29T10:15:02.114Z"}"#,
            #"{"id":"u1","timestamp":"2026-09-29T10:15:09.500Z","type":"user","content":[{"text":"Add an offline queue for login"}]}"#,
            #"{"id":"g1","timestamp":"2026-09-29T10:15:20.000Z","type":"gemini","content":"Draft one."}"#,
            #"{"id":"u2","timestamp":"2026-09-29T10:15:30.000Z","type":"user","content":[{"text":"no, rewind that"}]}"#,
            #"{"$rewindTo":"u2"}"#,
            #"{"id":"g2","timestamp":"2026-09-29T10:16:40.020Z","type":"gemini","content":"The queue drains on reconnect; 42 tests pass."}"#,
            #"{"$set":{"lastUpdated":"2026-09-29T10:16:40.021Z"}}"#,
        ].joined(separator: "\n"))
        try home.write("\(chats)/1a2b3c4d/child-1.jsonl", [
            #"{"sessionId":"child-1","projectHash":"h","startTime":"2026-09-29T10:16:00.000Z","lastUpdated":"2026-09-29T10:16:00.000Z","kind":"subagent","directories":["/Users/me/app"]}"#,
            #"{"id":"c1","timestamp":"2026-09-29T10:16:01.000Z","type":"user","content":[{"text":"subagent chore"}]}"#,
        ].joined(separator: "\n"))
        let rows = home.rows(.gemini)
        #expect(rows.count == 1, "a subagent chat belongs to its parent")
        let row = try #require(rows.first)
        #expect(row.task == "Add an offline queue for login", "the rewound prompt is gone")
        #expect(row.lastWord == "The queue drains on reconnect; 42 tests pass.")
        #expect(row.cwd == "/Users/me/app")
    }

    @Test func geminiUnderTheSandboxIsStillSeen() throws {
        let home = Home()
        try home.write(".cache/.gemini/tmp/app/.project_root", "/Users/me/app")
        try home.write(".cache/.gemini/tmp/app/chats/session-x.jsonl", [
            #"{"sessionId":"sbx","projectHash":"h","startTime":"2026-09-29T10:15:02.114Z","lastUpdated":"2026-09-29T10:15:02.114Z"}"#,
            #"{"id":"u1","timestamp":"2026-09-29T10:15:09.500Z","type":"user","content":[{"text":"Sandboxed run"}]}"#,
        ].joined(separator: "\n"))
        #expect(home.rows(.gemini).first?.task == "Sandboxed run")
    }

    @Test func geminiTaskIsWhatTheUserTypedNotTheExpandedFile() {
        let text = [
            #"{"sessionId":"s","projectHash":"h","startTime":"2026-09-29T10:00:00.000Z"}"#,
            #"{"id":"u1","timestamp":"2026-09-29T10:00:01.000Z","type":"user","content":[{"text":"Summarise @README.md\n--- README.md ---\n# Pulse …"}],"displayContent":[{"text":"Summarise @README.md"}]}"#,
        ].joined(separator: "\n")
        #expect(NativeActivityHarvest.parseGeminiFacts(text, path: "/h/.gemini/tmp/a/chats/s.jsonl").first?.task == "Summarise @README.md")
    }

    // MARK: - OpenCode (invariant)

    private func openCode(_ home: Home, root: String = ".local/share/opencode/opencode.db", parts: [(String, String)], title: String = "Offline queue for login", parent: String = "NULL") throws {
        var statements = [
            "CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT NOT NULL, title TEXT NOT NULL, agent TEXT, model TEXT, tokens_input INTEGER DEFAULT 0 NOT NULL, tokens_output INTEGER DEFAULT 0 NOT NULL, summary_files INTEGER, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, time_archived INTEGER);",
            "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);",
            "CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);",
            "INSERT INTO session VALUES ('ses_1', \(parent), '/Users/me/app', '\(title)', 'build', '{\"id\":\"claude-sonnet-4-5\",\"providerID\":\"anthropic\"}', 1200, 300, NULL, \(now - 60_000), \(now - 60_000), NULL);",
            "INSERT INTO message VALUES ('msg_u', 'ses_1', \(now - 60_000), \(now - 60_000), '{\"role\":\"user\",\"time\":{\"created\":\(now - 60_000)}}');",
            "INSERT INTO part VALUES ('prt_u', 'msg_u', 'ses_1', \(now - 60_000), \(now - 60_000), '{\"type\":\"text\",\"text\":\"Add an offline queue for login\"}');",
            "INSERT INTO message VALUES ('msg_a', 'ses_1', \(now - 50_000), \(now - 1_000), '{\"role\":\"assistant\"}');",
        ]
        for (index, part) in parts.enumerated() {
            statements.append("INSERT INTO part VALUES ('prt_\(index)', 'msg_a', 'ses_1', \(now - 5_000 + Int64(index)), \(now - 5_000 + Int64(index)), '\(part.1)');")
            _ = part.0
        }
        try home.database(root, statements)
    }

    @Test func openCodeStreamingToolInputIsNotAWait() throws {
        let home = Home()
        try openCode(home, parts: [("tool", #"{"type":"tool","tool":"bash","callID":"c1","state":{"status":"pending","input":{}}}"#)])
        let row = try #require(home.rows(.opencode).first)
        #expect(row.skill != "pending", "`pending` is the tool input streaming — every tool call used to flash red")
        #expect(row.harvestMs >= now - 6_000, "activity follows the newest part, not the prompt")
    }

    @Test func openCodeQuestionToolIsTheOneRecordedWait() throws {
        let home = Home()
        try openCode(home, parts: [("tool", #"{"type":"tool","tool":"question","callID":"c1","state":{"status":"running","input":{}}}"#)])
        #expect(try #require(home.rows(.opencode).first).skill == "pending")
    }

    @Test func openCodePlaceholderTitleGivesWayToThePrompt() throws {
        let home = Home()
        try openCode(home, parts: [], title: "New session - 2026-09-29T10:00:00.000Z")
        #expect(try #require(home.rows(.opencode).first).task == "Add an offline queue for login")
    }

    @Test func openCodeSubagentSessionsAreNotRows() throws {
        let home = Home()
        try openCode(home, parts: [], parent: "'ses_parent'")
        #expect(home.rows(.opencode).isEmpty)
    }

    @Test func aForeignDatabaseInAnOpenCodeCheckoutIsNotOpened() throws {
        let home = Home()
        try openCode(home, parts: [])
        try home.database(".local/share/opencode/worktree/app/data/app.db", ["CREATE TABLE unrelated (x INTEGER);"])
        let result = NativeActivityHarvest.scan(home: home.url, agentFilter: [.opencode])
        #expect(result.rows.contains { $0.id == .opencode })
        #expect(result.health.first { $0.id == .opencode }?.state.isIssue != true, "someone else's database is not a failed read")
    }

    // MARK: - Copilot CLI

    @Test func copilotSessionStateEvents() throws {
        let home = Home()
        try home.write(".copilot/session-state/c0ffee/events.jsonl", [
            #"{"id":"e1","parentId":null,"timestamp":"2026-09-29T10:00:00.000Z","type":"session.start","data":{"sessionId":"c0ffee","context":{"cwd":"/Users/me/app","gitRoot":"/Users/me/app"}}}"#,
            #"{"id":"e2","parentId":"e1","timestamp":"2026-09-29T10:00:01.000Z","type":"user.message","data":{"content":"Add an offline queue for login"}}"#,
            #"{"id":"e3","parentId":"e2","timestamp":"2026-09-29T10:00:09.000Z","type":"assistant.message","data":{"content":"The queue drains on reconnect; 42 tests pass.","model":"gpt-5"}}"#,
        ].joined(separator: "\n"))
        let row = try #require(home.rows(.copilot).first)
        #expect(row.task == "Add an offline queue for login")
        #expect(row.lastWord == "The queue drains on reconnect; 42 tests pass.")
        #expect(row.cwd == "/Users/me/app")
        #expect(row.sessionID == "c0ffee")
    }

    // MARK: - Pi

    @Test func piCacheWarmingIsNotActivity() throws {
        let text = [
            #"{"type":"session","version":3,"id":"0199a1b2-c3d4-7e5f-8a6b-7c8d9e0f1a2b","timestamp":"2026-09-29T10:00:00.000Z","cwd":"/Users/me/app"}"#,
            #"{"type":"message","id":"b2c3d4e5","parentId":null,"timestamp":"2026-09-29T10:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"Add an offline queue for login"}],"timestamp":1790676001000}}"#,
            #"{"type":"message","id":"c3d4e5f6","parentId":"b2c3d4e5","timestamp":"2026-09-29T10:00:09.000Z","message":{"role":"assistant","content":[{"type":"text","text":"The queue drains on reconnect; 42 tests pass."}],"stopReason":"stop","timestamp":1790676009000}}"#,
            #"{"type":"usage","id":"d4e5f6a7","parentId":"c3d4e5f6","timestamp":"2026-09-29T10:25:00.000Z","kind":"cache_warm","provider":"anthropic","model":"m","usage":{}}"#,
        ].joined(separator: "\n")
        let fact = try #require(NativeActivityHarvest.parsePiFacts(text, path: "/h/.pi/agent/sessions/--Users-me-app--/2026-09-29T10-00-00-000Z_0199a1b2-c3d4-7e5f-8a6b-7c8d9e0f1a2b.jsonl").first)
        let assistant = NativeActivityHarvest.normalizeTimestamp("2026-09-29T10:00:09.000Z")
        #expect(fact.activityMs == assistant, "twenty-five minutes of cache warming is not twenty-five minutes of work")
    }

    // MARK: - Hooks (invariant)

    /// 24.0: Grok runs Claude's hooks by default and marks its calls; Grok
    /// is not supported, and its events never land on a Claude row.
    @Test func grokCallingClaudesHooksIsRefused() {
        #expect(PulseHookReceiver.attributedAgent("claude", environment: ["GROK_HOOK_EVENT": "Notification"]) == nil)
        #expect(PulseHookReceiver.attributedAgent("claude", environment: [:]) == .claude)
        #expect(PulseHookReceiver.attributedAgent("codex", environment: ["GROK_SESSION_ID": "x"]) == .codex)
        #expect(PulseHookReceiver.attributedAgent("goose", environment: [:]) == nil)
    }

    @Test(arguments: ["agentStop", "preToolUse", "beforeShellExecution", "tool.execute.before", ""])
    func anUnknownVendorEventIsNeverRed(event: String) {
        for agent in AgentID.allCases {
            let reading = PulseHookReceiver.interpret(agent: agent, event: event, payload: [:])
            let blocked: Bool
            if case .blocked = reading?.action { blocked = true } else { blocked = false }
            #expect(!blocked, "\(agent.rawValue) \(event)")
        }
    }

    @Test func anUntypedNotificationIsNotAWait() {
        let untyped = PulseHookReceiver.interpret(agent: .claude, event: "Notification", payload: ["message": "idle for 60s"])
        #expect(untyped?.action == .ignore)
        let typed = PulseHookReceiver.interpret(agent: .claude, event: "Notification", payload: ["notification_type": "permission_prompt"])
        #expect(typed?.action == .blocked(.permission))
        #expect(AttentionProtocol.normalizeKind("stop") == AttentionKind.turn.rawValue, "a known alias still normalises")
    }
}

/// 18.0 · Codex's "paginated" history mode. It stops persisting
/// `user_message` / `agent_message` and writes `item_completed` turn items
/// instead (codex-rs `ItemCompletedEvent { item: TurnItem }`, `TurnItem`
/// tagged by `type`, message content `[{type: "text"|"Text", text}]`). Rollouts
/// older than seven days are compressed to `.jsonl.zst`. Shapes are taken from
/// the Codex source, not guessed.
@Suite("Codex paginated rollouts", .serialized)
struct CodexPaginatedRolloutTests {
    private func scan(_ lines: [String], name: String = "rollout-2026-09-29T10-00-00-abc.jsonl") throws -> [ActivityHarvest.Row] {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-codex-paged-\(UUID().uuidString)")
        let file = home
            .appendingPathComponent(".codex/sessions/2026/09/29", isDirectory: true)
            .appendingPathComponent(name)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return NativeActivityHarvest.scan(home: home, agentFilter: [.codex]).rows.filter { $0.id == .codex }
    }

    @Test func theTaskAndTheLastWordComeFromCompletedItems() throws {
        let rows = try scan([
            #"{"type":"session_meta","payload":{"session_id":"pg-1","cwd":"/Users/me/app"},"timestamp":1790000000}"#,
            #"{"type":"turn_context","payload":{"model":"gpt-5.2-codex","cwd":"/Users/me/app"},"timestamp":1790000001}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"},"timestamp":1790000002}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","thread_id":"th","turn_id":"t1","item":{"type":"UserMessage","id":"u1","content":[{"type":"text","text":"Add an offline queue for login","text_elements":[]}]},"completed_at_ms":1790000000000},"timestamp":1790000003}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","thread_id":"th","turn_id":"t1","item":{"type":"AgentMessage","id":"a1","content":[{"type":"Text","text":"The queue drains on reconnect; 42 tests pass."}]},"completed_at_ms":1790000001000},"timestamp":1790000004}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1"},"timestamp":1790000005}"#,
        ])
        let row = try #require(rows.first)
        #expect(row.task == "Add an offline queue for login")
        #expect(row.lastWord.contains("queue drains on reconnect"), "\(row.lastWord)")
        #expect(row.model == "gpt-5.2-codex")
    }

    @Test func otherItemKindsAreNotMistakenForWords() throws {
        let rows = try scan([
            #"{"type":"session_meta","payload":{"session_id":"pg-2","cwd":"/Users/me/app"},"timestamp":1790000000}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"u1","content":[{"type":"text","text":"Tidy the settings screen"}]}},"timestamp":1790000001}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"Reasoning","id":"r1","summary_text":["thinking about layout"]}},"timestamp":1790000002}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"c1","command":"swift test"}},"timestamp":1790000003}"#,
        ])
        let row = try #require(rows.first)
        #expect(row.task == "Tidy the settings screen")
        #expect(!row.lastWord.contains("thinking"))
    }

    @Test func legacyAndPaginatedLinesAgree() {
        #expect(NativeActivityHarvest.codexItemText([["type": "text", "text": "a"], ["type": "image", "url": "x"], ["type": "Text", "text": "b"]]) == "a\nb")
        #expect(NativeActivityHarvest.codexItemText("plain") == "plain")
        #expect(NativeActivityHarvest.codexItemText(nil) == "")
    }

    @Test func aCompressedRolloutIsNeverReadAsText() throws {
        // Seven-day-old rollouts become `.jsonl.zst`. Reading the bytes as
        // JSONL would invent a session out of compressed noise.
        let rows = try scan(["\u{28}\u{B5}\u{2F}\u{FD} not json"], name: "rollout-2026-09-01T10-00-00-old.jsonl.zst")
        #expect(rows.isEmpty)
    }
}
