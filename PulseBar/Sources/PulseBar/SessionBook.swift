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
///   A turn within `stopGraceMs` of a block does not clear it (the vendors'
///   event order is not ours), and a turn the person watched finish (`front`)
///   is owed to nobody.
/// - **An answer arrives as activity**: nothing writes `done` when a
///   permission is granted in the vendor's own prompt — the next tool call
///   (or prompt) stamped after the raise is the answer.
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
        note(record, ms: ms, into: &session)

        switch kind {
        case .start:
            // A start mid-work (a resume, a compaction) says nothing about
            // the work; otherwise the session is at its prompt.
            if session.state != .working { set(&session, .idle, at: ms) }
        case .working:
            set(&session, .working, at: ms)
        case .permission, .question, .waiting:
            var ask = ContentSanitizer.redact(record.message)
            // One approval is often raised twice (Claude's Notification and
            // PermissionRequest); a later raise with no words keeps the
            // earlier one's.
            if ask.isEmpty, case .blocked(let open) = session.state { ask = open.ask }
            set(&session, .blocked(Block(kind: kind, ask: ask, sinceMs: ms, inFront: record.front == true)), at: ms)
        case .turn:
            let message = ContentSanitizer.redact(record.message)
            if !message.isEmpty { session.message = message }
            if case .blocked(let block) = session.state, ms - block.sinceMs < Self.stopGraceMs {
                break
            }
            // The person watched it finish: nothing is owed.
            set(&session, record.front == true ? .idle : .yourTurn(sinceMs: ms), at: ms)
        case .done:
            _ = clear(&session, at: ms)
        case .end:
            set(&session, .ended(atMs: ms), at: ms)
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
        if kind == .turn, session.isEmpty { return nil }
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

    private func set(_ session: inout Session, _ state: State, at ms: Int64) {
        session.state = state
        session.stateSinceMs = ms
    }

    /// `done`: a block is answered (work goes on), a turn is seen (the
    /// session is at its prompt). Anything else is left as it is.
    private func clear(_ session: inout Session, at ms: Int64) -> Bool {
        switch session.state {
        case .blocked:
            set(&session, .working, at: ms)
            return true
        case .yourTurn:
            set(&session, .idle, at: ms)
            return true
        case .idle, .working, .ended:
            return false
        }
    }

    private mutating func resolve(_ key: String, at ms: Int64) -> Bool {
        guard var session = sessions[key], clear(&session, at: ms) else { return false }
        session.lastEventMs = max(session.lastEventMs, ms)
        sessions[key] = session
        return true
    }

    // MARK: - Activity events

    /// A tool ran or a prompt was submitted (the activity spool). Stamped
    /// after the current state began, it says the session is working: a
    /// block was answered in the vendor's prompt, a turn was taken up again,
    /// a session at its prompt got going. Idempotent — the spool is re-read
    /// whole, and an event no newer than the last one changes nothing.
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
        session.activityMs = ms
        session.lastEventMs = max(session.lastEventMs, ms)
        if session.startedMs == 0 || ms < session.startedMs { session.startedMs = ms }
        let cwd = ContentSanitizer.redact(event.cwd)
        if session.cwd.isEmpty, !cwd.isEmpty { session.cwd = cwd }
        if ms > session.stateSinceMs || before == nil {
            if session.state != .working { set(&session, .working, at: ms) }
        }
        sessions[key] = session
        return session != before
    }

    // MARK: - Processes

    /// The process `pid` exited: every live session it ran has ended.
    @discardableResult
    mutating func processExited(pid: Int32, atMs: Int64) -> Bool {
        guard pid > 0 else { return false }
        var changed = false
        for (key, session) in sessions where session.pid == pid && !session.isEnded {
            var copy = session
            set(&copy, .ended(atMs: max(atMs, session.lastEventMs)), at: max(atMs, session.lastEventMs))
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
            set(&copy, .ended(atMs: session.lastEventMs), at: session.lastEventMs)
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

            row.isStalled = row.state == .running
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
