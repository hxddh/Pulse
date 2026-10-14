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
        // postToolUse / postToolUseFailure: empty output keeps the tool's own
        // result (hooks-reference.md, "postToolUse output"); the tool ran, so
        // a permission raised for it was answered.
        hooks: HookContract(
            format: .ownedJSON(commandKey: "bash", timeoutKey: "timeoutSec"),
            path: ".copilot/hooks/pulse.json",
            home: ".copilot",
            events: [
                HookEvent("sessionStart", .start),
                HookEvent("sessionEnd", .end),
                HookEvent("userPromptSubmitted", .prompt),
                HookEvent("postToolUse", .activity),
                HookEvent("postToolUseFailure", .activity),
                HookEvent("agentStop", .turn),
                HookEvent("notification", .ignore),
                HookEvent("errorOccurred", .status),
            ]
        ),
        read: { Copilot.read($0, $1) }
    )
}

/// Copilot's events whose meaning is in the payload.
package enum Copilot {
    package static func read(_ event: String, _ payload: [String: Any]) -> HookReading? {
        switch event {
        case "errorOccurred":
            // An unrecoverable error ends the turn; a recoverable one is work
            // going on — not a tool that ran, so never an answer.
            let recoverable = payload["recoverable"] as? Bool ?? true
            return HookReading(action: recoverable ? .status : .failedTurn)
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
