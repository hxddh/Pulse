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
        // This wall measures *parsing*, so it must not also be a stopwatch.
        //
        // With the production 0.75 s per-adapter budget the same binary
        // produced claude=2 and claude=1 in two consecutive runs of the same
        // job: the Claude fixtures include a deliberately oversized 1.4 MB
        // transcript, and on a contended runner ingesting it can consume the
        // slice before the second file is reached. That flake is what made the
        // total read 133 once and 134 later — a number nobody could attribute
        // because it was never stable in the first place.
        //
        // Timing is covered where it belongs: `resource_budget_check.py` caps
        // the whole fixture run, and the explicit timeout scan below proves the
        // per-adapter deadline still isolates a slow adapter. Here, give every
        // adapter room to finish so a failure means a parser changed.
        let result = NativeActivityHarvest.scan(
            allowAppData: false,
            appDataAgents: granted,
            home: home,
            agentDeadlineSeconds: 10,
            totalDeadlineSeconds: 300
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
        for id in expected where !result.rows.contains(where: { $0.id == id }) {
            failures.append("no native row for \(id.rawValue)")
        }
        if result.rows.contains(where: { $0.task.isEmpty && $0.cwd.isEmpty && $0.tool.isEmpty && $0.model.isEmpty && $0.records == 0 }) {
            failures.append("blank structured row escaped admission")
        }

        func require(_ id: AgentID, _ predicate: (ActivityHarvest.Row) -> Bool, _ label: String) {
            guard result.rows.contains(where: { $0.id == id && predicate($0) }) else {
                if result.rows.contains(where: { $0.id == id }) {
                    failures.append("\(id.rawValue) lost \(label)")
                } else {
                    failures.append("missing \(id.rawValue) row for \(label)")
                }
                return
            }
        }
        require(.codex, { $0.task == "Compacted rollout fixture" && $0.tool == "bash" }, "compacted task/action")
        // 20.0 Drift: vendor-shaped stores read for values, not for a row.
        require(
            .gemini,
            { $0.task == "Gemini fixture" && $0.lastWord == "Gemini fixture reply." && $0.cwd == "/tmp/pulse-gemini" },
            "JSONL chat task, last word and project root"
        )
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
        // The transcript is larger than Claude's read window, so the window
        // alone can only produce a floor — and EXPERIENCE forbids presenting a
        // floor as a total. 23.0 removed the session digest that read the
        // middle of the file, so a truncated transcript reports unknown (0).
        if let claudeRow = result.rows.first(where: {
            $0.id == .claude && $0.task == "Fix the tray hero for Claude"
        }), claudeRow.records != 0 {
            failures.append(
                "Claude transcript records \(claudeRow.records), expected unknown (0) for a truncated read"
            )
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

        let openCodeRows = result.rows.filter { $0.id == .opencode }
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

        let denied = NativeActivityHarvest.scan(
            home: home,
            agentDeadlineSeconds: 10,
            totalDeadlineSeconds: 300
        )
        if denied.rows.contains(where: { $0.id == .cursor }) {
            failures.append("protected Cursor rows crossed the denied app-data boundary")
        }
        if denied.health.first(where: { $0.id == .cursor })?.state != .sourceAbsent {
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

        var log = SessionLog()
        var waitingRows: [AgentRow] = []
        for index in 0..<10 {
            var row = AgentRow(rowKey: "codex|waiting-\(index)", agent: .codex)
            row.sessionID = "waiting-\(index)"
            row.task = "Approve fixture \(index)"
            row.state = .blocked(RowWait(kind: "Permission", signal: .hooks))
            waitingRows.append(row)
        }
        log.reconcileWaits(rows: waitingRows, released: [], nowMs: 1_800_000_000_000)
        log.markBaseline()
        for row in waitingRows { log.markNotified(row.rowKey, nowMs: 1_800_000_000_001) }
        let logURL = home.appendingPathComponent("session-log.json")
        SessionLogFile.save(log, to: logURL, nowMs: 1_800_000_000_002)
        let restartedLog = SessionLogFile.load(from: logURL, nowMs: 1_800_000_000_003)
        if !restartedLog.baselineEstablished || restartedLog.waitingKeys.count != 10
            || waitingRows.contains(where: { restartedLog.openWait($0.rowKey)?.notifiedMs == nil }) {
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

        // The wall used to report one integer. When 0.99 moved it from 133 to
        // 134 there was no way to say which adapter changed — a total is not
        // attributable, which is the same defect 0.98 fixed for the collector.
        // Pin the shape instead: every count below is explained, so any future
        // drift names the agent that drifted.
        //
        //   opencode 100  — the concurrency-pressure fixture
        //   claude     2  — the generic fixture plus 0.98's vendor-shaped
        //   codex      2    transcript / rollout / official-JSONL fixtures
        //   pi         2
        //   everyone else 1
        let expectedRows: [String: Int] = [
            "claude": 2, "codex": 2, "copilot": 1, "cursor": 1,
            "gemini": 1, "opencode": 100, "pi": 2,
        ]
        let actualRows = Dictionary(grouping: result.rows, by: { $0.id.rawValue })
            .mapValues(\.count)
        for agent in Set(expectedRows.keys).union(actualRows.keys).sorted() {
            let want = expectedRows[agent] ?? 0
            let got = actualRows[agent] ?? 0
            if want != got {
                failures.append("fixture rows for \(agent): expected \(want), got \(got)")
            }
        }

        if failures.isEmpty {
            print("native fixture PASSED — rows=\(result.rows.count) adapters=\(result.health.count) complete=\(result.complete)")
            // A bare total cannot be compared across releases: when 0.99 moved
            // it by one there was no way to say which adapter changed without
            // another CI round trip. Print the breakdown so the number is an
            // argument rather than a mystery.
            let byAgent = Dictionary(grouping: result.rows, by: { $0.id.rawValue })
                .mapValues(\.count)
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            print("native fixture rows by agent — \(byAgent)")
            return true
        }
        print("native fixture FAILED")
        failures.forEach { print("  · \($0)") }
        return false
    }

    private static func writeGenericFixtures(home: URL) throws {
        let fm = FileManager.default
        // Where each agent's vendor-shaped fixture goes is part of its spec
        // (`HarvestWalk.fixturePath`), so a new agent cannot join the roster
        // without a place on this wall.
        let fixture: [AgentID: String] = Dictionary(
            uniqueKeysWithValues: AgentCatalog.all.compactMap { spec in
                spec.walk.fixturePath.map { (spec.id, $0) }
            }
        )
        let generic = "{\"sessionId\":\"fixture-ID\",\"title\":\"TITLE fixture\",\"cwd\":\"/tmp/pulse-ID\",\"status\":\"running\",\"currentTool\":\"bash\",\"model\":\"fixture-model\",\"inputTokens\":12,\"outputTokens\":3,\"filesChanged\":1,\"contextPercent\":24}"
        for (id, relative) in fixture {
            let url = home.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if id == .codex {
                let codex = """
                {"type":"session_meta","timestamp":"2026-08-03T00:00:00Z","payload":{"id":"fixture-codex","cwd":"/tmp/pulse-codex"}}
                {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Native rollout fixture"}]}}
                {"type":"response_item","payload":{"type":"function_call","name":"bash","arguments":"{}"}}
                {"type":"event_msg","payload":{"type":"task_complete"}}
                {"type":"compacted","payload":{"replacement_history":[{"type":"message","role":"user","content":[{"type":"input_text","text":"Compacted rollout fixture"}]}]}}
                """
                try codex.write(to: url, atomically: true, encoding: .utf8)
            } else if id == .gemini {
                // 20.0: what Gemini CLI writes (chatRecordingService.ts):
                // metadata, `type: user` with a part list, `type: gemini`
                // with a plain string, `$set` patches.
                let gemini = """
                {"sessionId":"gemini-fixture","projectHash":"f1","startTime":"2026-08-03T00:00:00.000Z","lastUpdated":"2026-08-03T00:00:00.000Z"}
                {"id":"u1","timestamp":"2026-08-03T00:00:01.000Z","type":"user","content":[{"text":"Gemini fixture"}]}
                {"$set":{"lastUpdated":"2026-08-03T00:00:01.001Z"}}
                {"id":"g1","timestamp":"2026-08-03T00:00:09.000Z","type":"gemini","content":"Gemini fixture reply.","thoughts":[],"model":"gemini-fixture"}
                {"$set":{"lastUpdated":"2026-08-03T00:00:09.001Z"}}
                """
                try gemini.write(to: url, atomically: true, encoding: .utf8)
                let marker = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".project_root")
                try fm.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "/tmp/pulse-gemini\n".write(to: marker, atomically: true, encoding: .utf8)
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
