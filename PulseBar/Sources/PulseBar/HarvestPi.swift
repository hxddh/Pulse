import Foundation
import SQLite3

// Pi: session JSONL / SQLite titles, prompts and cwd.
//
// 12.3 γ: one vendor per file. Moved verbatim out of HarvestFacts.swift; the
// dispatch that picks a dialect for a transcript lives in
// TranscriptDialect.swift.

extension NativeActivityHarvest {
    /// Bounded regex salvage for a Pi assistant record too large to JSON-
    /// parse under the adapter deadline: model, usage tokens, and the last
    /// tool call's name. Only assistant/message lines — a tool-result body
    /// carries none of these at the JSON level, and JSON escaping keeps the
    /// patterns from matching inside quoted prose.
    static func piSalvageLargeLine(_ raw: String, into f: inout Fact) {
        let prefix = raw.prefix(384)
        guard prefix.contains("\"assistant\"")
                || prefix.contains("\"type\":\"message\"")
                || prefix.contains("\"type\": \"message\"")
        else { return }
        if f.model.isEmpty {
            let model = regexValue(raw, patterns: [#""model"\s*:\s*"([^"]+)""#])
            if !model.isEmpty { f.model = model }
        }
        if let tin = Int(regexValue(raw, patterns: [#""input(?:_tokens|Tokens)?"\s*:\s*(\d+)"#])) {
            f.tokensIn = max(f.tokensIn, tin)
        }
        if let tout = Int(regexValue(raw, patterns: [#""output(?:_tokens|Tokens)?"\s*:\s*(\d+)"#])) {
            f.tokensOut = max(f.tokensOut, tout)
        }
        if let name = regexLastValue(raw, pattern: #""type"\s*:\s*"(?:toolCall|tool_use|tool_call)"[^{}]*?"name"\s*:\s*"([^"]+)""#),
           !name.isEmpty {
            f.tool = name
        }
    }

    /// Last capture-group match in the text — the newest tool call in an
    /// append-ordered record.
    static func regexLastValue(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.matches(in: text, range: range).last,
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[valueRange])
    }

    static func piLineMightCarryTitle(_ raw: String) -> Bool {
        // Only the line prefix — megabyte tool records must stay O(1).
        let prefix = raw.prefix(384)
        return prefix.contains("session_info")
            || prefix.contains("retainedTail")
            || prefix.contains("\"role\":\"user\"")
            || prefix.contains("\"role\": \"user\"")
            || prefix.contains("\"type\":\"session\"")
            || prefix.contains("\"type\": \"session\"")
            || prefix.contains("\"type\":\"compaction\"")
            || prefix.contains("\"type\": \"compaction\"")
    }

    static func piLooksOfficial(_ text: String) -> Bool {
        for line in text.split(whereSeparator: \.isNewline).prefix(8) {
            let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.hasPrefix("{") else { continue }
            let prefix = raw.prefix(384)
            if prefix.contains("\"type\":\"session\"")
                || prefix.contains("\"type\": \"session\"")
                || prefix.contains("\"type\":\"message\"")
                || prefix.contains("\"type\": \"message\"")
                || prefix.contains("\"type\":\"session_info\"")
                || prefix.contains("\"type\": \"session_info\"") {
                return true
            }
        }
        return false
    }

    /// Official Pi JSONL (`https://pi.dev/docs/latest/session-format`):
    /// `~/.pi/agent/sessions/--<cwd-with-slashes-as-dashes>--/<timestamp>_<uuid>.jsonl`
    /// with a `type:session` header, `message.content` as string *or* text
    /// blocks, optional `session_info.name`, and compaction `retainedTail`.
    /// Compatibility fixtures with a top-level `title` still fall through.
    static func parsePiFacts(_ text: String, path: String) -> [Fact] {
        var headerID = ""
        var headerCwd = ""
        var sessionNames: [String] = []
        var userTitles: [String] = []
        var compactionUsers: [String] = []
        var compactionSummaries: [String] = []
        var latestTimestamp: Int64 = 0
        var f = Fact()
        f.structured = true
        f.sourcePath = path

        for line in text.split(whereSeparator: \.isNewline) {
            let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.hasPrefix("{") else { continue }
            // Tool-result bodies can be megabytes. JSON-parsing them blew the
            // adapter deadline and left the /resume title unread. 8.2: the
            // skipped lines are exactly the assistant records that carry
            // usage, model and tool calls — salvage those three by bounded
            // regex instead of losing them (JSON string content escapes its
            // quotes, so `"model":"…"` cannot match inside prose).
            if raw.count > 8_192, !piLineMightCarryTitle(raw) {
                piSalvageLargeLine(raw, into: &f)
                continue
            }
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let recordType = firstString(object, keys: ["type"]).lowercased()
            let stamped = normalizeTimestamp(firstValue(object, keys: [
                "timestamp", "created_at", "createdAt", "updated_at", "updatedAt",
            ]))
            if stamped > 0 { latestTimestamp = max(latestTimestamp, stamped) }

            if recordType == "session" {
                let sid = firstString(object, keys: ["id", "sessionId", "session_id"])
                if sid.count >= 8 { headerID = sid }
                let cwd = normalizedPath(firstString(object, keys: ["cwd"]))
                if !cwd.isEmpty { headerCwd = cwd }
            }
            if recordType == "session_info" {
                // Official getSessionName: latest `name`, empty/null clears.
                // Do not fall through to `title` when `name` is present and empty.
                if object["name"] != nil {
                    let raw = (object["name"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    sessionNames = raw.isEmpty ? [""] : [cleanPiSessionTitle(raw)]
                } else {
                    let title = firstString(object, keys: ["title"])
                    sessionNames = title.isEmpty ? [""] : [cleanPiSessionTitle(title)]
                }
            }
            if recordType == "compaction" {
                let summary = cleanPiSessionTitle(firstString(object, keys: ["summary"]))
                if !summary.isEmpty { compactionSummaries.append(summary) }
                if let tail = object["retainedTail"] as? [Any] {
                    for item in tail {
                        guard let message = item as? [String: Any] else { continue }
                        let role = firstString(message, keys: ["role", "type"]).lowercased()
                        if role == "user" || role == "human" {
                            let title = cleanPiSessionTitle(piContentText(message["content"]))
                            if !title.isEmpty { compactionUsers.append(title) }
                        }
                    }
                }
            }

            let userTitle = cleanPiSessionTitle(piUserText(from: object))
            if !userTitle.isEmpty { userTitles.append(userTitle) }

            var generic = fact(from: object, context: "pi.session", structured: true, path: path)
            generic.task = ""
            generic.taskOrigin = .none
            if recordType != "session" { generic.sessionID = "" }
            if ["tool_use", "tool_call", "function_call", "custom_tool_call", "file_read"]
                .contains(recordType) {
                // Cline-style `path` is a file, not a workspace. Adopting it
                // as cwd made long Pi transcripts look like they lived in
                // `/tmp/file-0.swift`.
                generic.cwd = ""
                generic.project = ""
            }
            if generic.hasUsefulSignal { merge(&f, generic) }
        }
        // Same rule as Codex above: this loop walks the read *window*, which
        // for Pi is 96 KB of head plus 400 KB of tail. Counting its lines
        // would be a floor presented as a total. `ingestTranscriptFile` gives
        // `records` its one honest value.

        // Pi /resume shows the latest session_info.name (empty clears),
        // else the first user message. Latest turn is only a fallback when
        // the opening prompt was chrome or an env wrapper we stripped.
        let named = sessionNames.last.flatMap { name -> String? in
            if name.isEmpty { return nil }
            let cleaned = cleanPiSessionTitle(name)
            if cleaned.isEmpty || isChromeTask(cleaned) { return nil }
            return cleaned
        }
        let task = named
            ?? firstMeaningfulPiTitle(userTitles)
            ?? latestMeaningfulPiTitle(userTitles)
            ?? latestMeaningfulPiTitle(compactionUsers)
            ?? latestMeaningfulPiTitle(compactionSummaries)
            ?? ""
        if task.isEmpty, sessionNames.filter({ !$0.isEmpty }).isEmpty, userTitles.isEmpty,
           compactionUsers.isEmpty, compactionSummaries.isEmpty {
            return []
        }

        f.task = task
        // `/name` is a title the user typed for this session; everything else
        // in the chain is a user turn recovered from the transcript.
        f.taskOrigin = task.isEmpty ? .none : (named == nil ? .userPrompt : .sessionName)
        if !headerID.isEmpty { f.sessionID = headerID }
        if f.sessionID.isEmpty { f.sessionID = piSessionID(from: URL(fileURLWithPath: path)) }
        if !headerCwd.isEmpty { f.cwd = headerCwd }
        if f.cwd.isEmpty {
            let decoded = piCwdFromPath(path)
            f.cwd = decoded.path
            if !decoded.path.isEmpty { f.cwdBestEffort = !decoded.verified }
        }
        if f.project.isEmpty, !f.cwd.isEmpty { f.project = lastPathComponent(f.cwd) }
        f.activityMs = latestTimestamp > 0 ? latestTimestamp : fileMTime(URL(fileURLWithPath: path))
        f.task = clean(f.task, limit: 160)
        f.cwd = clean(f.cwd, limit: 240)
        f.sessionID = clean(f.sessionID, limit: 80)
        f.tool = clean(f.tool, limit: 64)
        f.phase = clean(f.phase, limit: 64)
        f.model = clean(f.model, limit: 64)
        guard f.hasUsefulSignal else { return [] }
        // 8.2: Pi returned before the generic walker's tail, so the shape-
        // strict self-report scan (the agent's words, its failed results)
        // never ran for it — the one adapter fixed alone again. Run it here
        // on the same window.
        var result = [f]
        applyTranscriptSelfReport(&result, text: text)
        return result
    }

    static func firstMeaningfulPiTitle(_ titles: [String]) -> String? {
        for title in titles {
            let cleaned = cleanPiSessionTitle(title)
            if cleaned.isEmpty || isChromeTask(cleaned) { continue }
            if meaningfulPiPrompt(cleaned) { return cleaned }
        }
        for title in titles {
            let cleaned = cleanPiSessionTitle(title)
            if !cleaned.isEmpty, !isChromeTask(cleaned) { return cleaned }
        }
        return nil
    }

    static func latestMeaningfulPiTitle(_ titles: [String]) -> String? {
        guard !titles.isEmpty else { return nil }
        for title in titles.reversed() {
            let cleaned = cleanPiSessionTitle(title)
            if cleaned.isEmpty || isChromeTask(cleaned) { continue }
            if meaningfulPiPrompt(cleaned) { return cleaned }
        }
        for title in titles.reversed() {
            let cleaned = cleanPiSessionTitle(title)
            if !cleaned.isEmpty, !isChromeTask(cleaned) { return cleaned }
        }
        return nil
    }

    static func piUserText(from dict: [String: Any]) -> String {
        let envelope = dict["message"] as? [String: Any]
        let role = firstString(envelope ?? dict, keys: ["role", "type", "kind"]).lowercased()
        if role == "user" || role == "human"
            || role.contains("user_message") || role.contains("user-prompt") {
            let content = envelope?["content"] ?? firstValue(dict, keys: ["content", "text", "message"])
            return piContentText(content)
        }
        if firstString(dict, keys: ["type"]).lowercased() == "message", let envelope {
            if firstString(envelope, keys: ["role", "type"]).lowercased() == "user" {
                return piContentText(envelope["content"])
            }
        }
        return ""
    }

    static func piContentText(_ value: Any?) -> String {
        guard let value else { return "" }
        if let text = value as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let array = value as? [Any] {
            let parts = array.compactMap { item -> String? in
                if let text = item as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                guard let dict = item as? [String: Any] else { return nil }
                let text = firstString(dict, keys: ["text"])
                return text.isEmpty ? nil : text
            }
            return parts.joined(separator: " ")
        }
        if let dict = value as? [String: Any] {
            return piContentText(dict["content"] ?? dict["text"])
        }
        return ""
    }

    static func piEventPrompt(type: String, data: String) -> String? {
        if type == "file_read" { return nil }
        if let object = jsonObject(data) {
            let fromEnvelope = cleanPiSessionTitle(piUserText(from: object))
            if !fromEnvelope.isEmpty { return fromEnvelope }
            if ["intent", "user", "message", "prompt"].contains(type) {
                let nested = cleanPiSessionTitle(piContentText(
                    firstValue(object, keys: ["text", "content", "prompt", "query", "data"])
                ))
                if !nested.isEmpty { return nested }
            }
            return nil
        }
        guard ["intent", "user", "message", "prompt"].contains(type) else { return nil }
        let title = cleanPiSessionTitle(data)
        return title.isEmpty ? nil : title
    }

    static func cleanPiSessionTitle(_ value: String) -> String {
        let stripped = stripPiContextWrappers(value)
        let title = clean(stripped, limit: 160)
        if title.count < 3 { return "" }
        let low = title.lowercased()
        if low.hasPrefix("<environment_context")
            || low.hasPrefix("<recommended_plugins")
            || low.hasPrefix("<app-context")
            || low.hasPrefix("<system-reminder") {
            return ""
        }
        return title
    }

    /// Keep the real prompt when Pi (or a wrapper) prepends env/plugin XML.
    /// Rejecting the whole string because it *starts* with those tags blanked
    /// every official user turn that carries context + goal in one `content`.
    static func stripPiContextWrappers(_ raw: String) -> String {
        if let query = piTaggedInner(raw, name: "user_query"), query.count >= 3 {
            return query
        }
        var text = raw
        for tag in [
            "environment_context", "recommended_plugins", "app-context",
            "system-reminder", "git_status", "git-status",
        ] {
            text = piRemoveTaggedBlocks(text, name: tag)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func piTaggedInner(_ text: String, name: String) -> String? {
        let open = "<\(name)"
        let close = "</\(name)>"
        guard let start = text.range(of: open, options: .caseInsensitive),
              let gt = text.range(of: ">", range: start.upperBound..<text.endIndex),
              let end = text.range(of: close, options: .caseInsensitive, range: gt.upperBound..<text.endIndex)
        else { return nil }
        let inner = text[gt.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : String(inner)
    }

    static func piRemoveTaggedBlocks(_ text: String, name: String) -> String {
        var s = text
        let open = "<\(name)"
        let close = "</\(name)>"
        while let start = s.range(of: open, options: .caseInsensitive) {
            if let gt = s.range(of: ">", range: start.upperBound..<s.endIndex),
               let end = s.range(of: close, options: .caseInsensitive, range: gt.upperBound..<s.endIndex) {
                s.removeSubrange(start.lowerBound..<end.upperBound)
                continue
            }
            // Truncated / unclosed env dump: drop from the open tag to the
            // end so `cwd:` lines cannot become the tray hero.
            s.removeSubrange(start.lowerBound..<s.endIndex)
            break
        }
        return s
    }

    static func meaningfulPiPrompt(_ value: String) -> Bool {
        let title = cleanPiSessionTitle(value)
        if title.isEmpty { return false }
        let compact = title
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: "！", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "？", with: "")
        let continuations: Set<String> = [
            "continue", "goon", "proceed", "resume", "keepgoing",
            "继续", "继续分析", "继续修复", "继续处理", "继续推进",
            "progress", "status", "statusupdate", "howisitgoing", "whatsprogress",
            "进展如何", "进度如何", "状态如何", "现在怎么样",
            "release", "publish", "ship", "发布", "合入发布",
        ]
        return !continuations.contains(compact)
    }

    static func piSessionID(from url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        // Official files are `<ISO-timestamp>_<uuid>.jsonl`. The header `id`
        // is the UUID; using the whole stem blocked SQLite merge.
        if let idx = stem.lastIndex(of: "_") {
            let rest = String(stem[stem.index(after: idx)...])
            if rest.count >= 8 { return String(rest.prefix(80)) }
        }
        let generic: Set<String> = [
            "session", "sessions", "events", "event", "messages",
            "conversation", "history", "transcript", "log",
        ]
        if stem.count >= 6, !generic.contains(stem.lowercased()) {
            return String(stem.prefix(80))
        }
        let parent = url.deletingLastPathComponent().lastPathComponent
        if parent.hasPrefix("--"), parent.hasSuffix("--") { return "" }
        if parent.count >= 6, !["sessions", "agent", "pi"].contains(parent.lowercased()) {
            return String(parent.prefix(80))
        }
        return sessionIDFromPath(url)
    }

    /// `--Users-me-Pulse--` → `/Users/me/Pulse` (Pi encodes `/` as `-`).
    ///
    /// Same ambiguity, same resolution, as `decodeClaudeProjectDir`.
    static func piCwdFromPath(_ path: String) -> (path: String, verified: Bool) {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        guard parent.hasPrefix("--"), parent.hasSuffix("--"), parent.count > 4 else { return ("", false) }
        var encoded = parent
        encoded.removeFirst(2)
        encoded.removeLast(2)
        let parts = encoded.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return ("", false) }
        let resolved = resolveDashEncodedPath(parts)
        return (normalizedPath(resolved.path), resolved.verified)
    }

    /// Empty SQLite Pi rows (cwd + file_read, no prompt) must not occupy the
    /// tray when JSONL already has the session title — often under a different
    /// identity (`timestamp_uuid` vs header UUID) before 0.97.
    static func dropEmptyPiSqliteDuplicates(_ facts: inout [Fact]) {
        let titledJSONL = facts.filter { fact in
            let path = fact.sourcePath.lowercased()
            guard path.hasSuffix(".jsonl") || path.hasSuffix(".ndjson") else { return false }
            let task = cleanPiSessionTitle(fact.task)
            return !task.isEmpty && !isChromeTask(task)
                && !AgentRow.looksLikeFilenameOnlyTitle(task)
        }
        guard !titledJSONL.isEmpty else { return }
        let ids = Set(titledJSONL.map(\.sessionID).filter { !$0.isEmpty })
        let cwds = Set(titledJSONL.map(\.cwd).filter { !$0.isEmpty })
        facts.removeAll { fact in
            let path = fact.sourcePath.lowercased()
            guard path.hasSuffix(".sqlite") || path.hasSuffix(".db") else { return false }
            let empty = fact.task.isEmpty || isChromeTask(fact.task)
                || AgentRow.looksLikeFilenameOnlyTitle(fact.task)
            guard empty else { return false }
            if !fact.sessionID.isEmpty, ids.contains(fact.sessionID) { return true }
            if !fact.cwd.isEmpty, cwds.contains(fact.cwd) { return true }
            return false
        }
    }

    static func isPiSqlitePath(_ path: String) -> Bool {
        let lower = path.lowercased()
        guard lower.contains("/.pi/") else { return false }
        return lower.hasSuffix(".sqlite") || lower.hasSuffix(".db")
    }

    static func piJSONLResumeTitle(_ path: String, _ task: String) -> Bool {
        let lower = path.lowercased()
        guard lower.contains("/.pi/"),
              lower.hasSuffix(".jsonl") || lower.hasSuffix(".ndjson")
        else { return false }
        let cleaned = cleanPiSessionTitle(task)
        return !cleaned.isEmpty && !isChromeTask(cleaned)
            && !AgentRow.looksLikeFilenameOnlyTitle(cleaned)
    }
}
