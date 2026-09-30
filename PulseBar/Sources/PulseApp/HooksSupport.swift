import Foundation

enum HooksSupport {
    /// Which agents carry Pulse's hook (24.0: all seven, each by its own
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

    /// Whether an agent's config carries Pulse's hook. Codex also counts its
    /// `notify` line in config.toml.
    static func isWired(_ agent: AgentID) -> Bool {
        let text = try? String(contentsOf: HooksInstaller.configURL(for: agent), encoding: .utf8)
        if let text, let events = HooksInstaller.installedEvents(agent, text: text), !events.isEmpty {
            return true
        }
        guard agent == .codex else { return false }
        return codexHooked(
            configTOML: try? String(contentsOf: HooksInstaller.codexConfigURL, encoding: .utf8),
            hooksJSON: text
        )
    }

    /// Pure: is Codex wired to Pulse, given the text of `config.toml` and
    /// `hooks.json` (nil when unreadable)? Either file carrying the marker
    /// counts.
    static func codexHooked(configTOML: String?, hooksJSON: String?) -> Bool {
        [configTOML, hooksJSON].contains { text in
            guard let text else { return false }
            return HooksInstaller.containsPulseMarker(text)
        }
    }

    /// Installs and removals run one at a time, on this queue: two clicks
    /// (a line's fix while the section's install runs) never edit the same
    /// config at once.
    static let installQueue = DispatchQueue(label: "com.pulse.hooks-install", qos: .userInitiated)

    /// Remove Pulse hooks from every agent's config. One agent's failure
    /// does not stop the others; the status names it.
    @discardableResult
    static func uninstall() -> Status {
        installQueue.sync {
            seedAssets()
            return status(after: HooksInstaller.uninstall())
        }
    }

    /// Install the native `pulse-hook` into every present agent's config.
    @discardableResult
    static func install() -> Status {
        installQueue.sync {
            seedAssets()
            do {
                return status(after: try HooksInstaller.install())
            } catch {
                let failure = HooksInstaller.failure(of: error)
                DebugLog.write("hooks install failed \(failure.rawValue): \(error.localizedDescription)")
                return .failed(failure)
            }
        }
    }

    /// What is wired now, and which agents the last run could not do.
    static func status(after results: [HooksInstaller.AgentResult]) -> Status {
        var failed: [AgentID: HooksInstaller.Failure] = [:]
        for result in results {
            if let failure = result.failure { failed[result.agent] = failure }
        }
        let probed = probeStatus()
        guard !failed.isEmpty else { return probed }
        return .installed(probed.installedAgents, failed: failed)
    }
}
