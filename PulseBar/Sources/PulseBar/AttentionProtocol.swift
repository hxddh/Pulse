import Foundation

/// Frozen Attention bridge contract (v1) — the public Waiting path for any
/// agent that can invoke `pulse-hook` / `PulseBar --hook` without expanding
/// the Claude/Codex hook installer.
///
/// Writers: `PulseHookReceiver`, `AttentionIO`, optional legacy `pulse_hook.py`.
/// Reader: `AttentionReader`. Spec: `docs/attention-protocol.md`.
enum AttentionProtocol {
    static let version = 1

    /// Comment header written at the top of `attention.tsv`.
    /// Must stay byte-compatible across Swift writers and the optional Python hook.
    static let header =
        "# pulse-attention v1 (agent\\tkind\\tms\\tmessage\\tsession\\tcwd)\n"

    /// Canonical kinds accepted on the write path after `normalizeKind`.
    /// Waiting kinds light the red lamp; clear kinds remove it; lifecycle
    /// kinds are stored for diagnostics but ignored by `AttentionReader`.
    static let waitingKinds: Set<String> = [
        "permission", "idle_prompt", "waiting",
    ]
    static let clearKinds: Set<String> = [
        "done", "stop",
    ]
    static let lifecycleKinds: Set<String> = [
        "subagent_start", "subagent_stop",
    ]

    static var acceptedWriteKinds: Set<String> {
        waitingKinds.union(clearKinds).union(lifecycleKinds)
    }

    /// Map vendor event names onto the v1 allowlist. Unknown tokens stay as-is
    /// so `acceptsWrite(kind:)` can reject them.
    static func normalizeKind(_ kind: String) -> String {
        let k = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = k.lowercased().replacingOccurrences(of: "-", with: "_")
        let mapping: [String: String] = [
            "agent_turn_complete": "done",
            "agent_completed": "done",
            "turn_complete": "done",
            "task_complete": "done",
            "exec_approval_request": "permission",
            "apply_patch_approval_request": "permission",
            "approval_request": "permission",
            "pending_approval": "permission",
            "request_user_input": "idle_prompt",
            "user_input_request": "idle_prompt",
            "elicitation_dialog": "idle_prompt",
            "permission_prompt": "permission",
            "idle_prompt": "idle_prompt",
            "idle": "idle_prompt",
            "agent_needs_input": "idle_prompt",
            "needs_input": "idle_prompt",
            "subagent_start": "subagent_start",
            "subagent_stop": "subagent_stop",
            "subagent": "subagent_start",
            "permission": "permission",
            "stop": "stop",
            "done": "done",
            "waiting": "waiting",
        ]
        if let mapped = mapping[low] { return mapped }
        // Narrow aliases only — never invent Waiting from free text.
        if low.contains("approval"), !low.contains("response"), !low.contains("decision") {
            return "permission"
        }
        if low.contains("user_input"), !low.contains("response") {
            return "idle_prompt"
        }
        return k.isEmpty ? "waiting" : low
    }

    static func acceptsWrite(kind: String) -> Bool {
        acceptedWriteKinds.contains(normalizeKind(kind))
    }

    static func isWaitingKind(_ kind: String) -> Bool {
        waitingKinds.contains(normalizeKind(kind))
    }
}
