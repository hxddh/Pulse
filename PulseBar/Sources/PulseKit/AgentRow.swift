import Foundation

/// The lamp: one state, drawn the same way in the menu bar, beside a row,
/// on the detail page, in the header's counts and on a notice. The shape
/// says what the session needs, the colour how it is going — so the state
/// reads without colour too.
///
/// | lamp          | shape                | colour |
/// | ------------- | -------------------- | ------ |
/// | `waiting`     | filled               | red    |
/// | `running`     | ring (circle + dot)  | green  |
/// | `stalled`     | ring + a corner notch| orange |
/// | `idle`        | hollow               | grey   |
/// | `processOnly` | dotted               | grey   |
///
/// Orange is **only** a stall (an error is a detail-page fact); a process
/// with no session is grey dotted — never orange, never green. The colours
/// and the menu-bar image are `PulseTheme`'s (`Lamp.color`,
/// `Lamp.statusBarImage`). Pure.
package enum Lamp: String, CaseIterable, Equatable, Sendable {
    case waiting, running, stalled, idle, processOnly

    /// The lamp of one row's status.
    package init(_ status: AgentRow.Status) {
        switch status {
        case .needsYou: self = .waiting
        case .processOnly: self = .processOnly
        case .running(let stalled): self = stalled ? .stalled : .running
        case .yourTurn, .recent: self = .idle
        }
    }

    /// The menu-bar lamp for the rule that set it.
    package init(_ rule: TrayState.LampRule) {
        switch rule {
        case .blocked: self = .waiting
        case .stalled: self = .stalled
        case .running: self = .running
        case .processOnly: self = .processOnly
        case .yourTurn, .recent, .idle: self = .idle
        }
    }

    /// Grey: the menu bar draws it as a template, in its own colour.
    package var isGrey: Bool { self == .idle || self == .processOnly }

    /// What VoiceOver says for the state.
    package var accessibilityKey: L10n.Key {
        switch self {
        case .waiting: return .a11yWaiting
        case .running: return .a11yRunning
        case .stalled: return .a11yStalled
        case .idle, .processOnly: return .a11yIdle
        }
    }
}

/// What a blocked session is blocked on: always a hook's blocked event — the
/// only source of a wait. The book holds it while the session is blocked; a
/// row in need of you carries the same value.
package struct Block: Hashable, Sendable {
    /// `.permission`, `.question` or `.waiting`.
    package var kind: AttentionKind
    /// What the agent asked, in its own words (sanitized); "" when unknown.
    package var ask: String
    /// When it was raised, by the hook's own clock; 0 unknown.
    package var sinceMs: Int64
    /// The prompt's own window was frontmost when it was raised — the lamp
    /// still lights, but no banner and no sound.
    package var inFront: Bool
    /// The tool the block is about, when the raise named it (`Bash` from
    /// Claude's `Bash: npm test`); "" when unknown. Only that tool answers it.
    package var tool: String

    package init(kind: AttentionKind, ask: String = "", sinceMs: Int64 = 0, inFront: Bool = false, tool: String = "") {
        self.kind = kind
        self.ask = ask
        self.sinceMs = sinceMs
        self.inFront = inFront
        self.tool = tool
    }
}

/// What a session said lately: its last words and error, its steps, its
/// clocks, the vendor events behind its state and its timeline — the facts
/// that move with every line. They are read from the book when a row or the
/// detail page is drawn (`SessionBook.facts`), never carried by the
/// projection, so a burst of tool lines lands nothing.
package struct SessionFacts: Equatable, Sendable {
    /// The first line of the agent's latest message, as its turn carried it.
    package var lastWords: String
    /// The text of the latest turn that ended on an error.
    package var lastError: String
    /// Up to `SessionBook.maxSteps` recent steps, oldest first.
    package var steps: [SessionBook.Step]
    /// When the current turn started (its prompt); 0 unknown.
    package var turnStartMs: Int64
    /// The newest event of any kind; 0 none.
    package var lastEventMs: Int64
    /// The newest activity (a tool ran, a prompt); 0 none.
    package var activityMs: Int64
    /// The vendor event of the line that put the session in its current
    /// state ("" for a process exit, or unknown) — what the why cites.
    package var stateEvent: String
    /// The vendor event of its newest line.
    package var lastEvent: String
    /// The last `SessionBook.maxTimeline` lines it heard, oldest first —
    /// the detail page's timeline.
    package var timeline: [SessionBook.Heard]

    package init(
        lastWords: String = "",
        lastError: String = "",
        steps: [SessionBook.Step] = [],
        turnStartMs: Int64 = 0,
        lastEventMs: Int64 = 0,
        activityMs: Int64 = 0,
        stateEvent: String = "",
        lastEvent: String = "",
        timeline: [SessionBook.Heard] = []
    ) {
        self.lastWords = lastWords
        self.lastError = lastError
        self.steps = steps
        self.turnStartMs = turnStartMs
        self.lastEventMs = lastEventMs
        self.activityMs = activityMs
        self.stateEvent = stateEvent
        self.lastEvent = lastEvent
        self.timeline = timeline
    }

    /// The newest step; nil when the agent's hook names no tool (Cursor,
    /// OpenCode) or none has run.
    package var lastStep: SessionBook.Step? { steps.last }

    /// The newest clock, in ms; 0 unknown.
    package var lastActivityMs: Int64 { max(lastEventMs, activityMs) }

    /// Seconds since the session last did anything, against the caller's
    /// clock; 0 when unknown.
    package func lastActivitySeconds(at nowMs: Int64) -> Double {
        let last = lastActivityMs
        guard last > 0 else { return 0 }
        return max(0, Double(nowMs - last) / 1000.0)
    }

    /// Whether the agent's words may be quoted as *now*: past 30 minutes of
    /// silence they would be stale wearing fresh clothes.
    package func selfReportFresh(at nowMs: Int64) -> Bool {
        lastActivitySeconds(at: nowMs) <= 30 * 60
    }
}

/// One tray row: a session (or a process no session has claimed) and the
/// state-bearing facts the lamp, the order, the counts, the notifier and the
/// row's words read. Plain `Equatable`: a projection that finds the same
/// world gives the same rows. What moves with every tool line is not here —
/// it is the book's (`SessionFacts`), read at render time.
package struct AgentRow: Identifiable, Hashable {
    /// The one state a row is in, decided once by `TrayState` from the book
    /// and the clock. The lamp, the section and the words all derive from
    /// it.
    package enum Status: Hashable, Sendable {
        /// Red: the vendor's hook reported a permission request or a
        /// question.
        case needsYou(Block)
        /// It took a prompt or reported work, and nothing since says
        /// otherwise; `stalled` when an agent that reports every tool call
        /// has said nothing for `AgentRow.stalledSeconds`.
        case running(stalled: Bool)
        /// It finished its turn and nobody has looked since. Never red.
        case yourTurn(sinceMs: Int64)
        /// At its prompt with nothing owed, ended, or quiet past what Pulse
        /// can vouch for — and which.
        case recent(RecentReason)
        /// An agent process no session has claimed — typically one started
        /// before Pulse was running. Ephemeral: once a hook event names its
        /// session, the process belongs to that row.
        case processOnly
    }

    /// Why a session is shown as recent rather than live.
    package enum RecentReason: Hashable, Sendable {
        /// At its prompt with nothing owed: it started, or its turn was seen
        /// or aged out.
        case atPrompt
        /// It ended, or its process exited, at this time.
        case ended(atMs: Int64)
        /// Its process is not known and nothing was heard for the idle bound
        /// — Pulse cannot vouch that it is still there.
        case quiet
        /// It was working, its process lives, and nothing has been heard for
        /// `TrayState.silentBoundMs` (an interrupted turn sends no Stop).
        case silent
    }

    // MARK: Identity — decided once, never changed.

    package var key: SessionKey
    /// The session exactly as the events spell it — what a dismissal must
    /// carry ("" for a folder's or a process's row).
    package var session: String = ""
    package var cwd: String = ""

    // MARK: The process and how to reach it

    /// The row's process is known and alive (an exit ends the session).
    package var liveProcess: Bool = false
    package var pid: Int32 = 0
    /// Where the session can be reached: the hook's landing handle, filled
    /// in from the process table where the hook said nothing.
    package var landing = LandingHandle()
    /// How a click lands (`LandingPlan.make`) — resolved once per
    /// projection, never in a view body.
    package var landingPlan = LandingPlan()

    // MARK: What it is

    /// The session's title: its first prompt that says something.
    package var task: String = ""
    package var status: Status

    package init(key: SessionKey, status: Status = .recent(.atPrompt)) {
        self.key = key
        self.status = status
    }

    package var id: SessionKey { key }
    package var agent: AgentID { key.agent }

    // MARK: - Status, read

    package var wait: Block? {
        if case .needsYou(let block) = status { return block }
        return nil
    }

    package var isBlocked: Bool { wait != nil }

    package var isProcessOnly: Bool { status == .processOnly }

    package var turnSinceMs: Int64? {
        if case .yourTurn(let since) = status { return since }
        return nil
    }

    package var isYourTurn: Bool { turnSinceMs != nil }

    package var isRecent: Bool {
        if case .recent = status { return true }
        return false
    }

    package var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    package var isStalled: Bool { status == .running(stalled: true) }

    package var lamp: Lamp { Lamp(status) }

    /// Where the row sorts: waits, then work (a live process, a turn whose
    /// CLI is still open), then stalls, then recent.
    package var rank: Int {
        switch status {
        case .needsYou: return 0
        case .running(let stalled): return stalled ? 2 : 1
        case .processOnly: return 1
        case .yourTurn: return liveProcess ? 1 : 3
        case .recent: return 3
        }
    }

    package var canFocusTerminal: Bool { !landingPlan.isEmpty }

    // MARK: - Stall

    /// The stall rule: twenty minutes with no event from a working session
    /// whose agent reports its work (one that has sent an activity event).
    /// Not a setting; `TrayState.Context` carries it so a test can move it.
    package static let stalledSeconds: Double = 20 * 60

    /// Whether a live row would be stalled at the given instant.
    /// `threshold <= 0` turns staleness off; a zero clock is unknown, not
    /// silence.
    package static func stalled(lastActivityMs: Int64, nowMs: Int64, threshold: Double = stalledSeconds) -> Bool {
        guard threshold > 0, lastActivityMs > 0 else { return false }
        return Double(nowMs - lastActivityMs) / 1000.0 >= threshold
    }

    // MARK: - Titles and places (`TitleHeuristics` decides)

    /// The project a row shows beside the agent: its folder's short name.
    package var project: String { TitleHeuristics.shortProject(cwd) }

    /// The task, when it is a real goal.
    package var usefulTask: String? { TitleHeuristics.usefulTitle(task, agentName: agent.displayName) }

    /// Where this session lives, written the way a person would write it.
    package var displayPath: String {
        TitleHeuristics.displayPath(cwd, home: FileManager.default.homeDirectoryForCurrentUser.path)
    }
}

/// The glance: the lamp, the menu-bar title and tooltip, and the counts.
/// Plain `Equatable` — the same world projects the same snapshot.
package struct PulseSnapshot: Equatable {
    /// The menu-bar lamp (`Lamp(TrayState.lampRule(counts:))`).
    package var lamp: Lamp = .idle
    package var title: String = ""
    /// One line: the rule that set the lamp (`TrayState.lampSentence`).
    package var tooltip: String = "Pulse"
    /// The lamp as VoiceOver says it, in the resolved language.
    package var accessibilityLabel: String = ""
    /// Every row counted once by its state.
    package var counts = TrayState.Counts()
    /// A projection made it — false only for the placeholder before the
    /// first one, which is no transition (no dip, no announcement).
    package var projected = false

    package init(
        lamp: Lamp = .idle,
        title: String = "",
        tooltip: String = "Pulse",
        accessibilityLabel: String = "",
        counts: TrayState.Counts = TrayState.Counts(),
        projected: Bool = false
    ) {
        self.lamp = lamp
        self.title = title
        self.tooltip = tooltip
        self.accessibilityLabel = accessibilityLabel
        self.counts = counts
        self.projected = projected
    }
}
