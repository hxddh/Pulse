import Foundation

/// One agent's hook connection, as Settings → Hooks says it on the agent's
/// line and "Copy report" says it in English: whether Pulse's hook is
/// installed and whole, which vendor event was heard last and when, the
/// last event it heard and did not turn into state (and why), and whether
/// the agent can report a wait at all.
///
/// Pure: built from what the installer read (`HooksSupport.inspect`), the
/// last install's failure and the event log's newest lines (kept by
/// `ScanEngine` as it applies them). A partial or stale install is fixed by
/// "Install all" — there is no per-agent button.
package struct Connection: Equatable, Sendable {
    /// How the agent's config carries Pulse's hook.
    package enum Install: Equatable, Sendable {
        /// No event carries Pulse's hook.
        case notInstalled
        /// Exactly the contract's events carry it, through this Pulse's
        /// launcher.
        case complete
        /// Some of the contract's events carry it — or an event the contract
        /// no longer has does: `found` of the contract's `of`.
        case partial(found: Int, of: Int)
        /// The hook runs a launcher that is not this Pulse's (another path)
        /// or cannot run (the launcher, or the app it starts, is gone).
        case staleLauncher
        /// The last install or removal could not be done.
        case failed(HooksInstaller.Failure)

        /// Pulse's hook is in the agent's config, whole or not.
        package var carriesHook: Bool {
            switch self {
            case .complete, .partial, .staleLauncher: return true
            case .notInstalled, .failed: return false
            }
        }

        /// "Install all" would change it: it is there, but not whole or not
        /// this Pulse's.
        package var needsUpdate: Bool {
            switch self {
            case .partial, .staleLauncher: return true
            case .complete, .notInstalled, .failed: return false
            }
        }

        /// What one config says. `installed`: the events that carry Pulse's
        /// command (nil: the file is not its format); `launchers`: the
        /// launcher paths its commands name; `expected`: this Pulse's
        /// launcher; `launcherRuns` / `runnerRuns`: the launcher is
        /// executable, and the app `hook-runner.path` names (when it names
        /// one) is. Pure.
        package static func classify(
            contract: Set<String>,
            installed: Set<String>?,
            launchers: Set<String>,
            expected: String,
            launcherRuns: Bool,
            runnerRuns: Bool
        ) -> Install {
            guard let installed, !installed.isEmpty else { return .notInstalled }
            if !launcherRuns || !runnerRuns || launchers.contains(where: { $0 != expected }) {
                return .staleLauncher
            }
            if installed != contract {
                return .partial(found: installed.intersection(contract).count, of: contract.count)
            }
            return .complete
        }
    }

    /// The newest line an agent's hook wrote: its vendor event and when.
    package struct Heard: Equatable, Sendable {
        package var event: String
        package var ms: Int64

        package init(event: String, ms: Int64) {
            self.event = event
            self.ms = ms
        }
    }

    /// The newest `ignored` line: its vendor event, the receiver's reason
    /// (`PulseHookReceiver.Ignored` raw value) and when.
    package struct Ignored: Equatable, Sendable {
        package var event: String
        package var reason: String
        package var ms: Int64

        package init(event: String, reason: String, ms: Int64) {
            self.event = event
            self.reason = reason
            self.ms = ms
        }
    }

    package var agent: AgentID
    package var install: Install
    package var lastHeard: Heard?
    package var lastIgnored: Ignored?

    package init(agent: AgentID, install: Install, lastHeard: Heard? = nil, lastIgnored: Ignored? = nil) {
        self.agent = agent
        self.install = install
        self.lastHeard = lastHeard
        self.lastIgnored = lastIgnored
    }

    /// One agent's connection: what its config says (`probed`; nil when not
    /// read), unless its last install failed — then why.
    package static func make(
        agent: AgentID,
        probed: Install?,
        failure: HooksInstaller.Failure?,
        heard: Heard?,
        ignored: Ignored?
    ) -> Connection {
        let install = failure.map(Install.failed) ?? probed ?? .notInstalled
        return Connection(agent: agent, install: install, lastHeard: heard, lastIgnored: ignored)
    }

    /// Whether the vendor's hook says when a session waits on the person.
    package var reportsWaits: Bool { agent.waitingSource == .hooks }

    // MARK: - The words (Settings)

    /// "Installed", "Needs update — 9 of 11 events", "Needs update — runs
    /// another Pulse", "Failed · why", "Not installed".
    package func stateText(lang: ResolvedLanguage) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        switch install {
        case .complete: return t(.settingsHookInstalled)
        case .partial(let found, let of): return String(format: t(.settingsHookPartial), found, of)
        case .staleLauncher: return t(.settingsHookStale)
        case .failed(let failure): return t(.hooksFailed) + " · " + HooksSupport.Status.reason(failure, lang: lang)
        case .notInstalled: return t(.hooksMissing)
        }
    }

    /// "Heard PermissionRequest · 4m ago", "Nothing heard yet"; "" when no
    /// hook is there to hear.
    package func heardText(nowMs: Int64, lang: ResolvedLanguage) -> String {
        guard install.carriesHook || lastHeard != nil else { return "" }
        guard let heard = lastHeard, heard.ms > 0 else { return L10n.t(.settingsHookNoEvent, lang) }
        let name = EventName.display(heard.event)
        let when = L10n.ago(min(heard.ms, nowMs), nowMs: nowMs, lang)
        return name.isEmpty
            ? String(format: L10n.t(.settingsHookHeardUnnamed, lang), when)
            : String(format: L10n.t(.settingsHookHeard, lang), name, when)
    }

    /// "Last ignored SubagentStop — not an installed event · 2m ago"; nil
    /// when nothing was.
    package func ignoredText(nowMs: Int64, lang: ResolvedLanguage) -> String? {
        guard let ignored = lastIgnored, ignored.ms > 0 else { return nil }
        let name = EventName.display(ignored.event)
        return String(
            format: L10n.t(.settingsHookIgnored, lang),
            name.isEmpty ? "?" : name,
            Self.reasonText(ignored.reason, lang: lang),
            L10n.ago(min(ignored.ms, nowMs), nowMs: nowMs, lang)
        )
    }

    /// "Reports when it waits" / "Doesn't report when it waits — running
    /// and your turn only".
    package func waitsText(lang: ResolvedLanguage) -> String {
        L10n.t(reportsWaits ? .settingsHookReportsWaits : .settingsHookNoWait, lang)
    }

    /// The receiver's reason for an `ignored` line, in the person's
    /// language. A reason the receiver never writes (a hand-edited log) is
    /// "not used" — its words are never repeated.
    package static func reasonText(_ raw: String, lang: ResolvedLanguage) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        switch PulseHookReceiver.Ignored(rawValue: raw) {
        case .noEvent?: return t(.ignoredNoEvent)
        case .notInstalled?: return t(.ignoredNotInstalled)
        case .unparsable?: return t(.ignoredUnparsable)
        case .cannotWait?: return t(.ignoredCannotWait)
        case .noSession?: return t(.ignoredNoSession)
        case .silent?: return t(.ignoredSilent)
        case nil: return t(.ignoredOther)
        }
    }

    // MARK: - The report (English, no path)

    /// The receiver's reason as the report says it: its own words when it
    /// is one the receiver writes, else "other".
    package static func reportReason(_ raw: String) -> String {
        PulseHookReceiver.Ignored(rawValue: raw)?.rawValue ?? "other"
    }

    /// An event name as the report says it: "?" when it is not a name.
    package static func reportEvent(_ raw: String) -> String {
        let name = EventName.display(raw)
        return name.isEmpty ? "?" : name
    }

    /// One agent's line: "  claude: installed, heard Stop 42s ago, last
    /// ignored SubagentStop (not an installed event) 3s ago, reports waits".
    package func reportLine(present: Bool, nowMs: Int64) -> String {
        func age(_ ms: Int64) -> String { "\(max(0, (nowMs - ms) / 1000))s ago" }
        var parts: [String] = []
        switch install {
        case .complete: parts.append("installed")
        case .partial(let found, let of): parts.append("needs update (\(found) of \(of) events)")
        case .staleLauncher: parts.append("needs update (stale launcher)")
        case .failed(let failure): parts.append("install failed (\(failure.rawValue))")
        case .notInstalled: parts.append(present ? "not installed" : "not on this Mac")
        }
        if let heard = lastHeard, heard.ms > 0 {
            parts.append("heard \(Self.reportEvent(heard.event)) \(age(heard.ms))")
        } else if install.carriesHook {
            parts.append("nothing heard yet")
        }
        if let ignored = lastIgnored, ignored.ms > 0 {
            parts.append("last ignored \(Self.reportEvent(ignored.event)) (\(Self.reportReason(ignored.reason))) \(age(ignored.ms))")
        }
        if install.carriesHook || present {
            parts.append(reportsWaits ? "reports waits" : "doesn't report waits")
        }
        return "  \(agent.rawValue): " + parts.joined(separator: ", ")
    }
}
