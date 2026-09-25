import Foundation
import SQLite3

// Gemini and Aider: the last-word readers their formats need.
//
// 12.3 γ: one vendor per file. Moved verbatim out of HarvestFacts.swift; the
// dispatch that picks a dialect for a transcript lives in
// TranscriptDialect.swift.

extension NativeActivityHarvest {
    /// The last `model`-role turn's text in a Gemini chat document. Arrays
    /// keep document order (the history array is the structure that matters);
    /// depth is bounded; an unrecognised layout yields nil.
    static func geminiLastWord(in value: Any, depth: Int = 0) -> String? {
        guard depth < 6 else { return nil }
        var latest: String?
        if let dict = value as? [String: Any] {
            let role = firstString(dict, keys: ["role"]).lowercased()
            if role == "model" || role == "assistant" {
                var text = firstString(dict, keys: ["text", "content"])
                if text.isEmpty, let parts = dict["parts"] as? [Any] {
                    for part in parts {
                        if let block = part as? [String: Any] {
                            let candidate = firstString(block, keys: ["text"])
                            if !candidate.isEmpty { text = candidate; break }
                        } else if let plain = part as? String, !plain.isEmpty {
                            text = plain
                            break
                        }
                    }
                }
                let line = selfReportLine(text)
                if !line.isEmpty { latest = line }
            }
            for (_, child) in dict {
                if let found = geminiLastWord(in: child, depth: depth + 1) {
                    latest = found
                }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let found = geminiLastWord(in: item, depth: depth + 1) {
                    latest = found
                }
            }
        }
        return latest
    }

    /// 9.0 — Aider's markdown history: the last non-fence, non-header prose
    /// line after the newest `#### ` user turn. Internal for the unit test.
    static func aiderLastWord(from text: String) -> String {
        var inFence = false
        var afterUser = false
        var word = ""
        for line in text.split(whereSeparator: \.isNewline) {
            let value = String(line).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            if value.hasPrefix("#### ") {
                afterUser = true
                word = ""
                continue
            }
            if value.isEmpty || value.hasPrefix("#") || value.hasPrefix(">") { continue }
            if afterUser { word = value }
        }
        return selfReportLine(word)
    }
}
