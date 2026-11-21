import Foundation

// The book's values: a session, its state and what it heard. The reducer
// that moves them is `SessionBook.apply` (SessionBook.swift); the timeline
// grouping is SessionBook+Timeline.swift.
extension SessionBook {
    /// What a session is doing, as its events said.
    package enum State: Equatable, Sendable, Codable {
        /// Started, or its turn was seen: alive at its prompt, nothing owed.
        case idle
        /// It took a prompt, or reported work since its last state.
        case working
        /// It cannot go on until the person answers — the red lamp.
        case blocked(Block)
        /// The person ignored a wait in Pulse (`dismiss`): neither red nor
        /// faking green while the vendor's prompt may still be open.
        case dismissedWait(sinceMs: Int64)
        /// It finished its turn and nobody has looked since — quiet.
        case yourTurn(sinceMs: Int64)
        /// It ended, or its process exited.
        case ended(atMs: Int64)
    }

    /// A turn that arrived within `stopGraceMs` of a block: held, never
    /// dropped.
    package struct HeldTurn: Equatable, Sendable, Codable {
        package var ms: Int64
        package var front: Bool
        /// The vendor event of the held turn — the why's when it lands.
        package var event = ""
    }

    /// The state a block interrupted when no turn was live, with its clock,
    /// its vendor event and whether the person had stopped the run.
    package struct Interrupted: Equatable, Sendable, Codable {
        package var state: State
        package var sinceMs: Int64
        package var event: String
        package var stopped: Bool
    }

    /// The block a dismissal in Pulse (a `dismiss` line) cleared last, and
    /// when.
    package struct ClearedBlock: Equatable, Sendable, Codable {
        package var kind: AttentionKind
        package var ask: String
        package var sinceMs: Int64
        package var clearedMs: Int64
    }

    /// One tool step, as its `tool` line said it: the tool (`Bash`), its
    /// target (`swift test`, sanitized; "" when the hook did not say) and
    /// when it was reported. A past step — never a claim that it still runs.
    package struct Step: Hashable, Sendable, Codable {
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
    package struct PlanProgress: Hashable, Sendable, Codable {
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
    package struct SubagentType: Hashable, Sendable, Codable {
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
    package struct Heard: Hashable, Sendable, Codable {
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
    package struct StepRun: Hashable, Sendable, Codable {
        package struct Tally: Hashable, Sendable, Codable {
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
    package enum Effect: Hashable, Sendable, Codable {
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

    /// One session: who it is, where it runs, the one state it is in and
    /// the reducer's own bookkeeping; what it said lately is its `facts`,
    /// read and written through the session's own members
    /// (`session.lastEventMs` is `session.facts.lastEventMs`).
    @dynamicMemberLookup
    package struct Session: Equatable, Sendable, Codable {
        /// Decided by the first event, never changed.
        package var key: SessionKey
        package var agent: AgentID { key.agent }
        /// The session exactly as the events spell it ("" for a
        /// folder-keyed one) — what a `dismiss` must carry.
        package var session: String
        package var cwd = ""
        /// The Git branch of the session's working tree ("" unknown or detached).
        package var branch = ""
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
}
