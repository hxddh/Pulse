import Foundation

/// Native attention receiver for Claude/Codex hooks and the public Attention
/// bridge (`pulse-hook` / `PulseBar --hook`).
///
/// Writes one attention line (or one activity event) and exits 0 at once.
/// Unknown kinds soft-fail (exit 0, no write) so vendor agents are never
/// stalled by accident. Since 23.0 nothing is ever held: the vendor's own
/// prompt is always in charge.
enum PulseHookReceiver {
    /// Always returns 0 — vendor hooks must never be broken by Pulse.
    @discardableResult
    static func run(
        arguments: [String],
        stdin: String = "",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int32 {
        let args = Array(arguments.drop(while: { $0 != "--hook" }).dropFirst())
        let agentRaw = attributedAgent(
            (args.first ?? "claude").lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
            environment: environment
        )
        let kindArg = args.count > 1 ? args[1] : ""
        var payload = parsePayload(stdin: stdin, trailingArg: args.count > 1 ? args.last : nil, kindArg: kindArg)
        if let msg = payload["msg"] as? [String: Any], payload["type"] == nil {
            payload.merge(msg) { current, _ in current }
        }
        let kindSource: String = {
            if !kindArg.isEmpty, !kindArg.hasPrefix("{") { return kindArg }
            return parseKind(from: payload)
        }()
        // Activity events branch off before the attention pipeline entirely:
        // state for the tray's "now", not a wait. Write one small
        // file and leave.
        let plain = kindSource.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if plain == "activity" || plain == "prompt" {
            writeActivity(agent: agentRaw, kind: plain, payload: payload)
            // 16.0: a prompt the user just submitted answers "your turn" —
            // and anything else this session owed. Session-scoped only: an
            // agent-wide clear from one terminal must not clear another's.
            let session = session(from: payload)
            if plain == "prompt", !session.isEmpty {
                _ = appendEvent(
                    agent: agentRaw, kind: AttentionKind.done.rawValue, message: "",
                    session: session, cwd: cwd(from: payload)
                )
            }
            return 0
        }
        var kind = AttentionProtocol.normalizeKind(kindSource.isEmpty ? "waiting" : kindSource)
        // 18.0: Claude routes AskUserQuestion through PermissionRequest. It
        // is a question, not a permission: there is no allow/deny that
        // answers it.
        if kind == AttentionKind.permission.rawValue,
           string(payload, keys: ["tool_name", "toolName"]) == "AskUserQuestion" {
            kind = AttentionKind.question.rawValue
        }
        guard AttentionProtocol.acceptsWrite(kind: kind) else {
            DebugLog.write("attention reject unknown kind=\(kind) agent=\(agentRaw)")
            return 0
        }
        let message = message(from: payload)
        let session = session(from: payload)
        let cwd = cwd(from: payload)
        // 16.0: was the prompt's own window in front as this was raised? A
        // turn the user watched finish is not owed to them, and a blocked
        // prompt already on screen needs no banner.
        let front: Bool? = {
            guard AttentionProtocol.kind(kind)?.isOpen == true else { return nil }
            return PromptVisibility.promptIsFrontmost()
        }()
        _ = appendEvent(
            agent: agentRaw, kind: kind, message: message, session: session, cwd: cwd, front: front
        )
        return 0
    }

    /// In-process helper. Rejects unknown kinds the same way as `run`.
    @discardableResult
    static func appendEvent(
        agent: String,
        kind: String,
        message: String,
        session: String = "",
        cwd: String = "",
        front: Bool? = nil,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> Bool {
        let normalized = AttentionProtocol.normalizeKind(kind)
        guard AttentionProtocol.acceptsWrite(kind: normalized) else { return false }
        let line = [
            cleanField(agent, limit: 48),
            cleanField(normalized, limit: 64),
            String(nowMs),
            cleanField(message, limit: 200),
            cleanField(session, limit: 80),
            cleanField(cwd, limit: 240),
            // Column 7 (host) is always empty since 23.0; readers ignore it.
            "",
            // v3 column 8.
            AttentionProtocol.frontField(front),
        ].joined(separator: "\t")
        AttentionIO.appendRawLine(line)
        return true
    }

    // MARK: - Activity events (2.9)

    /// One state file per session, latest event wins. No identity, no file:
    /// a session-less event cannot be matched to a row, and a guessed
    /// filename would collide across sessions.
    static func writeActivity(
        agent: String,
        kind: String,
        payload: [String: Any],
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        let session = session(from: payload)
        guard !session.isEmpty else { return }
        let tool = cleanField(
            (payload["tool_name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            limit: 64
        )
        let descriptor = toolDescriptor(from: payload)
        var target = ""
        if !tool.isEmpty, descriptor.hasPrefix(tool + ": ") {
            target = cleanField(String(descriptor.dropFirst(tool.count + 2)), limit: 160)
        }
        var prompt = ""
        if kind == "prompt" {
            prompt = cleanField(
                condenseOneLine(payload["prompt"] as? String ?? "", limit: 160),
                limit: 160
            )
        }
        _ = ActivitySpool.write(ActivitySpool.Event(
            agent: agent,
            session: session,
            event: kind == "activity" ? "tool" : "prompt",
            tool: tool,
            target: target,
            prompt: prompt,
            cwd: cwd(from: payload),
            tsMs: nowMs
        ))
    }

    // MARK: - Attribution

    /// 20.0: xAI's Grok Build runs the hooks in `~/.claude/settings.json`
    /// by default (xai-org/grok-build xai-grok-hooks discovery.rs, compat.rs)
    /// and marks its own calls with `GROK_HOOK_EVENT` / `GROK_SESSION_ID`
    /// (runner/command.rs). Without this its permission prompts and finished
    /// turns landed on Claude's rows — a red lamp on the wrong agent, or a
    /// Claude row that was never there.
    static func attributedAgent(_ agent: String, environment: [String: String]) -> String {
        guard agent == "claude" else { return agent }
        let grok = ["GROK_HOOK_EVENT", "GROK_SESSION_ID"].contains {
            !(environment[$0] ?? "").isEmpty
        }
        return grok ? "grok" : agent
    }

    // MARK: - Parse

    private static func parsePayload(stdin: String, trailingArg: String?, kindArg: String) -> [String: Any] {
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

    static func parseKind(from payload: [String: Any]) -> String {
        let ntype = string(payload, keys: ["notification_type", "notificationType"])
        if !ntype.isEmpty { return ntype }
        let event = string(payload, keys: ["hook_event_name", "hookEventName"])
        switch event {
        // 16.0: a turn ending is "your turn"; a subagent ending is only
        // lifecycle — it used to share `stop` with the parent.
        case "Stop": return "turn"
        case "StopFailure": return "stop_failure"
        case "SubagentStop": return "subagent_stop"
        case "Notification":
            // 20.0: a Notification that does not say what it is about is
            // not evidence of a block. Factory Droid fires one after 60 s
            // of an idle prompt, some builds without `notification_type`;
            // reading that as `waiting` lit a fake red lamp.
            let nested = string(payload, keys: ["notification_type", "notificationType"])
            return nested.isEmpty ? "notification" : nested
        case "PermissionRequest": return "permission"
        // 2.9 activity events — never attention; they branch
        // off in `run` before the attention pipeline.
        case "PreToolUse": return "activity"
        case "UserPromptSubmit": return "prompt"
        default:
            // 20.0: any other named vendor event is that event, not a wait.
            // Bridged agents spell theirs `stop`, `agentStop`, `preToolUse`…;
            // the known aliases normalise (`stop` → your turn) and the rest
            // are rejected as unknown kinds instead of falling through to red.
            if !event.isEmpty { return event }
        }
        let t = string(payload, keys: ["type", "event", "method"])
        return t.isEmpty ? "waiting" : t
    }

    /// Compatibility alias — prefer `AttentionProtocol.normalizeKind`.
    static func normalizeKind(_ kind: String) -> String {
        AttentionProtocol.normalizeKind(kind)
    }

    private static func message(from payload: [String: Any]) -> String {
        for key in ["last_assistant_message", "message", "body", "reason", "title", "content", "prompt"] {
            if let value = payload[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return String(trimmed.prefix(200)) }
            }
        }
        return toolDescriptor(from: payload)
    }

    /// What is actually being asked, when the vendor sends no prose.
    ///
    /// Claude's `PermissionRequest` payload has **no** `message` field — the
    /// ask *is* the tool call (`tool_name` + `tool_input`). Without this, the
    /// most important event in the product reached the banner, the row and
    /// Details with an empty reason, and all three degraded to the bare word
    /// "Permission": the lamp said someone was waiting but never what for.
    ///
    /// Field priority mirrors the vendor's own permission label
    /// (`command` → `file_path` → `url`), so Pulse names the same thing the
    /// dialog on the other machine names. Everything here still passes through
    /// `cleanField`, which redacts credentials and bounds the field.
    static func toolDescriptor(from payload: [String: Any]) -> String {
        let tool = (payload["tool_name"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tool.isEmpty else { return "" }
        guard let input = payload["tool_input"] as? [String: Any] else { return tool }
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

    private static func session(from payload: [String: Any]) -> String {
        for key in [
            "session_id", "sessionId", "thread_id", "threadId",
            "conversation_id", "conversationId",
        ] {
            if let value = payload[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return String(trimmed.prefix(80)) }
            }
        }
        for key in ["transcript_path", "transcriptPath", "rollout_path", "session_file"] {
            if let value = payload[key] as? String {
                var name = URL(fileURLWithPath: value).lastPathComponent
                if name.hasSuffix(".jsonl") {
                    name = String(name.dropLast(".jsonl".count))
                }
                if !name.isEmpty { return String(name.prefix(80)) }
            }
        }
        return ""
    }

    private static func cwd(from payload: [String: Any]) -> String {
        for key in ["cwd", "workdir", "working_directory", "workspace_root", "directory"] {
            if let value = payload[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("/") { return String(trimmed.prefix(240)) }
            }
        }
        return ""
    }

    private static func string(_ payload: [String: Any], keys: [String]) -> String {
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
