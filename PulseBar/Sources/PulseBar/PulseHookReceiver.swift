import Foundation

/// What one vendor hook event means to Pulse (24.0).
enum HookAction: Equatable {
    /// A session began (or resumed).
    case start
    /// The user submitted a prompt: working, and nothing is owed any more.
    case prompt
    /// The agent is working (a tool ran, a reply streamed): the activity
    /// spool only — never an attention line.
    case activity
    /// The agent cannot continue until the user acts.
    case blocked(AttentionKind)
    /// The turn is over: your turn.
    case turn
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

/// Native attention receiver for every supported agent's hook, plugin or
/// extension, and for the public Attention bridge (`pulse-hook` /
/// `PulseBar --hook`).
///
/// `pulse-hook <agent> <event>` with the vendor's JSON payload on stdin (or,
/// for Codex `notify`, as the last argument). Each agent's adapter maps its
/// own event names and payload onto a `HookAction`; anything else falls back
/// to the protocol vocabulary (`permission`, `turn`, `done`, …). Writes one
/// v4 attention line (or one activity event) and exits 0 at once. Unknown
/// events soft-fail (exit 0, no write), and a blocked event from an agent
/// whose hooks cannot report one (`waiting: .none`) is refused — no fake
/// Waiting. Nothing is ever held: the vendor's own prompt is always in charge.
enum PulseHookReceiver {
    /// Always returns 0 — vendor hooks must never be broken by Pulse.
    ///
    /// `attentionURL` nil writes the real attention file; the hook self-test
    /// passes a temporary one (never a global override — a scan may be
    /// reading at the same moment). `locate` finds the agent's pid and the
    /// landing handles; tests pass a fixed answer.
    @discardableResult
    static func run(
        arguments: [String],
        stdin: String = "",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        attentionURL: URL? = nil,
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
        let context = HookContext(payload: payload)
        switch reading.action {
        case .ignore:
            return 0
        case .activity:
            writeActivity(agent: agent.rawValue, kind: "activity", payload: payload, nowMs: nowMs)
            return 0
        case .prompt:
            writeActivity(agent: agent.rawValue, kind: "prompt", payload: payload, nowMs: nowMs)
            // Session-scoped only: an agent-wide clear from one terminal
            // must not clear another's.
            guard !context.session.isEmpty else { return 0 }
        case .start, .blocked, .turn, .idle, .resolved, .end:
            break
        }
        let kind: AttentionKind
        switch reading.action {
        case .start: kind = .start
        case .prompt: kind = .working
        case .blocked(let blocked): kind = blocked.isBlocking ? blocked : .waiting
        case .turn: kind = .turn
        case .idle: kind = .idle
        case .resolved: kind = .done
        case .end: kind = .end
        case .activity, .ignore: return 0
        }
        let message: String
        switch reading.action {
        case .blocked: message = reading.ask.isEmpty ? genericMessage(from: payload) : reading.ask
        case .turn: message = genericMessage(from: payload)
        default: message = ""
        }
        // Was the prompt's own window in front as this was raised? A turn
        // the user watched finish is not owed to them, and a blocked prompt
        // already on screen needs no banner.
        let front: Bool? = kind.isOpen ? PromptVisibility.promptIsFrontmost() : nil
        let located = locate(agent, environment)
        _ = appendEvent(
            agent: agent.rawValue,
            kind: kind.rawValue,
            message: message,
            session: context.session,
            cwd: context.cwd,
            front: front,
            pid: located.pid,
            transcript: context.transcript,
            landing: located.landing,
            nowMs: nowMs,
            attentionURL: attentionURL
        )
        return 0
    }

    // MARK: - Adapters

    /// The event an agent's hook reported: the argument the installed command
    /// carries, else what the payload names (a legacy `pulse-hook claude`
    /// entry, Codex `notify`).
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
        if plain == "activity" { return HookReading(action: .activity) }
        guard let kind = AttentionProtocol.kind(plain) else { return nil }
        switch kind {
        case .permission, .question, .waiting: return HookReading(action: .blocked(kind))
        case .turn: return HookReading(action: .turn)
        case .idle: return HookReading(action: .idle)
        case .done: return HookReading(action: .resolved)
        case .start: return HookReading(action: .start)
        case .working: return HookReading(action: .prompt)
        case .end: return HookReading(action: .end)
        case .subagentStart, .subagentStop: return HookReading(action: .ignore)
        }
    }

    /// Claude Code (code.claude.com/docs/en/hooks). Every entry is async.
    static func readClaude(_ event: String, _ payload: [String: Any]) -> HookReading? {
        switch event {
        case "SessionStart": return HookReading(action: .start)
        case "SessionEnd": return HookReading(action: .end)
        case "UserPromptSubmit": return HookReading(action: .prompt)
        case "PreToolUse", "PostToolUse", "PostToolUseFailure": return HookReading(action: .activity)
        case "PermissionRequest":
            // AskUserQuestion comes through PermissionRequest; it is a
            // question — no allow/deny answers it.
            let tool = string(payload, keys: ["tool_name", "toolName"])
            let kind: AttentionKind = tool == "AskUserQuestion" ? .question : .permission
            return HookReading(action: .blocked(kind), ask: toolDescriptor(from: payload))
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
        case "Stop", "StopFailure": return HookReading(action: .turn)
        case "SubagentStart", "SubagentStop": return HookReading(action: .ignore)
        default: return nil
        }
    }

    /// Codex hooks.json and `notify` (openai/codex codex-rs/hooks). Never
    /// blocked: its PermissionRequest fires before its own auto-review.
    static func readCodex(_ event: String, _ payload: [String: Any]) -> HookReading? {
        switch event {
        case "SessionStart": return HookReading(action: .start)
        case "SessionEnd": return HookReading(action: .end)
        case "UserPromptSubmit": return HookReading(action: .prompt)
        case "PostToolUse": return HookReading(action: .activity)
        case "Stop", "agent-turn-complete": return HookReading(action: .turn)
        case "PermissionRequest", "PreToolUse": return HookReading(action: .ignore)
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
            return HookReading(action: recoverable ? .activity : .turn)
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
        case "session.idle", "session.error": return HookReading(action: .turn)
        case "session.deleted": return HookReading(action: .end)
        case "permission.asked": return HookReading(action: .blocked(.permission), ask: openCodePermissionAsk(payload))
        case "question.asked": return HookReading(action: .blocked(.question), ask: openCodeQuestionAsk(payload))
        case "permission.replied", "question.replied", "question.rejected":
            return HookReading(action: .resolved)
        default: return nil
        }
    }

    /// Cursor hooks.json — observe-only events.
    static func readCursor(_ event: String, _ payload: [String: Any]) -> HookReading? {
        switch event {
        case "sessionStart": return HookReading(action: .start)
        case "sessionEnd": return HookReading(action: .end)
        case "afterAgentResponse", "afterAgentThought", "afterShellExecution", "afterFileEdit",
             "afterMCPExecution", "postToolUse":
            return HookReading(action: .activity)
        case "stop": return HookReading(action: .turn)
        default: return nil
        }
    }

    /// Pi extension events (badlogic/pi-mono coding-agent extensions/types.ts),
    /// forwarded by Pulse's extension.
    static func readPi(_ event: String, _ payload: [String: Any]) -> HookReading? {
        switch event {
        case "session_start": return HookReading(action: .start)
        case "session_shutdown": return HookReading(action: .end)
        case "agent_start": return HookReading(action: .prompt)
        case "tool_execution_start", "tool_execution_end", "turn_end": return HookReading(action: .activity)
        case "agent_settled": return HookReading(action: .turn)
        case "ui_prompt_start":
            let kind: AttentionKind = string(payload, keys: ["kind"]) == "confirm" ? .permission : .question
            return HookReading(action: .blocked(kind), ask: string(payload, keys: ["title", "message"]))
        case "ui_prompt_end": return HookReading(action: .resolved)
        default: return nil
        }
    }

    // MARK: - Asks

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

    // MARK: - Write

    /// In-process helper. Rejects unknown kinds the same way as `run`.
    @discardableResult
    static func appendEvent(
        agent: String,
        kind: String,
        message: String,
        session: String = "",
        cwd: String = "",
        front: Bool? = nil,
        pid: Int32 = 0,
        transcript: String = "",
        landing: String = "",
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        attentionURL: URL? = nil
    ) -> Bool {
        let normalized = AttentionProtocol.normalizeKind(kind)
        guard AttentionProtocol.acceptsWrite(kind: normalized) else { return false }
        let record = AttentionRecord(
            agent: cleanField(agent, limit: 48),
            kind: cleanField(normalized, limit: 64),
            ms: nowMs,
            message: cleanField(message, limit: 200),
            session: cleanField(session, limit: 80),
            cwd: cleanField(cwd, limit: 240),
            front: front,
            pid: max(0, pid),
            transcript: cleanField(transcript, limit: 400),
            landing: cleanField(landing, limit: 240)
        )
        AttentionIO.appendRawLine(record.line, at: attentionURL)
        return true
    }

    // MARK: - stdin

    /// Whether the payload already came in argv (Codex `notify` appends its
    /// JSON as the last argument) — then stdin is not read at all.
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
        return AttentionIO.decode(box.snapshot)
    }

    // MARK: - Activity events

    /// One state file per session, latest event wins. No identity, no file:
    /// a session-less event cannot be matched to a row, and a guessed
    /// filename would collide across sessions.
    static func writeActivity(
        agent: String,
        kind: String,
        payload: [String: Any],
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        let context = HookContext(payload: payload)
        guard !context.session.isEmpty else { return }
        let tool = cleanField(string(payload, keys: ["tool_name", "toolName"]), limit: 64)
        let descriptor = toolDescriptor(from: payload)
        var target = ""
        if !tool.isEmpty, descriptor.hasPrefix(tool + ": ") {
            target = cleanField(String(descriptor.dropFirst(tool.count + 2)), limit: 160)
        }
        var prompt = ""
        if kind == "prompt" {
            prompt = cleanField(
                condenseOneLine(string(payload, keys: ["prompt"]), limit: 160),
                limit: 160
            )
        }
        _ = ActivitySpool.write(ActivitySpool.Event(
            agent: agent,
            session: context.session,
            event: kind == "prompt" ? "prompt" : "tool",
            tool: tool,
            target: target,
            prompt: prompt,
            cwd: context.cwd,
            tsMs: nowMs
        ))
    }

    // MARK: - Attribution

    /// The agent an invocation speaks for, or nil when it is none of the
    /// supported seven.
    ///
    /// xAI's Grok Build runs the hooks in `~/.claude/settings.json` by default
    /// and marks its own calls with `GROK_HOOK_EVENT` / `GROK_SESSION_ID`.
    /// 24.0 does not support Grok, and its events must never land on a
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
    static func genericMessage(from payload: [String: Any]) -> String {
        for key in ["last_assistant_message", "last-assistant-message", "message", "prompt_response", "body", "reason", "title"] {
            if let value = payload[key] as? String {
                let folded = condenseOneLine(value, limit: 200)
                if !folded.isEmpty { return folded }
            }
        }
        return toolDescriptor(from: payload)
    }

    /// What is actually being asked, when the vendor sends no prose.
    ///
    /// Claude's `PermissionRequest` payload has **no** `message` field — the
    /// ask *is* the tool call (`tool_name` + `tool_input`). Field priority
    /// mirrors the vendor's own permission label (`command` → `file_path` →
    /// `url`). Everything here still passes through `cleanField`, which
    /// redacts credentials and bounds the field.
    static func toolDescriptor(from payload: [String: Any]) -> String {
        let tool = string(payload, keys: ["tool_name", "toolName"])
        guard !tool.isEmpty else { return "" }
        let input = payload["tool_input"] as? [String: Any] ?? payload["toolArgs"] as? [String: Any]
        guard let input else { return tool }
        for key in ["command", "file_path", "url", "path", "notebook_path", "pattern", "query"] {
            guard let raw = input[key] as? String else { continue }
            let target = condenseOneLine(raw)
            guard !target.isEmpty else { continue }
            return "\(tool): \(target)"
        }
        return tool
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

    private static func cleanField(_ value: String, limit: Int) -> String {
        let redacted = ContentSanitizer.redact(value)
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(redacted.prefix(limit))
    }
}

/// The identity fields every vendor's payload spells its own way.
struct HookContext: Equatable {
    var session: String
    var cwd: String
    var transcript: String

    init(payload: [String: Any]) {
        session = String(PulseHookReceiver.string(payload, keys: [
            "session_id", "sessionId", "sessionID", "thread_id", "threadId",
            "thread-id", "conversation_id", "conversationId",
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
        // no id): the file's own name, as 23.0 did.
        if session.isEmpty, !transcript.isEmpty {
            var name = URL(fileURLWithPath: transcript).lastPathComponent
            if name.hasSuffix(".jsonl") { name = String(name.dropLast(".jsonl".count)) }
            session = String(name.prefix(80))
        }
    }
}
