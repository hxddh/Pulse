import XCTest
@testable import PulseApp
@testable import PulseCore
@testable import PulseHarvest

// Transcripts: the lazy summary of one known transcript per dialect (24.0).

/// 24.0 · the lazy read of one known transcript: a title, the last
/// assistant message, the model and the last error, per dialect — from the
/// vendor-shaped lines the old harvest fixtures pinned.
final class TranscriptSummaryTests: XCTestCase {
    private func summary(_ lines: [String], _ dialect: TranscriptDialect) -> TranscriptSummary {
        TranscriptSummaryReader.summarize(head: nil, tail: lines.joined(separator: "\n"), dialect: dialect)
    }

    func testClaude() {
        let s = summary([
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>Caveat</local-command-caveat>"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Fix the tray hero for Claude"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4","content":[{"type":"text","text":"Reading the collector."},{"type":"tool_use","name":"Bash","input":{"command":"swift test"}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","is_error":true,"content":"error: no such module 'Foo'\nmore"}]}}"#,
            #"{"type":"user","isSidechain":true,"message":{"role":"user","content":"a subagent's own prompt"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"The hero now reads the user goal.\nDetails follow."}]}}"#,
        ], .claude)
        XCTAssertEqual(s.title, "Fix the tray hero for Claude", "caveats, slash commands and tool results are not the title")
        XCTAssertEqual(s.lastMessage, "The hero now reads the user goal.")
        XCTAssertEqual(s.model, "claude-sonnet-4", "a synthetic reply is not a model")
        XCTAssertEqual(s.lastError, "error: no such module 'Foo'")
    }

    func testClaudeSummaryIsOnlyAFallback() {
        XCTAssertEqual(summary([#"{"type":"summary","summary":"Tray hero fix","leafUuid":"x"}"#], .claude).title, "Tray hero fix")
        XCTAssertEqual(summary([
            #"{"type":"summary","summary":"Tray hero fix","leafUuid":"x"}"#,
            #"{"type":"user","message":{"role":"user","content":"Fix the tray hero"}}"#,
        ], .claude).title, "Fix the tray hero")
    }

    func testCodexLegacyAndPaginated() {
        let s = summary([
            #"{"type":"session_meta","payload":{"session_id":"pg-1","cwd":"/Users/me/app"},"timestamp":1790000000}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>cwd</environment_context>"}]}}"#,
            #"{"type":"turn_context","payload":{"model":"gpt-5.2-codex","cwd":"/Users/me/app"},"timestamp":1790000001}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"u1","content":[{"type":"text","text":"Add an offline queue for login"}]}}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"Reasoning","id":"r1","summary_text":["thinking about layout"]}}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"a1","content":[{"type":"Text","text":"The queue drains on reconnect; 42 tests pass."}]}}}"#,
            #"{"type":"event_msg","payload":{"type":"error","message":"stream disconnected before completion"}}"#,
        ], .codex)
        XCTAssertEqual(s.title, "Add an offline queue for login")
        XCTAssertEqual(s.lastMessage, "The queue drains on reconnect; 42 tests pass.")
        XCTAssertEqual(s.model, "gpt-5.2-codex")
        XCTAssertEqual(s.lastError, "stream disconnected before completion")

        let legacy = summary([
            ###"{"type":"event_msg","payload":{"type":"user_message","message":"## My request for Codex: Ship the Codex event_msg hero"}}"###,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"continue"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Shipped."}]}}"#,
        ], .codex)
        XCTAssertEqual(legacy.title, "Ship the Codex event_msg hero")
        XCTAssertEqual(legacy.lastMessage, "Shipped.")
    }

    func testGeminiRewindsAndCheckpoints() {
        let s = summary([
            #"{"sessionId":"1a2b3c4d","projectHash":"h","startTime":"2026-09-29T10:15:02.114Z"}"#,
            #"{"id":"u0","type":"user","content":[{"text":"no, rewind that"}]}"#,
            #"{"$rewindTo":"u0"}"#,
            #"{"id":"u1","timestamp":"2026-09-29T10:15:09.500Z","type":"user","content":[{"text":"Summarise @README.md\n--- README.md ---\n# Pulse"}],"displayContent":[{"text":"Summarise @README.md"}]}"#,
            #"{"id":"g1","type":"gemini","content":"Draft one.","model":"gemini-2.5-pro"}"#,
            #"{"id":"g1","type":"gemini","content":"The queue drains on reconnect; 42 tests pass.","model":"gemini-2.5-pro"}"#,
            #"{"id":"e1","type":"error","content":"Quota exceeded"}"#,
            #"{"$set":{"lastUpdated":"2026-09-29T10:16:40.021Z"}}"#,
        ], .gemini)
        XCTAssertEqual(s.title, "Summarise @README.md", "what the person typed, not the expanded file; the rewound prompt is gone")
        XCTAssertEqual(s.lastMessage, "The queue drains on reconnect; 42 tests pass.", "a re-appended id is one message")
        XCTAssertEqual(s.model, "gemini-2.5-pro")
        XCTAssertEqual(s.lastError, "Quota exceeded")
    }

    func testPiNameWinsOverTheFirstPrompt() {
        let lines = [
            #"{"type":"session","version":3,"id":"0199a1b2-c3d4","timestamp":"2026-09-29T10:00:00.000Z","cwd":"/Users/me/app"}"#,
            #"{"type":"message","id":"b2","parentId":null,"message":{"role":"user","content":[{"type":"text","text":"<environment_context>cwd</environment_context>Add an offline queue for login"}]}}"#,
            #"{"type":"message","id":"c3","parentId":"b2","message":{"role":"assistant","model":"claude-sonnet-4","content":[{"type":"text","text":"The queue drains on reconnect."},{"type":"toolCall","name":"bash"}],"stopReason":"stop"}}"#,
            #"{"type":"message","id":"d4","parentId":"c3","message":{"role":"toolResult","isError":true,"content":[{"type":"text","text":"bash: npm: command not found"}]}}"#,
        ]
        let unnamed = summary(lines, .pi)
        XCTAssertEqual(unnamed.title, "Add an offline queue for login", "an env wrapper does not swallow the goal")
        XCTAssertEqual(unnamed.lastMessage, "The queue drains on reconnect.")
        XCTAssertEqual(unnamed.model, "claude-sonnet-4")
        XCTAssertEqual(unnamed.lastError, "bash: npm: command not found")
        let named = summary(lines + [#"{"type":"session_info","name":"Refactor the auth module"}"#], .pi)
        XCTAssertEqual(named.title, "Refactor the auth module")
        let cleared = summary(lines + [#"{"type":"session_info","name":"Refactor"}"#, #"{"type":"session_info","name":""}"#], .pi)
        XCTAssertEqual(cleared.title, "Add an offline queue for login", "an empty /name clears the name")
    }

    func testCopilotSessionState() {
        let s = summary([
            #"{"id":"e1","timestamp":"2026-09-29T10:00:00.000Z","type":"session.start","data":{"sessionId":"c0ffee","context":{"cwd":"/Users/me/app"}}}"#,
            #"{"id":"e2","type":"user.message","data":{"content":"Add an offline queue for login"}}"#,
            #"{"id":"e3","type":"assistant.message","data":{"content":"The queue drains on reconnect; 42 tests pass.","model":"gpt-5"}}"#,
        ], .copilot)
        XCTAssertEqual(s.title, "Add an offline queue for login")
        XCTAssertEqual(s.lastMessage, "The queue drains on reconnect; 42 tests pass.")
        XCTAssertEqual(s.model, "gpt-5")
    }

    func testCursorAgentTranscript() {
        let s = summary([
            #"{"role":"user","message":{"content":[{"type":"text","text":"<user_query>\nTidy the settings screen\n</user_query>"}]}}"#,
            #"{"role":"assistant","message":{"content":[{"type":"text","text":"Tidied; the sections now scroll."}]}}"#,
        ], .cursor)
        XCTAssertEqual(s.title, "Tidy the settings screen")
        XCTAssertEqual(s.lastMessage, "Tidied; the sections now scroll.")
    }

    func testOpenCodeHasNoTranscript() {
        XCTAssertNil(TranscriptDialect(agent: .opencode))
        XCTAssertNil(TranscriptSummaryReader.read(path: "/nonexistent", agent: .opencode))
        for agent in AgentID.allCases where agent != .opencode {
            XCTAssertNotNil(TranscriptDialect(agent: agent), agent.rawValue)
        }
    }

    func testAContinuationIsNotTheTitle() {
        let s = summary([
            #"{"type":"user","message":{"role":"user","content":"continue"}}"#,
            #"{"type":"user","message":{"role":"user","content":"Port the parser to Swift"}}"#,
        ], .claude)
        XCTAssertEqual(s.title, "Port the parser to Swift")
    }

    /// A long file is read as a bounded head (the first prompt) and a
    /// bounded tail (the latest words); the torn line at each edge is not a
    /// record.
    func testALongTranscriptIsReadAtBothEndsOnly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-summary-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        var lines = [#"{"type":"user","message":{"role":"user","content":"Fix the tray hero for Claude"}}"#]
        let filler = String(repeating: "x", count: 2_000)
        for index in 0..<400 {
            lines.append(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"\#(filler)\#(index)"}]}}"#)
        }
        lines.append(#"{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4","content":[{"type":"text","text":"Done at the end."}]}}"#)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertGreaterThan(size, TranscriptSummaryReader.headBytes + TranscriptSummaryReader.tailBytes)
        let s = try XCTUnwrap(TranscriptSummaryReader.read(path: url.path, agent: .claude))
        XCTAssertEqual(s.title, "Fix the tray hero for Claude")
        XCTAssertEqual(s.lastMessage, "Done at the end.")
        XCTAssertEqual(s.model, "claude-opus-4")
    }

    func testAnUnreadableFileIsNil() {
        XCTAssertNil(TranscriptSummaryReader.read(path: "/nonexistent/pulse.jsonl", agent: .claude))
        XCTAssertNil(TranscriptSummaryReader.read(path: "", agent: .claude))
    }
}
