import Foundation
import PulseCore

/// What a session title is, and what it is not. A library can ask without
/// depending on the app's row model; `AgentRow`'s static functions forward
/// here, so there is one vocabulary.
package enum TitleHeuristics {
    /// A title is at most this many characters.
    package static let titleLimit = 120
    /// A last message or an error is at most this many characters.
    package static let lineLimit = 160

    /// Placeholders the seven agents (and their UIs) use for an untitled
    /// session — never a goal.
    package static let chromeTitles: Set<String> = [
        "-", "—", "none", "running", "active",
        "new session", "new chat", "untitled", "agent session", "chat",
        "cursor session", "gemini session", "copilot session", "opencode session",
        "pi session",
    ]

    package static func isChromeTitle(_ value: String) -> Bool {
        chromeTitles.contains(
            value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    package static func looksLikeFilenameOnlyTitle(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.range(
            of: #"^(Read|Reading)\s+\S+\.\w{1,12}$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }
        guard !t.contains(" "), t.contains(".") else { return false }
        let ext = (t as NSString).pathExtension.lowercased()
        let code = [
            "swift", "ts", "tsx", "js", "jsx", "py", "md", "json", "go", "rs",
            "rb", "java", "kt", "c", "h", "cpp", "hpp", "m", "mm", "cs", "sh",
        ]
        return code.contains(ext)
    }

    package static func shortProject(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        if s.contains("/") {
            s = (s as NSString).lastPathComponent
        }
        if s.range(of: #"^[0-9a-fA-F-]{16,}$"#, options: .regularExpression) != nil { return "" }
        if s.count > 24 { return String(s.prefix(23)) + "…" }
        return s
    }

    // MARK: - Prompts

    /// A prompt as a title: the wrappers vendors put around it removed, one
    /// line, sanitized, at most `limit` characters; "" when what is left is
    /// not something a person typed (a slash command's echo, an injected
    /// caveat).
    package static func promptTitle(_ raw: String, limit: Int = TitleHeuristics.titleLimit) -> String {
        var text = raw
        if let query = taggedInner(text, name: "user_query") { text = query }
        for tag in ["environment_context", "system-reminder", "user_instructions", "recommended_plugins", "app-context", "git_status"] {
            text = removingTagged(text, name: tag)
        }
        // Codex desktop: "…## My request for Codex: <the request>".
        if let marker = text.range(of: "## My request for Codex:", options: .caseInsensitive) {
            text = String(text[marker.upperBound...])
        }
        let folded = ContentSanitizer.redact(text)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard folded.count >= 3, !folded.hasPrefix("<"), !folded.hasPrefix("# AGENTS.md") else { return "" }
        return folded.count > limit ? String(folded.prefix(limit - 1)) + "…" : folded
    }

    /// "continue", "go on", "继续" are not what a session is about.
    package static func isMeaningful(_ title: String) -> Bool {
        let compact = title.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        let continuations: Set<String> = [
            "continue", "goon", "proceed", "resume", "keepgoing", "yes", "ok", "okay",
            "继续", "继续吧", "好的", "可以",
        ]
        return !compact.isEmpty && !continuations.contains(compact)
    }

    /// The first non-empty line, sanitized and bounded.
    package static func firstLine(_ raw: String, limit: Int = TitleHeuristics.lineLimit) -> String {
        for line in ContentSanitizer.redact(raw).split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
        }
        return ""
    }

    static func taggedInner(_ text: String, name: String) -> String? {
        guard let open = text.range(of: "<\(name)", options: .caseInsensitive),
              let close = text.range(of: ">", range: open.upperBound..<text.endIndex),
              let end = text.range(of: "</\(name)>", options: .caseInsensitive, range: close.upperBound..<text.endIndex)
        else { return nil }
        let inner = text[close.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    static func removingTagged(_ text: String, name: String) -> String {
        var out = text
        while let open = out.range(of: "<\(name)", options: .caseInsensitive),
              let end = out.range(of: "</\(name)>", options: .caseInsensitive, range: open.upperBound..<out.endIndex) {
            out.removeSubrange(open.lowerBound..<end.upperBound)
        }
        return out
    }
}
