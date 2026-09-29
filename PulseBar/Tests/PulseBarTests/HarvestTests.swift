import Foundation
import SQLite3
import Testing
import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

// Harvest: the native collector — adapters, row admission, pending, chrome.

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
        // 9.0: conversation bubbles live in the same store's KV table.
        let kv = """
        CREATE TABLE cursorDiskKV (key TEXT, value TEXT);
        INSERT INTO cursorDiskKV VALUES ('bubbleId:composer-1:b1', '{"type":1,"text":"please refine it"}');
        INSERT INTO cursorDiskKV VALUES ('bubbleId:composer-1:b2', '{"type":2,"text":"Adapter refined — headers now verified."}');
        """
        XCTAssertEqual(sqlite3_exec(database, kv, nil, nil, nil), SQLITE_OK)

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
        // 23.0: Cursor's format is unverified, so `hasBlockingPendingActions`
        // is not a Waiting signal.
        XCTAssertNotEqual(row.skill, "pending")
        XCTAssertEqual(row.mode, "agent", "unifiedMode must reach the tray, not invent local")
        XCTAssertEqual(
            row.lastWord, "Adapter refined — headers now verified.",
            "the latest assistant bubble is the row's last word"
        )
    }

    func testCorruptStoreDoesNotHideOtherAdapterAndFilterIsIsolated() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-corrupt-\(UUID().uuidString)")
        let codex = home.appendingPathComponent(".codex/sessions/2026/08/03/ok.jsonl")
        let broken = home.appendingPathComponent(".copilot/threads/bad.json")
        try fm.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: broken.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"{"session_id":"ok","cwd":"/Users/me/Pulse","title":"Codex survives"}"#.write(to: codex, atomically: true, encoding: .utf8)
        try "{not-json".write(to: broken, atomically: true, encoding: .utf8)
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.codex, .copilot])
        XCTAssertTrue(result.rows.contains { $0.id == .codex })
        XCTAssertTrue(result.health.contains { $0.id == .copilot })
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
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":220,"output_tokens":55,"total_tokens":27500},"model_context_window":110000}},"timestamp":1700000002}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.codex])
        let row = try XCTUnwrap(result.rows.first { $0.id == .codex })
        XCTAssertEqual(row.task, "Count the tokens")
        XCTAssertEqual(row.tokensIn, 220)
        XCTAssertEqual(row.tokensOut, 55)
    }

    func testPiWorkFactsAreCollected() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pi-work-\(UUID().uuidString)")
        let session = home.appendingPathComponent(
            ".pi/agent/sessions/--Users-me-Pulse--/2024-12-03T14-00-01-000Z_sess-work.jsonl"
        )
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        // A large assistant record (>8 KB) — the class of line the title-only
        // gate used to skip, which is exactly where usage/model/tool live.
        let prose = String(repeating: "All checks passing so far. ", count: 400)
        let bigAssistant = "{\"type\":\"message\",\"timestamp\":\"2024-12-03T14:00:04.000Z\","
            + "\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"\(prose)\"},"
            + "{\"type\":\"toolCall\",\"id\":\"t2\",\"name\":\"bash\",\"arguments\":{\"command\":\"swift test\"}}],"
            + "\"model\":\"claude-opus-4\",\"usage\":{\"input\":9000,\"output\":150}}}"
        XCTAssertGreaterThan(bigAssistant.count, 8_192)
        let lines = [
            #"{"type":"session","version":3,"id":"sess-work","timestamp":"2024-12-03T14:00:00.000Z","cwd":"/Users/me/Pulse"}"#,
            #"{"type":"message","timestamp":"2024-12-03T14:00:01.000Z","message":{"role":"user","content":"Fix the tray"}}"#,
            #"{"type":"message","timestamp":"2024-12-03T14:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Reading the panel code"},{"type":"toolCall","id":"t1","name":"read","arguments":{"path":"/a.swift"}}],"model":"claude-sonnet-4-5","usage":{"input":5185,"output":80}}}"#,
            #"{"type":"message","timestamp":"2024-12-03T14:00:03.000Z","message":{"role":"toolResult","toolCallId":"t1","content":"error: no such file /a.swift","isError":true}}"#,
            bigAssistant,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.pi])
        let row = try XCTUnwrap(result.rows.first { $0.id == .pi })
        XCTAssertEqual(row.task, "Fix the tray")
        // Small assistant line: parsed whole — model + usage {input, output}.
        XCTAssertEqual(row.model, "claude-sonnet-4-5")
        // Large assistant line: salvaged by bounded regex — tokens climb,
        // the latest tool call wins.
        XCTAssertEqual(row.tokensIn, 9_000)
        XCTAssertEqual(row.tokensOut, 150)
        XCTAssertEqual(row.tool, "bash")
        // Self-report now runs for Pi: the agent's words and the failed
        // result's own text.
        XCTAssertTrue(row.lastWord.hasPrefix("All checks passing"), row.lastWord)
        XCTAssertTrue(row.lastErrorText.contains("no such file"), row.lastErrorText)
    }

    func testCodexModelAndAssistantWordAreCollected() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-codex-model-\(UUID().uuidString)")
        let session = home
            .appendingPathComponent(".codex/sessions/2026/08/03", isDirectory: true)
            .appendingPathComponent("rollout-model.jsonl")
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let lines = [
            #"{"type":"session_meta","payload":{"session_id":"mdl-1","cwd":"/Users/me/Pulse"},"timestamp":1700000000}"#,
            #"{"type":"turn_context","payload":{"model":"gpt-5-codex","cwd":"/Users/me/Pulse"},"timestamp":1700000001}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Name the model"}]},"timestamp":1700000002}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done — the lamp is green."}]},"timestamp":1700000003}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.codex])
        let row = try XCTUnwrap(result.rows.first { $0.id == .codex })
        XCTAssertEqual(row.task, "Name the model")
        XCTAssertEqual(row.model, "gpt-5-codex")
        XCTAssertTrue(row.lastWord.contains("lamp is green"), row.lastWord)
    }

    func testClaudeSkillInvocationBecomesTheSkillFact() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-claude-skill-\(UUID().uuidString)")
        let session = home
            .appendingPathComponent(".claude/projects/-Users-me-code-Pulse", isDirectory: true)
            .appendingPathComponent("sess-skill.jsonl")
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let lines = [
            #"{"type":"user","message":{"role":"user","content":"Review the diff"},"sessionId":"sess-skill"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"code-review"}}]},"sessionId":"sess-skill"}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.claude])
        let row = try XCTUnwrap(result.rows.first { $0.id == .claude })
        XCTAssertEqual(row.skill, "code-review", "the workflow fact lives in the Skill call's input")
    }

    /// 20.0: the legacy whole-file layout Gemini CLI migrates on resume —
    /// `messages[{type: "user"|"gemini"}]`, never `history/role/parts`.
    func testGeminiWholeFileChatYieldsTheModelLastWord() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-gemini-chat-\(UUID().uuidString)")
        let session = home
            .appendingPathComponent(".gemini/tmp/pulse/chats", isDirectory: true)
            .appendingPathComponent("session-chat.json")
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let document = #"{"sessionId":"gem-chat","projectHash":"p","startTime":"2026-09-29T10:00:00.000Z","lastUpdated":"2026-09-29T10:05:00.000Z","messages":[{"id":"1","timestamp":"2026-09-29T10:00:01.000Z","type":"user","content":[{"text":"Fix the lamp"}]},{"id":"2","timestamp":"2026-09-29T10:01:00.000Z","type":"gemini","content":"First pass done."},{"id":"3","timestamp":"2026-09-29T10:02:00.000Z","type":"user","content":[{"text":"and the badge"}]},{"id":"4","timestamp":"2026-09-29T10:05:00.000Z","type":"gemini","content":"Badge is green now."}]}"#
        try document.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.gemini])
        let row = try XCTUnwrap(result.rows.first { $0.id == .gemini })
        XCTAssertEqual(row.lastWord, "Badge is green now.", "the LAST gemini turn wins")
        XCTAssertEqual(row.task, "and the badge")
    }

    func testOpenCodeLastWordComesFromTheAssistantMessage() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-opencode-\(UUID().uuidString)")
        let dbURL = home.appendingPathComponent(".local/share/opencode/opencode.db")
        try fm.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        var database: OpaquePointer?
        guard sqlite3_open(dbURL.path, &database) == SQLITE_OK, let database else {
            XCTFail("could not create OpenCode fixture database")
            return
        }
        defer { sqlite3_close(database) }
        let schema = """
        CREATE TABLE session (id TEXT, title TEXT, directory TEXT, agent TEXT, model TEXT,
            tokens_input INTEGER, tokens_output INTEGER, time_created INTEGER,
            time_updated INTEGER, summary_files INTEGER, time_archived INTEGER);
        CREATE TABLE message (id TEXT, session_id TEXT, data TEXT);
        CREATE TABLE part (session_id TEXT, message_id TEXT, data TEXT, time_updated INTEGER);
        INSERT INTO session VALUES ('oc-1', 'Tidy the panel', '/Users/me/Pulse', 'build',
            'anthropic/claude-sonnet-4', 1200, 300, 1700000000000, 1700000005000, 2, 0);
        INSERT INTO message VALUES ('m1', 'oc-1', '{"role":"user"}');
        INSERT INTO message VALUES ('m2', 'oc-1', '{"role":"assistant"}');
        INSERT INTO part VALUES ('oc-1', 'm1', '{"type":"text","text":"tidy it please"}', 1);
        INSERT INTO part VALUES ('oc-1', 'm2', '{"type":"text","text":"Panel tidied; two rows aligned."}', 2);
        """
        XCTAssertEqual(sqlite3_exec(database, schema, nil, nil, nil), SQLITE_OK)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.opencode])
        let row = try XCTUnwrap(result.rows.first { $0.id == .opencode })
        XCTAssertEqual(row.task, "Tidy the panel")
        XCTAssertEqual(row.tokensIn, 1200)
        XCTAssertEqual(
            row.lastWord, "Panel tidied; two rows aligned.",
            "role comes from the message table — a part alone has no author"
        )
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

    func testGooseAskFollowupIsPendingButDependingIsNot() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-ask-\(UUID().uuidString)")
        let goose = home.appendingPathComponent(".copilot/session.json")
        try fm.createDirectory(at: goose.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        try #"{"sessionId":"g-ask","title":"Need input","cwd":"/tmp/goose","status":"running","currentTool":"ask_followup_question"}"#
            .write(to: goose, atomically: true, encoding: .utf8)
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.copilot])
        let row = try XCTUnwrap(result.rows.first { $0.id == .copilot })
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

    func testPiClearedSessionNameFallsBackToFirstUser() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pi-clear-\(UUID().uuidString)")
        let session = home.appendingPathComponent(
            ".pi/agent/sessions/--Users-me-Pulse--/2024-12-03T14-00-01-000Z_sess-clear.jsonl"
        )
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let lines = [
            #"{"type":"session","id":"sess-clear","cwd":"/Users/me/Pulse"}"#,
            #"{"type":"message","message":{"role":"user","content":"Fix the tray hero"}}"#,
            #"{"type":"session_info","name":"Refactor auth module"}"#,
            #"{"type":"session_info","name":""}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.pi])
        let row = try XCTUnwrap(result.rows.first { $0.id == .pi })
        XCTAssertEqual(row.task, "Fix the tray hero", "empty /name clears; /resume shows the first user message")
    }

    func testPiSqliteLatestPromptDoesNotReplaceJSONLResumeTitle() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pi-merge-\(UUID().uuidString)")
        let dbURL = home.appendingPathComponent(".pi/agent/sessions/sessions.db")
        let session = home.appendingPathComponent(
            ".pi/agent/sessions/--Users-me-Pulse--/2024-12-03T14-00-01-000Z_merge-uuid.jsonl"
        )
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        var database: OpaquePointer?
        guard sqlite3_open(dbURL.path, &database) == SQLITE_OK, let database else {
            XCTFail("could not create Pi fixture database")
            return
        }
        defer { sqlite3_close(database) }
        let payload = #"{"type":"message","message":{"role":"user","content":"This later turn is much longer than the opening goal"}}"#
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
              'merge-uuid', '/Users/me/Pulse', '1700000000', '1700000100', 2
            );
            INSERT INTO session_events VALUES (
              1, 'merge-uuid', 'message', '', '\(payload)', '/Users/me/Pulse', '1700000100', 0
            );
            """, nil, nil, nil), SQLITE_OK)
        let lines = [
            #"{"type":"session","id":"merge-uuid","cwd":"/Users/me/Pulse"}"#,
            #"{"type":"message","message":{"role":"user","content":"Fix the tray hero"}}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.pi])
        let titled = result.rows.filter { $0.id == .pi }
        XCTAssertEqual(titled.count, 1)
        XCTAssertEqual(titled.first?.task, "Fix the tray hero")
    }

    func testPiUnclosedEnvironmentContextIsNotTitle() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pi-unclosed-\(UUID().uuidString)")
        let session = home.appendingPathComponent(
            ".pi/agent/sessions/--Users-me-Pulse--/2024-12-03T14-00-01-000Z_sess-unclosed.jsonl"
        )
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let lines = [
            #"{"type":"session","id":"sess-unclosed","cwd":"/Users/me/Pulse"}"#,
            #"{"type":"message","message":{"role":"user","content":"<environment_context>\ncwd: /Users/me/Pulse\nGit: main"}}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.pi])
        let rows = result.rows.filter { $0.id == .pi }
        XCTAssertTrue(rows.isEmpty, "truncated env dump must not become a cwd: tray hero")
    }

    func testNestedMessagesSkipToolResultEnvelopes() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-messages-tool-\(UUID().uuidString)")
        let session = home.appendingPathComponent(".copilot/sessions/sess-tool.json")
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"""
        {
          "sessionId": "cont-1",
          "title": "Copilot session",
          "cwd": "/Users/me/Pulse",
          "messages": [
            {"role": "user", "content": "Keep the real Copilot goal"},
            {"role": "user", "content": {"type": "tool_result", "content": "SEARCH OUTPUT DUMP that used to become the hero"}}
          ]
        }
        """#.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.copilot])
        let row = try XCTUnwrap(result.rows.first { $0.id == .copilot })
        XCTAssertEqual(row.task, "Keep the real Copilot goal")
        XCTAssertFalse(row.task.contains("SEARCH OUTPUT"))
    }

    func testCursorSubtitleIsComposerTitle() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-cursor-sub-\(UUID().uuidString)")
        let user = home.appendingPathComponent("Library/Application Support/Cursor/User", isDirectory: true)
        let dbURL = user.appendingPathComponent("globalStorage/state.vscdb")
        let workspace = user.appendingPathComponent("workspaceStorage/ws-s/workspace.json")
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
        let value = #"{"subtitle":"Fix the composer hero","unifiedMode":"agent"}"#
        let insert = "INSERT INTO composerHeaders VALUES ('composer-sub', 'ws-s', 1700000000000, '\(value.replacingOccurrences(of: "'", with: "''"))', 0, 0);"
        XCTAssertEqual(sqlite3_exec(database, insert, nil, nil, nil), SQLITE_OK)

        let result = NativeActivityHarvest.scan(
            allowAppData: false,
            appDataAgents: [.cursor],
            home: home,
            agentFilter: [.cursor]
        )
        let row = try XCTUnwrap(result.rows.first { $0.id == .cursor })
        XCTAssertEqual(row.task, "Fix the composer hero")
    }

    func testDependingStatusIsNotHarvestPending() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-pending-\(UUID().uuidString)")
        let goose = home.appendingPathComponent(".copilot/session.json")
        try fm.createDirectory(at: goose.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        try #"{"sessionId":"g-dep","title":"Real goose goal","cwd":"/tmp/goose","status":"depending","currentTool":"bash"}"#
            .write(to: goose, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.copilot])
        let row = try XCTUnwrap(result.rows.first { $0.id == .copilot })
        XCTAssertEqual(row.task, "Real goose goal")
        XCTAssertNotEqual(row.skill, "pending", "depending must not substring-match pending")
        XCTAssertEqual(row.phase, "working", "Goose depending is lifecycle busy, not Waiting (0.82)")
    }

    /// 20.0: the JSONL Gemini CLI writes today (chatRecordingService.ts):
    /// tokens, model and completed tool calls ride the `gemini` message; the
    /// same id re-appended replaces the earlier record.
    func testGeminiFunctionCallAndUsageMetadataReachTray() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-gemini-\(UUID().uuidString)")
        let session = home
            .appendingPathComponent(".gemini/tmp/pulse/chats", isDirectory: true)
            .appendingPathComponent("session-2026-09-29T10-15-1a2b3c4d.jsonl")
        let projectRoot = home.appendingPathComponent(".gemini/tmp/pulse/.project_root")
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try "/Users/me/Pulse".write(to: projectRoot, atomically: true, encoding: .utf8)
        let lines = [
            #"{"sessionId":"gem-1","projectHash":"p","startTime":"2026-09-29T10:15:02.114Z","lastUpdated":"2026-09-29T10:15:02.114Z"}"#,
            #"{"id":"u1","timestamp":"2026-09-29T10:15:09.500Z","type":"user","content":[{"text":"Ship fleet substance"}]}"#,
            #"{"$set":{"lastUpdated":"2026-09-29T10:15:09.501Z"}}"#,
            #"{"id":"g1","timestamp":"2026-09-29T10:16:00.000Z","type":"gemini","content":"","thoughts":[],"model":"gemini-2.5-pro"}"#,
            #"{"id":"g1","timestamp":"2026-09-29T10:16:40.020Z","type":"gemini","content":"Fleet shipped.","thoughts":[],"tokens":{"input":800,"output":120,"cached":0,"thoughts":0,"tool":0,"total":920},"model":"gemini-2.5-pro","toolCalls":[{"id":"t1","name":"run_shell_command","args":{},"status":"success","timestamp":"2026-09-29T10:16:30.000Z"}]}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.gemini])
        let rows = result.rows.filter { $0.id == .gemini }
        XCTAssertEqual(rows.count, 1, "one chat, one row — re-appended ids are updates")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.task, "Ship fleet substance")
        XCTAssertEqual(row.lastWord, "Fleet shipped.")
        XCTAssertEqual(row.model, "gemini-2.5-pro")
        XCTAssertEqual(row.tool, "run_shell_command")
        XCTAssertEqual(row.tokensIn, 800)
        XCTAssertEqual(row.tokensOut, 120)
        XCTAssertEqual(row.cwd, "/Users/me/Pulse")
        XCTAssertEqual(row.sessionID, "gem-1")
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

    func testAwaitingUserStatusIsHarvestPending() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-await-\(UUID().uuidString)")
        let goose = home.appendingPathComponent(".copilot/session.json")
        try fm.createDirectory(at: goose.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        try #"{"sessionId":"g-wait","title":"Need approval","cwd":"/tmp/goose","status":"awaiting_user","currentTool":"bash"}"#
            .write(to: goose, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.copilot])
        let row = try XCTUnwrap(result.rows.first { $0.id == .copilot })
        XCTAssertEqual(row.skill, "pending")
    }

    func testWaitingNoneAgentNeverStampsHarvestPending() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-native-waiting-none-\(UUID().uuidString)")
        // 24.0: Codex's hooks never report a block — status words / ask
        // tools in its files must not invent Waiting either.
        let codex = home.appendingPathComponent(".codex/sessions/2026/09/29/rollout-none.jsonl")
        try fm.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        try #"{"session_id":"codex-none","title":"Codex work","cwd":"/tmp/codex","status":"awaiting_user","currentTool":"ask_followup_question"}"#
            .write(to: codex, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.codex])
        let row = try XCTUnwrap(result.rows.first { $0.id == .codex })
        XCTAssertEqual(AgentID.codex.waitingSource, .none)
        XCTAssertNotEqual(row.skill, "pending", "Waiting-none must never stamp harvest pending")
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
        let goose = home.appendingPathComponent(".copilot/session.json")
        try fm.createDirectory(at: goose.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"{"sessionId":"g-name","name":"Need input","cwd":"/tmp/goose","status":"running","currentTool":"bash"}"#
            .write(to: goose, atomically: true, encoding: .utf8)
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.copilot])
        let row = try XCTUnwrap(result.rows.first { $0.id == .copilot })
        XCTAssertEqual(row.task, "Need input")
        XCTAssertEqual(row.cwd, "/tmp/goose")
    }

    // MARK: - 2.2 · a record count is exact or it is not offered

    /// Regression (B-12 / `H-M6`): the Codex parser walked the head 8 lines
    /// plus the last 2,048 of its window and counted them as `records` — a
    /// window figure carrying no truncation flag, published where the tray
    /// renders an exact "N records". Only a later unconditional assignment in
    /// `ingestTranscriptFile` kept it off screen, which is luck, not a rule.
    ///
    /// The rule now: `records` comes from a window that really was the whole
    /// file. Nothing else offers one. This rollout has far more lines than the parser ever looks at, so
    /// a parser-derived count would show 2,056 here instead of the truth.
    func testCodexRecordsCountTheFileNotTheParserWindow() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("pulse-native-codex-records-\(UUID().uuidString)")
        let session = home
            .appendingPathComponent(".codex/sessions/2026/08/18", isDirectory: true)
            .appendingPathComponent("rollout-records.jsonl")
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        var lines = [
            #"{"type":"session_meta","payload":{"session_id":"rec-1","cwd":"/Users/me/Pulse"},"timestamp":1700000000}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Count the records honestly"},"timestamp":1700000001}"#,
        ]
        // Past the parser's 8 + 2,048 candidate window, and well under the
        // 8 MB read window, so the file really is read whole.
        for index in 0..<2_500 {
            lines.append(
                #"{"type":"event_msg","payload":{"type":"token_count","info":{}},"index":\#(index),"timestamp":1700000002}"#
            )
        }
        try (lines.joined(separator: "\n") + "\n").write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(
            home: home,
            agentDeadlineSeconds: 30,
            totalDeadlineSeconds: 60,
            agentFilter: [.codex]
        )
        let row = try XCTUnwrap(result.rows.first { $0.id == .codex })
        XCTAssertEqual(row.task, "Count the records honestly")
        XCTAssertEqual(
            row.records, lines.count,
            "the whole file was read, so the count is the file's — never the parser's candidate slice"
        )
    }

    // MARK: - 2.2 · a workspace path the disk agrees with

    /// Regression (B-13): Claude and Pi name a project directory by replacing
    /// every `/` with `-`, and neither escapes a `-` the path already had.
    /// Expanding every `-` therefore turned `/Users/me/my-project` into
    /// `/Users/me/my/project` — and that is the path Focus opens a terminal
    /// or an IDE on.
    ///
    /// The workspace the name came from exists, so the filesystem settles it.
    func testAHyphenatedWorkspaceIsRestoredFromTheDiskNotFromTheDashes() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("pulse-native-cwdok-\(UUID().uuidString)")
        let workspace = home.appendingPathComponent("work/my-project", isDirectory: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        // Exactly what Claude Code writes for this workspace.
        let encoded = workspace.path.replacingOccurrences(of: "/", with: "-")
        let session = home
            .appendingPathComponent(".claude/projects/\(encoded)", isDirectory: true)
            .appendingPathComponent("sess-cwd.jsonl")
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"type":"user","sessionId":"cwd-1","message":{"role":"user","content":"Land in the right folder"}}"#
            .write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.claude])
        let row = try XCTUnwrap(result.rows.first { $0.id == .claude })
        XCTAssertEqual(
            row.cwd, workspace.path,
            "the hyphen belongs to the folder name, and the disk says so"
        )
        XCTAssertEqual(row.project, "my-project")
        XCTAssertFalse(row.cwdBestEffort, "a confirmed path is safe to land Focus on")
    }

    /// The other half: nothing on disk matches, so the naive decode is kept
    /// for display and marked best-effort. Focus must not land on it.
    func testAWorkspaceTheDiskCannotConfirmIsMarkedBestEffort() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("pulse-native-cwdbe-\(UUID().uuidString)")
        let session = home
            .appendingPathComponent(".claude/projects/-Users-me-code-PulseNoSuchDir", isDirectory: true)
            .appendingPathComponent("sess-be.jsonl")
        try fm.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"{"type":"user","sessionId":"cwd-2","message":{"role":"user","content":"Show it anyway"}}"#
            .write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.claude])
        let row = try XCTUnwrap(result.rows.first { $0.id == .claude })
        XCTAssertEqual(row.cwd, "/Users/me/code/PulseNoSuchDir", "still worth showing")
        XCTAssertTrue(row.cwdBestEffort, "and it says the disk never confirmed it")
    }
}

final class HarvestParsingTests: XCTestCase {
    /// The collector redacts credential-shaped content before a row exists.
    /// 0.99 deleted the legacy wire this used to be asserted through, so it is
    /// asserted where the boundary actually is now: a real scan of a real file.
    func testCollectorRedactsSecretsBeforeARowExists() throws {
        let fakeKey = "sk-proj-ExampleSecret123456789"
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-redact-\(UUID().uuidString)")
        let url = home.appendingPathComponent(".copilot/session.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        try #"{"sessionId":"redact-1","role":"user","content":"Deploy with KEY","cwd":"/tmp/redact"}"#
            .replacingOccurrences(of: "KEY", with: fakeKey)
            .write(to: url, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.copilot])
        let row = try XCTUnwrap(result.rows.first { $0.id == .copilot })
        XCTAssertFalse(row.task.contains(fakeKey))
        XCTAssertTrue(row.task.contains(ContentSanitizer.replacement))
    }

    func testSanitizerKeepsOrdinaryTechnicalText() {
        let safe = "Review token budget for sketch session 550e8400-e29b-41d4-a716-446655440000"
        XCTAssertEqual(ContentSanitizer.redact(safe), safe)
        XCTAssertEqual(
            ContentSanitizer.redact("Authorization: Bearer fakeBearerValue123"),
            "Authorization: Bearer ••••"
        )
        XCTAssertEqual(
            ContentSanitizer.redact("password=hunterExample123"),
            "password=••••"
        )
    }


    /// 23.0: a row key is the vendor's session id, whole — or, without one,
    /// a hash of the transcript path or of where and when the session began.
    func testRowKeysAreStableAndNeverCarryAPath() {
        let long = String(repeating: "a", count: 40)
        let key = RowIdentity.session(agent: .claude, sessionID: long)
        XCTAssertEqual(key, "claude|" + long)
        XCTAssertEqual(key, RowIdentity.session(agent: .claude, sessionID: long), "same input, same key")
        let placed = RowIdentity.session(agent: .codex, sessionID: "", cwd: "/a/b/Repo", startedMs: 5)
        XCTAssertTrue(placed.hasPrefix("codex|at:"))
        XCTAssertFalse(placed.contains("Repo"), "a key never carries a path")
        XCTAssertEqual(RowIdentity.session(agent: .codex, sessionID: ""), "codex|anon")
    }

    func testFreshnessRequiresAMtimeUnlessSubagentsAreRunning() {
        let now: Int64 = 1_700_000_000_000
        var row = ActivityHarvest.Row(id: .claude, task: "t", project: "", cwd: "", skill: "")
        XCTAssertFalse(ActivityHarvest.isFresh(row, nowMs: now), "no mtime is not a running signal")

        row.subRunning = 1
        XCTAssertTrue(ActivityHarvest.isFresh(row, nowMs: now))

        row.subRunning = 0
        row.harvestMs = now - 1000
        XCTAssertTrue(ActivityHarvest.isFresh(row, nowMs: now))

        row.harvestMs = now - ActivityHarvest.freshWindowMs - 1
        XCTAssertFalse(ActivityHarvest.isFresh(row, nowMs: now))
    }

    func testFarFutureActivityTimestampIsNotFresh() {
        let now: Int64 = 1_700_000_000_000
        var row = ActivityHarvest.Row(id: .codex, task: "t", project: "", cwd: "", skill: "")
        row.harvestMs = now + 5 * 60 * 1000 + 1
        XCTAssertFalse(ActivityHarvest.isFresh(row, nowMs: now))
    }

    func testCursorLocalSessionsUseBoundedWorkWindow() {
        let now: Int64 = 1_700_000_000_000
        var cursor = ActivityHarvest.Row(id: .cursor, task: "Local task", project: "", cwd: "", skill: "")
        cursor.mode = "local"
        cursor.harvestMs = now - ActivityHarvest.freshWindowMs - 1
        XCTAssertTrue(ActivityHarvest.isFresh(cursor, nowMs: now))

        cursor.harvestMs = now - ActivityHarvest.cursorLocalWindowMs - 1
        XCTAssertFalse(ActivityHarvest.isFresh(cursor, nowMs: now))

        var generic = cursor
        generic.id = .gemini
        generic.harvestMs = now - ActivityHarvest.freshWindowMs - 1
        XCTAssertFalse(ActivityHarvest.isFresh(generic, nowMs: now))
    }

    func testHealthCompletenessRequiresEveryUserFacingCollector() {
        let unscanned = ActivityHarvest.expectedCollectorIDs.map { ActivityHarvest.CollectorHealth.unscanned($0) }
        XCTAssertFalse(ActivityHarvest.isCompleteHealth(unscanned), "unscanned is an incomplete bounded scan")
        let complete = unscanned.map {
            ActivityHarvest.CollectorHealth(
                id: $0.id,
                state: .sourceAbsent,
                durationMs: 1,
                rowCount: 0,
                sourcePresent: false,
                errorKind: ""
            )
        }
        XCTAssertTrue(ActivityHarvest.isCompleteHealth(complete))
        XCTAssertFalse(ActivityHarvest.isCompleteHealth(Array(complete.dropLast())))
    }

    func testPartialHarvestKeepsAdaptersTheChildNeverReached() {
        let oldCodex = ActivityHarvest.Row(
            id: .codex,
            task: "Keep this session visible",
            project: "Pulse",
            cwd: "/Users/me/Pulse",
            skill: "",
            harvestMs: 1_700_000_000_000,
            sessionID: "codex-old"
        )
        let oldPi = ActivityHarvest.Row(
            id: .pi,
            task: "Replace after Pi reports",
            project: "Pulse",
            cwd: "/Users/me/Pulse",
            skill: "",
            harvestMs: 1_700_000_000_000,
            sessionID: "pi-old"
        )
        var freshCodex = oldCodex
        freshCodex.task = "Fresh Codex evidence"
        freshCodex.sessionID = "codex-new"
        let health = [
            ActivityHarvest.CollectorHealth(
                id: .codex,
                state: .observed,
                durationMs: 10,
                rowCount: 1,
                sourcePresent: true,
                errorKind: ""
            )
        ]

        let merged = ActivityHarvest.mergePartialRows(
            current: [freshCodex],
            health: health,
            previous: [oldCodex, oldPi]
        )

        XCTAssertEqual(merged.map(\.sessionID), ["codex-new", "pi-old"])
        XCTAssertFalse(merged.contains { $0.sessionID == "codex-old" })
    }

    func testAnAdapterThatTimedOutMidwayKeepsItsUnreachedSessions() {
        func codex(_ session: String, _ task: String) -> ActivityHarvest.Row {
            ActivityHarvest.Row(
                id: .codex, task: task, project: "Pulse", cwd: "/Users/me/Pulse",
                skill: "", harvestMs: 1_700_000_000_000, sessionID: session
            )
        }
        let previous = [codex("a", "old a"), codex("b", "old b"), codex("c", "old c")]
        let health = [
            ActivityHarvest.CollectorHealth(
                id: .codex, state: .failed, durationMs: 750, rowCount: 1,
                sourcePresent: true, errorKind: "native_timeout"
            )
        ]
        let merged = ActivityHarvest.mergePartialRows(
            current: [codex("a", "fresh a")], health: health, previous: previous
        )
        XCTAssertEqual(Set(merged.map(\.sessionID)), ["a", "b", "c"])
        XCTAssertEqual(merged.first { $0.sessionID == "a" }?.task, "fresh a", "fresh evidence wins")
        XCTAssertEqual(merged.filter { $0.sessionID == "a" }.count, 1, "no stale duplicate")
    }

    func testPartialHarvestWithNoAdapterBoundaryDoesNotEraseSnapshot() {
        var previous = ActivityHarvest.Row(
            id: .cursor,
            task: "Cursor task",
            project: "Client",
            cwd: "/Users/me/Client",
            skill: "",
            harvestMs: 1_700_000_000_000,
            sessionID: "cursor-1"
        )
        previous.mode = "local"
        let merged = ActivityHarvest.mergePartialRows(
            current: [],
            health: [],
            previous: [previous]
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.sessionID, previous.sessionID)
        XCTAssertEqual(merged.first?.task, previous.task)
        XCTAssertEqual(merged.first?.mode, previous.mode)
    }

    func testFailedEmptyAdapterRetainsLastGoodRowsUntilRetry() {
        let previous = ActivityHarvest.Row(
            id: .copilot,
            task: "Keep command session visible",
            project: "Pulse",
            cwd: "/Users/me/Pulse",
            skill: "",
            harvestMs: 1_700_000_000_000,
            sessionID: "command-old"
        )
        let health = [
            ActivityHarvest.CollectorHealth(
                id: .copilot,
                state: .failed,
                durationMs: 750,
                rowCount: 0,
                sourcePresent: true,
                errorKind: "native_timeout"
            )
        ]

        let merged = ActivityHarvest.mergePartialRows(
            current: [],
            health: health,
            previous: [previous]
        )

        XCTAssertEqual(merged.map(\.sessionID), ["command-old"])
    }

    func testEmptyPartialIssueBoundariesRetainLastGoodRows() {
        let previous = ActivityHarvest.Row(
            id: .cursor,
            task: "Keep Cursor session visible",
            project: "Client",
            cwd: "/Users/me/Client",
            skill: "",
            harvestMs: 1_700_000_000_000,
            sessionID: "cursor-old"
        )
        let states: [ActivityHarvest.CollectorState] = [
            .permissionDenied, .schemaMismatch, .unscanned,
        ]

        for state in states {
            let health = [ActivityHarvest.CollectorHealth(
                id: .cursor,
                state: state,
                durationMs: 10,
                rowCount: 0,
                sourcePresent: true,
                errorKind: "boundary"
            )]
            let merged = ActivityHarvest.mergePartialRows(
                current: [],
                health: health,
                previous: [previous]
            )
            XCTAssertEqual(
                merged.map(\.sessionID),
                ["cursor-old"],
                "empty \(state.rawValue) must not erase prior evidence"
            )
        }
    }

    func testAttentionFutureEventIsIgnored() {
        let now: Int64 = 1_700_000_000_000
        let text = "codex\tpermission\t\(now + 6 * 60 * 1000)\tApprove\tsession-1\t/Users/me/Pulse\t\t\t\t\n"
        XCTAssertTrue(AttentionReader.parse(text, nowMs: now).isEmpty)
    }

    func testCompletionClassificationUsesPhaseOrOutcome() {
        var row = ActivityHarvest.Row(id: .codex, task: "", project: "", cwd: "", skill: "")
        XCTAssertFalse(row.isCompleted)
        row.phase = "turn_complete"
        XCTAssertTrue(row.isCompleted)
        row.phase = ""
        row.outcome = "failed"
        XCTAssertTrue(row.isCompleted)
    }

    func testAgentAliasMapping() {
        XCTAssertEqual(ActivityHarvest.mapAgent("cursor_agent"), .cursor)
        XCTAssertEqual(ActivityHarvest.mapAgent("cursor-agent"), .cursor)
        XCTAssertEqual(ActivityHarvest.mapAgent("opencode"), .opencode)
        XCTAssertNil(ActivityHarvest.mapAgent("goose"), "24.0: an unsupported agent is not mapped")
        XCTAssertNil(ActivityHarvest.mapAgent("definitely-not-an-agent"))
    }
}

/// 0.98 Ground Truth — the collector can be held to account.
///
/// Every test here runs the real `NativeActivityHarvest.scan` against real
/// files at real paths. They cover the four things that made 0.96.1 through
/// 0.97.2 ship green with a wrong tray hero, plus the counting and fairness
/// defects found beside them.
final class HarvestEvidenceTests: XCTestCase {

    private func makeHome(_ label: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-ground-truth-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ text: String, to home: URL, _ relative: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - A starved budget is not an empty source

    /// Regression: when the global byte budget ran low (but not to zero),
    /// `reserve` refused the file read silently, the adapter classified as
    /// `no_sessions`, and mergePartialRows treated that as a trusted empty —
    /// clearing the previous good rows. A refused read must classify as
    /// `failed` so the last snapshot survives.
    func testABudgetDenialNeverReportsNoSessions() throws {
        let home = try makeHome("budget")
        defer { try? FileManager.default.removeItem(at: home) }
        let lines = [
            #"{"sessionId":"gt-b","title":"Real session","cwd":"/tmp/gt-budget"}"#,
            #"{"sessionId":"gt-b","role":"user","content":"Do the thing"}"#,
        ].joined(separator: "\n") + "\n"
        try write(lines, to: home, ".copilot/session.jsonl")

        // Sanity: a normal budget observes the session.
        let healthy = NativeActivityHarvest.scan(home: home, agentFilter: [.copilot])
        XCTAssertEqual(healthy.health.first { $0.id == .copilot }?.state, .observed)

        // Low-but-not-empty: the budget is alive, the file just does not fit.
        let starved = NativeActivityHarvest.scan(
            home: home,
            agentFilter: [.copilot],
            totalBudgetBytes: 8
        )
        let health = try XCTUnwrap(starved.health.first { $0.id == .copilot })
        XCTAssertNotEqual(
            health.state, .noSessions,
            "a refused read says something about resources, not about sessions"
        )
        XCTAssertEqual(health.state, .failed, "failed keeps the previous rows through the partial merge")
    }

    // MARK: - Hero selection is ordinal, not lexical

    /// The regression that cost four releases: a long vendor headline beat a
    /// short real goal because `preferTask` ended in a length comparison.
    func testShortUserPromptBeatsLongVendorHeadline() throws {
        let home = try makeHome("origin")
        defer { try? FileManager.default.removeItem(at: home) }
        let lines = [
            #"{"sessionId":"gt-1","title":"Session 4 — automated maintenance sweep across the whole repository","cwd":"/tmp/gt-origin"}"#,
            #"{"sessionId":"gt-1","role":"user","content":"Fix it"}"#,
        ].joined(separator: "\n") + "\n"
        try write(lines, to: home, ".copilot/session.jsonl")

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.copilot])
        let row = try XCTUnwrap(result.rows.first { $0.id == .copilot })
        XCTAssertEqual(
            row.task, "Fix it",
            "a user turn outranks a cache headline regardless of length"
        )
    }

    /// The same comparison in the other direction: when nothing better exists,
    /// the headline is still a legitimate hero.
    func testVendorHeadlineSurvivesWhenThereIsNoUserTurn() throws {
        let home = try makeHome("headline")
        defer { try? FileManager.default.removeItem(at: home) }
        try write(
            #"{"sessionId":"gt-2","title":"Automated maintenance sweep","cwd":"/tmp/gt-headline"}"#,
            to: home,
            ".copilot/session.json"
        )

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.copilot])
        let row = try XCTUnwrap(result.rows.first { $0.id == .copilot })
        XCTAssertEqual(row.task, "Automated maintenance sweep")
    }

    func testTaskOriginRanksUserGoalsOverVendorChrome() {
        XCTAssertLessThan(NativeActivityHarvest.TaskOrigin.chrome, .cacheTitle)
        XCTAssertLessThan(NativeActivityHarvest.TaskOrigin.cacheTitle, .toolTitle)
        XCTAssertLessThan(NativeActivityHarvest.TaskOrigin.toolTitle, .userPrompt)
        XCTAssertLessThan(NativeActivityHarvest.TaskOrigin.userPrompt, .sessionName)
    }

    // MARK: - One chrome vocabulary

    /// `isChromeTask` knew about `cascade session`; the copy inlined in
    /// `makeRows` did not, so the same placeholder was chrome in a merge and a
    /// legitimate hero at row admission.
    func testPlaceholderTitleIsRejectedAtRowAdmission() throws {
        let home = try makeHome("chrome")
        defer { try? FileManager.default.removeItem(at: home) }
        try write(
            #"{"sessionId":"gt-3","title":"Cascade session"}"#,
            to: home,
            ".copilot/session.json"
        )

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.copilot])
        XCTAssertFalse(
            result.rows.contains { $0.task.lowercased() == "cascade session" },
            "a vendor placeholder with no other fact is not a session"
        )
    }

    // MARK: - Counts are exact or unknown

    func testWholeFileWindowStillCountsRecords() throws {
        let home = try makeHome("records-small")
        defer { try? FileManager.default.removeItem(at: home) }
        let line = #"{"sessionId":"gt-4","role":"user","content":"Small transcript","cwd":"/tmp/gt-small"}"#
        try write(
            Array(repeating: line, count: 12).joined(separator: "\n") + "\n",
            to: home,
            ".copilot/session.jsonl"
        )

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.copilot])
        let row = try XCTUnwrap(result.rows.first { $0.id == .copilot })
        XCTAssertEqual(row.records, 12, "an untruncated file reports its real record count")
    }

    // MARK: - Budget starvation rotates

    /// Adapter order was the literal order of `descriptors()`, so a budget
    /// cutoff always fell in the same place and the tail adapters were
    /// `unscanned` on every refresh, forever.
    func testStartCursorRotatesWhichAdapterGoesFirst() throws {
        let home = try makeHome("rotate")
        defer { try? FileManager.default.removeItem(at: home) }

        let filter: Set<AgentID> = [.claude, .codex, .copilot]
        let first = NativeActivityHarvest.scan(home: home, agentFilter: filter, startCursor: 0)
        let rotated = NativeActivityHarvest.scan(home: home, agentFilter: filter, startCursor: 1)
        let firstOrder = first.health.map(\.id)
        let rotatedOrder = rotated.health.map(\.id)

        XCTAssertEqual(firstOrder.count, 3)
        XCTAssertEqual(Set(firstOrder), Set(rotatedOrder), "rotation reorders, it never drops")
        XCTAssertNotEqual(
            firstOrder.first, rotatedOrder.first,
            "the next scan starts where the previous one gave up"
        )
    }

    /// The cursor names a place in the stable adapter list. When the
    /// supervisor defers a different set next scan, it still resumes at the
    /// adapter that was cut off, not at whatever now sits at the same index.
    func testRotationResumesAtTheSameAdapterWhenTheFilterChanges() {
        // Stable indices of the adapters this pass attempts; 4 was cut off
        // last time. Adapter 2 is now deferred, which shifts every index in
        // the filtered list — the old code would have started at 5.
        XCTAssertEqual(
            NativeActivityHarvest.rotationOffset(filteredStableIndices: [0, 1, 3, 4, 5], cursor: 4), 3
        )
        // The cut-off adapter itself is deferred now: start at the next one.
        XCTAssertEqual(
            NativeActivityHarvest.rotationOffset(filteredStableIndices: [0, 1, 5], cursor: 4), 2
        )
        // Past the end wraps to the head.
        XCTAssertEqual(
            NativeActivityHarvest.rotationOffset(filteredStableIndices: [0, 1], cursor: 9), 0
        )
    }

    func testCompleteScanRewindsTheCursor() throws {
        let home = try makeHome("cursor")
        defer { try? FileManager.default.removeItem(at: home) }
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.copilot])
        XCTAssertEqual(
            result.nextCursor, 0,
            "a pass that reached every adapter starts the next one at the head"
        )
    }

    // MARK: - The collector explains itself

    func testExplainNamesTheRecordKindBehindTheHero() throws {
        let home = try makeHome("explain-hero")
        defer { try? FileManager.default.removeItem(at: home) }
        try write(
            #"{"sessionId":"gt-6","role":"user","content":"Explain the hero","cwd":"/tmp/gt-explain"}"#,
            to: home,
            ".copilot/session.json"
        )

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.copilot])
        let health = try XCTUnwrap(result.health.first { $0.id == .copilot })
        XCTAssertEqual(health.explain.heroOrigin, "user_prompt")
        XCTAssertEqual(health.explain.emptyReason, "")
        XCTAssertGreaterThan(health.explain.filesRead, 0)
        XCTAssertGreaterThan(health.explain.bytesRead, 0)
        XCTAssertTrue(health.explain.summary.contains("hero=user_prompt"))
    }

    func testExplainSaysWhyThereIsNoHero() throws {
        let home = try makeHome("explain-empty")
        defer { try? FileManager.default.removeItem(at: home) }

        // Pi's CLI is not on a CI runner, so an empty home can only be
        // `source_absent` — the reason stays deterministic there.
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.pi])
        let health = try XCTUnwrap(result.health.first { $0.id == .pi })
        XCTAssertEqual(health.state, .sourceAbsent)
        XCTAssertEqual(health.explain.emptyReason, "no_source")
        XCTAssertEqual(health.explain.heroOrigin, "")
    }

    func testExplainFlagsATruncatedRead() throws {
        let home = try makeHome("explain-truncated")
        defer { try? FileManager.default.removeItem(at: home) }
        let filler = String(repeating: "padding ", count: 160)
        var lines = [
            #"{"sessionId":"gt-7","role":"user","content":"Truncated goal","cwd":"/tmp/gt-trunc"}"#
        ]
        for index in 0..<900 {
            lines.append(#"{"sessionId":"gt-7","type":"note","index":\#(index),"text":"\#(filler)"}"#)
        }
        try write(lines.joined(separator: "\n") + "\n", to: home, ".copilot/session.jsonl")

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.copilot])
        let health = try XCTUnwrap(result.health.first { $0.id == .copilot })
        XCTAssertTrue(health.explain.truncated)
        XCTAssertTrue(health.explain.summary.contains("truncated"))
    }

    // MARK: - 2.2 · which sessions the read budget is spent on

    /// Regression (B-8 / `H-M2`): the bounded walk read transcripts in
    /// whatever order the filesystem handed them back, and stopped when it hit
    /// its cap. Filesystem order is neither time order nor stable, so on a
    /// heavy user's machine — Claude and Codex cross the cap within a couple
    /// of months — "was the session you are actually running scanned?" was a
    /// question about directory layout. Pi was fixed for exactly this in 0.97
    /// and the fix was never generalised.
    ///
    /// The rows read must therefore be the newest ones, contiguously: a gap
    /// in the sequence means something older displaced something newer.
    func testTheReadBudgetIsSpentOnTheNewestSessions() throws {
        let home = try makeHome("mtime-order")
        defer { try? FileManager.default.removeItem(at: home) }

        let total = 500
        let clock = Date()
        for index in 0..<total {
            let id = String(format: "gt-order-%03d", index)
            let relative = ".copilot/sessions/\(id).jsonl"
            try write(
                #"{"sessionId":"\#(id)","role":"user","content":"Session \#(id)","cwd":"/tmp/gt-order"}"# + "\n",
                to: home,
                relative
            )
            // 0 is the newest, `total - 1` the oldest; all inside the
            // freshness window so nothing is skipped for age.
            try FileManager.default.setAttributes(
                [.modificationDate: clock.addingTimeInterval(-60 * Double(index))],
                ofItemAtPath: home.appendingPathComponent(relative).path
            )
        }

        // Generous deadlines: this asserts which files were chosen, not how
        // fast the runner is.
        let result = NativeActivityHarvest.scan(
            home: home,
            agentDeadlineSeconds: 60,
            totalDeadlineSeconds: 120,
            agentFilter: [.copilot]
        )
        let indices = result.rows
            .filter { $0.id == .copilot }
            .compactMap { Int($0.sessionID.dropFirst("gt-order-".count)) }
            .sorted()

        XCTAssertFalse(indices.isEmpty, "the adapter read something")
        XCTAssertLessThan(
            indices.count, total,
            "the per-agent file cap must actually bite, or this proves nothing"
        )
        XCTAssertEqual(indices.first, 0, "the newest session is never the one left out")
        XCTAssertEqual(
            indices, Array(0..<indices.count),
            "the sessions read are exactly the newest N — a gap means an older file took a live one's place"
        )
    }

    // MARK: - 2.2 · Waiting is never inferred from prose

    /// Regression (B-11 / `H-M5`): the free-text fallback parser raised
    /// `skill=pending` from a `"status": "waiting"` regex match. It runs on
    /// `.md` / `.txt` / `.log` files and on JSON no real parser could read,
    /// where it cannot tell a session's own state from one quoted inside it —
    /// so a design note describing the attention bridge lit a red lamp.
    ///
    /// Waiting comes from hooks or a structured `skill=pending`, never from
    /// inference. The fallback may still supply display fields.
    func testAQuotedStatusInProseNeverLightsWaiting() throws {
        let home = try makeHome("prose-pending")
        defer { try? FileManager.default.removeItem(at: home) }
        // Deliberately not a JSON document and with no line that parses as
        // one: this is the path where only the regex fallback runs.
        let note = """
        # Attention bridge notes

        A raised event carries "sessionId": "gt-prose-1" and "cwd": "/tmp/gt-prose"
        alongside "status": "waiting" — written here as documentation of the
        wire format, not as a statement about this machine.
        """
        try write(note, to: home, ".copilot/notes.md")

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.copilot])
        let row = try XCTUnwrap(result.rows.first { $0.id == .copilot })
        XCTAssertEqual(row.cwd, "/tmp/gt-prose", "display fields still travel")
        XCTAssertNotEqual(
            row.skill, "pending",
            "a status quoted in prose is not this session's status"
        )
    }
}

/// Clarity fixes — each test pins one defect found by reading the code: the
/// value the user would have seen, before and after.
@MainActor
@Suite("Harvest fixes", .serialized)
struct HarvestFixTests {
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

        func database(_ relative: String, _ statements: [String]) throws {
            let file = url.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var db: OpaquePointer?
            guard sqlite3_open(file.path, &db) == SQLITE_OK, let db else { throw CocoaError(.fileWriteUnknown) }
            defer { sqlite3_close(db) }
            for sql in statements {
                guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "clarity", code: 1, userInfo: [NSLocalizedDescriptionKey: sql])
                }
            }
        }

        func rows(_ id: AgentID) -> [ActivityHarvest.Row] {
            NativeActivityHarvest.scan(
                allowAppData: true, appDataAgents: [id], home: url, agentFilter: [id]
            ).rows.filter { $0.id == id }
        }
    }

    func session(_ id: AgentID, _ sessionID: String, skill: String = "", ageMs: Int64 = 70_000) -> ActivityHarvest.Row {
        ActivityHarvest.Row(
            id: id, task: "Fix the login flow", project: "p", cwd: "/p", skill: skill,
            tool: "", harvestMs: now - ageMs, subRunning: 0, subTotal: 0, sessionID: sessionID,
            evidence: .session
        )
    }

    // MARK: - 3 / 19 · walks skip what is read another way

    @Test func claudeSubagentTranscriptsNeverSpeakForTheParent() throws {
        let home = Home()
        let project = ".claude/projects/-Users-me-app"
        let base = Date().addingTimeInterval(-120)
        try home.write("\(project)/sess-1.jsonl", [
            #"{"type":"user","sessionId":"sess-1","cwd":"/Users/me/app","message":{"role":"user","content":"Add an offline queue for login"}}"#,
            #"{"type":"assistant","sessionId":"sess-1","cwd":"/Users/me/app","message":{"role":"assistant","content":[{"type":"text","text":"The queue drains on reconnect."}]}}"#,
        ].joined(separator: "\n") + "\n", modified: base)
        try home.write("\(project)/sess-1/subagents/agent-a1.jsonl", [
            #"{"type":"user","isSidechain":true,"sessionId":"sess-1","cwd":"/Users/me/app","message":{"role":"user","content":"Search the repo for retry helpers"}}"#,
            #"{"type":"assistant","isSidechain":true,"sessionId":"sess-1","cwd":"/Users/me/app","message":{"role":"assistant","content":[{"type":"text","text":"Found three helpers."}]}}"#,
        ].joined(separator: "\n") + "\n")
        let rows = home.rows(.claude)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.lastWord == "The queue drains on reconnect.")
        #expect(row.task == "Add an offline queue for login")
        #expect(row.subTotal == 1, "still counted, by its own reader")
    }

    @Test func walksNameTheDirectoriesTheyLeaveToTheirReaders() {
        #expect(AgentID.claude.spec.walk.skippedDirectoryNames.contains("subagents"))
    }

    // MARK: - 4 · Pi follows the active branch

    static let piPath = "/h/.pi/agent/sessions/--Users-me-app--/2026-09-29T10-00-00-000Z_0199a1b2-c3d4-7e5f-8a6b-7c8d9e0f1a2b.jsonl"
    static let piHeader = #"{"type":"session","version":3,"id":"0199a1b2-c3d4-7e5f-8a6b-7c8d9e0f1a2b","timestamp":"2026-09-29T10:00:00.000Z","cwd":"/Users/me/app"}"#

    static func piMessage(_ id: String, parent: String?, role: String, _ text: String, second: Int) -> String {
        let parentJSON = parent.map { "\"\($0)\"" } ?? "null"
        return #"{"type":"message","id":"\#(id)","parentId":\#(parentJSON),"timestamp":"2026-09-29T10:00:\#(String(format: "%02d", second)).000Z","message":{"role":"\#(role)","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    @Test func piLastWordFollowsTheBranchTheUserIsOn() throws {
        let text = [
            Self.piHeader,
            Self.piMessage("a1", parent: nil, role: "user", "Add an offline queue for login", second: 1),
            Self.piMessage("b1", parent: "a1", role: "assistant", "Two ways to do it.", second: 2),
            Self.piMessage("c1", parent: "b1", role: "user", "Try the first way", second: 3),
            Self.piMessage("d1", parent: "c1", role: "assistant", "The first way broke login.", second: 4),
            // /tree back to b1 and continue from there.
            Self.piMessage("e1", parent: "b1", role: "user", "Try the second way", second: 5),
        ].joined(separator: "\n")
        let fact = try #require(NativeActivityHarvest.parsePiFacts(text, path: Self.piPath).first)
        #expect(fact.lastWord == "Two ways to do it.", "the abandoned branch's reply is not this session's last word")
    }

    @Test func piTitleComesFromTheActiveBranch() throws {
        let text = [
            Self.piHeader,
            Self.piMessage("a1", parent: nil, role: "user", "Rewrite the parser", second: 1),
            Self.piMessage("b1", parent: "a1", role: "assistant", "Started on the parser.", second: 2),
            Self.piMessage("c1", parent: nil, role: "user", "Add an offline queue for login", second: 3),
            Self.piMessage("d1", parent: "c1", role: "assistant", "Queue added.", second: 4),
        ].joined(separator: "\n")
        let fact = try #require(NativeActivityHarvest.parsePiFacts(text, path: Self.piPath).first)
        #expect(fact.task == "Add an offline queue for login")
        #expect(fact.lastWord == "Queue added.")
    }

    @Test func piAcceptsWhatTheWindowCutAwayFrom() throws {
        let text = [
            Self.piHeader,
            Self.piMessage("a1", parent: nil, role: "user", "Add an offline queue for login", second: 1),
            // …the middle of the file is outside the read window…
            Self.piMessage("z9", parent: "y8", role: "assistant", "Queue added.", second: 9),
        ].joined(separator: "\n")
        let fact = try #require(NativeActivityHarvest.parsePiFacts(text, path: Self.piPath).first)
        #expect(fact.task == "Add an offline queue for login", "a broken chain cannot place the head, so it is kept")
        #expect(fact.lastWord == "Queue added.")
    }

    // MARK: - 7 · merge takes "now" from the newer fragment

    @Test func mergeTakesNowFactsFromTheNewerFragmentWhateverTheOrder() throws {
        var newer = NativeActivityHarvest.Fact()
        newer.sessionID = "s1"
        newer.activityMs = now
        newer.tool = "Bash"
        newer.model = "model-new"
        newer.mode = "plan"
        newer.tokensIn = 10
        newer.planStep = "Running the gates"
        newer.progressDone = 3
        newer.progressTotal = 4
        newer.lastErrorText = "exit 2"
        var older = NativeActivityHarvest.Fact()
        older.sessionID = "s1"
        older.activityMs = now - 10 * Self.minute
        older.tool = "Read"
        older.model = "model-old"
        older.mode = "code"
        older.tokensIn = 99
        older.planStep = "Fixing the parser"
        older.progressDone = 1
        older.progressTotal = 9
        older.lastErrorText = "exit 1"

        let merged = try #require(NativeActivityHarvest.merge([newer, older]).first)
        #expect(merged.tool == "Bash")
        #expect(merged.model == "model-new")
        #expect(merged.mode == "plan")
        #expect(merged.tokensIn == 10)
        #expect(merged.planStep == "Running the gates")
        #expect(merged.progressDone == 3 && merged.progressTotal == 4, "one plan, not one list's count with another's step")
        #expect(merged.lastErrorText == "exit 2")
    }

    // MARK: - 8 · Pi's event count is not plan progress

    @Test func piEventCountIsNotAProgressBar() throws {
        let home = Home()
        try home.database(".pi/agent/sessions/sessions.db", [
            "CREATE TABLE session_meta (session_id TEXT, project_dir TEXT, started_at TEXT, last_event_at TEXT, event_count INTEGER);",
            "CREATE TABLE session_events (id INTEGER PRIMARY KEY, session_id TEXT, type TEXT, category TEXT, data TEXT, project_dir TEXT, created_at TEXT, bytes_returned INTEGER);",
            "INSERT INTO session_meta VALUES ('pi-count', '/Users/me/app', '1700000000', '1700000100', 412);",
        ])
        let row = try #require(home.rows(.pi).first)
        #expect(row.progressTotal == 0)
        #expect(row.progressDone == 0)
    }
}

/// 0.94 Waiting Proof — harvest ask → tray Waiting → dismiss → clear → re-raise,
/// Attention raise→clear for Waiting-none, and honesty guards (no fake Waiting).
final class HarvestPendingTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000

    @MainActor
    private func harvest(
        _ id: AgentID,
        task: String = "Ask",
        session: String = "s1",
        cwd: String = "/Users/me/Pulse",
        skill: String = "",
        tool: String = "",
        evidence: ObservationSource = .cache,
        ageMs: Int64 = 1_000,
        phase: String = ""
    ) -> ActivityHarvest.Row {
        var row = ActivityHarvest.Row(
            id: id, task: task, project: "", cwd: cwd, skill: skill,
            tool: tool, harvestMs: now - ageMs,
            subRunning: 0, subTotal: 0, sessionID: session,
            evidence: evidence
        )
        row.phase = phase
        return row
    }

    // MARK: P0-2 harvest stamp honesty

    @MainActor
    func testBlockedOnUserFlagStampsPending() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-proof-blocked-\(UUID().uuidString)")
        let goose = home.appendingPathComponent(".copilot/session.json")
        try fm.createDirectory(at: goose.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"{"sessionId":"g-block","title":"Need you","cwd":"/tmp/g","status":"running","isBlockedOnUser":true}"#
            .write(to: goose, atomically: true, encoding: .utf8)
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.copilot])
        let row = try XCTUnwrap(result.rows.first { $0.id == .copilot })
        XCTAssertEqual(row.skill, "pending")
    }

    @MainActor
    func testAskUserQuestionToolStampsPending() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-proof-asktool-\(UUID().uuidString)")
        let goose = home.appendingPathComponent(".copilot/session.json")
        try fm.createDirectory(at: goose.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"{"sessionId":"g-ask","title":"Question","cwd":"/tmp/g","status":"running","currentTool":"ask_user_question"}"#
            .write(to: goose, atomically: true, encoding: .utf8)
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.copilot])
        let row = try XCTUnwrap(result.rows.first { $0.id == .copilot })
        XCTAssertEqual(row.skill, "pending")
    }

    @MainActor
    func testWaitingNoneStillNeverStampsHarvestPending() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-proof-none-\(UUID().uuidString)")
        let codex = home.appendingPathComponent(".codex/sessions/2026/09/29/rollout-z.jsonl")
        try fm.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"{"session_id":"z-1","title":"Codex work","cwd":"/tmp/z","status":"awaiting_user","currentTool":"ask_followup_question","isWaitingForResponse":true}"#
            .write(to: codex, atomically: true, encoding: .utf8)
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.codex])
        let row = try XCTUnwrap(result.rows.first { $0.id == .codex })
        XCTAssertNotEqual(row.skill, "pending")
    }
}

/// 0.95 Extinguish Honesty — false Waiting must not light; clear stays clear
/// until genuine new evidence.
final class HarvestAnsweredAskTests: XCTestCase {
    // MARK: Answered ask / terminal veto

    @MainActor
    func testAnsweredAskWithStaleAskToolDoesNotStampPending() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-extinguish-answered-\(UUID().uuidString)")
        let goose = home.appendingPathComponent(".copilot/session.json")
        try fm.createDirectory(at: goose.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"""
        {"sessionId":"g-ans","title":"Answered","cwd":"/tmp/g","status":"running",
         "ask":"followup","askResponse":"messageResponse","currentTool":"ask_followup_question"}
        """#.write(to: goose, atomically: true, encoding: .utf8)
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.copilot])
        let row = try XCTUnwrap(result.rows.first { $0.id == .copilot })
        XCTAssertNotEqual(row.skill, "pending", "askResponse must veto ask-tool pending")
    }

    @MainActor
    func testCompletedStatusWithAskToolDoesNotStampPending() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-extinguish-done-\(UUID().uuidString)")
        let goose = home.appendingPathComponent(".copilot/session.json")
        try fm.createDirectory(at: goose.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"""
        {"sessionId":"g-done","title":"Done","cwd":"/tmp/g","status":"completed",
         "currentTool":"ask_user_question"}
        """#.write(to: goose, atomically: true, encoding: .utf8)
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.copilot])
        let row = try XCTUnwrap(result.rows.first { $0.id == .copilot })
        XCTAssertNotEqual(row.skill, "pending")
    }

    @MainActor
    func testConflictingBoolFlagsAnyTrueWins() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-extinguish-flags-\(UUID().uuidString)")
        let goose = home.appendingPathComponent(".copilot/session.json")
        try fm.createDirectory(at: goose.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try #"""
        {"sessionId":"g-flag","title":"Block","cwd":"/tmp/g","status":"running",
         "needsApproval":false,"isBlockedOnUser":true}
        """#.write(to: goose, atomically: true, encoding: .utf8)
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.copilot])
        let row = try XCTUnwrap(result.rows.first { $0.id == .copilot })
        XCTAssertEqual(row.skill, "pending")
    }
}

/// 0.99 Quiet Data — what Pulse writes down, and whether it says so.
///
/// 0.90–0.97 made the display honest and 0.98 made the collector honest. These
/// cover the surface neither of them touched: the bytes that outlive the scan.
final class ChromeVocabularyTests: XCTestCase {
    // MARK: - One chrome vocabulary, not three

    /// 0.98 collapsed the collector's two copies. The third lived in
    /// `usefulTask`, was case-sensitive where the collector lowercases, and had
    /// never learned `Cascade session`.
    @MainActor
    func testChromeTitlesAreRejectedWhateverTheirCase() {
        for title in ["Cascade session", "CASCADE SESSION", "cascade session",
                      "New Chat", "new chat", "Running", "running", "  Untitled  "] {
            var row = AgentRow(rowKey: "k", agent: .copilot)
            row.task = title
            XCTAssertNil(row.usefulTask, "\(title) is not a user goal")
        }
    }

    /// The collector and the row must agree on every entry. Two lists that
    /// merely look alike are what 0.98 and 0.99 each had to unpick.
    @MainActor
    func testCollectorAndRowShareOneVocabulary() {
        for title in AgentRow.chromeTitles {
            XCTAssertTrue(
                AgentRow.isChromeTitle(title.uppercased()),
                "\(title) must be chrome in either case"
            )
            var row = AgentRow(rowKey: "k", agent: .claude)
            row.task = title
            XCTAssertNil(row.usefulTask, "\(title) reached a row as a goal")
        }
    }

    func testARealGoalIsNotMistakenForChrome() {
        XCTAssertFalse(AgentRow.isChromeTitle("Auth session"))
        XCTAssertFalse(AgentRow.isChromeTitle("Fix the tray hero"))
    }
}
