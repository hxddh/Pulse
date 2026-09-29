import Foundation
import PulseCore
import SQLite3

// Goose sessions.
//
// 20.0 Drift. Checked against block/goose
// crates/goose/src/session/session_manager.rs (schema v16) and
// crates/goose-provider-types/src/conversation/message.rs (commit pinned in
// docs/vendor-formats.json). Since v1.10 (2025-10) every session is a row in
// `~/.local/share/goose/sessions/sessions.db`; before 20.0 Pulse read only the
// JSON under Goose's roots and so read no current Goose session at all.
//
// - `sessions`: `name` (starts as "CLI Session", later an LLM title),
//   `working_dir`, `updated_at` (`YYYY-MM-DD HH:MM:SS` UTC),
//   `model_config_json` (`{"model_name": …}`), accumulated token counts,
//   `session_type`, `archived_at`, `parent_session_id`.
// - `messages`: `role`, `content_json` — an array of `{"type":"text","text"}`,
//   `toolRequest`, `toolResponse`, `actionRequired`, … — and
//   `created_timestamp` in seconds.
// - The one blocked state Goose writes down is an MCP elicitation: an
//   assistant row whose content is `actionRequired` with
//   `actionType: "elicitation"`, released by a later `elicitationResponse`.
//   A tool approval is never persisted, so Goose's other waits cannot be seen
//   here — and are not guessed.

extension NativeActivityHarvest {
    package static func collectGooseDatabase(
        _ database: OpaquePointer,
        url: URL,
        into facts: inout [Fact],
        error: inout Bool
    ) {
        func query(_ filter: String) -> String {
            """
            SELECT id, name, working_dir, updated_at, created_at, model_config_json,
                   accumulated_input_tokens, accumulated_output_tokens
            FROM sessions
            WHERE 1 = 1\(filter)
            ORDER BY updated_at DESC
            LIMIT \(maxRowsPerAgent)
            """
        }
        // Newest schema first; each fallback drops a column an older
        // database does not have yet.
        let statement = sqlitePrepare(database, query(
            " AND archived_at IS NULL AND parent_session_id IS NULL AND IFNULL(session_type, 'user') = 'user'"
        )) ?? sqlitePrepare(database, query(" AND IFNULL(session_type, 'user') = 'user'"))
            ?? sqlitePrepare(database, query(""))
        guard let statement else {
            error = true
            return
        }
        defer { sqlite3_finalize(statement) }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        while sqlite3_step(statement) == SQLITE_ROW {
            let sid = sqliteString(statement, column: 0)
            guard !sid.isEmpty else { continue }
            let cwd = normalizedPath(sqliteString(statement, column: 2))
            let tin = sqlite3_column_int64(statement, 6)
            let tout = sqlite3_column_int64(statement, 7)
            let sessionUpdatedMs = normalizeTimestamp(sqliteString(statement, column: 3))

            // Decoding sixty message rows for each of up to `maxRowsPerAgent`
            // sessions spent the adapter's deadline on months-old history.
            // An old session keeps its title; its last word and wait state are
            // only read while it could still be live.
            let messages = gooseMessages(
                database,
                sessionID: sid,
                includeRecent: gooseReadsRecentMessages(updatedMs: sessionUpdatedMs, nowMs: nowMs)
            )
            var title = clean(sqliteString(statement, column: 1), limit: 160)
            if isGoosePlaceholderTitle(title) { title = messages.firstUserText }

            var fact = Fact()
            fact.structured = true
            fact.sourcePath = url.path
            fact.sessionID = sid
            if !title.isEmpty {
                fact.task = title
                fact.taskOrigin = messages.firstUserText == title ? .userPrompt : .cacheTitle
            }
            fact.cwd = cwd
            fact.project = cwd.isEmpty ? "" : lastPathComponent(cwd)
            if let config = jsonObject(sqliteString(statement, column: 5)) {
                fact.model = firstString(config, keys: ["model_name", "modelName"])
            }
            fact.tokensIn = Int(max(0, tin))
            fact.tokensOut = Int(max(0, tout))
            fact.lastWord = messages.lastWord
            fact.startedMs = normalizeTimestamp(sqliteString(statement, column: 4))
            let updated = max(sessionUpdatedMs, messages.latestMs)
            fact.activityMs = updated > 0 ? updated : fileMTime(url)
            fact.records = messages.count
            if messages.awaitingElicitation {
                fact.explicitPending = true
                fact.skill = "pending"
            }
            guard !fact.task.isEmpty || !cwd.isEmpty || !fact.lastWord.isEmpty else { continue }
            facts.append(fact)
            if facts.count >= maxFactsPerAgent { break }
        }
    }

    package static func isGoosePlaceholderTitle(_ title: String) -> Bool {
        let low = title.trimmingCharacters(in: .whitespaces).lowercased()
        return low.isEmpty || low == "cli session" || low == "new session"
    }

    package struct GooseMessages: Equatable {
        package var firstUserText = ""
        package var lastWord = ""
        package var latestMs: Int64 = 0
        package var count = 0
        package var awaitingElicitation = false
    }

    /// How recently a session must have moved for its newest messages to be
    /// read at all.
    package static let gooseRecentMessagesWindowMs: Int64 = 72 * 60 * 60 * 1000

    /// An unknown `updated_at` is read, never assumed old.
    package static func gooseReadsRecentMessages(updatedMs: Int64, nowMs: Int64) -> Bool {
        updatedMs <= 0 || nowMs - updatedMs <= gooseRecentMessagesWindowMs
    }

    /// Newest first for the last word and the open elicitation; the first
    /// user text needs the oldest row, read separately. `includeRecent:
    /// false` reads only that first user text (the title fallback).
    package static func gooseMessages(
        _ database: OpaquePointer,
        sessionID: String,
        includeRecent: Bool = true
    ) -> GooseMessages {
        var out = GooseMessages()
        let recent = "SELECT role, content_json, created_timestamp FROM messages WHERE session_id = ? ORDER BY id DESC LIMIT 60"
        if includeRecent, let statement = sqlitePrepare(database, recent), sqliteBind(statement, index: 1, text: sessionID) {
            defer { sqlite3_finalize(statement) }
            var decidedWaiting = false
            while sqlite3_step(statement) == SQLITE_ROW {
                out.count += 1
                let role = sqliteString(statement, column: 0).lowercased()
                let content = gooseContent(sqliteString(statement, column: 1))
                out.latestMs = max(out.latestMs, normalizeTimestamp(sqlite3_column_int64(statement, 2)))
                if !decidedWaiting {
                    for item in content where firstString(item, keys: ["type"]) == "actionRequired" {
                        let data = item["data"] as? [String: Any] ?? [:]
                        switch firstString(data, keys: ["actionType"]) {
                        case "elicitationResponse":
                            decidedWaiting = true
                        case "elicitation":
                            out.awaitingElicitation = true
                            decidedWaiting = true
                        default:
                            break
                        }
                    }
                    // Anything the user said after an ask answers it.
                    if role == "user", content.contains(where: { firstString($0, keys: ["type"]) == "text" }) {
                        decidedWaiting = true
                    }
                }
                if out.lastWord.isEmpty, role == "assistant" {
                    let text = content
                        .filter { firstString($0, keys: ["type"]) == "text" }
                        .map { firstString($0, keys: ["text"]) }
                        .joined(separator: "\n")
                    out.lastWord = selfReportLine(text)
                }
            }
        }
        let first = "SELECT content_json FROM messages WHERE session_id = ? AND role = 'user' ORDER BY id ASC LIMIT 5"
        if let statement = sqlitePrepare(database, first), sqliteBind(statement, index: 1, text: sessionID) {
            defer { sqlite3_finalize(statement) }
            while out.firstUserText.isEmpty, sqlite3_step(statement) == SQLITE_ROW {
                let text = gooseContent(sqliteString(statement, column: 0))
                    .filter { firstString($0, keys: ["type"]) == "text" }
                    .map { firstString($0, keys: ["text"]) }
                    .joined(separator: "\n")
                out.firstUserText = clean(text, limit: 160)
            }
        }
        return out
    }

    private static func gooseContent(_ raw: String) -> [[String: Any]] {
        guard let data = raw.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return [] }
        return array.compactMap { $0 as? [String: Any] }
    }
}
