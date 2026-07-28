import Foundation

/// Single source of truth for the product version.
///
/// `semver` is the truth; `scripts/version_check.py` keeps the CHANGELOG and
/// the README badge from drifting away from it. Build metadata (commit, date)
/// is injected into `Info.plist` by `PulseBar/Scripts/package.sh`, so a `swift
/// run` build honestly reports itself as `dev` instead of faking a release id.
enum PulseVersion {
    static let semver = "0.27.2"

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

enum AgentID: String, CaseIterable, Identifiable, Hashable {
    case claude, codex, cursor, cursorAgent = "cursor_agent"
    case grok, pi, amp, aider, gemini, copilot
    case opencode, goose, openhands, cline, roo, continue_ = "continue"
    case amazonQ = "amazon_q"
    case cascade, windsurf, augment, zedAgent = "zed_agent"
    case trae, warpAgent = "warp_agent"
    case devin, kiro, junie, kilo, replit
    case droid, commandCode = "command_code", antigravity, kimi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .cursorAgent: return "Cursor Agent"
        case .grok: return "Grok"
        case .pi: return "Pi"
        case .amp: return "Amp"
        case .aider: return "Aider"
        case .gemini: return "Gemini"
        case .copilot: return "Copilot"
        case .opencode: return "OpenCode"
        case .goose: return "Goose"
        case .openhands: return "OpenHands"
        case .cline: return "Cline"
        case .roo: return "Roo"
        case .continue_: return "Continue"
        case .amazonQ: return "Amazon Q"
        case .cascade: return "Cascade"
        case .windsurf: return "Windsurf"
        case .augment: return "Augment"
        case .zedAgent: return "Zed Agent"
        case .trae: return "Trae"
        case .warpAgent: return "Warp Agent"
        case .devin: return "Devin"
        case .kiro: return "Kiro"
        case .junie: return "Junie"
        case .kilo: return "Kilo"
        case .replit: return "Replit"
        case .droid: return "Droid"
        case .commandCode: return "Command Code"
        case .antigravity: return "Antigravity"
        case .kimi: return "Kimi"
        }
    }

    // `isSurface` used to gate Glance/Tray, but every case returned true — the
    // whole AgentID list is the surface list. The vacuous filter is gone; if a
    // non-surface id ever lands here, reintroduce the predicate deliberately.

    /// Honest Waiting path exists (hooks and/or harvest `skill=pending`).
    /// Agents with `.none` may still show Running; tray can nudge once.
    var waitingSource: WaitingSource {
        switch self {
        case .claude, .codex:
            return .hooks
        case .cursor, .cursorAgent, .gemini, .opencode, .amp, .aider, .goose,
             .cline, .roo, .continue_, .copilot, .amazonQ, .cascade, .windsurf,
             .augment, .zedAgent, .openhands, .grok, .pi, .kilo, .kiro,
             .droid, .commandCode, .kimi:
            return .harvestPending
        // Opaque / cloud-first / IDE-shell: probe (+best-effort harvest) only.
        case .replit, .antigravity, .trae, .warpAgent, .devin, .junie:
            return .none
        }
    }

    static let priority: [AgentID] = [
        .claude, .cursorAgent, .codex, .droid, .kimi, .commandCode, .devin,
        .antigravity, .cascade, .windsurf, .kiro, .junie, .kilo, .augment,
        .grok, .pi, .amp, .aider, .gemini, .copilot, .opencode, .goose,
        .openhands, .cline, .roo, .continue_, .amazonQ, .zedAgent, .trae,
        .warpAgent, .replit, .cursor,
    ]
}

enum WaitingSource {
    case hooks
    case harvestPending
    case none
}

/// How this row's Waiting was raised (shown as a short credibility tag).
enum WaitSignalKind: String, Equatable {
    case hooks
    case pending
}

/// Honesty tier for Focus — never claim TTY when we only have cwd.
enum FocusTier: Equatable {
    case tty
    case warp
    case openCwd
}

enum GlanceKind: Equatable {
    case idle
    case running
    case waiting
    case error

    /// VoiceOver reads this instead of the icon. It used to be hardcoded
    /// English, so a Chinese user heard "Needs attention" in an otherwise
    /// localized interface.
    var accessibilityKey: L10n.Key {
        switch self {
        case .idle: return .a11yIdle
        case .running: return .a11yRunning
        case .waiting: return .a11yWaiting
        case .error: return .a11yError
        }
    }
}

struct AgentRow: Identifiable, Hashable {
    /// Unique tray row (multi-session: agent|session or agent|project).
    var rowKey: String
    /// Agent product identity.
    var agent: AgentID
    /// Optional session / composer / rollout id for attention matching.
    var sessionID: String = ""
    var project: String = ""
    var task: String = ""
    var cwd: String = ""
    var waiting: Bool = false
    var waitKind: String = ""
    var waitMessage: String = ""
    /// hooks vs harvest pending — for tray credibility tag.
    var waitSignal: WaitSignalKind? = nil
    var viaWarp: Bool = false
    var processCount: Int = 0
    var tokensIn: Int = 0
    var tokensOut: Int = 0
    var tool: String = ""
    var skill: String = ""
    var waitSinceMs: Int64 = 0
    var pid: Int = 0
    var tty: String = ""
    var harvestMs: Int64 = 0
    var subRunning: Int = 0
    var subTotal: Int = 0
    /// True when a live process was matched (not harvest-only).
    var liveProcess: Bool = false
    /// How this row can be focused — resolved once per scan, never in a view body.
    var focusTier: FocusTier? = nil
    /// cwd/project exists on disk — resolved once per scan.
    var canOpenFolder: Bool = false
    /// Sessions of this agent that exist but did not fit the per-agent cap.
    var hiddenSessions: Int = 0
    /// Seconds left on a "remind me later", resolved at scan time. 0 = not snoozed.
    ///
    /// Snoozing suppresses the *interruption* — lamp, menu-bar text, banner —
    /// and nothing else. The row stays in the list, in Needs-you, with the
    /// remaining time on its chip. This mirrors the rule muting already
    /// follows: a muted agent stops notifying and still appears. A button that
    /// makes a row disappear is a button nobody dares press.
    var snoozeRemainingSeconds: Double = 0

    var isSnoozed: Bool { waiting && snoozeRemainingSeconds > 0 }

    var id: String { rowKey }

    var titleLine: String {
        var parts: [String] = [agent.displayName]
        let short = Self.shortProject(project)
        if !short.isEmpty {
            parts.append(short)
        } else if let hint = shortSessionHint {
            // No project — show short session so multi-row agents stay distinguishable.
            parts.append(hint)
        }
        if processCount > 1 { parts.append("×\(processCount)") }
        if viaWarp { parts.append("via Warp") }
        return parts.joined(separator: " · ")
    }

    /// Short session id for tray disambiguation (never the full uuid).
    var shortSessionHint: String? {
        let sid = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sid.isEmpty else { return nil }
        if sid.count <= 10 { return sid }
        return String(sid.suffix(8))
    }

    // Waiting reason lines are built in `StatusStore.localizedWaitDetail` so
    // durations and kinds follow the resolved language.

    var taskLine: String? {
        let t = task.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Drop placeholder harvest titles that aren't real session detail.
    var usefulTask: String? {
        guard let t = taskLine else { return nil }
        let junk: Set<String> = [
            "-", "—", "Running", "Active", "none",
            "Agent session", "Chat", "Amp session", "Amp thread",
            // Placeholders that shipped as row titles in 0.25.
            "New Session", "New session", "Untitled", "New Chat", "New chat",
        ]
        if junk.contains(t) { return nil }
        if t.hasPrefix("/"), !t.contains(" ") { return nil }
        return t
    }

    /// First-class session detail for tray (task title). Tool-only falls back for live rows.
    var sessionDetail: String? {
        if let t = usefulTask { return t }
        if waiting { return nil }
        let toolTrim = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        if !toolTrim.isEmpty, liveProcess || subRunning > 0 { return toolTrim }
        return nil
    }

    /// Recent (not live) rows may soft-prefix with L10n activityPrefix in the view.
    var isRecentOnly: Bool {
        !waiting && !liveProcess && subRunning == 0
    }

    /// Live / subagent with nothing to say about the session — secondary in list IA.
    /// Uses `sessionDetail` (task, else the current tool) so a live row running
    /// a known tool no longer degrades to a bare "Process detected".
    var isProcessOnly: Bool {
        !waiting && (liveProcess || subRunning > 0) && sessionDetail == nil
    }

    /// Has a first-class session title (sorts above process-only peers).
    var hasSessionTitle: Bool { usefulTask != nil }


    /// `↑12k ↓3k` — how much this session has actually moved.
    ///
    /// The only quantity the app has, and until 0.28 it lived behind a hover
    /// and then behind an expand. A panel whose rows carry a name, a path and
    /// a relative time has nothing on it that changes as work happens; this
    /// does. Waiting rows omit it, because there the question is the point.
    var tokenLine: String? {
        guard !waiting else { return nil }
        let tin = Self.compactToken(tokensIn)
        let tout = Self.compactToken(tokensOut)
        guard !tin.isEmpty || !tout.isEmpty else { return nil }
        var tok = ""
        if !tin.isEmpty { tok += "↑\(tin)" }
        if !tout.isEmpty {
            if !tok.isEmpty { tok += " " }
            tok += "↓\(tout)"
        }
        return tok
    }

    /// Compact meta: "↑12k ↓3k · Bash · sub 2↑/5"
    /// Waiting rows omit tokens (status first). Tool alone goes to sessionDetail when no task.
    var metaLine: String? {
        var bits: [String] = []
        if let tok = tokenLine { bits.append(tok) }
        if !tool.isEmpty, usefulTask != nil { bits.append(tool) }
        if !skill.isEmpty, skill != "pending" { bits.append(skill) }
        if let sub = subagentLine { bits.append(sub) }
        // When project already in title, still hint session if both exist (multi-session same project).
        if let hint = shortSessionHint, !Self.shortProject(project).isEmpty {
            bits.append(hint)
        }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    /// e.g. `sub 2↑/5` when Claude has parallel subagents.
    var subagentLine: String? {
        guard subTotal > 0 else { return nil }
        if subRunning > 0 {
            return "sub \(subRunning)↑/\(subTotal)"
        }
        return "sub \(subTotal)"
    }

    var canFocusTerminal: Bool { focusTier != nil }

    static func shortProject(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        if s.contains("/") {
            s = (s as NSString).lastPathComponent
        }
        if s.range(of: #"^[0-9a-fA-F-]{16,}$"#, options: .regularExpression) != nil { return "" }
        if s.count > 24 { return String(s.prefix(23)) + "…" }
        return s
    }

    static func compactToken(_ n: Int) -> String {
        guard n > 0 else { return "" }
        if n < 1000 { return "\(n)" }
        if n < 10_000 { return String(format: "%.1fk", Double(n) / 1000.0) }
        if n < 1_000_000 { return "\(n / 1000)k" }
        // Soft magnitude — avoid accounting-style millions in a status lamp.
        return String(format: "%.1fM", Double(n) / 1_000_000.0)
    }

    /// Seconds a Waiting row has been outstanding (0 when unknown).
    /// Formatting lives in `StatusStore.waitDurationLabel` so units localize.
    var waitAgeSeconds: Double {
        guard waitSinceMs > 0 else { return 0 }
        return max(0, Date().timeIntervalSince1970 - Double(waitSinceMs) / 1000.0)
    }

    /// Where this session lives, written the way a person would write it.
    ///
    /// `cwd` has been collected since the beginning and never shown. The tray
    /// could say who and what, but never *where* — so two Claude sessions in
    /// different repos were indistinguishable.
    var displayPath: String {
        let raw = cwd.isEmpty ? project : cwd
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // The home directory is not a project.
        //
        // 0.25 rendered it as "~" and grouped sessions under it, then a session
        // that had no cwd fell back to its harvest-encoded project name and the
        // *same* directory appeared a second time as "users-<name>". One
        // location, two groups, and a header claiming three projects where
        // there were two.
        if Self.isHomeLike(trimmed, home: home) { return "" }

        guard trimmed.hasPrefix("/") else { return Self.shortProject(trimmed) }
        var path = trimmed
        if !home.isEmpty, path.hasPrefix(home + "/") {
            path = "~" + path.dropFirst(home.count)
        }
        // Keep the tail: the last two components carry the identity, the
        // middle of a deep path does not.
        let parts = path.split(separator: "/").map(String.init)
        if parts.count > 3 {
            return (path.hasPrefix("~") ? "~/…/" : "/…/") + parts.suffix(2).joined(separator: "/")
        }
        return path
    }

    /// Every spelling of "the home directory" this data can produce.
    ///
    /// Harvest hands back either a real path or a decoded form of Claude's
    /// encoded project directory (`-Users-name` → `users-name`), so the same
    /// place arrives under several names and has to be collapsed before it can
    /// be grouped or counted.
    static func isHomeLike(_ raw: String, home: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s == "~" || s == "~/" { return true }
        guard !home.isEmpty else { return false }
        if s == home || s == home + "/" { return true }
        let user = (home as NSString).lastPathComponent.lowercased()
        guard !user.isEmpty else { return false }
        let low = s.lowercased()
        // `-Users-name` decoded to `users-name`, and the bare account name.
        return low == user || low == "users-\(user)" || low == "-users-\(user)"
    }

    /// Seconds since this session last did anything (0 when unknown).
    ///
    /// `harvestMs` is the last-activity stamp. "Running for 20 minutes with
    /// nothing happening" is a real signal, and the tray never carried it.
    var lastActivitySeconds: Double {
        guard harvestMs > 0 else { return 0 }
        return max(0, Date().timeIntervalSince1970 - Double(harvestMs) / 1000.0)
    }

    /// Running with a live session is the ordinary case, and the ordinary case
    /// does not need a badge. Only states worth reacting to get one.
    var needsStatusChip: Bool {
        if waiting || isProcessOnly || isRecentOnly || isStalled { return true }
        return false
    }

    /// Live, but nothing has moved for a long time.
    ///
    /// As real a signal as Waiting and never surfaced: an agent that has been
    /// "running" for twenty minutes without touching anything is usually stuck
    /// on something, and the tray showed it exactly like a healthy session.
    /// Default only. The real threshold comes from settings and rides in on
    /// `SnapshotBuilder.Context` — twenty minutes is right for nobody in
    /// particular: a long compile is not stalled at twenty, and a short
    /// question-and-answer session is stuck well before it.
    static let stalledSeconds: Double = 20 * 60

    /// Resolved once per scan against the scan's own clock, not `Date()`.
    ///
    /// As a computed property this reached for the real clock while the builder
    /// around it ran on an injected `nowMs` — so with a fixed test clock every
    /// row read as stalled by years. `focusTier` and `canOpenFolder` were moved
    /// to scan time in 0.23 for the same reason.
    var isStalled: Bool = false

    /// Whether this row would be stalled at the given instant.
    ///
    /// `threshold <= 0` means the user turned staleness off, which must read as
    /// "never stalled" rather than "always stalled".
    static func stalled(
        harvestMs: Int64,
        nowMs: Int64,
        waiting: Bool,
        live: Bool,
        threshold: Double = stalledSeconds
    ) -> Bool {
        guard threshold > 0, !waiting, live, harvestMs > 0 else { return false }
        return Double(nowMs - harvestMs) / 1000.0 >= threshold
    }

    /// A wait old enough to deserve more than the ordinary Waiting treatment.
    /// This is the *only* place "longer" becomes "louder" — every other visual
    /// encoding stays constant, so the escalation actually reads as one.
    static let urgentWaitSeconds: Double = 600

    var isUrgentWait: Bool { waiting && waitAgeSeconds >= Self.urgentWaitSeconds }

    /// Which tray section this row belongs to.
    var section: TraySection {
        if waiting { return .needsYou }
        if liveProcess || subRunning > 0 { return .running }
        return .recent
    }
}

/// Tray rows are grouped under a heading rather than relying on sort order
/// alone — five rows in one undifferentiated stack read as five equals.
enum TraySection: Int, CaseIterable, Hashable {
    case needsYou = 0
    case running = 1
    case recent = 2

    var titleKey: L10n.Key {
        switch self {
        case .needsYou: return .sectionNeedsYou
        case .running: return .sectionRunning
        case .recent: return .sectionRecent
        }
    }
}

struct PulseSnapshot: Equatable {
    var glance: GlanceKind = .idle
    var title: String = ""
    var tooltip: String = "Pulse"
    /// Glance state spoken by VoiceOver, in the resolved language.
    var accessibilityLabel: String = ""
    /// Short status word for tray header (Needs you / Running / …).
    var headerTitle: String = ""
    /// Supporting line under headerTitle (names · relative time).
    var headerDetail: String = ""
    var header: String = "No coding agents"
    var rows: [AgentRow] = []
    /// Section totals over the *whole* list, so a heading can say "3 running"
    /// even when the window is showing two of them.
    var sectionTotals: [TraySection: Int] = [:]
    /// Distinct projects across the whole list — an aggregate no single row
    /// can state, which is the only kind of thing the header should say.
    var projectCount: Int = 0
    /// Longest outstanding wait, in seconds — the number that decides who to
    /// deal with first, so it reaches the menu bar rather than staying buried
    /// in a row's third line.
    var longestWaitSeconds: Double = 0
    var hiddenCount: Int = 0
    /// Sessions suppressed by the per-agent cap (never silently dropped).
    var cappedSessions: Int = 0
    var totalCount: Int = 0
    var probeError: String?
    var updatedAt: Date = .distantPast
}

/// Which tray groups fold, and what a folded group still says.
///
/// Screenshots of 0.25.0 showed four rows, two of them Recent — finished
/// sessions, nothing to act on, taking half the panel and half the reading.
/// Folding them is the largest space win available without dropping a fact.
enum TrayFold {
    /// Below this many rows the panel is not crowded, so nothing folds.
    ///
    /// A 0.27 screenshot showed three sessions with two of them folded away —
    /// one visible row in a panel that had room for all three. Folding traded a
    /// line of screen for a click and hidden content, which is only a good
    /// trade when the screen is the scarce thing. It was not.
    static let crowdedFrom = 5

    /// A project group folds when nothing in it is waiting.
    ///
    /// `foldable` only ever answered for the Recent *section*, so grouping by
    /// project — the mode built for people running several repos at once — was
    /// the one mode where nothing folded and the panel was a flat list of every
    /// project. Same two guards as Recent, plus the one that matters here: a
    /// project holding a wait is never folded away.
    static func foldableProject(
        hasWaiting: Bool,
        groupCount: Int,
        rowCount: Int,
        totalRows: Int
    ) -> Bool {
        !hasWaiting && groupCount > 1 && rowCount >= 2 && totalRows >= crowdedFrom
    }

    /// Recent is foldable, but only when it is not the whole list.
    ///
    /// If Recent is all there is, those rows *are* the content and folding
    /// them leaves a panel that says nothing. The rule is "hide the part you
    /// are not here for", which requires there to be another part.
    static func foldable(
        section: TraySection,
        groupCount: Int,
        rowCount: Int,
        totalRows: Int
    ) -> Bool {
        section == .recent && groupCount > 1 && rowCount >= 2 && totalRows >= crowdedFrom
    }

    /// True when the summary names every row, making the count a repeat.
    ///
    /// Three Claude sessions summarise to "Claude" — one name for three rows,
    /// so the count is still the only thing saying how many. Two rows named
    /// "Pi · Amp" are a different case: the names *are* the count.
    static func summaryNamesEveryRow(_ rows: [AgentRow], limit: Int = 3) -> Bool {
        let distinct = Set(rows.map(\.agent)).count
        return distinct == rows.count && rows.count <= limit
    }

    /// Agents in the folded group, in first-seen order, deduplicated.
    ///
    /// A folded heading otherwise reads "Recent 3" — a count with no identity,
    /// which is exactly the question folding creates.
    static func summary(_ rows: [AgentRow], limit: Int = 3) -> String {
        var seen = Set<AgentID>()
        var names: [String] = []
        for row in rows where !seen.contains(row.agent) {
            seen.insert(row.agent)
            names.append(row.agent.displayName)
        }
        guard !names.isEmpty else { return "" }
        if names.count <= limit { return names.joined(separator: " · ") }
        return names.prefix(limit).joined(separator: " · ") + " +\(names.count - limit)"
    }
}
