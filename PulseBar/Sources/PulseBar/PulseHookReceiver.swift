import Foundation

/// Native attention receiver for Claude/Codex hooks and the public Attention
/// bridge (`pulse-hook` / `PulseBar --hook`).
///
/// Parity with `src/pulse_hook.py` plus Attention Protocol v1: unknown kinds
/// soft-fail (exit 0, no write) so vendor agents are never blocked.
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
        let kind = AttentionProtocol.normalizeKind(kindSource.isEmpty ? "waiting" : kindSource)
        guard AttentionProtocol.acceptsWrite(kind: kind) else {
            DebugLog.write("attention reject unknown kind=\(kind) agent=\(agentRaw)")
            return 0
        }
        let message = message(from: payload)
        let session = session(from: payload)
        let cwd = cwd(from: payload)
        _ = appendEvent(agent: agentRaw, kind: kind, message: message, session: session, cwd: cwd)
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
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> Bool {
        let normalized = AttentionProtocol.normalizeKind(kind)
        guard AttentionProtocol.acceptsWrite(kind: normalized) else { return false }
        // v2 column 7. A hook running on this Mac leaves it empty; a bridge on
        // another machine sets `PULSE_HOST` so its events keep their identity
        // once the file is synced here — otherwise the identity would rest on
        // the file name alone.
        let host = AttentionProtocol.normalizeHost(
            ProcessInfo.processInfo.environment["PULSE_HOST"] ?? ""
        )
        let line = [
            cleanField(agent, limit: 48),
            cleanField(normalized, limit: 64),
            String(nowMs),
            cleanField(message, limit: 200),
            cleanField(session, limit: 80),
            cleanField(cwd, limit: 240),
            cleanField(host, limit: 32),
        ].joined(separator: "\t")
        AttentionIO.appendRawLine(line)
        return true
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
        case "Stop", "SubagentStop": return "stop"
        case "Notification":
            let nested = string(payload, keys: ["notification_type", "notificationType"])
            return nested.isEmpty ? "waiting" : nested
        case "PermissionRequest": return "permission"
        default: break
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
