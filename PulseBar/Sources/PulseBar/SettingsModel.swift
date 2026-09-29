import Foundation

/// 23.0 · Settings as a value: one page, six short groups, a footer.
///
/// General (login, language) · Shortcut · Notifications (and the muted
/// agents, each with ✕) · Hooks (one line per agent, 24.0) · Terminal control ·
/// Updates (24.0: Data access went — Pulse reads no other app's data). About, build and "running from" collapsed into a
/// footer line. `SettingsFace` renders this and sends `Action`s; the store
/// builds it from `settings` and a few flags — never from a scan. Pure.
struct SettingsModel: Equatable {
    enum Section: String, CaseIterable, Equatable {
        case general, shortcut, notifications, hooks, terminal, updates
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
        case testHooks
        case setTerminalAutomation(Bool)
        case setUpdateCheck(Bool)
        case checkForUpdates
        case openRelease
        case openDiagnostics
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
    /// 24.0: one line per supported agent.
    var hookAgents: [HookAgent] = []
    var hookTest: String
    var hookTestTone: PulseTheme.Tone
    var hookTestRunning: Bool
    // Terminal control
    var allowTerminalAutomation: Bool
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
        /// Installed / not installed / not on this Mac.
        var state: String
        var installed: Bool
        /// "last event 12s ago" / "no event yet"; empty when not installed.
        var lastEvent: String
        /// Said for an agent whose hook never reports a wait.
        var note: String?

        var id: AgentID { agent }
    }

    /// Pure: the Hooks section's lines, in roster order.
    static func hookAgents(
        installed: Set<AgentID>,
        present: Set<AgentID>,
        lastEventMs: [AgentID: Int64],
        nowMs: Int64,
        lang: ResolvedLanguage
    ) -> [HookAgent] {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        return AgentID.priority.map { agent in
            let isInstalled = installed.contains(agent)
            let state: String
            if isInstalled {
                state = t(.settingsHookInstalled)
            } else if present.contains(agent) {
                state = t(.hooksMissing)
            } else {
                state = t(.settingsHookNotFound)
            }
            var lastEvent = ""
            if isInstalled {
                if let ms = lastEventMs[agent], ms > 0 {
                    let seconds = Double(max(0, nowMs - ms)) / 1000
                    lastEvent = seconds < 5
                        ? t(.settingsHookLastEventNow)
                        : String(format: t(.settingsHookLastEvent), DurationFormat.label(seconds: seconds, lang: lang))
                } else {
                    lastEvent = t(.settingsHookNoEvent)
                }
            }
            return HookAgent(
                agent: agent,
                state: state,
                installed: isInstalled,
                lastEvent: lastEvent,
                note: agent.waitingSource == .none ? t(.settingsHookNoWait) : nil
            )
        }
    }

    /// The page, top to bottom.
    static let sections: [Section] = [.general, .shortcut, .notifications, .hooks, .terminal, .updates]

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
        case .terminal: return t(.settingsTerminalSection)
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
