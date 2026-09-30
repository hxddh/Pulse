import Foundation

enum HooksSupport {
    /// Which agents carry Pulse's hook (all seven, each by its own
    /// contract).
    enum Status: Equatable {
        case unknown
        /// An install or removal is running; the buttons wait for it.
        case working
        /// The launcher is missing, or no agent carries Pulse's hook.
        case missing
        /// `failed`: agents whose last install or removal did not happen,
        /// and why — the others were done all the same.
        case installed(Set<AgentID>, failed: [AgentID: HooksInstaller.Failure] = [:])
        /// Nothing could be done (the launcher itself could not be written).
        case failed(HooksInstaller.Failure)

        /// Every supported agent — the fixtures' and tests' "all wired".
        static var all: Status { .installed(Set(AgentID.allCases)) }

        func label(lang: ResolvedLanguage) -> String {
            switch self {
            case .unknown: return L10n.t(.hooksUnknown, lang)
            case .working: return L10n.t(.hooksWorking, lang)
            case .missing: return L10n.t(.hooksMissing, lang)
            case .installed(let agents, let failed):
                var text = agents.isEmpty
                    ? L10n.t(.hooksMissing, lang)
                    : String(format: L10n.t(.hooksInstalledCount, lang), agents.count, AgentID.allCases.count)
                if !failed.isEmpty { text += " · " + Self.failureText(failed, lang: lang) }
                return text
            case .failed(let failure):
                return "\(L10n.t(.hooksFailed, lang)) · \(Self.reason(failure, lang: lang))"
            }
        }

        /// "Gemini: its settings file is not valid JSON…", one per agent, in
        /// roster order — words from `L10n`, never an installer's message
        /// (it names paths, and it is English).
        static func failureText(_ failed: [AgentID: HooksInstaller.Failure], lang: ResolvedLanguage) -> String {
            AgentID.priority.compactMap { agent in
                failed[agent].map { String(format: L10n.t(.hooksAgentFailed, lang), agent.displayName, reason($0, lang: lang)) }
            }.joined(separator: " · ")
        }

        static func reason(_ failure: HooksInstaller.Failure, lang: ResolvedLanguage) -> String {
            switch failure {
            case .invalidJSON: return L10n.t(.hooksFailureInvalidJSON, lang)
            case .notOurs: return L10n.t(.hooksFailureNotOurs, lang)
            case .unwritable: return L10n.t(.hooksFailureUnwritable, lang)
            case .hasComments: return L10n.t(.hooksFailureHasComments, lang)
            case .unexpectedShape: return L10n.t(.hooksFailureShape, lang)
            }
        }

        func isInstalled(for agent: AgentID) -> Bool {
            installedAgents.contains(agent)
        }

        var installedAgents: Set<AgentID> {
            if case .installed(let agents, _) = self { return agents }
            return []
        }

        /// The agents the last install or removal could not do.
        var failures: [AgentID: HooksInstaller.Failure] {
            if case .installed(_, let failed) = self { return failed }
            return [:]
        }

        var isWorking: Bool { self == .working }
    }

    static func supportDir() -> URL {
        if let home = HooksInstaller.homeOverride {
            return home.appendingPathComponent("Library/Application Support/Pulse")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse")
    }

    /// Ensure the native `pulse-hook` launcher exists and points at this app.
    static func seedAssets() {
        try? FileManager.default.createDirectory(at: supportDir(), withIntermediateDirectories: true)
        try? HooksInstaller.ensureLauncher()
        HooksInstaller.refreshRunnerPath()
    }

    static func probeStatus() -> Status {
        let launcher = HooksInstaller.launcherURL
        guard FileManager.default.isExecutableFile(atPath: launcher.path) else { return .missing }
        let wired = Set(AgentID.allCases.filter(isWired))
        return wired.isEmpty ? .missing : .installed(wired)
    }

    /// Whether an agent's config carries Pulse's hook (for Codex, its
    /// `hooks.json` — Pulse never touches `config.toml`).
    static func isWired(_ agent: AgentID) -> Bool {
        guard let text = try? String(contentsOf: HooksInstaller.configURL(for: agent), encoding: .utf8),
              let events = HooksInstaller.installedEvents(agent, text: text)
        else { return false }
        return !events.isEmpty
    }

    /// Installs and removals run one at a time, on this queue: two clicks
    /// (a line's fix while the section's install runs) never edit the same
    /// config at once.
    static let installQueue = DispatchQueue(label: "com.pulse.hooks-install", qos: .userInitiated)

    /// One install or removal: every agent (nil — for an install, every
    /// agent whose vendor folder is on this Mac), or exactly these.
    enum Job: Equatable, Sendable {
        case install([AgentID]?)
        case uninstall([AgentID]?)

        /// The agents it names; nil for every agent.
        var agents: [AgentID]? {
            switch self {
            case .install(let agents), .uninstall(let agents): return agents
            }
        }
    }

    /// Do one job. `previous`: the failures already said, kept for the
    /// agents this job did not touch — removing one agent's hook does not
    /// forget why another's install failed.
    @discardableResult
    static func run(_ job: Job, previous: [AgentID: HooksInstaller.Failure] = [:]) -> Status {
        switch job {
        case .install(let agents): return install(agents: agents, previous: previous)
        case .uninstall(let agents): return uninstall(agents: agents, previous: previous)
        }
    }

    /// Remove Pulse hooks from every agent's config (or `agents`). One
    /// agent's failure does not stop the others; the status names it.
    @discardableResult
    static func uninstall(agents: [AgentID]? = nil, previous: [AgentID: HooksInstaller.Failure] = [:]) -> Status {
        installQueue.sync {
            seedAssets()
            let results = HooksInstaller.uninstall(agents: agents ?? AgentID.priority)
            return status(after: results, keeping: previous)
        }
    }

    /// Install the native `pulse-hook` into every present agent's config
    /// (or exactly `agents`).
    @discardableResult
    static func install(agents: [AgentID]? = nil, previous: [AgentID: HooksInstaller.Failure] = [:]) -> Status {
        installQueue.sync {
            seedAssets()
            do {
                return status(after: try HooksInstaller.install(agents: agents), keeping: previous)
            } catch {
                let failure = HooksInstaller.failure(of: error)
                DebugLog.write("hooks install failed \(failure.rawValue): \(error.localizedDescription)")
                return .failed(failure)
            }
        }
    }

    /// What is wired now, and which agents could not be done: this run's
    /// failures, plus `keeping`'s for the agents this run did not touch.
    static func status(
        after results: [HooksInstaller.AgentResult],
        keeping previous: [AgentID: HooksInstaller.Failure] = [:]
    ) -> Status {
        let failed = failures(after: results, keeping: previous)
        let probed = probeStatus()
        guard !failed.isEmpty else { return probed }
        return .installed(probed.installedAgents, failed: failed)
    }

    /// This run's failures, plus the earlier ones of agents it did not
    /// touch. Pure.
    static func failures(
        after results: [HooksInstaller.AgentResult],
        keeping previous: [AgentID: HooksInstaller.Failure]
    ) -> [AgentID: HooksInstaller.Failure] {
        let touched = Set(results.map(\.agent))
        var failed = previous.filter { !touched.contains($0.key) }
        for result in results {
            if let failure = result.failure { failed[result.agent] = failure }
        }
        return failed
    }
}
