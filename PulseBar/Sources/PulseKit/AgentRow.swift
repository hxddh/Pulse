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

    /// The lamp beside one row.
    package init(_ row: AgentRow) {
        switch row.state {
        case .blocked: self = .waiting
        case .processOnly: self = .processOnly
        case .running: self = row.isStalled ? .stalled : .running
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

/// What a blocked row is blocked on: always a hook's blocked event — the
/// only source of a wait.
package struct RowWait: Hashable, Sendable {
    /// Protocol token (`Permission` / `Input` / `Waiting`), never user copy —
    /// `L10n.waitKind` translates it.
    package var kind: String
    /// What the agent asked, in its own words (sanitized); "" when unknown.
    package var ask: String = ""
    /// When the wait was raised, by the hook's own clock; 0 = unknown.
    package var sinceMs: Int64 = 0
    /// The prompt's own window was frontmost when it was raised — the lamp
    /// still lights, but no banner and no sound.
    package var inFront: Bool = false
}

/// The one state a row is in, decided once by `TrayState`, from the session
/// book.
package enum RowState: Hashable, Sendable {
    /// Red: the vendor's hook reported a permission request or a question.
    case blocked(RowWait)
    /// The session took a prompt or reported work, and nothing since says
    /// otherwise.
    case running
    /// The agent finished its turn and nobody has looked since. From hooks
    /// only; never red.
    case yourTurn(sinceMs: Int64)
    /// At its prompt with nothing owed, ended, or quiet past what Pulse can
    /// vouch for.
    case recent
    /// An agent process no session has claimed — typically one started
    /// before Pulse was running. Ephemeral: once a hook event names its
    /// session, the process belongs to that row.
    case processOnly
}

/// Why a session is shown as recent rather than live.
package enum RecentReason: Hashable, Sendable {
    /// At its prompt with nothing owed: it started, or its turn was seen or
    /// aged out.
    case atPrompt
    /// It ended, or its process exited.
    case ended
    /// Its process is not known and nothing was heard for the idle bound —
    /// Pulse cannot vouch that it is still there.
    case quiet
    /// It was working, its process lives, and nothing has been heard
    /// for `TrayState.silentBoundMs` (an interrupted turn sends no Stop).
    case silent
}

/// Where a row's facts came from — said in the "Copy report".
package enum RowSource: String, Equatable, Hashable, Sendable {
    /// The agent's own hook events.
    case hooks
    /// Only a process (the process table).
    case process
}

/// One tray row: a session (or a process no session has claimed) and
/// exactly what the tray row, the detail page, the lamp and the notifier
/// read. `TrayRowModel` builds the few sentences Pulse says from what is here.
package struct AgentRow: Identifiable, Hashable {
    // MARK: Identity — `RowIdentity` decides the key, and it never changes.

    package var rowKey: String
    package var agent: AgentID
    /// The vendor's session id; "" for a process-only row.
    package var sessionID: String = ""
    /// The session the attention entry behind this row's hook raise or turn
    /// carried — exactly as the file spells it, possibly empty. It can be a
    /// prefix of `sessionID` (or the other way round); a `done` must name the
    /// file's spelling or it clears nothing, and an empty one clears only
    /// the agent's session-less entry.
    package var attentionSession: String = ""
    package var cwd: String = ""
    package var project: String = ""

    // MARK: The process and how to reach it

    /// The row's process is known and alive (an exit ends the session).
    package var liveProcess: Bool = false
    package var pid: Int = 0
    /// Where the session can be reached: the hook's landing handle, filled
    /// in from the process table where the hook said nothing.
    package var landing = LandingHandle()
    /// How a click lands (`LandingPlan.make`) — resolved once per projection,
    /// never in a view body.
    package var landingPlan = LandingPlan()

    // MARK: What it is doing — from its events only

    /// The session's title: its first prompt that says something.
    package var task: String = ""
    /// The first line of the agent's latest message, as its turn event
    /// carried it (self-report tier).
    package var lastWord: String = ""
    /// The text of the latest turn that ended on an error, as its hook
    /// reported it.
    package var lastErrorText: String = ""
    /// The newest tool step (`recentSteps.last`); nil when the agent's hook
    /// names no tool (Cursor, OpenCode) or none has run.
    package var lastStep: SessionBook.Step?
    /// Up to `SessionBook.maxSteps` recent steps, oldest first.
    package var recentSteps: [SessionBook.Step] = []
    /// When the current turn started (its prompt); 0 unknown.
    package var turnStartMs: Int64 = 0

    // MARK: State

    package var state: RowState = .recent
    /// Why a `.recent` row is recent — `TrayRowModel.why` says the rule.
    package var recentReason: RecentReason = .atPrompt
    /// Resolved once per projection against its clock and the stall rule
    /// (`TrayState`), never against `Date()` in a view.
    package var isStalled: Bool = false
    /// When the row entered its state, by the event's clock (a process-only
    /// row: when the process began); 0 = unknown.
    package var stateSinceMs: Int64 = 0
    /// The newest event of any kind, in ms; 0 = none.
    package var lastEventMs: Int64 = 0
    /// The newest activity event (a tool ran, a prompt); 0 = none.
    package var activityMs: Int64 = 0
    /// When the session (or, for a process-only row, the process) began.
    package var startedMs: Int64 = 0
    package var source: RowSource = .process

    package var id: String { rowKey }

    // MARK: - State, read

    package var wait: RowWait? {
        if case .blocked(let wait) = state { return wait }
        return nil
    }

    package var isBlocked: Bool { wait != nil }

    package var isProcessOnly: Bool { state == .processOnly }

    package var turnSinceMs: Int64? {
        if case .yourTurn(let since) = state { return since }
        return nil
    }

    package var isYourTurn: Bool { turnSinceMs != nil }

    package var isRecent: Bool { state == .recent }

    /// Which tray section this row belongs to.
    package var section: TraySection {
        switch state {
        case .blocked: return .needsYou
        case .recent: return .recent
        case .processOnly: return .running
        case .running: return isStalled ? .stalled : .running
        case .yourTurn: return liveProcess ? .running : .recent
        }
    }

    package var canFocusTerminal: Bool { !landingPlan.isEmpty }

    /// The newest clock this row has, in ms; 0 = unknown.
    package var lastActivityMs: Int64 { max(lastEventMs, activityMs) }

    /// Seconds since this session last did anything, against the caller's
    /// clock (the projection passes its `nowMs`); 0 when unknown.
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

    // MARK: - Stall

    /// The stall rule: twenty minutes with no event from a working session
    /// whose agent reports its work (one that has sent an activity event).
    /// Not a setting; `TrayState.Context` carries it so a
    /// test can move it.
    package static let stalledSeconds: Double = 20 * 60

    /// Whether a live row would be stalled at the given instant.
    /// `threshold <= 0` turns staleness off; a zero clock is unknown, not
    /// silence.
    package static func stalled(lastActivityMs: Int64, nowMs: Int64, threshold: Double = stalledSeconds) -> Bool {
        guard threshold > 0, lastActivityMs > 0 else { return false }
        return Double(nowMs - lastActivityMs) / 1000.0 >= threshold
    }


    // MARK: - Titles and places (`TitleHeuristics` decides)

    /// The task, when it is a real goal.
    package var usefulTask: String? { TitleHeuristics.usefulTitle(task, agentName: agent.displayName) }

    /// The short project name a row shows beside the agent.
    package var shortPlace: String { TitleHeuristics.shortProject(project.isEmpty ? cwd : project) }

    /// Where this session lives, written the way a person would write it.
    package var displayPath: String {
        TitleHeuristics.displayPath(
            cwd.isEmpty ? project : cwd,
            home: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }
}

/// The order of the tray's states: waits first, then running, stalled and
/// recent (`TrayState.assemble` sorts by it).
package enum TraySection: Int, CaseIterable, Hashable {
    case needsYou = 0
    case running = 1
    case stalled = 2
    case recent = 3
}

package struct PulseSnapshot: Equatable {
    /// The menu-bar lamp (`Lamp(TrayState.lampRule(counts:))`).
    package var lamp: Lamp = .idle
    package var title: String = ""
    /// One line: the rule that set the lamp (`TrayState.lampSentence`).
    package var tooltip: String = "Pulse"
    /// The lamp as VoiceOver says it, in the resolved language.
    package var accessibilityLabel: String = ""
    package var rows: [AgentRow] = []
    /// Every row counted once by its state.
    package var counts = TrayState.Counts()
    package var updatedAt: Date = .distantPast

    package init(
        lamp: Lamp = .idle,
        title: String = "",
        tooltip: String = "Pulse",
        accessibilityLabel: String = "",
        rows: [AgentRow] = [],
        counts: TrayState.Counts = TrayState.Counts(),
        updatedAt: Date = .distantPast
    ) {
        self.lamp = lamp
        self.title = title
        self.tooltip = tooltip
        self.accessibilityLabel = accessibilityLabel
        self.rows = rows
        self.counts = counts
        self.updatedAt = updatedAt
    }
}

extension PulseSnapshot {
    /// Equal in everything a surface draws — `updatedAt` aside.
    package func sameContent(as other: PulseSnapshot) -> Bool {
        var mine = self
        mine.updatedAt = other.updatedAt
        return mine == other
    }

    /// Minute labels ("4m", "3m ago") need a redraw at most this often when
    /// nothing else moved.
    package static let minuteLabelRefresh: TimeInterval = 60

    /// Whether `next` must replace `current` for the surfaces to stay true:
    /// its content changed, or a minute passed and a relative-time label on
    /// screen moves. Nothing else about an unchanged world is worth a redraw.
    package static func needsPublish(next: PulseSnapshot, current: PulseSnapshot) -> Bool {
        current.updatedAt == .distantPast
            || !next.sameContent(as: current)
            || next.updatedAt.timeIntervalSince(current.updatedAt) >= minuteLabelRefresh
    }
}
