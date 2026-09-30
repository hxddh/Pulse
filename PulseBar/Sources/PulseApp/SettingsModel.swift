import Foundation

/// Settings as a value: one page, five short groups, a footer.
///
/// General (login, language) · Shortcut · Notifications (and the muted
/// agents, each with ✕) · Hooks — the diagnostics: one line per agent on this
/// Mac (installed or not, its last event, a fix), the agents that are not
/// here collapsed into one line, and "Copy report" · Updates. The version and
/// the kind of build are the footer. `SettingsFace` renders this and sends
/// `Action`s; the store builds it from `settings` and a few flags — never
/// from a scan. Pure.
struct SettingsModel: Equatable {
    enum Section: String, CaseIterable, Equatable {
        case general, shortcut, notifications, hooks, updates
    }

    /// Whether macOS lets Pulse post a banner.
    enum Notifications: Equatable { case notAsked, denied, allowed }

    enum Action: Equatable {
        case setLaunchAtLogin(Bool)
        case setLanguage(AppLanguage)
        case setHotkey(HotkeyChoice)
        case enableNotifications
        case openNotificationSettings
        case setNotifyOnWaiting(Bool)
        case unmute(AgentID)
        case installHooks
        case uninstallHooks
        case copyReport
        case setUpdateCheck(Bool)
        case checkForUpdates
        case openRelease
    }

    var lang: ResolvedLanguage
    // General
    var launchAtLogin: Bool
    var language: AppLanguage
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
    /// Pulse may script a terminal (and whether the row's offer was
    /// answered), and the global shortcut.
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
        var automationOfferAnswered = false
        var hotkey: HotkeyChoice = .off
        /// The system took the shortcut (false: another app owns it).
        var hotkeyRegistered = true
        var launchAtLogin: Bool
        /// Whether launchd took the toggle; nil when it was not applied this
        /// run.
        var loginItemApplied: Bool? = nil
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
            "terminal automation: \(input.terminalAutomation ? "allowed" : "off"), offer \(input.automationOfferAnswered ? "answered" : "not answered")",
            "shortcut: \(shortcut)",
            "launch at login: \(input.launchAtLogin ? "on" : "off"), applied: \(input.loginItemApplied.map { $0 ? "yes" : "no" } ?? "untouched")",
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
        return lines.joined(separator: "\n")
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
