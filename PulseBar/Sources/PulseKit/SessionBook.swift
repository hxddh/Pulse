import Foundation

/// The event core: every session Pulse knows, the one state each is in, and
/// what its events said about it — from the agents' own hook events.
///
/// Pulse reads no vendor session file. Each supported agent's hook appends
/// one v7 line to the event log (`EventLog`) when a session starts, takes a
/// prompt, runs a tool, is blocked, finishes its turn or ends; a process exit
/// ends a session. This is the reducer those lines feed, in `seq` order — a
/// pure value, `apply` in, `sessions` out — and `TrayState.project` turns it
/// into what the tray draws. At launch the engine replays the whole log
/// through it before the first projection, so everything here — the steps,
/// the title, the turn's clock — is rebuilt from the log and never kept
/// anywhere else. The quick facts a row's second line and the detail page
/// say (`SessionFacts`) are read from here at render time (`facts(for:)`):
/// they are not part of the projection.
///
/// What a session says about itself, from its events only:
///
/// - **steps**: the last `maxSteps` tool lines that named their tool (the
///   tool, its target, when), and the clock of the prompt that started the
///   current turn — the row's quiet "last step" and its turn's duration;
/// - **title**: the first prompt that says something (not "continue"), and
///   the latest prompt;
/// - **last words**: what the latest turn line carried; **error**: the text
///   of a turn that ended on an error (a `failed` line), until the next turn
///   starts (a prompt, or work after the turn ended). Tokens, context,
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
/// - **`done`** (the vendor's "resolved") and **`dismiss`** (Pulse's own)
///   clear the session they name; an empty session clears only the agent's
///   session-less session in the folder it names (every session-less one of
///   the agent when it names none), never one that has an id. After a
///   `dismiss` the same block said again right after (same kind, inside the
///   first raise's grace, no work since) stays cleared; after the vendor's
///   `done` it is raised again.
/// - **`ignored`** lines are skipped: they record what the receiver heard,
///   not a state.
/// - **An exit ends a session**: a process exit (kqueue) or a pid found dead
///   ends every live session that pid ran. Nothing here guesses "running".
package struct SessionBook: Equatable {
    /// What a session is doing, as its events said.
    package enum State: Equatable, Sendable {
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

    /// A turn that arrived within `stopGraceMs` of a block: held, never
    /// dropped.
    package struct HeldTurn: Equatable, Sendable {
        package var ms: Int64
        package var front: Bool
    }

    /// The block a dismissal in Pulse (a `dismiss` line) cleared last, and
    /// when.
    package struct ClearedBlock: Equatable, Sendable {
        package var kind: AttentionKind
        package var ask: String
        package var sinceMs: Int64
        package var clearedMs: Int64
    }

    /// One tool step, as its `tool` line said it: the tool (`Bash`), its
    /// target (`swift test`, sanitized; "" when the hook did not say) and
    /// when it was reported. A past step — never a claim that it still runs.
    package struct Step: Hashable, Sendable {
        package var tool: String
        package var target: String
        package var ms: Int64
    }

    package struct Session: Equatable, Sendable {
        /// Decided by the first event, never changed.
        package var key: SessionKey
        package var agent: AgentID { key.agent }
        /// The session exactly as the events spell it ("" for a
        /// folder-keyed one) — what a `dismiss` must carry.
        package var session: String
        package var cwd = ""
        /// The agent process the hook ran under; 0 unknown.
        package var pid: Int32 = 0
        /// The first event that named the current `pid` — a process that
        /// started after it is not that process (a reused pid).
        package var pidSinceMs: Int64 = 0
        /// Where the session can be reached (`tmux:…;tty:…;term:…`).
        package var landing = ""
        package var state: State = .idle
        /// When the current state began, by the event's clock.
        package var stateSinceMs: Int64 = 0
        /// The first event seen.
        package var startedMs: Int64 = 0
        /// The newest event of any kind.
        package var lastEventMs: Int64 = 0
        /// The newest activity (a `tool` line, or a prompt).
        package var activityMs: Int64 = 0
        /// The newest tool event — the only evidence a silence can be a stall.
        package var toolMs: Int64 = 0
        /// What the latest turn line carried (a vendor's last words, when
        /// its hook sends them).
        package var message = ""
        /// The text of the latest `failed` turn; cleared by the next turn.
        package var lastError = ""
        /// The first prompt that says something — the session's title.
        package var title = ""
        /// The latest prompt's text.
        package var lastPrompt = ""
        /// The prompt (or, with none seen, the step) that started the
        /// current turn; 0 unknown.
        package var turnStartMs: Int64 = 0
        /// The last `maxSteps` tool steps, oldest first.
        package var steps: [Step] = []
        /// A turn waiting out the grace of the current block.
        package var heldTurn: HeldTurn?
        /// The block the last dismissal in Pulse cleared: the same block
        /// said again right after (Claude's `Notification` about six seconds
        /// after its `PermissionRequest`) with no work since is not raised
        /// again. A vendor's own "resolved" `done` sets none — the same ask
        /// after it is a new ask.
        package var clearedBlock: ClearedBlock?

        package var isEnded: Bool {
            if case .ended = state { return true }
            return false
        }
    }

    package private(set) var sessions: [SessionKey: Session] = [:]

    /// A turn ending this soon after a block does not clear it.
    package static let stopGraceMs: Int64 = 20_000
    /// How far an event's stamp may run ahead of now before it is refused.
    package static let clockFutureToleranceMs: Int64 = 5 * 60 * 1000
    /// A session nothing has said anything about for this long is dropped.
    package static let retentionMs: Int64 = 24 * 60 * 60 * 1000
    package static let maxSessions = 256
    /// Tool steps kept per session.
    package static let maxSteps = 5
    /// A step's target is at most this many characters.
    package static let stepTargetLimit = 120

    package init() {}

    // MARK: - Events

    /// One event line, in `seq` order. Returns whether anything changed.
    @discardableResult
    package mutating func apply(_ record: AttentionRecord, nowMs: Int64) -> Bool {
        let kind = record.kind
        guard kind != .ignored, record.ms > 0, record.ms <= nowMs + Self.clockFutureToleranceMs else { return false }
        let agent = record.agent
        // No fake Waiting: an agent whose hooks cannot report a block is
        // never blocked, whoever wrote the line.
        if kind.isBlocking, agent.waitingSource == .none { return false }
        let ms = record.ms
        let spelled = record.session.trimmingCharacters(in: .whitespacesAndNewlines)
        let dismissal = kind == .dismiss

        if kind.isResolution, spelled.isEmpty {
            // An empty resolution clears the agent's session-less entries
            // only: the one of the folder it names, or — naming none — every
            // one.
            let folder = record.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            let folderKey = SessionKey(agent, "", cwd: record.cwd)
            let redacted = ContentSanitizer.redact(folder)
            var changed = false
            for key in sessions.keys.sorted() {
                guard let session = sessions[key], session.agent == agent, session.session.isEmpty else { continue }
                if !folder.isEmpty, key != folderKey, session.cwd != redacted { continue }
                changed = resolve(key, at: ms, dismissal: dismissal) || changed
            }
            return changed
        }

        let key = SessionKey(agent, spelled, cwd: record.cwd)
        let before = sessions[key]
        guard var session = before ?? introduce(key: key, session: spelled, kind: kind, ms: ms) else {
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
        case .tool, .status:
            session.activityMs = max(session.activityMs, ms)
            session.toolMs = max(session.toolMs, ms)
            if kind == .tool { Self.step(record, at: ms, into: &session) }
            // Work goes on — unless it is older than the state it would
            // end, or a different tool than the one a block is about.
            if ms > session.stateSinceMs || before == nil {
                switch session.state {
                case .working:
                    break
                case .blocked(let block):
                    if Self.answers(record, block) { Self.answer(&session, at: ms) }
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
        case .turn, .failed:
            let message = TitleHeuristics.firstLine(record.message)
            if !message.isEmpty {
                if kind == .failed { session.lastError = message } else { session.message = message }
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
        case .done, .dismiss:
            _ = Self.clear(&session, at: ms, dismissal: dismissal)
        case .end:
            Self.set(&session, .ended(atMs: ms), at: ms)
        case .ignored:
            return false
        }
        sessions[key] = session
        return session != before
    }

    /// A session an event names for the first time — unless the event says
    /// nothing is going on (a `done` or an `end` for a session never seen).
    private func introduce(key: SessionKey, session: String, kind: AttentionKind, ms: Int64) -> Session? {
        switch kind {
        case .done, .dismiss, .end, .ignored:
            return nil
        case .turn, .failed, .idle, .tool, .status:
            // With no identity there is no session to belong to.
            if session.isEmpty { return nil }
        case .start, .working, .permission, .question, .waiting:
            break
        }
        return Session(key: key, session: session, stateSinceMs: ms, startedMs: ms)
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

    /// A `tool` line that names its tool is a step. Lines are applied in
    /// order, so the last `maxSteps` are the newest.
    private static func step(_ record: AttentionRecord, at ms: Int64, into session: inout Session) {
        let tool = record.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tool.isEmpty else { return }
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
    /// keeps the earlier ones'. The same block said again after a dismissal
    /// in Pulse cleared it (a `dismiss` between the two) is not raised
    /// again: same kind, inside the grace of the first raise, no work since
    /// the clear, and words that say nothing new (the same ask, or only a
    /// generic "needs your permission").
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
    package static func blockedTool(_ ask: String) -> String {
        AttentionProtocol.blockedTool(ask)
    }

    /// How much an ask says: 0 nothing; 1 only which tool, or a vendor's
    /// generic "needs your permission / input" line; 2 what is actually
    /// asked (a command, a path, a question).
    package static func askSpecificity(_ ask: String, tool: String) -> Int {
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
    package static func settleHeldTurn(_ session: inout Session, nowMs: Int64) -> Bool {
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
    package mutating func settleHeldTurns(nowMs: Int64) -> Bool {
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
    private static func clear(_ session: inout Session, at ms: Int64, dismissal: Bool) -> Bool {
        if case .blocked = session.state, ms < session.stateSinceMs { return false }
        if case .yourTurn = session.state, ms < session.stateSinceMs { return false }
        switch session.state {
        case .blocked(let block):
            // Only Pulse's own dismissal is echoed by the vendor (Claude's
            // `Notification` after the `PermissionRequest` the person
            // dismissed). After the vendor's own "resolved" the same ask
            // again is a new ask, and is raised.
            session.clearedBlock = dismissal
                ? ClearedBlock(kind: block.kind, ask: block.ask, sinceMs: block.sinceMs, clearedMs: ms)
                : nil
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

    private mutating func resolve(_ key: SessionKey, at ms: Int64, dismissal: Bool) -> Bool {
        guard var session = sessions[key], Self.clear(&session, at: ms, dismissal: dismissal) else { return false }
        session.lastEventMs = max(session.lastEventMs, ms)
        sessions[key] = session
        return true
    }

    /// Whether an activity line answers a block: a `tool` line does unless
    /// both name a tool and the names differ (a parallel tool finishing is
    /// not the answer); a `status` line never does (work going on — a retry,
    /// a recoverable error — is not the person answering).
    package static func answers(_ record: AttentionRecord, _ block: Block) -> Bool {
        guard record.kind == .tool else { return false }
        let tool = record.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        if tool.isEmpty || block.tool.isEmpty { return true }
        return tool.caseInsensitiveCompare(block.tool) == .orderedSame
    }

    // MARK: - Processes

    /// The process `pid` exited: every live session it ran has ended.
    @discardableResult
    package mutating func processExited(pid: Int32, atMs: Int64) -> Bool {
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
    package mutating func endSessions(whosePidIsDead isAlive: (Int32) -> Bool) -> Bool {
        endSessions(whoseProcessIsGone: { !isAlive($0.pid) })
    }

    /// Ends every live session with a pid for which `gone` says its process
    /// is not there any more — dead, or the pid now belongs to a
    /// different process (`AgentProcesses.stillRuns`).
    @discardableResult
    package mutating func endSessions(whoseProcessIsGone gone: (Session) -> Bool) -> Bool {
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
    package var livePids: Set<Int32> {
        Set(sessions.values.filter { $0.pid > 0 && !$0.isEnded }.map(\.pid))
    }

    // MARK: - Facts

    /// What a session said lately, read at render time — never part of the
    /// projection, so a burst of tool lines moves no row. Empty for a key
    /// the book does not hold (a process-only row).
    package func facts(for key: SessionKey) -> SessionFacts {
        guard let session = sessions[key] else { return SessionFacts() }
        return SessionFacts(
            lastWords: session.message,
            lastError: session.lastError,
            steps: session.steps,
            turnStartMs: session.turnStartMs,
            lastEventMs: session.lastEventMs,
            activityMs: session.activityMs
        )
    }

    // MARK: - Bounds

    /// Drops sessions quiet for longer than `retentionMs`, and keeps at most
    /// `maxSessions` (ended ones go first, then the quietest).
    @discardableResult
    package mutating func prune(nowMs: Int64) -> Bool {
        let before = sessions
        sessions = sessions.filter { nowMs - $0.value.lastEventMs <= Self.retentionMs }
        if sessions.count > Self.maxSessions {
            let keep = sessions.values
                .sorted { a, b in
                    if a.isEnded != b.isEnded { return !a.isEnded }
                    if a.lastEventMs != b.lastEventMs { return a.lastEventMs > b.lastEventMs }
                    return a.key > b.key
                }
                .prefix(Self.maxSessions)
                .map(\.key)
            let kept = Set(keep)
            sessions = sessions.filter { kept.contains($0.key) }
        }
        return sessions != before
    }
}
