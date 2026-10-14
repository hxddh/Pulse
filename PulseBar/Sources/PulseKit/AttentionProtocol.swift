import Foundation

/// What a line of the event log means, as a type. One kind per meaning —
/// no marker in another column changes it:
///
/// - **blocked** (`permission`, `question`, `waiting`): the agent cannot go
///   on without you — the red lamp, a banner, a sound;
/// - **your turn** (`turn`, `failed`): it finished — or, `failed`, its turn
///   ended on an error — and waits for the next prompt: a quiet count, never
///   the red lamp;
/// - **idle** (`idle`): it has sat at its prompt a while (Claude's
///   `idle_prompt`, about a minute after a turn). Your turn only when Pulse
///   had not seen the turn end — so a turn the person already saw is not
///   revived;
/// - **resolved** (`done`, `dismiss`): nothing is owed — the vendor said its
///   prompt closed (`done`), or the person set the wait aside in Pulse
///   (`dismiss`, written by the app alone);
/// - **lifecycle** (`start`, `working`, `end`): the session began, took a
///   prompt, or ended;
/// - **activity** (`tool`, `status`): a tool ran — its last step, the answer
///   to a block raised for that tool — or (`status`) work goes on and no tool
///   ran: never a step, never an answer;
/// - **ignored** (`ignored`): the receiver heard an event it did not turn
///   into state — an event Pulse does not install, a payload that is not a
///   JSON object, a blocked event from an agent that cannot report one — and
///   says why in `message`. The reducer changes no state for it — it goes
///   on its session's timeline; it is there to be read.
package enum AttentionKind: String, Sendable, CaseIterable {
    case permission, question, waiting
    case turn, failed, idle
    case done, dismiss
    case start, working, end
    case tool, status
    case ignored

    /// The agent cannot continue until the user acts.
    package var isBlocking: Bool {
        self == .permission || self == .question || self == .waiting
    }

    /// Still owed to the user: the kinds whose `front` column is written.
    package var isOpen: Bool { isBlocking || self == .turn || self == .failed || self == .idle }

    /// Work going on: a tool ran, or (`status`) the agent says it is busy.
    package var isActivity: Bool { self == .tool || self == .status }

    /// Nothing is owed any more: the vendor's "resolved" or Pulse's own
    /// dismissal.
    package var isResolution: Bool { self == .done || self == .dismiss }
}

/// One v7 record: twelve tab-separated columns.
///
/// `seq  ms  agent  kind  event  session  cwd  pid  front  landing  tool  message`
///
/// - `seq`: the line's number in its log — assigned by `EventLog.append`
///   under the append lock, one more than the last; a reader applies only the
///   lines past the last one it applied;
/// - `event`: the vendor's own name of the hook event that wrote the line
///   (`PermissionRequest`, `tool_execution_end`, `session.status`), or
///   Pulse's own (`pulse.dismiss`, `pulse.seen`);
/// - `pid`: the agent process the hook ran under, empty when unknown (a pid
///   of 1 or less is never written: the hook's parent had exited);
/// - `front`: `1` when the prompt's own window was frontmost as the event was
///   raised, `0` when it was not, empty when that could not be established;
/// - `landing`: where the session can be reached, most specific first,
///   `;`-separated — `tmux:%3`, `iterm:w0t1p0:<uuid>`, `tty:/dev/ttys004`,
///   `term:<TERM_PROGRAM>`;
/// - `tool`: the tool a `tool` line ran, or the tool a block is about
///   (`Bash`); its target, when known, is the message;
/// - `message`: what the event said — a block's ask, a turn's last words, a
///   failed turn's error, a prompt's text, a tool's target, why a line was
///   ignored. Last, so the free text never shifts a column.
///
/// Writers clean every field (`AttentionProtocol.flatten`: no tabs, no line
/// breaks of any kind) before building one.
package struct AttentionRecord: Equatable, Sendable {
    package var seq: Int64
    package var ms: Int64
    package var agent: AgentID
    package var kind: AttentionKind
    package var event: String
    package var session: String
    package var cwd: String
    package var pid: Int32
    package var front: Bool?
    package var landing: String
    package var tool: String
    package var message: String

    package init(
        agent: AgentID,
        kind: AttentionKind,
        ms: Int64,
        message: String = "",
        session: String = "",
        cwd: String = "",
        front: Bool? = nil,
        pid: Int32 = 0,
        landing: String = "",
        tool: String = "",
        event: String = "",
        seq: Int64 = 0
    ) {
        self.seq = seq
        self.ms = ms
        self.agent = agent
        self.kind = kind
        self.event = event
        self.session = session
        self.cwd = cwd
        self.pid = pid
        self.front = front
        self.landing = landing
        self.tool = tool
        self.message = message
    }

    /// The `event` of the app's own dismissal of a wait (⌘D, a banner's
    /// "Ignore").
    package static let dismissEvent = "pulse.dismiss"
    /// The `event` of the app's own "your turn, seen" (the person went to a
    /// finished session).
    package static let seenEvent = "pulse.seen"

    /// The app's own `dismiss`: under exactly the session the row carried —
    /// an empty one, with its folder, clears only that agent's session-less
    /// entry there — so the vendor's echo of the same ask stays cleared.
    package static func dismissal(
        agent: AgentID, session: String, cwd: String, ms: Int64, event: String = AttentionRecord.dismissEvent
    ) -> AttentionRecord {
        AttentionRecord(
            agent: agent,
            kind: .dismiss,
            ms: ms,
            session: AttentionProtocol.flatten(session),
            cwd: AttentionProtocol.flatten(cwd),
            event: event
        )
    }

    /// The record as one line, without a line break.
    package var line: String {
        [
            String(seq),
            String(ms),
            agent.rawValue,
            kind.rawValue,
            event,
            session,
            cwd,
            pid > 1 ? String(pid) : "",
            AttentionProtocol.frontField(front),
            landing,
            tool,
            message,
        ].joined(separator: "\t")
    }

    /// A complete v7 record, or nil for anything else: a comment, a blank
    /// line, a line with another column count, a `seq` that is not a
    /// positive number, an agent or a kind the protocol does not know.
    package init?<S: StringProtocol>(line: S) {
        guard let cols = AttentionProtocol.columns(of: line),
              let seq = Int64(cols[0]), seq > 0,
              let agent = Agents.agent(named: cols[2]),
              let kind = AttentionProtocol.kind(cols[3])
        else { return nil }
        self.init(
            agent: agent,
            kind: kind,
            ms: Int64(cols[1]) ?? 0,
            message: cols[11],
            session: cols[5],
            cwd: cols[6],
            front: AttentionProtocol.parseFront(cols[8]),
            pid: AttentionProtocol.parsePid(cols[7]),
            landing: cols[9],
            tool: cols[10],
            event: cols[4],
            seq: seq
        )
    }
}

/// A vendor event name as Pulse says it — in a why, the detail page's
/// timeline, Settings and the report: the `event` column when it is a name
/// (letters, digits and `_ . : -`, at most 64 characters), else "" — a
/// hand-edited log or an argument that was a path says nothing rather than
/// something that is not an event. Writers already clean the column; this
/// is the reader's guard. Pure.
package enum EventName {
    package static func display(_ raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 64,
              name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_.:-".unicodeScalars.contains($0) })
        else { return "" }
        return name
    }
}

/// Attention Protocol v7 — every hook event of every supported agent, read
/// by its adapter in `pulse-hook` (the app's `--hook`), as one numbered line
/// of one append-only event log (`events.tsv`, `EventLog`).
///
/// Writers: `PulseHookReceiver` and the app's own `dismiss`, both through
/// `EventLog.append`. Reader: `SessionBook` (the app), every line in `seq`
/// order. Spec: `docs/attention-protocol.md`.
package enum AttentionProtocol {
    package static let version = 7

    /// What every `events.tsv` header begins with. A file whose first line
    /// does not is not a v7 log: it is emptied and a fresh one started, never
    /// read (`EventLog`).
    package static let headerPrefix = "# pulse-events v7 "

    /// The columns, in order — what the header's legend says.
    package static let columnNames = [
        "seq", "ms", "agent", "kind", "event", "session", "cwd", "pid", "front", "landing", "tool", "message",
    ]

    /// Column count of a complete v7 record.
    package static let columnCount = 12

    /// The first line of `events.tsv`: the protocol, the `seq` the next line
    /// gets when nothing in the file has a larger one, and the log's `gen` —
    /// chosen when the log is started (created, or a log that is not v7
    /// started over) and kept by every compaction, so a reader knows whether
    /// a rewritten file continues the numbering it applied.
    package struct Header: Equatable, Sendable {
        package var next: Int64
        package var gen: String

        package init(next: Int64, gen: String) {
            self.next = next
            self.gen = gen
        }

        /// A v7 header line, or nil for anything else.
        package init?<S: StringProtocol>(line: S) {
            let text = String(line)
            guard AttentionProtocol.isHeader(text) else { return nil }
            var next: Int64?
            var gen: String?
            for token in text.split(separator: " ").map(String.init) {
                if token.hasPrefix("next=") { next = Int64(token.dropFirst(5)) }
                if token.hasPrefix("gen=") { gen = String(token.dropFirst(4)) }
            }
            guard let next, next > 0, let gen, !gen.isEmpty else { return nil }
            self.init(next: next, gen: gen)
        }

        /// The header line, with its line break.
        package var line: String {
            let legend = AttentionProtocol.columnNames.joined(separator: "\\t")
            return AttentionProtocol.headerPrefix + "next=\(next) gen=\(gen) (\(legend))\n"
        }
    }

    /// Whether a file's first line is a v7 header.
    package static func isHeader<S: StringProtocol>(_ line: S) -> Bool {
        line.hasPrefix(headerPrefix)
    }

    /// The columns of one v7 record, or nil for a blank line, a comment or
    /// header, or a line without exactly `columnCount` columns. Only the
    /// line's own break (`\n`, `\r`) is trimmed: a record's trailing columns
    /// are often empty, so trailing tabs are part of it.
    package static func columns<S: StringProtocol>(of line: S) -> [String]? {
        var raw = String(line)
        while let last = raw.unicodeScalars.last, last == "\n" || last == "\r" {
            raw.unicodeScalars.removeLast()
        }
        if raw.isEmpty || raw.hasPrefix("#") { return nil }
        let cols = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        return cols.count == columnCount ? cols : nil
    }

    /// The typed kind of a line's `kind` column, or nil when it is not one
    /// of the v7 kinds, spelled as written (`AttentionKind.rawValue`). No
    /// other spelling is read: every writer is Pulse's own, so a word the
    /// protocol does not know is never guessed into a state, and never into
    /// Waiting.
    package static func kind(_ raw: String) -> AttentionKind? {
        AttentionKind(rawValue: raw)
    }

    /// The `front` column as written: `1` in front, `0` not, empty unknown.
    package static func frontField(_ front: Bool?) -> String {
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
    package static func blockedTool(_ ask: String) -> String {
        let head = ask.components(separatedBy: ": ").first ?? ""
        guard let first = head.unicodeScalars.first, CharacterSet.letters.contains(first),
              head.count <= 64,
              head.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0) })
        else { return "" }
        return head
    }

    /// Every character that ends a line somewhere — `\n`, `\r`, vertical
    /// tab, form feed, NEL, the Unicode line and paragraph separators — and
    /// the tab. A field holding one would split a record, or a column.
    package static let breakingScalars: Set<Unicode.Scalar> = [
        "\t", "\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}",
    ]

    /// A field as it may be written: every tab and line break a space,
    /// trimmed. Writers call it (or a stricter cleaner built on it) on every
    /// field.
    package static func flatten(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            scalars.append(breakingScalars.contains(scalar) ? " " : scalar)
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    /// The `pid` column: a pid of 1 or less (launchd — the hook's parent had
    /// exited — or garbage) is unknown.
    package static func parsePid(_ field: String) -> Int32 {
        let pid = Int32(field.trimmingCharacters(in: .whitespaces)) ?? 0
        return pid > 1 ? pid : 0
    }

    package static func parseFront(_ field: String) -> Bool? {
        switch field.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return true
        case "0": return false
        default: return nil
        }
    }
}
