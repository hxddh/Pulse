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
        // The CLI's `agent` command is a link into its install folder
        // (`~/.local/share/cursor-agent/versions/…`), which the
        // `cursor-agent` path component matches: a bare `agent` anywhere
        // else is never Cursor.
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
                // Observational (no output is read): a tool that failed — a
                // step marked failed, its `failure_type` the error; an
                // interrupted one is the person stopping the run.
                HookEvent("postToolUseFailure", .activity),
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
        // The agent's tool names as its hooks spell them (`shell`,
        // `read_file`, `edit_file`…; third-party bindings, unverified).
        toolCategories: Cursor.toolCategories,
        read: { Cursor.read($0, $1) }
    )
}

/// Cursor's events whose meaning is in the payload.
package enum Cursor {
    /// Cursor's tools by category, lowercased.
    package static let toolCategories: [String: StepCategory] = [
        "shell": .shell, "run_terminal_cmd": .shell, "bash": .shell,
        "read_file": .read, "read": .read,
        "edit_file": .edit, "write": .edit, "edit": .edit, "search_replace": .edit, "delete_file": .edit,
        "multiedit": .edit,
        "grep": .search, "glob": .search, "codebase_search": .search, "file_search": .search, "list_dir": .search,
        "web_search": .web, "fetch": .web, "webfetch": .web,
        "todo_write": .plan, "todowrite": .plan,
        "task": .agent,
    ]

    package static func read(_ event: String, _ payload: [String: Any]) -> HookReading? {
        switch event {
        case "afterShellExecution":
            let command = PulseHookReceiver.condenseOneLine(PulseHookReceiver.string(payload, keys: ["command"]), limit: 200)
            return HookReading(action: .activity, tookMs: duration(payload), target: command, tool: "Shell", cat: .shell)
        case "afterFileEdit":
            return HookReading(action: .activity, target: shortPath(payload), tool: "Edit", cat: .edit)
        case "afterMCPExecution":
            // The payload names the tool, not its server.
            let name = PulseHookReceiver.string(payload, keys: ["tool_name", "toolName"])
            return HookReading(action: .activity, tookMs: duration(payload), target: "", tool: name.isEmpty ? "MCP" : name, cat: .mcp)
        case "postToolUseFailure":
            if payload["is_interrupt"] as? Bool == true { return HookReading(action: .stopped) }
            let failure = LineMeta.token(PulseHookReceiver.string(payload, keys: ["failure_type"]))
            return HookReading(action: .activity, failed: true, tookMs: duration(payload), meta: LineMeta(err: failure.isEmpty ? "error" : failure))
        case "sessionEnd":
            // Why it ended, and the error it ended on, when it says.
            let error = LineMeta.firstLine(PulseHookReceiver.string(payload, keys: ["error_message"]), limit: LineMeta.errLimit)
            return HookReading(action: .end, meta: LineMeta(err: error, why: PulseHookReceiver.string(payload, keys: ["reason"])))
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
