import Foundation

extension AgentSpec {
    /// Codex `hooks.json` (openai/codex codex-rs/hooks). Pulse never touches
    /// `config.toml` — never reads it, never writes it. Only `SubagentStop`'s
    /// meaning is in its payload (the subagent that finished); every event
    /// carries the subagent that spoke (`agent_id`).
    package static let codex = AgentSpec(
        id: .codex,
        displayName: "Codex",
        aliases: [],
        // Codex's PermissionRequest fires before its own auto-review, so an
        // approval nobody is asked for would light a red lamp
        // (openai/codex#28833). Its hooks say running and your turn (Stop);
        // they never say blocked, and PermissionRequest is not installed.
        waiting: .none,
        process: AgentProcessRule(
            basenames: ["codex"],
            pathNeedles: ["/opt/homebrew/bin/codex", "/bin/codex", "Resources/codex"],
            argvDenyNeedles: ["Codex Framework", "crashpad", "computer-use", "codex-code-mode-host"]
        ),
        // The same nested shape as Claude's, `async` honoured — except
        // SessionEnd, which Codex always runs synchronously and caps at 3 s
        // (engine/discovery.rs). Interrupt runs async but its timeout is
        // capped at 3 s too; its only output is a `systemMessage`. PostToolUse
        // runs `async`, so it cannot change what Codex does; it is the
        // per-tool activity — the steps. SubagentStop is installed
        // async: its block decision is never read from an async entry. A
        // turn that ends on an error fires no Stop (core session/turn.rs):
        // Pulse infers nothing from the silence. SubagentStart is installed
        // async (its only output is context for the child, never read from
        // an async entry). PostCompact is installed async; PreCompact is
        // not — its `continue: false` stops the compaction. Codex runs an
        // entry only once it is trusted, bound to the entry's text
        // (`/hooks`): the install report says to trust it once.
        hooks: HookContract(
            format: .nested(NestedFlavor(
                async: true,
                synchronous: ["SessionEnd": 3],
                timeoutCaps: ["Interrupt": 3],
                installNote: "trust them once in Codex: /hooks"
            )),
            path: ".codex/hooks.json",
            home: ".codex",
            events: [
                HookEvent("SessionStart", .start),
                HookEvent("SessionEnd", .end),
                HookEvent("UserPromptSubmit", .prompt),
                HookEvent("PostToolUse", .activity),
                HookEvent("Stop", .turn),
                HookEvent("Interrupt", .stopped),
                HookEvent("SubagentStart", .start),
                HookEvent("SubagentStop", .turn),
                HookEvent("PostCompact", .status),
            ]
        ),
        // A subagent's events carry its `agent_id` (its thread); the main
        // agent's none. Every thread of a session shares its `session_id`.
        subagentKeys: ["agent_id"],
        // Codex's hook tool names (core tools/hook_names.rs and the
        // handlers' `tool_name`); an MCP tool is `mcp__<server>__<tool>`.
        toolCategories: Codex.toolCategories,
        mcpToolPrefixes: ["mcp__"],
        read: { Codex.read($0, $1) }
    )
}

/// Codex's events whose meaning is in the payload.
package enum Codex {
    /// Codex's tools by category, lowercased.
    package static let toolCategories: [String: StepCategory] = [
        "bash": .shell, "shell": .shell, "exec_command": .shell, "write_stdin": .shell, "local_shell": .shell,
        "apply_patch": .edit,
        "read_file": .read, "view_image": .read,
        "list_dir": .search, "grep_files": .search, "tool_search": .search,
        "web_search": .web,
        "spawn_agent": .agent, "send_input": .agent, "wait_agent": .agent, "close_agent": .agent,
        "update_plan": .plan,
    ]

    package static func read(_ event: String, _ payload: [String: Any]) -> HookReading? {
        switch event {
        case "SubagentStart", "SubagentStop":
            // A thread-spawned subagent began, or finished its turn: its own
            // line (`sub`), never the person's — one that names no subagent
            // says nothing Pulse shows.
            let sub = PulseHookReceiver.string(payload, keys: ["agent_id"])
            guard !sub.isEmpty else { return HookReading(action: .ignore) }
            let agentType = PulseHookReceiver.string(payload, keys: ["agent_type"])
            return HookReading(action: event == "SubagentStart" ? .start : .turn, sub: sub, meta: LineMeta(agentType: agentType))
        case "PostCompact":
            // A manual `/compact` is the person at the prompt; an automatic
            // one runs inside a turn. Nothing of the summary is read.
            guard PulseHookReceiver.string(payload, keys: ["trigger"]) == "auto" else { return HookReading(action: .ignore) }
            return HookReading(action: .status, note: "compacted")
        case "PostToolUse":
            switch PulseHookReceiver.string(payload, keys: ["tool_name"]) {
            case "apply_patch":
                // `tool_input.command` is the raw patch: its file headers
                // are the files, the first is the step's target.
                let files = patchFiles(PulseHookReceiver.toolInput(payload)?["command"] as? String ?? "")
                guard let first = files.first else { return nil }
                let target = files.count > 1 ? "\(first) (+\(files.count - 1))" : first
                return HookReading(action: .activity, target: PulseHookReceiver.condenseOneLine(target, limit: 200), meta: LineMeta(files: files))
            case "update_plan":
                // `tool_input.plan[{step, status}]` (protocol plan_tool.rs).
                let steps = PulseHookReceiver.toolInput(payload)?["plan"] as? [[String: Any]] ?? []
                let items = steps.map { (status: PulseHookReceiver.string($0, keys: ["status"]), text: PulseHookReceiver.string($0, keys: ["step"])) }
                let progress = LineMeta.progress(items)
                return HookReading(action: .activity, target: "", meta: LineMeta(plan: progress.plan, planNow: progress.now))
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// The files an `apply_patch` patch names, in its order, each once:
    /// `*** Add File: `, `*** Update File: `, `*** Delete File: ` and a
    /// move's `*** Move to: ` (apply-patch parser.rs). At most
    /// `LineMeta.maxFiles`. Pure.
    package static func patchFiles(_ patch: String) -> [String] {
        let markers = ["*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "]
        var files: [String] = []
        for line in patch.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let marker = markers.first(where: { text.hasPrefix($0) }) else { continue }
            let path = String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            if path.isEmpty || files.contains(path) { continue }
            files.append(path)
            if files.count >= LineMeta.maxFiles { break }
        }
        return files
    }
}
