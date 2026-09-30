import Foundation

/// The event core: every session Pulse knows, the one state each is in, and
/// what its events said about it — from the agents' own hook events.
///
/// Pulse reads no vendor session file. Each supported agent's hook appends
/// one v5 line to the event log (`EventLog`) when a session starts, takes a
/// prompt, runs a tool, is blocked, finishes its turn or ends; a process exit
/// ends a session. This is the reducer those lines feed, in file order — a
/// pure value, `apply` in, `sessions` out — and `TrayState.project` turns it
/// into what the tray draws. At launch the engine replays the whole log
/// through it before the first projection, so everything here — the steps,
/// the title, the turn's clock — is rebuilt from the log and never kept
/// anywhere else.
///
/// What a session says about itself, from its events only:
///
/// - **steps**: the last `maxSteps` tool lines that named their tool (the
///   tool, its target, when), and the clock of the prompt that started the
///   current turn — the row's quiet "last step" and its turn's duration;
/// - **title**: the first prompt that says something (not "continue"), and
///   the latest prompt;
/// - **last words**: what the latest turn line carried; **error**: the text
///   of a turn that ended on an error (`tool` = `error`), until the next
///   turn starts (a prompt, or work after the turn ended). Tokens, context,
///   cost and model are never read — a decision.
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
///   permission is granted in the vendor's own prompt — the next `tool` line
///   (or prompt) stamped after the raise is the answer. When the block and
///   the tool line both name their tool, only that tool answers it: a
///   parallel tool finishing is not the person saying yes, and a `status`
///   line (a retry, a recoverable error) is no answer at all. Every line is
///   applied, so a parallel tool written after the answer no longer
///   hides it.
/// - **`done`** (the vendor's "resolved", or a dismissal in Pulse) clears the
///   session it names; an empty session clears only the agent's session-less
///   session in the folder it names (every session-less one of the agent
///   when it names none), never one that has an id. The same block said
///   again right after (same kind, inside the first raise's grace, no work
///   since) stays cleared.
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

    /// The block a `done` cleared last — a dismissal in Pulse or the
    /// vendor's "resolved" — and when.
    struct ClearedBlock: Equatable, Sendable {
        var kind: AttentionKind
        var ask: String
        var sinceMs: Int64
        var clearedMs: Int64
    }

    /// One tool step, as its `tool` line said it: the tool (`Bash`), its
    /// target (`swift test`, sanitized; "" when the hook did not say) and
    /// when it was reported. A past step — never a claim that it still runs.
    struct Step: Hashable, Sendable {
        var tool: String
        var target: String
        var ms: Int64
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
        /// The first event that named the current `pid` — a process that
        /// started after it is not that process (a reused pid).
        var pidSinceMs: Int64 = 0
        /// Where the session can be reached (`tmux:…;tty:…;term:…`).
        var landing = ""
        var state: State = .idle
        /// When the current state began, by the event's clock.
        var stateSinceMs: Int64 = 0
        /// The first event seen.
        var startedMs: Int64 = 0
        /// The newest event of any kind.
        var lastEventMs: Int64 = 0
        /// The newest activity (a `tool` line, or a prompt).
        var activityMs: Int64 = 0
        /// The newest tool event — the only evidence a silence can be a stall.
        var toolMs: Int64 = 0
        /// What the latest turn line carried (a vendor's last words, when
        /// its hook sends them).
        var message = ""
        /// The text of the latest turn that ended on an error; cleared by
        /// the next prompt.
        var lastError = ""
        /// The first prompt that says something — the session's title.
        var title = ""
        /// The latest prompt's text.
        var lastPrompt = ""
        /// The prompt (or, with none seen, the step) that started the
        /// current turn; 0 unknown.
        var turnStartMs: Int64 = 0
        /// The last `maxSteps` tool steps, oldest first.
        var steps: [Step] = []
        /// A turn waiting out the grace of the current block.
        var heldTurn: HeldTurn?
        /// The block the last `done` cleared: the same block said again
        /// right after (Claude's `Notification` about six seconds after its
        /// `PermissionRequest`) with no work since is not raised again.
        var clearedBlock: ClearedBlock?

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
    /// Tool steps kept per session.
    static let maxSteps = 5
    /// A step's target is at most this many characters.
    static let stepTargetLimit = 120

    init() {}

    // MARK: - Events

    /// One event line, in file order. Returns whether anything changed.
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
        case .done where spelled.isEmpty:
            // An empty `done` clears the agent's session-less entries only:
            // the one of the folder it names, or — naming none — every one.
            let folder = record.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            let folderKey = RowIdentity.session(agent: agent, session: "", cwd: record.cwd)
            let redacted = ContentSanitizer.redact(folder)
            var changed = false
            for key in sessions.keys.sorted() {
                guard let session = sessions[key], session.agent == agent, session.session.isEmpty else { continue }
                if !folder.isEmpty, key != folderKey, session.cwd != redacted { continue }
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
            session.activityMs = max(session.activityMs, ms)
            Self.prompt(record.message, at: ms, into: &session)
            Self.answer(&session, at: ms)
        case .tool:
            session.activityMs = max(session.activityMs, ms)
            session.toolMs = max(session.toolMs, ms)
            Self.step(record, at: ms, into: &session)
            // Work goes on — unless it is older than the state it would
            // end, or a different tool than the one a block is about.
            if ms > session.stateSinceMs || before == nil {
                switch session.state {
                case .working:
                    break
                case .blocked(let block):
                    if Self.answers(tool: record.tool, block) { Self.answer(&session, at: ms) }
                case .idle, .yourTurn, .ended:
                    // A turn whose prompt Pulse did not see starts here;
                    // the error of the last one is over.
                    session.turnStartMs = ms
                    session.lastError = ""
                    Self.set(&session, .working, at: ms)
                }
            }
        case .permission, .question, .waiting:
            Self.raise(kind, record: record, at: ms, in: &session)
        case .turn:
            let message = TitleHeuristics.firstLine(record.message)
            if record.tool == AttentionRecord.errorTool {
                if !message.isEmpty { session.lastError = message }
            } else if !message.isEmpty {
                session.message = message
            }
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
        }
        sessions[key] = session
        return session != before
    }

    /// A session an event names for the first time — unless the event says
    /// nothing is going on (a `done` or an `end` for a session never seen).
    private func introduce(key: String, agent: AgentID, session: String, kind: AttentionKind, ms: Int64) -> Session? {
        if kind == .done || kind == .end { return nil }
        // A turn or a tool with no identity has no session to belong to.
        if kind == .turn || kind == .idle || kind == .tool, session.isEmpty { return nil }
        return Session(key: key, agent: agent, session: session, stateSinceMs: ms, startedMs: ms)
    }

    private func note(_ record: AttentionRecord, ms: Int64, into session: inout Session) {
        let cwd = ContentSanitizer.redact(record.cwd)
        if !cwd.isEmpty { session.cwd = cwd }
        if record.pid > 1, record.pid != session.pid {
            session.pid = record.pid
            session.pidSinceMs = ms
        } else if record.pid > 1, ms < session.pidSinceMs {
            session.pidSinceMs = ms
        }
        if !record.landing.isEmpty { session.landing = record.landing }
        if session.startedMs == 0 || ms < session.startedMs { session.startedMs = ms }
        session.lastEventMs = max(session.lastEventMs, ms)
    }

    /// A prompt: a new turn. Its text is the latest prompt, and the title
    /// when the session has none yet and it says something. The error of
    /// the last turn is over.
    private static func prompt(_ raw: String, at ms: Int64, into session: inout Session) {
        session.turnStartMs = ms
        session.lastError = ""
        let text = TitleHeuristics.promptTitle(raw)
        guard !text.isEmpty else { return }
        session.lastPrompt = text
        if session.title.isEmpty, TitleHeuristics.isMeaningful(text) { session.title = text }
    }

    /// A `tool` line that names its tool is a step (a `status` line is
    /// not). Lines are applied in file order, so the last `maxSteps` are
    /// the newest.
    private static func step(_ record: AttentionRecord, at ms: Int64, into session: inout Session) {
        let tool = record.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tool.isEmpty, !AttentionRecord.isStatus(tool: tool) else { return }
        var target = TitleHeuristics.firstLine(record.message, limit: stepTargetLimit)
        if target.caseInsensitiveCompare(tool) == .orderedSame { target = "" }
        session.steps.append(Step(tool: String(tool.prefix(64)), target: target, ms: ms))
        if session.steps.count > maxSteps { session.steps.removeFirst(session.steps.count - maxSteps) }
    }

    /// A blocked event. A re-raise of the same kind inside the grace is the
    /// same block said again (Claude's `PermissionRequest`, then its
    /// `Notification` about six seconds later): it keeps the earlier clock,
    /// and the more specific of the two asks (`askSpecificity`) — the
    /// earlier one on a tie — with its tool. A later raise with no words
    /// keeps the earlier ones'. The same block said again after a `done`
    /// cleared it (a dismissal between the two) is not raised again: same
    /// kind, inside the grace of the first raise, no work since the clear,
    /// and words that say nothing new (the same ask, or only a generic
    /// "needs your permission").
    private static func raise(_ kind: AttentionKind, record: AttentionRecord, at ms: Int64, in session: inout Session) {
        var block = Block(
            kind: kind,
            ask: ContentSanitizer.redact(record.message),
            sinceMs: ms,
            inFront: record.front == true
        )
        let named = record.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        block.tool = named.isEmpty ? blockedTool(block.ask) : named
        if let cleared = session.clearedBlock, cleared.kind == kind,
           abs(ms - cleared.sinceMs) < Self.stopGraceMs,
           session.activityMs <= cleared.clearedMs,
           block.ask == cleared.ask || askSpecificity(block.ask, tool: block.tool) <= 1 {
            return
        }
        var held: HeldTurn?
        if case .blocked(let open) = session.state {
            if open.kind == kind, abs(ms - open.sinceMs) < Self.stopGraceMs {
                if askSpecificity(block.ask, tool: block.tool) <= askSpecificity(open.ask, tool: open.tool) {
                    block.ask = open.ask
                    if !open.tool.isEmpty { block.tool = open.tool }
                } else if block.tool.isEmpty {
                    block.tool = open.tool
                }
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
    /// descriptor (`Tool` or `Tool: target`) — `AttentionProtocol.blockedTool`.
    static func blockedTool(_ ask: String) -> String {
        AttentionProtocol.blockedTool(ask)
    }

    /// How much an ask says: 0 nothing; 1 only which tool, or a vendor's
    /// generic "needs your permission / input" line; 2 what is actually
    /// asked (a command, a path, a question).
    static func askSpecificity(_ ask: String, tool: String) -> Int {
        let text = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return 0 }
        if !tool.isEmpty, text.caseInsensitiveCompare(tool) == .orderedSame { return 1 }
        if blockedTool(text) == text { return 1 }
        let lower = text.lowercased()
        let generic = ["needs your permission", "needs your input", "needs your attention", "waiting for your input"]
        if generic.contains(where: { lower.contains($0) }) { return 1 }
        return 2
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
        case .blocked(let block):
            session.clearedBlock = ClearedBlock(kind: block.kind, ask: block.ask, sinceMs: block.sinceMs, clearedMs: ms)
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

    /// Whether a `tool` line answers a block: it does unless both name a
    /// tool and the names differ (a parallel tool finishing is not the
    /// answer), or the line is a `status` (work going on — a retry, a
    /// recoverable error — is not the person answering).
    static func answers(tool raw: String, _ block: Block) -> Bool {
        let tool = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if AttentionRecord.isStatus(tool: tool) { return false }
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
        endSessions(whoseProcessIsGone: { !isAlive($0.pid) })
    }

    /// Ends every live session with a pid for which `gone` says its process
    /// is not there any more — dead, or the pid now belongs to a
    /// different process (`AgentProcesses.stillRuns`).
    @discardableResult
    mutating func endSessions(whoseProcessIsGone gone: (Session) -> Bool) -> Bool {
        var changed = false
        for (key, session) in sessions where session.pid > 0 && !session.isEnded && gone(session) {
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
