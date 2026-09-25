import Foundation
import SQLite3

// Turning transcript text into facts: the generic record walk, the Codex and
// Pi parsers, the agent's own plan and words, merging, and row shaping.

extension NativeActivityHarvest {
    // MARK: - Conservative metadata extraction

    static func parseFacts(_ text: String, structured: Bool, path: String) -> [Fact] {
        if path.lowercased().contains("/.codex/") && path.lowercased().hasSuffix(".jsonl") {
            let codex = parseCodexFacts(text, path: path)
            if !codex.isEmpty { return codex }
        }
        let lowerPath = path.lowercased()
        if lowerPath.contains("/.pi/"),
           lowerPath.hasSuffix(".jsonl") || lowerPath.hasSuffix(".ndjson") {
            let pi = parsePiFacts(text, path: path)
            if !pi.isEmpty { return pi }
            // Official envelopes without a parseable user prompt must not
            // fall through to the generic walker — that produced cwd-only
            // rows whose tray hero was the project folder name.
            if piLooksOfficial(text) { return [] }
        }
        var objects: [(Any, String)] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")),
           let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            objects.append((object, ""))
        } else {
            for line in text.split(whereSeparator: \.isNewline).suffix(256) {
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (value.hasPrefix("{") || value.hasPrefix("[")),
                      let data = value.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data)
                else { continue }
                objects.append((object, ""))
            }
        }

        var result: [Fact] = []
        var visited = 0
        for (object, context) in objects {
            walk(object, context: context, structured: structured, path: path, into: &result, visited: &visited)
            if result.count >= maxFactsPerAgent { break }
        }
        var merged = merge(result).filter(\.hasDisplaySignal)
        if usesTranscriptUserPrompt(path),
           let prompt = latestTranscriptUserPrompt(text),
           meaningfulPiPrompt(prompt) {
            if merged.isEmpty {
                var seed = Fact()
                seed.structured = structured
                seed.sourcePath = path
                seed.task = prompt
                seed.taskOrigin = .userPrompt
                merged = [seed]
            } else {
                for index in merged.indices {
                    merged[index].task = prompt
                    merged[index].taskOrigin = .userPrompt
                }
            }
        }
        // 2.8: after the seed, so a prompt-only fact still gets the plan.
        // 2.9: no path whitelist — the scanner matches shapes strictly
        // (`todos` arrays, assistant text blocks, `is_error` results), so any
        // vendor whose records carry the same structures yields the same
        // facts, and one that does not yields nothing. Codex and Pi never
        // reach here (their parsers returned above); this is the generic
        // JSONL walker's tail.
        applyTranscriptSelfReport(&merged, text: text)
        // 9.0: Gemini chats are one whole-file JSON — the line-based scan
        // above cannot see them, and the reply role is `model`, not
        // `assistant`. Walk the parsed document for the last model turn.
        if lowerPath.contains("/.gemini/"), lowerPath.contains("/chats/"),
           !merged.isEmpty,
           let root = objects.first?.0,
           let word = geminiLastWord(in: root) {
            for index in merged.indices where merged[index].lastWord.isEmpty {
                merged[index].lastWord = word
            }
        }
        return merged
    }

    /// The last `model`-role turn's text in a Gemini chat document. Arrays
    /// keep document order (the history array is the structure that matters);
    /// depth is bounded; an unrecognised layout yields nil.
    static func geminiLastWord(in value: Any, depth: Int = 0) -> String? {
        guard depth < 6 else { return nil }
        var latest: String?
        if let dict = value as? [String: Any] {
            let role = firstString(dict, keys: ["role"]).lowercased()
            if role == "model" || role == "assistant" {
                var text = firstString(dict, keys: ["text", "content"])
                if text.isEmpty, let parts = dict["parts"] as? [Any] {
                    for part in parts {
                        if let block = part as? [String: Any] {
                            let candidate = firstString(block, keys: ["text"])
                            if !candidate.isEmpty { text = candidate; break }
                        } else if let plain = part as? String, !plain.isEmpty {
                            text = plain
                            break
                        }
                    }
                }
                let line = selfReportLine(text)
                if !line.isEmpty { latest = line }
            }
            for (_, child) in dict {
                if let found = geminiLastWord(in: child, depth: depth + 1) {
                    latest = found
                }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let found = geminiLastWord(in: item, depth: depth + 1) {
                    latest = found
                }
            }
        }
        return latest
    }

    /// Claude / Command Code / Continue / Droid / Gemini chats keep one goal
    /// per file. Generic JSONL only walks the last 256 lines, so a long
    /// tool-result tail blanks the hero — same class as the Pi 0.96.1 bug.
    static func usesTranscriptUserPrompt(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.contains("/amp/") { return false }
        if lower.contains("/.claude/") { return true }
        if lower.contains("/.commandcode/") { return true }
        if lower.contains("/.continue/") { return true }
        if lower.contains("/.factory/") { return true }
        if lower.contains("/.gemini/") && lower.contains("/chats/") { return true }
        return false
    }

    static func latestTranscriptUserPrompt(_ text: String) -> String? {
        var candidates: [String] = []
        var attempts = 0
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.hasPrefix("{"), raw.contains("\"user\"") else { continue }
            attempts += 1
            if attempts > 4096 { break }
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let title = cleanPiSessionTitle(transcriptUserPrompt(from: object))
            if !title.isEmpty { candidates.append(title) }
        }
        guard !candidates.isEmpty else { return nil }
        return candidates.first(where: { meaningfulPiPrompt($0) }) ?? candidates[0]
    }

    // MARK: - Self-report (2.8): the agent's own plan, words, and errors

    /// The plan checklist is bounded for display, but the counts must come
    /// from the whole list — a capped list quoting its own length would be an
    /// estimate wearing an exact number's clothes.
    static let maxPlanSteps = 8
    static let maxPlanStepLength = 100
    static let maxSelfReportLength = 160

    /// The most valuable structure in a transcript is the one the agent
    /// writes for itself: its todo list. It used to be filtered out wholesale
    /// because plan-step titles once polluted the tray hero — the pollution
    /// was real, but the cure threw away the progress with it. This reads the
    /// structure on purpose, into fields that are not the hero.
    ///
    /// One reversed pass over the window, three independent finds, each
    /// "latest wins": the last `todos` array (a plan is a state, not an
    /// event), the last assistant text line, the last failed tool result.
    /// Substring prefilters keep megabyte tool-result lines O(1) until one
    /// actually needs decoding.
    static func applyTranscriptSelfReport(_ facts: inout [Fact], text: String) {
        guard !facts.isEmpty else { return }
        var plan: (steps: [ActivityHarvest.PlanStep], current: String, done: Int, total: Int)?
        var word: String?
        var errorText: String?
        var decoded = 0
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            if plan != nil, word != nil, errorText != nil { break }
            let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.hasPrefix("{") else { continue }
            let wantsPlan = plan == nil && raw.contains("\"todos\"")
            let wantsWord = word == nil && raw.contains("\"assistant\"")
            // Pi spells the flag `isError` on a standalone toolResult record;
            // the Claude family spells it `is_error` inside a content block.
            let wantsError = errorText == nil
                && (raw.contains("\"is_error\"") || raw.contains("\"isError\""))
            guard wantsPlan || wantsWord || wantsError else { continue }
            decoded += 1
            if decoded > 512 { break }
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let message = object["message"] as? [String: Any]
            let content = (message?["content"] as? [Any]) ?? (object["content"] as? [Any]) ?? []
            if wantsPlan {
                for item in content {
                    guard let block = item as? [String: Any],
                          firstString(block, keys: ["type"]).lowercased() == "tool_use",
                          let input = block["input"] as? [String: Any],
                          let todos = input["todos"] as? [Any]
                    else { continue }
                    if let parsed = planFacts(from: todos) { plan = parsed }
                }
            }
            if wantsWord,
               firstString(message ?? object, keys: ["role", "type"]).lowercased() == "assistant" {
                for item in content {
                    guard let block = item as? [String: Any],
                          firstString(block, keys: ["type"]).lowercased() == "text"
                    else { continue }
                    let line = selfReportLine(firstString(block, keys: ["text"]))
                    if !line.isEmpty { word = line; break }
                }
            }
            if wantsError {
                for item in content {
                    guard let block = item as? [String: Any],
                          firstString(block, keys: ["type"]).lowercased() == "tool_result",
                          anyTruthy(block, keys: ["is_error", "isError"])
                    else { continue }
                    let body: String
                    if let text = block["content"] as? String {
                        body = text
                    } else {
                        body = userMessageText(block["content"])
                    }
                    let line = selfReportLine(body)
                    if !line.isEmpty { errorText = line; break }
                }
                // Pi: a failed result is its own record — role `toolResult`
                // with `isError` and the output at the record level.
                if errorText == nil {
                    let container = message ?? object
                    let role = firstString(container, keys: ["role", "type"]).lowercased()
                    if role == "toolresult" || role == "tool_result",
                       anyTruthy(container, keys: ["is_error", "isError"]) {
                        let body: String
                        if let text = container["content"] as? String {
                            body = text
                        } else if let text = container["output"] as? String {
                            body = text
                        } else {
                            body = userMessageText(container["content"])
                        }
                        let line = selfReportLine(body)
                        if !line.isEmpty { errorText = line }
                    }
                }
            }
        }
        guard plan != nil || word != nil || errorText != nil else { return }
        for index in facts.indices {
            if let plan {
                facts[index].planSteps = plan.steps
                facts[index].planStep = plan.current
                facts[index].progressDone = plan.done
                facts[index].progressTotal = plan.total
            }
            if let word { facts[index].lastWord = word }
            if let errorText { facts[index].lastErrorText = errorText }
        }
    }

    /// Vendor todo/plan items → bounded steps plus whole-list counts.
    /// Understands Claude's `{content, status, activeForm}` and Codex's
    /// `{step, status}`. The current step's display text prefers
    /// `activeForm` ("Running tests") over the imperative `content`
    /// ("Run tests") because it is the one written to describe *now*.
    static func planFacts(
        from items: [Any]
    ) -> (steps: [ActivityHarvest.PlanStep], current: String, done: Int, total: Int)? {
        var steps: [ActivityHarvest.PlanStep] = []
        var current = ""
        for item in items {
            guard let dict = item as? [String: Any] else { continue }
            let text = clean(
                ContentSanitizer.redact(firstString(dict, keys: ["content", "step", "text", "title"])),
                limit: maxPlanStepLength
            )
            guard !text.isEmpty else { continue }
            let status = firstString(dict, keys: ["status", "state"]).lowercased()
            let state: ActivityHarvest.PlanStep.State
            switch status {
            case "completed", "complete", "done":
                state = .done
            case "in_progress", "inprogress", "active", "current":
                state = .current
            default:
                state = .pending
            }
            if state == .current, current.isEmpty {
                let active = clean(
                    ContentSanitizer.redact(firstString(dict, keys: ["activeForm", "active_form"])),
                    limit: maxPlanStepLength
                )
                current = active.isEmpty ? text : active
            }
            steps.append(ActivityHarvest.PlanStep(text: text, state: state))
        }
        guard !steps.isEmpty else { return nil }
        let done = steps.filter { $0.state == .done }.count
        let total = steps.count
        // Bound for display only, after the counts. Drop finished items
        // first (oldest first, wherever they sit — the original leading-
        // prefix loop stopped at the first non-done item and could then
        // truncate the current step away; Codex review on #74), then the
        // furthest-future pending items. The current item is never dropped:
        // a checklist whose `▸` is missing while `planStep` names one would
        // be the view contradicting its own summary.
        var bounded = steps
        while bounded.count > maxPlanSteps,
              let index = bounded.firstIndex(where: { $0.state == .done }) {
            bounded.remove(at: index)
        }
        while bounded.count > maxPlanSteps,
              let index = bounded.lastIndex(where: { $0.state == .pending }) {
            bounded.remove(at: index)
        }
        bounded = Array(bounded.prefix(maxPlanSteps))
        return (bounded, current, done, total)
    }

    /// One sanitized line of the agent's own text — first non-empty line,
    /// bounded. Used for both "what it just said" and "what just failed".
    static func selfReportLine(_ raw: String) -> String {
        for line in ContentSanitizer.redact(raw).split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            return clean(trimmed, limit: maxSelfReportLength)
        }
        return ""
    }

    static func transcriptUserPrompt(from dict: [String: Any]) -> String {
        if let nested = dict["message"] as? [String: Any],
           firstString(nested, keys: ["role", "type", "kind"]).lowercased() == "user" {
            let text = userMessageText(nested["content"] ?? nested["text"])
            if !text.isEmpty { return text }
        }
        if isUserRecord(dict) {
            return userMessageText(firstValue(dict, keys: ["content", "text", "message"]))
        }
        return ""
    }

    /// Visible user text only — skip tool_result / tool_call envelopes.
    /// Command Code (and Claude) store tool results as role=user records.
    static func userMessageText(_ value: Any?) -> String {
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
                if isToolEnvelope(dict) { return nil }
                let text = firstString(dict, keys: ["text"])
                if !text.isEmpty { return text }
                if ["input_text", "output_text", "text"].contains(
                    firstString(dict, keys: ["type"]).lowercased().replacingOccurrences(of: "-", with: "_")
                ) {
                    let nested = firstString(dict, keys: ["content"])
                    return nested.isEmpty ? nil : nested
                }
                return nil
            }
            return parts.joined(separator: " ")
        }
        if let dict = value as? [String: Any] {
            if isToolEnvelope(dict) { return "" }
            let text = firstString(dict, keys: ["text"])
            if !text.isEmpty { return text }
            return userMessageText(dict["content"])
        }
        return ""
    }

    static func isToolEnvelope(_ dict: [String: Any]) -> Bool {
        let kind = firstString(dict, keys: ["type"]).lowercased().replacingOccurrences(of: "-", with: "_")
        let tools: Set<String> = [
            "tool_result", "tool_call_output", "custom_tool_call_output",
            "function_call_output", "function_response", "mcp_tool_call_end",
            "tool_use", "tool_call", "function_call", "custom_tool_call",
            "mcp_tool_call", "functioncall",
        ]
        return tools.contains(kind)
    }

    static func isToolShapedRecord(_ dict: [String: Any]) -> Bool {
        if isToolEnvelope(dict) { return true }
        let kind = firstString(dict, keys: ["type"]).lowercased().replacingOccurrences(of: "-", with: "_")
        return kind == "file_read" || kind == "tool_use" || kind == "tool_call"
    }

    static func cwdKeys(for dict: [String: Any]) -> [String] {
        var keys = [
            "cwd", "workingDirectory", "workdir", "workDir", "workspacePath", "workspace_path",
            "projectPath", "project_path", "directory", "worktree", "repoPath",
            "workspace",
        ]
        // `path` is a Cline/Cascade workspace alias on session objects, and a
        // file argument on tool_use. Only the former is a cwd.
        if !isToolShapedRecord(dict) {
            keys.append("path")
        }
        return keys
    }

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

    static func walk(
        _ object: Any,
        context: String,
        structured: Bool,
        path: String,
        into result: inout [Fact],
        visited: inout Int
    ) {
        visited += 1
        guard visited <= maxObjectNodes else { return }
        if let array = object as? [Any] {
            for child in array.prefix(512) {
                walk(child, context: context, structured: structured, path: path, into: &result, visited: &visited)
            }
            return
        }
        guard let dict = object as? [String: Any] else { return }
        let fact = fact(from: dict, context: context, structured: structured, path: path)
        if fact.hasUsefulSignal {
            result.append(fact)
        }
        for (key, child) in dict {
            guard child is [String: Any] || child is [Any] else { continue }
            let childContext = context.isEmpty ? key : "\(context).\(key)"
            walk(child, context: childContext, structured: structured, path: path, into: &result, visited: &visited)
            if result.count >= maxFactsPerAgent { return }
        }
    }

    static func fact(
        from dict: [String: Any],
        context: String,
        structured: Bool,
        path: String
    ) -> Fact {
        var f = Fact()
        f.context = context
        f.structured = structured
        f.sourcePath = path
        // Prompt-shaped keys first, vendor headlines second. The precedence is
        // unchanged from 0.97; what is new is that each branch records *which*
        // kind of key won, so a later merge can rank fragments instead of
        // comparing their lengths.
        f.task = firstString(dict, keys: [
            "task", "goal", "prompt", "query", "user_message", "userMessage",
            "lastMessage", "last_message", "subject",
        ])
        if !f.task.isEmpty { f.taskOrigin = .userPrompt }
        if f.task.isEmpty {
            // Vendor chrome — often "Agent session" / plan-step titles.
            f.task = firstString(dict, keys: [
                "title", "summary", "description", "lastPrompt",
                "aiTitle", "customTitle", "subtitle",
            ])
            if !f.task.isEmpty {
                f.taskOrigin = isToolShapedRecord(dict) ? .toolTitle : .cacheTitle
            }
        }
        if (f.task.isEmpty || isChromeTask(f.task)), !isToolShapedRecord(dict) {
            let named = firstString(dict, keys: ["name"])
            if !named.isEmpty {
                f.task = named
                f.taskOrigin = .cacheTitle
            }
        }
        if f.task.isEmpty, isUserRecord(dict) {
            f.task = userMessageText(firstValue(dict, keys: ["content", "message", "text"]))
            if !f.task.isEmpty { f.taskOrigin = .userPrompt }
        }
        // Pi (and kin) wrap the user turn as `{type:"message", message:{role:"user"}}`.
        // Top-level type is "message", so isUserRecord misses it.
        if f.task.isEmpty || isChromeTask(f.task),
           let nested = dict["message"] as? [String: Any],
           firstString(nested, keys: ["role", "type", "kind"]).lowercased() == "user" {
            let prompt = userMessageText(nested["content"] ?? firstValue(nested, keys: ["text", "message"]))
            if !prompt.isEmpty {
                f.task = prompt
                f.taskOrigin = .userPrompt
            }
        }
        // Cache / IDE JSON often nests the real goal under messages[] while the
        // parent title is chrome ("Cascade session"). Prefer the latest user
        // turn when the headline is empty or chrome-only — never invent text.
        if f.task.isEmpty || isChromeTask(f.task),
           let messages = dict["messages"] as? [Any] {
            for item in messages.reversed() {
                guard let msg = item as? [String: Any], isUserRecord(msg) else { continue }
                let prompt = userMessageText(firstValue(msg, keys: ["content", "message", "text", "prompt"]))
                if !prompt.isEmpty {
                    f.task = prompt
                    f.taskOrigin = .userPrompt
                    break
                }
            }
        }
        // Amp's modern history.jsonl deliberately keeps each user prompt as
        // `{text, cwd}` without a role/type marker. This is still a safe,
        // session-shaped source (and is the only useful source on installs
        // without hooks), so recover the prompt instead of rendering a blank
        // “Amp session” row.
        if f.task.isEmpty,
           path.lowercased().contains("/amp/"),
           path.lowercased().hasSuffix("history.jsonl"),
           !normalizedPath(firstString(dict, keys: ["cwd", "workdir", "workingDirectory"])).isEmpty {
            f.task = textValue(firstValue(dict, keys: ["text", "content", "prompt", "query"]))
            if !f.task.isEmpty { f.taskOrigin = .userPrompt }
        }
        f.cwd = normalizedPath(firstString(dict, keys: cwdKeys(for: dict)))
        if looksLikeFilePathCwd(f.cwd) { f.cwd = "" }
        f.project = firstString(dict, keys: ["project", "projectName", "project_name", "repository", "repoName"])
        f.sessionID = firstString(dict, keys: [
            "sessionId", "session_id", "threadId", "thread_id", "conversationId",
            "conversation_id", "rolloutId", "rollout_id", "taskId", "task_id",
        ])
        if f.sessionID.isEmpty,
           contextLooksSession(context),
           !path.lowercased().contains("/.gemini/tmp/") {
            let rawID = firstString(dict, keys: ["uuid", "id"])
            if rawID.count >= 8 { f.sessionID = rawID }
        }
        f.tool = firstString(dict, keys: [
            "currentTool", "current_tool", "lastTool", "last_tool", "lastAction",
            "last_action", "toolName", "tool_name", "tool",
        ])
        // Claude / Anthropic transcripts emit `{type:"tool_use", name:"Bash"}`
        // rather than a lastTool field. Same-dict name only — never the next
        // sibling's name.
        if f.tool.isEmpty {
            let recordType = firstString(dict, keys: ["type"]).lowercased()
            if ["tool_use", "tool_call", "function_call", "custom_tool_call", "toolcall"].contains(recordType) {
                f.tool = firstString(dict, keys: ["name", "toolName", "tool_name"])
                // 8.2: a Skill/workflow invocation names the workflow in its
                // input — the one place the fact exists in the transcript.
                if f.skill.isEmpty, f.tool.lowercased() == "skill",
                   let input = dict["input"] as? [String: Any] {
                    f.skill = firstString(input, keys: ["skill", "skillName", "skill_name", "command"])
                }
            }
        }
        // Gemini / Google-style functionCall objects (0.82).
        if f.tool.isEmpty {
            if let fc = dict["functionCall"] as? [String: Any]
                ?? dict["function_call"] as? [String: Any] {
                f.tool = firstString(fc, keys: ["name", "toolName", "tool_name"])
            }
        }
        f.skill = firstString(dict, keys: ["skill", "skillName", "skill_name"])
        let phaseRaw = firstString(dict, keys: ["phase", "stage", "currentPhase", "current_phase", "status", "state"])
        f.phase = semanticPhase(phaseRaw)
        f.outcome = firstString(dict, keys: ["outcome", "result", "completion", "finalStatus", "final_status"])
        f.model = firstString(dict, keys: [
            "model", "modelId", "model_id", "modelName", "model_name",
            "currentModel", "current_model", "current_model_id",
        ])
        if f.model.isEmpty, let details = dict["modelDetails"] as? [String: Any]
            ?? dict["model_details"] as? [String: Any] {
            f.model = firstString(details, keys: [
                "modelName", "model_name", "model", "modelId", "model_id", "name",
            ])
        }
        f.mode = firstString(dict, keys: [
            "unifiedMode", "unified_mode", "composerMode", "composer_mode",
            "agentMode", "agent_mode", "mode", "role",
        ])
        f.tokensIn = firstNumber(dict, keys: [
            "inputTokens", "input_tokens", "promptTokens", "prompt_tokens",
            "inputTokenCount", "input_token_count", "promptTokenCount",
        ])
        f.tokensOut = firstNumber(dict, keys: [
            "outputTokens", "output_tokens", "completionTokens", "completion_tokens",
            "outputTokenCount", "output_token_count", "completionTokenCount",
            "candidatesTokenCount", "candidates_token_count",
        ])
        // Claude / Anthropic: model + usage live under `message`, not the
        // envelope. Dig once so tray observation is not empty when walk order
        // would otherwise drop a child-only fragment (0.81).
        if let message = dict["message"] as? [String: Any] {
            if f.model.isEmpty {
                f.model = firstString(message, keys: [
                    "model", "modelId", "model_id", "modelName", "currentModel", "current_model",
                ])
            }
            applyTokenUsage(&f, message["usage"] as? [String: Any])
            if f.tool.isEmpty, let content = message["content"] as? [Any] {
                for item in content.reversed() {
                    guard let block = item as? [String: Any] else { continue }
                    let blockType = firstString(block, keys: ["type"]).lowercased()
                    if ["tool_use", "tool_call", "function_call", "custom_tool_call", "toolcall"].contains(blockType) {
                        let name = firstString(block, keys: ["name", "toolName", "tool_name"])
                        if !name.isEmpty {
                            f.tool = name
                            if f.skill.isEmpty, name.lowercased() == "skill",
                               let input = block["input"] as? [String: Any] {
                                f.skill = firstString(input, keys: ["skill", "skillName", "skill_name", "command"])
                            }
                            break
                        }
                    }
                }
            }
        }
        applyTokenUsage(&f, dict["usage"] as? [String: Any])
        applyTokenUsage(&f, dict["usageMetadata"] as? [String: Any])
        applyTokenUsage(&f, dict["usage_metadata"] as? [String: Any])
        if let response = dict["response"] as? [String: Any] {
            applyTokenUsage(&f, response["usage"] as? [String: Any])
            applyTokenUsage(&f, response["usageMetadata"] as? [String: Any])
        }
        f.errors = firstNumber(dict, keys: ["errorCount", "errors", "toolFailureCount", "tool_failures"])
        f.files = firstNumber(dict, keys: [
            "filesChanged", "filesChangedCount", "totalFilesTouched",
            "filesTouched", "fileCount",
        ])
        f.contextPercent = contextPercent(firstValue(dict, keys: [
            "contextWindowUsage", "contextUsagePercent", "contextPercent", "context_percent",
            "contextUsage",
        ]))
        f.progressDone = firstNumber(dict, keys: ["completedTasks", "completed", "doneCount", "progressDone"])
        f.progressTotal = firstNumber(dict, keys: ["totalTasks", "total", "taskCount", "progressTotal"])
        f.subRunning = firstNumber(dict, keys: ["subagentsRunning", "subRunning", "activeSubagents"])
        f.subTotal = firstNumber(dict, keys: ["subagentsTotal", "subTotal", "totalSubagents"])
        let pendingFlagKeys = [
            "needsApproval", "needs_approval", "awaitingInput", "awaiting_input",
            "requiresAction", "requires_action", "pending",
            "hasBlockingPendingActions", "hasPendingPlan",
            // Explicit waiting-for-user flags (bool / yes / pending / waiting).
            // Do not include askResponse — in Cline that field means the user
            // already answered; see vendorAskFieldPending.
            "isWaitingForResponse", "is_waiting_for_response",
            "waitingForResponse", "waiting_for_response",
            "isAwaitingUserResponse", "is_awaiting_user_response",
            "userResponseNeeded", "user_response_needed",
            "didAskFollowupQuestion", "did_ask_followup_question",
            // 0.94 Waiting Proof — additional explicit vendor flags only.
            "requiresUserAction", "requires_user_action",
            "awaitingConfirmation", "awaiting_confirmation",
            "isBlockedOnUser", "is_blocked_on_user",
            "blockedOnUser", "blocked_on_user",
        ]
        // 0.95: any true flag wins — firstValue was nondeterministic across aliases.
        let flagPending = anyTruthy(dict, keys: pendingFlagKeys)
        let answeredAsk = vendorAskAlreadyAnswered(dict)
        let terminalOutcome = isTerminalSessionState(phaseRaw) || isTerminalSessionState(f.outcome)
            || isTerminalSessionState(firstString(dict, keys: ["status", "state", "lifecycle"]))
        let askToolPending = isVendorAskTool(f.tool) && !answeredAsk && !terminalOutcome
        f.explicitPending = !answeredAsk && !terminalOutcome && (
            flagPending
                || pendingPhase(phaseRaw)
                || pendingPhase(f.outcome)
                || askToolPending
                || vendorAskFieldPending(dict)
        )
        if f.explicitPending { f.skill = "pending" }
        let stamped = normalizeTimestamp(firstValue(dict, keys: [
            "lastUpdatedAt", "last_updated_at", "updatedAt", "updated_at",
            "time_updated", "timestamp", "modifiedAt", "modified_at",
        ]))
        if stamped > 0 { f.activityMs = stamped }

        if f.project.isEmpty, !f.cwd.isEmpty { f.project = lastPathComponent(f.cwd) }
        f.task = clean(f.task, limit: 160)
        f.project = clean(f.project, limit: 64)
        f.cwd = clean(f.cwd, limit: 240)
        f.sessionID = clean(f.sessionID, limit: 80)
        f.tool = clean(f.tool, limit: 64)
        f.skill = clean(f.skill, limit: 64)
        f.model = clean(f.model, limit: 64)
        f.mode = clean(f.mode, limit: 64)
        f.phase = clean(f.phase, limit: 64)
        f.outcome = clean(f.outcome, limit: 64)
        f.score = [
            !f.task.isEmpty, !f.cwd.isEmpty, !f.sessionID.isEmpty,
            !f.tool.isEmpty, !f.phase.isEmpty, !f.model.isEmpty,
            f.tokensIn > 0 || f.tokensOut > 0, f.progressTotal > 0,
        ].filter { $0 }.count
        return f
    }

    /// 9.0 — Aider's markdown history: the last non-fence, non-header prose
    /// line after the newest `#### ` user turn. Internal for the unit test.
    static func aiderLastWord(from text: String) -> String {
        var inFence = false
        var afterUser = false
        var word = ""
        for line in text.split(whereSeparator: \.isNewline) {
            let value = String(line).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            if value.hasPrefix("#### ") {
                afterUser = true
                word = ""
                continue
            }
            if value.isEmpty || value.hasPrefix("#") || value.hasPrefix(">") { continue }
            if afterUser { word = value }
        }
        return selfReportLine(word)
    }

    static func textFacts(_ text: String, structured: Bool, path: String) -> Fact? {
        var f = Fact()
        f.structured = structured
        f.sourcePath = path
        f.task = regexValue(text, patterns: [
            #"(?i)\"(?:task|title|summary|subject|prompt)\"\s*:\s*\"([^\"]{1,240})\""#,
        ])
        if !f.task.isEmpty { f.taskOrigin = .fallbackText }
        f.cwd = normalizedPath(regexValue(text, patterns: [
            #"(?i)\"(?:cwd|workdir|workingDirectory|workspacePath)\"\s*:\s*\"([^\"]+)\""#,
        ]))
        f.sessionID = regexValue(text, patterns: [
            #"(?i)\"(?:sessionId|session_id|threadId|conversationId|rolloutId)\"\s*:\s*\"([^\"]{6,100})\""#,
        ])
        f.model = regexValue(text, patterns: [#"(?i)\"(?:model|modelId)\"\s*:\s*\"([^\"]+)\""#])
        f.tool = regexValue(text, patterns: [#"(?i)\"(?:lastTool|lastAction|toolName)\"\s*:\s*\"([^\"]+)\""#])
        // 9.0: Aider's chat history is markdown — `#### ` heads each user
        // turn, the agent's prose follows. The last plain paragraph after
        // the newest user turn is the agent's latest word.
        if path.lowercased().contains("aider"), path.lowercased().contains("history") {
            f.lastWord = aiderLastWord(from: text)
        }
        f.phase = semanticPhase(regexValue(text, patterns: [#"(?i)\"(?:phase|stage|status|state)\"\s*:\s*\"([^\"]+)\""#]))
        f.outcome = regexValue(text, patterns: [#"(?i)\"(?:outcome|result|finalStatus)\"\s*:\s*\"([^\"]+)\""#])
        // Display fields only. This is the *free-text* fallback: it runs on
        // `.txt` / `.md` / `.log` files and on JSON the real parsers could not
        // read, with regexes that cannot tell a session's own status from a
        // status quoted inside it. A `"status": "waiting"` sample pasted into
        // a design note is enough to light a red lamp — and Waiting comes
        // from hooks or a structured `skill=pending`, never from inference.
        // Nothing here may set `skill`; the fields above are what a row shows,
        // not what it claims about needing you.
        if f.project.isEmpty, !f.cwd.isEmpty { f.project = lastPathComponent(f.cwd) }
        f.task = clean(f.task, limit: 160)
        f.cwd = clean(f.cwd, limit: 240)
        f.project = clean(f.project, limit: 64)
        f.sessionID = clean(f.sessionID, limit: 80)
        f.model = clean(f.model, limit: 64)
        f.tool = clean(f.tool, limit: 64)
        f.phase = clean(f.phase, limit: 64)
        f.outcome = clean(f.outcome, limit: 64)
        return f.hasUsefulSignal ? f : nil
    }

    static func merge(_ input: [Fact]) -> [Fact] {
        var byID: [String: Fact] = [:]
        for item in input {
            guard item.hasUsefulSignal else { continue }
            let key = item.identity
            if var current = byID[key] {
                merge(&current, item)
                byID[key] = current
            } else {
                byID[key] = item
            }
        }
        return byID.values.sorted {
            if $0.activityMs != $1.activityMs { return $0.activityMs > $1.activityMs }
            return $0.score > $1.score
        }
    }

    static func merge(_ target: inout Fact, _ source: Fact) {
        if piJSONLResumeTitle(target.sourcePath, target.task), isPiSqlitePath(source.sourcePath) {
            // JSONL is the /resume title. A SQLite fragment for the same
            // session never displaces it.
        } else if piJSONLResumeTitle(source.sourcePath, source.task), isPiSqlitePath(target.sourcePath) {
            target.task = source.task
            target.taskOrigin = source.taskOrigin
        } else {
            preferTask(&target, source)
        }
        func prefer(_ old: inout String, _ new: String) { if old.isEmpty, !new.isEmpty { old = new } }
        prefer(&target.project, source.project)
        // The confidence travels with the path it describes: whichever
        // fragment supplies `cwd` supplies `cwdBestEffort` with it, so a
        // confirmed path is never inherited by an unconfirmed one or vice
        // versa.
        if looksLikeFilePathCwd(target.cwd), !source.cwd.isEmpty, !looksLikeFilePathCwd(source.cwd) {
            target.cwd = source.cwd
            target.cwdBestEffort = source.cwdBestEffort
        } else if target.cwd.isEmpty, !source.cwd.isEmpty {
            target.cwd = source.cwd
            target.cwdBestEffort = source.cwdBestEffort
        }
        prefer(&target.sessionID, source.sessionID)
        // Last non-empty tool / model wins — Claude assistant envelopes arrive
        // after the user prompt; prefer-first left rows without telemetry.
        if !source.tool.isEmpty { target.tool = source.tool }
        // 0.95: pending follows the newest fragment by activityMs — never OR
        // an older ask onto a newer answered/cleared turn.
        if source.activityMs > target.activityMs {
            target.explicitPending = source.explicitPending
            if source.explicitPending || source.skill == "pending" {
                target.skill = "pending"
            } else if target.skill == "pending" {
                target.skill = source.skill
            } else {
                prefer(&target.skill, source.skill)
            }
        } else if source.activityMs == target.activityMs {
            target.explicitPending = target.explicitPending || source.explicitPending
            if target.explicitPending {
                target.skill = "pending"
            } else {
                prefer(&target.skill, source.skill)
            }
        } else if target.skill.isEmpty, source.skill != "pending", !source.explicitPending {
            prefer(&target.skill, source.skill)
        }
        prefer(&target.phase, source.phase); prefer(&target.outcome, source.outcome)
        if !source.model.isEmpty { target.model = source.model }
        if !source.mode.isEmpty { target.mode = source.mode }
        // Latest turn usage wins (Claude assistant envelopes; matches Codex
        // last_token_usage semantics). Never sum every turn into the tray.
        if source.tokensIn > 0 { target.tokensIn = source.tokensIn }
        if source.tokensOut > 0 { target.tokensOut = source.tokensOut }
        target.errors = max(target.errors, source.errors); target.files = max(target.files, source.files)
        target.contextPercent = max(target.contextPercent, source.contextPercent)
        target.progressDone = max(target.progressDone, source.progressDone)
        target.progressTotal = max(target.progressTotal, source.progressTotal)
        target.subRunning = max(target.subRunning, source.subRunning)
        target.subTotal = max(target.subTotal, source.subTotal)
        // explicitPending already resolved above by activityMs order — do not OR.
        target.score = max(target.score, source.score)
        target.activityMs = max(target.activityMs, source.activityMs)
        target.startedMs = target.startedMs == 0 ? source.startedMs : min(target.startedMs, source.startedMs == 0 ? target.startedMs : source.startedMs)
        target.records = max(target.records, source.records)
        target.windowTruncated = target.windowTruncated || source.windowTruncated
        target.structured = target.structured || source.structured
        mergeDigestFacts(&target, source)
    }

    /// Digest facts describe a whole file, not a fragment of one.
    ///
    /// Every fragment of the same transcript is stamped with the same digest,
    /// so in the ordinary case these merges are no-ops. They exist for the
    /// cases where they are not: a fragment shaped before the digest existed,
    /// and two files that legitimately share one session id. Taking the
    /// stronger side follows the tokens/progress rule already above — the
    /// weaker side is always an emptier read of the same thing.
    static func mergeDigestFacts(_ target: inout Fact, _ source: Fact) {
        // A longer run of the same tool is the more complete observation of
        // the same tail; an empty target has loopCount 0 and always loses.
        if source.loopCount > target.loopCount, !source.loopTool.isEmpty {
            target.loopTool = source.loopTool
            target.loopCount = source.loopCount
        }
        target.sessionErrors = max(target.sessionErrors, source.sessionErrors)
        if target.toolSummary.isEmpty { target.toolSummary = source.toolSummary }
        // Ordered, oldest first: the longer list is the one that saw more of
        // the session. Merging them elementwise would invent an order neither
        // side observed.
        if source.recentTools.count > target.recentTools.count {
            target.recentTools = source.recentTools
        }
        target.sessionTokensIn = max(target.sessionTokensIn, source.sessionTokensIn)
        target.sessionTokensOut = max(target.sessionTokensOut, source.sessionTokensOut)
        target.digestProgressPercent = max(
            target.digestProgressPercent, source.digestProgressPercent
        )
        target.digestCaughtUp = target.digestCaughtUp || source.digestCaughtUp
        target.bytesPerMinute = max(target.bytesPerMinute, source.bytesPerMinute)
        // The one field here that is not a max. Everything else above is a
        // count or a percentage, where "more" means "read more of the file";
        // this is an *origin*, where the truthful answer is the earliest
        // moment observed. Taking the max would make a session look younger
        // every time a second fragment turned up — the opposite of the fact.
        if target.sessionStartedMs == 0 {
            target.sessionStartedMs = source.sessionStartedMs
        } else if source.sessionStartedMs > 0 {
            target.sessionStartedMs = min(target.sessionStartedMs, source.sessionStartedMs)
        }
    }

    /// Merge two fragments' hero titles by the kind of record each came from.
    ///
    /// There is deliberately no comparison of string length here. The rank in
    /// `TaskOrigin` is the whole rule: a user turn beats a cache headline no
    /// matter how short, and a session the user named beats both. Two
    /// fragments of the same kind keep the first one seen — which is what "the
    /// /resume title is the *first* user message" means — unless the later
    /// fragment is demonstrably newer.
    static func preferTask(_ target: inout Fact, _ source: Fact) {
        guard !source.task.isEmpty else { return }
        let incoming = effectiveOrigin(source.task, source.taskOrigin)
        guard incoming > .chrome || target.task.isEmpty else { return }
        if target.task.isEmpty {
            target.task = source.task
            target.taskOrigin = source.taskOrigin
            return
        }
        let current = effectiveOrigin(target.task, target.taskOrigin)
        if incoming > current
            || (incoming == current && source.activityMs > target.activityMs) {
            target.task = source.task
            target.taskOrigin = source.taskOrigin
        }
    }

    /// A vendor placeholder or a bare filename can never win a merge, whatever
    /// record produced it. A title recorded without an origin is treated as a
    /// cache headline — the weakest claim that is still a real title.
    static func effectiveOrigin(_ task: String, _ origin: TaskOrigin) -> TaskOrigin {
        if task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .none }
        if isChromeTask(task) || AgentRow.looksLikeFilenameOnlyTitle(task) { return .chrome }
        return origin == .none ? .cacheTitle : origin
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

    /// The collector's view of the one chrome vocabulary. 0.98 collapsed the
    /// two copies that lived in this file; 0.99 folded in the third, which was
    /// inside `AgentRow.usefulTask`, so the definition now lives beside the row
    /// that renders it.
    static func isChromeTask(_ value: String) -> Bool {
        AgentRow.isChromeTitle(value)
    }

    /// Cline/Roo/Cascade (+ kin) ask tool ids — exact tokens only, never free-text inference.
    static func isVendorAskTool(_ tool: String) -> Bool {
        let normalized = tool.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let markers: Set<String> = [
            "ask_followup_question", "askfollowupquestion",
            "waiting_for_response", "waitingforresponse",
            "ask_user", "askuser",
            "ask_clarifying_question", "askclarifyingquestion",
            "request_user_input", "requestuserinput",
            // 0.94 Waiting Proof — additional exact vendor ask tools.
            "ask_question", "askquestion",
            "ask_user_question", "askuserquestion",
            "confirm_with_user", "confirmwithuser",
            "get_user_input", "getuserinput",
            "request_approval", "requestapproval",
        ]
        return markers.contains(normalized)
    }

    /// Cline (and kin) stamp an `ask` field while blocked on the user.
    /// When `askResponse` is already present, the user answered — not pending.
    static func vendorAskAlreadyAnswered(_ dict: [String: Any]) -> Bool {
        guard let raw = firstValue(dict, keys: ["askResponse", "ask_response"]) else { return false }
        if let flag = raw as? Bool { return flag }
        let text = stringValue(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty
    }

    static func isTerminalSessionState(_ value: String) -> Bool {
        let normalized = value.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let terminals: Set<String> = [
            "completed", "complete", "done", "finished", "cancelled", "canceled",
            "error", "failed", "rejected", "aborted", "stopped",
        ]
        if terminals.contains(normalized) { return true }
        let tokens = normalized
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        return tokens.contains(where: { terminals.contains($0) })
            && !tokens.contains(where: {
                ["pending", "waiting", "awaiting", "approval", "blocked"].contains($0)
            })
    }

    static func vendorAskFieldPending(_ dict: [String: Any]) -> Bool {
        let ask = firstString(dict, keys: ["ask", "askType", "ask_type"])
        guard !ask.isEmpty else { return false }
        if vendorAskAlreadyAnswered(dict) { return false }
        let normalized = ask.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let waitingAsks: Set<String> = [
            "followup", "command", "command_output", "completion_result",
            "tool", "use_mcp_server", "browser_action_launch",
            "resume_task", "resume_completed_task", "plan_mode_response",
            "clarifying_question", "user_input", "permission",
            "auto_approval_max_req_reached", "mistake_limit_reached",
            "new_task",
            // 0.94 — additional Cline-family ask enums (exact tokens).
            "yolo_mode_toggled", "api_req_failed",
        ]
        return waitingAsks.contains(normalized) || pendingPhase(ask)
    }

    /// `-Users-me-code-Pulse` → the workspace it was made from (Claude's
    /// projects directory). Empty `path` means the name is not one.
    static func decodeClaudeProjectDir(_ name: String) -> (path: String, verified: Bool) {
        let s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("-"), !s.contains("/") else { return ("", false) }
        let parts = s.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return ("", false) }
        let resolved = resolveDashEncodedPath(parts)
        if resolved.verified { return resolved }
        // Nothing on disk vouched for it, so the old shape check still stands
        // guard: an unconfirmed decode is only worth showing when it at least
        // looks like a home directory.
        let head = parts[0].lowercased()
        guard head == "users" || head == "home" else { return ("", false) }
        return resolved
    }

    /// How many `-` separated pieces a project directory name may have before
    /// resolving it stops being worth the stat calls.
    static let maxDashPathSegments = 32
    /// Hard ceiling on directory probes for one name. The search backtracks,
    /// so a pathological name (`-a-a-a-a-…`) could otherwise walk a large
    /// tree; past this the answer is "could not confirm", which is a fine
    /// answer.
    static let maxDashPathProbes = 256

    /// Resolved project directories, for the duration of one scan.
    ///
    /// One project directory holds every session file for that workspace, and
    /// the answer cannot change mid-pass, so without this the same name is
    /// re-probed once per transcript. `scan()` clears it, so a resolution
    /// never outlives the pass that made it. Scans run on one serial queue
    /// (`StatusStore.scanQueue`) and the CLI paths are single-threaded — the
    /// same convention `HarvestDigests` relies on and states.
    static var dashPathCache: [String: (path: String, verified: Bool)] = [:]

    /// Turn `["Users", "me", "my", "project"]` back into a real directory.
    ///
    /// Claude (`~/.claude/projects/-Users-me-my-project`) and Pi
    /// (`--Users-me-my-project--`) both write a workspace path with every `/`
    /// replaced by `-`, and neither escapes a `-` that was already in the
    /// path. `-Users-me-my-project` is therefore `/Users/me/my-project` and
    /// `/Users/me/my/project` at the same time, and expanding every `-`
    /// silently chose the second — for a hyphenated project name, which is
    /// most of them. That wrong path is not cosmetic: it is what Focus opens
    /// a terminal or an IDE on.
    ///
    /// The workspace the name was made from exists, so the filesystem can
    /// settle what the encoding threw away. Walk the pieces left to right and
    /// keep the first combination that exists as a directory, trying the
    /// plain piece before any `-`-joined merge so every name that already
    /// resolved correctly still resolves to exactly the same place.
    /// Backtrack when a prefix leads nowhere. When nothing matches — the
    /// workspace was deleted, the volume is not mounted — hand back the naive
    /// decode marked unverified: worth showing, never worth landing on.
    static func resolveDashEncodedPath(_ segments: [String]) -> (path: String, verified: Bool) {
        let naive = "/" + segments.joined(separator: "/")
        guard !segments.isEmpty, segments.count <= maxDashPathSegments else {
            return (naive, false)
        }
        let key = segments.joined(separator: "-")
        if let cached = dashPathCache[key] { return cached }

        let fm = FileManager.default
        var probes = 0
        func isDirectory(_ path: String) -> Bool {
            probes += 1
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        func resolve(prefix: String, from index: Int) -> String? {
            if index == segments.count { return prefix }
            var end = index + 1
            while end <= segments.count {
                if probes >= maxDashPathProbes { return nil }
                let candidate = prefix + "/" + segments[index..<end].joined(separator: "-")
                if isDirectory(candidate), let whole = resolve(prefix: candidate, from: end) {
                    return whole
                }
                end += 1
            }
            return nil
        }
        let result: (path: String, verified: Bool)
        if let resolved = resolve(prefix: "", from: 0) {
            result = (path: resolved, verified: true)
        } else {
            result = (path: naive, verified: false)
        }
        if dashPathCache.count < 512 { dashPathCache[key] = result }
        return result
    }

    /// Tool `input.path` is a file, not a workspace. Adopting it as cwd made
    /// Claude (and kin) rows look like they lived in `/tmp/file-0.swift`.
    static func looksLikeFilePathCwd(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        return AgentRow.looksLikeFilenameOnlyTitle(lastPathComponent(path))
    }

    /// Layout: `~/.claude/projects/<proj>/<sessionId>/subagents/agent-*.jsonl`
    /// Running ≈ mtime within 2 minutes.
    static func claudeSubagentCounts(for sessionFile: URL) -> (running: Int, total: Int) {
        let subDir = sessionFile
            .deletingLastPathComponent()
            .appendingPathComponent(sessionFile.deletingPathExtension().lastPathComponent, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: subDir.path) else { return (0, 0) }
        guard let files = try? fm.contentsOfDirectory(
            at: subDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }
        let now = Date().timeIntervalSince1970
        var running = 0
        var total = 0
        for file in files {
            let name = file.lastPathComponent.lowercased()
            guard name.hasPrefix("agent-"), name.hasSuffix(".jsonl") else { continue }
            total += 1
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?
                .timeIntervalSince1970 ?? 0
            if mtime > 0, now - mtime <= 120 { running += 1 }
        }
        return (running, total)
    }

    static func makeRows(from facts: [Fact], id: AgentID, home: URL) -> [ActivityHarvest.Row] {
        var seen = Set<String>()
        return facts.prefix(maxRowsPerAgent).compactMap { fact in
            guard fact.activityMs > 0 else { return nil }
            let task = clean(fact.task, limit: 160)
            let rawCwd = clean(fact.cwd, limit: 240)
            let homePath = home.standardizedFileURL.path
            let cwd = rawCwd == homePath ? "" : rawCwd
            let project = clean(fact.project.isEmpty ? lastPathComponent(cwd) : fact.project, limit: 64)
            let hasDisplaySignal = fact.hasDisplaySignal
            // A stable session id is identity, not content. Do not show blank
            // placeholders from Grok/OpenCode/Codex stores merely because the
            // vendor created an empty session record.
            guard hasDisplaySignal else { return nil }
            let placeholder = isChromeTask(task)
            if placeholder, cwd.isEmpty, fact.tool.isEmpty, fact.phase.isEmpty,
               fact.outcome.isEmpty, fact.model.isEmpty, fact.tokensIn == 0,
               fact.tokensOut == 0, fact.errors == 0, fact.files == 0,
               fact.contextPercent == 0, fact.progressTotal == 0 {
                return nil
            }
            var sid = clean(fact.sessionID, limit: 80)
            if sid.isEmpty, fact.structured { sid = sessionIDFromPath(URL(fileURLWithPath: fact.sourcePath)) }
            let key = sid.isEmpty ? "\(task)|\(cwd)|\(fact.sourcePath)" : sid
            guard seen.insert(key).inserted else { return nil }
            // Fleet honesty: bestEffortCache adapters never advertise session
            // evidence, even when a path needle or SQLite row looked "structured".
            let sessionEvidence = fact.structured && id.harvestSource == .structuredSession
            var skill = ContentSanitizer.redact(fact.skill)
            if id.waitingSource == .none, skill == "pending" {
                skill = ""
            }
            var row = ActivityHarvest.Row(
                id: id,
                task: ContentSanitizer.redact(task),
                project: ContentSanitizer.redact(project),
                cwd: ContentSanitizer.redact(cwd),
                skill: skill,
                tokensIn: max(0, fact.tokensIn),
                tokensOut: max(0, fact.tokensOut),
                tool: ContentSanitizer.redact(fact.tool),
                harvestMs: fact.activityMs,
                subRunning: max(0, fact.subRunning),
                subTotal: max(0, fact.subTotal),
                sessionID: ContentSanitizer.redact(sid),
                records: max(0, fact.records),
                startedMs: max(0, fact.startedMs),
                evidence: sessionEvidence ? .session : .cache,
                phase: ContentSanitizer.redact(fact.phase),
                outcome: ContentSanitizer.redact(fact.outcome),
                model: ContentSanitizer.redact(fact.model),
                mode: ContentSanitizer.redact(fact.mode),
                errors: max(0, fact.errors),
                files: max(0, fact.files),
                contextPercent: max(0, min(100, fact.contextPercent)),
                progressDone: max(0, fact.progressDone),
                progressTotal: max(0, fact.progressTotal)
            )
            // Digest facts are carried, never recomputed: they came from
            // reading the whole file and the window has no way to check them.
            // Only meaningful while there is a path to qualify.
            row.cwdBestEffort = !cwd.isEmpty && fact.cwdBestEffort
            // 2.8 self-report facts — already sanitized and bounded at parse
            // time; the caps here are the row boundary restating its rule.
            row.planStep = clean(fact.planStep, limit: maxPlanStepLength)
            row.planSteps = Array(fact.planSteps.prefix(maxPlanSteps))
            row.lastWord = clean(fact.lastWord, limit: maxSelfReportLength)
            row.lastErrorText = clean(fact.lastErrorText, limit: maxSelfReportLength)
            row.loopTool = fact.loopTool
            row.loopCount = max(0, fact.loopCount)
            row.sessionErrors = max(0, fact.sessionErrors)
            row.toolSummary = fact.toolSummary
            row.sessionTokensIn = max(0, fact.sessionTokensIn)
            row.sessionTokensOut = max(0, fact.sessionTokensOut)
            // Bounded again here: the fold already caps the list, and a row is
            // the boundary where that stops being an internal detail.
            row.recentTools = Array(fact.recentTools.suffix(SessionDigest.maxRecentTools))
            row.digestProgressPercent = max(0, min(100, fact.digestProgressPercent))
            row.digestCaughtUp = fact.digestCaughtUp
            row.bytesPerMinute = max(0, fact.bytesPerMinute)
            row.sessionStartedMs = max(0, fact.sessionStartedMs)
            // 4.0-α: only a real structured session transcript earns a read
            // handle — a cache/SQLite source has no conversation to render,
            // and offering one would be inventing content.
            let lowerSource = fact.sourcePath.lowercased()
            if sessionEvidence,
               lowerSource.hasSuffix(".jsonl") || lowerSource.hasSuffix(".ndjson") {
                row.transcriptPath = fact.sourcePath
            }
            return row
        }
    }
}
