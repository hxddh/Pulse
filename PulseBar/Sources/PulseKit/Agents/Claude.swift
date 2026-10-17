import Foundation

extension AgentSpec {
    /// Claude Code (code.claude.com/docs/en/hooks). Every entry runs
    /// `async: true`: an async hook cannot block or decide anything ("Run
    /// hooks in the background").
    package static let claude = AgentSpec(
        id: .claude,
        displayName: "Claude",
        aliases: [],
        // PermissionRequest (at once) and Notification permission_prompt,
        // elicitation_dialog (about six seconds later) — not when nobody can be
        // shown it, and never agent_needs_input (it may be another session's).
        waiting: .hooks,
        // The native install's `~/.local/bin/claude` links into
        // `~/.local/share/claude/versions/<version>`, the path the kernel
        // reports for the running binary.
        // `claude -p` runs with nobody at a prompt: a PermissionRequest
        // there is auto-denied unless a permission host
        // (`--permission-prompt-tool`, the Agent SDK's) answers it.
        process: AgentProcessRule(
            basenames: ["claude"],
            pathNeedles: ["/.local/bin/claude", "/bin/claude", "/.local/share/claude/versions/"],
            argvDenyNeedles: ["Claude.app", "chrome-native-host"],
            promptlessFlags: ["-p", "--print"],
            promptHostFlags: ["--permission-prompt-tool"]
        ),
        // PostToolUse, not PreToolUse, marks activity; PostToolUseFailure
        // is the same for a tool that failed — a denied or failed call still
        // answers the block raised for it. PermissionDenied (auto mode
        // denied a call) is installed async: its one control, `retry`, is a
        // decision output, which Claude never reads from an async hook —
        // and Pulse prints nothing. SubagentStart / SubagentStop carry the
        // subagent's `agent_id` (its own lifecycle, never the person's
        // turn); PostCompact says the context was compacted. Never
        // PreToolUse, MessageDisplay, Elicitation or WorktreeCreate.
        hooks: HookContract(
            format: .nested(NestedFlavor(async: true)),
            path: ".claude/settings.json",
            home: ".claude",
            events: [
                HookEvent("SessionStart", .start),
                HookEvent("SessionEnd", .end),
                HookEvent("UserPromptSubmit", .prompt),
                HookEvent("PostToolUse", .activity),
                HookEvent("PostToolUseFailure", .activity),
                HookEvent("PermissionRequest", .blocked(.permission)),
                HookEvent("Notification", .ignore, matcher: "permission_prompt|idle_prompt|agent_needs_input|elicitation_dialog|elicitation_url_dialog|elicitation_complete|elicitation_response"),
                HookEvent("Stop", .turn),
                // The turn ended on an API error (rate limit, auth, overload).
                HookEvent("StopFailure", .failedTurn),
                // After the main agent's: the first event of an action is
                // the one that names it.
                HookEvent("PermissionDenied", .status),
                HookEvent("SubagentStart", .start),
                HookEvent("SubagentStop", .turn),
                HookEvent("PostCompact", .status),
            ],
            // A managed policy that runs only managed hooks, or turns every
            // hook off, before the person's own `disableAllHooks`.
            offSwitches: [
                HookSwitch(path: Claude.managedSettings, key: "allowManagedHooksOnly", caveat: .managedOnly),
                HookSwitch(path: Claude.managedSettingsFolder, folder: true, key: "allowManagedHooksOnly", caveat: .managedOnly),
                HookSwitch(path: Claude.managedSettings, key: "disableAllHooks", caveat: .managedOnly),
                HookSwitch(path: Claude.managedSettingsFolder, folder: true, key: "disableAllHooks", caveat: .managedOnly),
                HookSwitch(path: ".claude/settings.json", key: "disableAllHooks", caveat: .turnedOff),
            ]
        ),
        // Grok Build runs these hooks by default and marks its calls; Pulse
        // does not support Grok, and its events never land on a Claude row.
        foreignCallers: ["GROK_HOOK_EVENT", "GROK_SESSION_ID"],
        // Inside a subagent (the Task tool) every event carries the
        // subagent's `agent_id`; the main agent's carry none.
        subagentKeys: ["agent_id"],
        read: { Claude.read($0, $1) }
    )
}

/// Claude's events whose meaning is in the payload.
package enum Claude {
    /// Where an administrator's managed settings live on macOS.
    package static let managedSettings = "/Library/Application Support/ClaudeCode/managed-settings.json"
    package static let managedSettingsFolder = "/Library/Application Support/ClaudeCode/managed-settings.d"

    package static func read(_ event: String, _ payload: [String: Any]) -> HookReading? {
        switch event {
        case "PostToolUse":
            return HookReading(action: .activity, target: target(payload))
        case "PostToolUseFailure":
            // The call reached Claude as an abort, not as the tool's own
            // error: the person interrupted the run.
            if payload["is_interrupt"] as? Bool == true { return HookReading(action: .stopped) }
            // The tool ran and failed: still the answer to a block raised
            // for it, and a step marked failed.
            return HookReading(action: .activity, failed: true, target: target(payload))
        case "PermissionRequest":
            // `dontAsk` denies whatever is not pre-approved: nobody is shown
            // this request (`-p` without a permission host is read from the
            // process, `AgentProcessRule.promptlessFlags`).
            if PulseHookReceiver.string(payload, keys: ["permission_mode"]) == "dontAsk" {
                return HookReading(action: .skip(.noPrompt))
            }
            // AskUserQuestion comes through PermissionRequest; it is a
            // question — no allow/deny answers it.
            let tool = PulseHookReceiver.string(payload, keys: ["tool_name", "toolName"])
            let kind: AttentionKind = tool == "AskUserQuestion" ? .question : .permission
            return HookReading(action: .blocked(kind), ask: ask(payload))
        case "PermissionDenied":
            // Auto mode denied a call: work goes on, nothing is asked. The
            // tool is named in the words, never the tool column (a `status`
            // that names a tool says it runs now). The `reason` is not read.
            let tool = PulseHookReceiver.toolLabel(PulseHookReceiver.string(payload, keys: ["tool_name"]))
            return HookReading(action: .status, note: tool.isEmpty ? "auto mode denied a tool" : "auto mode denied \(tool)")
        case "PostCompact":
            // A manual `/compact` is the person at the prompt and fires no
            // Stop: it is not work. An automatic one runs inside a turn.
            // The summary is never read.
            guard PulseHookReceiver.string(payload, keys: ["trigger"]) == "auto" else {
                return HookReading(action: .ignore)
            }
            return HookReading(action: .status, note: "compacted")
        case "SubagentStart", "SubagentStop":
            // The subagent's own start and end: always its line (`sub`),
            // never the main agent's — one that names no subagent says
            // nothing Pulse shows.
            let sub = PulseHookReceiver.string(payload, keys: ["agent_id"])
            guard !sub.isEmpty else { return HookReading(action: .ignore) }
            return HookReading(action: event == "SubagentStart" ? .start : .turn, sub: sub)
        case "Notification":
            let words = PulseHookReceiver.string(payload, keys: ["message", "title"])
            switch PulseHookReceiver.string(payload, keys: ["notification_type", "notificationType"]) {
            case "permission_prompt": return HookReading(action: .blocked(.permission), ask: words)
            case "elicitation_dialog", "elicitation_url_dialog":
                return HookReading(action: .blocked(.question), ask: words)
            // A background session waiting while agent view is open, a
            // teammate's terminal setup question, or auto mode's billing
            // notice: the payload does not name the session that waits, so
            // it may be another one's.
            case "agent_needs_input": return HookReading(action: .skip(.otherSession))
            // About a minute after a turn, and again after the person saw
            // it: never a turn of its own (`AttentionKind.idle`).
            case "idle_prompt": return HookReading(action: .idle)
            case "elicitation_complete", "elicitation_response": return HookReading(action: .resolved)
            // A Notification that does not say it is a block is not one.
            default: return HookReading(action: .ignore)
            }
        default:
            return nil
        }
    }

    /// A tool's target where the generic reading misses it: an `Agent`
    /// (formerly `Task`) call's `description`, else its `subagent_type`; a
    /// `Skill` call's `skill`. Nil for any other tool. Pure.
    package static func target(_ payload: [String: Any]) -> String? {
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        let keys: [String]
        switch PulseHookReceiver.string(payload, keys: ["tool_name"]) {
        case "Agent", "Task": keys = ["description", "subagent_type"]
        case "Skill": keys = ["skill"]
        default: return nil
        }
        let text = PulseHookReceiver.string(input, keys: keys)
        return text.isEmpty ? nil : PulseHookReceiver.condenseOneLine(text)
    }

    /// What a `PermissionRequest` asks: the question itself for
    /// `AskUserQuestion` (`tool_input.questions[0].question`), the plan's
    /// first line for `ExitPlanMode` (`tool_input.plan`), an `Agent` or
    /// `Skill` call by its target (`target`), else the tool call
    /// (`PulseHookReceiver.toolDescriptor`).
    package static func ask(_ payload: [String: Any]) -> String {
        let tool = PulseHookReceiver.string(payload, keys: ["tool_name", "toolName"])
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        switch tool {
        case "AskUserQuestion":
            if let questions = input["questions"] as? [[String: Any]], let first = questions.first {
                let text = PulseHookReceiver.string(first, keys: ["question", "header"])
                if !text.isEmpty { return PulseHookReceiver.condenseOneLine(text) }
            }
            let single = PulseHookReceiver.string(input, keys: ["question"])
            if !single.isEmpty { return PulseHookReceiver.condenseOneLine(single) }
        case "ExitPlanMode":
            let summary = planSummary(PulseHookReceiver.string(input, keys: ["plan"]))
            if !summary.isEmpty { return summary }
        default:
            if let target = target(payload) { return "\(tool): \(target)" }
        }
        return PulseHookReceiver.toolDescriptor(from: payload)
    }

    /// A plan's first line with words, without its Markdown marks.
    package static func planSummary(_ plan: String) -> String {
        let marks = CharacterSet(charactersIn: "#*->`_ \t")
        for line in plan.split(whereSeparator: \.isNewline) {
            let text = String(line).trimmingCharacters(in: marks)
            if !text.isEmpty { return PulseHookReceiver.condenseOneLine(text) }
        }
        return ""
    }
}
