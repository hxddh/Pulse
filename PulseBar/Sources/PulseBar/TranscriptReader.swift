import Foundation

/// 4.0-α — the workbench shows the session itself (scene BD).
///
/// Every version up to 3.0 extracted facts *about* the transcript and showed
/// those; the conversation — who said what, which tools ran, where it went
/// wrong — stayed invisible. That was a rule once ("counts and short names
/// only"), but 3.0-β re-scoped that rule to the tray and cross-machine
/// channels. Inside the workbench the user is reading their own file on their
/// own machine, and this reader renders it:
///
/// - **On demand only.** A click opens the file; nothing here runs on a scan
///   or a timer (energy is a hard constraint).
/// - **Tail-bounded.** The last `tailWindowBytes` of the file, torn first
///   line skipped (a partial line is the front half of a record, not a
///   record — the AP lesson). Truncation states itself.
/// - **Shape-based, vendor-blind** (the 2.9 平权 rule): Claude-family
///   `message.content[]` blocks, Codex `event_msg` / `response_item`
///   envelopes, generic `role`/`content` records. A line that matches no
///   shape yields nothing and is counted, never guessed at.
/// - **Sanitized per entry.** Transcripts are untrusted input; every string
///   that will be rendered passes `ContentSanitizer` and a length bound.
/// - **Local only.** The path never renders, the content never leaves the
///   machine, remote rows never had a path to begin with.
enum TranscriptReader {

    static let tailWindowBytes = 512 * 1024
    static let maxEntries = 300
    static let maxEntryChars = 2_000

    struct Entry: Equatable {
        enum Kind: Equatable {
            /// The person driving the session.
            case user
            /// The agent's own words.
            case agent
            /// A tool call or its result.
            case tool
        }

        var kind: Kind
        /// Tool name for `.tool` entries; empty otherwise (the view labels
        /// user/agent itself).
        var toolName: String = ""
        /// Sanitized, bounded display text.
        var text: String
        /// A failed tool result.
        var isError: Bool = false
        /// Record timestamp, 0 when the line carried none (never invented).
        var tsMs: Int64 = 0
    }

    struct Excerpt: Equatable {
        var entries: [Entry] = []
        /// The file was larger than the read window — entries are the tail.
        var truncatedHead = false
        /// Entries beyond `maxEntries` were dropped from the front.
        var entriesCapped = false
        /// Lines in the window that were not parseable JSON objects.
        var unparsedLines = 0
        var fileBytes = 0
        var windowBytes = 0
    }

    // MARK: - Reading

    /// Nil when the file cannot be read at all. An empty `entries` with a
    /// successful read is a different, honest answer ("nothing conversational
    /// in the window") and the view says so.
    static func read(path: String) -> Excerpt? {
        guard !path.isEmpty, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let fileBytes = Int(size)
        let offset = max(0, fileBytes - tailWindowBytes)
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let data = try? handle.readToEnd()
        else { return nil }
        var excerpt = parse(data: data, truncatedHead: offset > 0)
        excerpt.fileBytes = fileBytes
        return excerpt
    }

    /// Pure, so tests can pin every shape without touching a disk.
    static func parse(data: Data, truncatedHead: Bool) -> Excerpt {
        var excerpt = Excerpt()
        excerpt.truncatedHead = truncatedHead
        excerpt.windowBytes = data.count
        var body = data
        if truncatedHead {
            // The window almost certainly starts mid-record. The front half
            // of a torn line is not a record; skip through the first newline.
            if let firstNewline = body.firstIndex(of: 0x0A) {
                body = body[body.index(after: firstNewline)...]
            } else {
                return excerpt
            }
        }
        let text = String(decoding: body, as: UTF8.self)
        var entries: [Entry] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let lineData = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
            else {
                excerpt.unparsedLines += 1
                continue
            }
            entries.append(contentsOf: self.entries(from: object))
        }
        if entries.count > maxEntries {
            excerpt.entriesCapped = true
            entries.removeFirst(entries.count - maxEntries)
        }
        excerpt.entries = entries
        return excerpt
    }

    // MARK: - Shapes

    /// One JSONL record → zero or more display entries. A record that is not
    /// conversational (usage events, summaries, plan bookkeeping) yields
    /// nothing, which is normal and not an error.
    static func entries(from object: [String: Any]) -> [Entry] {
        let tsMs = timestamp(of: object)

        // Codex `event_msg` envelope: {"type":"event_msg","payload":{...}}.
        if str(object["type"]) == "event_msg",
           let payload = object["payload"] as? [String: Any] {
            switch str(payload["type"]) {
            case "user_message":
                return textEntry(.user, str(payload["message"]), tsMs: tsMs)
            case "agent_message":
                return textEntry(.agent, str(payload["message"]), tsMs: tsMs)
            default:
                return []
            }
        }

        // Codex `response_item` envelope carries an API-shaped message.
        if str(object["type"]) == "response_item",
           let payload = object["payload"] as? [String: Any] {
            return entries(from: payload)
        }

        // Claude family: {"type":"user"|"assistant","message":{...}}.
        if let message = object["message"] as? [String: Any] {
            return entries(fromMessage: message, envelopeType: str(object["type"]), tsMs: tsMs)
        }

        // Generic API-shaped record: {"role": ..., "content": ...}.
        if object["role"] != nil, object["content"] != nil {
            return entries(fromMessage: object, envelopeType: "", tsMs: tsMs)
        }

        return []
    }

    private static func entries(
        fromMessage message: [String: Any],
        envelopeType: String,
        tsMs: Int64
    ) -> [Entry] {
        let role = str(message["role"]).isEmpty ? envelopeType : str(message["role"])
        let kind: Entry.Kind = role == "user" ? .user : .agent

        // Content is either a plain string or an array of typed blocks.
        if let text = message["content"] as? String {
            return textEntry(kind, text, tsMs: tsMs)
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        var out: [Entry] = []
        for block in blocks {
            switch str(block["type"]) {
            case "text", "output_text", "input_text":
                out.append(contentsOf: textEntry(kind, str(block["text"]), tsMs: tsMs))
            case "tool_use":
                let name = str(block["name"])
                guard !name.isEmpty else { continue }
                out.append(Entry(
                    kind: .tool,
                    toolName: bound(ContentSanitizer.redact(name), limit: 80),
                    text: bound(ContentSanitizer.redact(toolTarget(block["input"])), limit: 200),
                    tsMs: tsMs
                ))
            case "tool_result":
                let body = resultText(block["content"])
                let isError = (block["is_error"] as? Bool) ?? false
                // A silent success is bookkeeping; a failure is content the
                // user came here to see even when the vendor wrote nothing.
                if body.isEmpty && !isError { continue }
                out.append(Entry(
                    kind: .tool,
                    toolName: "",
                    text: bound(ContentSanitizer.redact(body), limit: 400),
                    isError: isError,
                    tsMs: tsMs
                ))
            default:
                continue
            }
        }
        return out
    }

    // MARK: - Small pieces

    private static func textEntry(_ kind: Entry.Kind, _ raw: String, tsMs: Int64) -> [Entry] {
        let cleaned = bound(ContentSanitizer.redact(raw), limit: maxEntryChars)
        guard !cleaned.isEmpty else { return [] }
        return [Entry(kind: kind, text: cleaned, tsMs: tsMs)]
    }

    /// The one string a tool call is "about" — a path, a command, a pattern.
    /// First match wins; absent is absent.
    private static func toolTarget(_ input: Any?) -> String {
        guard let input = input as? [String: Any] else { return "" }
        for key in ["file_path", "path", "command", "pattern", "query", "url", "description"] {
            let value = str(input[key])
            if !value.isEmpty { return value }
        }
        return ""
    }

    private static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            for block in blocks where str(block["type"]) == "text" {
                let text = str(block["text"])
                if !text.isEmpty { return text }
            }
        }
        return ""
    }

    private static func timestamp(of object: [String: Any]) -> Int64 {
        if let ms = object["timestamp"] as? NSNumber {
            let value = ms.int64Value
            // Seconds vs milliseconds by magnitude; never a future invention.
            return value > 4_000_000_000 ? value : value * 1000
        }
        let raw = str(object["timestamp"])
        guard !raw.isEmpty else { return 0 }
        for parser in isoParsers {
            if let date = parser.date(from: raw) {
                return Int64(date.timeIntervalSince1970 * 1000)
            }
        }
        return 0
    }

    private static let isoParsers: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return [fractional, plain]
    }()

    private static func str(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func bound(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}
