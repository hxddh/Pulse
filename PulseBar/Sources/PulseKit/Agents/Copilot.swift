import Foundation

extension AgentSpec {
    /// Copilot CLI (github/docs, copilot hooks reference): the camelCase
    /// events Pulse installs, in a hook file Pulse owns whole.
    package static let copilot = AgentSpec(
        id: .copilot,
        displayName: "Copilot",
        aliases: [],
        // `notification` permission_prompt / elicitation_dialog —
        // fire-and-forget, never blocks the session.
        waiting: .hooks,
        process: AgentProcessRule(
            basenames: ["copilot"],
            pathNeedles: ["/bin/copilot", "github/gh-copilot", "@github/copilot", "copilot-cli"],
            argvDenyNeedles: ["crashpad", "language-server", "copilot-language-server", "Copilot.Helper", "Copilot for Xcode"]
        ),
        // Each entry runs the launcher directly (`exec` + `args`, CLI only):
        // no shell reads its path.
        //
        // postToolUse / postToolUseFailure: empty output keeps the tool's own
        // result (hooks-reference.md, "postToolUse output"); the tool ran, so
        // a permission raised for it was answered. `agentStop` and
        // `postToolUse` are synchronous and could return a decision — an
        // owner-approved exception to the install rule: Pulse's hook appends
        // one line and prints nothing, so it never decides.
        hooks: HookContract(
            format: .ownedJSON(command: .exec, timeoutKey: "timeoutSec"),
            path: ".copilot/hooks/pulse.json",
            home: ".copilot",
            events: [
                // A `-p` run's `initialPrompt` is its title.
                HookEvent("sessionStart", .start),
                HookEvent("sessionEnd", .end),
                HookEvent("userPromptSubmitted", .prompt),
                HookEvent("postToolUse", .activity),
                HookEvent("postToolUseFailure", .activity),
                HookEvent("agentStop", .turn),
                // Only the types Pulse reads reach the hook: a background
                // agent's idle is heard and said to mean nothing here.
                HookEvent("notification", .ignore, matcher: "permission_prompt|elicitation_dialog|agent_idle"),
                HookEvent("errorOccurred", .status),
                // Cannot block creation: a subagent began, on the timeline.
                HookEvent("subagentStart", .status),
                // Notification only; a manual `/compact` is the person at
                // the prompt, so only the automatic one is installed.
                HookEvent("preCompact", .status, matcher: "auto"),
            ],
            // `COPILOT_HOME` moves the folder hooks load from
            // (`$COPILOT_HOME/hooks/`); a GUI app cannot see it, so Pulse
            // installs to the default and says so.
            relocation: HookContract.Relocation(dir: ".copilot", variable: "COPILOT_HOME"),
            // The person's own `disableAllHooks` (cli-config-dir-reference,
            // user settings: "Disable all hooks (both repository-level and
            // user-level)"). Copilot documents no managed-only switch.
            offSwitches: [
                HookSwitch(path: ".copilot/settings.json", key: "disableAllHooks", caveat: .turnedOff),
            ]
        ),
        // A subagent's events carry its `agentId`; the main agent's none.
        subagentKeys: ["agentId"],
        // The runtime's tool names (hooks-reference, "Claude-format
        // matchers").
        toolCategories: Copilot.toolCategories,
        read: { Copilot.read($0, $1) }
    )
}

/// Copilot's events whose meaning is in the payload.
package enum Copilot {
    /// Copilot's tools by category, lowercased.
    package static let toolCategories: [String: StepCategory] = [
        "bash": .shell, "powershell": .shell,
        "view": .read,
        "create": .edit, "edit": .edit, "str_replace_editor": .edit, "apply_patch": .edit,
        "grep": .search, "rg": .search, "glob": .search,
        "web_fetch": .web, "web_search": .web,
        "task": .agent,
        "update_todo": .plan,
        "skill": .skill,
    ]

    package static func read(_ event: String, _ payload: [String: Any]) -> HookReading? {
        switch event {
        case "sessionStart":
            // A one-shot run (`copilot -p`) says its prompt here: the row's
            // title before any prompt event.
            let initial = PulseHookReceiver.string(payload, keys: ["initialPrompt", "initial_prompt"])
            return initial.isEmpty ? nil : HookReading(action: .start, name: TitleHeuristics.promptTitle(initial, limit: 200))
        case "postToolUseFailure":
            // The tool ran and failed: a step marked failed, with its
            // error's first line.
            let error = LineMeta.firstLine(PulseHookReceiver.string(payload, keys: ["error"]), limit: LineMeta.errLimit)
            return HookReading(action: .activity, failed: true, meta: LineMeta(err: error))
        case "errorOccurred":
            // An unrecoverable error ends the turn; a recoverable one is work
            // going on — not a tool that ran, so never an answer, and after
            // the turn ended it moves nothing (a `status` that names no tool
            // never starts a turn). Its `error.name` is the line's error.
            let recoverable = payload["recoverable"] as? Bool ?? true
            let name = (payload["error"] as? [String: Any]).map { PulseHookReceiver.string($0, keys: ["name"]) } ?? ""
            let meta = LineMeta(err: LineMeta.firstLine(name, limit: LineMeta.errLimit))
            return recoverable
                ? HookReading(action: .status, note: "recoverable error", meta: meta)
                : HookReading(action: .failedTurn, meta: meta)
        case "subagentStart":
            // Its payload names the agent, not the `agentId` its own events
            // will carry: the name marks the line as the subagent's.
            let name = PulseHookReceiver.string(payload, keys: ["agentName", "agentDisplayName"])
            return HookReading(action: .status, sub: String(name.prefix(80)), note: "subagent started")
        case "preCompact":
            // The matcher installs the automatic one; a manual one says
            // nothing if it ever arrives.
            if PulseHookReceiver.string(payload, keys: ["trigger"]) == "manual" { return HookReading(action: .ignore) }
            return HookReading(action: .status, note: "compacting")
        case "notification":
            let words = PulseHookReceiver.string(payload, keys: ["message", "title"])
            switch PulseHookReceiver.string(payload, keys: ["notification_type", "notificationType"]) {
            case "permission_prompt": return HookReading(action: .blocked(.permission), ask: words)
            case "elicitation_dialog": return HookReading(action: .blocked(.question), ask: words)
            // agent_idle / agent_completed are background subagents, not the
            // session's own turn; shell completions are not either.
            default: return HookReading(action: .ignore)
            }
        default:
            return nil
        }
    }
}
