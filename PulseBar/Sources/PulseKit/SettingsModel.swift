import Foundation

/// Settings as a value: one page, three short groups, a footer.
///
/// General (open at login) · Notifications (whether macOS allows banners) ·
/// Hooks — the diagnostics: Install all / Remove all, one line per agent on
/// this Mac (its `Connection`: installed, needing an update or failed;
/// whether it can report a wait; the vendor event heard last and when; why a whole install may not run; the last event not
/// used and why), the agents that are not here collapsed into one line,
/// and "Copy report". The
/// version, the kind of build and "Releases…" are the footer. The language
/// is the system's. `SettingsFace` renders this and sends `Action`s; the
/// store builds it from `settings` and a few flags — never from a scan.
/// Pure.
package struct SettingsModel: Equatable {
    package enum Section: String, CaseIterable, Equatable {
        case general, notifications, hooks
    }

    /// Whether macOS lets Pulse post a banner.
    package enum Notifications: Equatable { case notAsked, denied, allowed }

    /// What the login line says under its toggle, when it has something
    /// to say.
    package enum LoginNote: Equatable {
        /// Registered, and macOS waits for the person in Login Items.
        case needsApproval
        /// Asked for, and macOS did not take it.
        case failed
    }

    package enum Action: Equatable {
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
        /// The global shortcut, on or off.
        case setGlobalShortcut(Bool)
        /// The direct-jump global shortcut (⌃⌥⌘↩), on or off.
        case setDirectJumpShortcut(Bool)
        /// One agent's banners, muted or not.
        case setMuted(AgentID, Bool)
        /// One agent's automatic turn-done banner, on or off.
        case setNotifyDone(AgentID, Bool)
        /// Automatic turn-done banner threshold for long turns (seconds; 0 off).
        case setLongTurnSeconds(Int)
        /// Notification banner sound preference.
        case setNotificationSound(NotificationSound)
        /// Install or update one agent's hook.
        case installAgent(AgentID)
        /// Remove one agent's hook.
        case uninstallAgent(AgentID)
        /// Run the installed launcher once (`HookPing`).
        case testConnection
        /// The global shortcut's chord.
        case setShortcut(ShortcutChoice)
        /// Group the tray by project, or not.
        case setGroupByProject(Bool)
        /// Menu bar display density beside the lamp.
        case setMenuBarStyle(MenuBarStyle)
        /// Show or hide the floating waiting beacon HUD.
        case setFloatingBeacon(Bool)
        /// Resume notifications immediately when quiet mode is active.
        case resumeQuiet
        /// System Settings → Privacy & Security → Automation.
        case openAutomationSettings
    }

    /// One terminal's Apple Events permission, as the page says it.
    package struct AutomationLine: Equatable, Identifiable {
        package var name: String
        package var text: String
        package var warning: Bool
        package var id: String { name }
    }

    /// Where "Releases…" goes. Pulse itself never asks the network.
    package static let releasesURL = "https://github.com/hxddh/Pulse/releases"

    package var lang: ResolvedLanguage
    // General
    /// The toggle: what macOS says (`LoginItemState`), else what was asked.
    package var launchAtLogin: Bool
    package var loginNote: LoginNote? = nil
    // Notifications
    package var notifications: Notifications
    // Hooks
    package var hooksStatus: String
    package var hooksInstalled: Bool
    /// An install or removal is running: every hook button waits for it.
    package var hooksBusy: Bool = false
    /// One line per agent on this Mac (or carrying Pulse's hook), in roster
    /// order.
    package var hookAgents: [HookAgent] = []
    /// The agents that are not on this Mac, said once: "Not on this Mac: …".
    package var absentAgents: [AgentID] = []
    // Footer
    package var version: String
    /// Said in orange: a preview or unnotarized build, or a stale bundle.
    package var buildWarning: String?
    /// Where a deep link asked the page to scroll.
    package var focus: Section?
    // Added in 34: the shortcut, muting, the connection test.
    /// The global shortcut's toggle.
    package var globalShortcut = true
    /// Said under it when macOS refused the chord.
    package var shortcutNote: String?
    /// Agents whose banners can be muted: those on this Mac that report
    /// waits, in roster order.
    package var muteCandidates: [AgentID] = []
    package var mutedAgents: Set<AgentID> = []
    /// The last connection test, in words; nil not run.
    package var pingLine: String?
    package var pingWarning = false
    /// The global shortcut's chord.
    package var shortcutChoice: ShortcutChoice = .default
    /// Direct jump to oldest wait (⌃⌥⌘↩).
    package var directJumpShortcut = false
    /// Said under it when macOS refused ⌃⌥⌘↩.
    package var directJumpNote: String?
    package var groupByProject = false
    package var menuBarStyle: MenuBarStyle = .minimal
    package var floatingBeacon = true
    /// Agents whose finished turns can be opted into "Done" banners (present on this Mac).
    package var notifyDoneCandidates: [AgentID] = []
    package var notifyDoneAgents: Set<AgentID> = []
    package var notifyLongTurnSeconds = 0
    package var notificationSound: NotificationSound = .default
    /// Remaining quiet-mode snooze duration label when active; nil when not snoozed.
    package var quietRemaining: String? = nil
    /// Each running terminal's Apple Events permission; empty when none
    /// runs or it was not asked yet.
    package var automation: [AutomationLine] = []

    package init(
        lang: ResolvedLanguage,
        launchAtLogin: Bool,
        loginNote: LoginNote? = nil,
        notifications: Notifications,
        hooksStatus: String,
        hooksInstalled: Bool,
        hooksBusy: Bool = false,
        hookAgents: [HookAgent] = [],
        absentAgents: [AgentID] = [],
        version: String,
        buildWarning: String? = nil,
        focus: Section? = nil
    ) {
        self.lang = lang
        self.launchAtLogin = launchAtLogin
        self.loginNote = loginNote
        self.notifications = notifications
        self.hooksStatus = hooksStatus
        self.hooksInstalled = hooksInstalled
        self.hooksBusy = hooksBusy
        self.hookAgents = hookAgents
        self.absentAgents = absentAgents
        self.version = version
        self.buildWarning = buildWarning
        self.focus = focus
    }

    /// What macOS allows for each terminal Pulse searches with
    /// AppleScript — only the running ones, in a fixed order; a denial is
    /// a warning.
    package static func automationLines(_ states: [String: AutomationState], lang: ResolvedLanguage) -> [AutomationLine] {
        let names = [(LandingPlan.terminalBundleID, "Terminal"), (LandingPlan.iTermBundleID, "iTerm2")]
        return names.compactMap { bundle, name in
            guard let state = states[bundle], state != .notRunning else { return nil }
            let key: L10n.Key
            switch state {
            case .allowed: key = .automationAllowed
            case .denied: key = .automationDenied
            case .notAsked: key = .automationNotAsked
            case .notRunning: key = .automationNotRunning
            case .unknown: key = .automationUnknown
            }
            return AutomationLine(
                name: String(format: L10n.t(.automationTitle, lang), name),
                text: L10n.t(key, lang),
                warning: state == .denied
            )
        }
    }

    /// The shortcut's line: the toggle, and why it is not working when
    /// macOS refused the chord.
    package static func shortcutNote(
        on: Bool, registered: Bool?, choice: ShortcutChoice = .default, lang: ResolvedLanguage
    ) -> String? {
        guard on, registered == false else { return nil }
        return String(format: L10n.t(.settingsShortcutTaken, lang), choice.display)
    }

    /// Why the direct-jump shortcut (⌃⌥⌘↩) is not working when macOS refused it.
    package static func directJumpNote(on: Bool, registered: Bool?, lang: ResolvedLanguage) -> String? {
        guard on, registered == false else { return nil }
        return String(format: L10n.t(.settingsShortcutTaken, lang), "⌃⌥⌘↩")
    }

    /// The agents whose banners can be muted: on this Mac and able to
    /// report a wait.
    package static func muteCandidates(present: Set<AgentID>) -> [AgentID] {
        AgentID.priority.filter { present.contains($0) && $0.waitingSource != .none }
    }

    /// The agents on this Mac that can opt into automatic "Done" banners.
    package static func notifyDoneCandidates(present: Set<AgentID>) -> [AgentID] {
        AgentID.priority.filter { present.contains($0) }
    }

    /// Label for one long-turn threshold option.
    package static func longTurnLabel(_ seconds: Int, lang: ResolvedLanguage) -> String {
        guard seconds > 0 else { return L10n.t(.settingsLongTurnOff, lang) }
        return String(format: L10n.t(.settingsLongTurnMinutes, lang), max(1, seconds / 60))
    }

    /// Label for one menu bar display style.
    package static func menuBarStyleLabel(_ style: MenuBarStyle, lang: ResolvedLanguage) -> String {
        switch style {
        case .minimal: return L10n.t(.settingsMenuBarMinimal, lang)
        case .compact: return L10n.t(.settingsMenuBarCompact, lang)
        case .counts: return L10n.t(.settingsMenuBarCounts, lang)
        }
    }

    /// What the connection test found, in words, and whether it is a
    /// warning.
    package static func pingLine(_ result: HookPing.Result?, nowMs: Int64, lang: ResolvedLanguage) -> (text: String, warning: Bool)? {
        switch result {
        case nil: return nil
        case .running?: return (L10n.t(.settingsTestRunning, lang), false)
        case .ok(let ms)?: return (String(format: L10n.t(.settingsTestOK, lang), L10n.ago(min(ms, nowMs), nowMs: nowMs, lang)), false)
        case .noLauncher?: return (L10n.t(.settingsTestNoLauncher, lang), true)
        case .noAnswer?: return (L10n.t(.settingsTestNoAnswer, lang), true)
        }
    }

    /// One agent's connection, as the Hooks section says it, in one order:
    /// its name and state on one line; under it, quietly, that it does not
    /// report waits (`noWaits`), what was heard and when with any caveat
    /// the state line does not already say (`detail`), and the last event
    /// not used (`notUsed`).
    package struct HookAgent: Equatable, Identifiable {
        package enum Tone: Equatable {
            /// Installed and whole.
            case ok
            /// Needs an update, or the last install failed.
            case warning
            /// Not installed.
            case quiet
        }

        package var connection: Connection
        /// "Installed" / "Needs update — 9 of 11 events" / "Failed · why" /
        /// "Not installed".
        package var state: String
        package var tone: Tone
        /// "This agent doesn't report waits" — only for an agent whose
        /// hook cannot (`WaitingSource.none`), whatever the install; nil
        /// otherwise.
        package var noWaits: String?
        /// "Heard PermissionRequest · 4m ago" (only when a hook is there to
        /// hear), a caveat the state line does not say, a config folder
        /// that is missing; "" when none.
        package var detail: String
        /// "Last not used PreCompact — not an installed event · 2m ago".
        package var notUsed: String?

        package var agent: AgentID { connection.agent }
        package var id: AgentID { agent }
        package var installed: Bool { connection.install.carriesHook }

        package init(_ connection: Connection, nowMs: Int64, lang: ResolvedLanguage) {
            self.connection = connection
            state = connection.stateText(lang: lang)
            switch connection.install {
            // Nothing heard yet is said, not warned about: the agent may
            // simply not have run since the install.
            case .complete: tone = connection.caveat == nil || connection.caveat == .neverHeard ? .ok : .warning
            case .partial, .staleLauncher, .outdatedModule, .failed: tone = .warning
            case .notInstalled: tone = .quiet
            }
            // The state line already says nothing was heard.
            let heard = connection.caveat == .neverHeard && connection.lastHeard == nil
                ? "" : connection.heardText(nowMs: nowMs, lang: lang)
            // A caveat the state line does not already say (an install that
            // is not whole and is silenced too).
            var caveat = ""
            if let reason = connection.caveat, connection.install != .complete {
                caveat = connection.caveatText(reason, lang: lang)
            }
            noWaits = connection.agent.waitingSource == .none ? L10n.t(.detailNoWaits, lang) : nil
            detail = [heard, caveat, connection.configDirText(lang: lang) ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            notUsed = connection.ignoredText(nowMs: nowMs, lang: lang)
        }
    }

    /// Pure: the Hooks section's lines, in roster order — every agent that
    /// is on this Mac, carries Pulse's hook, or failed its last install. The
    /// rest are `absentAgents`.
    package static func hookAgents(
        connections: [Connection],
        present: Set<AgentID>,
        nowMs: Int64,
        lang: ResolvedLanguage
    ) -> [HookAgent] {
        AgentID.priority.compactMap { agent in
            guard let connection = connections.first(where: { $0.agent == agent }),
                  hasLine(connection, present: present)
            else { return nil }
            return HookAgent(connection, nowMs: nowMs, lang: lang)
        }
    }

    /// Pure: the agents with no line of their own — not on this Mac, no
    /// hook, no failure — in roster order.
    package static func absentAgents(connections: [Connection], present: Set<AgentID>) -> [AgentID] {
        AgentID.priority.filter { agent in
            guard let connection = connections.first(where: { $0.agent == agent }) else { return !present.contains(agent) }
            return !hasLine(connection, present: present)
        }
    }

    private static func hasLine(_ connection: Connection, present: Set<AgentID>) -> Bool {
        if present.contains(connection.agent) || connection.install.carriesHook || connection.configDirMissing { return true }
        if case .failed = connection.install { return true }
        return false
    }

    /// "Install all" would update an agent: say so once, under the buttons.
    package var hooksNeedUpdate: Bool {
        hookAgents.contains { $0.connection.install.needsUpdate }
    }

    /// "Not on this Mac: Pi, OpenCode" — nil when every agent is here.
    package static func absentLine(_ agents: [AgentID], lang: ResolvedLanguage) -> String? {
        guard !agents.isEmpty else { return nil }
        return String(format: L10n.t(.settingsHookAbsent, lang), L10n.joinNames(agents.map(\.displayName), lang))
    }

    // MARK: - The report

    /// What "Copy report" puts on the clipboard: plain text, English, no
    /// path, prompt, session id or project — the version, each agent's
    /// connection (its install, the event heard last, the last one not
    /// used and why, whether it reports waits), whether macOS allows
    /// banners, the login item as macOS sees it, and how Pulse reads each
    /// listed session with its last few heard lines (the detail page does
    /// not say it).
    package struct ReportInput: Equatable {
        package var version: String
        package var macOS: String
        /// Every agent's connection, in any order.
        package var connections: [Connection]
        package var present: Set<AgentID>
        package var nowMs: Int64
        /// nil: macOS has not been asked yet.
        package var notifyAuthorized: Bool?
        package var launchAtLogin: Bool
        /// What macOS says of Pulse's login item; nil when not read.
        package var loginItem: LoginItemState? = nil
        /// Every listed session, as the few facts that say how Pulse reads it.
        package var sessions: [ReportSession] = []

        package init(
            version: String,
            macOS: String,
            connections: [Connection],
            present: Set<AgentID>,
            nowMs: Int64,
            notifyAuthorized: Bool? = nil,
            launchAtLogin: Bool,
            loginItem: LoginItemState? = nil,
            sessions: [ReportSession] = []
        ) {
            self.version = version
            self.macOS = macOS
            self.connections = connections
            self.present = present
            self.nowMs = nowMs
            self.notifyAuthorized = notifyAuthorized
            self.launchAtLogin = launchAtLogin
            self.loginItem = loginItem
            self.sessions = sessions
        }
    }

    /// How Pulse reads one session, without naming it: its state, where
    /// its facts come from, how a click lands, whether its process is
    /// watched, when it last spoke, and its last few heard lines.
    package struct ReportSession: Equatable {
        package var agent: AgentID
        package var state: String
        package var go: LandingPlan.Precision?
        package var liveProcess: Bool
        package var lastEventMs: Int64
        /// Steps this turn took, and how many failed.
        package var turnSteps: Int
        package var turnFailedSteps: Int
        /// The last `reportTimeline` heard lines, newest first — runs of
        /// steps already grouped (`SessionBook.StepRun`).
        package var timeline: [SessionBook.Heard]

        /// Heard lines a session's report carries.
        package static let reportTimeline = 3

        /// `facts`: the session's (`SessionFacts`) — its newest event and
        /// its timeline; none for a process-only row.
        package init(_ row: AgentRow, facts: SessionFacts = SessionFacts()) {
            agent = row.agent
            switch row.status {
            case .needsYou: state = "blocked"
            case .running(let stalled): state = stalled ? "stalled" : "running"
            case .yourTurn: state = "your turn"
            case .recent: state = "recent"
            case .processOnly: state = "process only"
            }
            go = row.landingPlan.precision
            liveProcess = row.liveProcess
            lastEventMs = facts.lastEventMs
            turnSteps = facts.turnSteps
            turnFailedSteps = facts.turnFailedSteps
            timeline = Array(facts.timeline.suffix(Self.reportTimeline).reversed())
        }

        package func line(nowMs: Int64) -> String {
            let goWord: String
            switch go {
            case .exact: goWord = "exact"
            case .app: goWord = "app only"
            case nil: goWord = "none"
            }
            let source = state == "process only" ? "process only" : "hooks"
            var text = "  \(agent.rawValue): \(state), from \(source), go \(goWord)"
            text += liveProcess ? ", process watched" : ", no process"
            text += lastEventMs > 0 ? ", last event \(max(0, (nowMs - lastEventMs) / 1000))s ago" : ", no event"
            if turnSteps > 0 {
                text += ", steps \(turnSteps)" + (turnFailedSteps > 0 ? " (\(turnFailedSteps) failed)" : "")
            }
            for heard in timeline {
                let by = heard.sub.isEmpty ? "" : "subagent "
                text += "\n    \(max(0, (nowMs - heard.ms) / 1000))s ago · \(Connection.reportEvent(heard.event)) · \(by)\(heard.effect.reportWord)"
            }
            return text
        }
    }

    package static func report(_ input: ReportInput) -> String {
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
            let connection = input.connections.first { $0.agent == agent } ?? Connection(agent: agent, install: .notInstalled)
            lines.append(connection.reportLine(present: input.present.contains(agent), nowMs: input.nowMs))
        }
        lines.append(input.sessions.isEmpty ? "sessions: none listed" : "sessions:")
        lines += input.sessions.map { $0.line(nowMs: input.nowMs) }
        return lines.joined(separator: "\n")
    }

    /// The hook work an action asks for; nil for any other action. Pure.
    package static func hooksJob(_ action: Action) -> HooksSupport.Job? {
        switch action {
        case .installHooks: return .install
        case .uninstallHooks: return .uninstall
        default: return nil
        }
    }

    /// The page, top to bottom.
    package static let sections: [Section] = [.general, .notifications, .hooks]

    /// A deep link's target, as the section it scrolls to.
    package static func section(for target: SettingsFocus.Target) -> Section {
        switch target {
        case .waitingSignals: return .hooks
        case .notifications: return .notifications
        }
    }

    package static func title(_ section: Section, lang: ResolvedLanguage) -> String {
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
    package static func loginLine(asked: Bool, state: LoginItemState?) -> (isOn: Bool, note: LoginNote?) {
        guard let state else { return (asked, nil) }
        switch state {
        case .enabled: return (true, nil)
        case .requiresApproval: return (true, .needsApproval)
        case .off, .unavailable: return (false, asked ? .failed : nil)
        }
    }

    package static func notifications(_ authorized: Bool?) -> Notifications {
        switch authorized {
        case .some(true): return .allowed
        case .some(false): return .denied
        case .none: return .notAsked
        }
    }
}

/// Pulse's login item as macOS reports it (`SMAppService.mainApp.status`,
/// read by `LoginItem`). Pure.
package enum LoginItemState: String, Equatable, Sendable {
    /// Not registered.
    case off
    case enabled
    /// Registered; macOS waits for the person in System Settings → Login
    /// Items.
    case requiresApproval
    /// macOS cannot find the app to register (a build outside a bundle).
    case unavailable

    /// Pulse opens at login, or will once approved.
    package var isOn: Bool { self == .enabled || self == .requiresApproval }

    package var reportWord: String {
        switch self {
        case .off: return "not registered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval"
        case .unavailable: return "unavailable"
        }
    }
}

/// Where Settings scrolls when a deep link opens it. The token moves on
/// every deep link, so a second link to the same place still scrolls there.
package struct SettingsFocus: Equatable {
    package enum Target: Equatable {
        /// The hooks: how an agent gets a "needs you" signal.
        case waitingSignals
        case notifications
    }

    package var target: Target?
    package var token = 0

    package init(target: Target? = nil, token: Int = 0) {
        self.target = target
        self.token = token
    }
}
