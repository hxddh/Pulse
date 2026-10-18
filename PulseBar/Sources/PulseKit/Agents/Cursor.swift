import Foundation

extension AgentSpec {
    /// Cursor — the IDE and its `cursor-agent` CLI are one agent
    /// (`~/.cursor/hooks.json`, observe-only events). Its `after*` events
    /// name the shell command, the edited file and the MCP tool a turn
    /// used: a Cursor row has steps, and its silence can be a stall.
    package static let cursor = AgentSpec(
        id: .cursor,
        displayName: "Cursor",
        aliases: ["cursor_agent", "cursor-agent"],
        // No Cursor hook reports a pending approval without being a gating
        // `before*` hook — running and your turn only.
        waiting: .none,
        // Only the program's path is evidence: Electron gives Cursor's
        // helpers the same `Cursor` name as the app, so no bare name is.
        // Cursor's private-worker daemon is persistent infrastructure: it
        // stays alive with no composer running, so counting it made an idle
        // IDE look like "2 processes" forever.
        process: AgentProcessRule(
            basenames: [],
            pathNeedles: ["Cursor.app/Contents/MacOS/Cursor", "cursor-agent", "anysphere.cursor-agent"],
            argvDenyNeedles: ["crashpad", "CursorUIViewService", "worker start", "--worker-dir"]
        ),
        // `beforeSubmitPrompt` can stop a prompt (`continue: false`) and every
        // `before*` event can deny: none is installed. The `after*` events
        // report what already ran; their output is not read by Cursor.
        hooks: HookContract(
            format: .versioned(commandKey: "command"),
            path: ".cursor/hooks.json",
            home: ".cursor",
            events: [
                HookEvent("sessionStart", .start),
                HookEvent("sessionEnd", .end),
                // The steps: what the agent ran, edited and called. They also
                // fire in the `cursor-agent` CLI, where `afterAgentResponse`
                // does not.
                HookEvent("afterShellExecution", .activity),
                HookEvent("afterFileEdit", .activity),
                HookEvent("afterMCPExecution", .activity),
                // A reply: work, and its `text` the turn's last words so far.
                HookEvent("afterAgentResponse", .activity),
                // `status`: `completed` your turn, `error` a failed turn,
                // `aborted` the person stopped it.
                HookEvent("stop", .turn),
            ]
        ),
        // Every Cursor event carries `conversation_id`; `session_id` only
        // some (forum reports: `sessionStart` has both, the tool events only
        // the conversation) — the conversation is the session.
        sessionKeys: ["conversation_id", "conversationId"] + HookContext.sessionKeys,
        read: { Cursor.read($0, $1) }
    )
}

/// Cursor's events whose meaning is in the payload.
package enum Cursor {
    package static func read(_ event: String, _ payload: [String: Any]) -> HookReading? {
        switch event {
        case "afterShellExecution":
            let command = PulseHookReceiver.condenseOneLine(PulseHookReceiver.string(payload, keys: ["command"]), limit: 200)
            return HookReading(action: .activity, tookMs: duration(payload), target: command, tool: "Shell")
        case "afterFileEdit":
            return HookReading(action: .activity, target: shortPath(payload), tool: "Edit")
        case "afterMCPExecution":
            let name = PulseHookReceiver.string(payload, keys: ["tool_name", "toolName"])
            let server = PulseHookReceiver.string(payload, keys: ["server_name", "serverName", "server"])
            let tool = server.isEmpty || name.isEmpty || name.hasPrefix("mcp__") ? name : "\(server) · \(name)"
            return HookReading(action: .activity, tookMs: duration(payload), target: "", tool: tool.isEmpty ? "MCP" : tool)
        case "afterAgentResponse":
            return HookReading(action: .activity, target: "", tool: "", words: PulseHookReceiver.string(payload, keys: ["text"]))
        case "stop":
            switch PulseHookReceiver.string(payload, keys: ["status"]) {
            case "error": return HookReading(action: .failedTurn)
            case "aborted": return HookReading(action: .stopped)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// How long a command or an MCP call ran, in ms, when the payload says
    /// (`duration`); 0 unknown.
    package static func duration(_ payload: [String: Any]) -> Int64 {
        for key in ["duration", "duration_ms"] {
            // Bounded before the conversion: a day is far past any command.
            if let number = payload[key] as? NSNumber, number.doubleValue.isFinite, number.doubleValue > 0 {
                return Int64(min(number.doubleValue, 86_400_000).rounded())
            }
        }
        return 0
    }

    /// The edited file, short: relative to the workspace root it lies in,
    /// else its own name.
    package static func shortPath(_ payload: [String: Any]) -> String {
        let path = PulseHookReceiver.string(payload, keys: ["file_path", "filePath"])
        guard !path.isEmpty else { return "" }
        let roots = (payload["workspace_roots"] as? [Any] ?? []).compactMap { $0 as? String }
        for root in roots where !root.isEmpty {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if path.hasPrefix(prefix), path.count > prefix.count {
                return PulseHookReceiver.condenseOneLine(String(path.dropFirst(prefix.count)), limit: 200)
            }
        }
        return PulseHookReceiver.condenseOneLine((path as NSString).lastPathComponent, limit: 200)
    }
}
