import Foundation
import PulseCore
import SQLite3

// Small, pure value helpers shared by the native collector's readers.

extension NativeActivityHarvest {
    // MARK: - Small value helpers

    package static func applyTokenUsage(_ fact: inout Fact, _ usage: [String: Any]?) {
        guard let usage else { return }
        // Bare `input`/`output` are Pi's official usage keys. They are safe
        // here and only here: this function is handed usage-labelled dicts,
        // never arbitrary records where `input` means a tool's arguments.
        fact.tokensIn = max(fact.tokensIn, firstNumber(usage, keys: [
            "inputTokens", "input_tokens", "promptTokens", "prompt_tokens",
            "inputTokenCount", "input_token_count", "promptTokenCount", "input",
        ]))
        fact.tokensOut = max(fact.tokensOut, firstNumber(usage, keys: [
            "outputTokens", "output_tokens", "completionTokens", "completion_tokens",
            "outputTokenCount", "output_token_count", "completionTokenCount",
            "candidatesTokenCount", "candidates_token_count", "output",
        ]))
    }

    package static func normalizedKey(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    package static func firstValue(_ dict: [String: Any], keys: [String]) -> Any? {
        let wanted = Set(keys.map(normalizedKey))
        for (key, value) in dict where wanted.contains(normalizedKey(key)) { return value }
        return nil
    }

    /// True if any recognized alias is a truthy pending flag (deterministic OR).
    package static func anyTruthy(_ dict: [String: Any], keys: [String]) -> Bool {
        let wanted = Set(keys.map(normalizedKey))
        for (key, value) in dict where wanted.contains(normalizedKey(key)) {
            if boolValue(value) { return true }
        }
        return false
    }

    package static func firstString(_ dict: [String: Any], keys: [String]) -> String {
        for key in keys {
            guard let value = firstValue(dict, keys: [key]) else { continue }
            guard let raw = value as? String else { continue }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return ""
    }

    package static func isUserRecord(_ dict: [String: Any]) -> Bool {
        let kind = firstString(dict, keys: ["role", "type", "kind"]).lowercased()
        guard !kind.isEmpty else { return false }
        return kind == "user" || kind == "human"
            || kind.contains("user_message") || kind.contains("user-prompt")
            || kind.contains("human_message")
    }

    package static func textValue(_ value: Any?, depth: Int = 0) -> String {
        guard depth < 4 else { return "" }
        if let text = value as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let array = value as? [Any] {
            return array.prefix(16).compactMap { textValue($0, depth: depth + 1) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        if let dict = value as? [String: Any] {
            for key in ["text", "content", "message", "value"] {
                if let nested = firstValue(dict, keys: [key]) {
                    let text = textValue(nested, depth: depth + 1)
                    if !text.isEmpty { return text }
                }
            }
        }
        return ""
    }

    package static func firstNumber(_ dict: [String: Any], keys: [String]) -> Int {
        guard let value = firstValue(dict, keys: keys) else { return 0 }
        if let number = value as? NSNumber { return max(0, min(Int.max, number.intValue)) }
        return Int(stringValue(value).split(separator: ".").first ?? "") ?? 0
    }

    package static func stringValue(_ value: Any?) -> String {
        guard let value else { return "" }
        if let string = value as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    package static func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        let text = stringValue(value).lowercased()
        return ["1", "true", "yes", "pending", "waiting"].contains(text)
    }

    package static func normalizedPath(_ value: String) -> String {
        var path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("file://") { path = String(path.dropFirst(7)).removingPercentEncoding ?? path }
        return path.hasPrefix("/") ? path : ""
    }

    package static func contextPercent(_ value: Any?) -> Int {
        let raw = stringValue(value).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "%", with: "")
        guard var number = Double(raw), number.isFinite, number > 0 else { return 0 }
        if number <= 1 { number *= 100 }
        return max(1, min(100, Int(number.rounded())))
    }

    package static func contextLooksSession(_ context: String) -> Bool {
        let lower = context.lowercased()
        return sessionNeedles.contains(where: { lower.contains($0) })
    }

    /// Whole-token / phrase markers only — never substring-match inside words
    /// like `depending` (historical Goose false Waiting footgun).
    package static func pendingPhase(_ value: String) -> Bool {
        let normalized = value
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let phrases = [
            "needs user", "awaiting user", "awaiting approval",
            "waiting for user", "waiting for approval", "ask user",
            "user approval", "blocking pending", "has blocking",
            "waiting for response", "awaiting response",
        ]
        if phrases.contains(where: { normalized.contains($0) }) { return true }
        let tokens = normalized
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        // Bare "ask" is too broad (matches unrelated status words). Keep
        // askuser / permission / pending / waiting / approval / awaiting.
        let markers: Set<String> = [
            "pending", "waiting", "approval", "awaiting",
            "askuser", "permission", "confirm", "confirmation",
            "blocked",
        ]
        return tokens.contains(where: { markers.contains($0) })
    }

    package static func semanticPhase(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        let lower = value.lowercased()
        // Vendor lifecycle enums → stable working (0.82). Never treat Goose
        // `depending` as Waiting — that was a historical false-red footgun.
        if ["in_progress", "inprogress", "active", "busy", "thinking", "depending"]
            .contains(where: { lower == $0 || lower.replacingOccurrences(of: "_", with: "") == $0.replacingOccurrences(of: "_", with: "") }) {
            return "working"
        }
        if lower.contains("plan") { return "planning" }
        if lower.contains("read") || lower.contains("inspect") { return "reading" }
        if lower.contains("research") || lower.contains("search") { return "researching" }
        if lower.contains("test") || lower.contains("verify") { return "testing" }
        if lower.contains("build") || lower.contains("compile") { return "building" }
        if lower.contains("publish") || lower.contains("deploy") || lower.contains("release") { return "publishing" }
        if lower.contains("edit") || lower.contains("code") || lower.contains("patch") { return "editing" }
        if lower.contains("run") || lower.contains("execut") || lower.contains("command") { return "running" }
        return String(value.prefix(64))
    }

    package static func clean(_ value: String, limit: Int) -> String {
        let compact = value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(compact.prefix(limit))
    }

    package static func lastPathComponent(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let leaf = URL(fileURLWithPath: path).lastPathComponent
        guard !leaf.isEmpty, leaf != "/", leaf.count <= 64 else { return "" }
        if leaf.range(of: #"^[0-9a-fA-F]{16,}$"#, options: .regularExpression) != nil { return "" }
        return leaf
    }

    package static func regexValue(_ text: String, patterns: [String]) -> String {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text)
            else { continue }
            let value = String(text[valueRange])
            if !value.isEmpty { return value }
        }
        return ""
    }
}
