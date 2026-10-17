import Foundation

extension AgentSpec {
    /// Codex `hooks.json` (openai/codex codex-rs/hooks). Pulse never touches
    /// `config.toml`. No event's action is in its payload; only the
    /// subagent that spoke (`agent_id`) is.
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
        // (engine/discovery.rs). PostToolUse runs `async`, so it cannot
        // change what Codex does; it is the per-tool activity the stall rule
        // needs.
        hooks: HookContract(
            format: .nested(NestedFlavor(
                async: true,
                synchronous: ["SessionEnd": 3],
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
            ]
        ),
        // A subagent's events carry its `agent_id`; the main agent's none.
        subagentKeys: ["agent_id"]
    )
}
