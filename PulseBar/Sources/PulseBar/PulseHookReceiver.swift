import Foundation

/// Native Claude/Codex → attention.tsv receiver.
///
/// Parity with `src/pulse_hook.py`: same kind normalization, JSON field
/// extraction, flocked TSV append, and soft-fail exit. Invoked as
/// `PulseBar --hook <agent> [kind]` so Waiting never depends on optional Python.
enum PulseHookReceiver {
    /// Always returns 0 — vendor hooks must never block the agent.
    @discardableResult
    static func run(arguments: [String], stdin: String = "") -> Int32 {
        let args = Array(arguments.drop(while: { $0 != "--hook" }).dropFirst())
        let agentRaw = (args.first ?? "claude").lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let kindArg = args.count > 1 ? args[1] : ""
        var payload = parsePayload(stdin: stdin, trailingArg: args.count > 1 ? args.last : nil, kindArg: kindArg)
        if let msg = payload["msg"] as? [String: Any], payload["type"] == nil {
            payload.merge(msg) { current, _ in current }
        }
        let kindSource: String = {
            if !kindArg.isEmpty, !kindArg.hasPrefix("{") { return kindArg }
            return parseKind(from: payload)
        }()
        let kind = normalizeKind(kindSource.isEmpty ? "waiting" : kindSource)
        let message = message(from: payload)
        let session = session(from: payload)
        let cwd = cwd(from: payload)
        appendEvent(agent: agentRaw, kind: kind, message: message, session: session, cwd: cwd)
        return 0
    }

    /// In-process self-test helper (no Process, no Python).
    static func appendEvent(
        agent: String,
        kind: String,
        message: String,
        session: String = "",
        cwd: String = "",
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        let line = [
            cleanField(agent, limit: 48),
            cleanField(kind, limit: 64),
            String(nowMs),
            cleanField(message, limit: 200),
            cleanField(session, limit: 80),
            cleanField(cwd, limit: 240),
        ].joined(separator: "\t")
        AttentionIO.appendRawLine(line)
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
        if let ntype = string(payload, keys: ["notification_type", "notificationType"]), !ntype.isEmpty {
            return ntype
        }
        let event = string(payload, keys: ["hook_event_name", "hookEventName"])
        switch event {
        case "Stop", "SubagentStop": return "stop"
        case "Notification":
            return string(payload, keys: ["notification_type", "notificationType"]).isEmpty
                ? "waiting"
                : string(payload, keys: ["notification_type", "notificationType"])
        case "PermissionRequest": return "permission"
        default: break
        }
        let t = string(payload, keys: ["type", "event", "method"])
        return t.isEmpty ? "waiting" : t
    }

    static func normalizeKind(_ kind: String) -> String {
        let k = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = k.lowercased().replacingOccurrences(of: "-", with: "_")
        let mapping: [String: String] = [
            "agent_turn_complete": "done",
            "agent-turn-complete": "done",
            "agent_completed": "done",
            "turn_complete": "done",
            "task_complete": "done",
            "exec_approval_request": "permission",
            "apply_patch_approval_request": "permission",
            "approval_request": "permission",
            "pending_approval": "permission",
            "request_user_input": "idle_prompt",
            "user_input_request": "idle_prompt",
            "elicitation_dialog": "idle_prompt",
            "permission_prompt": "permission",
            "idle_prompt": "idle_prompt",
            "agent_needs_input": "idle_prompt",
            "needs_input": "idle_prompt",
            "subagent_start": "subagent_start",
            "subagent_stop": "subagent_stop",
            "permission": "permission",
            "stop": "stop",
            "done": "done",
            "waiting": "waiting",
        ]
        if let mapped = mapping[low] { return mapped }
        if low.contains("approval"), !low.contains("response"), !low.contains("decision") {
            return "permission"
        }
        if low.contains("user_input"), !low.contains("response") {
            return "idle_prompt"
        }
        return k.isEmpty ? "waiting" : k
    }

    private static func message(from payload: [String: Any]) -> String {
        for key in ["last_assistant_message", "message", "body", "reason", "title", "content", "prompt"] {
            if let value = payload[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return String(trimmed.prefix(200)) }
            }
        }
        return ""
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
