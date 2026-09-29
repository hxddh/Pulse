import Foundation

/// Frozen Attention bridge contract (v1) — the public Waiting path for any
/// agent that can invoke `pulse-hook` / `PulseBar --hook` without expanding
/// the Claude/Codex hook installer.
///
/// Writers: `PulseHookReceiver`, `AttentionIO`, optional legacy `pulse_hook.py`.
/// Reader: `AttentionReader`. Spec: `docs/attention-protocol.md`.
/// 16.0 · what an attention event means, as a type.
///
/// Until 15.0 the canonical kinds were bare strings, and one of them —
/// `idle_prompt` — meant two things: a clarifying question (the bridge docs)
/// and Claude's `idle_prompt` notification, which is a 60-second timer that
/// fires after every finished turn. Both lit the red lamp, so every Claude
/// session that finished its work went red a minute later and stayed red.
/// v3 separates the three things a person can owe an agent:
///
/// - **blocked** (`permission`, `question`, `waiting`): the agent cannot go
///   on without you — the red lamp, a banner, a sound;
/// - **your turn** (`turn`): it finished and is waiting for the next prompt —
///   a quiet count, never the red lamp;
/// - **resolved** (`done`): nothing is owed.
public enum AttentionKind: String, Sendable, CaseIterable {
    case permission
    case question
    case waiting
    case turn
    case done
    case subagentStart = "subagent_start"
    case subagentStop = "subagent_stop"

    /// The agent cannot continue until the user acts.
    public var isBlocking: Bool {
        self == .permission || self == .question || self == .waiting
    }

    /// Still owed to the user — kept when the attention file is compacted.
    public var isOpen: Bool { isBlocking || self == .turn }
}

/// Frozen Attention bridge contract (v3) — the public Waiting path for any
/// agent that can invoke `pulse-hook` / `PulseBar --hook` without expanding
/// the Claude/Codex hook installer.
///
/// Writers: `PulseHookReceiver`, `AttentionIO`, optional legacy `pulse_hook.py`.
/// Reader: `AttentionReader`. Spec: `docs/attention-protocol.md`.
public enum AttentionProtocol {
    public static let version = 3

    /// Comment header written at the top of `attention.tsv`.
    ///
    /// v2 added `host` (an empty host means this Mac, which is what every v1
    /// line means). v3 adds `front`: `1` when the prompt's own window was the
    /// frontmost application as the event was raised, `0` when it was not,
    /// empty when that could not be established. v1 and v2 lines stay valid;
    /// a missing column reads as unknown.
    public static let header =
        "# pulse-attention v3 (agent\\tkind\\tms\\tmessage\\tsession\\tcwd\\thost\\tfront)\n"

    /// The v1 header, still written by older installed hooks. Readers must
    /// accept it; an upgrade that darkened the local lamp would be a worse
    /// bug than anything remote visibility adds.
    public static let headerV1 =
        "# pulse-attention v1 (agent\\tkind\\tms\\tmessage\\tsession\\tcwd)\n"

    /// Any line starting with this is a header, whatever version it names.
    public static let headerPrefix = "# pulse-attention "

    /// Column count of a complete v3 record.
    public static let columnCount = 8

    /// Canonical kinds, as strings, for the writers and older call sites.
    public static let waitingKinds: Set<String> = Set(
        AttentionKind.allCases.filter(\.isBlocking).map(\.rawValue)
    )
    public static let clearKinds: Set<String> = [AttentionKind.done.rawValue]
    public static let turnKinds: Set<String> = [AttentionKind.turn.rawValue]
    public static let lifecycleKinds: Set<String> = [
        AttentionKind.subagentStart.rawValue, AttentionKind.subagentStop.rawValue,
    ]

    public static var acceptedWriteKinds: Set<String> {
        Set(AttentionKind.allCases.map(\.rawValue))
    }

    /// Vendor event names onto the v3 kinds. Unknown tokens stay as-is so
    /// `acceptsWrite(kind:)` can reject them.
    ///
    /// v3 changes three meanings on purpose (docs/attention-protocol.md):
    /// `idle_prompt` / `idle` and `stop` are **your turn**, not blocked and
    /// not cleared; Codex's `agent-turn-complete` is your turn, not cleared;
    /// the question family has its own kind instead of borrowing `idle_prompt`.
    public static func normalizeKind(_ kind: String) -> String {
        let k = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = k.lowercased().replacingOccurrences(of: "-", with: "_")
        let mapping: [String: AttentionKind] = [
            // Your turn: the agent finished and is idle at its prompt.
            "turn": .turn,
            "stop": .turn,
            "idle_prompt": .turn,
            "idle": .turn,
            "agent_turn_complete": .turn,
            "agent_completed": .turn,
            "turn_complete": .turn,
            "task_complete": .turn,
            // Blocked on a permission.
            "permission": .permission,
            "permission_prompt": .permission,
            "exec_approval_request": .permission,
            "apply_patch_approval_request": .permission,
            "approval_request": .permission,
            "pending_approval": .permission,
            // Blocked on a question.
            "question": .question,
            "request_user_input": .question,
            "user_input_request": .question,
            "elicitation_dialog": .question,
            "agent_needs_input": .question,
            "needs_input": .question,
            // Blocked, reason unknown.
            "waiting": .waiting,
            // Resolved.
            "done": .done,
            // Lifecycle, stored for diagnostics only.
            "subagent_start": .subagentStart,
            "subagent": .subagentStart,
            "subagent_stop": .subagentStop,
        ]
        if let mapped = mapping[low] { return mapped.rawValue }
        // Narrow aliases only — never invent Waiting from free text.
        if low.contains("approval"), !low.contains("response"), !low.contains("decision") {
            return AttentionKind.permission.rawValue
        }
        if low.contains("user_input"), !low.contains("response") {
            return AttentionKind.question.rawValue
        }
        return k.isEmpty ? AttentionKind.waiting.rawValue : low
    }

    /// The typed kind of a token, or nil when the protocol does not know it.
    public static func kind(_ raw: String) -> AttentionKind? {
        AttentionKind(rawValue: normalizeKind(raw))
    }

    /// A host label is an identity, not free text: it lands in a `rowKey` and
    /// on the identity line, so it must not carry the separators those rely on
    /// and must not grow unbounded.
    ///
    /// An empty result means "this machine" — the same thing a v1 line means.
    public static func normalizeHost(_ raw: String) -> String {
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

    public static func acceptsWrite(kind: String) -> Bool {
        acceptedWriteKinds.contains(normalizeKind(kind))
    }

    public static func isWaitingKind(_ kind: String) -> Bool {
        Self.kind(kind)?.isBlocking == true
    }

    /// Column 8 as written: `1` in front, `0` not, empty unknown.
    public static func frontField(_ front: Bool?) -> String {
        switch front {
        case .some(true): return "1"
        case .some(false): return "0"
        case .none: return ""
        }
    }

    public static func parseFront(_ field: String) -> Bool? {
        switch field.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return true
        case "0": return false
        default: return nil
        }
    }
}
