import Foundation

/// Single source of truth for the product version.
///
/// `semver` is the truth; `scripts/version_check.py` keeps the CHANGELOG and
/// the README badge from drifting away from it. Build metadata (commit, date)
/// is injected into `Info.plist` by `PulseBar/Scripts/package.sh`, so a `swift
/// run` build honestly reports itself as `dev` instead of faking a release id.
enum PulseVersion {
    static let semver = "24.0.0"

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

/// 23.0 · what a blocked row is blocked on. 24.0: always a hook's blocked
/// event — the only source of a wait.
struct RowWait: Hashable, Sendable {
    /// Protocol token (`Permission` / `Input` / `Waiting`), never user copy —
    /// `L10n.waitKind` translates it.
    var kind: String
    /// What the agent asked, in its own words (sanitized); "" when unknown.
    var ask: String = ""
    /// When the wait was raised, by the hook's own clock; 0 = unknown.
    var sinceMs: Int64 = 0
    /// 16.0: the prompt's own window was frontmost when it was raised — the
    /// lamp still lights, but no banner and no sound.
    var inFront: Bool = false
}

/// 23.0 · the one state a row is in, decided once (24.0: by
/// `TrayState`, from the session book).
enum RowState: Hashable, Sendable {
    /// Red: the vendor's hook reported a permission request or a question.
    case blocked(RowWait)
    /// The session took a prompt or reported work, and nothing since says
    /// otherwise.
    case running
    /// 16.0: the agent finished its turn and nobody has looked since. From
    /// hooks only; never red.
    case yourTurn(sinceMs: Int64)
    /// At its prompt with nothing owed, ended, or quiet past what Pulse can
    /// vouch for.
    case recent
    /// An agent process no session has claimed — typically one started
    /// before Pulse was running. Ephemeral: once a hook event names its
    /// session, the process belongs to that row.
    case processOnly
}

/// 24.0 · why a session is shown as recent rather than live.
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

/// 23.0 · where a row's facts came from, in the words `Explain` uses.
enum RowSource: String, Equatable, Hashable, Sendable {
    /// The agent's own hook events.
    case hooks
    /// Only a process (the process table).
    case process
}

/// One tray row: a session (or a process no session has claimed) and
/// exactly what the tray row, the detail page, the lamp and the notifier
/// read. `Explain` builds the few sentences Pulse says from what is here.
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

    // MARK: What it is doing (24.0: from its transcript, read lazily)

    /// The session's title: the vendor's own name, else the first prompt.
    var task: String = ""
    var model: String = ""
    /// The first line of the agent's latest message (self-report tier).
    var lastWord: String = ""
    /// The first line of the latest error the transcript holds.
    var lastErrorText: String = ""

    // MARK: State

    var state: RowState = .recent
    /// Why a `.recent` row is recent — `Explain` says the rule.
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
    /// whose agent reports its work (24.0: one that has sent an activity
    /// event). Not a setting; `TrayState.Context` carries it so a
    /// test can move it.
    static let stalledSeconds: Double = 20 * 60

    /// Whether a live row would be stalled at the given instant.
    /// `threshold <= 0` turns staleness off; a zero clock is unknown, not
    /// silence.
    static func stalled(lastActivityMs: Int64, nowMs: Int64, threshold: Double = stalledSeconds) -> Bool {
        guard threshold > 0, lastActivityMs > 0 else { return false }
        return Double(nowMs - lastActivityMs) / 1000.0 >= threshold
    }


    // MARK: - Titles

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

struct PulseSnapshot: Equatable {
    var glance: GlanceKind = .idle
    var title: String = ""
    /// One line: the rule that set the lamp (`Explain.lampSentence`).
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
    /// 21.0: sessions quiet past the recent window, left out of the list —
    /// and which agents they belong to (the last 24 hours only).
    var staleHidden: Int = 0
    /// 23.0: the menu-bar lamp's shape and tone (`LampFace.glance`).
    var lamp: LampFace = .idle
    var staleHiddenAgents: [AgentID] = []
    var totalCount: Int = 0
    var updatedAt: Date = .distantPast
}
