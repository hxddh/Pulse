import Foundation
import PulseCore
import SQLite3

// Aider: the last-word reader its format needs. (Gemini moved to
// HarvestGemini.swift in 20.0.)
//
// 12.3 γ: one vendor per file. Moved verbatim out of HarvestFacts.swift; the
// dispatch that picks a dialect for a transcript lives in
// TranscriptDialect.swift.

extension NativeActivityHarvest {
    /// 9.0 — Aider's markdown history: the last non-fence, non-header prose
    /// line after the newest `#### ` user turn. Internal for the unit test.
    package static func aiderLastWord(from text: String) -> String {
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
