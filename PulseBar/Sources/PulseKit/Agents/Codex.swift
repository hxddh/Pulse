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
        // Pulse infers nothing from the silence. Codex runs an entry only
        // once it is trusted, bound to the entry's text (`/hooks`): the
        // install report says to trust it once.
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
                HookEvent("SubagentStop", .turn),
            ]
        ),
        // A subagent's events carry its `agent_id` (its thread); the main
        // agent's none. Every thread of a session shares its `session_id`.
        subagentKeys: ["agent_id"],
        // A turn says its last words: `Stop` carries `last_assistant_message`.
        lastWords: true,
        read: { Codex.read($0, $1) }
    )
}

/// Codex's events whose meaning is in the payload.
package enum Codex {
    package static func read(_ event: String, _ payload: [String: Any]) -> HookReading? {
        switch event {
        case "SubagentStop":
            // A thread-spawned subagent finished its turn: its own line
            // (`sub`), never the end of the person's turn — one that names
            // no subagent says nothing Pulse shows.
            let sub = PulseHookReceiver.string(payload, keys: ["agent_id"])
            guard !sub.isEmpty else { return HookReading(action: .ignore) }
            return HookReading(action: .turn, sub: sub)
        default:
            return nil
        }
    }
}
