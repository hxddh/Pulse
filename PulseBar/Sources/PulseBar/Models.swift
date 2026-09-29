import Foundation

/// Single source of truth for the product version.
///
/// `semver` is the truth; `scripts/version_check.py` keeps the CHANGELOG and
/// the README badge from drifting away from it. Build metadata (commit, date)
/// is injected into `Info.plist` by `PulseBar/Scripts/package.sh`, so a `swift
/// run` build honestly reports itself as `dev` instead of faking a release id.
enum PulseVersion {
    static let semver = "22.0.0"

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

    /// `preview` (ad-hoc) / `signed` (Developer ID, not notarized) / `stable`
    /// (notarized) / `dev` (unpackaged). Never treat signed-as-stable.
    static var distributionChannel: String {
        plist("PulseDistributionChannel") ?? (bundleVersion == nil ? "dev" : "preview")
    }

    /// Stapler success stamp from `package.sh`. Absent or false → not Gatekeeper-ready.
    static var isNotarized: Bool {
        (plist("PulseNotarized") ?? "false").lowercased() == "true"
    }

    /// True only for notarized stable builds that other Macs can open without
    /// the Control-click recovery path.
    static var isGatekeeperReady: Bool {
        distributionChannel == "stable" && isNotarized
    }

    /// Preview and signed-but-unnotarized builds should follow prerelease feeds.
    static var prefersPrereleaseUpdates: Bool {
        switch distributionChannel {
        case "stable": return false
        case "dev": return false
        default: return true
        }
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



/// How this row's Waiting was raised.
enum WaitSignalKind: String, Equatable, Sendable {
    /// A Claude / Codex hook (or an Attention bridge line) said so.
    case hooks
    /// The vendor's own session file holds an open ask (`skill=pending`).
    case pending
    /// 18.0: the vendor's own report of a blocked session (`claude agents`).
    case vendor
}

/// Honesty tier for Focus — never claim session/tab precision when we only activate an app.
enum FocusTier: Equatable, Hashable {
    /// Terminal/iTerm tab select (Automation opt-in only).
    case tty
    /// Warp app activate — never tab-precise.
    case warp
    /// Host IDE with an absolute workspace path we can open via `open -a`.
    case hostWorkspace(HostAppKind)
    /// Host IDE app activate only.
    case hostApp(HostAppKind)
}

enum GlanceKind: Equatable {
    case idle
    case running
    case stalled
    case waiting

    /// VoiceOver reads this instead of the icon. It used to be hardcoded
    /// English, so a Chinese user heard "Needs attention" in an otherwise
    /// localized interface.
    var accessibilityKey: L10n.Key {
        switch self {
        case .idle: return .a11yIdle
        case .running: return .a11yRunning
        case .stalled: return .a11yStalled
        case .waiting: return .a11yWaiting
        }
    }
}

/// 23.0 · what a blocked row is blocked on, and on what evidence.
struct RowWait: Hashable, Sendable {
    /// Protocol token (`Permission` / `Input` / `Waiting`), never user copy —
    /// `L10n.waitKind` translates it.
    var kind: String
    /// What the agent asked, in its own words (sanitized); "" when unknown.
    var ask: String = ""
    /// When the wait was raised, by the evidence's own clock; 0 = unknown.
    var sinceMs: Int64 = 0
    var signal: WaitSignalKind
    /// 16.0: the prompt's own window was frontmost when it was raised — the
    /// lamp still lights, but no banner and no sound.
    var inFront: Bool = false
}

/// 23.0 · the one state a row is in. It replaces the booleans that used to
/// say it in pieces (`waiting`, `yourTurn`, `isProcessOnly`, a completed
/// phase…), which could disagree. Decided once, by `SnapshotBuilder`.
enum RowState: Hashable, Sendable {
    /// Red: a permission, a question, or a wait the vendor reported.
    case blocked(RowWait)
    /// A live session (a process, an explicit running phase, or subagents).
    case running
    /// 16.0: the agent finished its turn and nobody has looked since. From
    /// hooks only; never red.
    case yourTurn(sinceMs: Int64)
    /// A session with no live evidence — finished or gone quiet.
    case recent
    /// A process and nothing else: no session file, no hook. Ephemeral — it
    /// is not built once a session row for the agent exists.
    case processOnly
}

/// 23.0 · where a row's facts came from, in the words `Explain` uses.
enum RowSource: String, Equatable, Hashable, Sendable {
    /// The vendor's structured session file.
    case session
    /// A vendor cache or database.
    case cache
    /// Only a hook said anything (no session file found yet).
    case hooks
    /// Only a process.
    case process

    init(_ evidence: ObservationSource) {
        switch evidence {
        case .session: self = .session
        case .cache: self = .cache
        case .process: self = .process
        }
    }
}

/// One tray row: a session (or a process, or a hook wait) and exactly what
/// the tray row, the detail page, the lamp and the notifier read.
///
/// 23.0 cut ~70 stored and ~36 computed fields down to these. Tokens, CPU,
/// memory, context, files, tool histograms, subagent counts, phase and
/// outcome strings and the observation-quality envelope existed for
/// narration sentences that are gone; `Explain` builds the few sentences
/// left from what is here.
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
    /// The workspace path was reconstructed from a dash-encoded vendor
    /// directory name and the disk could not confirm it. Display only —
    /// `focusTier` never offers workspace precision for it.
    var cwdBestEffort: Bool = false
    var project: String = ""

    // MARK: The process and how to reach it

    /// A live process of this agent was attached to this row.
    var liveProcess: Bool = false
    var pid: Int = 0
    var tty: String = ""
    var viaWarp: Bool = false
    /// Host IDE detected by walking the process parent chain (`ps` only).
    var hostApp: HostAppKind? = nil
    /// How this row can be focused — resolved once per scan, never in a view body.
    var focusTier: FocusTier? = nil

    // MARK: What it is doing

    var task: String = ""
    var model: String = ""
    /// The first line of the agent's latest message (self-report tier).
    var lastWord: String = ""
    /// The agent's own plan (TodoWrite / update_plan), bounded.
    var planSteps: [ActivityHarvest.PlanStep] = []
    var errors: Int = 0
    var lastErrorText: String = ""

    // MARK: State

    var state: RowState = .recent
    /// Resolved once per scan against the scan's clock and the stall rule
    /// (`SnapshotBuilder`), never against `Date()` in a view.
    var isStalled: Bool = false
    /// The session file's last change, in ms; 0 = unknown.
    var harvestMs: Int64 = 0
    /// The live-signal clock: a hook activity event, or a fact that moved
    /// while the file's mtime did not. 0 = none.
    var activityMs: Int64 = 0
    /// When the session (or, for a process-only row, the process) began.
    var startedMs: Int64 = 0
    var source: RowSource = .process
    /// Sessions of this agent that exist but did not fit the per-agent cap.
    var hiddenSessions: Int = 0

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

    var canFocusTerminal: Bool { focusTier != nil }

    /// The newest clock this row has, in ms; 0 = unknown.
    var lastActivityMs: Int64 { max(harvestMs, activityMs) }

    /// Seconds since this session last did anything, against the caller's
    /// clock (the builder must pass `Context.nowMs`); 0 when unknown.
    func lastActivitySeconds(at nowMs: Int64) -> Double {
        let last = lastActivityMs
        guard last > 0 else { return 0 }
        return max(0, Double(nowMs - last) / 1000.0)
    }

    /// Whether the agent's plan and words may be quoted as *now*: past 30
    /// minutes of silence a "current step" would be stale wearing fresh
    /// clothes.
    func selfReportFresh(at nowMs: Int64) -> Bool {
        lastActivitySeconds(at: nowMs) <= 30 * 60
    }

    /// A 2.9 hook activity event moved this session now. The stamp feeds
    /// the live-signal clock, never `harvestMs`: the session moved, but its
    /// harvested facts are as old as their harvest.
    mutating func applyActivity(_ event: ActivitySpool.Event, nowMs: Int64) {
        activityMs = max(activityMs, min(event.tsMs, nowMs))
    }

    // MARK: - Stall

    /// The stall rule: twenty minutes of silence from a live session. Not a
    /// setting (23.0); `SnapshotBuilder.Context` carries it so a test can
    /// move it.
    static let stalledSeconds: Double = 20 * 60

    /// Whether a live row would be stalled at the given instant.
    /// `threshold <= 0` turns staleness off; a zero clock is unknown, not
    /// silence.
    static func stalled(lastActivityMs: Int64, nowMs: Int64, threshold: Double = stalledSeconds) -> Bool {
        guard threshold > 0, lastActivityMs > 0 else { return false }
        return Double(nowMs - lastActivityMs) / 1000.0 >= threshold
    }


    // MARK: - Titles

    static var chromeTitles: Set<String> { TitleHeuristics.chromeTitles }

    static func isChromeTitle(_ value: String) -> Bool { TitleHeuristics.isChromeTitle(value) }

    /// The task, when it is a real goal — not a vendor placeholder, the
    /// agent's own name, a slash command, a tool identifier or a lone file.
    var usefulTask: String? {
        let raw = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let t = Self.displayTaskTitle(raw)
        if Self.isChromeTitle(t) { return nil }
        let low = t.lowercased()
        let agent = agent.displayName.lowercased()
        if low == agent { return nil }
        let genericSuffixes = [" session", " thread", " chat", " task", " agent"]
        if genericSuffixes.contains(where: { low == agent + $0 }) { return nil }
        if t.hasPrefix("/"), !t.contains(" ") { return nil }
        if Self.looksLikeInternalToolIdentifier(t) { return nil }
        if TitleHeuristics.looksLikeFilenameOnlyTitle(t) { return nil }
        return t
    }

    /// Session titles are plain UI labels, not a Markdown renderer: keep a
    /// `[label](URL)` link's label, and name a few bare commands.
    static func displayTaskTitle(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(
            of: #"!?\[([^\]\n]{1,240})\]\((?:https?|file)://[^)\n]+\)"#,
            with: "$1",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = cleaned
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "·", with: "")
        switch compact {
        case "piupdate", "updatepi", "upgradepi":
            return "Update Pi and extensions"
        case "pilist", "listpi":
            return "List Pi agents"
        case "update", "upgrade":
            return "Update agent packages"
        case "resume":
            return "Resume agent session"
        default:
            return cleaned
        }
    }

    /// `update_plan`, namespaced MCP leaves, etc. — never a user goal.
    static func looksLikeInternalToolIdentifier(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(" ") else { return false }
        let low = t.lowercased()
        if low.contains(":") { return true } // mcp:server:tool
        let known: Set<String> = [
            "bash", "shell", "exec", "read", "write", "grep", "glob",
            "update_plan", "todowrite", "todo_write", "run_terminal_cmd",
            "run_terminal_command", "batch_execute",
        ]
        if known.contains(low) { return true }
        if low.hasPrefix("mcp_") || low.hasPrefix("mcp.") { return true }
        if low.hasSuffix("_plan") || low.hasSuffix("_todo") { return true }
        if low.hasPrefix("run_") && low.contains("terminal") { return true }
        return false
    }

    static func shortProject(_ raw: String) -> String { TitleHeuristics.shortProject(raw) }

    /// The short project name a row shows beside the agent.
    var shortPlace: String { Self.shortProject(project.isEmpty ? cwd : project) }

    /// `840 B` / `12 KB` / `1.4 MB`. Empty when unknown — an invented "0 KB"
    /// would be a different claim.
    static func compactBytes(_ n: Int) -> String {
        guard n > 0 else { return "" }
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return "\(n / 1024) KB" }
        return String(format: "%.1f MB", Double(n) / (1024.0 * 1024.0))
    }

    /// Where this session lives, written the way a person would write it.
    /// The home directory is not a project, and a deep path keeps its tail.
    var displayPath: String {
        let raw = cwd.isEmpty ? project : cwd
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if Self.isHomeLike(trimmed, home: home) { return "" }
        guard trimmed.hasPrefix("/") else { return Self.shortProject(trimmed) }
        var path = trimmed
        if !home.isEmpty, path.hasPrefix(home + "/") {
            path = "~" + path.dropFirst(home.count)
        }
        let parts = path.split(separator: "/").map(String.init)
        if parts.count > 3 {
            return (path.hasPrefix("~") ? "~/…/" : "/…/") + parts.suffix(2).joined(separator: "/")
        }
        return path
    }

    /// Every spelling of "the home directory" this data can produce
    /// (`-Users-name` decoded to `users-name`, the bare account name, `~`).
    static func isHomeLike(_ raw: String, home: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s == "~" || s == "~/" { return true }
        guard !home.isEmpty else { return false }
        if s == home || s == home + "/" { return true }
        let user = (home as NSString).lastPathComponent.lowercased()
        guard !user.isEmpty else { return false }
        let low = s.lowercased()
        return low == user || low == "users-\(user)" || low == "-users-\(user)"
    }
}

/// Tray rows are grouped under a heading rather than relying on sort order
/// alone — five rows in one undifferentiated stack read as five equals.
enum TraySection: Int, CaseIterable, Hashable {
    case needsYou = 0
    case running = 1
    case stalled = 2
    case recent = 3

    var titleKey: L10n.Key {
        switch self {
        case .needsYou: return .sectionNeedsYou
        case .running: return .sectionRunning
        case .stalled: return .sectionStalled
        case .recent: return .sectionRecent
        }
    }
}

/// Runtime truth for one supported Agent.
///
/// The support matrix says what an adapter is designed to read. This model
/// says what Pulse actually observed on this Mac in the latest good scan.
/// Keeping the two distinct prevents a declared collector from being presented
/// as rich support when the vendor store is missing, unreadable, or changed.
struct AgentSupportHealth: Identifiable, Equatable {
    var agent: AgentID
    var collectorState: ActivityHarvest.CollectorState
    var collectorDurationMs: Int
    var collectorRows: Int
    var sourcePresent: Bool
    var collectorErrorKind: String
    var processDetected: Bool
    var processEvidence: ProcessEvidence?
    /// Earliest matched process start for this Agent, when the probe provided
    /// it. This is process evidence, not session age.
    var processStartedMs: Int64 = 0
    /// Number of matching processes represented by the support row.
    var processCount: Int = 0
    var evidence: ObservationSource?
    var lastSuccessfulReadMs: Int64
    var lastWaitingSignalMs: Int64
    var hasGoal: Bool
    var hasWorkspace: Bool
    var hasActivity: Bool
    var hasProgress: Bool
    var waitingSignalReady: Bool
    /// True when the latest result may be incomplete because the user keeps
    /// protected app-data reads disabled. This is explanatory UI state, not a
    /// claim that the Agent is installed.
    var privacyLimited: Bool = false
    /// Optional operational facts shown separately from the four core facts.
    /// These are inventory signals, not quality gates: an Agent may not expose
    /// a model or resource counter in its local store, but that absence must be
    /// visible instead of silently making every adapter look equivalent.
    var hasActionSignal: Bool = false
    var hasModelSignal: Bool = false
    var hasResourceSignal: Bool = false
    /// Best Focus handle among this Agent's rows this scan — nil means observation only.
    var focusTier: FocusTier? = nil
    /// A real TTY exists but Shortcuts Automation is off — honest, not clickable.
    var focusTTYNeedsOptIn: Bool = false
    /// Seconds since the freshest session activity clock (0 = unknown).
    /// Distinct from `lastSuccessfulReadMs` (Pulse read the adapter).
    var activityAgeSeconds: Double = 0
    /// True when any live row for this Agent is currently marked stalled.
    var hasStalledLive: Bool = false
    /// How the adapter reached the result above: how much it read, whether the
    /// window was truncated, and — when there is no hero title — which layer
    /// lost it. Diagnostic only; it carries counts and fixed tags, never
    /// titles, prompts or vendor paths, and it is never promoted to a tray
    /// fact. It has been collected since 1.2 and until now only reached
    /// debug.log, which meant the one question Support Health exists to answer
    /// — "why is this row empty?" — still cost a terminal to ask.
    var collectorExplain: ActivityHarvest.CollectorExplain = ActivityHarvest.CollectorExplain()
    /// 2.9 · measured fact classes from the latest scan (names only). The
    /// declared tier is a promise; this is what actually came out.
    var factClasses: Set<String> = []
    /// Declared structured, produced rows, zero core facts — drift, not
    /// idleness. See `CollectorHealth.looksDrifted`.
    var looksDrifted: Bool = false

    var id: AgentID { agent }

    var isObserved: Bool { processDetected || evidence != nil }

    var missingCapabilities: [SupportCapability] {
        guard isObserved else { return [.notDetected] }
        var missing: [SupportCapability] = []
        if evidence == .process || !hasActivity { missing.append(.activityFeed) }
        if !hasGoal { missing.append(.goal) }
        if !hasWorkspace { missing.append(.workspace) }
        if agent.waitingSource != .none, !waitingSignalReady {
            missing.append(.waitingSignal)
        }
        return missing
    }

    var observedFactCount: Int {
        [
            hasGoal,
            hasWorkspace,
            hasActivity,
            evidence != nil || processDetected,
        ].filter { $0 }.count
    }

    /// User-value scorecard: goal, workspace, activity, progress, and a usable
    /// Waiting route when that Agent actually exposes one. Process detection is
    /// evidence, not useful content; an Agent with no Waiting contract must not
    /// lose a point for a capability it cannot provide.
    var usefulFactCount: Int {
        var facts = [
            hasGoal,
            hasWorkspace,
            hasActivity,
            hasProgress,
        ]
        if agent.waitingSource != .none {
            facts.append(waitingSignalReady)
        }
        return facts.filter { $0 }.count
    }

    /// Number of useful signals that are meaningful for this Agent's local
    /// contract. This keeps the support UI honest for cloud/opaque agents that
    /// do not expose a Waiting event at all.
    var usefulFactTotal: Int {
        agent.waitingSource == .none ? 4 : 5
    }

    var disposition: SupportDisposition {
        // A scan that ended before this adapter reported is an observation
        // gap, not an adapter failure. The support window shows the global
        // partial-scan banner and preserves the previous per-agent result.
        if collectorState == .unscanned {
            return isObserved ? .limited : .unscanned
        }
        if collectorState.isIssue {
            // A bounded timeout that already returned rows is actionable for
            // diagnostics, but the partial rows are still usable. Keep them
            // visible as limited rather than hiding them behind an error state.
            if collectorState == .failed, collectorRows > 0 { return .limited }
            if collectorState == .permissionDenied { return .permissionDenied }
            return .needsAction
        }
        if privacyLimited && !isObserved { return .permissionDenied }
        if isObserved,
           agent.waitingSource == .hooks,
           !waitingSignalReady {
            return .needsAction
        }
        guard isObserved else {
            if collectorState == .sourceAbsent { return .notInstalled }
            return .noRecentSession
        }
        if collectorState == .noSessions || collectorState == .noRecentData {
            return .noRecentSession
        }
        if evidence == .process
            || !hasGoal
            || !hasWorkspace
            || !hasActivity
            || !hasProgress
            || (agent.waitingSource != .none && !waitingSignalReady) {
            return .limited
        }
        return .available
    }

    var repair: SupportRepair {
        if disposition == .needsAction,
           agent.waitingSource == .hooks,
           !waitingSignalReady {
            return .installHooks
        }
        if disposition == .permissionDenied { return .openSettings }
        if collectorState.isIssue { return .retry }
        // Live opaque agents cannot invent Waiting — point at the Attention bridge.
        if agent.waitingSource == .none, processDetected {
            return .openAttentionBridge
        }
        return .none
    }
}

enum SupportDisposition: Int, Equatable {
    case available = 0
    case needsAction = 1
    case limited = 2
    case notInstalled = 3
    case noRecentSession = 4
    case permissionDenied = 5
    case unscanned = 6
}

enum SupportRepair: Equatable {
    case none
    case installHooks
    case retry
    case openSettings
    case runAgent
    case openAttentionBridge
}

enum SupportCapability: String, Equatable {
    case notDetected
    case activityFeed
    case goal
    case workspace
    case waitingSignal
}

struct PulseSnapshot: Equatable {
    var glance: GlanceKind = .idle
    var title: String = ""
    /// One line: the rule that set the lamp (`LampExplanation.sentence`).
    var tooltip: String = "Pulse"
    /// Glance state spoken by VoiceOver, in the resolved language.
    var accessibilityLabel: String = ""
    /// The census VoiceOver announces when it changes ("1 needs you · 2
    /// running"), counted by row state.
    var headerTitle: String = ""
    var rows: [AgentRow] = []
    /// Section totals over the *whole* list, so a heading can say "3 running"
    /// even when the window is showing two of them.
    var sectionTotals: [TraySection: Int] = [:]
    var hiddenCount: Int = 0
    /// Sessions suppressed by the per-agent cap (never silently dropped).
    var cappedSessions: Int = 0
    /// 21.0: sessions older than the fresh window, left out of the list —
    /// and which agents they belong to. A row that went quiet for 46
    /// minutes used to vanish with no trace outside debug.log.
    var staleHidden: Int = 0
    /// 23.0: the menu-bar lamp's shape and tone (`LampFace.glance`).
    var lamp: LampFace = .idle
    var staleHiddenAgents: [AgentID] = []
    var totalCount: Int = 0
    var updatedAt: Date = .distantPast
}
