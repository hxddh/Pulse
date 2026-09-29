import Foundation
import PulseCore
import SQLite3

// The native collector's SQLite readers — Cursor, OpenCode and Pi keep their authoritative session metadata in databases. Which agent
// uses which reader is its `HarvestWalk.database` in AgentCatalog.

extension NativeActivityHarvest {
    // MARK: - Native SQLite adapters

    /// OpenCode and Pi store their authoritative session metadata
    /// in SQLite. Falling back to a generic file walk makes those agents look
    /// absent even while they have many sessions. These readers only prepare
    /// read-only statements, cap rows, and share the same global byte budget.
    package static func collectDatabase(
        _ url: URL,
        adapter: DatabaseAdapter,
        home: URL,
        into facts: inout [Fact],
        budget: ScanBudget,
        error: inout Bool
    ) {
        if adapter == .cursor {
            // Cursor's reader manages its own connection and budget: it also
            // resolves workspace databases that sit beside this one.
            collectCursorDatabase(url, into: &facts, budget: budget, error: &error)
            return
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { return }
        guard budget.reserve(min(size, maxFileBytes)) else {
            budget.noteBudgetDenied()
            return
        }
        var database: OpaquePointer?
        let status = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard status == SQLITE_OK, let database else {
            // Pi JSONL is the title source. A sibling that is not SQLite
            // must not fail the adapter (that froze lastGoodHarvest empty).
            if adapter.failsOnUnreadableFile { error = true }
            if database != nil { sqlite3_close(database) }
            return
        }
        budget.noteFileRead()
        defer { sqlite3_close(database) }
        switch adapter {
        case .cursor:
            return  // handled above
        case .openCode:
            collectOpenCodeDatabase(database, url: url, into: &facts, error: &error)
        case .pi:
            collectPiDatabase(database, url: url, home: home, into: &facts, error: &error)
            // A non-session_meta sibling must not fail the JSONL adapter.
            return
        }
        // A locked, corrupt, or non-SQLite file can successfully open and only
        // fail on the first prepared statement/step. Do not turn that into a
        // healthy zero-session result: the caller must retain the previous
        // adapter rows and expose a retryable Support Health state.
        if sqliteReadFailed(database) { error = true }
    }

    package static func collectOpenCodeDatabase(
        _ database: OpaquePointer,
        url: URL,
        into facts: inout [Fact],
        error: inout Bool
    ) {
        // 20.0: a subagent session (`parent_id` set, titled "… (@agent
        // subagent)") is part of its parent's work, not a row of its own.
        // Databases from before `parent_id` existed fall back to all sessions.
        func query(_ filter: String) -> String {
            """
            SELECT id, title, directory, agent, model, tokens_input, tokens_output,
                   time_created, time_updated, summary_files
            FROM session
            WHERE IFNULL(time_archived, 0) = 0\(filter)
            ORDER BY time_updated DESC
            LIMIT \(maxRowsPerAgent)
            """
        }
        guard let statement = sqlitePrepare(database, query(" AND parent_id IS NULL"))
            ?? sqlitePrepare(database, query(""))
        else {
            error = true
            return
        }
        defer { sqlite3_finalize(statement) }

        // 0.95: never smear a project-level permission-ruleset update onto every
        // session. Waiting comes only from this session's tool parts.
        while sqlite3_step(statement) == SQLITE_ROW {
            let sid = sqliteString(statement, column: 0)
            guard !sid.isEmpty else { continue }
            // 20.0: "New session - <ISO>" is OpenCode's placeholder until its
            // title model answers — and forever when that fails. The user's
            // own first prompt is the truer title.
            var title = sqliteString(statement, column: 1)
            if isOpenCodePlaceholderTitle(title) {
                title = openCodeFirstUserText(database, sessionID: sid)
            }
            let cwd = normalizedPath(sqliteString(statement, column: 2))
            let agent = sqliteString(statement, column: 3)
            let model = modelIdentifier(sqliteString(statement, column: 4))
            let tin = sqlite3_column_int64(statement, 5)
            let tout = sqlite3_column_int64(statement, 6)
            let created = sqlite3_column_int64(statement, 7)
            let updated = sqlite3_column_int64(statement, 8)
            guard !title.isEmpty || !cwd.isEmpty || tin > 0 || tout > 0 else { continue }

            var values: [String: Any] = [
                "sessionId": sid,
                "title": title,
                "cwd": cwd,
                "agentMode": agent,
                "model": model,
                "inputTokens": tin,
                "outputTokens": tout,
            ]
            var fact = fact(from: values, context: "opencode.session", structured: true, path: url.path)
            fact.sessionID = sid
            // 20.0: `session.time_updated` moves only when a prompt starts;
            // every part upsert stamps its own `time_updated`, so the newest
            // part is when the session last did anything.
            let touched = max(normalizeTimestamp(updated), openCodeLatestPartMs(database, sessionID: sid))
            fact.activityMs = touched > 0 ? touched : fileMTime(url)
            fact.startedMs = normalizeTimestamp(created)
            fact.records = openCodePartCount(database, sessionID: sid)
            enrichOpenCodeParts(database, sessionID: sid, fact: &fact)
            // 9.0: the agent's words, with the role taken from the message
            // table — a text part alone has no author, and guessing one
            // would pass the user's words off as the agent's.
            if fact.lastWord.isEmpty {
                fact.lastWord = openCodeLastWord(database, sessionID: sid)
            }
            if fact.hasUsefulSignal { facts.append(fact) }
            if facts.count >= maxFactsPerAgent { break }
            values.removeAll(keepingCapacity: false)
        }
    }

    /// 9.0 — the latest assistant message's text, via the message table's
    /// role. Every step is guarded: a schema without these tables or columns
    /// returns "" (absence, never a guess), and `rowid` ordering needs no
    /// vendor timestamp column to exist.
    package static func openCodeLastWord(_ database: OpaquePointer, sessionID: String) -> String {
        let messageSQL = "SELECT id, data FROM message WHERE session_id = ? ORDER BY rowid DESC LIMIT 40"
        guard let messages = sqlitePrepare(database, messageSQL),
              sqliteBind(messages, index: 1, text: sessionID) else { return "" }
        defer { sqlite3_finalize(messages) }
        while sqlite3_step(messages) == SQLITE_ROW {
            let messageID = sqliteString(messages, column: 0)
            guard !messageID.isEmpty,
                  let object = jsonObject(sqliteString(messages, column: 1)),
                  firstString(object, keys: ["role"]).lowercased() == "assistant"
            else { continue }
            let partSQL = "SELECT data FROM part WHERE message_id = ? ORDER BY rowid DESC LIMIT 40"
            guard let parts = sqlitePrepare(database, partSQL),
                  sqliteBind(parts, index: 1, text: messageID) else { return "" }
            defer { sqlite3_finalize(parts) }
            while sqlite3_step(parts) == SQLITE_ROW {
                guard let part = jsonObject(sqliteString(parts, column: 0)),
                      firstString(part, keys: ["type"]).lowercased() == "text"
                else { continue }
                let line = selfReportLine(firstString(part, keys: ["text"]))
                if !line.isEmpty { return line }
            }
            // The newest assistant message carried no text part — honest empty
            // beats reaching further back and calling old words current.
            return ""
        }
        return ""
    }

    package static func isOpenCodePlaceholderTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty
            || trimmed.hasPrefix("New session - ")
            || trimmed.hasPrefix("Child session - ")
    }

    /// The first text part of the session's first user message.
    package static func openCodeFirstUserText(_ database: OpaquePointer, sessionID: String) -> String {
        let messageSQL = "SELECT id, data FROM message WHERE session_id = ? ORDER BY rowid ASC LIMIT 20"
        guard let messages = sqlitePrepare(database, messageSQL),
              sqliteBind(messages, index: 1, text: sessionID) else { return "" }
        defer { sqlite3_finalize(messages) }
        while sqlite3_step(messages) == SQLITE_ROW {
            let messageID = sqliteString(messages, column: 0)
            guard !messageID.isEmpty,
                  let object = jsonObject(sqliteString(messages, column: 1)),
                  firstString(object, keys: ["role"]).lowercased() == "user"
            else { continue }
            let partSQL = "SELECT data FROM part WHERE message_id = ? ORDER BY rowid ASC LIMIT 20"
            guard let parts = sqlitePrepare(database, partSQL),
                  sqliteBind(parts, index: 1, text: messageID) else { return "" }
            defer { sqlite3_finalize(parts) }
            while sqlite3_step(parts) == SQLITE_ROW {
                guard let part = jsonObject(sqliteString(parts, column: 0)),
                      firstString(part, keys: ["type"]).lowercased() == "text",
                      !anyTruthy(part, keys: ["synthetic", "ignored"])
                else { continue }
                let title = clean(firstString(part, keys: ["text"]), limit: 160)
                if !title.isEmpty { return title }
            }
            return ""
        }
        return ""
    }

    package static func openCodeLatestPartMs(_ database: OpaquePointer, sessionID: String) -> Int64 {
        let sql = "SELECT MAX(time_updated) FROM part WHERE session_id = ?"
        guard let statement = sqlitePrepare(database, sql) else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqliteBind(statement, index: 1, text: sessionID), sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return normalizeTimestamp(sqlite3_column_int64(statement, 0))
    }

    package static func openCodePartCount(_ database: OpaquePointer, sessionID: String) -> Int {
        let sql = "SELECT COUNT(*) FROM part WHERE session_id = ?"
        guard let statement = sqlitePrepare(database, sql) else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqliteBind(statement, index: 1, text: sessionID), sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return max(0, Int(sqlite3_column_int64(statement, 0)))
    }

    package static func enrichOpenCodeParts(_ database: OpaquePointer, sessionID: String, fact: inout Fact) {
        let sql = "SELECT data FROM part WHERE session_id = ? ORDER BY time_updated DESC LIMIT 80"
        guard let statement = sqlitePrepare(database, sql), sqliteBind(statement, index: 1, text: sessionID) else { return }
        defer { sqlite3_finalize(statement) }
        // Newest tool status wins — do not OR historical pending across the
        // whole transcript (0.95 Extinguish Honesty).
        var decidedPending = false
        while sqlite3_step(statement) == SQLITE_ROW {
            let raw = sqliteString(statement, column: 0)
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dict = object as? [String: Any]
            else { continue }
            let type = firstString(dict, keys: ["type"]).lowercased()
            if type == "tool", fact.tool.isEmpty {
                fact.tool = clean(firstString(dict, keys: ["tool", "name"]), limit: 64)
            }
            if type == "tool", let state = dict["state"] as? [String: Any], !decidedPending {
                let status = firstString(state, keys: ["status"]).lowercased()
                let tool = firstString(dict, keys: ["tool", "name"]).lowercased()
                // 20.0 Drift — checked against anomalyco/opencode
                // (packages/opencode/src/session/processor.ts, permission/index.ts):
                // `pending` is the tool input still streaming, and a tool
                // waiting on a permission prompt stays `running` while the ask
                // itself lives only in memory. Before 20.0 Pulse lit red on
                // every `pending` — a fake Waiting on every tool call. The one
                // blocked state the database does record is the `question`
                // tool, which only ever waits for the user.
                if status == "running" || status == "pending" {
                    fact.phase = "working"
                }
                if status == "running", tool == "question" {
                    fact.explicitPending = true
                    fact.skill = "pending"
                    decidedPending = true
                } else if status == "running" || status == "pending" {
                    decidedPending = true
                } else if status.contains("complete") || status == "error" || status == "rejected" {
                    fact.outcome = status.contains("complete") ? "completed" : fact.outcome
                    decidedPending = true
                }
            }
            if type == "step-finish" || type == "step_finish" {
                fact.phase = fact.phase.isEmpty ? "turn_complete" : fact.phase
                let reason = firstString(dict, keys: ["reason"]).lowercased()
                if ["stop", "complete", "completed"].contains(reason) { fact.outcome = "completed" }
            }
        }
    }

    package static func collectPiDatabase(
        _ database: OpaquePointer,
        url: URL,
        home: URL,
        into facts: inout [Fact],
        error: inout Bool
    ) {
        let sql = "SELECT session_id, project_dir, started_at, last_event_at, event_count FROM session_meta ORDER BY COALESCE(last_event_at, started_at) DESC LIMIT \(maxRowsPerAgent)"
        guard let statement = sqlitePrepare(database, sql) else {
            // ~/.pi trees contain JSONL plus incidental .db files. Missing
            // session_meta is not a harvest failure — JSONL still has titles.
            return
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            let sid = sqliteString(statement, column: 0)
            guard !sid.isEmpty else { continue }
            let cwd = normalizedPath(sqliteString(statement, column: 1))
            let started = normalizeTimestamp(sqliteString(statement, column: 2))
            let updated = normalizeTimestamp(sqliteString(statement, column: 3))
            let records = max(0, Int(sqlite3_column_int64(statement, 4)))
            let homePath = home.standardizedFileURL.path
            guard records > 0 || (!cwd.isEmpty && cwd != homePath) else { continue }
            var values: [String: Any] = [
                "sessionId": sid,
                "cwd": cwd,
                "agentMode": "Pi",
            ]
            // `event_count` is how many events the session logged — a
            // record count (`fact.records`), never plan progress. As
            // `progressTotal` it drew a "0 / 412" bar no plan ever had.
            var fact = fact(from: values, context: "pi.context_mode.session", structured: true, path: url.path)
            fact.sessionID = sid
            fact.startedMs = started
            fact.activityMs = updated > 0 ? updated : (started > 0 ? started : fileMTime(url))
            fact.records = records
            enrichPiEvents(database, sessionID: sid, fact: &fact)
            if fact.hasUsefulSignal { facts.append(fact) }
            if facts.count >= maxFactsPerAgent { break }
            values.removeAll(keepingCapacity: false)
        }
    }

    package static func enrichPiEvents(_ database: OpaquePointer, sessionID: String, fact: inout Fact) {
        let sql = "SELECT type, category, data, project_dir, created_at, bytes_returned FROM session_events WHERE session_id = ? ORDER BY id DESC LIMIT 128"
        guard let statement = sqlitePrepare(database, sql), sqliteBind(statement, index: 1, text: sessionID) else { return }
        defer { sqlite3_finalize(statement) }
        var foundMeaningfulPrompt = false
        var decidedSessionInfo = false
        while sqlite3_step(statement) == SQLITE_ROW {
            let type = sqliteString(statement, column: 0).lowercased()
            let category = sqliteString(statement, column: 1)
            let data = sqliteString(statement, column: 2)
            // Newest events first. Keep the latest meaningful user prompt;
            // never promote file_read paths into the tray hero (those used
            // to become "Read Foo.swift" and then block a shorter JSONL title).
            if let prompt = piEventPrompt(type: type, data: data), !prompt.isEmpty {
                if meaningfulPiPrompt(prompt) {
                    if !foundMeaningfulPrompt {
                        fact.task = prompt
                        fact.taskOrigin = .userPrompt
                        foundMeaningfulPrompt = true
                    }
                } else if !foundMeaningfulPrompt, fact.task.isEmpty || isChromeTask(fact.task) {
                    fact.task = prompt
                    fact.taskOrigin = .userPrompt
                }
            }
            if !decidedSessionInfo, type == "session_info" {
                decidedSessionInfo = true
                let raw = firstString(jsonObject(data) ?? [:], keys: ["name", "title"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.isEmpty {
                    // /name cleared — do not adopt an older session_info later.
                    if !foundMeaningfulPrompt {
                        fact.task = ""
                        fact.taskOrigin = .none
                    }
                } else {
                    let name = cleanPiSessionTitle(raw)
                    if !name.isEmpty, !isChromeTask(name), !foundMeaningfulPrompt {
                        fact.task = name
                        fact.taskOrigin = .sessionName
                        foundMeaningfulPrompt = meaningfulPiPrompt(name)
                    }
                }
            }
            if type == "tool_call" && fact.tool.isEmpty {
                if let object = jsonObject(data) { fact.tool = clean(firstString(object, keys: ["tool", "name"]), limit: 64) }
                if fact.tool.isEmpty { fact.tool = clean(category, limit: 64) }
                fact.phase = fact.phase.isEmpty ? "working" : fact.phase
            }
            if type.contains("error") { fact.errors += 1 }
            if type == "file_read", fact.phase.isEmpty { fact.phase = "reading" }
            if type.contains("sandbox") { fact.phase = "running" }
            // 0.95: never stamp pending from free-text event payloads.
            if type == "agent_usage" {
                let (tin, tout) = tokenPair(data)
                fact.tokensIn = max(fact.tokensIn, tin)
                fact.tokensOut = max(fact.tokensOut, tout)
            }
            // Prefer structured event JSON when present — agent_usage often
            // carries model + usageMetadata that the legacy tokens_in regex
            // never saw (0.82 Tray Fleet Substance).
            if let object = jsonObject(data) {
                if fact.model.isEmpty {
                    fact.model = clean(firstString(object, keys: [
                        "model", "modelId", "model_id", "modelName", "model_name",
                        "currentModel", "current_model",
                    ]), limit: 64)
                    if fact.model.isEmpty,
                       let details = object["modelDetails"] as? [String: Any]
                        ?? object["model_details"] as? [String: Any] {
                        fact.model = clean(firstString(details, keys: [
                            "modelName", "model_name", "model", "modelId", "model_id", "name",
                        ]), limit: 64)
                    }
                }
                applyTokenUsage(&fact, object)
                applyTokenUsage(&fact, object["usage"] as? [String: Any])
                applyTokenUsage(&fact, object["usageMetadata"] as? [String: Any])
                applyTokenUsage(&fact, object["usage_metadata"] as? [String: Any])
            }
            if fact.activityMs == 0 {
                fact.activityMs = normalizeTimestamp(sqliteString(statement, column: 4))
            }
            if fact.cwd.isEmpty { fact.cwd = normalizedPath(sqliteString(statement, column: 3)) }
            if Int(sqlite3_column_int64(statement, 5)) > 0 { fact.records = max(fact.records, recordsFromBytes(sqlite3_column_int64(statement, 5))) }
        }
    }

    package static func recordsFromBytes(_ bytes: Int64) -> Int { bytes > 0 ? 1 : 0 }

    package static func tokenPair(_ text: String) -> (Int, Int) {
        let input = regexInt(text, pattern: #"tokens_in\s*:\s*(\d+)"#)
        let output = regexInt(text, pattern: #"tokens_out\s*:\s*(\d+)"#)
        return (input, output)
    }

    package static func regexInt(_ text: String, pattern: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return 0 }
        return Int(text[range]) ?? 0
    }

    package static func sqlitePrepare(_ database: OpaquePointer, _ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        return statement
    }

    package static func sqliteBind(_ statement: OpaquePointer, index: Int32, text: String) -> Bool {
        sqlite3_bind_text(
            statement,
            index,
            text,
            -1,
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        ) == SQLITE_OK
    }

    package static func modelIdentifier(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        if let object = jsonObject(raw) {
            return firstString(object, keys: ["id", "model", "modelID", "model_id"])
        }
        return raw
    }

    package static func jsonObject(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return value as? [String: Any]
    }

    package static func jsonFirstText(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data)
        else { return "" }
        return jsonFirstString(value, keys: ["text", "query", "prompt", "initial_query"])
    }

    package static func jsonFirstTool(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data)
        else { return "" }
        return jsonFirstString(value, keys: ["tool", "tool_name", "name"])
    }

    package static func jsonFirstString(_ value: Any, keys: [String]) -> String {
        if let dict = value as? [String: Any] {
            let text = firstString(dict, keys: keys)
            if !text.isEmpty { return text }
            for child in dict.values {
                if let found = jsonFirstStringOptional(child, keys: keys), !found.isEmpty { return found }
            }
        } else if let array = value as? [Any] {
            for child in array.reversed() {
                if let found = jsonFirstStringOptional(child, keys: keys), !found.isEmpty { return found }
            }
        }
        return ""
    }

    package static func jsonFirstStringOptional(_ value: Any, keys: [String]) -> String? {
        let found = jsonFirstString(value, keys: keys)
        return found.isEmpty ? nil : found
    }

    package static func isSessionPath(_ url: URL) -> Bool {
        let parts = url.pathComponents.map { $0.lowercased() }
        let ext = url.pathExtension.lowercased()
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        let namedTranscript = ["rollout", "session", "conversation", "thread", "transcript", "history"]
            .contains(where: { stem == $0 || stem.hasPrefix($0 + "-") || stem.hasPrefix($0 + "_") })
        // `sessions` / `threads` directories must count — exact needle equality
        // missed Pi's `.../sessions/*.jsonl` and Goose `session.json`.
        let partHit = parts.contains(where: { part in
            sessionNeedles.contains(where: { needle in
                part == needle || part.hasPrefix(needle)
            })
        })
        return partHit
            || parts.contains(where: { $0.contains("rollout") || $0.contains("transcript") })
            || (["jsonl", "ndjson", "json"].contains(ext) && namedTranscript)
    }

    package static func sessionIDFromPath(_ url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let cleaned = stem.replacingOccurrences(of: "rollout-", with: "")
        guard cleaned.count >= 6,
              !["history", "sessions", "conversation", "messages"].contains(cleaned.lowercased())
        else { return "" }
        return String(cleaned.prefix(80))
    }

    package static func readWindow(
        _ url: URL,
        size: Int,
        budget: ScanBudget,
        cap: Int,
        headLimit: Int = 64_000
    ) -> (text: String, truncated: Bool)? {
        // The newest event is at the tail of the append-only transcripts. The
        // caller gives Codex a wider window because its compacted context is a
        // single large JSONL record; Pi keeps the session header and first
        // user prompt at the head and /name + compaction at the tail. Every
        // window remains bounded by the process-wide 48 MB budget.
        let headSize = max(64_000, headLimit)
        let window = max(headSize, cap)
        do {
            if size <= window {
                guard budget.reserve(size) else {
                    budget.noteBudgetDenied()
                    return nil
                }
                budget.noteFileRead()
                let whole = String(
                    decoding: try Data(contentsOf: url, options: [.mappedIfSafe]),
                    as: UTF8.self
                )
                return (whole, false)
            }
            guard budget.reserve(window) else {
                budget.noteBudgetDenied()
                return nil
            }
            budget.noteFileRead()
            budget.noteTruncated()
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let tailSize = window - headSize
            var head = try handle.read(upToCount: headSize) ?? Data()
            // A Pi user turn can be one JSONL record larger than the head
            // slice. Split records fail JSON parse and the tray hero goes
            // blank. Extend to the next newline so the first prompt survives.
            if head.last != 0x0A {
                var extra = 0
                while extra < 2_000_000 {
                    guard budget.reserve(64_000) else {
                        // The window itself was read; a refused head
                        // extension is a truncation, not a denied file.
                        budget.noteTruncated()
                        break
                    }
                    guard let chunk = try handle.read(upToCount: 64_000), !chunk.isEmpty else { break }
                    head.append(chunk)
                    extra += chunk.count
                    if chunk.contains(0x0A) { break }
                }
            }
            if let lastNL = head.lastIndex(of: 0x0A) {
                head = Data(head[head.startIndex...lastNL])
            }
            handle.seek(toFileOffset: UInt64(max(0, size - tailSize)))
            var tail = try handle.read(upToCount: tailSize) ?? Data()
            if let firstNL = tail.firstIndex(of: 0x0A), firstNL > tail.startIndex {
                tail = Data(tail[tail.index(after: firstNL)...])
            }
            // The tail can begin in the middle of a multi-byte character (or
            // a JSONL record). Lossy UTF-8 decoding keeps the following
            // complete lines available instead of turning one large rollout
            // into an empty adapter result.
            return (String(decoding: head + Data("\n".utf8) + tail, as: UTF8.self), true)
        } catch {
            return nil
        }
    }

    /// Cursor keeps its composer headers in SQLite rather than JSON files.
    /// Foundation has no high-level SQLite API, but macOS ships the SQLite3
    /// C module; using its read-only interface keeps this adapter native and
    /// avoids reviving the Python dependency just for Cursor.
    package static func collectCursorDatabase(
        _ url: URL,
        into facts: inout [Fact],
        budget: ScanBudget,
        error: inout Bool
    ) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // SQLite is queried by indexed metadata rather than copied into
        // memory. Reserve the same bounded budget as a large text window but
        // do not discard a real Cursor database merely because its cache grew.
        guard size > 0 else { return }
        guard budget.reserve(min(size, maxFileBytes)) else {
            budget.noteBudgetDenied()
            return
        }
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, let database else {
            error = true
            if database != nil { sqlite3_close(database) }
            return
        }
        budget.noteFileRead()
        defer { sqlite3_close(database) }

        let composerSQL = """
        SELECT composerId, workspaceId, lastUpdatedAt, value
        FROM composerHeaders
        WHERE IFNULL(isArchived, 0) = 0 AND IFNULL(isSubagent, 0) = 0
        ORDER BY lastUpdatedAt DESC
        LIMIT \(maxRowsPerAgent)
        """
        // Cursor versions do not all ship the cloud-agent ItemTable. Treat
        // each table as an optional capability: a missing table must not turn
        // valid Composer data into a collector failure. Lock/corrupt errors
        // still surface through sqliteReadFailed below.
        if let statement = sqlitePrepare(database, composerSQL) {
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                let sessionID = sqliteString(statement, column: 0)
                guard !sessionID.isEmpty, sessionID != "empty-state-draft" else { continue }
                let workspaceID = sqliteString(statement, column: 1)
                let updated = sqlite3_column_int64(statement, 2)
                let value = sqliteString(statement, column: 3)
                // Composer headers are compact metadata objects without a
                // session-shaped filename. Give the parser an explicit
                // session context so usage/pending/file fields survive the
                // conservative identity gate instead of falling back to a
                // title-only Fact.
                var parsed = parseFacts(
                    value,
                    structured: true,
                    path: url.path + "/composer"
                )
                if parsed.isEmpty { parsed = [Fact()] }
                for index in parsed.indices {
                    parsed[index].sessionID = sessionID
                    if parsed[index].task.isEmpty, let object = jsonObject(value) {
                        // Cursor's composer header calls the user-visible title
                        // `name`, unlike the transcript adapters' `title`.
                        parsed[index].task = clean(firstString(object, keys: ["name", "subtitle", "title"]), limit: 160)
                        if !parsed[index].task.isEmpty {
                            parsed[index].taskOrigin = .sessionName
                        }
                    }
                    parsed[index].cwd = parsed[index].cwd.isEmpty
                        ? cursorWorkspacePath(databaseURL: url, workspaceID: workspaceID)
                        : parsed[index].cwd
                    parsed[index].project = parsed[index].project.isEmpty
                        ? lastPathComponent(parsed[index].cwd)
                        : parsed[index].project
                    parsed[index].activityMs = updated > 0 ? updated : fileMTime(url)
                    parsed[index].sourcePath = url.path
                    parsed[index].structured = true
                    // 9.0: the conversation bubbles live in the same store's
                    // KV table — the latest assistant bubble is the row's
                    // last word. Any schema mismatch returns "" (absence).
                    if parsed[index].lastWord.isEmpty {
                        parsed[index].lastWord = cursorLastWord(database, composerID: sessionID)
                    }
                    // Do not invent mode=local — readableMode strips it and the
                    // observation line goes blank (0.81). Prefer vendor keys.
                    if parsed[index].mode.isEmpty, let object = jsonObject(value) {
                        parsed[index].mode = firstString(object, keys: [
                            "unifiedMode", "unified_mode", "composerMode", "composer_mode",
                            "agentMode", "agent_mode", "mode", "role",
                        ])
                    }
                    // Composer headers nest the display model under modelDetails
                    // more often than a top-level model key (0.82).
                    if parsed[index].model.isEmpty, let object = jsonObject(value) {
                        parsed[index].model = firstString(object, keys: [
                            "model", "modelId", "model_id", "modelName", "model_name",
                            "currentModel", "current_model",
                        ])
                        if parsed[index].model.isEmpty,
                           let details = object["modelDetails"] as? [String: Any]
                            ?? object["model_details"] as? [String: Any] {
                            parsed[index].model = firstString(details, keys: [
                                "modelName", "model_name", "model", "modelId", "model_id", "name",
                            ])
                        }
                    }
                }
                let remaining = max(0, maxFactsPerAgent - facts.count)
                if remaining > 0 {
                    facts.append(contentsOf: parsed.filter { $0.hasUsefulSignal && $0.hasDisplaySignal }.prefix(remaining))
                }
                if facts.count >= maxFactsPerAgent { break }
            }
        } else if sqliteReadFailed(database) {
            error = true
        }

        // Cloud Agent rows are stored as JSON arrays in ItemTable. They have a
        // stable id/title/status even when no local composer transcript exists.
        let cloudSQL = "SELECT value FROM ItemTable WHERE key LIKE 'cloudAgentRepository.agents.%'"
        if let cloudStatement = sqlitePrepare(database, cloudSQL) {
            defer { sqlite3_finalize(cloudStatement) }
            while sqlite3_step(cloudStatement) == SQLITE_ROW {
                let value = sqliteString(cloudStatement, column: 0)
                guard let data = value.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let list = object as? [Any]
                else { continue }
                for item in list {
                    guard let meta = item as? [String: Any] else { continue }
                    let sid = firstString(meta, keys: ["bcId", "id"])
                    guard !sid.isEmpty else { continue }
                    var fact = fact(from: meta, context: "cloudAgentRepository", structured: true, path: url.path)
                    fact.sessionID = sid
                    fact.project = fact.project.isEmpty
                        ? lastPathComponent(firstString(meta, keys: ["repoUrl", "repository"]))
                        : fact.project
                    let status = firstNumber(meta, keys: ["status"])
                    if fact.phase.isEmpty { fact.phase = status == 1 ? "running" : status == 2 ? "completed" : "" }
                    fact.mode = fact.mode.isEmpty ? "cloud" : fact.mode
                    fact.activityMs = normalizeTimestamp(firstValue(meta, keys: ["updatedAt", "updated_at"]))
                    if fact.activityMs == 0 { fact.activityMs = fileMTime(url) }
                    guard fact.hasUsefulSignal && fact.hasDisplaySignal else { continue }
                    if facts.count < maxFactsPerAgent { facts.append(fact) }
                    if facts.count >= maxFactsPerAgent { break }
                }
                if facts.count >= maxFactsPerAgent { break }
            }
        } else if sqliteReadFailed(database) {
            error = true
        }
        if sqliteReadFailed(database) { error = true }
    }

    package static func sqliteReadFailed(_ database: OpaquePointer) -> Bool {
        switch sqlite3_errcode(database) {
        case SQLITE_BUSY, SQLITE_LOCKED, SQLITE_CORRUPT, SQLITE_NOTADB:
            return true
        default:
            return false
        }
    }

    package static func sqliteString(_ statement: OpaquePointer, column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    /// 9.0 — the latest assistant bubble's text from Cursor's `cursorDiskKV`
    /// store (`bubbleId:<composer>:<bubble>` keys; bubble `type` 2 is the
    /// assistant, 1 the user). `rowid DESC` approximates write order without
    /// depending on a timestamp column; a store without the table, or bubbles
    /// without plain text, yield "" — absence, never a guess.
    package static func cursorLastWord(_ database: OpaquePointer, composerID: String) -> String {
        guard !composerID.isEmpty else { return "" }
        let sql = "SELECT value FROM cursorDiskKV WHERE key LIKE 'bubbleId:' || ? || ':%' ORDER BY rowid DESC LIMIT 60"
        guard let statement = sqlitePrepare(database, sql),
              sqliteBind(statement, index: 1, text: composerID) else { return "" }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let object = jsonObject(sqliteString(statement, column: 0)),
                  firstNumber(object, keys: ["type"]) == 2
            else { continue }
            let line = selfReportLine(firstString(object, keys: ["text"]))
            if !line.isEmpty { return line }
        }
        return ""
    }

    package static func cursorWorkspacePath(databaseURL: URL, workspaceID: String) -> String {
        guard !workspaceID.isEmpty else { return "" }
        let user = databaseURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspace = user
            .appendingPathComponent("workspaceStorage")
            .appendingPathComponent(workspaceID)
            .appendingPathComponent("workspace.json")
        guard let data = try? Data(contentsOf: workspace),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folder = object["folder"] as? String
        else { return "" }
        return normalizedPath(folder)
    }

    package static func normalizeTimestamp(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            if raw > 10_000_000_000 { return Int64(raw) }
            return Int64(raw * 1000)
        }
        let text = stringValue(value)
        if let raw = Double(text), raw.isFinite, raw > 0 {
            return raw > 10_000_000_000 ? Int64(raw) : Int64(raw * 1000)
        }
        for parser in isoParsers {
            if let date = parser.date(from: text) { return Int64(date.timeIntervalSince1970 * 1000) }
        }
        for parser in fallbackParsers {
            if let date = parser.date(from: text) { return Int64(date.timeIntervalSince1970 * 1000) }
        }
        return 0
    }

    /// Fractional seconds first: `2024-12-03T14:00:01.000Z` is what Claude and
    /// Pi actually write, and the default ISO8601DateFormatter rejects it —
    /// every vendor timestamp used to fall through to file mtime, collapsing
    /// per-record ordering (the 0.95 pending-follows-newest rule degraded to
    /// OR). Cached because this runs on the per-line hot path; both formatter
    /// types are immutable after creation and safe to share.
    // Immutable after creation and documented thread-safe for parsing; Swift
    // 6 cannot see that through a non-Sendable class type.
    nonisolated(unsafe) package static let isoParsers: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return [fractional, plain]
    }()

    package static let fallbackParsers: [DateFormatter] = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss",
    ].map { format in
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = format
        return parser
    }

    package static func fileMTime(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let date = values.contentModificationDate
        else { return 0 }
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}
