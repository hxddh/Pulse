import Foundation

/// What one vendor hook event means to Pulse.
enum HookAction: Equatable {
    /// A session began (or resumed).
    case start
    /// The user submitted a prompt: working, and nothing is owed any more.
    case prompt
    /// The agent is working (a tool ran, a reply streamed): a `tool` line.
    case activity
    /// The agent cannot continue until the user acts.
    case blocked(AttentionKind)
    /// The turn is over: your turn.
    case turn
    /// The turn ended on an error (an API error, an unrecoverable failure):
    /// your turn, and the error's text is the session's last error.
    case failedTurn
    /// The agent has sat at its prompt a while (Claude's `idle_prompt`):
    /// your turn only if the turn's end was not seen (`AttentionKind.idle`).
    case idle
    /// The block was answered in the vendor's own prompt.
    case resolved
    /// The session ended.
    case end
    /// A known event that says nothing Pulse shows.
    case ignore
}

/// One event read by an agent's adapter: the action and, for a block, what
/// is being asked.
struct HookReading: Equatable {
    var action: HookAction
    var ask: String = ""
}

/// Native receiver for every supported agent's hook, plugin or extension,
/// and for the public Attention bridge (`pulse-hook` / `PulseBar --hook`).
///
/// `pulse-hook <agent> <event>` with the vendor's JSON payload on stdin (or,
/// for the two modules, as the last argument). Each
/// agent's adapter maps its own event names and payload onto a
/// `HookAction`; anything else falls back to the protocol vocabulary
/// (`permission`, `turn`, `done`, …). Writes one v5 line to the event log
/// (`EventLog` — the only file it writes) and exits 0 at once.
/// Unknown events soft-fail (exit 0, no write), and a blocked event from an
/// agent whose hooks cannot report one (`waiting: .none`) is refused — no
/// fake Waiting. Nothing is ever held: the vendor's own prompt is always in
/// charge.
enum PulseHookReceiver {
    /// Always returns 0 — vendor hooks must never be broken by Pulse.
    ///
    /// `logURL` nil writes the real event log; a test passes a temporary one
    /// (never a global override — suites run in parallel). `locate` finds
    /// the agent's pid and the landing handles; tests pass a fixed answer.
    @discardableResult
    static func run(
        arguments: [String],
        stdin: String = "",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logURL: URL? = nil,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        locate: (AgentID, [String: String]) -> (pid: Int32, landing: String) = HookLanding.current
    ) -> Int32 {
        let args = Array(arguments.drop(while: { $0 != "--hook" }).dropFirst())
        let agentRaw = (args.first ?? "claude").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let agent = attributedAgent(agentRaw, environment: environment) else {
            DebugLog.write("attention reject agent=\(agentRaw)")
            return 0
        }
        let eventArg = args.count > 1 && !args[1].hasPrefix("{") ? args[1] : ""
        var payload = parsePayload(stdin: stdin, trailingArg: args.count > 1 ? args.last : nil)
        if let msg = payload["msg"] as? [String: Any], payload["type"] == nil {
            payload.merge(msg) { current, _ in current }
        }
        guard let reading = interpret(agent: agent, event: eventArg, payload: payload) else {
            DebugLog.write("attention reject event=\(eventArg) agent=\(agent.rawValue)")
            return 0
        }
        // No fake Waiting: an agent whose hooks cannot say it is blocked is
        // never shown blocked, whoever writes the line.
        if case .blocked = reading.action, agent.waitingSource == .none {
            DebugLog.write("attention reject blocked agent=\(agent.rawValue) waiting=none")
            return 0
        }
        guard let line = record(agent: agent, reading: reading, payload: payload, nowMs: nowMs) else { return 0 }
        // Was the prompt's own window in front as this was raised? A turn
        // the user watched finish is not owed to them, and a blocked prompt
        // already on screen needs no banner.
        var written = line
        if let kind = AttentionProtocol.kind(line.kind), kind.isOpen {
            written.front = PromptVisibility.promptIsFrontmost()
        }
        let located = locate(agent, environment)
        written.pid = located.pid > 1 ? located.pid : 0
        written.landing = cleanField(located.landing, limit: 240)
        EventLog.append(written.line, at: logURL, nowMs: nowMs)
        return 0
    }

    /// The v5 line one reading becomes, before the hook's own facts (front,
    /// pid, landing) are added — nil when it writes nothing. Pure.
    static func record(agent: AgentID, reading: HookReading, payload: [String: Any], nowMs: Int64) -> AttentionRecord? {
        let context = HookContext(payload: payload)
        let tool = cleanField(string(payload, keys: ["tool_name", "toolName"]), limit: 64)
        let kind: AttentionKind
        var message = ""
        var toolColumn = ""
        switch reading.action {
        case .ignore:
            return nil
        case .activity:
            // A tool with no session cannot be matched to anything, and
            // would make a row of its own.
            guard !context.session.isEmpty else { return nil }
            kind = .tool
            toolColumn = tool
            let descriptor = toolDescriptor(from: payload)
            if !tool.isEmpty, descriptor.hasPrefix(tool + ": ") {
                message = String(descriptor.dropFirst(tool.count + 2))
            }
        case .prompt:
            // Session-scoped only: an agent-wide clear from one terminal
            // must not clear another's.
            guard !context.session.isEmpty else { return nil }
            kind = .working
            // What the person typed: the session's title and latest prompt.
            message = TitleHeuristics.promptTitle(string(payload, keys: ["prompt"]), limit: 200)
        case .start:
            kind = .start
        case .blocked(let blocked):
            kind = blocked.isBlocking ? blocked : .waiting
            message = reading.ask.isEmpty ? genericMessage(from: payload, blocked: true) : reading.ask
            toolColumn = tool
        case .turn:
            kind = .turn
            message = genericMessage(from: payload)
        case .failedTurn:
            kind = .turn
            toolColumn = AttentionRecord.errorTool
            message = errorMessage(from: payload)
        case .idle:
            kind = .idle
        case .resolved:
            kind = .done
        case .end:
            kind = .end
        }
        return AttentionRecord(
            agent: cleanField(agent.rawValue, limit: 48),
            kind: kind.rawValue,
            ms: nowMs,
            message: cleanField(message, limit: 200),
            session: cleanField(context.session, limit: 80),
            cwd: cleanField(context.cwd, limit: 240),
            tool: toolColumn
        )
    }

    // MARK: - Adapters

    /// The event an agent's hook reported: the argument the installed command
    /// carries, else what the payload names (an entry that names no event).
    static func eventName(_ event: String, payload: [String: Any]) -> String {
        let trimmed = event.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return string(payload, keys: ["hook_event_name", "hookEventName", "type", "event"])
    }

    /// One agent's event, read. `nil` means the adapter does not know it and
    /// the protocol vocabulary is tried instead.
    static func interpret(agent: AgentID, event: String, payload: [String: Any]) -> HookReading? {
        let name = eventName(event, payload: payload)
        let vendor: HookReading?
        switch agent {
        case .claude: vendor = readClaude(name, payload)
        case .codex: vendor = readCodex(name, payload)
        case .gemini: vendor = readGemini(name, payload)
        case .copilot: vendor = readCopilot(name, payload)
        case .opencode: vendor = readOpenCode(name, payload)
        case .cursor: vendor = readCursor(name, payload)
        case .pi: vendor = readPi(name, payload)
        }
        if let vendor { return vendor }
        return readBridge(name)
    }

    /// The protocol's own words, for bridges that write a kind, not a vendor
    /// event. Unknown and empty words are rejected — never Waiting.
    static func readBridge(_ word: String) -> HookReading? {
        let plain = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let kind = AttentionProtocol.kind(plain) else { return nil }
        switch kind {
        case .permission, .question, .waiting: return HookReading(action: .blocked(kind))
        case .turn: return HookReading(action: .turn)
        case .idle: return HookReading(action: .idle)
        case .done: return HookReading(action: .resolved)
        case .start: return HookReading(action: .start)
        case .working: return HookReading(action: .prompt)
        case .end: return HookReading(action: .end)
        case .tool: return HookReading(action: .activity)
        }
    }

    /// Claude Code (code.claude.com/docs/en/hooks). Every entry is async.
    static func readClaude(_ event: String, _ payload: [String: Any]) -> HookReading? {
        switch event {
        case "SessionStart": return HookReading(action: .start)
        case "SessionEnd": return HookReading(action: .end)
        case "UserPromptSubmit": return HookReading(action: .prompt)
        case "PostToolUse", "PostToolUseFailure": return HookReading(action: .activity)
        case "PermissionRequest":
            // AskUserQuestion comes through PermissionRequest; it is a
            // question — no allow/deny answers it.
            let tool = string(payload, keys: ["tool_name", "toolName"])
            let kind: AttentionKind = tool == "AskUserQuestion" ? .question : .permission
            return HookReading(action: .blocked(kind), ask: claudeAsk(payload))
        case "Notification":
            let ask = string(payload, keys: ["message", "title"])
            switch string(payload, keys: ["notification_type", "notificationType"]) {
            case "permission_prompt": return HookReading(action: .blocked(.permission), ask: ask)
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                return HookReading(action: .blocked(.question), ask: ask)
            // About a minute after a turn, and again after the person saw
            // it: never a turn of its own (`AttentionKind.idle`).
            case "idle_prompt": return HookReading(action: .idle)
            case "elicitation_complete", "elicitation_response": return HookReading(action: .resolved)
            // A Notification that does not say it is a block is not one.
            default: return HookReading(action: .ignore)
            }
        case "Stop": return HookReading(action: .turn)
        // The turn ended on an API error (rate limit, auth, overload).
        case "StopFailure": return HookReading(action: .failedTurn)
        default: return nil
        }
    }

    /// Codex hooks.json (openai/codex codex-rs/hooks). Never blocked: its
    /// PermissionRequest fires before its own auto-review, and is not
    /// installed.
    static func readCodex(_ event: String, _ payload: [String: Any]) -> HookReading? {
        switch event {
        case "SessionStart": return HookReading(action: .start)
        case "SessionEnd": return HookReading(action: .end)
        case "UserPromptSubmit": return HookReading(action: .prompt)
        case "PostToolUse": return HookReading(action: .activity)
        case "Stop": return HookReading(action: .turn)
        default: return nil
        }
    }

    /// Gemini CLI (google-gemini/gemini-cli docs/hooks/reference.md).
    static func readGemini(_ event: String, _ payload: [String: Any]) -> HookReading? {
        switch event {
        case "SessionStart": return HookReading(action: .start)
        case "SessionEnd": return HookReading(action: .end)
        case "BeforeAgent": return HookReading(action: .prompt)
        case "AfterTool": return HookReading(action: .activity)
        case "AfterAgent": return HookReading(action: .turn)
        case "Notification":
            guard string(payload, keys: ["notification_type"]) == "ToolPermission" else {
                return HookReading(action: .ignore)
            }
            return HookReading(action: .blocked(.permission), ask: geminiAsk(payload))
        default: return nil
        }
    }

    /// Copilot CLI (github/docs copilot hooks reference). Both the camelCase
    /// names Pulse installs and the VS Code–compatible PascalCase ones.
    static func readCopilot(_ event: String, _ payload: [String: Any]) -> HookReading? {
        switch event {
        case "sessionStart", "SessionStart": return HookReading(action: .start)
        case "sessionEnd", "SessionEnd": return HookReading(action: .end)
        case "userPromptSubmitted", "UserPromptSubmit": return HookReading(action: .prompt)
        case "postToolUse", "PostToolUse", "postToolUseFailure", "PostToolUseFailure":
            return HookReading(action: .activity)
        case "agentStop", "Stop": return HookReading(action: .turn)
        case "errorOccurred", "ErrorOccurred":
            // An unrecoverable error ends the turn; a recoverable one is work.
            let recoverable = payload["recoverable"] as? Bool ?? true
            return HookReading(action: recoverable ? .activity : .failedTurn)
        case "notification", "Notification":
            let ask = string(payload, keys: ["message", "title"])
            switch string(payload, keys: ["notification_type", "notificationType"]) {
            case "permission_prompt": return HookReading(action: .blocked(.permission), ask: ask)
            case "elicitation_dialog": return HookReading(action: .blocked(.question), ask: ask)
            // agent_idle / agent_completed are background subagents, not
            // the session's own turn; shell completions are not either.
            default: return HookReading(action: .ignore)
            }
        default: return nil
        }
    }

    /// OpenCode plugin events (anomalyco/opencode SDK v2 `Event`), forwarded
    /// by Pulse's plugin with the event's properties as the payload.
    static func readOpenCode(_ event: String, _ payload: [String: Any]) -> HookReading? {
        switch event {
        case "session.created": return HookReading(action: .start)
        case "session.status":
            let status = (payload["status"] as? [String: Any]).map { string($0, keys: ["type"]) }
                ?? string(payload, keys: ["status"])
            return HookReading(action: status == "busy" || status == "retry" ? .activity : .ignore)
        case "session.idle": return HookReading(action: .turn)
        case "session.error": return HookReading(action: .failedTurn)
        case "session.deleted": return HookReading(action: .end)
        case "permission.asked": return HookReading(action: .blocked(.permission), ask: openCodePermissionAsk(payload))
        case "question.asked": return HookReading(action: .blocked(.question), ask: openCodeQuestionAsk(payload))
        case "permission.replied", "question.replied", "question.rejected":
            return HookReading(action: .resolved)
        default: return nil
        }
    }

    /// Cursor hooks.json — observe-only events. None names a tool, so a
    /// Cursor row has no steps.
    static func readCursor(_ event: String, _ payload: [String: Any]) -> HookReading? {
        switch event {
        case "sessionStart": return HookReading(action: .start)
        case "sessionEnd": return HookReading(action: .end)
        case "afterAgentResponse": return HookReading(action: .activity)
        case "stop": return HookReading(action: .turn)
        default: return nil
        }
    }

    /// Pi extension events (badlogic/pi-mono coding-agent extensions/types.ts),
    /// forwarded by Pulse's extension — a tool's name and a short summary of
    /// its arguments ride along (`tool_name`, `tool_input`).
    static func readPi(_ event: String, _ payload: [String: Any]) -> HookReading? {
        switch event {
        case "session_start": return HookReading(action: .start)
        case "session_shutdown": return HookReading(action: .end)
        case "agent_start": return HookReading(action: .prompt)
        case "tool_execution_end": return HookReading(action: .activity)
        case "agent_settled": return HookReading(action: .turn)
        case "ui_prompt_start":
            let kind: AttentionKind = string(payload, keys: ["kind"]) == "confirm" ? .permission : .question
            return HookReading(action: .blocked(kind), ask: string(payload, keys: ["title", "message"]))
        case "ui_prompt_end": return HookReading(action: .resolved)
        default: return nil
        }
    }

    // MARK: - Asks

    /// What a Claude `PermissionRequest` asks: the question itself for
    /// `AskUserQuestion` (`tool_input.questions[0].question`), the plan's
    /// first line for `ExitPlanMode` (`tool_input.plan`), else the tool
    /// call (`toolDescriptor`).
    static func claudeAsk(_ payload: [String: Any]) -> String {
        let tool = string(payload, keys: ["tool_name", "toolName"])
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        switch tool {
        case "AskUserQuestion":
            if let questions = input["questions"] as? [[String: Any]], let first = questions.first {
                let text = string(first, keys: ["question", "header"])
                if !text.isEmpty { return condenseOneLine(text) }
            }
            let single = string(input, keys: ["question"])
            if !single.isEmpty { return condenseOneLine(single) }
        case "ExitPlanMode":
            let summary = planSummary(string(input, keys: ["plan"]))
            if !summary.isEmpty { return summary }
        default:
            break
        }
        return toolDescriptor(from: payload)
    }

    /// A plan's first line with words, without its Markdown marks.
    static func planSummary(_ plan: String) -> String {
        let marks = CharacterSet(charactersIn: "#*->`_ \t")
        for line in plan.split(whereSeparator: \.isNewline) {
            let text = String(line).trimmingCharacters(in: marks)
            if !text.isEmpty { return condenseOneLine(text) }
        }
        return ""
    }

    static func geminiAsk(_ payload: [String: Any]) -> String {
        let message = string(payload, keys: ["message"])
        if !message.isEmpty { return condenseOneLine(message) }
        guard let details = payload["details"] as? [String: Any] else { return "" }
        return condenseOneLine(string(details, keys: ["title", "command", "tool_name", "toolName", "file_path", "filePath"]))
    }

    static func openCodePermissionAsk(_ payload: [String: Any]) -> String {
        let title = string(payload, keys: ["title"])
        if !title.isEmpty { return condenseOneLine(title) }
        let permission = string(payload, keys: ["permission", "type"])
        let patterns = (payload["patterns"] as? [Any] ?? payload["pattern"] as? [Any] ?? [])
            .compactMap { $0 as? String }
        let single = string(payload, keys: ["pattern"])
        let target = patterns.isEmpty ? single : patterns.joined(separator: " ")
        if permission.isEmpty { return condenseOneLine(target) }
        return condenseOneLine(target.isEmpty ? permission : "\(permission): \(target)")
    }

    static func openCodeQuestionAsk(_ payload: [String: Any]) -> String {
        let questions = payload["questions"] as? [[String: Any]] ?? []
        if let first = questions.first {
            return condenseOneLine(string(first, keys: ["question", "header"]))
        }
        return condenseOneLine(string(payload, keys: ["question", "title"]))
    }

    // MARK: - stdin

    /// Whether the payload already came in argv (the OpenCode plugin and the
    /// Pi extension pass their JSON as the last argument) — then stdin is not
    /// read at all.
    static func payloadInArguments(_ arguments: [String]) -> Bool {
        arguments.drop(while: { $0 != "--hook" }).dropFirst().dropFirst().contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("{")
        }
    }

    /// The most a hook payload may be; anything past it is not read.
    static let stdinLimit = 1 << 20

    /// Vendors pipe JSON on stdin, but a caller that leaves stdin open (a
    /// terminal, a wrapper that never closes the pipe) must not keep the hook
    /// — and the agent waiting on it — alive. Read on a background thread,
    /// wait at most `timeout`, keep at most `limit` bytes; whatever arrived
    /// by then is the payload. The reader thread is abandoned on a timeout:
    /// the process exits right after.
    static func readStdin(timeout: TimeInterval = 1, limit: Int = stdinLimit) -> String {
        let box = Guarded(Data())
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let got = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
                if got < 0, errno == EINTR { continue }
                if got <= 0 { break }
                let full = box.withValue { (data: inout Data) -> Bool in
                    data.append(contentsOf: buffer[0..<got])
                    if data.count > limit { data = data.prefix(limit) }
                    return data.count >= limit
                }
                if full { break }
            }
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + timeout)
        // Lossy: one invalid byte never loses the whole payload.
        return String(decoding: box.snapshot, as: UTF8.self)
    }

    // MARK: - Attribution

    /// The agent an invocation speaks for, or nil when it is none of the
    /// supported seven.
    ///
    /// xAI's Grok Build runs the hooks in `~/.claude/settings.json` by default
    /// and marks its own calls with `GROK_HOOK_EVENT` / `GROK_SESSION_ID`.
    /// Pulse does not support Grok, and its events must never land on a
    /// Claude row — so they are refused.
    static func attributedAgent(_ raw: String, environment: [String: String]) -> AgentID? {
        guard let agent = AgentCatalog.agent(named: raw) else { return nil }
        if agent == .claude,
           ["GROK_HOOK_EVENT", "GROK_SESSION_ID"].contains(where: { !(environment[$0] ?? "").isEmpty }) {
            return nil
        }
        return agent
    }

    // MARK: - Parse

    private static func parsePayload(stdin: String, trailingArg: String?) -> [String: Any] {
        let trimmed = stdin.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if let data = trimmed.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj
            }
            return ["message": trimmed]
        }
        if let trailingArg, trailingArg.hasPrefix("{"),
           let data = trailingArg.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        return [:]
    }

    /// What a turn or a block says, when its adapter found no specific ask.
    /// A block never takes `reason`: it is an event's why (Pi's
    /// `ui_prompt`, a shutdown's `exit`), not what is asked.
    static func genericMessage(from payload: [String: Any], blocked: Bool = false) -> String {
        let keys = ["last_assistant_message", "message", "prompt_response", "body"]
            + (blocked ? [] : ["reason"]) + ["title"]
        for key in keys {
            if let value = payload[key] as? String {
                let folded = condenseOneLine(value, limit: 200)
                if !folded.isEmpty { return folded }
            }
        }
        return toolDescriptor(from: payload)
    }

    /// What a failed turn said went wrong: Claude StopFailure's rendered
    /// error (`last_assistant_message`, else `error_details`, else its
    /// `error` type), Copilot's `error.message`, the OpenCode plugin's
    /// `error` — the hook's own words only.
    static func errorMessage(from payload: [String: Any]) -> String {
        var text = string(payload, keys: ["last_assistant_message", "error_details", "error", "message"])
        if text.isEmpty, let error = payload["error"] as? [String: Any] {
            text = string(error, keys: ["message", "name"])
            if text.isEmpty, let data = error["data"] as? [String: Any] { text = string(data, keys: ["message"]) }
        }
        return condenseOneLine(text, limit: 200)
    }

    /// What is actually being asked, when the vendor sends no prose.
    ///
    /// Claude's `PermissionRequest` payload has **no** `message` field — the
    /// ask *is* the tool call (`tool_name` + `tool_input`). Field priority
    /// mirrors the vendor's own permission label (`command` → `file_path` →
    /// `url`). Copilot sends `toolArgs` as a JSON string; it is read as the
    /// object it encodes. Everything here still passes through `cleanField`,
    /// which redacts credentials and bounds the field.
    static func toolDescriptor(from payload: [String: Any]) -> String {
        let tool = string(payload, keys: ["tool_name", "toolName"])
        guard !tool.isEmpty else { return "" }
        guard let input = toolInput(payload) else { return tool }
        for key in ["command", "file_path", "url", "path", "notebook_path", "pattern", "query"] {
            guard let raw = input[key] as? String else { continue }
            let target = condenseOneLine(raw)
            guard !target.isEmpty else { continue }
            return "\(tool): \(target)"
        }
        return tool
    }

    /// A tool call's arguments: `tool_input` / `toolArgs` as an object, or
    /// `toolArgs` as a JSON string holding one (Copilot).
    static func toolInput(_ payload: [String: Any]) -> [String: Any]? {
        if let input = payload["tool_input"] as? [String: Any] { return input }
        if let input = payload["toolArgs"] as? [String: Any] { return input }
        guard let raw = payload["toolArgs"] as? String,
              raw.trimmingCharacters(in: .whitespaces).hasPrefix("{"),
              let data = raw.data(using: .utf8)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A banner, a tray row and a TSV field are all single-line: fold every
    /// run of whitespace and bound the result before it ever reaches them.
    static func condenseOneLine(_ raw: String, limit: Int = 140) -> String {
        let folded = raw.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard folded.count > limit else { return folded }
        return String(folded.prefix(limit - 1)) + "…"
    }

    static func string(_ payload: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = payload[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return ""
    }

    /// One field of a v5 line: credentials redacted, every tab and line
    /// break — `\n`, `\r`, VT, FF, NEL, U+2028, U+2029 — a space
    /// (`AttentionProtocol.flatten`), bounded.
    static func cleanField(_ value: String, limit: Int) -> String {
        let flat = AttentionProtocol.flatten(ContentSanitizer.redact(value))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(flat.prefix(limit))
    }
}

/// The identity fields every vendor's payload spells its own way.
struct HookContext: Equatable {
    var session: String
    var cwd: String
    /// The vendor's transcript path, when its payload names one — used only
    /// to name a session that has no id; never written, never read.
    var transcript: String

    init(payload: [String: Any]) {
        session = String(PulseHookReceiver.string(payload, keys: [
            "session_id", "sessionId", "sessionID", "thread_id", "threadId",
            "conversation_id", "conversationId",
        ]).prefix(80))
        transcript = PulseHookReceiver.string(payload, keys: [
            "transcript_path", "transcriptPath", "session_file", "sessionFile", "rollout_path",
        ])
        var dir = PulseHookReceiver.string(payload, keys: ["cwd", "directory", "workdir", "working_directory", "workspace_root"])
        if dir.isEmpty, let roots = payload["workspace_roots"] as? [Any],
           let first = roots.compactMap({ $0 as? String }).first {
            dir = first
        }
        cwd = dir.hasPrefix("/") ? String(dir.prefix(240)) : ""
        // A session named only by its transcript file (a vendor that sends
        // no id): the file's own name. The file itself is never read.
        if session.isEmpty, !transcript.isEmpty {
            var name = URL(fileURLWithPath: transcript).lastPathComponent
            if name.hasSuffix(".jsonl") { name = String(name.dropLast(".jsonl".count)) }
            session = String(name.prefix(80))
        }
    }
}
