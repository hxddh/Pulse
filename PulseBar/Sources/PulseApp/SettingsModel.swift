import Foundation

/// Settings as a value: one page, five short groups, a footer.
///
/// General (open at login, language, Terminal automation) · Shortcut · Notifications (and the muted
/// agents, each with ✕) · Hooks — the diagnostics: one line per agent on this
/// Mac (installed or not, its last event, a fix), the agents that are not
/// here collapsed into one line, and "Copy report" · Updates. The version and
/// the kind of build are the footer, with "Uninstall Pulse…". `SettingsFace` renders this and sends
/// `Action`s; the store builds it from `settings` and a few flags — never
/// from a scan. Pure.
struct SettingsModel: Equatable {
    enum Section: String, CaseIterable, Equatable {
        case general, shortcut, notifications, hooks, updates
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
        case setLanguage(AppLanguage)
        case setTerminalAutomation(Bool)
        case setHotkey(HotkeyChoice)
        case enableNotifications
        case openNotificationSettings
        case setNotifyOnWaiting(Bool)
        case unmute(AgentID)
        /// Every agent on this Mac, or one.
        case installHooks
        case uninstallHooks
        case installHook(AgentID)
        case uninstallHook(AgentID)
        case copyReport
        case setUpdateCheck(Bool)
        case checkForUpdates
        case openRelease
        /// "Uninstall Pulse…": confirm, then remove everything Pulse put on
        /// this Mac (`UninstallPlan`) and quit.
        case uninstallPulse
    }

    var lang: ResolvedLanguage
    // General
    /// The toggle: what macOS says (`LoginItemState`), else what was asked.
    var launchAtLogin: Bool
    var loginNote: LoginNote? = nil
    var language: AppLanguage
    /// Go may select the exact Terminal / iTerm tab with AppleScript.
    var terminalAutomation: Bool = false
    // Shortcut
    var hotkey: HotkeyChoice
    /// The system refused the chosen shortcut (another app owns it).
    var hotkeyTaken: Bool
    // Notifications
    var notifications: Notifications
    /// The switch as it takes effect: off while macOS does not allow banners.
    var notifyOnWaiting: Bool
    var mutedAgents: [AgentID]
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
    // Updates
    var updateCheckEnabled: Bool
    var updateStatus: String
    var updateAvailable: Bool
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
        /// The agent is here and its hook is not (or did not go in): the
        /// line offers the install.
        var needsFix = false

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
                failed: failure != nil,
                needsFix: failure != nil || !isInstalled
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
    /// and when it last reported, whether macOS allows banners, whether
    /// Pulse may script a terminal, the global shortcut, the login item as
    /// macOS sees it, and how Pulse reads each listed
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
        var notifyOnWaiting: Bool
        var terminalAutomation: Bool
        var hotkey: HotkeyChoice = .off
        /// The system took the shortcut (false: another app owns it).
        var hotkeyRegistered = true
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
        let shortcut = input.hotkey == .off
            ? "off"
            : "\(input.hotkey.rawValue), registered: \(input.hotkeyRegistered ? "yes" : "no — taken")"
        var lines: [String] = [
            "Pulse report",
            input.version,
            "macOS \(input.macOS)",
            "notifications: \(authorization), needs-you banners \(input.notifyOnWaiting ? "on" : "off")",
            "terminal automation: \(input.terminalAutomation ? "allowed" : "off")",
            "shortcut: \(shortcut)",
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

    /// The hook work an action asks for — every agent on this Mac, or the
    /// one a line names; nil for any other action. Pure.
    static func hooksJob(_ action: Action) -> HooksSupport.Job? {
        switch action {
        case .installHooks: return .install(nil)
        case .uninstallHooks: return .uninstall(nil)
        case .installHook(let agent): return .install([agent])
        case .uninstallHook(let agent): return .uninstall([agent])
        default: return nil
        }
    }

    /// The page, top to bottom.
    static let sections: [Section] = [.general, .shortcut, .notifications, .hooks, .updates]

    /// A deep link's target, as the section it scrolls to.
    static func section(for target: SettingsFocus.Target) -> Section {
        switch target {
        case .waitingSignals: return .hooks
        case .notifications: return .notifications
        case .updates: return .updates
        }
    }

    static func title(_ section: Section, lang: ResolvedLanguage) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        switch section {
        case .general: return t(.general)
        case .shortcut: return t(.shortcuts)
        case .notifications: return t(.notificationsSection)
        case .hooks: return t(.settingsHooksSection)
        case .updates: return t(.settingsUpdatesSection)
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

    /// Muted agents in the order a person reads them.
    static func sortedMuted(_ agents: Set<AgentID>) -> [AgentID] {
        agents.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
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
/// "Uninstall Pulse…" as a value: everything Pulse put on this Mac, said in
/// the confirmation before any of it is removed. Pure — `StatusStore` does
/// it, in this order: every agent's hook comes out through the installer
/// (byte for byte, from the record of what each install replaced); only
/// when none is left does the login item go and the folder — that record
/// with it — get deleted; then Pulse quits and shows itself in Finder.
struct UninstallPlan: Equatable, Sendable {
    /// The agents whose config carries Pulse's hook now, in roster order.
    /// The removal runs for every agent all the same.
    var hooks: [AgentID]
    /// Pulse is a login item (on, or waiting for approval).
    var loginItem: Bool
    /// Pulse's folder, as a person reads it (`~/Library/…`).
    var folder: String

    static func make(installed: Set<AgentID>, loginItem: LoginItemState?, folder: URL, home: URL) -> UninstallPlan {
        let path = folder.path
        let homePath = home.path.hasSuffix("/") ? String(home.path.dropLast()) : home.path
        let shown = path.hasPrefix(homePath + "/") ? "~" + String(path.dropFirst(homePath.count)) : path
        return UninstallPlan(
            hooks: AgentID.priority.filter(installed.contains),
            loginItem: loginItem?.isOn ?? false,
            folder: shown
        )
    }

    /// The confirmation's body: what goes, one line each, then what happens.
    func message(_ lang: ResolvedLanguage) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        var lines: [String] = []
        lines.append(hooks.isEmpty
            ? t(.uninstallNoHooks)
            : String(format: t(.uninstallPlanHooks), L10n.joinNames(hooks.map(\.displayName), lang)))
        if loginItem { lines.append(t(.uninstallLogin)) }
        lines.append(String(format: t(.uninstallFolder), folder))
        lines.append(t(.uninstallThen))
        return lines.joined(separator: "\n\n")
    }

    /// Whether the hook removal left nothing of Pulse's in any agent's
    /// config. Only then is the folder — and with it the record a later
    /// byte-for-byte removal would need — deleted.
    static func hooksRemoved(_ status: HooksSupport.Status) -> Bool {
        switch status {
        case .missing: return true
        case .installed(let agents, let failed): return agents.isEmpty && failed.isEmpty
        case .unknown, .working, .failed: return false
        }
    }
}

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
