import Foundation
import PulseCore

/// A vendor transcript format that needs more than the generic record walk.
///
/// 12.3 γ. `parseFacts` used to open with a chain of path tests — Codex, then
/// Pi — and close with a Gemini special case, each written inline in the
/// generic parser. Every vendor that needed its own reading meant another
/// branch in the middle of shared code. A dialect is now one value in one
/// table: it says which transcripts it claims, parses them itself or hands
/// them to the generic walker, and may finish what the walker produced.
///
/// Dispatch is by path, as before, and in registration order; the first
/// dialect that claims a transcript owns it. The parsers themselves live one
/// vendor per file (`HarvestCodex.swift`, `HarvestPi.swift`, …).
package protocol TranscriptDialect: Sendable {
    /// Whether this dialect owns the transcript at `lowerPath` (lowercased).
    func claims(lowerPath: String) -> Bool
    /// Parse the whole transcript, or return `nil` to hand it to the generic
    /// walker. An empty array is an answer: "this is ours and it says nothing".
    func parse(_ text: String, path: String) -> [NativeActivityHarvest.Fact]?
    /// Adjust the generic walker's facts. `root` is the first parsed JSON
    /// document, when the transcript was one.
    func finish(_ facts: inout [NativeActivityHarvest.Fact], root: Any?)
}

extension TranscriptDialect {
    package func parse(_ text: String, path: String) -> [NativeActivityHarvest.Fact]? { nil }
    package func finish(_ facts: inout [NativeActivityHarvest.Fact], root: Any?) {}
}

package enum TranscriptDialects {
    /// Registration order is precedence.
    package static let all: [any TranscriptDialect] = [
        CodexDialect(), PiDialect(), GeminiDialect(), CopilotDialect(),
    ]

    package static func dialect(for path: String) -> (any TranscriptDialect)? {
        let lower = path.lowercased()
        return all.first { $0.claims(lowerPath: lower) }
    }
}

/// Codex rollouts: its own parser; an empty result falls back to the walker.
package struct CodexDialect: TranscriptDialect {
    package func claims(lowerPath: String) -> Bool {
        lowerPath.contains("/.codex/") && lowerPath.hasSuffix(".jsonl")
    }

    package func parse(_ text: String, path: String) -> [NativeActivityHarvest.Fact]? {
        let facts = NativeActivityHarvest.parseCodexFacts(text, path: path)
        return facts.isEmpty ? nil : facts
    }
}

/// Pi sessions. Official envelopes without a parseable user prompt must not
/// fall through to the generic walker — that produced cwd-only rows whose tray
/// hero was the project folder name.
package struct PiDialect: TranscriptDialect {
    package func claims(lowerPath: String) -> Bool {
        lowerPath.contains("/.pi/")
            && (lowerPath.hasSuffix(".jsonl") || lowerPath.hasSuffix(".ndjson"))
    }

    package func parse(_ text: String, path: String) -> [NativeActivityHarvest.Fact]? {
        let facts = NativeActivityHarvest.parsePiFacts(text, path: path)
        if !facts.isEmpty { return facts }
        return NativeActivityHarvest.piLooksOfficial(text) ? [] : nil
    }
}

/// Gemini chat recordings (20.0): append-only JSONL with `type: "gemini"`
/// replies, `$set` checkpoints and rewinds — its own parser
/// (`HarvestGemini.swift`). A subagent's chat is claimed and says nothing:
/// it is part of its parent's session.
package struct GeminiDialect: TranscriptDialect {
    package func claims(lowerPath: String) -> Bool {
        lowerPath.contains("/.gemini/") && lowerPath.contains("/chats/")
    }

    package func parse(_ text: String, path: String) -> [NativeActivityHarvest.Fact]? {
        let facts = NativeActivityHarvest.parseGeminiFacts(text, path: path)
        if !facts.isEmpty { return facts }
        return text.contains("\"subagent\"") ? [] : nil
    }
}

/// GitHub Copilot CLI `session-state/<id>/events.jsonl` (20.0).
package struct CopilotDialect: TranscriptDialect {
    package func claims(lowerPath: String) -> Bool {
        lowerPath.contains("/.copilot/session-state/") && lowerPath.hasSuffix("/events.jsonl")
    }

    package func parse(_ text: String, path: String) -> [NativeActivityHarvest.Fact]? {
        let facts = NativeActivityHarvest.parseCopilotEvents(text, path: path)
        return facts.isEmpty ? nil : facts
    }
}
