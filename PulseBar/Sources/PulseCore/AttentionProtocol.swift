import Foundation

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
/// Writers: `PulseHookReceiver`, `AttentionIO`, and external integrators
/// appending lines directly. Reader: `AttentionReader`. Spec:
/// `docs/attention-protocol.md`.
public enum AttentionProtocol {
    public static let version = 3

    /// Comment header written at the top of `attention.tsv`.
    ///
    /// `host` (column 7) is written empty and ignored: every line in
    /// `attention.tsv` is this Mac's. `front` (column 8) is `1` when the
    /// prompt's own window was the frontmost application as the event was
    /// raised, `0` when it was not, empty when that could not be established.
    /// Since 23.0 every record has all eight columns; a shorter line (v1/v2)
    /// is not read.
    public static let header =
        "# pulse-attention v3 (agent\\tkind\\tms\\tmessage\\tsession\\tcwd\\thost\\tfront)\n"

    /// Column count of a complete v3 record.
    public static let columnCount = 8

    /// The columns of one v3 record, or nil for a blank line, a comment or
    /// header, or a line without exactly `columnCount` columns. Only line
    /// breaks are trimmed: a v3 line's trailing columns are often empty, so
    /// trailing tabs are part of the record.
    public static func columns<S: StringProtocol>(of line: S) -> [String]? {
        let raw = String(line).trimmingCharacters(in: .newlines)
        if raw.isEmpty || raw.hasPrefix("#") { return nil }
        let cols = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        return cols.count == columnCount ? cols : nil
    }

    public static var acceptedWriteKinds: Set<String> {
        Set(AttentionKind.allCases.map(\.rawValue))
    }

    /// Vendor event names onto the v3 kinds. Unknown tokens stay as-is — and
    /// an empty one stays empty — so `acceptsWrite(kind:)` rejects them: a
    /// line that does not say what it is about is never Waiting.
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
            // 18.0: Claude's StopFailure — the turn ended on an API error
            // (rate limit, auth, overload). Over to the user; never red.
            "stop_failure": .turn,
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
            "elicitation_url_dialog": .question,
            "agent_needs_input": .question,
            "needs_input": .question,
            // Blocked, reason unknown.
            "waiting": .waiting,
            // Resolved.
            "done": .done,
            // 18.0: the elicitation was answered or closed.
            "elicitation_complete": .done,
            "elicitation_response": .done,
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
        return low
    }

    /// The typed kind of a token, or nil when the protocol does not know it.
    public static func kind(_ raw: String) -> AttentionKind? {
        AttentionKind(rawValue: normalizeKind(raw))
    }

    public static func acceptsWrite(kind: String) -> Bool {
        acceptedWriteKinds.contains(normalizeKind(kind))
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
