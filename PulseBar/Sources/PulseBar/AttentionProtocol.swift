import Foundation

/// Frozen Attention bridge contract (v1) — the public Waiting path for any
/// agent that can invoke `pulse-hook` / `PulseBar --hook` without expanding
/// the Claude/Codex hook installer.
///
/// Writers: `PulseHookReceiver`, `AttentionIO`, optional legacy `pulse_hook.py`.
/// Reader: `AttentionReader`. Spec: `docs/attention-protocol.md`.
enum AttentionProtocol {
    static let version = 2

    /// Comment header written at the top of `attention.tsv`.
    /// Must stay byte-compatible across Swift writers and the optional Python hook.
    ///
    /// v2 adds a seventh column, `host`, so a wait raised on another machine
    /// can be told apart from one raised here. An empty `host` means this Mac,
    /// which is exactly what every v1 line means — so v1 lines stay valid and
    /// an already-installed `pulse_hook.py` keeps lighting the local lamp.
    static let header =
        "# pulse-attention v2 (agent\\tkind\\tms\\tmessage\\tsession\\tcwd\\thost)\n"

    /// The v1 header, still written by older installed hooks. Readers must
    /// accept it; an upgrade that darkened the local lamp would be a worse
    /// bug than anything remote visibility adds.
    static let headerV1 =
        "# pulse-attention v1 (agent\\tkind\\tms\\tmessage\\tsession\\tcwd)\n"

    /// Any line starting with this is a header, whatever version it names.
    static let headerPrefix = "# pulse-attention "

    /// Column count of a complete v2 record.
    static let columnCount = 7

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

    /// A host label is an identity, not free text: it lands in a `rowKey` and
    /// on the identity line, so it must not carry the separators those rely on
    /// and must not grow unbounded.
    ///
    /// An empty result means "this machine" — the same thing a v1 line means.
    static func normalizeHost(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in ["\t", "\n", "|", "/"] {
            value = value.replacingOccurrences(of: separator, with: "-")
        }
        // `devbox.local` and `devbox` are the same machine to a human.
        if value.lowercased().hasSuffix(".local") {
            value = String(value.dropLast(".local".count))
        }
        if value.count > 32 { value = String(value.prefix(32)) }
        return value
    }

    static func acceptsWrite(kind: String) -> Bool {
        acceptedWriteKinds.contains(normalizeKind(kind))
    }

    static func isWaitingKind(_ kind: String) -> Bool {
        waitingKinds.contains(normalizeKind(kind))
    }
}
