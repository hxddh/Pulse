import Foundation

/// What an event means, as a type.
///
/// v3 (16.0) separated the three things a person can owe an agent; v4 (24.0)
/// added the session lifecycle the vendors' own hooks report; v5 puts
/// tool activity in the same log (`tool`), so every hook event is one line:
///
/// - **blocked** (`permission`, `question`, `waiting`): the agent cannot go
///   on without you — the red lamp, a banner, a sound;
/// - **your turn** (`turn`): it finished and is waiting for the next prompt —
///   a quiet count, never the red lamp;
/// - **idle** (`idle`, 24.0): it has sat at its prompt a while (Claude's
///   `idle_prompt`, about a minute after a turn). Your turn only when Pulse
///   had not seen the turn end — the session was still working or blocked,
///   or was never seen — so a turn the person already saw is not revived;
/// - **resolved** (`done`): nothing is owed;
/// - **lifecycle** (`start`, `working`, `end`): the session began, took a
///   prompt, or ended;
/// - **activity** (`tool`): a tool ran. It keeps a working session
///   from reading stalled and answers a block raised for that tool.
public enum AttentionKind: String, Sendable, CaseIterable {
    case permission
    case question
    case waiting
    case turn
    case idle
    case done
    case start
    case working
    case end
    case tool

    /// The agent cannot continue until the user acts.
    public var isBlocking: Bool {
        self == .permission || self == .question || self == .waiting
    }

    /// Still owed to the user: the kinds whose `front` column is written.
    public var isOpen: Bool { isBlocking || self == .turn || self == .idle }
}

/// One v5 record: eleven tab-separated columns.
///
/// `agent  kind  ms  message  session  cwd  front  pid  transcript  landing  tool`
///
/// - `front`: `1` when the prompt's own window was frontmost as the event was
///   raised, `0` when it was not, empty when that could not be established;
/// - `pid`: the agent process the hook ran under, empty when unknown (a
///   pid of 1 or less is never written: the hook's parent had exited);
/// - `transcript`: the vendor's transcript path, when its hook names one;
/// - `landing`: where the session can be reached, most specific first,
///   `;`-separated — `tmux:%3`, `iterm:w0t1p0:<uuid>`, `tty:/dev/ttys004`,
///   `term:<TERM_PROGRAM>`;
/// - `tool`: the tool a `tool` line ran, or the tool a block is about
///   (`Bash`); its target, when known, is the message.
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
    public var tool: String

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
        landing: String = "",
        tool: String = ""
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
        self.tool = tool
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
            pid > 1 ? String(pid) : "",
            transcript,
            landing,
            tool,
        ].joined(separator: "\t")
    }

    /// A complete v5 record, or nil for anything else (a comment, a blank
    /// line, a v4 line with ten columns).
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
            pid: AttentionProtocol.parsePid(cols[7]),
            transcript: cols[8],
            landing: cols[9],
            tool: cols[10]
        )
    }
}

/// Frozen Attention bridge contract (v5) — every hook event of every
/// supported agent, and anything else that can invoke `pulse-hook` /
/// `PulseBar --hook`, as one line of one append-only event log
/// (`events.tsv`, `EventLog`).
///
/// Writers: `PulseHookReceiver` (through `EventLog.append`), the app's own
/// `done` for a dismissal, and external integrators appending lines.
/// Reader: `SessionBook` (the app), every line in file order. Spec:
/// `docs/attention-protocol.md`.
public enum AttentionProtocol {
    public static let version = 5

    /// The first line of `events.tsv`: the protocol and this file's
    /// generation (a new one each time the file is created or compacted, so
    /// a reader holding a byte offset knows the file was rewritten). Only
    /// complete v5 records (eleven columns) are read.
    public static func header(generation: String) -> String {
        "# pulse-events v5 \(generation) (agent\\tkind\\tms\\tmessage\\tsession\\tcwd\\tfront\\tpid\\ttranscript\\tlanding\\ttool)\n"
    }

    /// Column count of a complete v5 record.
    public static let columnCount = 11

    /// The columns of one v5 record, or nil for a blank line, a comment or
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

    /// Protocol spellings onto the v5 kinds, for bridges that write a kind
    /// word rather than a vendor event. Unknown tokens stay as-is — and an
    /// empty one stays empty — so `acceptsWrite(kind:)` rejects them: a line
    /// that does not say what it is about is never Waiting.
    ///
    /// `stop` is **your turn**, not blocked and not cleared; `idle_prompt` /
    /// `idle` is **idle** (your turn only if the turn's end was not seen);
    /// the question family has its own kind.
    public static func normalizeKind(_ kind: String) -> String {
        let k = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = k.lowercased().replacingOccurrences(of: "-", with: "_")
        let mapping: [String: AttentionKind] = [
            // Your turn: the agent finished and is idle at its prompt.
            "turn": .turn,
            "stop": .turn,
            // Sat at its prompt a while: your turn only if nobody saw it end.
            "idle_prompt": .idle,
            "idle": .idle,
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
            // Activity: a tool ran.
            "tool": .tool,
            "activity": .tool,
            // 24.0 lifecycle.
            "start": .start,
            "session_start": .start,
            "working": .working,
            "prompt": .working,
            "end": .end,
            "session_end": .end,
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

    /// The tool a raise names when its words are the receiver's tool
    /// descriptor (`Tool` or `Tool: target`): one token of letters, digits
    /// and `_ . -`. Anything else — prose, a question — names no tool. Used
    /// when a line's `tool` column is empty.
    public static func blockedTool(_ ask: String) -> String {
        let head = ask.components(separatedBy: ": ").first ?? ""
        guard let first = head.unicodeScalars.first, CharacterSet.letters.contains(first),
              head.count <= 64,
              head.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0) })
        else { return "" }
        return head
    }

    /// The `pid` column: a pid of 1 or less (launchd — the hook's parent had
    /// exited — or garbage) is unknown.
    public static func parsePid(_ field: String) -> Int32 {
        let pid = Int32(field.trimmingCharacters(in: .whitespaces)) ?? 0
        return pid > 1 ? pid : 0
    }

    public static func parseFront(_ field: String) -> Bool? {
        switch field.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return true
        case "0": return false
        default: return nil
        }
    }
}
