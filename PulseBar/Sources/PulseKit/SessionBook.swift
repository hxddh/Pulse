import Foundation

/// The event core: every session Pulse knows, the one state each is in, and
/// what its events said about it — from the agents' own hook events.
///
/// Pulse reads no vendor session file. Each supported agent's hook appends
/// one v9 line to the event log (`EventLog`) when a session starts, takes a
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
/// - **steps**: the last tool line that named its tool (the tool, its
///   target, when, whether it failed, how long it ran, which subagent ran
///   it), the tools `status` lines say are running now (each
///   until its own step), and the clock of the prompt that started the
///   current turn — the row's quiet "last step" and its turn's duration;
/// - **title**: the vendor's own name for the session when it has one (a
///   `title` line, or a `start` that carries it), else the first prompt
///   that says something (not "continue"); and the latest prompt;
/// - **this turn** (`TurnDigest`): the main agent's tools, the files,
///   skills and MCP servers the turn touched, each subagent's own steps —
///   started over with the turn, like its clock;
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
///   hides it. An agent whose module sends every reply
///   (`AgentSpec.stepsAnswerBlocks` false) is answered by the reply alone.
/// - **A block raised while no turn was live** (a background subagent's
///   ask after the turn ended) is answered back to where the session was —
///   your turn, or at its prompt — never into a turn nobody started.
/// - **`done`** (the vendor's "resolved") and **`dismiss`** (Pulse's own)
///   clear the session they name; an empty session clears only the agent's
///   session-less session in the folder it names (every session-less one of
///   the agent when it names none), never one that has an id. After a
///   `dismiss` the same block said again right after (same kind, inside the
///   first raise's grace, no work since) stays cleared; after the vendor's
///   `done` it is raised again.
/// - **`ignored`** lines change no state: they record what the receiver
///   heard. One that names a session the book holds goes on its timeline.
/// - **A subagent is not the person** (a line with `sub`): its line never
///   answers a block the main agent — or another subagent — raised, never
///   revives a turn that has ended (your turn and idle stay), and its prompt
///   is not the person's prompt (no title, no latest prompt, no turn clock);
///   its steps go on the timeline marked as its own. Only its own block is
///   answered by its activity, its `done` or its end of turn — and its
///   block is answered by no other speaker's step: only by its own lines,
///   a prompt, a `done`, a stop or the session's end. The main UI's notice
///   of its ask, right after it (Claude's `Notification`, which names no
///   subagent), is the same ask said again: it stays the subagent's.
/// - **An end is final for what came before it**: a turn, a prompt or a
///   step stamped no later than the session's end (lines numbered out of
///   order) revives nothing.
/// - **`stopped`**: the person stopped the run at the agent's prompt — the
///   session is at its prompt with nothing owed, and no last words.
/// - **Every line says where it came from**: the session keeps the vendor
///   event that put it in its current state (`stateEvent` — the why cites
///   it), its newest event (`lastEvent`) and its last `maxTimeline` heard
///   lines with what each did (`timeline`, the detail page's), all rebuilt
///   by the launch replay like everything else here.
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
        /// The vendor event of the held turn — the why's when it lands.
        package var event = ""
    }

    /// The state a block interrupted when no turn was live, with its clock,
    /// its vendor event and whether the person had stopped the run.
    package struct Interrupted: Equatable, Sendable {
        package var state: State
        package var sinceMs: Int64
        package var event: String
        package var stopped: Bool
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
        /// The tool reported it failed (`err`).
        package var failed = false
        /// How long it ran, in ms (`took`); 0 unknown.
        package var tookMs: Int64 = 0
        /// The subagent that ran it; "" for the main agent.
        package var sub = ""
        /// What kind of step it is (`cat`), as its adapter named the tool;
        /// nil when the line said none.
        package var category: StepCategory?
        /// A failed step's error, its first line (`meta` `err`); "" none.
        package var error = ""
    }

    /// A plan's progress as the main agent last reported it (`meta`
    /// `plan` / `planNow`): how many items are done, of how many, the one
    /// in progress, and when it said so.
    package struct PlanProgress: Hashable, Sendable {
        package var done: Int
        package var total: Int
        package var now: String
        package var ms: Int64

        package init(done: Int, total: Int, now: String = "", ms: Int64) {
            self.done = done
            self.total = total
            self.now = now
            self.ms = ms
        }
    }

    /// A subagent's type as its own lines said it (`meta` `type`).
    package struct SubagentType: Hashable, Sendable {
        package var sub: String
        package var type: String

        package init(sub: String, type: String) {
            self.sub = sub
            self.type = type
        }
    }

    /// One line a session heard, as its timeline says it: when, the
    /// vendor's own event name (`AttentionRecord.event`, unsanitized —
    /// `EventName.display` cleans it where it is drawn) and what the line
    /// did to the session.
    package struct Heard: Hashable, Sendable {
        package var ms: Int64
        package var event: String
        package var effect: Effect
        /// The subagent the line came from; "" for the main agent.
        package var sub: String
        /// How long a single step ran, in ms (`took`); 0 unknown, and 0
        /// for anything that is not one step.
        package var tookMs: Int64
        /// A single step's category (`cat`); nil for anything else, and for
        /// a run of steps.
        package var category: StepCategory?
        /// The facts the line carried (`meta`); empty for a run of steps.
        package var meta: LineMeta
        /// The steps behind a steps entry, oldest first: the step itself,
        /// or the newest `maxStepsPerEntry` of a run — each with its target,
        /// duration and failure, what the detail page discloses under the
        /// run's "Edit ×4". Empty for anything that is not steps. Kept
        /// beside the effect, never in it: what the entry *did* stays the
        /// effect's.
        package var steps: [Step]

        package init(
            ms: Int64, event: String, effect: Effect, sub: String = "", tookMs: Int64 = 0,
            category: StepCategory? = nil, meta: LineMeta = LineMeta(), steps: [Step] = []
        ) {
            self.ms = ms
            self.event = event
            self.effect = effect
            self.sub = sub
            self.tookMs = tookMs
            self.category = category
            self.meta = meta
            self.steps = steps
        }
    }

    /// Steps of one speaker, said as one timeline entry: a single step
    /// (its tool and target), or consecutive ones ("Edit ×4 · Bash ×2") —
    /// each tool once, in the order it first ran, with how many times; how
    /// many steps in all and how many failed. So the timeline's
    /// `maxTimeline` entries cover a whole turn, not its last dozen tool
    /// calls.
    package struct StepRun: Hashable, Sendable {
        package struct Tally: Hashable, Sendable {
            package var tool: String
            package var count: Int

            package init(tool: String, count: Int) {
                self.tool = tool
                self.count = count
            }
        }

        package var tools: [Tally]
        package var count: Int
        package var failed: Int
        /// A single step's target ("" when it said none); "" for a run.
        package var target: String

        package init(tools: [Tally] = [], count: Int = 0, failed: Int = 0, target: String = "") {
            self.tools = tools
            self.count = count
            self.failed = failed
            self.target = target
        }

        /// One step.
        package init(tool: String, target: String, failed: Bool) {
            self.init(tools: [Tally(tool: tool, count: 1)], count: 1, failed: failed ? 1 : 0, target: target)
        }

        /// One more step of `tool`: a run, which names no target.
        package mutating func add(_ tool: String, failed stepFailed: Bool) {
            count += 1
            if stepFailed { failed += 1 }
            target = ""
            if let index = tools.firstIndex(where: { $0.tool == tool }) {
                tools[index].count += 1
            } else {
                tools.append(Tally(tool: tool, count: 1))
            }
        }
    }

    /// What one heard line did, decided by the reducer as it applied it —
    /// never guessed from the event's name. How each is said, and how loud,
    /// is `Effect.text`, `.tone` and `.reportWord`.
    package enum Effect: Hashable, Sendable {
        /// The session started or resumed (`start`).
        case started
        /// A prompt started a turn (`working`).
        case prompt
        /// A tool ran (`step`), or consecutive steps of one speaker, as one
        /// entry — the timeline's grouping, decided as it is heard.
        case steps(StepRun)
        /// Activity that named no tool.
        case working
        /// Work goes on, no tool ran (`status`).
        case status
        /// A block was raised: the lamp went red.
        case raised(AttentionKind)
        /// The same block said again (a re-raise inside the grace, or the
        /// echo of a dismissed one): nothing new.
        case again
        /// The line ended the block: it was answered in the vendor's prompt.
        case answered
        /// The turn ended and nobody watched: your turn.
        case yourTurn
        /// The turn ended in front of the person (or at its prompt with
        /// nothing owed).
        case turnEnded
        /// The turn ended on an error.
        case failed
        /// A turn inside a block's grace: held, lands when the grace ends.
        case held
        /// It sat at its prompt; nothing new (`idle` after a seen turn).
        case atPrompt
        /// The vendor said its prompt closed (`done`).
        case resolved
        /// Set aside in Pulse (`pulse.dismiss`).
        case dismissed
        /// Its finished turn was looked at from Pulse (`pulse.seen`).
        case seen
        /// The person stopped the run at its prompt (`stopped`).
        case stopped
        /// The vendor named the session (`title`).
        case named
        /// A subagent's own lifecycle — its start, prompt, end of turn or
        /// end: the session's state did not move.
        case subagent
        /// The session ended.
        case ended
        /// Heard, and not turned into state — the receiver's reason
        /// (`PulseHookReceiver.Ignored` raw value).
        case skipped(reason: String)

        /// One step: its tool, its target, whether it failed.
        package static func step(tool: String, target: String, failed: Bool = false) -> Effect {
            .steps(StepRun(tool: tool, target: target, failed: failed))
        }
    }

    /// The lines a replay rebuilds a session's own facts from, by the `seq`
    /// each was applied with (0 none) — what a compaction keeps whatever its
    /// budget (`EventLog.compact`). None of `lines` raises anything.
    package struct Anchors: Equatable, Sendable {
        /// Its first line that raises nothing and can introduce it
        /// (`introduces`) — its first clock.
        package var first: Int64 = 0
        /// The prompt its title came from.
        package var title: Int64 = 0
        /// The line that started the current turn — its clock.
        package var turn: Int64 = 0
        /// The latest prompt that said something.
        package var prompt: Int64 = 0
        /// The line its vendor name came from.
        package var name: Int64 = 0
        /// The line the main agent's latest plan came from — the current
        /// turn's plan, when it reported one this turn.
        package var plan: Int64 = 0
        /// The raise that turned it red, while it is blocked — the open
        /// block's first line.
        package var block: Int64 = 0

        /// Every anchor but the block.
        package var lines: [Int64] { [first, title, turn, prompt, name, plan].filter { $0 > 0 } }
    }

    /// One session: who it is, where it runs, the one state it is in and
    /// the reducer's own bookkeeping; what it said lately is its `facts`,
    /// read and written through the session's own members
    /// (`session.lastEventMs` is `session.facts.lastEventMs`).
    @dynamicMemberLookup
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
        /// The newest tool event — the only evidence a silence can be a stall.
        package var toolMs: Int64 = 0
        /// The first prompt that says something — the session's title when
        /// the vendor has not named it.
        package var title = ""
        /// The vendor's own name for the session (a `title` line, or a
        /// `start` that carries one); "" none.
        package var name = ""
        /// A turn waiting out the grace of the current block.
        package var heldTurn: HeldTurn?
        /// Where the session was when the current block was raised while no
        /// turn was live (your turn, at its prompt): answered, it goes back
        /// there. Nil for a block raised during a turn.
        package var interrupted: Interrupted?
        /// The block the last dismissal in Pulse cleared: the same block
        /// said again right after (Claude's `Notification` about six seconds
        /// after its `PermissionRequest`) with no work since is not raised
        /// again. A vendor's own "resolved" `done` sets none — the same ask
        /// after it is a new ask.
        package var clearedBlock: ClearedBlock?
        /// What it said lately — its last words, step, clocks, events and
        /// timeline (`SessionFacts`).
        package var facts = SessionFacts()
        /// The lines its facts and its open block came from.
        package var anchors = Anchors()

        package subscript<T>(dynamicMember path: WritableKeyPath<SessionFacts, T>) -> T {
            get { facts[keyPath: path] }
            set { facts[keyPath: path] = newValue }
        }

        package subscript<T>(dynamicMember path: KeyPath<SessionFacts, T>) -> T {
            facts[keyPath: path]
        }

        package var isEnded: Bool {
            if case .ended = state { return true }
            return false
        }

        /// What the row calls the session: the vendor's name, else the
        /// first prompt that said something.
        package var shownTitle: String { name.isEmpty ? title : name }
    }

    package private(set) var sessions: [SessionKey: Session] = [:]

    /// A turn ending this soon after a block does not clear it.
    package static let stopGraceMs: Int64 = 20_000
    /// How far an event's stamp may run ahead of now before it is refused.
    package static let clockFutureToleranceMs: Int64 = 5 * 60 * 1000
    /// A session nothing has said anything about for this long is dropped.
    package static let retentionMs: Int64 = 24 * 60 * 60 * 1000
    package static let maxSessions = 256
    /// Running tools kept per session.
    package static let maxRunning = 8
    /// A step's target is at most this many characters.
    package static let stepTargetLimit = 120
    /// Heard lines kept per session — the detail page's timeline.
    package static let maxTimeline = 40
    /// Steps kept behind one timeline entry (`Heard.steps`).
    package static let maxStepsPerEntry = 8
    /// Subagent types kept per session.
    package static let maxSubagentTypes = 16

    package init() {}

    // MARK: - Events

    /// One event line, in `seq` order. Returns whether anything but the
    /// timeline changed — an `ignored` line, or one that moves nothing, is
    /// heard and changes nothing.
    @discardableResult
    package mutating func apply(_ record: AttentionRecord, nowMs: Int64) -> Bool {
        let kind = record.kind
        guard record.ms > 0, record.ms <= nowMs + Self.clockFutureToleranceMs else { return false }
        if kind == .ignored {
            hearIgnored(record)
            return false
        }
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
                changed = resolve(key, record: record) || changed
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
        let prior = session.state
        let event = record.event
        let sub = record.sub.trimmingCharacters(in: .whitespacesAndNewlines)

        if !sub.isEmpty {
            Self.applySubagent(record, sub: sub, at: ms, new: before == nil, into: &session)
            Self.digestFiles(record, into: &session)
            Self.hear(&session, Self.heard(record, effect: Self.effect(of: record, prior: prior, now: session), sub: sub))
            return land(session, record: record, before: before)
        }

        switch kind {
        case .start:
            // A start mid-work (a resume, a compaction) says nothing about
            // the work; otherwise the session is at its prompt.
            if session.state != .working { Self.set(&session, .idle, at: ms, event: event) }
            // A session the vendor already named (a resume).
            let name = TitleHeuristics.firstLine(record.message)
            if !name.isEmpty {
                session.name = name
                session.anchors.name = record.seq
            }
        case .working:
            session.activityMs = max(session.activityMs, ms)
            // A custom name riding on the prompt (Claude's `session_title`).
            let named = TitleHeuristics.firstLine(record.meta.name)
            if !named.isEmpty {
                session.name = named
                session.anchors.name = record.seq
            }
            Self.prompt(record, at: ms, into: &session)
            // A prompt stamped no later than the session's end is from
            // before it: it revives nothing.
            if !Self.endedBefore(session, ms) { Self.answer(&session, at: ms, event: event) }
        case .tool, .status:
            // A `status` that names no tool — a retry, a recoverable error, a
            // compaction — says work goes on: it keeps a live turn from
            // reading stalled, and never starts one. After the turn ended
            // (or before any was seen) it is heard and moves nothing.
            if kind == .status, before != nil, record.tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !Self.isLive(session.state) {
                break
            }
            // A tool said to start no later than the session's end runs
            // nothing now.
            if kind == .status, Self.endedBefore(session, ms) { break }
            session.activityMs = max(session.activityMs, ms)
            session.toolMs = max(session.toolMs, ms)
            Self.progress(record, at: ms, into: &session)
            // A reply that names no tool (Cursor's `afterAgentResponse`):
            // its words are the turn's last words so far — a turn line that
            // carries none keeps them.
            if kind == .tool, record.tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let words = TitleHeuristics.firstLine(record.message)
                if !words.isEmpty { session.lastWords = words }
            }
            // Work goes on — unless it is older than the state it would
            // end, or a different tool than the one a block is about.
            if ms > session.stateSinceMs || before == nil {
                switch session.state {
                case .working:
                    break
                case .blocked(let block):
                    if Self.answers(record, block) { Self.answer(&session, at: ms, event: event) }
                case .idle, .yourTurn, .ended:
                    // A turn whose prompt Pulse did not see starts here;
                    // the error of the last one is over, and its count is
                    // this line's step alone.
                    session.turnStartMs = ms
                    session.anchors.turn = record.seq
                    session.lastError = ""
                    session.failedTurn = false
                    let step = kind == .tool ? Self.stepOf(record) : nil
                    session.turnSteps = step == nil ? 0 : 1
                    session.turnFailedSteps = step?.failed == true ? 1 : 0
                    session.digest = TurnDigest()
                    if let step { session.digest.add(step, files: record.meta.files) }
                    Self.set(&session, .working, at: ms, event: event)
                }
            }
        case .permission, .question, .waiting:
            Self.raise(kind, record: record, at: ms, new: before == nil, in: &session)
        case .stopped:
            Self.stop(&session, at: ms, event: event)
        case .title:
            // The vendor's name for the session; an empty one clears it.
            session.name = TitleHeuristics.firstLine(record.message)
            session.anchors.name = record.seq
        case .turn, .failed:
            // A turn stamped no later than the session's end is from before
            // it (the lines were numbered out of order): heard, no state.
            if Self.endedBefore(session, ms) { break }
            let message = TitleHeuristics.firstLine(record.message)
            if !message.isEmpty {
                if kind == .failed { session.lastError = message } else { session.lastWords = message }
            }
            session.failedTurn = kind == .failed
            Self.turn(&session, at: ms, front: record.front == true, event: event)
        case .idle:
            // Sat at its prompt a while: news only if Pulse had not seen the
            // turn end (still working or blocked — an Esc on a prompt fires
            // no Stop — or a session met just now).
            switch session.state {
            case .working, .blocked:
                session.failedTurn = false
                Self.turn(&session, at: ms, front: record.front == true, event: event)
            case .idle where before == nil:
                Self.turn(&session, at: ms, front: record.front == true, event: event)
            case .idle, .yourTurn, .ended:
                break
            }
        case .done, .dismiss:
            _ = Self.clear(&session, at: ms, dismissal: dismissal, event: event)
        case .end:
            Self.set(&session, .ended(atMs: ms), at: ms, event: event)
        case .ignored:
            return false
        }
        Self.digestFiles(record, into: &session)
        Self.hear(&session, Self.heard(record, effect: Self.effect(of: record, prior: prior, now: session), sub: ""))
        return land(session, record: record, before: before)
    }

    /// The applied line's session goes back in the book, with its first
    /// clock when this is it. Returns whether anything but the timeline and
    /// the anchors changed.
    private mutating func land(_ session: Session, record: AttentionRecord, before: Session?) -> Bool {
        var session = session
        if session.anchors.first == 0, Self.introduces(record) { session.anchors.first = record.seq }
        sessions[session.key] = session
        guard var unheard = before else { return true }
        unheard.timeline = session.timeline
        unheard.anchors = session.anchors
        return unheard != session
    }

    /// Whether a line can introduce a session without raising anything —
    /// a session's first clock: a `start` or a prompt, or a turn, an idle or
    /// activity that names its session. Never a block (an answered one kept
    /// without its answer would be red again), a resolution, an `end`, a
    /// title or an ignored line.
    package static func introduces(_ record: AttentionRecord) -> Bool {
        switch record.kind {
        case .start, .working:
            return true
        case .turn, .failed, .idle, .tool, .status, .stopped:
            return !record.session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .permission, .question, .waiting, .done, .dismiss, .end, .title, .ignored:
            return false
        }
    }

    /// An `ignored` line: no state. When it names a session the book holds
    /// it goes on that session's timeline — never one it would make.
    private mutating func hearIgnored(_ record: AttentionRecord) {
        let spelled = record.session.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = SessionKey(record.agent, spelled, cwd: record.cwd)
        guard var session = sessions[key] else { return }
        Self.hear(&session, Heard(ms: record.ms, event: record.event, effect: .skipped(reason: record.message)))
        sessions[key] = session
    }

    /// A subagent's line (`sub` set). It never answers a block the main
    /// agent or another subagent raised, never revives a turn that has ended
    /// and is never the person's prompt; its own block is answered by its
    /// own activity, its `done` or its end of turn. A raise is a block of
    /// the session's (the subagent cannot go on, so neither can the work).
    private static func applySubagent(_ record: AttentionRecord, sub: String, at ms: Int64, new: Bool, into session: inout Session) {
        let event = record.event
        session.digest.hear(sub: String(sub.prefix(80)), type: record.meta.agentType, kind: record.kind)
        var owned: Block?
        if case .blocked(let block) = session.state, block.sub == String(sub.prefix(80)) { owned = block }
        let live: Bool
        switch session.state {
        case .working, .blocked: live = true
        case .idle, .yourTurn, .ended: live = false
        }
        switch record.kind {
        case .permission, .question, .waiting:
            raise(record.kind, record: record, at: ms, new: new, in: &session)
        case .tool, .status:
            // Work inside a live turn — never a turn of its own after the
            // person's has ended. A session met only now is working.
            guard live || new else { return }
            session.activityMs = max(session.activityMs, ms)
            session.toolMs = max(session.toolMs, ms)
            progress(record, at: ms, into: &session)
            guard ms > session.stateSinceMs || new else { return }
            if new, !live {
                set(&session, .working, at: ms, event: event)
            } else if let owned, answers(record, owned) {
                answer(&session, at: ms, event: event, restoring: true)
            }
        case .working:
            // Its own task, not the person's prompt.
            if live { session.activityMs = max(session.activityMs, ms) }
        case .done:
            if let owned, ms >= owned.sinceMs { answer(&session, at: ms, event: event, restoring: true) }
        case .turn, .failed, .idle, .stopped, .end:
            // The subagent is done: its own ask is over; the session's turn
            // goes on — or, raised after it ended, stays over.
            if let owned, ms >= owned.sinceMs { answer(&session, at: ms, event: event, restoring: true) }
        case .start, .title, .dismiss, .ignored:
            break
        }
    }

    /// A turn is going on: working, or blocked on the person.
    private static func isLive(_ state: State) -> Bool {
        switch state {
        case .working, .blocked: return true
        case .idle, .yourTurn, .ended: return false
        }
    }

    /// The session has ended, and a line stamped `ms` is from no later than
    /// its end.
    private static func endedBefore(_ session: Session, _ ms: Int64) -> Bool {
        session.isEnded && ms <= session.stateSinceMs
    }

    /// The person stopped the run (`stopped`): at its prompt, nothing owed,
    /// no held turn. A stop stamped before the block or turn it would end
    /// is about an earlier one.
    private static func stop(_ session: inout Session, at ms: Int64, event: String) {
        switch session.state {
        case .blocked, .yourTurn:
            guard ms >= session.stateSinceMs else { return }
            set(&session, .idle, at: ms, event: event)
            session.stopped = true
        case .working:
            set(&session, .idle, at: ms, event: event)
            session.stopped = true
        case .idle, .ended:
            break
        }
    }

    /// One heard line on the session's timeline; the oldest beyond
    /// `maxTimeline` goes.
    ///
    /// A step heard right after a step (or a run of them) of the same
    /// speaker joins it: one entry, "Edit ×4 · Bash ×2", at the newest
    /// line's clock and event. A single step keeps its own words, target
    /// and duration.
    private static func hear(_ session: inout Session, _ heard: Heard) {
        if let last = session.timeline.last, last.sub == heard.sub,
           case .steps(var run) = last.effect, case .steps(let next) = heard.effect, next.count == 1,
           let tool = next.tools.first?.tool {
            run.add(tool, failed: next.failed > 0)
            let steps = Array((last.steps + heard.steps).suffix(maxStepsPerEntry))
            session.timeline[session.timeline.count - 1] = Heard(
                ms: max(last.ms, heard.ms), event: heard.event, effect: .steps(run), sub: heard.sub, steps: steps
            )
            return
        }
        session.timeline.append(heard)
        if session.timeline.count > maxTimeline { session.timeline.removeFirst(session.timeline.count - maxTimeline) }
    }

    /// How long a `tool` line's step ran (`took`), for its timeline entry;
    /// 0 for any other line.
    private static func took(_ record: AttentionRecord) -> Int64 {
        record.kind == .tool ? max(0, record.tookMs) : 0
    }

    /// One applied line as its timeline entry: its effect, its speaker, its
    /// step's duration and category, and the facts it carried.
    private static func heard(_ record: AttentionRecord, effect: Effect, sub: String) -> Heard {
        var steps: [Step] = []
        if case .steps = effect, let step = stepOf(record) { steps = [step] }
        return Heard(
            ms: record.ms, event: record.event, effect: effect, sub: sub, tookMs: took(record),
            category: record.category, meta: record.meta, steps: steps
        )
    }

    /// The files a line that is not a step named (`meta` `files`: a
    /// batch's diff) go in the turn's digest; a step's own went in with it
    /// (`progress`).
    private static func digestFiles(_ record: AttentionRecord, into session: inout Session) {
        guard !record.meta.files.isEmpty, stepOf(record) == nil || record.kind != .tool else { return }
        session.digest.addFiles(record.meta.files)
    }

    /// What one applied line did, from the state before it (`prior`, after
    /// a held turn settled) and after it. Pure.
    private static func effect(of record: AttentionRecord, prior: State, now session: Session) -> Effect {
        var wasBlocked = false
        if case .blocked = prior { wasBlocked = true }
        var isBlocked = false
        if case .blocked = session.state { isBlocked = true }
        let answered = wasBlocked && !isBlocked
        if !record.sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A subagent's own lifecycle moves nothing but its own ask.
            switch record.kind {
            case .start, .working, .turn, .failed, .idle, .stopped, .title, .end:
                return answered ? .answered : .subagent
            default:
                break
            }
        }
        switch record.kind {
        case .start:
            return .started
        case .working:
            return answered ? .answered : .prompt
        case .tool:
            if answered { return .answered }
            guard let step = stepOf(record) else { return .working }
            return .step(tool: step.tool, target: step.target, failed: step.failed)
        case .status:
            return .status
        case .permission, .question, .waiting:
            // Not raised: the echo of a dismissed block. A re-raise of the
            // open block inside its grace (`raise` merges it): said again.
            guard case .blocked = session.state else { return .again }
            if case .blocked(let was) = prior, was.kind == record.kind,
               abs(record.ms - was.sinceMs) < stopGraceMs {
                return .again
            }
            return .raised(record.kind)
        case .turn, .failed, .idle:
            if isBlocked, session.heldTurn != nil { return .held }
            if record.kind == .failed { return .failed }
            if record.kind == .idle, session.state == prior { return .atPrompt }
            if case .yourTurn = session.state { return .yourTurn }
            return .turnEnded
        case .done:
            return .resolved
        case .dismiss:
            return record.event == AttentionRecord.seenEvent ? .seen : .dismissed
        case .stopped:
            return .stopped
        case .title:
            return .named
        case .end:
            return .ended
        case .ignored:
            return .skipped(reason: record.message)
        }
    }

    /// A session an event names for the first time — unless the event says
    /// nothing is going on (a `done` or an `end` for a session never seen).
    private func introduce(key: SessionKey, session: String, kind: AttentionKind, ms: Int64) -> Session? {
        switch kind {
        case .done, .dismiss, .end, .ignored, .title:
            return nil
        case .turn, .failed, .idle, .tool, .status, .stopped:
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
        if ms >= session.lastEventMs { session.lastEvent = record.event }
        session.lastEventMs = max(session.lastEventMs, ms)
        remember(record.meta, of: record, at: ms, into: &session)
    }

    /// The facts a line carried (`meta`), kept as the session's latest: the
    /// main agent's plan progress, why it started and why it ended, each
    /// subagent's type, the files a batch changed. A subagent's plan, start
    /// or end is not the session's.
    private func remember(_ meta: LineMeta, of record: AttentionRecord, at ms: Int64, into session: inout Session) {
        let speaker = String(record.sub.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        if speaker.isEmpty {
            if let plan = meta.plan, ms >= (session.plan?.ms ?? .min) {
                session.plan = PlanProgress(done: plan.done, total: plan.total, now: meta.planNow, ms: ms)
                session.anchors.plan = record.seq
            }
            if record.kind == .start, !meta.src.isEmpty { session.startSource = meta.src }
            if record.kind == .end, !meta.why.isEmpty { session.endReason = meta.why }
        } else if !meta.agentType.isEmpty {
            session.subagentTypes.removeAll { $0.sub == speaker }
            session.subagentTypes.append(SubagentType(sub: speaker, type: meta.agentType))
            if session.subagentTypes.count > Self.maxSubagentTypes {
                session.subagentTypes.removeFirst(session.subagentTypes.count - Self.maxSubagentTypes)
            }
        }
        if !meta.files.isEmpty { session.changedFiles = meta.files }
    }

    /// A prompt: a new turn. Its text is the latest prompt, and the title
    /// when the session has none yet and it says something. The error of
    /// the last turn is over.
    private static func prompt(_ record: AttentionRecord, at ms: Int64, into session: inout Session) {
        session.turnStartMs = ms
        session.anchors.turn = record.seq
        session.lastError = ""
        session.failedTurn = false
        session.turnSteps = 0
        session.turnFailedSteps = 0
        session.runningSteps = []
        session.digest = TurnDigest()
        let text = TitleHeuristics.promptTitle(record.message)
        guard !text.isEmpty else { return }
        session.lastPrompt = text
        session.anchors.prompt = record.seq
        if session.title.isEmpty, TitleHeuristics.isMeaningful(text) {
            session.title = text
            session.anchors.title = record.seq
        }
    }

    /// A `tool` line that names its tool is a step, and finishes one tool
    /// its speaker said was running — the same tool on the same target,
    /// else the oldest of the same tool; one that names no tool finishes
    /// every tool its speaker said was running. A `status` line that names
    /// a tool says it runs now, beside any other (parallel tools).
    private static func progress(_ record: AttentionRecord, at ms: Int64, into session: inout Session) {
        let step = stepOf(record)
        if record.kind == .status {
            if let step {
                session.runningSteps.append(step)
                if session.runningSteps.count > maxRunning {
                    session.runningSteps.removeFirst(session.runningSteps.count - maxRunning)
                }
            }
            return
        }
        let speaker = String(record.sub.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        if let step {
            let same = session.runningSteps.indices.filter { index in
                session.runningSteps[index].sub == speaker
                    && session.runningSteps[index].tool.caseInsensitiveCompare(step.tool) == .orderedSame
            }
            if let index = same.first(where: { session.runningSteps[$0].target == step.target }) ?? same.first {
                session.runningSteps.remove(at: index)
            }
        } else {
            session.runningSteps.removeAll { $0.sub == speaker }
        }
        guard let step else { return }
        session.turnSteps += 1
        if step.failed { session.turnFailedSteps += 1 }
        session.lastStep = step
        session.digest.add(step, files: record.meta.files)
    }

    /// The step a `tool` (or `status`) line names; nil when it names no tool.
    private static func stepOf(_ record: AttentionRecord) -> Step? {
        let tool = record.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tool.isEmpty else { return nil }
        var target = TitleHeuristics.firstLine(record.message, limit: stepTargetLimit)
        if target.caseInsensitiveCompare(tool) == .orderedSame { target = "" }
        let failed = record.kind == .tool && record.failed
        return Step(
            tool: String(tool.prefix(64)),
            target: target,
            ms: record.ms,
            failed: failed,
            tookMs: record.kind == .tool ? max(0, record.tookMs) : 0,
            sub: String(record.sub.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)),
            category: record.category,
            error: failed ? record.meta.err : ""
        )
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
    /// generic "needs your permission"). A re-raise that names no subagent
    /// right after a subagent's ask of the same kind (Claude's main UI
    /// `Notification` after the subagent's `PermissionRequest`) is that ask
    /// said again: it stays the subagent's, on its clock. A block raised
    /// while no turn was live remembers where the session was
    /// (`Session.interrupted`).
    private static func raise(_ kind: AttentionKind, record: AttentionRecord, at ms: Int64, new: Bool, in session: inout Session) {
        var block = Block(
            kind: kind,
            ask: ContentSanitizer.redact(record.message),
            sinceMs: ms,
            inFront: record.front == true,
            sub: String(record.sub.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
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
        // The event that raised the block: a re-raise of the same block
        // keeps the first one's, as it keeps its clock.
        var cause = record.event
        // Where a block raised outside a turn interrupted the session; a
        // block raised over a block keeps the first one's. A session met
        // only now, by its block, interrupted nothing Pulse saw.
        var interrupted: Interrupted?
        switch session.state {
        case .blocked:
            interrupted = session.interrupted
        case .idle, .yourTurn:
            if !new {
                interrupted = Interrupted(state: session.state, sinceMs: session.stateSinceMs, event: session.stateEvent, stopped: session.stopped)
            }
        case .working, .ended:
            interrupted = nil
        }
        if case .blocked(let open) = session.state {
            if open.kind == kind, open.sub == block.sub || block.sub.isEmpty, abs(ms - open.sinceMs) < Self.stopGraceMs {
                cause = session.stateEvent
                block.sub = open.sub
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
        // The raise that turned it red; a raise over a block keeps it.
        if case .blocked = session.state {} else { session.anchors.block = record.seq }
        Self.set(&session, .blocked(block), at: block.sinceMs, event: cause)
        session.heldTurn = held
        session.interrupted = interrupted
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

    /// A new state from `ms`, put there by the vendor event `event` ("" for
    /// a process exit). A held turn belongs to the block it waits on and
    /// goes with it.
    private static func set(_ session: inout Session, _ state: State, at ms: Int64, event: String) {
        session.state = state
        session.stateSinceMs = ms
        session.stateEvent = event
        // Only `stop` says the person stopped it, right after this.
        session.stopped = false
        switch state {
        case .blocked: return
        case .working: break
        case .idle, .yourTurn, .ended:
            // The turn is over: nothing runs now.
            session.runningSteps = []
        }
        session.heldTurn = nil
        session.interrupted = nil
    }

    /// A turn event: held while a block is inside its grace, else the turn
    /// is over.
    private static func turn(_ session: inout Session, at ms: Int64, front: Bool, event: String) {
        if case .blocked(let block) = session.state, ms - block.sinceMs < stopGraceMs {
            // Held, not dropped: the later of two held turns is the one.
            if (session.heldTurn?.ms ?? .min) <= ms {
                session.heldTurn = HeldTurn(ms: ms, front: front, event: event)
            }
            return
        }
        endTurn(&session, at: ms, front: front, event: event)
    }

    /// The turn is over: your turn, or nothing owed when the person watched
    /// it finish.
    private static func endTurn(_ session: inout Session, at ms: Int64, front: Bool, event: String) {
        set(&session, front ? .idle : .yourTurn(sinceMs: ms), at: ms, event: event)
    }

    /// A held turn lands.
    private static func endTurn(_ session: inout Session, held: HeldTurn) {
        endTurn(&session, at: held.ms, front: held.front, event: held.event)
    }

    /// Work goes on (a prompt, a tool, a `done` for a block). A turn held
    /// for the block that ended no earlier than this still ends it. A
    /// subagent's own answer (`restoring`) to a block raised while no turn
    /// was live puts the session back where it was: its work is not a turn.
    private static func answer(_ session: inout Session, at ms: Int64, event: String, restoring: Bool = false) {
        let held = session.heldTurn
        if restoring, held == nil, let back = session.interrupted {
            restore(&session, back)
            return
        }
        Self.set(&session, .working, at: ms, event: event)
        if let held, held.ms >= ms { endTurn(&session, held: held) }
    }

    /// A block raised while no turn was live is over: the session is back
    /// in the state it interrupted, on that state's own clock and event.
    private static func restore(_ session: inout Session, _ back: Interrupted) {
        set(&session, back.state, at: back.sinceMs, event: back.event)
        session.stopped = back.stopped
    }

    /// Apply a held turn once `nowMs` is past its block's grace. Returns
    /// whether it did.
    @discardableResult
    package static func settleHeldTurn(_ session: inout Session, nowMs: Int64) -> Bool {
        guard let held = session.heldTurn, case .blocked(let block) = session.state,
              nowMs - block.sinceMs >= stopGraceMs
        else { return false }
        endTurn(&session, held: held)
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
    private static func clear(_ session: inout Session, at ms: Int64, dismissal: Bool, event: String) -> Bool {
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
                endTurn(&session, held: held)
            } else if let back = session.interrupted {
                // Raised while no turn was live: back where it was.
                restore(&session, back)
            } else {
                Self.set(&session, .working, at: ms, event: event)
            }
            return true
        case .yourTurn:
            Self.set(&session, .idle, at: ms, event: event)
            return true
        case .idle, .working, .ended:
            return false
        }
    }

    /// An empty resolution, for one session-less session: cleared, heard.
    private mutating func resolve(_ key: SessionKey, record: AttentionRecord) -> Bool {
        let ms = record.ms
        guard var session = sessions[key],
              Self.clear(&session, at: ms, dismissal: record.kind == .dismiss, event: record.event)
        else { return false }
        if ms >= session.lastEventMs { session.lastEvent = record.event }
        session.lastEventMs = max(session.lastEventMs, ms)
        let effect: Effect = record.kind == .done ? .resolved
            : record.event == AttentionRecord.seenEvent ? .seen : .dismissed
        Self.hear(&session, Heard(ms: ms, event: record.event, effect: effect))
        sessions[key] = session
        return true
    }

    /// Whether an activity line answers a block: a `tool` line of the
    /// block's own speaker (the main agent's for the main agent's block, the
    /// subagent's for its own) does unless both name a tool and the names
    /// differ (a parallel tool finishing is not the answer); a `status`
    /// line never does (work going on — a retry, a recoverable error — is
    /// not the person answering), and no step does for an agent whose
    /// module sends every reply (`AgentSpec.stepsAnswerBlocks`).
    package static func answers(_ record: AttentionRecord, _ block: Block) -> Bool {
        guard record.kind == .tool, record.agent.stepsAnswerBlocks else { return false }
        guard String(record.sub.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) == block.sub else { return false }
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
            Self.set(&copy, .ended(atMs: max(atMs, session.lastEventMs)), at: max(atMs, session.lastEventMs), event: "")
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
            Self.set(&copy, .ended(atMs: session.lastEventMs), at: session.lastEventMs, event: "")
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
        sessions[key]?.facts ?? SessionFacts()
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
