import Foundation
import SQLite3

/// Headless native-collector verification for machines that only have the
/// Command Line Tools (and therefore cannot import XCTest). The packaged
/// selftest remains resource-focused; this opt-in fixture mode exercises the
/// same Swift scanner against every declared source family without touching a
/// user's home directory.
enum NativeHarvestSelfTest {
    static func run() -> Bool {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(
            "pulse-native-fixtures-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fm.removeItem(at: home) }

        do {
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
            try writeGenericFixtures(home: home)
            try writeClaudeTranscriptFixture(home: home)
            try writeCodexEventFixture(home: home)
            try writeOfficialPiFixture(home: home)
            try writeCorruptJSONFixture(home: home)
            try writeCursorFixture(home: home)
            try writeOpenCodeFixture(home: home)
            try writePiFixture(home: home)
            try writeGrokFixture(home: home)
            try writeWarpFixture(home: home)
        } catch {
            print("native fixture FAILED: \(error.localizedDescription)")
            return false
        }

        // Hold one vendor database under an exclusive transaction while the
        // scanner runs. A locked source must be reported as a retryable
        // failure, never as "no sessions" that clears the other valid rows.
        let lockedDatabase: OpaquePointer?
        do {
            lockedDatabase = try lockOpenCodeFixture(home: home)
        } catch {
            print("native fixture FAILED: \(error.localizedDescription)")
            return false
        }
        defer {
            if let lockedDatabase {
                sqlite3_exec(lockedDatabase, "ROLLBACK", nil, nil, nil)
                sqlite3_close(lockedDatabase)
            }
        }

        let granted = Set(AgentID.allCases.filter(\.requiresAppDataOptIn))
        let result = NativeActivityHarvest.scan(
            allowAppData: false,
            appDataAgents: granted,
            home: home
        )
        let expected = ActivityHarvest.expectedCollectorIDs
        let healthIDs = Set(result.health.map(\.id))
        var failures: [String] = []
        if healthIDs != expected {
            failures.append("health ids \(healthIDs.subtracting(expected)) / missing \(expected.subtracting(healthIDs))")
        }
        if result.health.contains(where: { $0.state == .unscanned }) {
            failures.append("fixture scan emitted unscanned adapters")
        }
        for id in expected {
            // Cascade claims shared ~/.windsurf roots; Windsurf shell rows are
            // suppressed when Cascade observed anything (legacy cascade_block).
            if id == .windsurf, result.rows.contains(where: { $0.id == .cascade }) {
                continue
            }
            if !result.rows.contains(where: { $0.id.surfaceID == id }) {
                failures.append("no native row for \(id.rawValue)")
            }
        }
        if result.rows.contains(where: { $0.id == .cascade }),
           result.rows.contains(where: { $0.id == .windsurf }) {
            failures.append("Cascade and Windsurf both raised from shared roots")
        }
        if result.rows.contains(where: { $0.task.isEmpty && $0.cwd.isEmpty && $0.tool.isEmpty && $0.model.isEmpty && $0.records == 0 }) {
            failures.append("blank structured row escaped admission")
        }

        func require(_ id: AgentID, _ predicate: (ActivityHarvest.Row) -> Bool, _ label: String) {
            guard result.rows.contains(where: { $0.id.surfaceID == id && predicate($0) }) else {
                if result.rows.contains(where: { $0.id.surfaceID == id }) {
                    failures.append("\(id.rawValue) lost \(label)")
                } else {
                    failures.append("missing \(id.rawValue) row for \(label)")
                }
                return
            }
        }
        require(.codex, { $0.task == "Compacted rollout fixture" && $0.tool == "bash" }, "compacted task/action")

        // Flagship hero fidelity. Everything below asserts the *value* of the
        // tray hero against a vendor-shaped file, not merely that a row
        // exists. The generic `{"title": …}` fixtures could not tell a correct
        // hero from a wrong one, which is how 0.96.1 through 0.97.2 each
        // shipped green with the tray still showing the wrong line.
        require(
            .claude,
            { $0.task == "Fix the tray hero for Claude" && $0.cwd == "/Users/me/PulseFixture" },
            "user goal under a long tool_result tail"
        )
        // The transcript is larger than Claude's read window, so any newline
        // count taken from it is a floor. EXPERIENCE forbids estimating, so
        // the row must say unknown rather than an authoritative undercount.
        if let claudeRow = result.rows.first(where: {
            $0.id == .claude && $0.task == "Fix the tray hero for Claude"
        }), claudeRow.records != 0 {
            failures.append("truncated Claude window reported \(claudeRow.records) records as exact")
        }
        require(
            .codex,
            { $0.task == "Ship the Codex event_msg hero" },
            "event_msg user text as hero"
        )
        require(
            .pi,
            { $0.task == "Refactor the auth module" && $0.cwd == "/Users/me/PiFixture" },
            "official JSONL /name over the first user turn"
        )
        require(.cursor, { $0.task == "Cursor fixture" && $0.cwd == "/tmp/pulse-cursor" }, "composer workspace")
        if result.health.first(where: { $0.id == .cursor })?.state != .observed {
            failures.append("Cursor Composer source was downgraded when optional cloud table is absent")
        }
        require(.opencode, { $0.model == "fixture-model" && $0.tool == "bash" && $0.tokensIn == 1200 }, "database facts")
        require(.pi, { $0.tool == "bash" && $0.tokensIn == 120 }, "context-mode facts")
        require(.grok, { $0.task == "Grok fixture" && $0.records > 0 }, "session index facts")
        require(.warpAgent, { $0.task == "Warp fixture" && $0.model == "warp-model" }, "Warp database facts")
        require(.amp, { $0.task == "Amp fixture" && $0.records == 0 }, "prompt-log record semantics")

        let openCodeRows = result.rows.filter { $0.id.surfaceID == .opencode }
        if openCodeRows.count < 100 {
            failures.append("100-session pressure retained only \(openCodeRows.count) OpenCode rows")
        }
        if openCodeRows.count > 500 {
            failures.append("OpenCode row cap exceeded: \(openCodeRows.count)")
        }
        if let opencodeHealth = result.health.first(where: { $0.id == .opencode }),
           opencodeHealth.state != .failed || opencodeHealth.rowCount == 0 {
            failures.append("locked OpenCode source was not isolated: \(String(describing: opencodeHealth))")
        }
        if let claudeHealth = result.health.first(where: { $0.id == .claude }),
           claudeHealth.state != .failed || claudeHealth.rowCount == 0 {
            failures.append("corrupt JSON did not remain isolated beside valid Claude rows: \(String(describing: claudeHealth))")
        }

        let denied = NativeActivityHarvest.scan(home: home)
        if denied.rows.contains(where: { $0.id.surfaceID == .cursor || $0.id.surfaceID == .warpAgent }) {
            failures.append("protected Cursor/Warp rows crossed the denied app-data boundary")
        }
        if denied.health.first(where: { $0.id == .cursor })?.state != .sourceAbsent
            || denied.health.first(where: { $0.id == .warpAgent })?.state != .sourceAbsent {
            failures.append("denied protected stores did not report source_absent")
        }

        let timeout = NativeActivityHarvest.scan(
            home: home,
            agentDeadlineSeconds: 0.000001,
            totalDeadlineSeconds: 1.0
        )
        if timeout.complete || !timeout.health.contains(where: {
            $0.state == .failed && $0.errorKind == "native_timeout"
        }) {
            failures.append("per-agent timeout did not produce an isolated partial health result")
        }

        if RuntimeResolver.python3(environment: [
            "PULSE_PYTHON": "/no/such/python3",
            "PATH": "/no/such/bin",
        ], includeFallbacks: false) != nil {
            failures.append("missing optional helper was not detected")
        }

        var ledger = AttentionLedger()
        var waitingRows: [AgentRow] = []
        for index in 0..<10 {
            var row = AgentRow(rowKey: "codex|waiting-\(index)", agent: .codex)
            row.sessionID = "waiting-\(index)"
            row.task = "Approve fixture \(index)"
            row.waiting = true
            row.waitKind = "Permission"
            waitingRows.append(row)
        }
        ledger.reconcile(activeRows: waitingRows, nowMs: 1_800_000_000_000)
        ledger.markBaseline()
        for row in waitingRows { ledger.markNotified(rowKey: row.rowKey, nowMs: 1_800_000_000_001) }
        let ledgerURL = home.appendingPathComponent("attention-ledger.json")
        ledger.save(to: ledgerURL)
        let restartedLedger = AttentionLedger.load(from: ledgerURL)
        if !restartedLedger.baselineEstablished || restartedLedger.activeKeys.count != 10
            || restartedLedger.events.contains(where: { $0.notifiedAtMs == 0 }) {
            failures.append("10 concurrent Waiting events did not survive atomic restart recovery")
        }

        let asleep = ProbeSchedule.Power(displayAsleep: true, screenLocked: false, lowPowerMode: false)
        if ProbeSchedule.interval(activity: .running, power: asleep, trayOpen: false) != nil
            || ProbeSchedule.interval(activity: .running, power: .init(), trayOpen: false) == nil {
            failures.append("sleep/wake probe scheduling did not park and resume")
        }

        // A native run must retain a bounded set rather than letting a large
        // rollout directory grow the tray model without limit.
        let codexRows = result.rows.filter { $0.id == .codex }
        if codexRows.count > 500 { failures.append("Codex row cap exceeded: \(codexRows.count)") }

        if failures.isEmpty {
            print("native fixture PASSED — rows=\(result.rows.count) adapters=\(result.health.count) complete=\(result.complete)")
            return true
        }
        print("native fixture FAILED")
        failures.forEach { print("  · \($0)") }
        return false
    }

    private static func writeGenericFixtures(home: URL) throws {
        let fm = FileManager.default
        let fixture: [AgentID: String] = [
            .claude: ".claude/projects/fixture.jsonl",
            .codex: ".codex/sessions/fixture/rollout-fixture.jsonl",
            .amp: ".local/share/amp/history.jsonl",
            .aider: ".aider/session.json",
            .gemini: ".gemini/tmp/fixture/chats/session-fixture.jsonl",
            .copilot: ".copilot/session.json",
            .goose: ".config/goose/session.json",
            .openhands: ".openhands/session.json",
            .continue_: ".continue/session.json",
            .droid: ".factory/session.jsonl",
            .commandCode: ".commandcode/session.jsonl",
            .kimi: ".kimi-code/session.jsonl",
            .amazonQ: ".aws/amazonq/session.json",
            .cline: "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/session.json",
            .roo: "Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/session.json",
            .cascade: ".codeium/session.json",
            .windsurf: ".windsurf/session.json",
            .augment: ".augment/session.json",
            .zedAgent: ".zed/session.json",
            .trae: "Library/Application Support/Trae/session.json",
            .devin: ".devin/session.json",
            .kiro: ".kiro/session.json",
            .junie: ".junie/session.json",
            .kilo: "Library/Application Support/Code/User/globalStorage/kilocode.kilo-code/session.json",
            .replit: ".replit/session.json",
            .antigravity: "Library/Application Support/Antigravity/User/globalStorage/session.json",
            .zcode: ".zcode/sessions/session.json",
        ]
        let generic = "{\"sessionId\":\"fixture-ID\",\"title\":\"TITLE fixture\",\"cwd\":\"/tmp/pulse-ID\",\"status\":\"running\",\"currentTool\":\"bash\",\"model\":\"fixture-model\",\"inputTokens\":12,\"outputTokens\":3,\"filesChanged\":1,\"contextPercent\":24}"
        for (id, relative) in fixture {
            let url = home.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if id == .amp {
                let amp = """
                {"text":"Amp fixture","cwd":"/tmp/pulse-amp"}
                {"text":"continue","cwd":"/tmp/pulse-amp"}
                """
                try amp.write(to: url, atomically: true, encoding: .utf8)
            } else if id == .codex {
                let codex = """
                {"type":"session_meta","timestamp":"2026-08-03T00:00:00Z","payload":{"id":"fixture-codex","cwd":"/tmp/pulse-codex"}}
                {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Native rollout fixture"}]}}
                {"type":"response_item","payload":{"type":"function_call","name":"bash","arguments":"{}"}}
                {"type":"event_msg","payload":{"type":"task_complete"}}
                {"type":"compacted","payload":{"replacement_history":[{"type":"message","role":"user","content":[{"type":"input_text","text":"Compacted rollout fixture"}]}]}}
                """
                try codex.write(to: url, atomically: true, encoding: .utf8)
            } else if id == .gemini {
                try #"{"type":"user","message":{"role":"user","content":"Gemini fixture"},"model":"gemini-fixture","status":"success"}"#.write(to: url, atomically: true, encoding: .utf8)
                let marker = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".project_root")
                try fm.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "/tmp/pulse-gemini\n".write(to: marker, atomically: true, encoding: .utf8)
            } else if id == .claude || id == .commandCode || id == .droid || id == .kimi {
                try (generic.replacingOccurrences(of: "ID", with: id.rawValue)
                    .replacingOccurrences(of: "TITLE", with: id.displayName))
                    .write(to: url, atomically: true, encoding: .utf8)
            } else {
                try (generic.replacingOccurrences(of: "ID", with: id.rawValue)
                    .replacingOccurrences(of: "TITLE", with: id.displayName))
                    .write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func writeCursorFixture(home: URL) throws {
        let fm = FileManager.default
        let user = home.appendingPathComponent("Library/Application Support/Cursor/User", isDirectory: true)
        let dbURL = user.appendingPathComponent("globalStorage/state.vscdb")
        let workspace = user.appendingPathComponent("workspaceStorage/ws-1/workspace.json")
        try fm.createDirectory(at: workspace.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"folder":"/tmp/pulse-cursor"}"#.write(to: workspace, atomically: true, encoding: .utf8)
        let db = try open(dbURL)
        defer { sqlite3_close(db) }
        try exec(db, "CREATE TABLE composerHeaders (composerId TEXT, workspaceId TEXT, lastUpdatedAt INTEGER, value TEXT, isArchived INTEGER, isSubagent INTEGER);")
        let value = #"{"name":"Cursor fixture","currentTool":"bash","contextUsagePercent":42}"#
        try exec(db, "INSERT INTO composerHeaders VALUES ('cursor-fixture', 'ws-1', 1785715200000, '\(sql(value))', 0, 0);")
    }

    /// A Claude transcript in the shape Claude Code actually writes: an
    /// encoded project directory, a `role=user` goal, an assistant `tool_use`,
    /// and then a long tail of `role=user` **tool_result** envelopes. That tail
    /// is the production failure — it is what made the tray hero a tool dump,
    /// and it is deliberately larger than the read window so the truncation
    /// path is exercised too.
    private static func writeClaudeTranscriptFixture(home: URL) throws {
        let fm = FileManager.default
        let url = home.appendingPathComponent(
            ".claude/projects/-Users-me-PulseFixture/transcript.jsonl"
        )
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lines = [
            #"{"type":"user","sessionId":"claude-transcript","cwd":"/Users/me/PulseFixture","message":{"role":"user","content":"Fix the tray hero for Claude"}}"#,
            #"{"type":"assistant","sessionId":"claude-transcript","message":{"role":"assistant","model":"claude-fixture-model","usage":{"input_tokens":120,"output_tokens":34},"content":[{"type":"tool_use","name":"Bash","input":{"command":"swift test","path":"/Users/me/PulseFixture/Sources/Thing.swift"}}]}}"#,
        ]
        // ~1.4 MB of tool_result envelopes: past Claude's 1 MB window.
        let filler = String(repeating: "tool output line; ", count: 90)
        for index in 0..<800 {
            lines.append(
                #"{"type":"user","sessionId":"claude-transcript","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t\#(index)","content":"\#(filler)"}]}}"#
            )
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Codex writes the user's own words as an `event_msg` / `user_message`
    /// payload, sometimes wrapped in the Desktop request envelope. A rollout
    /// whose only user text lives there must still produce that hero.
    private static func writeCodexEventFixture(home: URL) throws {
        let fm = FileManager.default
        let url = home.appendingPathComponent(
            ".codex/sessions/event/rollout-event.jsonl"
        )
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = [
            #"{"type":"session_meta","timestamp":"2026-08-03T00:00:00Z","payload":{"id":"codex-event","cwd":"/Users/me/CodexFixture"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Ship the Codex event_msg hero"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"continue"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{}"}}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Pi's official on-disk layout: `--<encoded cwd>--/<timestamp>_<uuid>.jsonl`
    /// with a `session` header, string `content` user turns and a
    /// `session_info` name. `/name` is the `/resume` title and must outrank the
    /// first user turn — the ranking that replaced the old "longer wins" merge.
    private static func writeOfficialPiFixture(home: URL) throws {
        let fm = FileManager.default
        let url = home.appendingPathComponent(
            ".pi/agent/sessions/--Users-me-PiFixture--/2026-08-03T00-00-01-000Z_pi-official.jsonl"
        )
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = [
            #"{"type":"session","version":3,"id":"pi-official","timestamp":"2026-08-03T00:00:00.000Z","cwd":"/Users/me/PiFixture"}"#,
            #"{"type":"message","timestamp":"2026-08-03T00:00:01.000Z","message":{"role":"user","content":"first prompt that must lose to /name"}}"#,
            #"{"type":"message","timestamp":"2026-08-03T00:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"working"}]}}"#,
            #"{"type":"session_info","timestamp":"2026-08-03T00:00:03.000Z","name":"Refactor the auth module"}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writeCorruptJSONFixture(home: URL) throws {
        let url = home.appendingPathComponent(".claude/projects/corrupt.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{\"oops\": ".write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writeOpenCodeFixture(home: URL) throws {
        let url = home.appendingPathComponent(".local/share/opencode/opencode.db")
        let db = try open(url)
        defer { sqlite3_close(db) }
        try exec(db, "CREATE TABLE session (id TEXT PRIMARY KEY, title TEXT, directory TEXT, agent TEXT, model TEXT, tokens_input INTEGER, tokens_output INTEGER, time_created INTEGER, time_updated INTEGER, summary_files INTEGER, time_archived INTEGER);")
        try exec(db, "CREATE TABLE part (session_id TEXT, data TEXT, time_updated INTEGER);")
        try exec(db, "CREATE TABLE permission (time_updated INTEGER);")
        for index in 0..<100 {
            let sid = index == 0 ? "opencode-fixture" : "opencode-pressure-\(index)"
            let title = index == 0 ? "OpenCode fixture" : "OpenCode pressure \(index)"
            let input = index == 0 ? 1200 : 100 + index
            let output = index == 0 ? 300 : 40 + index
            try exec(db, "INSERT INTO session VALUES ('\(sid)', '\(sql(title))', '/tmp/pulse-opencode', 'build', '{\"id\":\"fixture-model\"}', \(input), \(output), 1785715200000, \(1785715201000 + index), 2, NULL);")
            let part = #"{"type":"tool","tool":"bash","state":{"status":"completed"}}"#
            try exec(db, "INSERT INTO part VALUES ('\(sid)', '\(sql(part))', \(1785715201000 + index));")
        }
    }

    private static func lockOpenCodeFixture(home: URL) throws -> OpaquePointer {
        let url = home.appendingPathComponent(".local/share/opencode/opencode-locked.db")
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "NativeHarvestSelfTest", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "cannot create locked SQLite fixture",
            ])
        }
        do {
            try exec(database, "CREATE TABLE session (id TEXT, title TEXT, directory TEXT, agent TEXT, model TEXT, tokens_input INTEGER, tokens_output INTEGER, time_created INTEGER, time_updated INTEGER, summary_files INTEGER, time_archived INTEGER);")
            try exec(database, "INSERT INTO session VALUES ('locked', 'Locked source', '/tmp/pulse-opencode', 'build', '{}', 1, 1, 1785715200000, 1785715201000, 0, NULL);")
            guard sqlite3_exec(database, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "NativeHarvestSelfTest", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "cannot lock SQLite fixture",
                ])
            }
            return database
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    private static func writePiFixture(home: URL) throws {
        let url = home.appendingPathComponent(".pi/context-mode/sessions/fixture.db")
        let db = try open(url)
        defer { sqlite3_close(db) }
        try exec(db, "CREATE TABLE session_meta (session_id TEXT PRIMARY KEY, project_dir TEXT, started_at TEXT, last_event_at TEXT, event_count INTEGER, compact_count INTEGER);")
        try exec(db, "CREATE TABLE session_events (id INTEGER PRIMARY KEY, session_id TEXT, type TEXT, category TEXT, data TEXT, project_dir TEXT, created_at TEXT, bytes_returned INTEGER);")
        try exec(db, "INSERT INTO session_meta VALUES ('pi-fixture', '/tmp/pulse-pi', '2026-08-03 00:00:00.000', '2026-08-03 00:01:00.000', 2, 0);")
        try exec(db, "INSERT INTO session_events VALUES (1, 'pi-fixture', 'intent', '', 'Native Pi fixture', '/tmp/pulse-pi', '2026-08-03 00:00:01.000', 12);")
        try exec(db, "INSERT INTO session_events VALUES (2, 'pi-fixture', 'tool_call', 'bash', '{\"tool\":\"bash\"}', '/tmp/pulse-pi', '2026-08-03 00:01:00.000', 24);")
        try exec(db, "INSERT INTO session_events VALUES (3, 'pi-fixture', 'agent_usage', '', 'tokens_in: 120 tokens_out: 40', '/tmp/pulse-pi', '2026-08-03 00:01:00.000', 24);")
    }

    private static func writeGrokFixture(home: URL) throws {
        let url = home.appendingPathComponent(".grok/sessions/session_search.sqlite")
        let db = try open(url)
        defer { sqlite3_close(db) }
        try exec(db, "CREATE TABLE session_docs (session_id TEXT, cwd TEXT, updated_at INTEGER, title TEXT, content TEXT);")
        try exec(db, "INSERT INTO session_docs VALUES ('grok-fixture', '/tmp/pulse-grok', 1785715200000, 'Grok fixture', 'tool bash completed');")
    }

    private static func writeWarpFixture(home: URL) throws {
        let url = home.appendingPathComponent("Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite")
        let db = try open(url)
        defer { sqlite3_close(db) }
        try exec(db, "CREATE TABLE agent_conversations (conversation_id TEXT PRIMARY KEY, conversation_data TEXT, last_modified_at TEXT, summary TEXT);")
        try exec(db, "CREATE TABLE ai_queries (conversation_id TEXT, start_ts TEXT, working_directory TEXT, output_status TEXT, model_id TEXT, input TEXT);")
        try exec(db, "CREATE TABLE agent_tasks (conversation_id TEXT);")
        try exec(db, "INSERT INTO agent_conversations VALUES ('warp-fixture', '{}', '2026-08-03 00:01:00', '{\"title\":\"Warp fixture\",\"initial_working_directory\":\"/tmp/pulse-warp\"}');")
        try exec(db, "INSERT INTO ai_queries VALUES ('warp-fixture', '2026-08-03 00:01:00', '/tmp/pulse-warp', 'completed', 'warp-model', '{\"text\":\"Build Warp fixture\",\"tool\":\"bash\"}');")
        try exec(db, "INSERT INTO agent_tasks VALUES ('warp-fixture');")
    }

    private static func open(_ url: URL) throws -> OpaquePointer {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "NativeHarvestSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot create SQLite fixture"])
        }
        return db
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let message = sqlite3_errmsg(db).map(String.init(cString:)) ?? "sqlite error"
            throw NSError(domain: "NativeHarvestSelfTest", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private static func sql(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "''")
    }
}
