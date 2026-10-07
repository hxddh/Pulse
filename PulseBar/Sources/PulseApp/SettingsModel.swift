import Foundation

/// Settings as a value: one page, three short groups, a footer.
///
/// General (open at login) · Notifications (whether macOS allows banners) ·
/// Hooks — the diagnostics: Install all / Remove all, one line per agent on
/// this Mac (installed or not, its last event, why an install failed), the
/// agents that are not here collapsed into one line, and "Copy report". The
/// version, the kind of build and "Releases…" are the footer. The language
/// is the system's. `SettingsFace` renders this and sends `Action`s; the
/// store builds it from `settings` and a few flags — never from a scan.
/// Pure.
struct SettingsModel: Equatable {
    enum Section: String, CaseIterable, Equatable {
        case general, notifications, hooks
    }

    /// Whether macOS lets Pulse post a banner.
    enum Notifications: Equatable { case notAsked, denied, allowed }

    /// What the login line says under its toggle, when it has something
    /// to say.
    enum LoginNote: Equatable {
        /// Registered, and macOS waits for the person in Login Items.
        case needsApproval
        /// Asked for, and macOS did not take it.
        case failed
    }

    enum Action: Equatable {
        case setLaunchAtLogin(Bool)
        case openLoginItems
        case enableNotifications
        case openNotificationSettings
        /// Every agent on this Mac.
        case installHooks
        /// Every agent's hook.
        case uninstallHooks
        case copyReport
        /// The footer's "Releases…": Pulse's releases page, in the browser.
        case openReleases
    }

    /// Where "Releases…" goes. Pulse itself never asks the network.
    static let releasesURL = "https://github.com/hxddh/Pulse/releases"

    var lang: ResolvedLanguage
    // General
    /// The toggle: what macOS says (`LoginItemState`), else what was asked.
    var launchAtLogin: Bool
    var loginNote: LoginNote? = nil
    // Notifications
    var notifications: Notifications
    // Hooks
    var hooksStatus: String
    var hooksInstalled: Bool
    /// An install or removal is running: every hook button waits for it.
    var hooksBusy: Bool = false
    /// One line per agent on this Mac (or carrying Pulse's hook), in roster
    /// order.
    var hookAgents: [HookAgent] = []
    /// The agents that are not on this Mac, said once: "Not on this Mac: …".
    var absentAgents: [AgentID] = []
    // Footer
    var version: String
    /// Said in orange: a preview or unnotarized build, or a stale bundle.
    var buildWarning: String?
    /// Where a deep link asked the page to scroll.
    var focus: Section?

    /// One agent's hook, as the Hooks section says it.
    struct HookAgent: Equatable, Identifiable {
        var agent: AgentID
        /// Installed / not installed, or why the last install failed.
        var state: String
        var installed: Bool
        /// "last event 12s ago" / "no event yet"; empty when not installed.
        var lastEvent: String
        /// Said for an agent whose hook never reports a wait.
        var note: String?
        /// The last install or removal failed for this agent (the state
        /// says why, in words from `L10n`).
        var failed = false

        var id: AgentID { agent }
    }

    /// Pure: the Hooks section's lines, in roster order — every agent that
    /// is on this Mac, carries Pulse's hook, or failed its last install. The
    /// rest are `absentAgents`.
    static func hookAgents(
        installed: Set<AgentID>,
        present: Set<AgentID>,
        lastEventMs: [AgentID: Int64],
        nowMs: Int64,
        lang: ResolvedLanguage,
        failed: [AgentID: HooksInstaller.Failure] = [:]
    ) -> [HookAgent] {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        return AgentID.priority.compactMap { agent in
            let isInstalled = installed.contains(agent)
            let failure = failed[agent]
            guard isInstalled || present.contains(agent) || failure != nil else { return nil }
            let state: String
            if let failure {
                state = t(.hooksFailed) + " · " + HooksSupport.Status.reason(failure, lang: lang)
            } else if isInstalled {
                state = t(.settingsHookInstalled)
            } else {
                state = t(.hooksMissing)
            }
            var lastEvent = ""
            if isInstalled {
                if let ms = lastEventMs[agent], ms > 0 {
                    let seconds = Double(max(0, nowMs - ms)) / 1000
                    lastEvent = seconds < 5
                        ? t(.settingsHookLastEventNow)
                        : String(format: t(.settingsHookLastEvent), DurationFormat.label(seconds: seconds, lang: lang, spoken: true))
                } else {
                    lastEvent = t(.settingsHookNoEvent)
                }
            }
            return HookAgent(
                agent: agent,
                state: state,
                installed: isInstalled,
                lastEvent: lastEvent,
                note: agent.waitingSource == .none ? t(.settingsHookNoWait) : nil,
                failed: failure != nil
            )
        }
    }

    /// Pure: the agents with no line of their own — not on this Mac, no
    /// hook, no failure — in roster order.
    static func absentAgents(
        installed: Set<AgentID>,
        present: Set<AgentID>,
        failed: [AgentID: HooksInstaller.Failure] = [:]
    ) -> [AgentID] {
        AgentID.priority.filter { agent in
            !installed.contains(agent) && !present.contains(agent) && failed[agent] == nil
        }
    }

    /// "Not on this Mac: Pi, OpenCode" — nil when every agent is here.
    static func absentLine(_ agents: [AgentID], lang: ResolvedLanguage) -> String? {
        guard !agents.isEmpty else { return nil }
        return String(format: L10n.t(.settingsHookAbsent, lang), L10n.joinNames(agents.map(\.displayName), lang))
    }

    // MARK: - The report

    /// What "Copy report" puts on the clipboard: plain text, English, no
    /// path, prompt, session id or project — the version, each agent's hook
    /// and when it last reported, whether macOS allows banners, the login
    /// item as macOS sees it, and how Pulse reads each listed
    /// session (the detail page does not say it).
    struct ReportInput: Equatable {
        var version: String
        var macOS: String
        var installed: Set<AgentID>
        var present: Set<AgentID>
        var failed: [AgentID: HooksInstaller.Failure] = [:]
        var lastEventMs: [AgentID: Int64]
        var nowMs: Int64
        /// nil: macOS has not been asked yet.
        var notifyAuthorized: Bool?
        var launchAtLogin: Bool
        /// What macOS says of Pulse's login item; nil when not read.
        var loginItem: LoginItemState? = nil
        /// Every listed session, as the few facts that say how Pulse reads it.
        var sessions: [ReportSession] = []
    }

    /// How Pulse reads one session, without naming it: its state, where
    /// its facts come from, how a click lands, whether its process is
    /// watched, and when it last spoke.
    struct ReportSession: Equatable {
        var agent: AgentID
        var state: String
        var source: RowSource
        var go: LandingPlan.Precision?
        var liveProcess: Bool
        var lastEventMs: Int64

        init(_ row: AgentRow) {
            agent = row.agent
            switch row.state {
            case .blocked: state = "blocked"
            case .running: state = row.isStalled ? "stalled" : "running"
            case .yourTurn: state = "your turn"
            case .recent: state = "recent"
            case .processOnly: state = "process only"
            }
            source = row.source
            go = row.landingPlan.precision
            liveProcess = row.liveProcess
            lastEventMs = row.lastEventMs
        }

        func line(nowMs: Int64) -> String {
            let goWord: String
            switch go {
            case .exact: goWord = "exact"
            case .app: goWord = "app only"
            case nil: goWord = "none"
            }
            var text = "  \(agent.rawValue): \(state), from \(source == .hooks ? "hooks" : "process only"), go \(goWord)"
            text += liveProcess ? ", process watched" : ", no process"
            text += lastEventMs > 0 ? ", last event \(max(0, (nowMs - lastEventMs) / 1000))s ago" : ", no event"
            return text
        }
    }

    static func report(_ input: ReportInput) -> String {
        let authorization: String
        switch input.notifyAuthorized {
        case .some(true): authorization = "allowed"
        case .some(false): authorization = "denied"
        case .none: authorization = "not asked"
        }
        var lines: [String] = [
            "Pulse report",
            input.version,
            "macOS \(input.macOS)",
            "notifications: \(authorization)",
            "open at login: \(input.launchAtLogin ? "on" : "off"), macOS: \(input.loginItem?.reportWord ?? "not read")",
            "hooks:",
        ]
        for agent in AgentID.priority {
            let state: String
            if let failure = input.failed[agent] {
                state = "install failed (\(failure.rawValue))"
            } else if input.installed.contains(agent) {
                state = "installed"
            } else if input.present.contains(agent) {
                state = "not installed"
            } else {
                state = "not on this Mac"
            }
            var line = "  \(agent.rawValue): \(state)"
            if input.installed.contains(agent) {
                if let ms = input.lastEventMs[agent], ms > 0 {
                    line += ", last event \(max(0, (input.nowMs - ms) / 1000))s ago"
                } else {
                    line += ", no event yet"
                }
            }
            lines.append(line)
        }
        lines.append(input.sessions.isEmpty ? "sessions: none listed" : "sessions:")
        lines += input.sessions.map { $0.line(nowMs: input.nowMs) }
        return lines.joined(separator: "\n")
    }

    /// The hook work an action asks for; nil for any other action. Pure.
    static func hooksJob(_ action: Action) -> HooksSupport.Job? {
        switch action {
        case .installHooks: return .install
        case .uninstallHooks: return .uninstall
        default: return nil
        }
    }

    /// The page, top to bottom.
    static let sections: [Section] = [.general, .notifications, .hooks]

    /// A deep link's target, as the section it scrolls to.
    static func section(for target: SettingsFocus.Target) -> Section {
        switch target {
        case .waitingSignals: return .hooks
        case .notifications: return .notifications
        }
    }

    static func title(_ section: Section, lang: ResolvedLanguage) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        switch section {
        case .general: return t(.general)
        case .notifications: return t(.notificationsSection)
        case .hooks: return t(.settingsHooksSection)
        }
    }

    /// The login toggle and its line, from what was asked and what macOS
    /// says (nil: not read yet). The toggle shows macOS's answer — Pulse
    /// is in Login Items or it is not — and a line says when macOS waits for
    /// approval or did not take a request. Pure.
    static func loginLine(asked: Bool, state: LoginItemState?) -> (isOn: Bool, note: LoginNote?) {
        guard let state else { return (asked, nil) }
        switch state {
        case .enabled: return (true, nil)
        case .requiresApproval: return (true, .needsApproval)
        case .off, .unavailable: return (false, asked ? .failed : nil)
        }
    }

    static func notifications(_ authorized: Bool?) -> Notifications {
        switch authorized {
        case .some(true): return .allowed
        case .some(false): return .denied
        case .none: return .notAsked
        }
    }
}

/// Pulse's login item as macOS reports it (`SMAppService.mainApp.status`,
/// read by `LoginItem`). Pure.
enum LoginItemState: String, Equatable, Sendable {
    /// Not registered.
    case off
    case enabled
    /// Registered; macOS waits for the person in System Settings → Login
    /// Items.
    case requiresApproval
    /// macOS cannot find the app to register (a build outside a bundle).
    case unavailable

    /// Pulse opens at login, or will once approved.
    var isOn: Bool { self == .enabled || self == .requiresApproval }

    var reportWord: String {
        switch self {
        case .off: return "not registered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval"
        case .unavailable: return "unavailable"
        }
    }
}
