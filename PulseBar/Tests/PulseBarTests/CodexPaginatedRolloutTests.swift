import Foundation
import Testing
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

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
