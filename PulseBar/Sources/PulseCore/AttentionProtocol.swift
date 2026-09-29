import Foundation

/// What an attention event means, as a type.
///
/// v3 (16.0) separated the three things a person can owe an agent; v4 (24.0)
/// adds the session lifecycle the vendors' own hooks report:
///
/// - **blocked** (`permission`, `question`, `waiting`): the agent cannot go
///   on without you — the red lamp, a banner, a sound;
/// - **your turn** (`turn`): it finished and is waiting for the next prompt —
///   a quiet count, never the red lamp;
/// - **resolved** (`done`): nothing is owed;
/// - **lifecycle** (`start`, `working`, `end`): the session began, took a
///   prompt, or ended. Each says nothing is owed any more, so each clears the
///   session's entry exactly like `done`.
public enum AttentionKind: String, Sendable, CaseIterable {
    case permission
    case question
    case waiting
    case turn
    case done
    case start
    case working
    case end
    case subagentStart = "subagent_start"
    case subagentStop = "subagent_stop"

    /// The agent cannot continue until the user acts.
    public var isBlocking: Bool {
        self == .permission || self == .question || self == .waiting
    }

    /// Still owed to the user — kept when the attention file is compacted.
    public var isOpen: Bool { isBlocking || self == .turn }

    /// Says nothing is owed for the session it names (24.0: the lifecycle
    /// kinds clear like `done`).
    public var clears: Bool {
        self == .done || self == .start || self == .working || self == .end
    }
}

/// One v4 record: ten tab-separated columns.
///
/// `agent  kind  ms  message  session  cwd  front  pid  transcript  landing`
///
/// - `front`: `1` when the prompt's own window was frontmost as the event was
///   raised, `0` when it was not, empty when that could not be established;
/// - `pid`: the agent process the hook ran under, `0`/empty when unknown;
/// - `transcript`: the vendor's transcript path, when its hook names one;
/// - `landing`: where the session can be reached, most specific first,
///   `;`-separated — `tmux:%3`, `iterm:w0t1p0:<uuid>`, `tty:/dev/ttys004`,
///   `term:<TERM_PROGRAM>`.
///
/// Writers clean every field (no tabs, no line breaks) before building one.
public struct AttentionRecord: Equatable, Sendable {
    public var agent: String
    public var kind: String
    public var ms: Int64
    public var message: String
    public var session: String
    public var cwd: String
    public var front: Bool?
    public var pid: Int32
    public var transcript: String
    public var landing: String

    public init(
        agent: String,
        kind: String,
        ms: Int64,
        message: String = "",
        session: String = "",
        cwd: String = "",
        front: Bool? = nil,
        pid: Int32 = 0,
        transcript: String = "",
        landing: String = ""
    ) {
        self.agent = agent
        self.kind = kind
        self.ms = ms
        self.message = message
        self.session = session
        self.cwd = cwd
        self.front = front
        self.pid = pid
        self.transcript = transcript
        self.landing = landing
    }

    /// The record as one line, without a line break.
    public var line: String {
        [
            agent,
            kind,
            String(ms),
            message,
            session,
            cwd,
            AttentionProtocol.frontField(front),
            pid > 0 ? String(pid) : "",
            transcript,
            landing,
        ].joined(separator: "\t")
    }

    /// A complete v4 record, or nil for anything else (a comment, a blank
    /// line, a v3 line with eight columns).
    public init?<S: StringProtocol>(line: S) {
        guard let cols = AttentionProtocol.columns(of: line) else { return nil }
        self.init(
            agent: cols[0],
            kind: cols[1],
            ms: Int64(cols[2]) ?? 0,
            message: cols[3],
            session: cols[4],
            cwd: cols[5],
            front: AttentionProtocol.parseFront(cols[6]),
            pid: Int32(cols[7]) ?? 0,
            transcript: cols[8],
            landing: cols[9]
        )
    }
}

/// Frozen Attention bridge contract (v4) — the Waiting path for every
/// supported agent's hook, and for anything else that can invoke
/// `pulse-hook` / `PulseBar --hook`.
///
/// Writers: `PulseHookReceiver`, `AttentionIO`, and external integrators
/// appending lines directly. Reader: `AttentionReader`. Spec:
/// `docs/attention-protocol.md`.
public enum AttentionProtocol {
    public static let version = 4

    /// Comment header written at the top of `attention.tsv`. Since 24.0 only
    /// complete v4 records (ten columns) are read; a v3 line is ignored.
    public static let header =
        "# pulse-attention v4 (agent\\tkind\\tms\\tmessage\\tsession\\tcwd\\tfront\\tpid\\ttranscript\\tlanding)\n"

    /// Column count of a complete v4 record.
    public static let columnCount = 10

    /// The columns of one v4 record, or nil for a blank line, a comment or
    /// header, or a line without exactly `columnCount` columns. Only line
    /// breaks are trimmed: a record's trailing columns are often empty, so
    /// trailing tabs are part of it.
    public static func columns<S: StringProtocol>(of line: S) -> [String]? {
        let raw = String(line).trimmingCharacters(in: .newlines)
        if raw.isEmpty || raw.hasPrefix("#") { return nil }
        let cols = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        return cols.count == columnCount ? cols : nil
    }

    public static var acceptedWriteKinds: Set<String> {
        Set(AttentionKind.allCases.map(\.rawValue))
    }

    /// Protocol spellings onto the v4 kinds, for bridges that write a kind
    /// word rather than a vendor event. Unknown tokens stay as-is — and an
    /// empty one stays empty — so `acceptsWrite(kind:)` rejects them: a line
    /// that does not say what it is about is never Waiting.
    ///
    /// `idle_prompt` / `idle` and `stop` are **your turn**, not blocked and
    /// not cleared; the question family has its own kind.
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
            "turn_complete": .turn,
            "task_complete": .turn,
            // Claude's StopFailure — the turn ended on an API error (rate
            // limit, auth, overload). Over to the user; never red.
            "stop_failure": .turn,
            // Blocked on a permission.
            "permission": .permission,
            "permission_prompt": .permission,
            "approval_request": .permission,
            // Blocked on a question.
            "question": .question,
            "elicitation_dialog": .question,
            "elicitation_url_dialog": .question,
            "agent_needs_input": .question,
            // Blocked, reason unknown.
            "waiting": .waiting,
            // Resolved.
            "done": .done,
            // The elicitation was answered or closed.
            "elicitation_complete": .done,
            "elicitation_response": .done,
            // 24.0 lifecycle.
            "start": .start,
            "session_start": .start,
            "working": .working,
            "prompt": .working,
            "end": .end,
            "session_end": .end,
            // Lifecycle, stored for diagnostics only.
            "subagent_start": .subagentStart,
            "subagent_stop": .subagentStop,
        ]
        if let mapped = mapping[low] { return mapped.rawValue }
        // Never invent Waiting from free text: an unknown word stays unknown.
        return low
    }

    /// The typed kind of a token, or nil when the protocol does not know it.
    public static func kind(_ raw: String) -> AttentionKind? {
        AttentionKind(rawValue: normalizeKind(raw))
    }

    public static func acceptsWrite(kind: String) -> Bool {
        acceptedWriteKinds.contains(normalizeKind(kind))
    }

    /// The `front` column as written: `1` in front, `0` not, empty unknown.
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
