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
/// - **lifecycle** (`start`, `working`, `stopped`, `title`, `end`): the
///   session began, took a prompt, was stopped by the person at its prompt
///   (`stopped`: nothing owed, no last words), was named by its vendor
///   (`title`: the name, no state), or ended;
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
    case start, working, stopped, title, end
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

/// One v9 record: seventeen tab-separated columns.
///
/// `seq  ms  agent  kind  event  session  sub  cwd  pid  front  landing  tool  err  took  cat  meta  message`
///
/// - `seq`: the line's number in its log — assigned by `EventLog.append`
///   under the append lock, one more than the last; a reader applies only the
///   lines past the last one it applied;
/// - `event`: the vendor's own name of the hook event that wrote the line
///   (`PermissionRequest`, `tool_execution_end`, `session.status`), or
///   Pulse's own (`pulse.dismiss`, `pulse.seen`);
/// - `sub`: the vendor's id of the subagent (child agent) the event came
///   from — Claude's and Codex's `agent_id`, Copilot's `agentId` — empty for
///   the main agent. A subagent's line never answers another's block, never
///   revives an ended turn and is never the person's prompt (`SessionBook`);
/// - `pid`: the agent process the hook ran under, empty when unknown (a pid
///   of 1 or less is never written: the hook's parent had exited);
/// - `front`: `1` when the prompt's own window was frontmost as the event was
///   raised, `0` when it was not, empty when that could not be established;
/// - `landing`: where the session can be reached, most specific first,
///   `;`-separated — `tmux:%3`, `iterm:w0t1p0:<uuid>`, `tty:/dev/ttys004`,
///   `term:<TERM_PROGRAM>`;
/// - `tool`: the tool a `tool` line ran, or the tool a block is about
///   (`Bash`), or the tool a `status` line says has started; its target,
///   when known, is the message;
/// - `err`: `1` when the tool a `tool` line reports failed, else empty;
/// - `took`: how long that tool ran, in ms, when the vendor said; else empty;
/// - `cat`: the step's category (`StepCategory`) as the agent's adapter
///   names its tool — on a line that names a tool; else empty;
/// - `meta`: small structured facts (`LineMeta`): a plan's progress, a
///   failed tool's error line, why a session started or ended, the
///   subagent's type, the files a batch changed, the vendor's name for the
///   session;
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
    /// The subagent the line came from; "" for the main agent.
    package var sub: String
    /// The tool a `tool` line reports failed (`err` = `1`).
    package var failed: Bool
    /// How long that tool ran, in ms; 0 unknown.
    package var tookMs: Int64
    /// The step's category, on a line that names a tool; nil none.
    package var category: StepCategory?
    /// Small structured facts (`meta`); empty none.
    package var meta: LineMeta
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
        seq: Int64 = 0,
        sub: String = "",
        failed: Bool = false,
        tookMs: Int64 = 0,
        category: StepCategory? = nil,
        meta: LineMeta = LineMeta()
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
        self.sub = sub
        self.failed = failed
        self.tookMs = tookMs
        self.category = category
        self.meta = meta
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
            sub,
            cwd,
            pid > 1 ? String(pid) : "",
            AttentionProtocol.frontField(front),
            landing,
            tool,
            failed ? "1" : "",
            tookMs > 0 ? String(tookMs) : "",
            category?.rawValue ?? "",
            meta.field,
            message,
        ].joined(separator: "\t")
    }

    /// A complete v9 record, or nil for anything else: a comment, a blank
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
            message: cols[16],
            session: cols[5],
            cwd: cols[7],
            front: AttentionProtocol.parseFront(cols[9]),
            pid: AttentionProtocol.parsePid(cols[8]),
            landing: cols[10],
            tool: cols[11],
            event: cols[4],
            seq: seq,
            sub: cols[6],
            failed: cols[12] == "1",
            tookMs: AttentionProtocol.parseTook(cols[13]),
            category: StepCategory(rawValue: cols[14]),
            meta: LineMeta(field: cols[15])
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

/// Attention Protocol v9 — every hook event of every supported agent, read
/// by its adapter in `pulse-hook` (the app's `--hook`), as one numbered line
/// of one append-only event log (`events.tsv`, `EventLog`).
///
/// Writers: `PulseHookReceiver` and the app's own `dismiss`, both through
/// `EventLog.append`. Reader: `SessionBook` (the app), every line in `seq`
/// order. Spec: `docs/attention-protocol.md`.
package enum AttentionProtocol {
    package static let version = 9

    /// What every `events.tsv` header begins with. A file whose first line
    /// does not is not a v9 log: it is emptied and a fresh one started, never
    /// read (`EventLog`).
    package static let headerPrefix = "# pulse-events v9 "

    /// The columns, in order — what the header's legend says.
    package static let columnNames = [
        "seq", "ms", "agent", "kind", "event", "session", "sub", "cwd", "pid", "front", "landing", "tool",
        "err", "took", "cat", "meta", "message",
    ]

    /// Column count of a complete v9 record.
    package static let columnCount = 17

    /// The first line of `events.tsv`: the protocol, the `seq` the next line
    /// gets when nothing in the file has a larger one, and the log's `gen` —
    /// chosen when the log is started (created, or a log that is not v9
    /// started over) and kept by every compaction, so a reader knows whether
    /// a rewritten file continues the numbering it applied.
    package struct Header: Equatable, Sendable {
        package var next: Int64
        package var gen: String

        package init(next: Int64, gen: String) {
            self.next = next
            self.gen = gen
        }

        /// A v9 header line, or nil for anything else.
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

    /// Whether a file's first line is a v9 header.
    package static func isHeader<S: StringProtocol>(_ line: S) -> Bool {
        line.hasPrefix(headerPrefix)
    }

    /// The columns of one v9 record, or nil for a blank line, a comment or
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
    /// of the v9 kinds, spelled as written (`AttentionKind.rawValue`). No
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

    /// The `took` column: a positive number of ms, else unknown (0).
    package static func parseTook(_ field: String) -> Int64 {
        let took = Int64(field.trimmingCharacters(in: .whitespaces)) ?? 0
        return took > 0 ? took : 0
    }

    package static func parseFront(_ field: String) -> Bool? {
        switch field.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return true
        case "0": return false
        default: return nil
        }
    }
}

/// What kind of work a step is — the `cat` column — as the agent's own
/// adapter names its tool (`AgentSpec.category(ofTool:)`, or the adapter's
/// own reading): no vendor's tool name is spelled outside `Agents/`. Only a
/// line that names a tool carries one; anything else leaves the column
/// empty. A word the protocol does not know reads as none.
package enum StepCategory: String, Sendable, CaseIterable, Hashable {
    /// A file was written, edited or patched.
    case edit
    /// A file (or an image) was read.
    case read
    /// A command ran in a shell.
    case shell
    /// Files or code were searched or listed.
    case search
    /// A page was fetched, or the web searched.
    case web
    /// A tool of an MCP server.
    case mcp
    /// A subagent was started, messaged or waited on.
    case agent
    /// A skill was invoked.
    case skill
    /// The agent's own plan or to-do list changed.
    case plan
    /// Any other tool.
    case other
}

/// The `meta` column: small structured facts a line carries, `k=v` pairs
/// separated by `;`, in a fixed order — `plan=<done>/<total>`,
/// `planNow=<the item in progress>`, `err=<a failed tool's first error
/// line>`, `src=<why the session started>`, `why=<why it ended>`,
/// `type=<the subagent's type>`, `files=<path|path…>` (a batch of changed
/// files), `name=<the vendor's name for the session>`. Every value is one
/// line (`AttentionProtocol.flatten`), bounded, with `%`, `;` and `|`
/// escaped (`%25`, `%3B`, `%7C`); an unknown key is skipped, a malformed
/// value is none. Writers redact credentials before they build one
/// (`PulseHookReceiver.cleanMeta`). Pure.
package struct LineMeta: Hashable, Sendable {
    /// A plan's progress: how many of its items are done, of how many.
    package struct Plan: Hashable, Sendable {
        package var done: Int
        package var total: Int

        /// Nil unless `0 <= done <= total`, `0 < total <= maxPlanItems`.
        package init?(done: Int, total: Int) {
            guard total > 0, total <= LineMeta.maxPlanItems, done >= 0, done <= total else { return nil }
            self.done = done
            self.total = total
        }
    }

    package var plan: Plan?
    /// The plan item in progress, its first line.
    package var planNow: String
    /// A failed tool's (or a session's) error, its first line.
    package var err: String
    /// Why the session started (`startup`, `resume`, `clear`, `compact`, `fork`…).
    package var src: String
    /// Why the session ended (`clear`, `logout`, `quit`…).
    package var why: String
    /// The subagent's type (`Explore`, `worker`).
    package var agentType: String
    /// The files a batch reported changed, in its order.
    package var files: [String]
    /// The vendor's name for the session, carried by a line that is not a
    /// `title` or `start` (Claude's prompt with its custom title).
    package var name: String

    package static let planNowLimit = 120
    package static let errLimit = 160
    package static let tokenLimit = 40
    package static let nameLimit = 120
    package static let fileLimit = 160
    package static let maxFiles = 16
    /// The most the escaped `files` value takes.
    package static let filesBudget = 480
    package static let maxPlanItems = 9999

    package init(
        plan: Plan? = nil, planNow: String = "", err: String = "", src: String = "", why: String = "",
        agentType: String = "", files: [String] = [], name: String = ""
    ) {
        self.plan = plan
        self.planNow = planNow
        self.err = err
        self.src = src
        self.why = why
        self.agentType = agentType
        self.files = files
        self.name = name
    }

    /// Nothing said.
    package var isEmpty: Bool { field.isEmpty }

    /// The column as written: every value cleaned and bounded, empty ones
    /// left out.
    package var field: String {
        var pairs: [String] = []
        if let plan { pairs.append("plan=\(plan.done)/\(plan.total)") }
        func add(_ key: String, _ value: String, _ limit: Int) {
            let clean = Self.clean(value, limit: limit)
            if !clean.isEmpty { pairs.append(key + "=" + Self.escape(clean)) }
        }
        add("planNow", planNow, Self.planNowLimit)
        add("err", err, Self.errLimit)
        add("src", Self.token(src), Self.tokenLimit)
        add("why", Self.token(why), Self.tokenLimit)
        add("type", agentType, Self.tokenLimit)
        var kept: [String] = []
        var size = 0
        for file in files.prefix(Self.maxFiles) {
            let value = Self.escape(Self.clean(file, limit: Self.fileLimit))
            if value.isEmpty { continue }
            if size + value.count + 1 > Self.filesBudget { break }
            kept.append(value)
            size += value.count + 1
        }
        if !kept.isEmpty { pairs.append("files=" + kept.joined(separator: "|")) }
        add("name", name, Self.nameLimit)
        return pairs.joined(separator: ";")
    }

    /// The column as read.
    package init(field: String) {
        self.init()
        for pair in field.split(separator: ";", omittingEmptySubsequences: true) {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[pair.startIndex..<equals])
            let raw = String(pair[pair.index(after: equals)...])
            switch key {
            case "plan":
                let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
                if parts.count == 2, let done = Int(parts[0]), let total = Int(parts[1]) {
                    plan = Plan(done: done, total: total)
                }
            case "planNow": planNow = Self.clean(Self.unescape(raw), limit: Self.planNowLimit)
            case "err": err = Self.clean(Self.unescape(raw), limit: Self.errLimit)
            case "src": src = Self.token(Self.unescape(raw))
            case "why": why = Self.token(Self.unescape(raw))
            case "type": agentType = Self.clean(Self.unescape(raw), limit: Self.tokenLimit)
            case "files":
                files = Array(raw.split(separator: "|", omittingEmptySubsequences: true)
                    .map { Self.clean(Self.unescape(String($0)), limit: Self.fileLimit) }
                    .filter { !$0.isEmpty }
                    .prefix(Self.maxFiles))
            case "name": name = Self.clean(Self.unescape(raw), limit: Self.nameLimit)
            default: continue
            }
        }
    }

    /// A value as it may be written: one line, at most `limit` characters.
    package static func clean(_ value: String, limit: Int) -> String {
        let flat = AttentionProtocol.flatten(value)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(max(0, limit - 1))) + "…"
    }

    /// A word only — letters, digits and `_ . : -`, at most `tokenLimit`
    /// characters (a start's `source`, an end's `reason`); anything else is
    /// none: a reason is never prose.
    package static func token(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= tokenLimit,
              text.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_.:-".unicodeScalars.contains($0) })
        else { return "" }
        return text
    }

    /// The first line of `raw` that says something, credentials redacted,
    /// at most `limit` characters.
    package static func firstLine(_ raw: String, limit: Int) -> String {
        TitleHeuristics.firstLine(raw, limit: limit)
    }

    /// The plan items' statuses, as an agent's adapter read them: done is
    /// `completed`, and the first `in_progress` item is the one in progress.
    /// Nil progress for an empty plan. Pure.
    package static func progress(_ items: [(status: String, text: String)]) -> (plan: Plan?, now: String) {
        let total = min(items.count, maxPlanItems)
        let done = items.prefix(total).filter { $0.status == "completed" }.count
        let now = items.first { $0.status == "in_progress" }.map { firstLine($0.text, limit: planNowLimit) } ?? ""
        return (Plan(done: done, total: total), now)
    }

    private static func escape(_ value: String) -> String {
        var out = ""
        for character in value {
            switch character {
            case "%": out += "%25"
            case ";": out += "%3B"
            case "|": out += "%7C"
            default: out.append(character)
            }
        }
        return out
    }

    private static func unescape(_ value: String) -> String {
        var out = ""
        var rest = Substring(value)
        while let first = rest.first {
            if first == "%", rest.count >= 3 {
                let code = rest.dropFirst().prefix(2).uppercased()
                let decoded: Character? = code == "25" ? "%" : code == "3B" ? ";" : code == "7C" ? "|" : nil
                if let decoded {
                    out.append(decoded)
                    rest = rest.dropFirst(3)
                    continue
                }
            }
            out.append(first)
            rest = rest.dropFirst()
        }
        return out
    }
}
