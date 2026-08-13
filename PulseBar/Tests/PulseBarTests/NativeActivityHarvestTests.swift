import XCTest
import SQLite3
@testable import PulseBar

final class NativeActivityHarvestTests: XCTestCase {
    func testNativeCollectorProducesUsefulFactsAndCompleteHealthWithoutPython() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-\(UUID().uuidString)")
        let session = home
            .appendingPathComponent(".codex/sessions/2026/08/03", isDirectory: true)
            .appendingPathComponent("rollout-native.jsonl")
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let lines = [
            #"{"session_id":"native-123","cwd":"/Users/me/Pulse","task":"Run the native harvest","model":"gpt-5","status":"testing","lastAction":"swift_test","inputTokens":120,"outputTokens":34,"progressDone":3,"progressTotal":5}"#,
            #"{"session_id":"native-123","cwd":"/Users/me/Pulse","status":"testing","filesChanged":2}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home)
        XCTAssertTrue(result.complete)
        XCTAssertEqual(Set(result.health.map(\.id)), ActivityHarvest.expectedCollectorIDs)
        let row = try XCTUnwrap(result.rows.first { $0.id == .codex })
        XCTAssertEqual(row.task, "Run the native harvest")
        XCTAssertEqual(row.cwd, "/Users/me/Pulse")
        XCTAssertEqual(row.tool, "swift_test")
        XCTAssertEqual(row.tokensIn, 120)
        XCTAssertEqual(row.progressTotal, 5)
        XCTAssertEqual(row.evidence, .session)
    }

    func testProtectedRootsRemainSkippedUntilScopedAccessIsSelected() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-private-\(UUID().uuidString)")
        let session = home
            .appendingPathComponent("Library/Application Support/Cursor/User", isDirectory: true)
            .appendingPathComponent("session.json")
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"{"sessionId":"cursor-1","title":"Private Cursor work","cwd":"/Users/me/Client"}"#
            .write(to: session, atomically: true, encoding: .utf8)

        let denied = NativeActivityHarvest.scan(home: home)
        XCTAssertFalse(denied.rows.contains { $0.id == .cursor })

        let allowed = NativeActivityHarvest.scan(
            allowAppData: false,
            appDataAgents: [.cursor],
            home: home
        )
        XCTAssertTrue(allowed.rows.contains { $0.id == .cursor })
    }

    func testCursorComposerDatabaseIsReadNatively() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-cursor-\(UUID().uuidString)")
        let user = home.appendingPathComponent("Library/Application Support/Cursor/User", isDirectory: true)
        let dbURL = user.appendingPathComponent("globalStorage/state.vscdb")
        let workspace = user.appendingPathComponent("workspaceStorage/ws-1/workspace.json")
        try fm.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: workspace.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"{"folder":"/Users/me/Client"}"#.write(to: workspace, atomically: true, encoding: .utf8)

        var database: OpaquePointer?
        guard sqlite3_open(dbURL.path, &database) == SQLITE_OK, let database else {
            XCTFail("could not create Cursor fixture database")
            return
        }
        defer { sqlite3_close(database) }
        let schema = "CREATE TABLE composerHeaders (composerId TEXT, workspaceId TEXT, lastUpdatedAt INTEGER, value TEXT, isArchived INTEGER, isSubagent INTEGER);"
        XCTAssertEqual(sqlite3_exec(database, schema, nil, nil, nil), SQLITE_OK)
        let value = #"{"name":"Refine Cursor adapter","unifiedMode":"agent","contextUsagePercent":42,"filesChangedCount":3,"hasBlockingPendingActions":true}"#
        let insert = "INSERT INTO composerHeaders VALUES ('composer-1', 'ws-1', 1700000000000, '\(value.replacingOccurrences(of: "'", with: "''"))', 0, 0);"
        XCTAssertEqual(sqlite3_exec(database, insert, nil, nil, nil), SQLITE_OK)

        let result = NativeActivityHarvest.scan(
            allowAppData: false,
            appDataAgents: [.cursor],
            home: home
        )
        XCTAssertEqual(
            result.health.first(where: { $0.id == .cursor })?.state,
            .observed,
            "Cursor Composer data remains healthy when an older build has no optional cloud table"
        )
        let row = try XCTUnwrap(result.rows.first { $0.id == .cursor })
        XCTAssertEqual(row.task, "Refine Cursor adapter")
        XCTAssertEqual(row.cwd, "/Users/me/Client")
        XCTAssertEqual(row.contextPercent, 42)
        XCTAssertEqual(row.files, 3)
        XCTAssertEqual(row.skill, "pending")
        XCTAssertEqual(row.mode, "agent", "unifiedMode must reach the tray, not invent local")
    }

    func testCorruptStoreDoesNotHideOtherAdapterAndFilterIsIsolated() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-corrupt-\(UUID().uuidString)")
        let codex = home.appendingPathComponent(".codex/sessions/2026/08/03/ok.jsonl")
        let amp = home.appendingPathComponent(".amp/threads/bad.json")
        try fm.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: amp.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"{"session_id":"ok","cwd":"/Users/me/Pulse","title":"Codex survives"}"#.write(to: codex, atomically: true, encoding: .utf8)
        try "{not-json".write(to: amp, atomically: true, encoding: .utf8)
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.codex, .amp])
        XCTAssertTrue(result.rows.contains { $0.id == .codex })
        XCTAssertTrue(result.health.contains { $0.id == .amp })
        XCTAssertTrue(result.health.contains { $0.id == .codex })
    }

    func testClaudeToolUseAndEncodedProjectDirBecomeUsefulRowFacts() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-claude-\(UUID().uuidString)")
        let session = home
            .appendingPathComponent(".claude/projects/-Users-me-code-Pulse", isDirectory: true)
            .appendingPathComponent("sess-claude.jsonl")
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let lines = [
            #"{"type":"user","message":{"role":"user","content":"Fix the tray density"},"sessionId":"sess-claude"}"#,
            #"{"type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4","usage":{"input_tokens":1200,"output_tokens":340},"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4","usage":{"input_tokens":1500,"output_tokens":80},"content":[{"type":"tool_use","name":"Edit","input":{"file":"PulseApp.swift"}}]}}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.claude])
        let row = try XCTUnwrap(result.rows.first { $0.id == .claude })
        XCTAssertEqual(row.task, "Fix the tray density")
        XCTAssertEqual(row.cwd, "/Users/me/code/Pulse")
        XCTAssertEqual(row.project, "Pulse")
        XCTAssertEqual(row.tool, "Edit", "latest tool_use must win, not the first")
        XCTAssertEqual(row.model, "claude-sonnet-4")
        XCTAssertEqual(row.tokensIn, 1500)
        XCTAssertEqual(row.tokensOut, 80)
    }

    func testCodexLastTokenUsageBecomesTrayTokens() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-codex-tokens-\(UUID().uuidString)")
        let session = home
            .appendingPathComponent(".codex/sessions/2026/08/03", isDirectory: true)
            .appendingPathComponent("rollout-tokens.jsonl")
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let lines = [
            #"{"type":"session_meta","payload":{"session_id":"tok-1","cwd":"/Users/me/Pulse"},"timestamp":1700000000}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Count the tokens"}]},"timestamp":1700000001}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":220,"output_tokens":55}}},"timestamp":1700000002}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.codex])
        let row = try XCTUnwrap(result.rows.first { $0.id == .codex })
        XCTAssertEqual(row.task, "Count the tokens")
        XCTAssertEqual(row.tokensIn, 220)
        XCTAssertEqual(row.tokensOut, 55)
    }

    func testClaudeSubagentDirectoryCountsAttachToSessionRow() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-claude-sub-\(UUID().uuidString)")
        let session = home
            .appendingPathComponent(".claude/projects/-Users-me-code-Pulse", isDirectory: true)
            .appendingPathComponent("sess-sub.jsonl")
        let subDir = session
            .deletingLastPathComponent()
            .appendingPathComponent("sess-sub/subagents", isDirectory: true)
        try fm.createDirectory(at: subDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        try #"{"type":"user","message":{"role":"user","content":"Spin up helpers"},"sessionId":"sess-sub"}"#
            .write(to: session, atomically: true, encoding: .utf8)
        let fresh = subDir.appendingPathComponent("agent-alpha.jsonl")
        let stale = subDir.appendingPathComponent("agent-beta.jsonl")
        try " {}\n".write(to: fresh, atomically: true, encoding: .utf8)
        try " {}\n".write(to: stale, atomically: true, encoding: .utf8)
        let old = Date(timeIntervalSince1970: Date().timeIntervalSince1970 - 600)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: stale.path)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.claude])
        let row = try XCTUnwrap(result.rows.first { $0.id == .claude })
        XCTAssertEqual(row.subTotal, 2)
        XCTAssertEqual(row.subRunning, 1, "only mtime ≤ 120s counts as running")
        XCTAssertEqual(row.task, "Spin up helpers")
    }

    func testCodexUntypedTitleIsNotPromotedToTask() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-codex-title-\(UUID().uuidString)")
        let session = home
            .appendingPathComponent(".codex/sessions/2026/08/03", isDirectory: true)
            .appendingPathComponent("rollout-tool-title.jsonl")
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        // Untyped head lines often carry plan/registry `title` values — those
        // must not become the tray hero. Real prompts use task/prompt keys.
        let lines = [
            #"{"session_id":"title-1","cwd":"/Users/me/Pulse","title":"update_plan step label","lastAction":"Bash"}"#,
            #"{"session_id":"title-1","cwd":"/Users/me/Pulse","model":"gpt-5"}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.codex])
        let row = try XCTUnwrap(result.rows.first { $0.id == .codex })
        XCTAssertEqual(row.cwd, "/Users/me/Pulse")
        XCTAssertEqual(row.tool, "Bash")
        XCTAssertTrue(row.task.isEmpty, "tool-arg / registry title must not become task")
    }

    func testAmpHistoryFixtureYieldsGoalAndCwd() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-amp-\(UUID().uuidString)")
        let history = home.appendingPathComponent(".local/share/amp/history.jsonl")
        try fm.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let lines = [
            #"{"text":"Ship fleet continuity","cwd":"/Users/me/Pulse"}"#,
            #"{"text":"continue","cwd":"/Users/me/Pulse"}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: history, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.amp])
        let row = try XCTUnwrap(result.rows.first { $0.id == .amp })
        XCTAssertEqual(row.task, "Ship fleet continuity")
        XCTAssertEqual(row.cwd, "/Users/me/Pulse")
        XCTAssertEqual(row.evidence, .session)
    }

    func testBestEffortCacheNeverClaimsSessionEvidence() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-cache-\(UUID().uuidString)")
        let windsurf = home.appendingPathComponent(".windsurf/session.json")
        let cline = home.appendingPathComponent(
            "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/session.json"
        )
        try fm.createDirectory(at: windsurf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: cline.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        // Thin index: title + model only — still cache, never structured session.
        try #"{"sessionId":"ws-1","title":"Windsurf thin","model":"cascade","status":"running"}"#
            .write(to: windsurf, atomically: true, encoding: .utf8)
        try #"{"sessionId":"cl-1","title":"Cline thin","cwd":"/tmp/cline","status":"running"}"#
            .write(to: cline, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(
            allowAppData: false,
            appDataAgents: [.cline],
            home: home,
            agentFilter: [.windsurf, .cline]
        )
        let wind = try XCTUnwrap(result.rows.first { $0.id == .windsurf })
        XCTAssertEqual(AgentID.windsurf.harvestSource, .bestEffortCache)
        XCTAssertEqual(wind.evidence, .cache, "cache adapters must not stamp session evidence")
        XCTAssertEqual(wind.task, "Windsurf thin")

        let clineRow = try XCTUnwrap(result.rows.first { $0.id == .cline })
        XCTAssertEqual(clineRow.evidence, .cache)
        XCTAssertEqual(clineRow.cwd, "/tmp/cline")

        var agentRow = AgentRow(rowKey: "windsurf|ws-1", agent: .windsurf)
        agentRow.task = wind.task
        agentRow.cwd = wind.cwd
        agentRow.tool = wind.tool
        agentRow.model = wind.model
        agentRow.observationSource = wind.evidence
        agentRow.harvestMs = wind.harvestMs
        agentRow.refreshObservationQuality()
        XCTAssertTrue(agentRow.quality.isLimited, "thin cache must stay Limited")
        XCTAssertEqual(agentRow.quality.confidence, .low)
        XCTAssertTrue(agentRow.quality.missing.contains(where: { $0.reason == "cache_thin" }))
    }

    func testRichWindsurfCacheExtractsGoalWorkspaceToolStillCacheEvidence() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-rich-cache-\(UUID().uuidString)")
        let windsurf = home.appendingPathComponent(".windsurf/session.json")
        let roo = home.appendingPathComponent(
            "Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/session.json"
        )
        try fm.createDirectory(at: windsurf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: roo.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        try #"""
        {
          "sessionId": "ws-rich",
          "title": "Cascade session",
          "task": "Ship cache continuity",
          "workspace": "/Users/me/Pulse",
          "status": "running",
          "currentTool": "edit_file",
          "model": "cascade",
          "lastUpdatedAt": 1700000000000
        }
        """#.write(to: windsurf, atomically: true, encoding: .utf8)

        try #"""
        {
          "sessionId": "roo-1",
          "title": "Roo session",
          "messages": [{"role": "user", "content": "Refactor the tray density"}],
          "workspacePath": "/Users/me/Pulse",
          "status": "running",
          "currentTool": "ask_followup_question"
        }
        """#.write(to: roo, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(
            allowAppData: false,
            appDataAgents: [.roo],
            home: home,
            agentFilter: [.windsurf, .roo]
        )
        let wind = try XCTUnwrap(result.rows.first { $0.id == .windsurf })
        XCTAssertEqual(wind.evidence, .cache)
        XCTAssertEqual(wind.task, "Ship cache continuity")
        XCTAssertEqual(wind.cwd, "/Users/me/Pulse")
        XCTAssertEqual(wind.tool, "edit_file")
        XCTAssertEqual(wind.harvestMs, 1_700_000_000_000)

        var agentRow = AgentRow(rowKey: "windsurf|ws-rich", agent: .windsurf)
        agentRow.task = wind.task
        agentRow.cwd = wind.cwd
        agentRow.tool = wind.tool
        agentRow.model = wind.model
        agentRow.observationSource = wind.evidence
        agentRow.harvestMs = wind.harvestMs
        agentRow.refreshObservationQuality()
        XCTAssertTrue(agentRow.quality.isLimited)
        XCTAssertEqual(agentRow.quality.confidence, .medium)
        XCTAssertTrue(agentRow.quality.missing.contains(where: { $0.reason == "cache_conditional" }))

        let rooRow = try XCTUnwrap(result.rows.first { $0.id == .roo })
        XCTAssertEqual(rooRow.evidence, .cache)
        XCTAssertEqual(rooRow.task, "Refactor the tray density", "nested user message must beat chrome title")
        XCTAssertEqual(rooRow.cwd, "/Users/me/Pulse")
        XCTAssertEqual(rooRow.skill, "pending", "ask_followup_question is an explicit ask tool")
    }

    func testGooseAskFollowupIsPendingButDependingIsNot() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-ask-\(UUID().uuidString)")
        let goose = home.appendingPathComponent(".config/goose/session.json")
        try fm.createDirectory(at: goose.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        try #"{"sessionId":"g-ask","title":"Need input","cwd":"/tmp/goose","status":"running","currentTool":"ask_followup_question"}"#
            .write(to: goose, atomically: true, encoding: .utf8)
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.goose])
        let row = try XCTUnwrap(result.rows.first { $0.id == .goose })
        XCTAssertEqual(row.skill, "pending")
        XCTAssertEqual(row.evidence, .session)
    }

    func testPiFixtureYieldsGoalAndCwd() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pi-\(UUID().uuidString)")
        let session = home.appendingPathComponent(".pi/agent/sessions/sess-pi.jsonl")
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"{"sessionId":"sess-pi","title":"Improve cache continuity","cwd":"/Users/me/Pulse","status":"editing","currentTool":"bash"}"#
            .write(to: session, atomically: true, encoding: .utf8)
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.pi])
        let row = try XCTUnwrap(result.rows.first { $0.id == .pi })
        XCTAssertEqual(row.task, "Improve cache continuity")
        XCTAssertEqual(row.cwd, "/Users/me/Pulse")
        XCTAssertEqual(row.tool, "bash")
        XCTAssertEqual(row.evidence, .session)
    }

    func testPiNestedMessageContentIsSessionTitle() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pi-nested-\(UUID().uuidString)")
        let session = home.appendingPathComponent(".pi/agent/sessions/pulse/sess-pi.jsonl")
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let lines = [
            #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Ship Pi session titles"}]}}"#,
            #"{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Working on it"}]}}"#,
            #"{"cwd":"/Users/me/Pulse","currentTool":"bash"}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.pi])
        let row = try XCTUnwrap(result.rows.first { $0.id == .pi })
        XCTAssertEqual(row.task, "Ship Pi session titles")
        XCTAssertEqual(row.cwd, "/Users/me/Pulse")
        XCTAssertEqual(row.tool, "bash")
        XCTAssertEqual(row.evidence, .session)
        XCTAssertEqual(AgentRow.displayTaskTitle("pi update"), "Update Pi and extensions")
    }

    func testPiEarlyUserPromptSurvivesLongToolTail() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pi-tail-\(UUID().uuidString)")
        let session = home.appendingPathComponent(".pi/agent/sessions/pulse/long-pi.jsonl")
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        var lines = [
            #"{"cwd":"/Users/me/Pulse"}"#,
            #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Keep the opening Pi goal"}]}}"#,
        ]
        for index in 0..<300 {
            lines.append(#"{"type":"tool_use","name":"read","path":"/tmp/file-\#(index).swift"}"#)
        }
        lines.append(#"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"continue"}]}}"#)
        try (lines.joined(separator: "\n") + "\n").write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.pi])
        let row = try XCTUnwrap(result.rows.first { $0.id == .pi })
        XCTAssertEqual(row.task, "Keep the opening Pi goal", "continuation must not replace the last meaningful prompt")
        XCTAssertEqual(row.cwd, "/Users/me/Pulse")
    }

    func testPiSqliteMessageDataWithoutIntentIsTitle() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pi-sqlite-msg-\(UUID().uuidString)")
        let dbURL = home.appendingPathComponent(".pi/context-mode/sessions/sessions.db")
        try fm.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        var database: OpaquePointer?
        guard sqlite3_open(dbURL.path, &database) == SQLITE_OK, let database else {
            XCTFail("could not create Pi fixture database")
            return
        }
        defer { sqlite3_close(database) }
        let payload = #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Fix Pi hero"}]}}"#
            .replacingOccurrences(of: "'", with: "''")
        XCTAssertEqual(sqlite3_exec(database, """
            CREATE TABLE session_meta (
              session_id TEXT, project_dir TEXT, started_at TEXT, last_event_at TEXT, event_count INTEGER
            );
            CREATE TABLE session_events (
              id INTEGER PRIMARY KEY, session_id TEXT, type TEXT, category TEXT,
              data TEXT, project_dir TEXT, created_at TEXT, bytes_returned INTEGER
            );
            INSERT INTO session_meta VALUES (
              'pi-msg', '/Users/me/Pulse', '1700000000', '1700000100', 2
            );
            INSERT INTO session_events VALUES (
              1, 'pi-msg', 'message', '', '\(payload)', '/Users/me/Pulse', '1700000000', 0
            );
            INSERT INTO session_events VALUES (
              2, 'pi-msg', 'file_read', '', '/Users/me/Pulse/Models.swift', '/Users/me/Pulse', '1700000100', 32
            );
            """, nil, nil, nil), SQLITE_OK)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.pi])
        let row = try XCTUnwrap(result.rows.first { $0.id == .pi })
        XCTAssertEqual(row.task, "Fix Pi hero")
        XCTAssertNotEqual(row.task, "Read Models.swift")
        XCTAssertEqual(row.cwd, "/Users/me/Pulse")
    }

    func testPiFileReadDoesNotBecomeTask() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pi-read-\(UUID().uuidString)")
        let dbURL = home.appendingPathComponent(".pi/agent/sessions/sessions.db")
        try fm.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        var database: OpaquePointer?
        guard sqlite3_open(dbURL.path, &database) == SQLITE_OK, let database else {
            XCTFail("could not create Pi fixture database")
            return
        }
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, """
            CREATE TABLE session_meta (
              session_id TEXT, project_dir TEXT, started_at TEXT, last_event_at TEXT, event_count INTEGER
            );
            CREATE TABLE session_events (
              id INTEGER PRIMARY KEY, session_id TEXT, type TEXT, category TEXT,
              data TEXT, project_dir TEXT, created_at TEXT, bytes_returned INTEGER
            );
            INSERT INTO session_meta VALUES (
              'pi-read', '/Users/me/Pulse', '1700000000', '1700000100', 1
            );
            INSERT INTO session_events VALUES (
              1, 'pi-read', 'file_read', '', '/Users/me/Pulse/Models.swift', '/Users/me/Pulse', '1700000100', 32
            );
            """, nil, nil, nil), SQLITE_OK)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.pi])
        let row = try XCTUnwrap(result.rows.first { $0.id == .pi })
        XCTAssertFalse(row.task.hasPrefix("Read "), "file_read must not become the session title")
        XCTAssertNotEqual(row.task, "Models.swift")
        XCTAssertEqual(row.cwd, "/Users/me/Pulse")
    }

    func testPiSqliteFileReadDoesNotBlockJsonlTitle() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pi-merge-\(UUID().uuidString)")
        let dbURL = home.appendingPathComponent(".pi/agent/sessions/sessions.db")
        let session = home.appendingPathComponent(".pi/agent/sessions/sess-pi-title.jsonl")
        try fm.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        var database: OpaquePointer?
        guard sqlite3_open(dbURL.path, &database) == SQLITE_OK, let database else {
            XCTFail("could not create Pi fixture database")
            return
        }
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, """
            CREATE TABLE session_meta (
              session_id TEXT, project_dir TEXT, started_at TEXT, last_event_at TEXT, event_count INTEGER
            );
            CREATE TABLE session_events (
              id INTEGER PRIMARY KEY, session_id TEXT, type TEXT, category TEXT,
              data TEXT, project_dir TEXT, created_at TEXT, bytes_returned INTEGER
            );
            INSERT INTO session_meta VALUES (
              'sess-pi-title', '/Users/me/Pulse', '1700000000', '1700000100', 1
            );
            INSERT INTO session_events VALUES (
              1, 'sess-pi-title', 'file_read', '',
              '/Users/me/Pulse/NativeActivityHarvest.swift', '/Users/me/Pulse', '1700000100', 32
            );
            """, nil, nil, nil), SQLITE_OK)
        try #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Fix the tray hero"}]}}"#
            .write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.pi])
        let row = try XCTUnwrap(result.rows.first { $0.id == .pi && $0.sessionID == "sess-pi-title" })
        XCTAssertEqual(row.task, "Fix the tray hero")
        XCTAssertNotEqual(row.task, "Read NativeActivityHarvest.swift")
    }

    func testPiOfficialSessionLayoutYieldsTitleAndCwd() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pi-official-\(UUID().uuidString)")
        let session = home.appendingPathComponent(
            ".pi/agent/sessions/--Users-me-Pulse--/2024-12-03T14-00-01-000Z_sess-official.jsonl"
        )
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let lines = [
            #"{"type":"session","version":3,"id":"sess-official","timestamp":"2024-12-03T14:00:00.000Z","cwd":"/Users/me/Pulse"}"#,
            #"{"type":"message","id":"a1b2c3d4","parentId":null,"timestamp":"2024-12-03T14:00:01.000Z","message":{"role":"user","content":"Fix the tray hero"}}"#,
            #"{"type":"message","id":"b2c3d4e5","parentId":"a1b2c3d4","timestamp":"2024-12-03T14:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"On it"}],"model":"claude-sonnet-4-5"}}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.pi])
        let row = try XCTUnwrap(result.rows.first { $0.id == .pi })
        XCTAssertEqual(row.task, "Fix the tray hero")
        XCTAssertEqual(row.cwd, "/Users/me/Pulse")
        XCTAssertEqual(row.sessionID, "sess-official")
        XCTAssertEqual(row.evidence, .session)
    }

    func testPiSessionInfoNameIsHero() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pi-named-\(UUID().uuidString)")
        let session = home.appendingPathComponent(
            ".pi/agent/sessions/--Users-me-Pulse--/2024-12-03T14-00-01-000Z_sess-named.jsonl"
        )
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let lines = [
            #"{"type":"session","version":3,"id":"sess-named","cwd":"/Users/me/Pulse"}"#,
            #"{"type":"message","message":{"role":"user","content":"first prompt that should lose"}}"#,
            #"{"type":"session_info","name":"Refactor auth module"}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.pi])
        let row = try XCTUnwrap(result.rows.first { $0.id == .pi })
        XCTAssertEqual(row.task, "Refactor auth module", "/name is the session selector title")
    }

    func testPiEnvironmentContextDoesNotHidePrompt() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pi-env-\(UUID().uuidString)")
        let session = home.appendingPathComponent(
            ".pi/agent/sessions/--Users-me-Pulse--/2024-12-03T14-00-01-000Z_sess-env.jsonl"
        )
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let lines = [
            #"{"type":"session","id":"sess-env","cwd":"/Users/me/Pulse"}"#,
            #"{"type":"message","message":{"role":"user","content":"<environment_context>\ncwd: /Users/me/Pulse\n</environment_context>\nShip the Pi title"}}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.pi])
        let row = try XCTUnwrap(result.rows.first { $0.id == .pi })
        XCTAssertEqual(row.task, "Ship the Pi title")
    }

    func testPiCompactionRetainedTailIsTitle() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pi-compact-\(UUID().uuidString)")
        let session = home.appendingPathComponent(
            ".pi/agent/sessions/--Users-me-Pulse--/2024-12-03T14-00-01-000Z_sess-compact.jsonl"
        )
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let lines = [
            #"{"type":"session","id":"sess-compact","cwd":"/Users/me/Pulse"}"#,
            #"{"type":"compaction","summary":"Earlier turns","retainedTail":[{"role":"user","content":"Keep the compacted Pi goal"},{"role":"assistant","content":[{"type":"text","text":"ok"}]}]}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.pi])
        let row = try XCTUnwrap(result.rows.first { $0.id == .pi })
        XCTAssertEqual(row.task, "Keep the compacted Pi goal")
    }

    func testPiEncodedFolderIsCwdWithoutHeader() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pi-folder-\(UUID().uuidString)")
        let session = home.appendingPathComponent(
            ".pi/agent/sessions/--Users-me-Pulse--/2024-12-03T14-00-01-000Z_sess-folder.jsonl"
        )
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"{"type":"message","message":{"role":"user","content":"Decode the Pi folder"}}"#
            .write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.pi])
        let row = try XCTUnwrap(result.rows.first { $0.id == .pi })
        XCTAssertEqual(row.task, "Decode the Pi folder")
        XCTAssertEqual(row.cwd, "/Users/me/Pulse")
        XCTAssertEqual(row.sessionID, "sess-folder")
    }

    func testPiStaleJSONLStillYieldsTitle() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pi-stale-\(UUID().uuidString)")
        let session = home.appendingPathComponent(
            ".pi/agent/sessions/--Users-me-Pulse--/2024-12-03T14-00-01-000Z_sess-stale.jsonl"
        )
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let lines = [
            #"{"type":"session","id":"sess-stale","cwd":"/Users/me/Pulse"}"#,
            #"{"type":"message","message":{"role":"user","content":"Old but named Pi goal"}}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)
        try fm.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-80 * 24 * 3600)],
            ofItemAtPath: session.path
        )

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.pi])
        let row = try XCTUnwrap(result.rows.first { $0.id == .pi })
        XCTAssertEqual(row.task, "Old but named Pi goal")
    }

    func testPiEmptySqliteDoesNotHideOfficialJSONL() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pi-sqlite-official-\(UUID().uuidString)")
        let dbURL = home.appendingPathComponent(".pi/agent/sessions/sessions.db")
        let session = home.appendingPathComponent(
            ".pi/agent/sessions/--Users-me-Pulse--/2024-12-03T14-00-01-000Z_official-uuid.jsonl"
        )
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        var database: OpaquePointer?
        guard sqlite3_open(dbURL.path, &database) == SQLITE_OK, let database else {
            XCTFail("could not create Pi fixture database")
            return
        }
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, """
            CREATE TABLE session_meta (
              session_id TEXT, project_dir TEXT, started_at TEXT, last_event_at TEXT, event_count INTEGER
            );
            CREATE TABLE session_events (
              id INTEGER PRIMARY KEY, session_id TEXT, type TEXT, category TEXT,
              data TEXT, project_dir TEXT, created_at TEXT, bytes_returned INTEGER
            );
            INSERT INTO session_meta VALUES (
              'official-uuid', '/Users/me/Pulse', '1700000000', '1700000100', 1
            );
            INSERT INTO session_events VALUES (
              1, 'official-uuid', 'file_read', '',
              '/Users/me/Pulse/NativeActivityHarvest.swift', '/Users/me/Pulse', '1700000100', 32
            );
            """, nil, nil, nil), SQLITE_OK)
        let lines = [
            #"{"type":"session","id":"official-uuid","cwd":"/Users/me/Pulse"}"#,
            #"{"type":"message","message":{"role":"user","content":"Fix the tray hero"}}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.pi])
        let titled = result.rows.filter { $0.id == .pi }
        XCTAssertEqual(titled.count, 1, "empty SQLite must not add a second blank Pi row")
        XCTAssertEqual(titled.first?.task, "Fix the tray hero")
        XCTAssertEqual(titled.first?.sessionID, "official-uuid")
    }

    func testPiResumeTitleIsFirstUserMessage() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pi-first-\(UUID().uuidString)")
        let session = home.appendingPathComponent(
            ".pi/agent/sessions/--Users-me-Pulse--/2024-12-03T14-00-01-000Z_sess-first.jsonl"
        )
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let lines = [
            #"{"type":"session","id":"sess-first","cwd":"/Users/me/Pulse"}"#,
            #"{"type":"message","message":{"role":"user","content":"Fix the tray hero"}}"#,
            #"{"type":"message","message":{"role":"user","content":"Also update the README"}}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.pi])
        let row = try XCTUnwrap(result.rows.first { $0.id == .pi })
        XCTAssertEqual(row.task, "Fix the tray hero", "Pi /resume uses the first user message, not the latest")
    }

    func testPiNamedSessionEndingInSessionWordIsTitle() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pi-auth-session-\(UUID().uuidString)")
        let session = home.appendingPathComponent(
            ".pi/agent/sessions/--Users-me-Pulse--/2024-12-03T14-00-01-000Z_sess-auth.jsonl"
        )
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let lines = [
            #"{"type":"session","id":"sess-auth","cwd":"/Users/me/Pulse"}"#,
            #"{"type":"message","message":{"role":"user","content":"first prompt that should lose"}}"#,
            #"{"type":"session_info","name":"Auth session"}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.pi])
        let row = try XCTUnwrap(result.rows.first { $0.id == .pi })
        XCTAssertEqual(row.task, "Auth session", "/name titles ending in 'session' are not chrome")
    }

    func testPiDummyDatabaseWithoutSessionMetaStillTitles() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pi-noise-db-\(UUID().uuidString)")
        let dbURL = home.appendingPathComponent(".pi/agent/sessions/noise.db")
        let session = home.appendingPathComponent(
            ".pi/agent/sessions/--Users-me-Pulse--/2024-12-03T14-00-01-000Z_sess-noise.jsonl"
        )
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        var database: OpaquePointer?
        guard sqlite3_open(dbURL.path, &database) == SQLITE_OK, let database else {
            XCTFail("could not create dummy Pi database")
            return
        }
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE unrelated (id INTEGER);", nil, nil, nil), SQLITE_OK)
        let lines = [
            #"{"type":"session","id":"sess-noise","cwd":"/Users/me/Pulse"}"#,
            #"{"type":"message","message":{"role":"user","content":"Survive a sibling database"}}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.pi])
        let row = try XCTUnwrap(result.rows.first { $0.id == .pi })
        XCTAssertEqual(row.task, "Survive a sibling database")
        XCTAssertFalse(result.health.contains { $0.id == .pi && $0.state == .failed })
    }

    func testPiUserPromptAfterOversizedToolRecord() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pi-huge-\(UUID().uuidString)")
        let session = home.appendingPathComponent(
            ".pi/agent/sessions/--Users-me-Pulse--/2024-12-03T14-00-01-000Z_sess-huge.jsonl"
        )
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        // Larger than the 96 KB Pi head so the user line is only in the tail.
        let blob = String(repeating: "a", count: 600_000)
        let lines = [
            #"{"type":"session","id":"sess-huge","cwd":"/Users/me/Pulse"}"#,
            #"{"type":"tool_use","name":"read","content":"\#(blob)"}"#,
            #"{"type":"message","message":{"role":"user","content":"Keep the split Pi goal"}}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.pi])
        let row = try XCTUnwrap(result.rows.first { $0.id == .pi })
        XCTAssertEqual(row.task, "Keep the split Pi goal")
    }

    func testPiOfficialHeaderWithoutUserDoesNotInventProjectHero() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pi-header-\(UUID().uuidString)")
        let session = home.appendingPathComponent(
            ".pi/agent/sessions/--Users-me-Pulse--/2024-12-03T14-00-01-000Z_sess-empty.jsonl"
        )
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let lines = [
            #"{"type":"session","version":3,"id":"sess-empty","cwd":"/Users/me/Pulse"}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.pi])
        XCTAssertTrue(
            result.rows.filter { $0.id == .pi }.isEmpty,
            "cwd-only official Pi JSONL must not become a project-name tray hero"
        )
    }

    func testPiGarbageDatabaseDoesNotBlankJSONLTitle() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pi-garbage-db-\(UUID().uuidString)")
        let dbURL = home.appendingPathComponent(".pi/agent/sessions/not-sqlite.db")
        let session = home.appendingPathComponent(
            ".pi/agent/sessions/--Users-me-Pulse--/2024-12-03T14-00-01-000Z_sess-live.jsonl"
        )
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try Data("this is not a sqlite database".utf8).write(to: dbURL)
        let lines = [
            #"{"type":"session","id":"sess-live","cwd":"/Users/me/Pulse"}"#,
            #"{"type":"message","message":{"role":"user","content":"Survive a garbage database"}}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.pi])
        let row = try XCTUnwrap(result.rows.first { $0.id == .pi })
        XCTAssertEqual(row.task, "Survive a garbage database")
        XCTAssertFalse(result.health.contains { $0.id == .pi && $0.state == .failed })
    }

    func testDependingStatusIsNotHarvestPending() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pending-\(UUID().uuidString)")
        let goose = home.appendingPathComponent(".config/goose/session.json")
        try fm.createDirectory(at: goose.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        try #"{"sessionId":"g-dep","title":"Real goose goal","cwd":"/tmp/goose","status":"depending","currentTool":"bash"}"#
            .write(to: goose, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.goose])
        let row = try XCTUnwrap(result.rows.first { $0.id == .goose })
        XCTAssertEqual(row.task, "Real goose goal")
        XCTAssertNotEqual(row.skill, "pending", "depending must not substring-match pending")
        XCTAssertEqual(row.phase, "working", "Goose depending is lifecycle busy, not Waiting (0.82)")
    }

    func testGeminiFunctionCallAndUsageMetadataReachTray() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-gemini-\(UUID().uuidString)")
        let session = home
            .appendingPathComponent(".gemini/tmp/pulse/chats", isDirectory: true)
            .appendingPathComponent("session-gemini.jsonl")
        let projectRoot = home.appendingPathComponent(".gemini/tmp/pulse/.project_root")
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try "/Users/me/Pulse\n".write(to: projectRoot, atomically: true, encoding: .utf8)
        let lines = [
            #"{"sessionId":"gem-1","title":"Ship fleet substance","cwd":"/Users/me/Pulse","modelName":"gemini-2.5-pro","status":"in_progress","functionCall":{"name":"run_shell"},"usageMetadata":{"promptTokenCount":800,"candidatesTokenCount":120}}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.gemini])
        let row = try XCTUnwrap(result.rows.first { $0.id == .gemini })
        XCTAssertEqual(row.task, "Ship fleet substance")
        XCTAssertEqual(row.model, "gemini-2.5-pro")
        XCTAssertEqual(row.tool, "run_shell")
        XCTAssertEqual(row.tokensIn, 800)
        XCTAssertEqual(row.tokensOut, 120)
        XCTAssertEqual(row.phase, "working", "in_progress must normalize to working")
        XCTAssertEqual(row.evidence, .session)
    }

    func testCursorComposerModelDetailsReachTray() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-cursor-model-\(UUID().uuidString)")
        let user = home.appendingPathComponent("Library/Application Support/Cursor/User", isDirectory: true)
        let dbURL = user.appendingPathComponent("globalStorage/state.vscdb")
        let workspace = user.appendingPathComponent("workspaceStorage/ws-m/workspace.json")
        try fm.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: workspace.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"{"folder":"/Users/me/Client"}"#.write(to: workspace, atomically: true, encoding: .utf8)

        var database: OpaquePointer?
        guard sqlite3_open(dbURL.path, &database) == SQLITE_OK, let database else {
            XCTFail("could not create Cursor fixture database")
            return
        }
        defer { sqlite3_close(database) }
        let schema = "CREATE TABLE composerHeaders (composerId TEXT, workspaceId TEXT, lastUpdatedAt INTEGER, value TEXT, isArchived INTEGER, isSubagent INTEGER);"
        XCTAssertEqual(sqlite3_exec(database, schema, nil, nil, nil), SQLITE_OK)
        let value = #"{"name":"Model details composer","unifiedMode":"agent","modelDetails":{"modelName":"claude-4-sonnet"}}"#
        let insert = "INSERT INTO composerHeaders VALUES ('composer-md', 'ws-m', 1700000000000, '\(value.replacingOccurrences(of: "'", with: "''"))', 0, 0);"
        XCTAssertEqual(sqlite3_exec(database, insert, nil, nil, nil), SQLITE_OK)

        let result = NativeActivityHarvest.scan(
            allowAppData: false,
            appDataAgents: [.cursor],
            home: home,
            agentFilter: [.cursor]
        )
        let row = try XCTUnwrap(result.rows.first { $0.id == .cursor })
        XCTAssertEqual(row.model, "claude-4-sonnet")
        XCTAssertEqual(row.mode, "agent")
    }

    func testPiAgentUsageJSONCarriesModelAndTokens() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pi-db-\(UUID().uuidString)")
        let dbURL = home.appendingPathComponent(".pi/agent/sessions/sessions.db")
        try fm.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        var database: OpaquePointer?
        guard sqlite3_open(dbURL.path, &database) == SQLITE_OK, let database else {
            XCTFail("could not create Pi fixture database")
            return
        }
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, """
            CREATE TABLE session_meta (
              session_id TEXT, project_dir TEXT, started_at TEXT, last_event_at TEXT, event_count INTEGER
            );
            CREATE TABLE session_events (
              id INTEGER PRIMARY KEY, session_id TEXT, type TEXT, category TEXT,
              data TEXT, project_dir TEXT, created_at TEXT, bytes_returned INTEGER
            );
            """, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, """
            INSERT INTO session_meta VALUES (
              'pi-1', '/Users/me/Pulse', '1700000000', '1700000100', 4
            );
            INSERT INTO session_events VALUES (
              1, 'pi-1', 'intent', '', 'Improve Pi tray substance', '/Users/me/Pulse', '1700000000', 0
            );
            INSERT INTO session_events VALUES (
              2, 'pi-1', 'agent_usage', '',
              '{"model":"gpt-5","usageMetadata":{"promptTokenCount":400,"candidatesTokenCount":90}}',
              '/Users/me/Pulse', '1700000100', 64
            );
            """, nil, nil, nil), SQLITE_OK)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.pi])
        let row = try XCTUnwrap(result.rows.first { $0.id == .pi })
        XCTAssertEqual(row.task, "Improve Pi tray substance")
        XCTAssertEqual(row.model, "gpt-5")
        XCTAssertEqual(row.tokensIn, 400)
        XCTAssertEqual(row.tokensOut, 90)
        XCTAssertEqual(row.cwd, "/Users/me/Pulse")
    }

    func testThinCacheModelStillSurfacesWithoutSessionUpgrade() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-cache-model-\(UUID().uuidString)")
        let windsurf = home.appendingPathComponent(".windsurf/session.json")
        try fm.createDirectory(at: windsurf.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"{"sessionId":"ws-model","title":"Windsurf model only","model":"cascade","status":"active"}"#
            .write(to: windsurf, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.windsurf])
        let wind = try XCTUnwrap(result.rows.first { $0.id == .windsurf })
        XCTAssertEqual(wind.evidence, .cache)
        XCTAssertEqual(wind.model, "cascade")
        XCTAssertEqual(wind.phase, "working", "active → working")
        XCTAssertNotEqual(wind.evidence, .session)
    }

    func testAwaitingUserStatusIsHarvestPending() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-await-\(UUID().uuidString)")
        let goose = home.appendingPathComponent(".config/goose/session.json")
        try fm.createDirectory(at: goose.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        try #"{"sessionId":"g-wait","title":"Need approval","cwd":"/tmp/goose","status":"awaiting_user","currentTool":"bash"}"#
            .write(to: goose, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.goose])
        let row = try XCTUnwrap(result.rows.first { $0.id == .goose })
        XCTAssertEqual(row.skill, "pending")
    }

    func testClineAskFieldIsPendingUntilAskResponse() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-cline-ask-\(UUID().uuidString)")
        let waiting = home.appendingPathComponent(
            "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/session.json"
        )
        try fm.createDirectory(at: waiting.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        try #"""
        {
          "sessionId": "cl-ask",
          "title": "Cline needs input",
          "workspacePath": "/Users/me/Pulse",
          "status": "running",
          "ask": "followup",
          "text": "Which package manager?"
        }
        """#.write(to: waiting, atomically: true, encoding: .utf8)

        let pending = NativeActivityHarvest.scan(
            allowAppData: false,
            appDataAgents: [.cline],
            home: home,
            agentFilter: [.cline]
        )
        let pendingRow = try XCTUnwrap(pending.rows.first { $0.id == .cline })
        XCTAssertEqual(pendingRow.skill, "pending", "Cline ask=followup is an explicit wait")
        XCTAssertEqual(pendingRow.evidence, .cache)

        try #"""
        {
          "sessionId": "cl-ask",
          "title": "Cline needs input",
          "workspacePath": "/Users/me/Pulse",
          "status": "running",
          "ask": "followup",
          "askResponse": "messageResponse",
          "text": "Which package manager?"
        }
        """#.write(to: waiting, atomically: true, encoding: .utf8)

        let answered = NativeActivityHarvest.scan(
            allowAppData: false,
            appDataAgents: [.cline],
            home: home,
            agentFilter: [.cline]
        )
        let answeredRow = try XCTUnwrap(answered.rows.first { $0.id == .cline })
        XCTAssertNotEqual(answeredRow.skill, "pending", "askResponse means the user already answered")
    }

    func testCascadeWaitingForResponseFlagIsPending() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-cascade-wait-\(UUID().uuidString)")
        let windsurf = home.appendingPathComponent(".windsurf/session.json")
        try fm.createDirectory(at: windsurf.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        try #"""
        {
          "sessionId": "ws-ask",
          "title": "Cascade needs you",
          "workspace": "/Users/me/Pulse",
          "status": "running",
          "isWaitingForResponse": true,
          "currentTool": "ask_clarifying_question"
        }
        """#.write(to: windsurf, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.windsurf])
        let row = try XCTUnwrap(result.rows.first { $0.id == .windsurf })
        XCTAssertEqual(row.skill, "pending")
        XCTAssertEqual(row.tool, "ask_clarifying_question")
        XCTAssertEqual(row.evidence, .cache)
    }

    func testWaitingNoneAgentNeverStampsHarvestPending() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-waiting-none-\(UUID().uuidString)")
        // Trae is waitingSource.none and bestEffortCache — status words / ask
        // tools must not invent Waiting; Attention bridge is the only honest path.
        let trae = home.appendingPathComponent(".trae/session.json")
        try fm.createDirectory(at: trae.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        try #"""
        {
          "sessionId": "trae-1",
          "title": "Trae work",
          "cwd": "/tmp/trae",
          "status": "awaiting_user",
          "currentTool": "ask_followup_question"
        }
        """#.write(to: trae, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(
            allowAppData: false,
            appDataAgents: [.trae],
            home: home,
            agentFilter: [.trae]
        )
        let row = try XCTUnwrap(result.rows.first { $0.id == .trae })
        XCTAssertEqual(AgentID.trae.waitingSource, .none)
        XCTAssertNotEqual(row.skill, "pending", "Waiting-none must never stamp harvest pending")
        XCTAssertEqual(row.evidence, .cache)
    }

    func testClaudeToolResultIsNotSessionTitle() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-claude-result-\(UUID().uuidString)")
        let session = home
            .appendingPathComponent(".claude/projects/-Users-me-code-Pulse", isDirectory: true)
            .appendingPathComponent("sess-result.jsonl")
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let dump = String(repeating: "search hit ", count: 40)
        let lines = [
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Keep the Claude goal"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"\#(dump)"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"path":"/tmp/file-0.swift"}}]}}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.claude])
        let row = try XCTUnwrap(result.rows.first { $0.id == .claude })
        XCTAssertEqual(row.task, "Keep the Claude goal")
        XCTAssertFalse(row.task.contains("search hit"))
        XCTAssertNotEqual(row.cwd, "/tmp/file-0.swift")
        XCTAssertEqual(row.cwd, "/Users/me/code/Pulse")
    }

    func testClaudeEarlyPromptSurvivesLongToolResultTail() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-claude-tail-\(UUID().uuidString)")
        let session = home
            .appendingPathComponent(".claude/projects/-Users-me-Pulse", isDirectory: true)
            .appendingPathComponent("sess-long.jsonl")
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        var lines = [
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Ship hero honesty"}]}}"#,
        ]
        for index in 0..<300 {
            lines.append(
                #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"chunk-\#(index)"}]}}"#
            )
        }
        try (lines.joined(separator: "\n") + "\n").write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.claude])
        let row = try XCTUnwrap(result.rows.first { $0.id == .claude })
        XCTAssertEqual(row.task, "Ship hero honesty")
    }

    func testCodexEventMsgUserMessageIsSessionTitle() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-codex-event-\(UUID().uuidString)")
        let session = home
            .appendingPathComponent(".codex/sessions/2026/08/13", isDirectory: true)
            .appendingPathComponent("rollout-event.jsonl")
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let lines = [
            #"{"type":"session_meta","payload":{"session_id":"evt-1","cwd":"/Users/me/Pulse"},"timestamp":1700000000}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Ship Codex event titles"},"timestamp":1700000001}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"continue"},"timestamp":1700000002}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.codex])
        let row = try XCTUnwrap(result.rows.first { $0.id == .codex })
        XCTAssertEqual(row.task, "Ship Codex event titles")
        XCTAssertEqual(row.cwd, "/Users/me/Pulse")
    }

    func testCodexDesktopEnvelopeIsStrippedFromTitle() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-codex-desk-\(UUID().uuidString)")
        let session = home
            .appendingPathComponent(".codex/sessions/2026/08/13", isDirectory: true)
            .appendingPathComponent("rollout-desk.jsonl")
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let lines = [
            #"{"type":"session_meta","payload":{"session_id":"desk-1","cwd":"/Users/me/Pulse"},"timestamp":1700000000}"#,
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"## My request for Codex:\\nFix the lamp\\n<image>blob</image>\"}]},\"timestamp\":1700000001}",
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.codex])
        let row = try XCTUnwrap(result.rows.first { $0.id == .codex })
        XCTAssertEqual(row.task, "Fix the lamp")
        XCTAssertFalse(row.task.contains("My request"))
        XCTAssertFalse(row.task.contains("<image"))
    }

    func testGooseNameIsSessionTitle() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-goose-name-\(UUID().uuidString)")
        let goose = home.appendingPathComponent(".config/goose/session.json")
        try fm.createDirectory(at: goose.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"{"sessionId":"g-name","name":"Need input","cwd":"/tmp/goose","status":"running","currentTool":"bash"}"#
            .write(to: goose, atomically: true, encoding: .utf8)
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.goose])
        let row = try XCTUnwrap(result.rows.first { $0.id == .goose })
        XCTAssertEqual(row.task, "Need input")
        XCTAssertEqual(row.cwd, "/tmp/goose")
    }

    func testKimiLastPromptAndWorkDirReachTray() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-kimi-\(UUID().uuidString)")
        let state = home.appendingPathComponent(".kimi-code/sessions/k1/state.json")
        try fm.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"{"sessionId":"k1","lastPrompt":"Refactor auth","workDir":"/Users/me/app"}"#
            .write(to: state, atomically: true, encoding: .utf8)
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.kimi])
        let row = try XCTUnwrap(result.rows.first { $0.id == .kimi })
        XCTAssertEqual(row.task, "Refactor auth")
        XCTAssertEqual(row.cwd, "/Users/me/app")
    }
}
