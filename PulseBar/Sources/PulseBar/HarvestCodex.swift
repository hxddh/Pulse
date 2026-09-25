import Foundation
import SQLite3

// Codex: the rollout JSONL parser.
//
// 12.3 γ: one vendor per file. Moved verbatim out of HarvestFacts.swift; the
// dispatch that picks a dialect for a transcript lives in
// TranscriptDialect.swift.

extension NativeActivityHarvest {
    static func parseCodexFacts(_ text: String, path: String) -> [Fact] {
        var f = Fact()
        f.structured = true
        f.sourcePath = path
        var latestTimestamp: Int64 = 0
        let lines = text.split(whereSeparator: \.isNewline)
        // The head of a Codex rollout contains a very large tool registry.
        // Inspect only the tail event stream plus the compact session header;
        // walking the registry first used to return `mode=auto` as if it were
        // the user's task and starved the actual prompt.
        let candidates = Array(lines.prefix(8)) + Array(lines.suffix(2048))
        for line in candidates {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            latestTimestamp = max(latestTimestamp, normalizeTimestamp(object["timestamp"]))
            let type = firstString(object, keys: ["type"]).lowercased()
            // Older/local Codex rollout fixtures (and a few compatibility
            // exports) put session facts at the top level instead of inside a
            // typed payload. Merge those fields before handling the richer
            // event envelope so cwd/title/tool/token evidence is not lost.
            if type.isEmpty {
                var generic = fact(from: object, context: "codex.rollout", structured: true, path: path)
                // Untyped Codex head/compat lines often carry registry or plan
                // step `title` values. Keep cwd/tool/tokens; only accept task
                // from real prompt keys so tool-arg titles never become the hero.
                let prompt = firstString(object, keys: [
                    "task", "goal", "prompt", "query", "user_message", "userMessage",
                    "lastMessage", "last_message", "subject",
                ])
                if prompt.isEmpty {
                    generic.task = ""
                    generic.taskOrigin = .none
                }
                if generic.hasUsefulSignal { merge(&f, generic) }
            }
            let payload = object["payload"] as? [String: Any] ?? [:]
            let payloadType = firstString(payload, keys: ["type"]).lowercased()
            // 8.2: the model rides the turn context / session meta payloads.
            // It was the one work fact this parser never picked up.
            if f.model.isEmpty {
                f.model = firstString(payload, keys: ["model", "modelId", "model_id", "model_name"])
            }
            if payloadType == "session_meta" || type == "session_meta" {
                f.sessionID = firstString(payload, keys: ["session_id", "sessionId"])
                f.cwd = normalizedPath(firstString(payload, keys: ["cwd", "workdir", "workingDirectory"]))
                f.startedMs = latestTimestamp
            }
            if type == "compacted",
               let replacementHistory = payload["replacement_history"] as? [Any] {
                // Codex stores a rolling context window as one compacted JSON
                // record. It contains the latest user turn even when that
                // turn is no longer among the final 2,048 event lines.
                for item in replacementHistory {
                    guard let message = item as? [String: Any],
                          firstString(message, keys: ["role"]).lowercased() == "user"
                    else { continue }
                    let prompt = cleanCodexUserRequest(codexUserText(message["content"]))
                    if !prompt.isEmpty, meaningfulPiPrompt(prompt) || f.task.isEmpty {
                        f.task = prompt
                        f.taskOrigin = .userPrompt
                    }
                }
            }
            if type == "event_msg" {
                switch payloadType {
                case "user_message":
                    let prompt = firstString(payload, keys: ["message", "text", "content"])
                    let cleaned = cleanCodexUserRequest(prompt)
                    if !cleaned.isEmpty, meaningfulPiPrompt(cleaned) || f.task.isEmpty {
                        f.task = cleaned
                        f.taskOrigin = .userPrompt
                    }
                    f.phase = f.phase.isEmpty ? "working" : f.phase
                case "task_started", "turn_started":
                    f.phase = f.phase.isEmpty ? "working" : f.phase
                case "task_complete", "turn_complete":
                    f.phase = "turn_complete"
                    f.outcome = "completed"
                case "agent_message":
                    // What the agent just said — the candidates walk oldest
                    // to newest, so the last assignment is the latest word.
                    let line = selfReportLine(firstString(payload, keys: ["message", "text", "content"]))
                    if !line.isEmpty { f.lastWord = line }
                case "error", "stream_error":
                    let line = selfReportLine(firstString(payload, keys: ["message", "text", "error"]))
                    if !line.isEmpty { f.lastErrorText = line }
                case "token_count":
                    if let info = payload["info"] as? [String: Any] {
                        // Prefer the latest turn (`last_token_usage`); fall back
                        // to cumulative totals — the latest turn, never a sum.
                        let usage = (info["last_token_usage"] as? [String: Any])
                            ?? (info["total_token_usage"] as? [String: Any])
                        if let usage {
                            f.tokensIn = max(f.tokensIn, firstNumber(usage, keys: [
                                "input_tokens", "inputTokens", "prompt_tokens",
                            ]))
                            f.tokensOut = max(f.tokensOut, firstNumber(usage, keys: [
                                "output_tokens", "outputTokens", "completion_tokens",
                            ]))
                        }
                        // 8.3: context % from two measured numbers Codex writes
                        // side by side — the model's window and the tokens the
                        // latest turn put in it. A ratio of measurements is a
                        // fact; a guess at either side would not be.
                        let window = firstNumber(info, keys: [
                            "model_context_window", "modelContextWindow", "context_window",
                        ])
                        let used = firstNumber(
                            (info["last_token_usage"] as? [String: Any]) ?? [:],
                            keys: ["total_tokens", "totalTokens"]
                        )
                        if window > 0, used > 0, used <= window {
                            f.contextPercent = max(
                                f.contextPercent,
                                Int((Double(used) / Double(window) * 100).rounded())
                            )
                        }
                    }
                default:
                    break
                }
            }
            if type == "response_item" {
                let responseType = payloadType
                if responseType == "message", firstString(payload, keys: ["role"]).lowercased() == "user" {
                    let prompt = cleanCodexUserRequest(codexUserText(payload["content"]))
                    // Continuations ("continue", "可以") stay only when the
                    // rollout has no preceding goal.
                    if !prompt.isEmpty,
                       meaningfulPiPrompt(prompt) || f.task.isEmpty {
                        f.task = prompt
                        f.taskOrigin = .userPrompt
                    }
                } else if responseType == "function_call" {
                    let name = firstString(payload, keys: ["name", "toolName"])
                    if !name.isEmpty { f.tool = name }
                    // Never promote tool-call argument titles into `task`.
                    // Those are plan steps / MCP labels, not the user's goal —
                    // they used to become the tray hero (e.g. update_plan titles).
                    // 2.8: but the plan itself is a first-class fact now —
                    // read it into the fields built for it, which are not the
                    // hero. `arguments` is a JSON string, not an object.
                    if name == "update_plan",
                       let data = firstString(payload, keys: ["arguments"]).data(using: .utf8),
                       let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let items = arguments["plan"] as? [Any],
                       let plan = planFacts(from: items) {
                        f.planSteps = plan.steps
                        f.planStep = plan.current
                        f.progressDone = plan.done
                        f.progressTotal = plan.total
                    }
                } else if responseType == "message",
                          firstString(payload, keys: ["role"]).lowercased() == "assistant" {
                    let phase = firstString(payload, keys: ["phase", "status"])
                    if !phase.isEmpty { f.phase = semanticPhase(phase) }
                    // 8.2: older rollouts carry the agent's words only here,
                    // never as an event_msg — same fact, same field.
                    let line = selfReportLine(codexUserText(payload["content"]))
                    if !line.isEmpty { f.lastWord = line }
                }
            }
            if f.sessionID.isEmpty, contextLooksSession(path) {
                let sid = firstString(payload, keys: ["session_id", "sessionId", "thread_id"])
                if !sid.isEmpty { f.sessionID = sid }
            }
        }
        // No record count from here. `candidates` above is the head 8 lines
        // plus the last 2,048 of the window — a Codex rollout of any age has
        // more lines than that, and even the untruncated case says nothing
        // about the file. A count taken from it is an estimate wearing an
        // exact number's clothes ("数量不估算"), and this one carried no
        // truncation flag to warn anybody. `records` has exactly one honest
        // origin: a window that really was the whole file, or a digest that
        // has folded its way to the end — both applied in
        // `ingestTranscriptFile`, which is also what quietly overwrote this
        // counter and kept the defect off the tray by accident rather than
        // by design. Removing it makes that a rule instead of luck.
        if f.sessionID.isEmpty { f.sessionID = sessionIDFromPath(URL(fileURLWithPath: path)) }
        f.activityMs = latestTimestamp > 0 ? latestTimestamp : fileMTime(URL(fileURLWithPath: path))
        if f.project.isEmpty, !f.cwd.isEmpty { f.project = lastPathComponent(f.cwd) }
        f.task = clean(f.task, limit: 160)
        f.cwd = clean(f.cwd, limit: 240)
        f.sessionID = clean(f.sessionID, limit: 80)
        f.tool = clean(f.tool, limit: 64)
        f.phase = clean(f.phase, limit: 64)
        return f.hasUsefulSignal ? [f] : []
    }

    static func codexUserText(_ value: Any?) -> String {
        guard let value else { return "" }
        if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let array = value as? [Any] {
            for item in array {
                if let dict = item as? [String: Any],
                   firstString(dict, keys: ["type"]).lowercased() == "input_text" {
                    let text = firstString(dict, keys: ["text"])
                    if !text.isEmpty { return text }
                }
                let nested = codexUserText(item)
                if !nested.isEmpty { return nested }
            }
        }
        if let dict = value as? [String: Any] {
            return firstString(dict, keys: ["text", "content", "message"])
        }
        return ""
    }

    static func cleanCodexUserRequest(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "" }
        if let regex = try? NSRegularExpression(pattern: #"##\s+My request for Codex:\s*"#, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            text = String(text[range.upperBound...])
        }
        if let regex = try? NSRegularExpression(pattern: #"<image\b[^>]*>[\s\S]*?</image>"#, options: .caseInsensitive) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
        if let regex = try? NSRegularExpression(pattern: #"<image\b[^>]*/?>"#, options: .caseInsensitive) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
        if let regex = try? NSRegularExpression(pattern: #"\[Image\s*#[^\]]*\]\([^)]*\)"#, options: .caseInsensitive) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
        return cleanPiSessionTitle(text)
    }
}
