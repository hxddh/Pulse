import Foundation
import PulseCore

// Cline, Roo Code and Kilo Code (legacy) task stores.
//
// 20.0 Drift. Checked against cline/cline (branch legacy-extension:
// shared/ExtensionMessage.ts, core/storage/disk.ts, core/task/message-state.ts),
// RooCodeInc/Roo-Code (packages/types/src/message.ts, history.ts,
// core/task-persistence) and Kilo-Org/kilocode-legacy
// (packages/types/src/message.ts); commits pinned in docs/vendor-formats.json.
//
// Each task is a directory `…/<publisher.id>/tasks/<taskId>/` holding
// `ui_messages.json` — a compact JSON array of `ClineMessage
// {ts, type: "ask"|"say", ask?, say?, text?, partial?, isAnswered?, modelInfo?}`
// — plus the API history, metadata and (Roo) `history_item.json`. Cline keeps
// its task list in `state/taskHistory.json`, Roo in `tasks/_index.json`; that
// is where the working directory lives (`cwdOnTaskInitialization` /
// `workspace`).
//
// What was wrong before 20.0: the generic walker read `ui_messages.json`
// without the `ts` clock, so every ask in the file — including approvals
// granted long ago — merged into one "pending"; and it counted the vendors'
// own *idle* asks as blocked. Every finished task ends with a persisted
// `ask: "completion_result"`, so every finished Cline/Roo/Kilo task lit red.
// The vendor classifies its asks itself (Roo `message.ts` interactive vs idle
// vs resumable); only the interactive ones, on the newest settled message,
// and not already answered, are a wait.

extension NativeActivityHarvest {
    /// The asks the vendors classify as interactive — the agent is blocked on
    /// the person. Everything else (`completion_result`, `api_req_failed`,
    /// `resume_task`, `resume_completed_task`, `mistake_limit_reached`,
    /// `auto_approval_max_req_reached`, `command_output`, …) is idle,
    /// resumable or non-blocking.
    package static let clineBlockingAsks: Set<String> = [
        "followup", "command", "tool", "use_mcp_server", "browser_action_launch",
        // Cline
        "plan_mode_respond", "act_mode_respond", "new_task", "condense",
        "summarize_task", "report_bug", "use_subagents",
        // Kilo (legacy)
        "checkpoint_restore",
    ]

    package static func isClineFamilyPath(_ lowerPath: String) -> Bool {
        lowerPath.contains("/saoudrizwan.claude-dev/")
            || lowerPath.contains("/rooveterinaryinc.roo-cline/")
            || lowerPath.contains("/kilocode.kilo-code/")
            || lowerPath.contains("/.cline/data/")
    }

    /// Dispatch by file name within a Cline-family store. Files that are not
    /// task evidence (API history, metadata, settings, temp writes) are
    /// claimed and say nothing; anything else goes to the generic walker.
    package static func parseClineFamily(_ text: String, path: String) -> [Fact]? {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent.lowercased()
        let lower = path.lowercased()
        if lower.contains("/.cline/data/sessions/") {
            return parseClineSDKSession(text, path: path)
        }
        switch name {
        case "ui_messages.json":
            return parseClineUIMessages(text, path: path, taskID: url.deletingLastPathComponent().lastPathComponent)
        case "history_item.json":
            guard let item = clineJSON(text) as? [String: Any] else { return [] }
            return clineHistoryFacts([item], path: path)
        case "taskhistory.json":
            return clineHistoryFacts(clineJSON(text) as? [Any] ?? [], path: path)
        case "_index.json":
            let index = clineJSON(text) as? [String: Any]
            return clineHistoryFacts(index?["entries"] as? [Any] ?? [], path: path)
        case "api_conversation_history.json", "context_history.json", "task_metadata.json", "settings.json":
            return []
        default:
            // A write in progress: `ui_messages.json.tmp.<ts>.<rand>.json`.
            if name.contains(".tmp") { return [] }
            return nil
        }
    }

    /// Cline's SDK bundle (4.1+ "next" cohort, the CLI 3.x):
    /// `~/.cline/data/sessions/<sid>/<sid>.json` is the manifest
    /// `{session_id, cwd, workspace_root, prompt, metadata{title}, model,
    /// started_at, status}` and `<sid>.messages.json` holds `{updated_at,
    /// messages: [{role, content, ts}]}`. Its `status: "pending"` is queued
    /// work, never the user — and the SDK keeps approvals in memory, so
    /// nothing here is a wait.
    package static func parseClineSDKSession(_ text: String, path: String) -> [Fact]? {
        guard let object = clineJSON(text) as? [String: Any] else { return [] }
        let url = URL(fileURLWithPath: path)
        var fact = Fact()
        fact.structured = true
        fact.sourcePath = path
        fact.sessionID = firstString(object, keys: ["session_id", "sessionId"])
        if fact.sessionID.isEmpty { fact.sessionID = url.deletingLastPathComponent().lastPathComponent }
        if let messages = object["messages"] as? [Any] {
            var latest = normalizeTimestamp(object["updated_at"])
            for case let message as [String: Any] in messages {
                latest = max(latest, normalizeTimestamp(message["ts"]))
                let role = firstString(message, keys: ["role"])
                let text = clineContentText(message["content"])
                if role == "user", fact.task.isEmpty {
                    let task = cleanPiSessionTitle(text)
                    if !task.isEmpty { fact.task = task; fact.taskOrigin = .userPrompt }
                }
                if role == "assistant" {
                    let word = selfReportLine(text)
                    if !word.isEmpty { fact.lastWord = word }
                }
            }
            fact.activityMs = latest
            fact.records = messages.count
            return [fact]
        }
        guard object["session_id"] != nil || object["messages_path"] != nil else { return [] }
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        let title = cleanPiSessionTitle(firstString(metadata, keys: ["title"]))
        let prompt = cleanPiSessionTitle(firstString(object, keys: ["prompt"]))
        if !title.isEmpty {
            fact.task = title
            fact.taskOrigin = .cacheTitle
        } else if !prompt.isEmpty {
            fact.task = prompt
            fact.taskOrigin = .userPrompt
        }
        fact.cwd = normalizedPath(firstString(object, keys: ["cwd", "workspace_root"]))
        fact.project = fact.cwd.isEmpty ? "" : lastPathComponent(fact.cwd)
        fact.model = firstString(object, keys: ["model"])
        fact.activityMs = normalizeTimestamp(object["started_at"])
        return [fact]
    }

    private static func clineContentText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        guard let blocks = value as? [Any] else { return "" }
        return blocks.compactMap { block -> String? in
            guard let dict = block as? [String: Any], firstString(dict, keys: ["type"]) == "text" else { return nil }
            let text = firstString(dict, keys: ["text"])
            return text.isEmpty ? nil : text
        }.joined(separator: "\n")
    }

    private static func clineJSON(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// The newest history entries become facts carrying the task, working
    /// directory and model; `ui_messages.json` supplies words and the wait.
    static let clineHistoryEntries = 24

    package static func clineHistoryFacts(_ entries: [Any], path: String) -> [Fact] {
        let items = entries.compactMap { $0 as? [String: Any] }
            .sorted { normalizeTimestamp($0["ts"]) > normalizeTimestamp($1["ts"]) }
            .prefix(clineHistoryEntries)
        return items.compactMap { item in
            let id = firstString(item, keys: ["id"])
            guard !id.isEmpty else { return nil }
            var fact = Fact()
            fact.structured = true
            fact.sourcePath = path
            fact.sessionID = id
            let task = cleanPiSessionTitle(firstString(item, keys: ["task"]))
            if !task.isEmpty {
                fact.task = task
                fact.taskOrigin = .userPrompt
            }
            fact.cwd = normalizedPath(firstString(item, keys: ["cwdOnTaskInitialization", "workspace"]))
            fact.project = fact.cwd.isEmpty ? "" : lastPathComponent(fact.cwd)
            fact.model = firstString(item, keys: ["modelId"])
            fact.tokensIn = firstNumber(item, keys: ["tokensIn"])
            fact.tokensOut = firstNumber(item, keys: ["tokensOut"])
            fact.activityMs = normalizeTimestamp(item["ts"])
            return fact
        }
    }

    package static func parseClineUIMessages(_ text: String, path: String, taskID: String) -> [Fact] {
        let messages = clineMessages(text)
        guard !messages.isEmpty else { return [] }
        var fact = Fact()
        fact.structured = true
        fact.sourcePath = path
        fact.sessionID = taskID
        fact.records = messages.count

        // The task is the first message: Cline `say: "task"`, Roo/Kilo the
        // first `say: "text"` (Roo's history item takes it from index 0).
        if let first = messages.first,
           ["task", "text"].contains(firstString(first, keys: ["say"])) {
            let task = cleanPiSessionTitle(firstString(first, keys: ["text"]))
            if !task.isEmpty {
                fact.task = task
                fact.taskOrigin = .userPrompt
            }
        }
        var latest: Int64 = 0
        for message in messages {
            latest = max(latest, normalizeTimestamp(message["ts"]))
            if let info = message["modelInfo"] as? [String: Any] {
                let model = firstString(info, keys: ["modelId"])
                if !model.isEmpty { fact.model = model }
            }
        }
        fact.activityMs = latest
        // The agent's latest words: its newest settled text or completion.
        for message in messages.reversed() where !anyTruthy(message, keys: ["partial"]) {
            let say = firstString(message, keys: ["say"])
            guard firstString(message, keys: ["type"]) == "say",
                  say == "text" || say == "completion_result"
            else { continue }
            let word = selfReportLine(firstString(message, keys: ["text"]))
            if !word.isEmpty, word != fact.task { fact.lastWord = word; break }
        }
        // The wait: only the newest settled message counts, only an
        // interactive ask, and only if the vendor did not record an answer.
        if let last = messages.last(where: { !anyTruthy($0, keys: ["partial"]) }),
           firstString(last, keys: ["type"]) == "ask",
           clineBlockingAsks.contains(firstString(last, keys: ["ask"]).lowercased()),
           !anyTruthy(last, keys: ["isAnswered"]) {
            fact.explicitPending = true
            fact.skill = "pending"
        }
        return [fact]
    }

    /// Every `ClineMessage` object that can be recovered. A file larger than
    /// the read window arrives as head + tail and is not valid JSON; the
    /// messages are still there, each starting with `{"ts":`, so they are
    /// recovered one by one rather than losing the file.
    package static func clineMessages(_ text: String) -> [[String: Any]] {
        if let array = clineJSON(text) as? [Any] {
            return array.compactMap { $0 as? [String: Any] }
        }
        var out: [[String: Any]] = []
        let scalars = Array(text.utf8)
        let marker = Array(#"{"ts":"#.utf8)
        var index = 0
        while index + marker.count <= scalars.count {
            guard scalars[index] == marker[0], Array(scalars[index..<index + marker.count]) == marker else {
                index += 1
                continue
            }
            // String-aware brace match from here.
            var depth = 0
            var inString = false
            var escaped = false
            var end = index
            while end < scalars.count {
                let byte = scalars[end]
                if inString {
                    if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                } else if byte == 0x22 {
                    inString = true
                } else if byte == 0x7B {
                    depth += 1
                } else if byte == 0x7D {
                    depth -= 1
                    if depth == 0 { break }
                }
                end += 1
            }
            guard end < scalars.count,
                  let object = try? JSONSerialization.jsonObject(with: Data(scalars[index...end])) as? [String: Any]
            else {
                index += marker.count
                continue
            }
            out.append(object)
            index = end + 1
        }
        return out.sorted { normalizeTimestamp($0["ts"]) < normalizeTimestamp($1["ts"]) }
    }
}
