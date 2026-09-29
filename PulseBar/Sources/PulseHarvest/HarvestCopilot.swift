import Foundation
import PulseCore

// GitHub Copilot CLI sessions.
//
// 20.0 Drift. Checked against github/docs (copilot-cli config-dir reference)
// and github/copilot-sdk nodejs/src/generated/session-events.ts (commits in
// docs/vendor-formats.json). Since 0.0.342 each session is
// `~/.copilot/session-state/<session-id>/events.jsonl`: one
// `{id, parentId, timestamp, type, data}` per line — `session.start`
// (`data.context.cwd`), `user.message` (`data.content`), `assistant.message`
// (`data.content`, a string). Pulse's generic walker compares `type` with
// "user" / "assistant", so none of it was read. `permission.requested` is
// raised before Copilot's own rules and auto-approval run, so it is not
// evidence that anyone is being asked — no Waiting is taken from it.

extension NativeActivityHarvest {
    package static func parseCopilotEvents(_ text: String, path: String) -> [Fact] {
        var fact = Fact()
        fact.structured = true
        fact.sourcePath = path
        fact.sessionID = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        var latest: Int64 = 0
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("{"),
                  let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            latest = max(latest, normalizeTimestamp(event["timestamp"]))
            let payload = event["data"] as? [String: Any] ?? [:]
            fact.records += 1
            switch firstString(event, keys: ["type"]) {
            case "session.start":
                let context = payload["context"] as? [String: Any] ?? [:]
                let cwd = normalizedPath(firstString(context, keys: ["cwd", "gitRoot"]))
                if !cwd.isEmpty {
                    fact.cwd = cwd
                    fact.project = lastPathComponent(cwd)
                }
                let sid = firstString(payload, keys: ["sessionId"])
                if !sid.isEmpty { fact.sessionID = sid }
            case "user.message":
                let task = cleanPiSessionTitle(firstString(payload, keys: ["content"]))
                if !task.isEmpty {
                    fact.task = task
                    fact.taskOrigin = .userPrompt
                }
            case "assistant.message":
                let word = selfReportLine(firstString(payload, keys: ["content"]))
                if !word.isEmpty { fact.lastWord = word }
                let model = firstString(payload, keys: ["model"])
                if !model.isEmpty { fact.model = model }
            default:
                break
            }
        }
        fact.activityMs = latest
        return fact.records > 0 ? [fact] : []
    }
}
