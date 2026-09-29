import Foundation
import PulseCore

/// 24.0 · what one known transcript says, read lazily and bounded.
///
/// The hooks say *what state* a session is in; its transcript says *what it
/// is about*. Pulse no longer walks vendor directories: a hook names the
/// session's transcript (`transcript_path` in the v4 line), and this reads
/// that one file — when a session reaches "your turn", and when its detail
/// opens — off the main thread, at most `headBytes` from the front (the
/// first prompt is the title) and `tailBytes` from the end (the latest words,
/// model and error). The caller caches the answer per (path, size, mtime).
///
/// Four facts, all self-report, all sanitized and bounded: a title (the
/// vendor's own name for the session, else the first real prompt), the last
/// assistant message, the model, the last error. Never a wait: nothing in a
/// transcript lights the lamp. A line that matches no shape says nothing.
package struct TranscriptSummary: Equatable, Sendable {
    package var title = ""
    package var lastMessage = ""
    package var model = ""
    package var lastError = ""

    package init(title: String = "", lastMessage: String = "", model: String = "", lastError: String = "") {
        self.title = title
        self.lastMessage = lastMessage
        self.model = model
        self.lastError = lastError
    }

    package var isEmpty: Bool { self == TranscriptSummary() }
}

/// How one vendor writes its transcript lines. Only the shapes the summary
/// needs; the vendor sources are in `docs/vendor-formats.md`.
package enum TranscriptDialect: Equatable, Sendable {
    /// Claude Code: `{type: user|assistant|summary, message: {role, content, model}}`.
    case claude
    /// Codex rollouts: `turn_context`, `event_msg` (legacy and paginated
    /// `item_completed`), `response_item`.
    case codex
    /// Gemini CLI chat recordings: `{type: user|gemini|error}`, `$rewindTo`, `$set`.
    case gemini
    /// Pi sessions: `{type: message, message: {role, content, model}}`, `session_info`.
    case pi
    /// Copilot CLI `session-state/<id>/events.jsonl`: `{type, data}`.
    case copilot
    /// Cursor agent transcripts: `{role, message: {content}}` (unverified;
    /// read as found).
    case cursor

    /// OpenCode keeps no transcript file; its plugin's events carry what
    /// there is.
    package init?(agent: AgentID) {
        switch agent {
        case .claude: self = .claude
        case .codex: self = .codex
        case .gemini: self = .gemini
        case .pi: self = .pi
        case .copilot: self = .copilot
        case .cursor: self = .cursor
        case .opencode: return nil
        }
    }
}

package enum TranscriptSummaryReader {
    package static let headBytes = 64 * 1024
    package static let tailBytes = 256 * 1024
    /// Title, message and error lengths.
    package static let titleLimit = 160
    package static let lineLimit = 160

    /// The summary of the transcript at `path`, or nil when there is no
    /// dialect for the agent or the file cannot be read. Blocking IO: call
    /// it off the main thread.
    package static func read(path: String, agent: AgentID) -> TranscriptSummary? {
        guard let dialect = TranscriptDialect(agent: agent), !path.isEmpty,
              let handle = FileHandle(forReadingAtPath: path)
        else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let fileBytes = Int(size)
        if fileBytes <= headBytes + tailBytes {
            guard (try? handle.seek(toOffset: 0)) != nil, let data = try? handle.readToEnd() else { return nil }
            return summarize(head: nil, tail: String(decoding: data, as: UTF8.self), dialect: dialect)
        }
        guard (try? handle.seek(toOffset: 0)) != nil,
              let front = try? handle.read(upToCount: headBytes),
              (try? handle.seek(toOffset: UInt64(fileBytes - tailBytes))) != nil,
              let back = try? handle.readToEnd()
        else { return nil }
        // The head's last line and the tail's first line are torn halves of
        // a record; neither is one.
        var head = String(decoding: front, as: UTF8.self)
        if let cut = head.lastIndex(of: "\n") { head = String(head[..<cut]) }
        var tail = String(decoding: back, as: UTF8.self)
        if let cut = tail.firstIndex(of: "\n") { tail = String(tail[tail.index(after: cut)...]) }
        return summarize(head: head, tail: tail, dialect: dialect)
    }

    /// Pure: `head` (nil when `tail` is the whole file) and `tail` → the
    /// summary. The title is the vendor's own name when it has one, else the
    /// first real prompt (the head is read first); the message, model and
    /// error are the latest the text holds.
    package static func summarize(head: String?, tail: String, dialect: TranscriptDialect) -> TranscriptSummary {
        var notes = Notes()
        if let head { read(head, dialect: dialect, into: &notes) }
        read(tail, dialect: dialect, into: &notes)
        return notes.summary
    }

    // MARK: - What the lines said

    struct Notes {
        /// The vendor's explicit name for the session (Pi `/name`), latest wins.
        var named: String?
        /// Prompts in order, cleaned; the first meaningful one is the title.
        var prompts: [String] = []
        /// A vendor summary, used only when no prompt was found.
        var fallbackTitle = ""
        var lastMessage = ""
        var model = ""
        var lastError = ""

        mutating func user(_ raw: String) {
            let title = TranscriptSummaryReader.promptTitle(raw)
            if !title.isEmpty, prompts.count < 32 { prompts.append(title) }
        }

        mutating func agent(_ raw: String) {
            let line = TranscriptSummaryReader.firstLine(raw)
            if !line.isEmpty { lastMessage = line }
        }

        mutating func error(_ raw: String) {
            let line = TranscriptSummaryReader.firstLine(raw)
            if !line.isEmpty { lastError = line }
        }

        mutating func setModel(_ raw: String) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Claude marks its own synthetic replies; that is not a model.
            if !value.isEmpty, !value.hasPrefix("<") { model = String(value.prefix(64)) }
        }

        var summary: TranscriptSummary {
            let prompt = prompts.first(where: TranscriptSummaryReader.isMeaningful) ?? prompts.first ?? ""
            var title = named ?? ""
            if title.isEmpty { title = prompt }
            if title.isEmpty { title = fallbackTitle }
            return TranscriptSummary(title: title, lastMessage: lastMessage, model: model, lastError: lastError)
        }
    }

    static func read(_ text: String, dialect: TranscriptDialect, into notes: inout Notes) {
        var gemini = GeminiLog()
        for line in text.split(whereSeparator: \.isNewline) {
            let raw = line.trimmingCharacters(in: .whitespaces)
            guard raw.hasPrefix("{"), let data = raw.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            switch dialect {
            case .claude, .cursor: readMessageRecord(object, into: &notes)
            case .codex: readCodex(object, into: &notes)
            case .gemini: gemini.add(object)
            case .pi: readPi(object, into: &notes)
            case .copilot: readCopilot(object, into: &notes)
            }
        }
        if dialect == .gemini { gemini.replay(into: &notes) }
    }

    /// Claude and Cursor: `{type|role, message: {role, content, model}}`,
    /// plus Claude's `summary` records.
    static func readMessageRecord(_ object: [String: Any], into notes: inout Notes) {
        if str(object["type"]) == "summary" {
            let summary = promptTitle(str(object["summary"]))
            if !summary.isEmpty { notes.fallbackTitle = summary }
            return
        }
        // Meta records (a caveat Claude injects) and sidechains (a
        // subagent's own conversation) are not the session's words.
        if object["isMeta"] as? Bool == true || object["isSidechain"] as? Bool == true { return }
        guard let message = object["message"] as? [String: Any] else { return }
        let role = [str(message["role"]), str(object["role"]), str(object["type"])].first { !$0.isEmpty } ?? ""
        switch role {
        case "user":
            if let text = message["content"] as? String {
                notes.user(text)
                return
            }
            for block in blocks(message["content"]) {
                switch str(block["type"]) {
                case "text": notes.user(str(block["text"]))
                case "tool_result" where block["is_error"] as? Bool == true:
                    notes.error(text(block["content"]))
                default: break
                }
            }
        case "assistant":
            notes.setModel(str(message["model"]))
            if let text = message["content"] as? String {
                notes.agent(text)
                return
            }
            for block in blocks(message["content"]) where str(block["type"]) == "text" {
                notes.agent(str(block["text"]))
            }
        default:
            break
        }
    }

    /// Codex rollouts. The user's words are read from `event_msg` only: a
    /// `response_item` user message also carries the instructions and the
    /// environment Codex injects.
    static func readCodex(_ object: [String: Any], into notes: inout Notes) {
        let payload = object["payload"] as? [String: Any] ?? [:]
        switch str(object["type"]) {
        case "turn_context":
            notes.setModel(str(payload["model"]))
        case "event_msg":
            switch str(payload["type"]) {
            case "user_message": notes.user(str(payload["message"]))
            case "agent_message": notes.agent(str(payload["message"]))
            case "error", "stream_error": notes.error(str(payload["message"]))
            case "item_completed":
                // 18.0 paginated history: completed turn items, tagged by type.
                guard let item = payload["item"] as? [String: Any] else { return }
                let words = blocks(item["content"])
                    .filter { str($0["type"]).lowercased() == "text" }
                    .map { str($0["text"]) }
                    .joined(separator: "\n")
                switch str(item["type"]).lowercased() {
                case "usermessage", "user_message": notes.user(words)
                case "agentmessage", "agent_message": notes.agent(words)
                default: break
                }
            default:
                break
            }
        case "response_item":
            guard str(payload["type"]) == "message", str(payload["role"]) == "assistant" else { return }
            let words = blocks(payload["content"])
                .filter { ["output_text", "text"].contains(str($0["type"])) }
                .map { str($0["text"]) }
                .joined(separator: "\n")
            notes.agent(words)
        default:
            break
        }
    }

    /// Pi sessions: `message` records and the `/name` a person gave it.
    static func readPi(_ object: [String: Any], into notes: inout Notes) {
        switch str(object["type"]) {
        case "session_info":
            // An empty name clears the title Pi shows.
            let name = promptTitle(str(object["name"]))
            notes.named = name.isEmpty ? nil : name
        case "model_change":
            notes.setModel(str(object["modelId"]))
        case "message":
            guard let message = object["message"] as? [String: Any] else { return }
            switch str(message["role"]) {
            case "user":
                notes.user(text(message["content"]))
            case "assistant":
                notes.setModel(str(message["model"]))
                let words = blocks(message["content"])
                    .filter { str($0["type"]) == "text" }
                    .map { str($0["text"]) }
                    .joined(separator: "\n")
                notes.agent(words)
                if str(message["stopReason"]) == "error" { notes.error(str(message["errorMessage"])) }
            case "toolResult":
                if message["isError"] as? Bool == true { notes.error(text(message["content"])) }
            default:
                break
            }
        default:
            break
        }
    }

    /// Copilot CLI events: `{type, data}`.
    static func readCopilot(_ object: [String: Any], into notes: inout Notes) {
        let data = object["data"] as? [String: Any] ?? [:]
        switch str(object["type"]) {
        case "user.message": notes.user(str(data["content"]))
        case "assistant.message":
            notes.setModel(str(data["model"]))
            notes.agent(str(data["content"]))
        case "session.error": notes.error(str(data["message"]))
        default: break
        }
    }

    /// Gemini's recording is a list with edits: `$set.messages` replaces
    /// it, `$rewindTo` drops a message and everything after it, and the same
    /// id is re-appended as a reply grows. Replayed once the window is read.
    struct GeminiLog {
        var order: [String] = []
        var messages: [String: [String: Any]] = [:]
        var summary = ""

        mutating func upsert(_ record: [String: Any]) {
            let id = TranscriptSummaryReader.str(record["id"])
            let key = id.isEmpty ? "#\(order.count)" : id
            if messages[key] == nil { order.append(key) }
            messages[key] = record
        }

        mutating func add(_ record: [String: Any]) {
            if let patch = record["$set"] as? [String: Any] {
                if let list = patch["messages"] as? [Any] {
                    order.removeAll()
                    messages.removeAll()
                    for item in list { if let message = item as? [String: Any] { upsert(message) } }
                }
                if let value = patch["summary"] as? String { summary = value }
                return
            }
            if let target = record["$rewindTo"] as? String {
                if let index = order.firstIndex(of: target) {
                    for key in order[index...] { messages[key] = nil }
                    order.removeSubrange(index...)
                }
                return
            }
            if record["type"] != nil {
                upsert(record)
            } else if let value = record["summary"] as? String {
                summary = value
            }
        }

        func replay(into notes: inout Notes) {
            let title = TranscriptSummaryReader.promptTitle(summary)
            if !title.isEmpty { notes.fallbackTitle = title }
            for key in order {
                guard let message = messages[key] else { continue }
                switch TranscriptSummaryReader.str(message["type"]) {
                case "user":
                    // What the person typed, when the CLI expanded it (@file).
                    let typed = TranscriptSummaryReader.text(message["displayContent"])
                    notes.user(typed.isEmpty ? TranscriptSummaryReader.text(message["content"]) : typed)
                case "gemini":
                    notes.setModel(TranscriptSummaryReader.str(message["model"]))
                    notes.agent(TranscriptSummaryReader.text(message["content"]))
                case "error":
                    notes.error(TranscriptSummaryReader.text(message["content"]))
                default:
                    break
                }
            }
        }
    }

    // MARK: - Words

    /// A prompt as a title: the wrappers vendors put around it removed, one
    /// line, bounded; "" when what is left is not something a person typed.
    package static func promptTitle(_ raw: String) -> String {
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
        // A slash command's echo (`<command-name>/init</command-name>`), a
        // local command's output, an injected caveat: not a prompt.
        guard folded.count >= 3, !folded.hasPrefix("<"), !folded.hasPrefix("# AGENTS.md") else { return "" }
        return folded.count > titleLimit ? String(folded.prefix(titleLimit - 1)) + "…" : folded
    }

    /// "continue", "go on", "继续" are not what a session is about.
    package static func isMeaningful(_ title: String) -> Bool {
        let compact = title.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        let continuations: Set<String> = [
            "continue", "goon", "proceed", "resume", "keepgoing", "yes", "ok", "okay",
            "继续", "继续吧", "好的", "可以",
        ]
        return !continuations.contains(compact)
    }

    /// The first non-empty line, sanitized and bounded.
    package static func firstLine(_ raw: String) -> String {
        for line in ContentSanitizer.redact(raw).split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            return trimmed.count > lineLimit ? String(trimmed.prefix(lineLimit - 1)) + "…" : trimmed
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

    // MARK: - JSON pieces

    static func str(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func blocks(_ value: Any?) -> [[String: Any]] {
        (value as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    /// A content value as text: a string, or the `text` of its parts.
    static func text(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let part = value as? [String: Any] { return str(part["text"]) }
        return (value as? [Any] ?? []).compactMap { part -> String? in
            if let string = part as? String { return string }
            guard let block = part as? [String: Any] else { return nil }
            let text = str(block["text"])
            return text.isEmpty ? nil : text
        }.joined(separator: "\n")
    }
}
