import Foundation

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
protocol TranscriptDialect {
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
    func parse(_ text: String, path: String) -> [NativeActivityHarvest.Fact]? { nil }
    func finish(_ facts: inout [NativeActivityHarvest.Fact], root: Any?) {}
}

enum TranscriptDialects {
    /// Registration order is precedence.
    static let all: [any TranscriptDialect] = [CodexDialect(), PiDialect(), GeminiDialect()]

    static func dialect(for path: String) -> (any TranscriptDialect)? {
        let lower = path.lowercased()
        return all.first { $0.claims(lowerPath: lower) }
    }
}

/// Codex rollouts: its own parser; an empty result falls back to the walker.
struct CodexDialect: TranscriptDialect {
    func claims(lowerPath: String) -> Bool {
        lowerPath.contains("/.codex/") && lowerPath.hasSuffix(".jsonl")
    }

    func parse(_ text: String, path: String) -> [NativeActivityHarvest.Fact]? {
        let facts = NativeActivityHarvest.parseCodexFacts(text, path: path)
        return facts.isEmpty ? nil : facts
    }
}

/// Pi sessions. Official envelopes without a parseable user prompt must not
/// fall through to the generic walker — that produced cwd-only rows whose tray
/// hero was the project folder name.
struct PiDialect: TranscriptDialect {
    func claims(lowerPath: String) -> Bool {
        lowerPath.contains("/.pi/")
            && (lowerPath.hasSuffix(".jsonl") || lowerPath.hasSuffix(".ndjson"))
    }

    func parse(_ text: String, path: String) -> [NativeActivityHarvest.Fact]? {
        let facts = NativeActivityHarvest.parsePiFacts(text, path: path)
        if !facts.isEmpty { return facts }
        return NativeActivityHarvest.piLooksOfficial(text) ? [] : nil
    }
}

/// Gemini chats are one whole-file JSON whose reply role is `model`, not
/// `assistant`; the generic walk parses them, then this reads the last model
/// turn for the facts that have no last word yet.
struct GeminiDialect: TranscriptDialect {
    func claims(lowerPath: String) -> Bool {
        lowerPath.contains("/.gemini/") && lowerPath.contains("/chats/")
    }

    func finish(_ facts: inout [NativeActivityHarvest.Fact], root: Any?) {
        guard !facts.isEmpty, let root,
              let word = NativeActivityHarvest.geminiLastWord(in: root)
        else { return }
        for index in facts.indices where facts[index].lastWord.isEmpty {
            facts[index].lastWord = word
        }
    }
}
