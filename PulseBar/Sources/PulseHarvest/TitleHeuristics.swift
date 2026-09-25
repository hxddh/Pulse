import Foundation
import PulseCore

/// What a session title is not (12.3: moved out of `AgentRow` so the harvest
/// library can ask without depending on the app's row model; `AgentRow`'s
/// static functions forward here, so there is still one vocabulary).
package enum TitleHeuristics {
    package static let chromeTitles: Set<String> = [
        "-", "—", "none", "running", "active",
        "new session", "new chat", "untitled", "agent session", "chat",
        "amp session", "amp thread", "pi session", "grok session",
        "cursor session", "opencode session", "gemini session", "goose session",
        "copilot session", "continue session", "warp session",
        "windsurf session", "cline session", "roo session",
        "cascade session", "aider session", "droid session", "kimi session",
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
}
