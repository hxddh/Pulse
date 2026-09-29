import Foundation
import SQLite3
import Testing
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

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

    @Test func kiloSevenIsReadThroughTheOpenCodeSchema() throws {
        let home = Home()
        try openCode(home, root: ".local/share/kilo/kilo.db", parts: [])
        #expect(try #require(home.rows(.kilo).first).cwd == "/Users/me/app")
    }

    // MARK: - Goose

    private func goose(_ home: Home, messages: [(String, String)]) throws {
        var statements = [
            "CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', description TEXT NOT NULL DEFAULT '', user_set_name BOOLEAN DEFAULT FALSE, session_type TEXT NOT NULL DEFAULT 'user', working_dir TEXT NOT NULL, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, extension_data TEXT DEFAULT '{}', accumulated_input_tokens INTEGER, accumulated_output_tokens INTEGER, provider_name TEXT, model_config_json TEXT, goose_mode TEXT NOT NULL DEFAULT 'auto', archived_at TIMESTAMP, project_id TEXT, parent_session_id TEXT);",
            "CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, message_id TEXT, session_id TEXT NOT NULL REFERENCES sessions(id), role TEXT NOT NULL, content_json TEXT NOT NULL, created_timestamp INTEGER NOT NULL, timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP, tokens INTEGER, metadata_json TEXT);",
            "INSERT INTO sessions (id, name, working_dir, updated_at, accumulated_input_tokens, accumulated_output_tokens, model_config_json) VALUES ('20260929_1', 'CLI Session', '/Users/me/app', datetime('now'), 1200, 300, '{\"model_name\":\"claude-sonnet-4-5\"}');",
        ]
        for (index, message) in messages.enumerated() {
            statements.append("INSERT INTO messages (message_id, session_id, role, content_json, created_timestamp) VALUES ('m\(index)', '20260929_1', '\(message.0)', '\(message.1)', \(now / 1000 - 60 + Int64(index)));")
        }
        try home.database(".local/share/goose/sessions/sessions.db", statements)
    }

    @Test func gooseSessionsComeFromItsDatabase() throws {
        let home = Home()
        try goose(home, messages: [
            ("user", #"[{"type":"text","text":"Add an offline queue for login"}]"#),
            ("assistant", #"[{"type":"text","text":"The queue drains on reconnect; 42 tests pass."}]"#),
        ])
        let row = try #require(home.rows(.goose).first)
        #expect(row.task == "Add an offline queue for login", "the placeholder name gives way to the prompt")
        #expect(row.lastWord == "The queue drains on reconnect; 42 tests pass.")
        #expect(row.cwd == "/Users/me/app")
        #expect(row.model == "claude-sonnet-4-5")
        #expect(row.skill != "pending")
    }

    @Test func gooseOpenElicitationIsAWaitUntilAnswered() throws {
        let home = Home()
        let ask = #"[{"type":"actionRequired","data":{"actionType":"elicitation","id":"e1","message":"Which database?","requested_schema":{}}}]"#
        try goose(home, messages: [("user", #"[{"type":"text","text":"Migrate"}]"#), ("assistant", ask)])
        #expect(try #require(home.rows(.goose).first).skill == "pending")

        let answered = Home()
        try goose(answered, messages: [
            ("user", #"[{"type":"text","text":"Migrate"}]"#), ("assistant", ask),
            ("user", #"[{"type":"actionRequired","data":{"actionType":"elicitationResponse","id":"e1","user_data":{}}}]"#),
        ])
        #expect(try #require(answered.rows(.goose).first).skill != "pending")
    }

    // MARK: - Cline family (invariant)

    private let cline = "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev"
    private let roo = "Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline"

    @Test func aFinishedClineTaskIsNotRed() throws {
        let home = Home()
        try home.write("\(cline)/tasks/1790000000000/ui_messages.json", """
        [{"ts":\(now - 40_000),"type":"say","say":"task","text":"Add an offline queue for login"},{"ts":\(now - 36_000),"type":"ask","ask":"command","text":"npm test","partial":false},{"ts":\(now - 20_000),"type":"say","say":"command","text":"npm test"},{"ts":\(now - 10_000),"type":"say","say":"completion_result","text":"The queue drains on reconnect; 42 tests pass.","partial":false},{"ts":\(now - 9_000),"type":"ask","ask":"completion_result","text":""}]
        """)
        try home.write("\(cline)/state/taskHistory.json", """
        [{"id":"1790000000000","ts":\(now - 9_000),"task":"Add an offline queue for login","tokensIn":1200,"tokensOut":80,"cwdOnTaskInitialization":"/Users/me/app","modelId":"claude-sonnet-4-5"}]
        """)
        let rows = home.rows(.cline)
        #expect(rows.count == 1, "the task directory is the session")
        let row = try #require(rows.first)
        #expect(row.skill != "pending", "a completion_result ask is idle — the long-granted command ask is history")
        #expect(row.lastWord == "The queue drains on reconnect; 42 tests pass.")
        #expect(row.cwd == "/Users/me/app")
        #expect(row.sessionID == "1790000000000")
    }

    @Test func aClineCommandApprovalIsAWait() throws {
        let home = Home()
        try home.write("\(cline)/tasks/1790000000001/ui_messages.json", """
        [{"ts":\(now - 5_000),"type":"say","say":"task","text":"Add an offline queue for login"},{"ts":\(now - 1_000),"type":"ask","ask":"command","text":"npm test","partial":false}]
        """)
        #expect(try #require(home.rows(.cline).first).skill == "pending")
    }

    @Test func rooRecordsItsAnswers() throws {
        let home = Home()
        try home.write("\(roo)/tasks/019a3c1e/ui_messages.json", """
        [{"ts":\(now - 5_000),"type":"say","say":"text","text":"Add an offline queue for login"},{"ts":\(now - 1_000),"type":"ask","ask":"followup","text":"Which store?","isAnswered":true}]
        """)
        try home.write("\(roo)/tasks/019a3c1e/history_item.json", """
        {"id":"019a3c1e","number":1,"ts":\(now - 1_000),"task":"Add an offline queue for login","tokensIn":1,"tokensOut":1,"totalCost":0,"workspace":"/Users/me/app","mode":"code"}
        """)
        let row = try #require(home.rows(.roo).first)
        #expect(row.skill != "pending")
        #expect(row.cwd == "/Users/me/app")
    }

    @Test func aLargeUIMessagesFileIsStillRead() {
        // What the walker hands over for a file past its window: a head and a
        // tail that are not one JSON document.
        let head = #"[{"ts":1,"type":"say","say":"task","text":"Add an offline queue for login"},{"ts":2,"type":"say","say":"text","text":"work"#
        let tail = #"t"},{"ts":9,"type":"ask","ask":"command","text":"npm test","partial":false}]"#
        let facts = NativeActivityHarvest.parseClineUIMessages(head + "\n…\n" + tail, path: "/x/tasks/1/ui_messages.json", taskID: "1")
        #expect(facts.first?.task == "Add an offline queue for login")
        #expect(facts.first?.skill == "pending")
    }

    @Test func clineSDKQueuedIsNotWaiting() throws {
        let home = Home()
        try home.write(".cline/data/sessions/sdk1/sdk1.json", """
        {"version":1,"session_id":"sdk1","source":"cli","pid":1,"started_at":"2026-09-29T10:00:00.000Z","status":"pending","interactive":true,"provider":"anthropic","model":"claude-sonnet-4-5","cwd":"/Users/me/app","prompt":"Add an offline queue for login","messages_path":"x"}
        """)
        let row = try #require(home.rows(.cline).first)
        #expect(row.skill != "pending", "the SDK's `pending` is queued work")
        #expect(row.task == "Add an offline queue for login")
    }

    // MARK: - Grok

    @Test func grokWordsComeFromTheSessionStream() throws {
        let home = Home()
        try home.database(".grok/sessions/session_search.sqlite", [
            "CREATE TABLE session_docs (session_id TEXT PRIMARY KEY, cwd TEXT, updated_at INTEGER, title TEXT, content TEXT, content_hash TEXT);",
            "INSERT INTO session_docs VALUES ('0199a1b2', '/Users/me/app', \(now / 1000 - 3600), 'Offline login queue', 'Add an offline queue for login\n\nThe queue drains on reconnect; 42 tests pass.\n\nRun command npm test', 'h');",
        ])
        try home.write(".grok/sessions/%2FUsers%2Fme%2Fapp/0199a1b2/updates.jsonl", [
            #"{"timestamp":\#(now / 1000 - 3700),"method":"session/update","params":{"sessionId":"0199a1b2","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Add an offline queue for login"}}}}"#,
            #"{"timestamp":\#(now / 1000 - 3650),"method":"session/update","params":{"sessionId":"0199a1b2","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"The queue drains "}}}}"#,
            #"{"timestamp":\#(now / 1000 - 3600),"method":"session/update","params":{"sessionId":"0199a1b2","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"on reconnect; 42 tests pass."}}}}"#,
        ].joined(separator: "\n"))
        let rows = home.rows(.grok)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.lastWord == "The queue drains on reconnect; 42 tests pass.")
        #expect(row.phase != "running", "a tool title from an hour ago is not now")
        #expect(row.cwd == "/Users/me/app")
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

    // MARK: - Continue

    @Test func continueSessionsReadTheIDEWorkspaceAndWords() throws {
        let home = Home()
        try home.write(".continue/sessions/5f0c2b1e.json", """
        {
          "sessionId": "5f0c2b1e",
          "title": "New Session",
          "workspaceDirectory": "file:///Users/me/app",
          "history": [
            {"message": {"role": "user", "content": "Add an offline queue for login"}, "contextItems": []},
            {"message": {"role": "assistant", "content": "The queue drains on reconnect; 42 tests pass."}, "contextItems": []}
          ],
          "mode": "agent",
          "chatModelTitle": "Claude Sonnet 4",
          "usage": {"totalCost": 0.03, "promptTokens": 8100, "completionTokens": 120}
        }
        """)
        try home.write(".continue/sessions/sessions.json", """
        [{"sessionId":"old-1","title":"Something from last spring","dateCreated":"1700000000000","workspaceDirectory":"/Users/me/old","messageCount":4}]
        """)
        let rows = home.rows(.continue_)
        #expect(rows.count == 1, "the index is not a session — and its mtime is not the old session's clock")
        let row = try #require(rows.first)
        #expect(row.task == "Add an offline queue for login")
        #expect(row.lastWord == "The queue drains on reconnect; 42 tests pass.")
        #expect(row.cwd == "/Users/me/app")
        #expect(row.model == "Claude Sonnet 4")
        #expect(AgentID.continue_.waitingSource == .none, "nothing on disk tells an approval from a call in flight")
    }

    // MARK: - OpenHands

    @Test func openHandsConfirmationIsTheVendorsOwnWait() throws {
        let home = Home()
        let conversation = ".openhands/conversations/3f2a9c1e5b7d4e8f9a0b1c2d3e4f5a6b"
        try home.write("\(conversation)/events/event-00001-a1b2.json",
            #"{"id":"a1b2","timestamp":"2026-09-29T10:15:40.123456","source":"user","llm_message":{"role":"user","content":[{"cache_prompt":false,"type":"text","text":"Add an offline queue for login"}],"thinking_blocks":[]},"activated_skills":[],"extended_content":[],"kind":"MessageEvent"}"#)
        try home.write("\(conversation)/events/event-00002-b2c3.json",
            #"{"id":"b2c3","timestamp":"2026-09-29T10:17:02.654321","source":"agent","llm_message":{"role":"assistant","content":[{"cache_prompt":false,"type":"text","text":"Running the test suite next."}],"thinking_blocks":[]},"kind":"MessageEvent"}"#)
        try home.write("\(conversation)/base_state.json",
            #"{"id":"3f2a9c1e-5b7d-4e8f-9a0b-1c2d3e4f5a6b","agent":{"llm":{"model":"anthropic/claude-sonnet-4-5-20250929","kind":"LLM"},"kind":"Agent"},"workspace":{"working_dir":"/Users/me/app","kind":"LocalWorkspace"},"execution_status":"waiting_for_confirmation","confirmation_policy":{"kind":"AlwaysConfirm"}}"#)
        let rows = home.rows(.openhands)
        #expect(rows.count == 1, "one conversation, one row — not one per event file")
        let row = try #require(rows.first)
        #expect(row.task == "Add an offline queue for login")
        #expect(row.lastWord == "Running the test suite next.")
        #expect(row.cwd == "/Users/me/app")
        #expect(row.model == "anthropic/claude-sonnet-4-5-20250929")
        #expect(row.skill == "pending")
    }

    // MARK: - Hooks (invariant)

    @Test func grokCallingClaudesHooksIsGrok() {
        #expect(PulseHookReceiver.attributedAgent("claude", environment: ["GROK_HOOK_EVENT": "Notification"]) == "grok")
        #expect(PulseHookReceiver.attributedAgent("claude", environment: [:]) == "claude")
        #expect(PulseHookReceiver.attributedAgent("codex", environment: ["GROK_SESSION_ID": "x"]) == "codex")
    }

    @Test(arguments: ["agentStop", "preToolUse", "sessionStart", "beforeShellExecution"])
    func anUnknownVendorEventIsNeverRed(event: String) {
        let kind = PulseHookReceiver.parseKind(from: ["hook_event_name": event])
        #expect(!AttentionProtocol.acceptsWrite(kind: kind) || AttentionProtocol.kind(kind)?.isBlocking != true)
    }

    @Test func anUntypedNotificationIsNotAWait() {
        let kind = PulseHookReceiver.parseKind(from: ["hook_event_name": "Notification", "message": "idle for 60s"])
        #expect(!AttentionProtocol.acceptsWrite(kind: kind))
        #expect(PulseHookReceiver.parseKind(from: ["hook_event_name": "Notification", "notification_type": "permission_prompt"]) == "permission_prompt")
        #expect(PulseHookReceiver.parseKind(from: ["hook_event_name": "stop"]) == "stop", "a known alias still normalises")
        #expect(AttentionProtocol.normalizeKind("stop") == AttentionKind.turn.rawValue)
    }
}
