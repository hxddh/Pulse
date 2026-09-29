import Foundation
import PulseCore

// Kimi Code sessions.
//
// 20.0 Drift. Checked against MoonshotAI/kimi-code
// packages/agent-core-v2/src (wire/record.ts, app/event/event2.ts,
// agent/contextMemory/contextEvents.ts, agent/loop/turnOps.ts,
// agent/interaction/interactionOps.ts, session/sessionMetadata/*; commit
// pinned in docs/vendor-formats.json). The Python kimi-cli that wrote ~/.kimi
// is archived (final release 2026-09-22) and hands over to Kimi Code.
//
// `~/.kimi-code/sessions/<workspace>/<session_…>/` holds:
// - `state.json` — `{id, cwd, createdAt, updatedAt (ms), title, lastPrompt, …}`
// - `agents/<agentId>/wire.jsonl` — append-only `{type, …, time}` records,
//   `main` for the session's own agent, one directory per subagent:
//   `turn.prompt {input: [{type: "text", text}]}`,
//   `context.append_loop_event {event: {type: "content.part", part: {text}}}`,
//   `llm.request {model}`, `turn.ended {reason}`, and
//   `interaction.request {id, kind: approval|question|user_tool}` answered
//   by `interaction.resolved {id}`. An unanswered approval or question is the
//   vendor itself writing down that the agent is waiting on the person —
//   before 20.0 Pulse read neither that nor the agent's words.

extension NativeActivityHarvest {
    package static func parseKimiSession(_ text: String, path: String) -> [Fact] {
        let url = URL(fileURLWithPath: path)
        let components = url.pathComponents
        let name = url.lastPathComponent.lowercased()
        if name == "state.json", url.deletingLastPathComponent().lastPathComponent.hasPrefix("session_") {
            return kimiStateFacts(text, path: path, sessionID: url.deletingLastPathComponent().lastPathComponent)
        }
        guard name == "wire.jsonl",
              let agentsIndex = components.lastIndex(of: "agents"),
              agentsIndex >= 1, agentsIndex + 1 < components.count
        else { return [] }
        // A subagent's stream is part of its parent's session.
        guard components[agentsIndex + 1] == "main" else { return [] }
        return kimiWireFacts(text, path: path, sessionID: components[agentsIndex - 1])
    }

    private static func kimiStateFacts(_ text: String, path: String, sessionID: String) -> [Fact] {
        guard let data = text.data(using: .utf8),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        var fact = Fact()
        fact.structured = true
        fact.sourcePath = path
        fact.sessionID = firstString(state, keys: ["id"]).isEmpty ? sessionID : firstString(state, keys: ["id"])
        let title = cleanPiSessionTitle(firstString(state, keys: ["title"]))
        let prompt = cleanPiSessionTitle(firstString(state, keys: ["lastPrompt"]))
        if !title.isEmpty || !prompt.isEmpty {
            fact.task = title.isEmpty ? prompt : title
            fact.taskOrigin = .userPrompt
        }
        fact.cwd = normalizedPath(firstString(state, keys: ["cwd", "workDir"]))
        fact.project = fact.cwd.isEmpty ? "" : lastPathComponent(fact.cwd)
        fact.activityMs = normalizeTimestamp(state["updatedAt"])
        fact.startedMs = normalizeTimestamp(state["createdAt"])
        return [fact]
    }

    private static func kimiWireFacts(_ text: String, path: String, sessionID: String) -> [Fact] {
        var fact = Fact()
        fact.structured = true
        fact.sourcePath = path
        fact.sessionID = sessionID
        var latest: Int64 = 0
        var open: [String: String] = [:]
        var step = ""
        var words = ""
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("{"),
                  let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            latest = max(latest, normalizeTimestamp(record["time"]))
            fact.records += 1
            switch firstString(record, keys: ["type"]) {
            case "turn.prompt":
                let prompt = (record["input"] as? [Any] ?? [])
                    .compactMap { ($0 as? [String: Any]).map { firstString($0, keys: ["text"]) } }
                    .joined(separator: "\n")
                let task = cleanPiSessionTitle(prompt)
                if !task.isEmpty {
                    fact.task = task
                    fact.taskOrigin = .userPrompt
                }
            case "context.append_loop_event":
                guard let event = record["event"] as? [String: Any] else { continue }
                if firstString(event, keys: ["type"]) == "content.part",
                   let part = event["part"] as? [String: Any],
                   firstString(part, keys: ["type"]) == "text" {
                    // Parts of one step are one reply; a new step starts a
                    // new one.
                    let stepID = firstString(event, keys: ["stepUuid", "turnId"])
                    if stepID != step { step = stepID; words = "" }
                    // Raw: a streamed chunk's edge spaces are part of the words.
                    words += part["text"] as? String ?? ""
                    let line = selfReportLine(words)
                    if !line.isEmpty { fact.lastWord = line }
                } else if firstString(event, keys: ["type"]) == "tool.call" {
                    fact.tool = clean(firstString(event, keys: ["name"]), limit: 64)
                }
            case "llm.request":
                let model = firstString(record, keys: ["model"])
                if !model.isEmpty { fact.model = model }
            case "interaction.request":
                let kind = firstString(record, keys: ["kind"])
                let id = firstString(record, keys: ["id"])
                if !id.isEmpty, kind == "approval" || kind == "question" { open[id] = kind }
            case "interaction.resolved":
                open[firstString(record, keys: ["id"])] = nil
            default:
                break
            }
        }
        fact.activityMs = latest
        if !open.isEmpty {
            fact.explicitPending = true
            fact.skill = "pending"
        }
        return fact.records > 0 ? [fact] : []
    }
}
