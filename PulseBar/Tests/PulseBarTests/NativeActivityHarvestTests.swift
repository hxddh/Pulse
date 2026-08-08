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
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file":"PulseApp.swift"}}]}}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.claude])
        let row = try XCTUnwrap(result.rows.first { $0.id == .claude })
        XCTAssertEqual(row.task, "Fix the tray density")
        XCTAssertEqual(row.cwd, "/Users/me/code/Pulse")
        XCTAssertEqual(row.project, "Pulse")
        XCTAssertEqual(row.tool, "Edit", "latest tool_use must win, not the first")
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
}
