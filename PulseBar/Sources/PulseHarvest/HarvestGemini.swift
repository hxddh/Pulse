import Foundation
import PulseCore

// Gemini CLI chat recordings.
//
// 20.0 Drift. Checked against google-gemini/gemini-cli
// packages/core/src/services/chatRecordingService.ts and chatRecordingTypes.ts
// (commit pinned in docs/vendor-formats.json). What the vendor writes:
//
// - `~/.gemini/tmp/<project slug>/chats/session-<ts>-<id8>.jsonl`, append-only.
//   `~/.cache/.gemini/…` under the macOS Seatbelt sandbox. `.project_root` in
//   the slug directory holds the absolute project path.
// - Line 1 is metadata `{sessionId, projectHash, startTime, lastUpdated,
//   kind?, directories?}` — no cwd.
// - Messages `{id, timestamp, type, content, displayContent?, model?, …}`;
//   `type` is `user | gemini | info | error | warning`. A user message's
//   `content` is `[{text}]` (or `[{functionResponse}]` for a tool result the
//   CLI records as a user turn); a gemini message's `content` is a plain
//   string. The same `id` is re-appended when tokens or tool calls update.
// - `{"$set": {…}}` patches metadata; `{"$set": {"messages": [...]}}` is a
//   checkpoint that replaces the list; `{"$rewindTo": id}` drops that message
//   and everything after it.
// - Subagents write `chats/<parentSessionId>/<id>.jsonl` with
//   `kind: "subagent"` — part of the parent's session, not a row of its own.
// - Legacy `.json` files are one document `{…metadata, messages: [...]}`.
//
// Before 20.0 Pulse read Gemini as a whole-file document with a `model` role —
// a shape the CLI never wrote — so no Gemini session ever had a last word.

extension NativeActivityHarvest {
    /// One Gemini chat file → at most one fact. An empty result for a
    /// subagent file is an answer: it belongs to its parent's row.
    package static func parseGeminiFacts(_ text: String, path: String) -> [Fact] {
        var metadata: [String: Any] = [:]
        var order: [String] = []
        var messages: [String: [String: Any]] = [:]

        func upsert(_ record: [String: Any]) {
            let id = firstString(record, keys: ["id"])
            let key = id.isEmpty ? "#\(order.count)" : id
            if messages[key] == nil { order.append(key) }
            messages[key] = record
        }

        func replace(with list: [Any]) {
            order.removeAll()
            messages.removeAll()
            for item in list { if let record = item as? [String: Any] { upsert(record) } }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), !trimmed.contains("\n{"),
           let data = trimmed.data(using: .utf8),
           let whole = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           whole["messages"] is [Any] || whole["sessionId"] != nil {
            // Legacy whole-file session.
            metadata = whole
            replace(with: whole["messages"] as? [Any] ?? [])
        } else {
            for line in text.split(whereSeparator: \.isNewline) {
                let raw = line.trimmingCharacters(in: .whitespaces)
                guard raw.hasPrefix("{"),
                      let data = raw.data(using: .utf8),
                      let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                if let patch = record["$set"] as? [String: Any] {
                    if let list = patch["messages"] as? [Any] { replace(with: list) }
                    for (key, value) in patch where key != "messages" { metadata[key] = value }
                    continue
                }
                if let target = record["$rewindTo"] as? String {
                    if let index = order.firstIndex(of: target) {
                        for key in order[index...] { messages[key] = nil }
                        order.removeSubrange(index...)
                    }
                    continue
                }
                if record["type"] != nil, record["id"] != nil || record["content"] != nil {
                    upsert(record)
                } else if record["sessionId"] != nil {
                    for (key, value) in record { metadata[key] = value }
                }
            }
        }

        if firstString(metadata, keys: ["kind"]).lowercased() == "subagent" { return [] }
        guard !order.isEmpty || !metadata.isEmpty else { return [] }

        var fact = Fact()
        fact.structured = true
        fact.sourcePath = path
        fact.sessionID = firstString(metadata, keys: ["sessionId"])
        var latest = max(
            normalizeTimestamp(metadata["lastUpdated"]),
            normalizeTimestamp(metadata["startTime"])
        )
        var prompt = ""
        for key in order {
            guard let message = messages[key] else { continue }
            latest = max(latest, normalizeTimestamp(message["timestamp"]))
            switch firstString(message, keys: ["type"]).lowercased() {
            case "user":
                // What the user typed, when the CLI expanded it (@file).
                let typed = geminiText(message["displayContent"])
                let sent = typed.isEmpty ? geminiText(message["content"]) : typed
                let title = cleanPiSessionTitle(sent)
                if !title.isEmpty { prompt = title }
            case "gemini":
                let word = selfReportLine(geminiText(message["content"]))
                if !word.isEmpty { fact.lastWord = word }
                let model = firstString(message, keys: ["model"])
                if !model.isEmpty { fact.model = model }
                // `tokens {input, output, …}` is that call's usage.
                if let tokens = message["tokens"] as? [String: Any] {
                    let input = firstNumber(tokens, keys: ["input"])
                    let output = firstNumber(tokens, keys: ["output"])
                    if input > 0 { fact.tokensIn = input }
                    if output > 0 { fact.tokensOut = output }
                }
                // Tool calls are recorded once complete; the newest is the
                // session's most recent action.
                if let calls = message["toolCalls"] as? [Any],
                   let call = calls.last as? [String: Any] {
                    let name = clean(firstString(call, keys: ["name", "displayName"]), limit: 64)
                    if !name.isEmpty { fact.tool = name }
                }
            case "error":
                fact.errors += 1
            default:
                break
            }
        }
        if !prompt.isEmpty {
            fact.task = prompt
            fact.taskOrigin = .userPrompt
        } else {
            let summary = cleanPiSessionTitle(firstString(metadata, keys: ["summary"]))
            if !summary.isEmpty {
                fact.task = summary
                fact.taskOrigin = .cacheTitle
            }
        }
        fact.activityMs = latest
        return [fact]
    }

    /// Text of a Gemini `content` / `displayContent`: a plain string, or a
    /// part list whose `text` parts are joined. A `functionResponse` part is
    /// a tool result, not words.
    package static func geminiText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let part = value as? [String: Any] { return firstString(part, keys: ["text"]) }
        guard let parts = value as? [Any] else { return "" }
        return parts.compactMap { part -> String? in
            if let text = part as? String { return text }
            guard let block = part as? [String: Any] else { return nil }
            let text = firstString(block, keys: ["text"])
            return text.isEmpty ? nil : text
        }.joined(separator: "\n")
    }

    /// `~/.gemini/tmp/<slug>/chats/<session>.jsonl` and, for a subagent,
    /// `…/chats/<parent>/<session>.jsonl` → `<slug>/.project_root`.
    package static func geminiProjectRoot(for url: URL) -> String? {
        var directory = url.deletingLastPathComponent()
        for _ in 0..<3 {
            if directory.lastPathComponent == "chats" { break }
            directory = directory.deletingLastPathComponent()
        }
        guard directory.lastPathComponent == "chats" else { return nil }
        let marker = directory.deletingLastPathComponent().appendingPathComponent(".project_root")
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        let path = normalizedPath(text)
        return path.isEmpty ? nil : path
    }
}
