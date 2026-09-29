import Foundation

enum HooksSupport {
    /// Which agents carry Pulse's hook (24.0: all seven, each by its own
    /// contract).
    enum Status: Equatable {
        case unknown
        /// The launcher is missing, or no agent carries Pulse's hook.
        case missing
        case installed(Set<AgentID>)
        case failed(String)

        /// Every supported agent — the fixtures' and tests' "all wired".
        static var all: Status { .installed(Set(AgentID.allCases)) }

        func label(lang: ResolvedLanguage) -> String {
            switch self {
            case .unknown: return L10n.t(.hooksUnknown, lang)
            case .missing: return L10n.t(.hooksMissing, lang)
            case .installed(let agents):
                return String(format: L10n.t(.hooksInstalledCount, lang), agents.count, AgentID.allCases.count)
            case .failed(let m): return "\(L10n.t(.hooksFailed, lang)) · \(m)"
            }
        }

        func isInstalled(for agent: AgentID) -> Bool {
            if case .installed(let agents) = self { return agents.contains(agent) }
            return false
        }

        var installedAgents: Set<AgentID> {
            if case .installed(let agents) = self { return agents }
            return []
        }
    }

    enum SelfTestResult: Equatable {
        case idle
        case running
        case passed(Date)
        case failed(String)
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

    /// Remove Pulse hooks from every agent's config.
    @discardableResult
    static func uninstall() -> Status {
        seedAssets()
        do {
            _ = try HooksInstaller.uninstall()
        } catch {
            return .failed(error.localizedDescription)
        }
        return probeStatus()
    }

    /// Install the native `pulse-hook` into every present agent's config.
    @discardableResult
    static func install() -> Status {
        seedAssets()
        do {
            _ = try HooksInstaller.install()
        } catch {
            return .failed(error.localizedDescription)
        }
        return probeStatus()
    }

    /// Exercise the native hook receiver end-to-end in an isolated temporary
    /// file. Never writes a fake wait into the user's attention log and
    /// never asks for Automation, Accessibility, or Screen Recording. The
    /// file is passed explicitly: it runs off the main thread, and a global
    /// override would redirect a scan reading at the same moment.
    static func selfTest() -> SelfTestResult {
        seedAssets()
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent(
            "pulse-hook-selftest-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fm.removeItem(at: temp) }
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            let file = temp.appendingPathComponent("attention.tsv")
            // The vendor path: a Claude Notification as its hook sends it.
            _ = PulseHookReceiver.run(
                arguments: ["--hook", "claude", "Notification"],
                stdin: #"{"hook_event_name":"Notification","notification_type":"elicitation_dialog","message":"Pulse self-test","session_id":"selftest"}"#,
                attentionURL: file,
                locate: { _, _ in (0, "") }
            )
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("claude\tquestion\t"),
                  text.contains("\tPulse self-test\tselftest\t")
            else { return .failed("hook output mismatch") }
            return .passed(Date())
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
