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

    /// Why an installed hook may not be running, though the config carries
    /// it whole: a vendor setting silences it, or the vendor has not run it
    /// since the file changed and needs the person to trust it.
    package enum Caveat: String, Equatable, Sendable {
        /// The person's own settings turn every hook off (Claude's
        /// `disableAllHooks` in `~/.claude/settings.json`).
        case turnedOff
        /// A managed policy runs only managed hooks, or none
        /// (`allowManagedHooksOnly`, a managed `disableAllHooks`).
        case managedOnly
        /// A trust-bound vendor (Codex: `NestedFlavor.trustBound`) has run
        /// since the file last changed and nothing was heard: the changed
        /// entries wait to be trusted (`/hooks`).
        case untrusted
        /// The install is whole and nothing was ever heard from the agent
        /// through it: no line in the log — or, for a file Pulse owns
        /// whole (whose last change is Pulse's install), none since it was
        /// written. Not a fault (the agent may not have run yet), but the
        /// first thing to check when it has: a sandbox that keeps the hook
        /// from Pulse's folder, a config folder moved by the environment.
        case neverHeard
    }

    package var agent: AgentID
    package var install: Install
    package var lastHeard: Heard?
    package var lastIgnored: Ignored?
    /// Installed, but maybe not running (`Caveat`); nil otherwise.
    package var caveat: Caveat?
    /// The agent is on this Mac, but the folder its contract can be moved
    /// from (`HookContract.relocation`, Pi's `~/.pi/agent`) is not there:
    /// it may read another folder (`PI_CODING_AGENT_DIR`), which Pulse —
    /// a GUI app, blind to the shell's environment — never follows. Settings
    /// says where Pulse installs.
    package var configDirMissing: Bool

    package init(
        agent: AgentID,
        install: Install,
        lastHeard: Heard? = nil,
        lastIgnored: Ignored? = nil,
        configDirMissing: Bool = false,
        caveat: Caveat? = nil
    ) {
        self.agent = agent
        self.install = install
        self.lastHeard = lastHeard
        self.lastIgnored = lastIgnored
        self.configDirMissing = configDirMissing
        self.caveat = caveat
    }

    /// One agent's connection: what its config says (`probed`; nil when not
    /// read), unless its last install failed — then why.
    package static func make(
        agent: AgentID,
        probed: Install?,
        failure: HooksInstaller.Failure?,
        heard: Heard?,
        ignored: Ignored?,
        configDirMissing: Bool = false,
        config: Config = Config(),
        runningSince: [Int64] = []
    ) -> Connection {
        let install = failure.map(Install.failed) ?? probed ?? .notInstalled
        return Connection(
            agent: agent, install: install, lastHeard: heard, lastIgnored: ignored,
            configDirMissing: configDirMissing && agent.spec.hooks.relocation != nil,
            caveat: caveat(agent: agent, install: install, config: config, heardMs: heard?.ms, runningSince: runningSince)
        )
    }

    /// What was read from the agent's config besides its entries: the
    /// vendor setting that silences hooks (`HookContract.offSwitches`) and
    /// when the file Pulse edits last changed (ms; 0 unknown).
    package struct Config: Equatable, Sendable {
        package var offBy: Caveat?
        package var changedMs: Int64

        package init(offBy: Caveat? = nil, changedMs: Int64 = 0) {
            self.offBy = offBy
            self.changedMs = changedMs
        }
    }

    /// Why a whole install may still say nothing: a setting that silences
    /// it; else, for a trust-bound vendor, a process of the agent that
    /// started after the file last changed (`runningSince`: start times of
    /// its running processes, 0 unknown) while nothing was heard since that
    /// change; else nothing heard through it at all (`neverHeard`: no line
    /// from the agent — or, in a file Pulse owns whole, none since it was
    /// written). Nil for an install that is not whole. Pure.
    package static func caveat(
        agent: AgentID, install: Install, config: Config, heardMs: Int64?, runningSince: [Int64]
    ) -> Caveat? {
        guard install.carriesHook else { return nil }
        if let off = config.offBy { return off }
        guard install == .complete else { return nil }
        if agent.spec.hooks.trustBound, config.changedMs > 0,
           (heardMs ?? 0) < config.changedMs,
           runningSince.contains(where: { $0 == 0 || $0 >= config.changedMs }) {
            return .untrusted
        }
        // A file the person edits too (Claude's settings) changes for
        // reasons of its own: only no line at all says nothing was heard.
        // A file Pulse owns changes only when Pulse writes it.
        guard let heardMs, heardMs > 0 else { return .neverHeard }
        if agent.spec.hooks.format.ownsFile, config.changedMs > 0, heardMs < config.changedMs { return .neverHeard }
        return nil
    }

    /// The vendor setting that silences hooks, first of `switches` that is
    /// set: each names a file (or a folder of `*.json`), read by `read`
    /// (nil: absent or unreadable) and listed by `list`; a top-level `key`
    /// that is JSON `true`. A file that is not a JSON object says nothing.
    /// Pure.
    package static func offBy(
        _ switches: [HookSwitch], read: (String) -> String?, list: (String) -> [String]
    ) -> Caveat? {
        for flip in switches {
            let files = flip.folder
                ? list(flip.path).filter { $0.hasSuffix(".json") }.sorted().map { flip.path + "/" + $0 }
                : [flip.path]
            for file in files {
                guard let text = read(file), let data = text.data(using: .utf8),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let value = object[flip.key] as? Bool, value
                else { continue }
                return flip.caveat
            }
        }
        return nil
    }

    /// Whether the agent's movable config folder is missing while the agent
    /// is on this Mac (`present`: its vendor folder exists, or a process of
    /// it runs). `exists` answers for a home-relative folder — the caller's
    /// file check, so this stays pure.
    package static func configDirMissing(agent: AgentID, present: Bool, exists: (String) -> Bool) -> Bool {
        guard present, let relocation = agent.spec.hooks.relocation else { return false }
        return !exists(relocation.dir)
    }

    /// "Pulse installs to ~/.pi/agent, which isn't there yet — a Pi set to
    /// another folder (PI_CODING_AGENT_DIR) won't load it"; nil when the
    /// folder is there or cannot move.
    package func configDirText(lang: ResolvedLanguage) -> String? {
        guard configDirMissing, let relocation = agent.spec.hooks.relocation else { return nil }
        return String(format: L10n.t(.settingsHookConfigDir, lang), relocation.dir, agent.displayName, relocation.variable)
    }

    /// Whether the vendor's hook says when a session waits on the person.
    package var reportsWaits: Bool { agent.waitingSource == .hooks }

    // MARK: - The words (Settings)

    /// "Installed", "Installed — turned off in its settings", "Needs
    /// update — 9 of 11 events", "Needs update — runs another Pulse",
    /// "Failed · why", "Not installed".
    package func stateText(lang: ResolvedLanguage) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        if let caveat, install == .complete { return caveatText(caveat, lang: lang) }
        switch install {
        case .complete: return t(.settingsHookInstalled)
        case .partial(let found, let of): return String(format: t(.settingsHookPartial), found, of)
        case .staleLauncher: return t(.settingsHookStale)
        case .failed(let failure): return t(.hooksFailed) + " · " + HooksSupport.Status.reason(failure, lang: lang)
        case .notInstalled: return t(.hooksMissing)
        }
    }

    /// An installed hook that may not run, and why: "Installed — but
    /// `disableAllHooks` turns every Claude hook off", "Installed — Codex
    /// hasn't run it yet: trust it in Codex (/hooks)".
    package func caveatText(_ caveat: Caveat, lang: ResolvedLanguage) -> String {
        switch caveat {
        case .turnedOff: return String(format: L10n.t(.settingsHookTurnedOff, lang), agent.displayName)
        case .managedOnly: return String(format: L10n.t(.settingsHookManagedOnly, lang), agent.displayName)
        case .untrusted: return String(format: L10n.t(.settingsHookUntrusted, lang), agent.displayName, agent.displayName)
        case .neverHeard: return L10n.t(.settingsHookNeverHeard, lang)
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

    /// "Last ignored PreCompact — not an installed event · 2m ago"; nil
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
        case .notABlock?: return t(.ignoredNotABlock)
        case .noPrompt?: return t(.ignoredNoPrompt)
        case .otherSession?: return t(.ignoredOtherSession)
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
    /// ignored PreCompact (not an installed event) 3s ago, reports waits".
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
        switch caveat {
        case .turnedOff?: parts.append("hooks turned off by its settings (disableAllHooks)")
        case .managedOnly?: parts.append("blocked by managed policy (allowManagedHooksOnly / disableAllHooks)")
        case .untrusted?: parts.append("not run since its file changed while it ran (untrusted?)")
        case .neverHeard?: parts.append("nothing heard through it since it was installed")
        case nil: break
        }
        if let heard = lastHeard, heard.ms > 0 {
            parts.append("heard \(Self.reportEvent(heard.event)) \(age(heard.ms))")
        } else if install.carriesHook, caveat != .neverHeard {
            parts.append("nothing heard yet")
        }
        if let ignored = lastIgnored, ignored.ms > 0 {
            parts.append("last ignored \(Self.reportEvent(ignored.event)) (\(Self.reportReason(ignored.reason))) \(age(ignored.ms))")
        }
        if install.carriesHook || present {
            parts.append(reportsWaits ? "reports waits" : "doesn't report waits")
        }
        if configDirMissing, let relocation = agent.spec.hooks.relocation {
            parts.append("installs to ~/\(relocation.dir), not there (\(relocation.variable) is not followed)")
        }
        return "  \(agent.rawValue): " + parts.joined(separator: ", ")
    }
}
