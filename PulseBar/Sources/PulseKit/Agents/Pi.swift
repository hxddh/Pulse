import Foundation

extension AgentSpec {
    /// Pi (earendil-works/pi, packages/coding-agent `extensions/types.ts`):
    /// an extension Pulse owns whole. Its handlers return nothing, so no
    /// event's result changes; it forwards a small payload in the last
    /// argument.
    package static let pi = AgentSpec(
        id: .pi,
        displayName: "Pi",
        aliases: [],
        // `ui_prompt_start` / `ui_prompt_end`: Pi reports when it waits on a
        // blocking user-facing prompt (a confirm, a select, an input, an
        // editor — a `custom` view is not one).
        waiting: .hooks,
        // Pi's deny list is the program's own name (`pip`, `pihole`…): an
        // argument such as `./pipeline.ts` does not make Pi not Pi. Pi sets
        // `process.title` to `pi` (`src/cli/setup.ts`) or `pi-rpc`
        // (`src/rpc-entry.ts`), which on macOS overwrites its argv: the
        // kernel then reports `node` with argv `["pi", "", …]`, read as
        // `node pi` (`AgentProcesses.commandLine`).
        process: AgentProcessRule(
            basenames: ["pi", "pi-rpc"],
            pathNeedles: ["pi-coding-agent", "/opt/homebrew/bin/pi", "/usr/local/bin/pi", "/.local/bin/pi"],
            denyNeedles: ["pip", "pip3", "pihole", "pickle", "pypi", "pixel", "piano"],
            allowBareBasename: true
        ),
        hooks: HookContract(
            format: .module(render: { Pi.module(launcher: $0, events: $1) }),
            path: ".pi/agent/extensions/pulse.js",
            home: ".pi",
            events: [
                // Neither is sent for a reload: the same session goes on.
                // A start carries the session's name, when it has one.
                HookEvent("session_start", .start),
                HookEvent("session_shutdown", .end),
                // The person (or `/name`) named the session: its title.
                HookEvent("session_info_changed", .title),
                // A run began; it carries no prompt.
                HookEvent("agent_start", .prompt),
                // Sent for the person's own message only: its text is the
                // prompt (the title, unless the session has a name).
                HookEvent("message_start", .prompt),
                // A tool started: what runs now — never a step, never an
                // answer, and a long tool is not a stall.
                HookEvent("tool_execution_start", .status),
                HookEvent("tool_execution_end", .activity),
                HookEvent("ui_prompt_start", .blocked(.question)),
                HookEvent("ui_prompt_end", .resolved),
                // Pi will not continue on its own: the turn is over — or,
                // `aborted`, the person stopped it.
                HookEvent("agent_settled", .turn),
            ],
            // `getAgentDir()` (src/config.ts): `PI_CODING_AGENT_DIR` moves
            // the folder the extension is loaded from; a GUI app cannot see
            // it, so Pulse installs to the default and says so.
            relocation: HookContract.Relocation(dir: ".pi/agent", variable: "PI_CODING_AGENT_DIR")
        ),
        // Pi runs subagents as separate `pi --mode json` processes, which
        // the extension silences; a tool's nested calls are folded into it.
        // No event names a subagent.
        subagentKeys: [],
        // The extension spawns pulse-hook itself, with `process.pid`.
        reportsOwnPID: true,
        // Pi's built-in tools (`src/core/tools`).
        toolCategories: [
            "bash": .shell, "powershell": .shell,
            "read": .read,
            "edit": .edit, "write": .edit,
            "ls": .search, "grep": .search, "find": .search,
        ],
        read: { Pi.read($0, $1) }
    )
}

/// Pi's events whose meaning is in the payload, and its extension.
package enum Pi {
    package static func read(_ event: String, _ payload: [String: Any]) -> HookReading? {
        let kind = PulseHookReceiver.string(payload, keys: ["kind"])
        switch event {
        case "ui_prompt_start":
            // As Pi's own interactive reporter says it
            // (`interactive-mode.ts`, `setBlocked`): a confirm is an
            // approval; a select, an input or an editor is a question; a
            // `custom` view blocks nothing. The ask is the prompt's title —
            // never the event's `reason` (`ui_prompt`).
            if kind == "custom" { return HookReading(action: .skip(.notABlock)) }
            let blocked: AttentionKind = kind == "confirm" ? .permission : .question
            return HookReading(action: .blocked(blocked), ask: PulseHookReceiver.string(payload, keys: ["title", "message"]))
        case "ui_prompt_end":
            // The end of a view that was never a block answers nothing.
            return kind == "custom" ? HookReading(action: .skip(.notABlock)) : nil
        case "tool_execution_end":
            // `isError` and `durationMs`, forwarded as `is_error` /
            // `duration_ms`: a step marked failed, and how long it ran.
            let failed = payload["is_error"] as? Bool ?? false
            let took = (payload["duration_ms"] as? NSNumber)?.int64Value ?? 0
            return HookReading(action: .activity, failed: failed, tookMs: max(0, took))
        case "agent_settled":
            // The person stopped the run (Escape): nothing is owed, and its
            // partial words are not the turn's last words.
            if payload["aborted"] as? Bool == true { return HookReading(action: .stopped) }
            // The run's last assistant message stopped on an error (the
            // extension forwards its `errorMessage` as `error`).
            return PulseHookReceiver.string(payload, keys: ["error"]).isEmpty ? nil : HookReading(action: .failedTurn)
        default:
            return nil
        }
    }

    /// `~/.pi/agent/extensions/pulse.js` (docs/extensions.md). Starts
    /// nothing in the factory; every handler is wrapped in `try`, returns
    /// `undefined` and never awaits.
    ///
    /// - **Only an interactive Pi speaks.** Nothing is sent when
    ///   `ctx.mode` is `json` or `print`: a subagent is a `pi --mode json -p
    ///   --no-session` process, and a script's one-shot run is nobody's
    ///   session.
    /// - **In order.** Each event is one `pulse-hook` child, and the log
    ///   numbers lines in the order the children take its lock — not the
    ///   order Pi emitted them — so the extension spawns a child only after
    ///   the one before it exited (or `GUARD_MS` passed): a prompt's end is
    ///   never written before its start. The queue is bounded (`QUEUE_MAX`;
    ///   a block, its answer and the turn's end are dropped last). On
    ///   `session_shutdown` whatever is still queued is dropped and the
    ///   shutdown is sent at once: children spawned together take the lock
    ///   in any order, and a step numbered after the session's end would
    ///   revive it.
    /// - **Steps.** `tool_execution_start` is sent (what runs now) and its
    ///   one short argument kept by `toolCallId` for the end, which carries
    ///   none: the command for a shell, the path for a file tool, the
    ///   pattern for a search, else the first of a fallback list. The end
    ///   says whether the tool failed and how long it ran. A call another
    ///   tool made (`parentToolCallId`) is folded into its caller: not sent.
    /// - **Titles.** A skill invocation (`<skill name="N" …>…</skill>` and
    ///   its arguments) is sent as `/skill:N ARGS` — never the skill file's
    ///   path or body; the session's own name rides on `session_start` and
    ///   `session_info_changed`.
    /// - **Last words.** `agent_end` (observed, never sent) keeps the run's
    ///   last assistant words or its error for `agent_settled`; an aborted
    ///   run sends neither.
    ///
    /// Every text is sliced only to bound the argv, well past what a row
    /// shows: the receiver redacts credentials from the whole value it gets
    /// before it shortens it. No transcript path is sent.
    package static func module(launcher: String, events: [String]) -> String {
        let list = events.map(HookModules.literal).joined(separator: ", ")
        return HookModules.piModuleTemplate
            .replacingOccurrences(of: #"/*__PULSE_HOOK__*/"/tmp/pulse-hook""#, with: HookModules.literal(launcher))
            .replacingOccurrences(of: "/*__EVENTS__*/", with: list)
    }
}
