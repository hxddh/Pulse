import Foundation
import PulseCore
import SQLite3

// Turning transcript text into facts: the generic record walk, the agent's
// own plan and words, merging, and row shaping. Vendor dialects (Codex, Pi,
// Claude, Gemini, Aider) live in their own files since 12.3.

extension NativeActivityHarvest {
    // MARK: - Conservative metadata extraction

    package static func parseFacts(_ text: String, structured: Bool, path: String) -> [Fact] {
        // 12.3 γ: vendor formats with their own reading are dialects.
        let dialect = TranscriptDialects.dialect(for: path)
        if let facts = dialect?.parse(text, path: path) { return facts }
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
        // above cannot see their last reply; the dialect reads it.
        dialect?.finish(&merged, root: objects.first?.0)
        return merged
    }

    /// Claude / Command Code / Continue / Droid / Gemini chats keep one goal
    /// per file. Generic JSONL only walks the last 256 lines, so a long
    /// tool-result tail blanks the hero — same class as the Pi 0.96.1 bug.
    package static func usesTranscriptUserPrompt(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.contains("/amp/") { return false }
        if lower.contains("/.claude/") { return true }
        if lower.contains("/.commandcode/") { return true }
        if lower.contains("/.continue/") { return true }
        if lower.contains("/.factory/") { return true }
        if lower.contains("/.gemini/") && lower.contains("/chats/") { return true }
        return false
    }

    package static func latestTranscriptUserPrompt(_ text: String) -> String? {
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
    package static let maxPlanSteps = 8
    package static let maxPlanStepLength = 100
    package static let maxSelfReportLength = 160

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
    package static func applyTranscriptSelfReport(_ facts: inout [Fact], text: String) {
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
    package static func planFacts(
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
    package static func selfReportLine(_ raw: String) -> String {
        for line in ContentSanitizer.redact(raw).split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            return clean(trimmed, limit: maxSelfReportLength)
        }
        return ""
    }

    package static func transcriptUserPrompt(from dict: [String: Any]) -> String {
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
    package static func userMessageText(_ value: Any?) -> String {
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

    package static func isToolEnvelope(_ dict: [String: Any]) -> Bool {
        let kind = firstString(dict, keys: ["type"]).lowercased().replacingOccurrences(of: "-", with: "_")
        let tools: Set<String> = [
            "tool_result", "tool_call_output", "custom_tool_call_output",
            "function_call_output", "function_response", "mcp_tool_call_end",
            "tool_use", "tool_call", "function_call", "custom_tool_call",
            "mcp_tool_call", "functioncall",
        ]
        return tools.contains(kind)
    }

    package static func isToolShapedRecord(_ dict: [String: Any]) -> Bool {
        if isToolEnvelope(dict) { return true }
        let kind = firstString(dict, keys: ["type"]).lowercased().replacingOccurrences(of: "-", with: "_")
        return kind == "file_read" || kind == "tool_use" || kind == "tool_call"
    }

    package static func cwdKeys(for dict: [String: Any]) -> [String] {
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

    package static func walk(
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

    package static func fact(
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

    package static func textFacts(_ text: String, structured: Bool, path: String) -> Fact? {
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

    package static func merge(_ input: [Fact]) -> [Fact] {
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

    package static func merge(_ target: inout Fact, _ source: Fact) {
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
    package static func mergeDigestFacts(_ target: inout Fact, _ source: Fact) {
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
    package static func preferTask(_ target: inout Fact, _ source: Fact) {
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
    package static func effectiveOrigin(_ task: String, _ origin: TaskOrigin) -> TaskOrigin {
        if task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .none }
        if isChromeTask(task) || TitleHeuristics.looksLikeFilenameOnlyTitle(task) { return .chrome }
        return origin == .none ? .cacheTitle : origin
    }

    /// The collector's view of the one chrome vocabulary. 0.98 collapsed the
    /// two copies that lived in this file; 0.99 folded in the third, which was
    /// inside `AgentRow.usefulTask`, so the definition now lives beside the row
    /// that renders it.
    package static func isChromeTask(_ value: String) -> Bool {
        TitleHeuristics.isChromeTitle(value)
    }

    /// Cline/Roo/Cascade (+ kin) ask tool ids — exact tokens only, never free-text inference.
    package static func isVendorAskTool(_ tool: String) -> Bool {
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
    package static func vendorAskAlreadyAnswered(_ dict: [String: Any]) -> Bool {
        guard let raw = firstValue(dict, keys: ["askResponse", "ask_response"]) else { return false }
        if let flag = raw as? Bool { return flag }
        let text = stringValue(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty
    }

    package static func isTerminalSessionState(_ value: String) -> Bool {
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

    package static func vendorAskFieldPending(_ dict: [String: Any]) -> Bool {
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

    /// Tool `input.path` is a file, not a workspace. Adopting it as cwd made
    /// Claude (and kin) rows look like they lived in `/tmp/file-0.swift`.
    package static func looksLikeFilePathCwd(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        return TitleHeuristics.looksLikeFilenameOnlyTitle(lastPathComponent(path))
    }

    package static func makeRows(from facts: [Fact], id: AgentID, home: URL) -> [ActivityHarvest.Row] {
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
