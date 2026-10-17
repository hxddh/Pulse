import Foundation

package enum HooksSupport {
    /// Which agents carry Pulse's hook (all six, each by its own
    /// contract).
    package enum Status: Equatable {
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
        package static var all: Status { .installed(Set(AgentID.allCases)) }

        package func label(lang: ResolvedLanguage) -> String {
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

        /// "Cursor: its hooks file is not valid JSON…", one per agent, in
        /// roster order — words from `L10n`, never an installer's message
        /// (it names paths, and it is English).
        package static func failureText(_ failed: [AgentID: HooksInstaller.Failure], lang: ResolvedLanguage) -> String {
            AgentID.priority.compactMap { agent in
                failed[agent].map { String(format: L10n.t(.hooksAgentFailed, lang), agent.displayName, reason($0, lang: lang)) }
            }.joined(separator: " · ")
        }

        package static func reason(_ failure: HooksInstaller.Failure, lang: ResolvedLanguage) -> String {
            switch failure {
            case .invalidJSON: return L10n.t(.hooksFailureInvalidJSON, lang)
            case .notOurs: return L10n.t(.hooksFailureNotOurs, lang)
            case .unwritable: return L10n.t(.hooksFailureUnwritable, lang)
            case .hasComments: return L10n.t(.hooksFailureHasComments, lang)
            case .unexpectedShape: return L10n.t(.hooksFailureShape, lang)
            }
        }

        package func isInstalled(for agent: AgentID) -> Bool {
            installedAgents.contains(agent)
        }

        package var installedAgents: Set<AgentID> {
            if case .installed(let agents, _) = self { return agents }
            return []
        }

        /// The agents the last install or removal could not do.
        package var failures: [AgentID: HooksInstaller.Failure] {
            if case .installed(_, let failed) = self { return failed }
            return [:]
        }

        package var isWorking: Bool { self == .working }
    }

    package static func supportDir() -> URL {
        if let home = HooksInstaller.homeOverride {
            return home.appendingPathComponent("Library/Application Support/Pulse")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse")
    }

    /// Ensure the native `pulse-hook` launcher exists and points at this app.
    package static func seedAssets() {
        try? FileManager.default.createDirectory(at: supportDir(), withIntermediateDirectories: true)
        try? HooksInstaller.ensureLauncher()
        HooksInstaller.refreshRunnerPath()
    }

    package static func probeStatus() -> Status {
        let launcher = HooksInstaller.launcherURL
        guard FileManager.default.isExecutableFile(atPath: launcher.path) else { return .missing }
        let wired = Set(AgentID.allCases.filter(isWired))
        return wired.isEmpty ? .missing : .installed(wired)
    }

    /// Whether an agent's config carries Pulse's hook (for Codex, its
    /// `hooks.json` — Pulse never touches `config.toml`).
    package static func isWired(_ agent: AgentID) -> Bool {
        guard let text = try? String(contentsOf: HooksInstaller.configURL(for: agent), encoding: .utf8),
              let events = HooksInstaller.installedEvents(agent, text: text)
        else { return false }
        return !events.isEmpty
    }

    /// How one agent's config carries Pulse's hook, read now: whole, partly
    /// (not every event of its contract, or one it no longer has), through
    /// a launcher that is not this Pulse's or cannot run, or not at all.
    /// Six small reads; Settings opening, an install and the launch call it
    /// — never the scan path.
    package static func inspect(_ agent: AgentID) -> Connection.Install {
        guard let text = try? String(contentsOf: HooksInstaller.configURL(for: agent), encoding: .utf8) else {
            return .notInstalled
        }
        let launcher = HooksInstaller.launcherURL.path
        return Connection.Install.classify(
            contract: Set(agent.spec.hooks.events.map(\.name)),
            installed: HooksInstaller.installedEvents(agent, text: text),
            launchers: HooksInstaller.launcherPaths(in: text),
            expected: launcher,
            launcherRuns: FileManager.default.isExecutableFile(atPath: launcher),
            runnerRuns: runnerRuns()
        )
    }

    /// Every agent's install, read now.
    package static func inspectAll() -> [AgentID: Connection.Install] {
        Dictionary(uniqueKeysWithValues: AgentID.allCases.map { ($0, inspect($0)) })
    }

    /// What else one agent's config says, read now and read only: a vendor
    /// setting that silences every hook (`HookContract.offSwitches` —
    /// Claude's settings and its managed settings, never a transcript), and
    /// when the file Pulse edits last changed. A home-relative path is under
    /// `HooksInstaller.homeURL`, an absolute one is the system's.
    package static func config(_ agent: AgentID) -> Connection.Config {
        let fm = FileManager.default
        func url(_ path: String) -> URL {
            path.hasPrefix("/") ? URL(fileURLWithPath: path) : HooksInstaller.homeURL.appendingPathComponent(path)
        }
        let offBy = Connection.offBy(
            agent.spec.hooks.offSwitches,
            read: { try? String(contentsOf: url($0), encoding: .utf8) },
            list: { (try? fm.contentsOfDirectory(atPath: url($0).path)) ?? [] }
        )
        let modified = (try? fm.attributesOfItem(atPath: HooksInstaller.configURL(for: agent).path))?[.modificationDate] as? Date
        let changedMs = modified.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        return Connection.Config(offBy: offBy, changedMs: changedMs)
    }

    /// Every agent's `config`, read now.
    package static func configAll() -> [AgentID: Connection.Config] {
        Dictionary(uniqueKeysWithValues: AgentID.allCases.map { ($0, config($0)) })
    }

    /// Whether the app `hook-runner.path` names can run. No file, or an
    /// empty one, is fine: the launcher then looks in the Applications
    /// folders itself.
    package static func runnerRuns() -> Bool {
        guard let text = try? String(contentsOf: HooksInstaller.runnerPathURL, encoding: .utf8) else { return true }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty || FileManager.default.isExecutableFile(atPath: path)
    }

    /// Installs and removals run one at a time, on this queue: two clicks
    /// never edit the same config at once.
    package static let installQueue = DispatchQueue(label: "io.github.hxddh.pulse.hooks-install", qos: .userInitiated)

    /// Settings' and the setup card's one job: install every agent on this
    /// Mac, or remove every agent's hook.
    package enum Job: Equatable, Sendable {
        case install
        case uninstall
    }

    /// Do one job. `previous`: the failures already said, kept for the
    /// agents this job did not touch — an install that skips an agent not on
    /// this Mac does not forget why its last install failed.
    @discardableResult
    package static func run(_ job: Job, previous: [AgentID: HooksInstaller.Failure] = [:]) -> Status {
        switch job {
        case .install: return install(previous: previous)
        case .uninstall: return uninstall(previous: previous)
        }
    }

    /// Remove Pulse hooks from every agent's config (or `agents`). One
    /// agent's failure does not stop the others; the status names it.
    @discardableResult
    package static func uninstall(agents: [AgentID]? = nil, previous: [AgentID: HooksInstaller.Failure] = [:]) -> Status {
        installQueue.sync {
            seedAssets()
            let results = HooksInstaller.uninstall(agents: agents ?? AgentID.priority)
            return status(after: results, keeping: previous)
        }
    }

    /// Install the native `pulse-hook` into every present agent's config
    /// (or exactly `agents`).
    @discardableResult
    package static func install(agents: [AgentID]? = nil, previous: [AgentID: HooksInstaller.Failure] = [:]) -> Status {
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
    package static func status(
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
    package static func failures(
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
