import Foundation
import PulseCore

// Continue and OpenHands.
//
// 20.0 Drift. Continue checked against continuedev/continue
// (core/util/history.ts, core/util/paths.ts, core/index.d.ts); OpenHands
// against OpenHands/software-agent-sdk (conversation/state.py,
// persistence_const.py, event_store.py, event/llm_convertible/message.py) and
// OpenHands/OpenHands-CLI (openhands_cli/locations.py). Commits in
// docs/vendor-formats.json.

extension NativeActivityHarvest {
    // MARK: - Continue

    /// `~/.continue/sessions/<id>.json` — pretty-printed
    /// `{sessionId, title, workspaceDirectory, history: [{message: {role,
    /// content}}], chatModelTitle?, usage?}`. `workspaceDirectory` is a
    /// `file://` URI from the IDE and a plain path from the `cn` CLI. The
    /// index `sessions.json` has no clock Pulse can trust (it is rewritten on
    /// every save) and `dev_data/` holds rendered prompts, not sessions — both
    /// are claimed and say nothing. Continue persists no reliable wait: a tool
    /// call sits at `generated` both while it awaits approval and, in the CLI,
    /// for every call before policy runs — so Continue shows Running and says
    /// so rather than guess.
    package static func parseContinue(_ text: String, path: String) -> [Fact]? {
        let lower = path.lowercased()
        if lower.contains("/dev_data/") || lower.hasSuffix("/sessions/sessions.json") { return [] }
        guard let data = text.data(using: .utf8),
              let session = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let history = session["history"] as? [Any]
        else { return nil }
        var fact = Fact()
        fact.structured = true
        fact.sourcePath = path
        fact.sessionID = firstString(session, keys: ["sessionId"])
        var prompt = ""
        for case let item as [String: Any] in history {
            guard let message = item["message"] as? [String: Any] else { continue }
            let text = continueText(message["content"])
            switch firstString(message, keys: ["role"]) {
            case "user":
                let title = cleanPiSessionTitle(text)
                if !title.isEmpty { prompt = title }
            case "assistant":
                let word = selfReportLine(text)
                if !word.isEmpty { fact.lastWord = word }
            default:
                break
            }
        }
        let title = cleanPiSessionTitle(firstString(session, keys: ["title"]))
        let placeholder = ["new session", "untitled session", "untitled"].contains(title.lowercased())
        if !prompt.isEmpty {
            fact.task = prompt
            fact.taskOrigin = .userPrompt
        } else if !title.isEmpty, !placeholder {
            fact.task = title
            fact.taskOrigin = .cacheTitle
        }
        var cwd = firstString(session, keys: ["workspaceDirectory"])
        if cwd.hasPrefix("file://"), let url = URL(string: cwd) { cwd = url.path }
        fact.cwd = normalizedPath(cwd)
        fact.project = fact.cwd.isEmpty ? "" : lastPathComponent(fact.cwd)
        fact.model = firstString(session, keys: ["chatModelTitle"])
        if let usage = session["usage"] as? [String: Any] {
            fact.tokensIn = firstNumber(usage, keys: ["promptTokens"])
            fact.tokensOut = firstNumber(usage, keys: ["completionTokens"])
        }
        fact.records = history.count
        return [fact]
    }

    private static func continueText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        guard let parts = value as? [Any] else { return "" }
        return parts.compactMap { part -> String? in
            guard let dict = part as? [String: Any], firstString(dict, keys: ["type"]) == "text" else { return nil }
            let text = firstString(dict, keys: ["text"])
            return text.isEmpty ? nil : text
        }.joined(separator: "\n")
    }

    // MARK: - OpenHands

    /// A conversation directory — `~/.openhands/conversations/<hex>/` (CLI),
    /// `agent-canvas/dev_conversations/<hex>/` (Agent Canvas) or
    /// `v1_conversations/<hex>/` (the 1.x server) — holds `base_state.json`
    /// (`workspace.working_dir`, `agent.llm.model`, `execution_status`),
    /// `meta.json` (title) and one compact JSON event per file under
    /// `events/`. `execution_status: "waiting_for_confirmation"` is the SDK
    /// writing down that the agent waits for the person's confirmation.
    package static func parseOpenHands(_ text: String, path: String) -> [Fact]? {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        var fact = Fact()
        fact.structured = true
        fact.sourcePath = path
        switch name {
        case "base_state.json":
            fact.sessionID = url.deletingLastPathComponent().lastPathComponent
            let workspace = object["workspace"] as? [String: Any] ?? [:]
            fact.cwd = normalizedPath(firstString(workspace, keys: ["working_dir"]))
            fact.project = fact.cwd.isEmpty ? "" : lastPathComponent(fact.cwd)
            let agent = object["agent"] as? [String: Any] ?? [:]
            let llm = agent["llm"] as? [String: Any] ?? [:]
            fact.model = firstString(llm, keys: ["model"])
            let status = firstString(object, keys: ["execution_status"])
            switch status {
            case "waiting_for_confirmation":
                fact.explicitPending = true
                fact.skill = "pending"
                fact.phase = "waiting"
            case "running":
                fact.phase = "working"
            default:
                break
            }
            // The conversation's words are in its own `events/` directory,
            // one small file per event; the newest few carry the latest ask
            // and reply. Read here so one fragment holds the whole row.
            let messages = openHandsRecentMessages(url.deletingLastPathComponent().appendingPathComponent("events"))
            if !messages.task.isEmpty {
                fact.task = messages.task
                fact.taskOrigin = .userPrompt
            }
            fact.lastWord = messages.lastWord
            // The file is autosaved on every state change; its mtime (the
            // walker's fallback) is when the conversation last moved.
            return fact.cwd.isEmpty && fact.model.isEmpty && fact.task.isEmpty ? [] : [fact]
        case "meta.json":
            fact.sessionID = url.deletingLastPathComponent().lastPathComponent
            let title = cleanPiSessionTitle(firstString(object, keys: ["title"]))
            if !title.isEmpty {
                fact.task = title
                fact.taskOrigin = .cacheTitle
            }
            let workspace = object["workspace"] as? [String: Any] ?? [:]
            fact.cwd = normalizedPath(firstString(workspace, keys: ["working_dir"]))
            return title.isEmpty && fact.cwd.isEmpty ? [] : [fact]
        default:
            // Event files are read through their conversation's
            // base_state.json — one row per conversation, not per event.
            return []
        }
    }

    static let openHandsEventsRead = 60

    package static func openHandsRecentMessages(_ events: URL) -> (task: String, lastWord: String) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: events.path)) ?? [])
            .filter { $0.hasPrefix("event-") && $0.hasSuffix(".json") }
            .sorted(by: >)
            .prefix(openHandsEventsRead)
        var task = ""
        var word = ""
        for name in names where task.isEmpty || word.isEmpty {
            guard let data = FileManager.default.contents(atPath: events.appendingPathComponent(name).path),
                  data.count < 512 * 1024,
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  firstString(event, keys: ["kind"]) == "MessageEvent",
                  let message = event["llm_message"] as? [String: Any]
            else { continue }
            let text = continueText(message["content"])
            switch firstString(message, keys: ["role"]) {
            case "user" where task.isEmpty:
                task = cleanPiSessionTitle(text)
            case "assistant" where word.isEmpty:
                word = selfReportLine(text)
            default:
                break
            }
        }
        return (task, word)
    }
}
