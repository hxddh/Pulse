import Foundation

/// Single source of truth for the product version.
///
/// `semver` is the truth; `scripts/version_check.py` keeps the CHANGELOG and
/// the README badge from drifting away from it. Build metadata (commit, date)
/// is injected into `Info.plist` by `PulseBar/Scripts/package.sh`, so a `swift
/// run` build honestly reports itself as `dev` instead of faking a release id.
enum PulseVersion {
    static let semver = "29.0.1"

    enum Channel {
        /// Packaged Pulse.app whose bundle version matches this binary.
        case release
        /// `swift run` / unpackaged — no build metadata.
        case dev
        /// Packaged, but Info.plist disagrees with the compiled semver.
        case mismatch(bundle: String)
    }

    private static func plist(_ key: String) -> String? {
        guard let raw = Bundle.main.infoDictionary?[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `CFBundleShortVersionString` of the running bundle, when packaged.
    static var bundleVersion: String? { plist("CFBundleShortVersionString") }

    /// Short git sha stamped at package time (`dev` when unpackaged).
    static var commit: String { plist("PulseGitCommit") ?? "dev" }

    /// ISO date stamped at package time (empty when unpackaged).
    static var buildDate: String { plist("PulseBuildDate") ?? "" }

    /// `stable` (notarized — `package.sh` stamps it only after stapler
    /// validates) / `preview` (every other packaged build: ad-hoc or not
    /// notarized) / `dev` (unpackaged). An unnotarized build is never stable.
    static var distributionChannel: String {
        plist("PulseDistributionChannel") ?? (bundleVersion == nil ? "dev" : "preview")
    }

    /// Stapler success stamp from `package.sh`. Absent or false → not Gatekeeper-ready.
    static var isNotarized: Bool {
        (plist("PulseNotarized") ?? "false").lowercased() == "true"
    }

    static var channel: Channel {
        guard let bundle = bundleVersion else { return .dev }
        return bundle == semver ? .release : .mismatch(bundle: bundle)
    }

    /// Compact badge for tray footer / logs: `x.y.z`, `x.y.z-dev`, `x.y.z≠<bundle>`.
    static var short: String {
        switch channel {
        case .release: return semver
        case .dev: return "\(semver)-dev"
        case .mismatch(let bundle): return "\(semver)≠\(bundle)"
        }
    }

    /// `Pulse x.y.z` — About heading.
    static var about: String { "Pulse \(short)" }

    /// Second About line: `<sha> · <date>`. Empty when there is nothing honest to show.
    static var buildLine: String {
        var bits: [String] = []
        if commit != "dev" { bits.append(commit) }
        if !buildDate.isEmpty { bits.append(buildDate) }
        return bits.joined(separator: " · ")
    }

    /// One line that fully identifies this build — logs and bug reports.
    static var fingerprint: String {
        let build = buildLine
        return build.isEmpty ? "Pulse \(short)" : "Pulse \(short) (\(build))"
    }
}

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
enum Lamp: String, CaseIterable, Equatable, Sendable {
    case waiting, running, stalled, idle, processOnly

    /// The lamp beside one row.
    init(_ row: AgentRow) {
        switch row.state {
        case .blocked: self = .waiting
        case .processOnly: self = .processOnly
        case .running: self = row.isStalled ? .stalled : .running
        case .yourTurn, .recent: self = .idle
        }
    }

    /// The menu-bar lamp for the rule that set it.
    init(_ rule: TrayState.LampRule) {
        switch rule {
        case .blocked: self = .waiting
        case .stalled: self = .stalled
        case .running: self = .running
        case .processOnly: self = .processOnly
        case .yourTurn, .recent, .idle: self = .idle
        }
    }

    /// Grey: the menu bar draws it as a template, in its own colour.
    var isGrey: Bool { self == .idle || self == .processOnly }

    /// What VoiceOver says for the state.
    var accessibilityKey: L10n.Key {
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
struct RowWait: Hashable, Sendable {
    /// Protocol token (`Permission` / `Input` / `Waiting`), never user copy —
    /// `L10n.waitKind` translates it.
    var kind: String
    /// What the agent asked, in its own words (sanitized); "" when unknown.
    var ask: String = ""
    /// When the wait was raised, by the hook's own clock; 0 = unknown.
    var sinceMs: Int64 = 0
    /// The prompt's own window was frontmost when it was raised — the lamp
    /// still lights, but no banner and no sound.
    var inFront: Bool = false
}

/// The one state a row is in, decided once by `TrayState`, from the session
/// book.
enum RowState: Hashable, Sendable {
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
enum RecentReason: Hashable, Sendable {
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
enum RowSource: String, Equatable, Hashable, Sendable {
    /// The agent's own hook events.
    case hooks
    /// Only a process (the process table).
    case process
}

/// One tray row: a session (or a process no session has claimed) and
/// exactly what the tray row, the detail page, the lamp and the notifier
/// read. `TrayRowModel` builds the few sentences Pulse says from what is here.
struct AgentRow: Identifiable, Hashable {
    // MARK: Identity — `RowIdentity` decides the key, and it never changes.

    var rowKey: String
    var agent: AgentID
    /// The vendor's session id; "" for a process-only row.
    var sessionID: String = ""
    /// The session the attention entry behind this row's hook raise or turn
    /// carried — exactly as the file spells it, possibly empty. It can be a
    /// prefix of `sessionID` (or the other way round); a `done` must name the
    /// file's spelling or it clears nothing, and an empty one clears only
    /// the agent's session-less entry.
    var attentionSession: String = ""
    var cwd: String = ""
    var project: String = ""

    // MARK: The process and how to reach it

    /// The row's process is known and alive (an exit ends the session).
    var liveProcess: Bool = false
    var pid: Int = 0
    /// Where the session can be reached: the hook's landing handle, filled
    /// in from the process table where the hook said nothing.
    var landing = LandingHandle()
    /// How a click lands (`LandingPlan.make`) — resolved once per projection,
    /// never in a view body.
    var landingPlan = LandingPlan()

    // MARK: What it is doing — from its events only

    /// The session's title: its first prompt that says something.
    var task: String = ""
    /// The first line of the agent's latest message, as its turn event
    /// carried it (self-report tier).
    var lastWord: String = ""
    /// The text of the latest turn that ended on an error, as its hook
    /// reported it.
    var lastErrorText: String = ""
    /// The newest tool step (`recentSteps.last`); nil when the agent's hook
    /// names no tool (Cursor, OpenCode) or none has run.
    var lastStep: SessionBook.Step?
    /// Up to `SessionBook.maxSteps` recent steps, oldest first.
    var recentSteps: [SessionBook.Step] = []
    /// When the current turn started (its prompt); 0 unknown.
    var turnStartMs: Int64 = 0

    // MARK: State

    var state: RowState = .recent
    /// Why a `.recent` row is recent — `TrayRowModel.why` says the rule.
    var recentReason: RecentReason = .atPrompt
    /// Resolved once per projection against its clock and the stall rule
    /// (`TrayState`), never against `Date()` in a view.
    var isStalled: Bool = false
    /// When the row entered its state, by the event's clock (a process-only
    /// row: when the process began); 0 = unknown.
    var stateSinceMs: Int64 = 0
    /// The newest event of any kind, in ms; 0 = none.
    var lastEventMs: Int64 = 0
    /// The newest activity event (a tool ran, a prompt); 0 = none.
    var activityMs: Int64 = 0
    /// When the session (or, for a process-only row, the process) began.
    var startedMs: Int64 = 0
    var source: RowSource = .process

    var id: String { rowKey }

    // MARK: - State, read

    var wait: RowWait? {
        if case .blocked(let wait) = state { return wait }
        return nil
    }

    var isBlocked: Bool { wait != nil }

    var isProcessOnly: Bool { state == .processOnly }

    var turnSinceMs: Int64? {
        if case .yourTurn(let since) = state { return since }
        return nil
    }

    var isYourTurn: Bool { turnSinceMs != nil }

    var isRecent: Bool { state == .recent }

    /// Which tray section this row belongs to.
    var section: TraySection {
        switch state {
        case .blocked: return .needsYou
        case .recent: return .recent
        case .processOnly: return .running
        case .running: return isStalled ? .stalled : .running
        case .yourTurn: return liveProcess ? .running : .recent
        }
    }

    var canFocusTerminal: Bool { !landingPlan.isEmpty }

    /// The newest clock this row has, in ms; 0 = unknown.
    var lastActivityMs: Int64 { max(lastEventMs, activityMs) }

    /// Seconds since this session last did anything, against the caller's
    /// clock (the projection passes its `nowMs`); 0 when unknown.
    func lastActivitySeconds(at nowMs: Int64) -> Double {
        let last = lastActivityMs
        guard last > 0 else { return 0 }
        return max(0, Double(nowMs - last) / 1000.0)
    }

    /// Whether the agent's words may be quoted as *now*: past 30 minutes of
    /// silence they would be stale wearing fresh clothes.
    func selfReportFresh(at nowMs: Int64) -> Bool {
        lastActivitySeconds(at: nowMs) <= 30 * 60
    }

    // MARK: - Stall

    /// The stall rule: twenty minutes with no event from a working session
    /// whose agent reports its work (one that has sent an activity event).
    /// Not a setting; `TrayState.Context` carries it so a
    /// test can move it.
    static let stalledSeconds: Double = 20 * 60

    /// Whether a live row would be stalled at the given instant.
    /// `threshold <= 0` turns staleness off; a zero clock is unknown, not
    /// silence.
    static func stalled(lastActivityMs: Int64, nowMs: Int64, threshold: Double = stalledSeconds) -> Bool {
        guard threshold > 0, lastActivityMs > 0 else { return false }
        return Double(nowMs - lastActivityMs) / 1000.0 >= threshold
    }


    // MARK: - Titles and places (`TitleHeuristics` decides)

    /// The task, when it is a real goal.
    var usefulTask: String? { TitleHeuristics.usefulTitle(task, agentName: agent.displayName) }

    /// The short project name a row shows beside the agent.
    var shortPlace: String { TitleHeuristics.shortProject(project.isEmpty ? cwd : project) }

    /// Where this session lives, written the way a person would write it.
    var displayPath: String {
        TitleHeuristics.displayPath(
            cwd.isEmpty ? project : cwd,
            home: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }
}

/// The order of the tray's states: waits first, then running, stalled and
/// recent (`TrayState.assemble` sorts by it).
enum TraySection: Int, CaseIterable, Hashable {
    case needsYou = 0
    case running = 1
    case stalled = 2
    case recent = 3
}

struct PulseSnapshot: Equatable {
    /// The menu-bar lamp (`Lamp(TrayState.lampRule(counts:))`).
    var lamp: Lamp = .idle
    var title: String = ""
    /// One line: the rule that set the lamp (`TrayState.lampSentence`).
    var tooltip: String = "Pulse"
    /// The lamp as VoiceOver says it, in the resolved language.
    var accessibilityLabel: String = ""
    var rows: [AgentRow] = []
    /// Every row counted once by its state.
    var counts = TrayState.Counts()
    var updatedAt: Date = .distantPast
}

extension PulseSnapshot {
    /// Equal in everything a surface draws — `updatedAt` aside.
    func sameContent(as other: PulseSnapshot) -> Bool {
        var mine = self
        mine.updatedAt = other.updatedAt
        return mine == other
    }

    /// Minute labels ("4m", "3m ago") need a redraw at most this often when
    /// nothing else moved.
    static let minuteLabelRefresh: TimeInterval = 60

    /// Whether `next` must replace `current` for the surfaces to stay true:
    /// its content changed, or a minute passed and a relative-time label on
    /// screen moves. Nothing else about an unchanged world is worth a redraw.
    static func needsPublish(next: PulseSnapshot, current: PulseSnapshot) -> Bool {
        current.updatedAt == .distantPast
            || !next.sameContent(as: current)
            || next.updatedAt.timeIntervalSince(current.updatedAt) >= minuteLabelRefresh
    }
}
