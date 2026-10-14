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
        // elicitation_dialog, agent_needs_input (about six seconds later).
        waiting: .hooks,
        // The native install's `~/.local/bin/claude` links into
        // `~/.local/share/claude/versions/<version>`, the path the kernel
        // reports for the running binary.
        process: AgentProcessRule(
            basenames: ["claude"],
            pathNeedles: ["/.local/bin/claude", "/bin/claude", "/.local/share/claude/versions/"],
            argvDenyNeedles: ["Claude.app", "chrome-native-host"]
        ),
        // PostToolUse, not PreToolUse, marks activity; PostToolUseFailure
        // is the same for a tool that failed — a denied or failed call still
        // answers the block raised for it. PermissionDenied is not
        // installed: its output can ask for a retry, so it is not
        // observe-only.
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
            ]
        ),
        // Grok Build runs these hooks by default and marks its calls; Pulse
        // does not support Grok, and its events never land on a Claude row.
        foreignCallers: ["GROK_HOOK_EVENT", "GROK_SESSION_ID"],
        read: { Claude.read($0, $1) }
    )
}

/// Claude's events whose meaning is in the payload.
package enum Claude {
    package static func read(_ event: String, _ payload: [String: Any]) -> HookReading? {
        switch event {
        case "PermissionRequest":
            // AskUserQuestion comes through PermissionRequest; it is a
            // question — no allow/deny answers it.
            let tool = PulseHookReceiver.string(payload, keys: ["tool_name", "toolName"])
            let kind: AttentionKind = tool == "AskUserQuestion" ? .question : .permission
            return HookReading(action: .blocked(kind), ask: ask(payload))
        case "Notification":
            let words = PulseHookReceiver.string(payload, keys: ["message", "title"])
            switch PulseHookReceiver.string(payload, keys: ["notification_type", "notificationType"]) {
            case "permission_prompt": return HookReading(action: .blocked(.permission), ask: words)
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                return HookReading(action: .blocked(.question), ask: words)
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

    /// What a `PermissionRequest` asks: the question itself for
    /// `AskUserQuestion` (`tool_input.questions[0].question`), the plan's
    /// first line for `ExitPlanMode` (`tool_input.plan`), else the tool
    /// call (`PulseHookReceiver.toolDescriptor`).
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
            break
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
