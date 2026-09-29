import Foundation

/// 24.0 · the event core: every session Pulse knows, and the one state each
/// is in, from the agents' own hook events.
///
/// Pulse no longer reads vendor session files to guess what a session is
/// doing. Each supported agent's hook writes an attention line (v4) when a
/// session starts, takes a prompt, is blocked, finishes its turn or ends,
/// and an activity event per tool call; a process exit ends a session. This
/// is the reducer those events feed — a pure value, `apply` in, `sessions`
/// out — and `SessionProjection` turns it into the rows the tray draws.
///
/// The rules, each an owner decision:
///
/// - **Red only from a blocked event** (`permission`, `question`,
///   `waiting`), and never for an agent whose hook cannot say it is blocked
///   (Codex, Cursor: `waiting: .none`).
/// - **Your turn is quiet**: a `turn` is a count, never red, never a banner.
///   A turn within `stopGraceMs` of a block does not clear it at once (the
///   vendors' event order is not ours): it is held, and applies when the
///   grace ends (`settleHeldTurns`, the next event, the tick) or as soon as
///   the block is answered before it — a turn is never dropped, so a denied
///   prompt cannot leave the lamp red. A turn the person watched finish
///   (`front`) is owed to nobody, and `idle` (Claude's `idle_prompt`, a
///   minute after the turn) is a turn only while the session was still
///   working or blocked — it never revives a turn already seen.
/// - **An answer arrives as activity**: nothing writes `done` when a
///   permission is granted in the vendor's own prompt — the next tool call
///   (or prompt) stamped after the raise is the answer. When the block and
///   the activity both name their tool, only that tool's activity answers
///   it: a parallel tool finishing is not the person saying yes.
/// - **`done`** (the vendor's "resolved", or a dismissal in Pulse) clears the
///   session it names; an empty session clears only the agent's session-less
///   sessions, never one that has an id.
/// - **An exit ends a session**: a process exit (kqueue) or a pid found dead
///   ends every live session that pid ran. Nothing here guesses "running".
struct SessionBook: Equatable {
    /// What a session is doing, as its events said.
    enum State: Equatable, Sendable {
        /// Started, or its turn was seen: alive at its prompt, nothing owed.
        case idle
        /// It took a prompt, or reported work since its last state.
        case working
        /// It cannot go on until the person answers — the red lamp.
        case blocked(Block)
        /// It finished its turn and nobody has looked since — quiet.
        case yourTurn(sinceMs: Int64)
        /// It ended, or its process exited.
        case ended(atMs: Int64)
    }

    struct Block: Equatable, Sendable {
        /// `.permission`, `.question` or `.waiting`.
        var kind: AttentionKind
        /// What the agent asked, sanitized; "" when the event did not say.
        var ask: String
        var sinceMs: Int64
        /// The prompt's own window was in front when it was raised.
        var inFront: Bool
        /// The tool the block is about, when the raise named it (`Bash`
        /// from Claude's `Bash: npm test`); "" when unknown.
        var tool: String = ""
    }

    /// A turn that arrived within `stopGraceMs` of a block: held, never
    /// dropped.
    struct HeldTurn: Equatable, Sendable {
        var ms: Int64
        var front: Bool
    }

    struct Session: Equatable, Sendable {
        /// `RowIdentity.session` — decided by the first event, never changed.
        var key: String
        var agent: AgentID
        /// The session exactly as the events spell it ("" for a
        /// folder-keyed one) — what a dismissal's `done` must carry.
        var session: String
        var cwd = ""
        /// The agent process the hook ran under; 0 unknown.
        var pid: Int32 = 0
        /// The vendor's transcript, when its hook names one.
        var transcript = ""
        /// Where the session can be reached (`tmux:…;tty:…;term:…`).
        var landing = ""
        var state: State = .idle
        /// When the current state began, by the event's clock.
        var stateSinceMs: Int64 = 0
        /// The first event seen.
        var startedMs: Int64 = 0
        /// The newest event of any kind.
        var lastEventMs: Int64 = 0
        /// The newest activity event (a tool ran, a prompt was submitted).
        var activityMs: Int64 = 0
        /// What the latest turn line carried (a vendor's last words, when
        /// its hook sends them) — the only words an agent with no transcript
        /// has.
        var message = ""
        /// A turn waiting out the grace of the current block.
        var heldTurn: HeldTurn?

        var isEnded: Bool {
            if case .ended = state { return true }
            return false
        }
    }

    private(set) var sessions: [String: Session] = [:]

    /// A turn ending this soon after a block does not clear it.
    static let stopGraceMs: Int64 = 20_000
    /// How far an event's stamp may run ahead of now before it is refused.
    static let clockFutureToleranceMs: Int64 = 5 * 60 * 1000
    /// A session nothing has said anything about for this long is dropped.
    static let retentionMs: Int64 = 24 * 60 * 60 * 1000
    static let maxSessions = 256
    /// An activity event may introduce a session Pulse has not met only
    /// while it is this fresh (the spool keeps a day of files).
    static let activityIntroductionMs: Int64 = 30 * 60 * 1000

    init() {}

    // MARK: - Attention events

    /// One attention line, in file order. Returns whether anything changed.
    @discardableResult
    mutating func apply(_ record: AttentionRecord, nowMs: Int64) -> Bool {
        guard let agent = AgentCatalog.agent(named: record.agent),
              let kind = AttentionProtocol.kind(record.kind),
              record.ms > 0, record.ms <= nowMs + Self.clockFutureToleranceMs
        else { return false }
        // No fake Waiting: an agent whose hooks cannot report a block is
        // never blocked, whoever wrote the line.
        if kind.isBlocking, agent.waitingSource == .none { return false }
        let ms = record.ms
        let spelled = record.session.trimmingCharacters(in: .whitespacesAndNewlines)

        switch kind {
        case .subagentStart, .subagentStop:
            return false
        case .done where spelled.isEmpty:
            // An empty `done` clears the agent's session-less entries only.
            var changed = false
            for key in sessions.keys.sorted() where sessions[key]?.agent == agent && sessions[key]?.session.isEmpty == true {
                changed = resolve(key, at: ms) || changed
            }
            return changed
        default:
            break
        }

        let key = RowIdentity.session(agent: agent, session: spelled, cwd: record.cwd)
        let before = sessions[key]
        guard var session = before ?? introduce(key: key, agent: agent, session: spelled, kind: kind, ms: ms) else {
            return false
        }
        // A held turn whose grace this event's clock has passed goes first.
        Self.settleHeldTurn(&session, nowMs: ms)
        note(record, ms: ms, into: &session)

        switch kind {
        case .start:
            // A start mid-work (a resume, a compaction) says nothing about
            // the work; otherwise the session is at its prompt.
            if session.state != .working { Self.set(&session, .idle, at: ms) }
        case .working:
            Self.answer(&session, at: ms)
        case .permission, .question, .waiting:
            Self.raise(kind, record: record, at: ms, in: &session)
        case .turn:
            let message = ContentSanitizer.redact(record.message)
            if !message.isEmpty { session.message = message }
            Self.turn(&session, at: ms, front: record.front == true)
        case .idle:
            // Sat at its prompt a while: news only if Pulse had not seen the
            // turn end (still working or blocked — an Esc on a prompt fires
            // no Stop — or a session met just now).
            switch session.state {
            case .working, .blocked:
                Self.turn(&session, at: ms, front: record.front == true)
            case .idle where before == nil:
                Self.turn(&session, at: ms, front: record.front == true)
            case .idle, .yourTurn, .ended:
                break
            }
        case .done:
            _ = Self.clear(&session, at: ms)
        case .end:
            Self.set(&session, .ended(atMs: ms), at: ms)
        case .subagentStart, .subagentStop:
            break
        }
        sessions[key] = session
        return session != before
    }

    /// A session an event names for the first time — unless the event says
    /// nothing is going on (a `done` or an `end` for a session never seen).
    private func introduce(key: String, agent: AgentID, session: String, kind: AttentionKind, ms: Int64) -> Session? {
        if kind == .done || kind == .end { return nil }
        // A turn with no identity has no session to belong to.
        if kind == .turn || kind == .idle, session.isEmpty { return nil }
        return Session(key: key, agent: agent, session: session, stateSinceMs: ms, startedMs: ms)
    }

    private func note(_ record: AttentionRecord, ms: Int64, into session: inout Session) {
        let cwd = ContentSanitizer.redact(record.cwd)
        if !cwd.isEmpty { session.cwd = cwd }
        if record.pid > 0 { session.pid = record.pid }
        if !record.transcript.isEmpty { session.transcript = record.transcript }
        if !record.landing.isEmpty { session.landing = record.landing }
        if session.startedMs == 0 || ms < session.startedMs { session.startedMs = ms }
        session.lastEventMs = max(session.lastEventMs, ms)
    }

    /// A blocked event. A re-raise of the same kind inside the grace is the
    /// same block said again (Claude's `PermissionRequest`, then its
    /// `Notification` about six seconds later): it keeps the earlier words,
    /// clock and tool. A later raise with no words keeps the earlier ones'.
    private static func raise(_ kind: AttentionKind, record: AttentionRecord, at ms: Int64, in session: inout Session) {
        var block = Block(
            kind: kind,
            ask: ContentSanitizer.redact(record.message),
            sinceMs: ms,
            inFront: record.front == true
        )
        block.tool = blockedTool(block.ask)
        var held: HeldTurn?
        if case .blocked(let open) = session.state {
            if open.kind == kind, abs(ms - open.sinceMs) < Self.stopGraceMs {
                if !open.ask.isEmpty { block.ask = open.ask }
                if !open.tool.isEmpty || block.ask == open.ask { block.tool = open.tool }
                block.sinceMs = min(open.sinceMs, ms)
                block.inFront = open.inFront
            } else if block.ask.isEmpty {
                block.ask = open.ask
                block.tool = open.tool
            }
            // A held turn outlives a raise stamped before it (the lines came
            // out of order); a raise after it is a new block.
            if let turn = session.heldTurn, turn.ms >= ms { held = turn }
        }
        Self.set(&session, .blocked(block), at: block.sinceMs)
        session.heldTurn = held
    }

    /// The tool a raise names, when its words are the receiver's tool
    /// descriptor (`Tool` or `Tool: target`): one token of letters, digits
    /// and `_ . -`. Anything else — prose, a question — names no tool.
    static func blockedTool(_ ask: String) -> String {
        let head = ask.components(separatedBy: ": ").first ?? ""
        guard let first = head.unicodeScalars.first, CharacterSet.letters.contains(first),
              head.count <= 64,
              head.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0) })
        else { return "" }
        return head
    }

    /// A new state from `ms`. A held turn belongs to the block it waits on
    /// and goes with it.
    private static func set(_ session: inout Session, _ state: State, at ms: Int64) {
        session.state = state
        session.stateSinceMs = ms
        if case .blocked = state { return }
        session.heldTurn = nil
    }

    /// A turn event: held while a block is inside its grace, else the turn
    /// is over.
    private static func turn(_ session: inout Session, at ms: Int64, front: Bool) {
        if case .blocked(let block) = session.state, ms - block.sinceMs < stopGraceMs {
            // Held, not dropped: the later of two held turns is the one.
            if (session.heldTurn?.ms ?? .min) <= ms {
                session.heldTurn = HeldTurn(ms: ms, front: front)
            }
            return
        }
        endTurn(&session, at: ms, front: front)
    }

    /// The turn is over: your turn, or nothing owed when the person watched
    /// it finish.
    private static func endTurn(_ session: inout Session, at ms: Int64, front: Bool) {
        set(&session, front ? .idle : .yourTurn(sinceMs: ms), at: ms)
    }

    /// Work goes on (a prompt, a tool, a `done` for a block). A turn held
    /// for the block that ended no earlier than this still ends it.
    private static func answer(_ session: inout Session, at ms: Int64) {
        let held = session.heldTurn
        Self.set(&session, .working, at: ms)
        if let held, held.ms >= ms { endTurn(&session, at: held.ms, front: held.front) }
    }

    /// Apply a held turn once `nowMs` is past its block's grace. Returns
    /// whether it did.
    @discardableResult
    static func settleHeldTurn(_ session: inout Session, nowMs: Int64) -> Bool {
        guard let held = session.heldTurn, case .blocked(let block) = session.state,
              nowMs - block.sinceMs >= stopGraceMs
        else { return false }
        endTurn(&session, at: held.ms, front: held.front)
        return true
    }

    /// Every held turn whose grace has passed — the tick's share of the
    /// rule, so a turn after a denied prompt lands even when nothing else
    /// happens. Returns whether anything changed.
    @discardableResult
    mutating func settleHeldTurns(nowMs: Int64) -> Bool {
        var changed = false
        for key in sessions.keys.sorted() {
            guard var session = sessions[key], Self.settleHeldTurn(&session, nowMs: nowMs) else { continue }
            sessions[key] = session
            changed = true
        }
        return changed
    }

    /// `done`: a block is answered (work goes on — or, when a turn was held
    /// for it, the turn is over), a turn is seen (the session is at its
    /// prompt). Anything else is left as it is. A `done` stamped before the
    /// state began is about an earlier one (a dismissal written while a new
    /// ask was being raised) and changes nothing.
    private static func clear(_ session: inout Session, at ms: Int64) -> Bool {
        if case .blocked = session.state, ms < session.stateSinceMs { return false }
        if case .yourTurn = session.state, ms < session.stateSinceMs { return false }
        switch session.state {
        case .blocked:
            if let held = session.heldTurn {
                endTurn(&session, at: held.ms, front: held.front)
            } else {
                Self.set(&session, .working, at: ms)
            }
            return true
        case .yourTurn:
            Self.set(&session, .idle, at: ms)
            return true
        case .idle, .working, .ended:
            return false
        }
    }

    private mutating func resolve(_ key: String, at ms: Int64) -> Bool {
        guard var session = sessions[key], Self.clear(&session, at: ms) else { return false }
        session.lastEventMs = max(session.lastEventMs, ms)
        sessions[key] = session
        return true
    }

    // MARK: - Activity events

    /// A tool ran or a prompt was submitted (the activity spool). Stamped
    /// after the current state began, it says the session is working: a
    /// block was answered in the vendor's prompt, a turn was taken up again,
    /// a session at its prompt got going. A block that names its tool is
    /// answered only by a prompt or by that tool (`answers`). Idempotent —
    /// the spool is re-read whole, and an event no newer than the last one
    /// changes nothing.
    @discardableResult
    mutating func apply(activity event: ActivitySpool.Event, nowMs: Int64) -> Bool {
        guard let agent = AgentID(rawValue: event.agent), !event.session.isEmpty else { return false }
        let ms = min(event.tsMs, nowMs)
        guard ms > 0 else { return false }
        let key = RowIdentity.session(agent: agent, session: event.session)
        let before = sessions[key]
        var session: Session
        if let before {
            guard ms > before.activityMs else { return false }
            session = before
        } else {
            guard nowMs - ms <= Self.activityIntroductionMs else { return false }
            session = Session(key: key, agent: agent, session: event.session, stateSinceMs: ms, startedMs: ms)
        }
        Self.settleHeldTurn(&session, nowMs: ms)
        session.activityMs = ms
        session.lastEventMs = max(session.lastEventMs, ms)
        if session.startedMs == 0 || ms < session.startedMs { session.startedMs = ms }
        let cwd = ContentSanitizer.redact(event.cwd)
        if session.cwd.isEmpty, !cwd.isEmpty { session.cwd = cwd }
        if ms > session.stateSinceMs || before == nil {
            switch session.state {
            case .working:
                break
            case .blocked(let block):
                if Self.answers(event, block) { Self.answer(&session, at: ms) }
            case .idle, .yourTurn, .ended:
                Self.set(&session, .working, at: ms)
            }
        }
        sessions[key] = session
        return session != before
    }

    /// Whether an activity event answers a block: a prompt always does; a
    /// tool does unless both name a tool and the names differ (a parallel
    /// tool finishing is not the answer).
    static func answers(_ event: ActivitySpool.Event, _ block: Block) -> Bool {
        if event.event == "prompt" { return true }
        let tool = event.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        if tool.isEmpty || block.tool.isEmpty { return true }
        return tool.caseInsensitiveCompare(block.tool) == .orderedSame
    }

    // MARK: - Processes

    /// The process `pid` exited: every live session it ran has ended.
    @discardableResult
    mutating func processExited(pid: Int32, atMs: Int64) -> Bool {
        guard pid > 0 else { return false }
        var changed = false
        for (key, session) in sessions where session.pid == pid && !session.isEnded {
            var copy = session
            Self.set(&copy, .ended(atMs: max(atMs, session.lastEventMs)), at: max(atMs, session.lastEventMs))
            sessions[key] = copy
            changed = true
        }
        return changed
    }

    /// Ends every live session whose process is gone — found at a launch or
    /// a scan, not seen exiting, so it ended when it was last heard from.
    @discardableResult
    mutating func endSessions(whosePidIsDead isAlive: (Int32) -> Bool) -> Bool {
        var changed = false
        for (key, session) in sessions where session.pid > 0 && !session.isEnded && !isAlive(session.pid) {
            var copy = session
            Self.set(&copy, .ended(atMs: session.lastEventMs), at: session.lastEventMs)
            sessions[key] = copy
            changed = true
        }
        return changed
    }

    /// The pids of live sessions — what the exit watch follows.
    var livePids: Set<Int32> {
        Set(sessions.values.filter { $0.pid > 0 && !$0.isEnded }.map(\.pid))
    }

    // MARK: - Bounds

    /// Drops sessions quiet for longer than `retentionMs`, and keeps at most
    /// `maxSessions` (ended ones go first, then the quietest).
    @discardableResult
    mutating func prune(nowMs: Int64) -> Bool {
        let before = sessions
        sessions = sessions.filter { nowMs - $0.value.lastEventMs <= Self.retentionMs }
        if sessions.count > Self.maxSessions {
            let keep = sessions.values
                .sorted { a, b in
                    if a.isEnded != b.isEnded { return !a.isEnded }
                    return (a.lastEventMs, a.key) > (b.lastEventMs, b.key)
                }
                .prefix(Self.maxSessions)
                .map(\.key)
            let kept = Set(keep)
            sessions = sessions.filter { kept.contains($0.key) }
        }
        return sessions != before
    }
}

/// 24.0 · the book as tray rows: one row per session worth showing, plus a
/// process-only row for each agent process no session has claimed. Pure.
///
/// Time rules, said by `Explain`:
///
/// - a session whose pid is known stays in its state while the process
///   lives (an exit ends it); with no pid, a session quiet for `idleBoundMs`
///   is shown as recent — Pulse cannot tell it is still there;
/// - a turn is owed for `idleBoundMs`, then it is recent;
/// - a recent session (idle, ended, or past the bound) stays listed for
///   `recentWindowMs` after its last event, or while its process lives; then
///   it is counted as "older, not shown" for a day.
enum SessionProjection {
    static let idleBoundMs: Int64 = 30 * 60 * 1000
    static let recentWindowMs: Int64 = 45 * 60 * 1000
    /// Hidden sessions are counted only within this window.
    static let staleHiddenWindowMs: Int64 = 24 * 60 * 60 * 1000

    struct Context {
        var nowMs: Int64
        /// Settings → terminal control: AppleScript landing steps allowed.
        var allowAutomation = false
        /// Seconds of silence that make a working session stalled; 0 off.
        var stalledSeconds: Double = AgentRow.stalledSeconds
    }

    struct Output: Equatable {
        var rows: [AgentRow] = []
        /// Sessions left out for age, per agent (last 24 h only).
        var staleHidden: [AgentID: Int] = [:]
    }

    static func rows(
        book: SessionBook,
        processes: [AgentProcesses.Hit],
        transcripts: [String: TranscriptSummary],
        context: Context
    ) -> Output {
        let nowMs = context.nowMs
        var out = Output()
        var claimed: [AgentID: [SessionBook.Session]] = [:]
        let byPid = Dictionary(processes.flatMap { hit in hit.family.map { ($0, hit) } }, uniquingKeysWith: { first, _ in first })

        for session in book.sessions.values.sorted(by: { $0.key < $1.key }) {
            let live = session.pid > 0 && !session.isEnded
            if !session.isEnded { claimed[session.agent, default: []].append(session) }
            var row = AgentRow(rowKey: session.key, agent: session.agent)
            row.sessionID = session.session
            row.attentionSession = session.session
            row.cwd = session.cwd
            row.project = AgentRow.shortProject(session.cwd)
            row.pid = Int(session.pid)
            row.liveProcess = live
            row.startedMs = session.startedMs
            row.eventMs = session.lastEventMs
            row.activityMs = session.activityMs
            row.source = .hooks
            row.state = state(of: session, nowMs: nowMs)
            row.stateSinceMs = stateSince(of: session, nowMs: nowMs)
            row.recentReason = recentReason(of: session)

            let visible = live || nowMs - session.lastEventMs <= recentWindowMs || !row.isRecent
            guard visible else {
                if nowMs - session.lastEventMs <= staleHiddenWindowMs {
                    out.staleHidden[session.agent, default: 0] += 1
                }
                continue
            }

            if let summary = transcripts[session.transcript], !session.transcript.isEmpty {
                row.task = summary.title
                row.model = summary.model
                row.lastWord = summary.lastMessage
                row.lastErrorText = summary.lastError
            }
            if row.lastWord.isEmpty { row.lastWord = firstLine(session.message) }

            // How to reach it: the hook's landing handle first; the process
            // table fills only what the hook did not say.
            var landing = LandingHandle(session.landing)
            let hit = live ? byPid[session.pid] : nil
            if let hit {
                if landing.tty.isEmpty { landing.tty = LandingHandle.normalizeTTY(hit.tty) }
                if landing.term.isEmpty, hit.viaWarp { landing.term = "WarpTerminal" }
            }
            row.landing = landing
            row.landingPlan = LandingPlan.make(
                handle: landing, cwd: row.cwd, allowAutomation: context.allowAutomation,
                pid: live ? session.pid : 0, hostApp: hit?.hostApp
            )

            // Silence is evidence only from an agent whose hook reports
            // every tool call; the others are silent through every long turn.
            row.isStalled = row.state == .running
                && session.agent.reportsToolActivity
                && session.activityMs > 0
                && AgentRow.stalled(lastActivityMs: session.lastEventMs, nowMs: nowMs, threshold: context.stalledSeconds)
            out.rows.append(row)
        }

        for hit in processes {
            let sessions = claimed[hit.agent] ?? []
            let owned = sessions.contains { session in
                (session.pid > 0 && hit.family.contains(session.pid))
                    || (session.pid == 0 && !session.cwd.isEmpty && session.cwd == hit.cwd)
            }
            guard !owned else { continue }
            var row = AgentRow(rowKey: RowIdentity.process(agent: hit.agent, pid: Int(hit.pid)), agent: hit.agent)
            row.cwd = hit.cwd
            row.project = AgentRow.shortProject(hit.cwd)
            row.pid = Int(hit.pid)
            row.liveProcess = true
            row.landing = LandingHandle(
                tty: LandingHandle.normalizeTTY(hit.tty),
                term: hit.viaWarp ? "WarpTerminal" : ""
            )
            row.landingPlan = LandingPlan.make(
                handle: row.landing, cwd: row.cwd, allowAutomation: context.allowAutomation,
                pid: hit.pid, hostApp: hit.hostApp
            )
            row.startedMs = hit.startedMs
            row.stateSinceMs = hit.startedMs
            row.source = .process
            row.state = .processOnly
            out.rows.append(row)
        }
        return out
    }

    /// The row state for a session at `nowMs`.
    static func state(of session: SessionBook.Session, nowMs: Int64) -> RowState {
        let quiet = nowMs - session.lastEventMs > idleBoundMs
        let unknownPid = session.pid <= 0
        switch session.state {
        case .blocked(let block):
            if unknownPid, quiet { return .recent }
            return .blocked(RowWait(kind: waitKind(block.kind), ask: block.ask, sinceMs: block.sinceMs, inFront: block.inFront))
        case .working:
            if unknownPid, quiet { return .recent }
            return .running
        case .yourTurn(let since):
            if nowMs - since > idleBoundMs { return .recent }
            return .yourTurn(sinceMs: since)
        case .idle, .ended:
            return .recent
        }
    }

    /// Why a session projected as recent is: ended, at its prompt, or
    /// quiet past the idle bound with no process Pulse can see.
    static func recentReason(of session: SessionBook.Session) -> RecentReason {
        switch session.state {
        case .ended: return .ended
        case .idle, .yourTurn: return .atPrompt
        case .working, .blocked: return .quiet
        }
    }

    /// When the row entered the state `state(of:nowMs:)` gives: the
    /// session's own state clock, or — when a time rule moved it to recent —
    /// the moment the rule did.
    static func stateSince(of session: SessionBook.Session, nowMs: Int64) -> Int64 {
        switch (session.state, state(of: session, nowMs: nowMs)) {
        case (.yourTurn(let since), .recent): return since + idleBoundMs
        case (.blocked, .recent), (.working, .recent): return session.lastEventMs + idleBoundMs
        default: return session.stateSinceMs
        }
    }

    /// The protocol kind as the token `RowWait` carries (`L10n.waitKind`).
    static func waitKind(_ kind: AttentionKind) -> String {
        switch kind {
        case .permission: return "Permission"
        case .question: return "Input"
        default: return "Waiting"
        }
    }

    static func firstLine(_ raw: String) -> String {
        TranscriptSummaryReader.firstLine(raw)
    }
}
