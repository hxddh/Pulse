import Foundation

/// Removes credential-shaped content before it reaches any user-visible
/// surface. Agent transcripts are untrusted input: a prompt, tool result, or
/// waiting message may contain a secret even when Pulse only intends to show a
/// short title.
enum ContentSanitizer {
    static let replacement = "••••"

    private struct Rule {
        let expression: NSRegularExpression
        let replacement: String

        init(_ pattern: String, replacement: String = ContentSanitizer.replacement) {
            expression = try! NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            )
            self.replacement = replacement
        }
    }

    private static let rules: [Rule] = [
        // Common provider and service tokens.
        Rule(#"\bsk-(?:proj-)?[A-Za-z0-9_-]{12,}\b"#),
        Rule(#"\bgithub_pat_[A-Za-z0-9_]{12,}\b"#),
        Rule(#"\bgh[pousr]_[A-Za-z0-9_]{12,}\b"#),
        Rule(#"\bxox[a-z]-[A-Za-z0-9-]{12,}\b"#),
        Rule(#"\bAKIA[0-9A-Z]{16}\b"#),
        // Authorization headers and credential assignments retain the label so
        // the surrounding sentence remains understandable.
        Rule(#"\b(Bearer\s+)[A-Za-z0-9._~+/\-=]{8,}"#, replacement: "$1••••"),
        Rule(
            #"\b((?:api[_-]?key|access[_-]?token|auth[_-]?token|secret|password|passwd|token)\s*[:=]\s*['"]?)[^\s'";,]{8,}"#,
            replacement: "$1••••"
        ),
        // URL user info and SSH identity paths can disclose credentials even
        // when they do not look like API tokens.
        Rule(#"(https?://[^/\s:@]+:)[^@\s/]+@"#, replacement: "$1••••@"),
        Rule(#"(\b(?:ssh\s+)?-i\s+)(?:~|/)[^\s'"]+"#, replacement: "$1••••"),
        // Collapse an entire PEM private-key block, not just its header.
        Rule(
            #"-----BEGIN[ A-Z0-9_-]*PRIVATE KEY-----[\s\S]*?-----END[ A-Z0-9_-]*PRIVATE KEY-----"#
        ),
    ]

    static func redact(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var value = raw
        for rule in rules {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            value = rule.expression.stringByReplacingMatches(
                in: value,
                options: [],
                range: range,
                withTemplate: rule.replacement
            )
        }
        return value
    }
}
