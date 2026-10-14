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

    /// One agent's hook, as the Hooks section says it.
    package struct HookAgent: Equatable, Identifiable {
        package var agent: AgentID
        /// Installed / not installed, or why the last install failed.
        package var state: String
        package var installed: Bool
        /// "last event 12m ago" / "no event yet"; empty when not installed.
        package var lastEvent: String
        /// Said for an agent whose hook never reports a wait.
        package var note: String?
        /// The last install or removal failed for this agent (the state
        /// says why, in words from `L10n`).
        package var failed = false

        package var id: AgentID { agent }
    }

    /// Pure: the Hooks section's lines, in roster order — every agent that
    /// is on this Mac, carries Pulse's hook, or failed its last install. The
    /// rest are `absentAgents`.
    package static func hookAgents(
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
                    lastEvent = nowMs - ms < 60_000
                        ? t(.settingsHookLastEventNow)
                        : String(format: t(.settingsHookLastEvent), L10n.duration(Double(nowMs - ms) / 1000, lang))
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
    package static func absentAgents(
        installed: Set<AgentID>,
        present: Set<AgentID>,
        failed: [AgentID: HooksInstaller.Failure] = [:]
    ) -> [AgentID] {
        AgentID.priority.filter { agent in
            !installed.contains(agent) && !present.contains(agent) && failed[agent] == nil
        }
    }

    /// "Not on this Mac: Pi, OpenCode" — nil when every agent is here.
    package static func absentLine(_ agents: [AgentID], lang: ResolvedLanguage) -> String? {
        guard !agents.isEmpty else { return nil }
        return String(format: L10n.t(.settingsHookAbsent, lang), L10n.joinNames(agents.map(\.displayName), lang))
    }

    // MARK: - The report

    /// What "Copy report" puts on the clipboard: plain text, English, no
    /// path, prompt, session id or project — the version, each agent's hook
    /// and when it last reported, whether macOS allows banners, the login
    /// item as macOS sees it, and how Pulse reads each listed
    /// session (the detail page does not say it).
    package struct ReportInput: Equatable {
        package var version: String
        package var macOS: String
        package var installed: Set<AgentID>
        package var present: Set<AgentID>
        package var failed: [AgentID: HooksInstaller.Failure] = [:]
        package var lastEventMs: [AgentID: Int64]
        /// The last event each agent's hook sent that Pulse heard and did not
        /// turn into state (an `ignored` line): its event and why.
        package var ignored: [AgentID: Ignored] = [:]
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
            installed: Set<AgentID>,
            present: Set<AgentID>,
            failed: [AgentID: HooksInstaller.Failure] = [:],
            lastEventMs: [AgentID: Int64],
            ignored: [AgentID: Ignored] = [:],
            nowMs: Int64,
            notifyAuthorized: Bool? = nil,
            launchAtLogin: Bool,
            loginItem: LoginItemState? = nil,
            sessions: [ReportSession] = []
        ) {
            self.version = version
            self.macOS = macOS
            self.installed = installed
            self.present = present
            self.failed = failed
            self.lastEventMs = lastEventMs
            self.ignored = ignored
            self.nowMs = nowMs
            self.notifyAuthorized = notifyAuthorized
            self.launchAtLogin = launchAtLogin
            self.loginItem = loginItem
            self.sessions = sessions
        }
    }

    /// One heard event Pulse did not turn into state: the vendor's event name
    /// (only when it is an identifier — never a path) and the receiver's
    /// reason (`PulseHookReceiver.Ignored`).
    package struct Ignored: Equatable, Sendable {
        package var event: String
        package var reason: String

        package init(event: String, reason: String) {
            let identifier = !event.isEmpty && event.count <= 64
                && event.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "_.:-".unicodeScalars.contains($0) }
            self.event = identifier ? event : "?"
            self.reason = reason
        }

        package var phrase: String { "\(event) (\(reason))" }
    }

    /// How Pulse reads one session, without naming it: its state, where
    /// its facts come from, how a click lands, whether its process is
    /// watched, and when it last spoke.
    package struct ReportSession: Equatable {
        package var agent: AgentID
        package var state: String
        package var go: LandingPlan.Precision?
        package var liveProcess: Bool
        package var lastEventMs: Int64

        /// `lastEventMs`: the session's newest event (`SessionFacts`); 0 for
        /// a process-only row.
        package init(_ row: AgentRow, lastEventMs: Int64 = 0) {
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
            self.lastEventMs = lastEventMs
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
            if let ignored = input.ignored[agent] { line += ", last ignored: \(ignored.phrase)" }
            lines.append(line)
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
