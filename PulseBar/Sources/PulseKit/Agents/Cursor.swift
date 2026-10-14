import Foundation

extension AgentSpec {
    /// Cursor — the IDE and its `cursor-agent` CLI are one agent
    /// (`~/.cursor/hooks.json`, observe-only events). None names a tool, so
    /// a Cursor row has no steps; no event's meaning is in its payload.
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
        // `beforeSubmitPrompt` can stop a prompt (`continue: false`), so it
        // is not installed.
        hooks: HookContract(
            format: .versioned(commandKey: "command"),
            path: ".cursor/hooks.json",
            home: ".cursor",
            events: [
                HookEvent("sessionStart", .start),
                HookEvent("sessionEnd", .end),
                HookEvent("afterAgentResponse", .activity),
                HookEvent("stop", .turn),
            ]
        )
    )
}
