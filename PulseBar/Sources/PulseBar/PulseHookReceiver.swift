import Foundation

/// Native attention receiver for Claude/Codex hooks and the public Attention
/// bridge (`pulse-hook` / `PulseBar --hook`).
///
/// Parity with `src/pulse_hook.py` plus Attention Protocol v1: unknown kinds
/// soft-fail (exit 0, no write) so vendor agents are never stalled by
/// accident. One deliberate, bounded exception: a `PermissionRequest` may be
/// **held** — waiting up to a hard-capped number of seconds for a verdict
/// from the answering Mac — and only when the user opted in with a
/// `respond-secret.key` *and* nobody is at this machine. Every hold path
/// still ends in exit 0; a timeout leaves the vendor's own prompt in charge,
/// exactly like the Python end of the protocol.
enum PulseHookReceiver {
    /// Always returns 0 — vendor hooks must never be broken by Pulse.
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
        // The lamp lights first: the attention line is written before any
        // hold, so the tray shows Waiting even while the hook is parked.
        _ = appendEvent(agent: agentRaw, kind: kind, message: message, session: session, cwd: cwd)
        if kind == "permission" {
            let decision = respondDecisionJSON(
                agent: agentRaw,
                kind: kind,
                payload: payload,
                rawStdin: Data(stdin.utf8),
                idleSeconds: UserPresence.idleSeconds,
                clockMs: { Int64(Date().timeIntervalSince1970 * 1000) },
                sleepMs: { Thread.sleep(forTimeInterval: Double($0) / 1000.0) }
            )
            if let decision {
                // Same stdout contract the vendor already honours from the
                // Python hook (plan-respond P0-0 Q2).
                print(decision)
            }
        }
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

    // MARK: - Respond hold (Mac-to-Mac parity with pulse_hook.py)

    /// Poll cadence while parked. (= RESPOND_POLL_SECONDS)
    static let respondPollMs = 250

    /// Same test as `pulse_hook.py is_permission_request`: the vendor's event
    /// name, or a permission kind whose payload actually carries `tool_input`.
    static func isPermissionRequest(payload: [String: Any], kind: String) -> Bool {
        let event = string(payload, keys: ["hook_event_name", "hookEventName"])
        if event == "PermissionRequest" { return true }
        return AttentionProtocol.normalizeKind(kind) == "permission"
            && payload["tool_input"] != nil
    }

    /// How long the agent may be made to wait, seconds. Default 60, clamped
    /// to [5, 300] — frozen with the Python side's `max_hold_seconds`.
    static func maxHoldSeconds(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        let raw = (environment["PULSE_RESPOND_MAX_HOLD_SECONDS"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(raw), value.isFinite else { return 60 }
        return Int(max(5, min(300, value)))
    }

    /// How long without input before this Mac stops assuming someone is here,
    /// seconds. `PULSE_RESPOND_AWAY_SECONDS` overrides, clamped to [30, 3600].
    ///
    /// The Python end runs on headless boxes with no idle information and
    /// holds unconditionally. This Mac *has* the information, so it must use
    /// it: holding in front of a present user freezes their agent for N
    /// seconds before the prompt that was already going to appear
    /// (plan-respond, "who is actually waiting").
    static func awayAfterSeconds(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Double {
        let raw = (environment["PULSE_RESPOND_AWAY_SECONDS"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(raw), value.isFinite else {
            return RespondHold.defaultAwayAfterSeconds
        }
        return max(30, min(3600, value))
    }

    /// Machine label for the request and the verdict binding — `PULSE_HOST`
    /// override, else the hostname, normalized like every other host column.
    static func respondHost(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let override = (environment["PULSE_HOST"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty { return AttentionProtocol.normalizeHost(override) }
        return AttentionProtocol.normalizeHost(ProcessInfo.processInfo.hostName)
    }

    /// Park until a valid verdict is claimed or the deadline passes. Clock
    /// and sleep are injected so tests run in microseconds; the exactly-once
    /// and stays-consumed semantics live in `RespondSpool.claimVerdict`.
    static func holdForVerdict(
        requestID: String,
        digest: String,
        agent: String,
        host: String,
        truncated: Bool,
        deadlineMs: Int64,
        clockMs: () -> Int64,
        sleepMs: (Int) -> Void
    ) -> Bool? {
        while clockMs() < deadlineMs {
            if let allow = RespondSpool.claimVerdict(
                requestID: requestID, digest: digest, agent: agent, host: host,
                truncated: truncated, nowMs: clockMs()
            ) {
                return allow
            }
            sleepMs(respondPollMs)
        }
        return nil
    }

    /// Full hold path, mirroring `pulse_hook.py respond_decision_json` plus
    /// the presence gate. Returns the stdout decision JSON, or nil for
    /// silence — and silence on *every* path that is not a verified, in-time
    /// verdict: not a permission request, empty stdin, no opt-in key, no
    /// vendor request id, someone at this Mac, write failure, timeout.
    ///
    /// `idleSeconds` is an autoclosure so the production caller's
    /// `UserPresence` read only happens once the cheap guards have passed.
    static func respondDecisionJSON(
        agent: String,
        kind: String,
        payload: [String: Any],
        rawStdin: Data,
        idleSeconds: @autoclosure () -> Double,
        promptIsFrontmost: @autoclosure () -> Bool? = PromptVisibility.promptIsFrontmost(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        clockMs: () -> Int64,
        sleepMs: (Int) -> Void
    ) -> String? {
        guard isPermissionRequest(payload: payload, kind: kind) else { return nil }
        // Without the verbatim request bytes there is nothing the user could
        // actually review, so there is nothing Pulse may hold for.
        guard !rawStdin.isEmpty else { return nil }
        // Either key will do: the shared one provisioned for a partner Mac,
        // or the local one Pulse generates when answering this Mac's own
        // agents is switched on. No key at all means this install never opted
        // in, and an agent's behaviour must not change for those people.
        guard RespondSpool.hasAnyKey() else { return nil }
        let requestID = ((payload["tool_use_id"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // No stable id → a verdict could not be bound to this request.
        guard !requestID.isEmpty else { return nil }
        // Hold only where the user cannot already see the vendor's prompt:
        // nobody here at all, or here but looking at something that is not
        // this agent's window. Both reads are autoclosures so a request that
        // was never going to be held costs neither of them.
        guard RespondHold.shouldHold(
            idleSeconds: idleSeconds(),
            promptIsFrontmost: promptIsFrontmost(),
            awayAfterSeconds: awayAfterSeconds(environment: environment)
        ) else { return nil }
        let host = respondHost(environment: environment)
        let digest = RespondDigest.of(rawStdin)
        let now = clockMs()
        let deadlineMs = now + Int64(maxHoldSeconds(environment: environment)) * 1000
        guard RespondSpool.writeOutboundRequest(
            requestID: requestID,
            agent: agent,
            host: host,
            session: session(from: payload),
            cwd: cwd(from: payload),
            toolName: (payload["tool_name"] as? String) ?? "",
            payload: rawStdin,
            nowMs: now,
            expiresAtMs: deadlineMs
        ) else { return nil }
        guard let allow = holdForVerdict(
            requestID: requestID, digest: digest, agent: agent, host: host,
            truncated: false, deadlineMs: deadlineMs,
            clockMs: clockMs, sleepMs: sleepMs
        ) else { return nil }
        return decisionJSON(allow: allow, host: host)
    }

    /// The stdout decision shape 2.1.233 consumes — frozen with
    /// `pulse_hook.py respond_decision_json`: same keys, same nesting, same
    /// message text.
    static func decisionJSON(allow: Bool, host: String) -> String {
        // The host label lands inside hand-built JSON. normalizeHost already
        // removed the separators; strip the two characters that could still
        // break the quoting rather than pulling in a serializer that would
        // reorder the keys.
        let safeHost = host.filter { $0 != "\"" && $0 != "\\" && !$0.isNewline }
        return "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\","
            + "\"decision\":{\"behavior\":\"" + (allow ? "allow" : "deny")
            + "\",\"message\":\"Answered via Pulse from " + safeHost + "\"}}}"
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
