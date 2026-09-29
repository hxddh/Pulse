import Foundation

enum HooksSupport {
    enum Status: Equatable {
        case unknown
        case missing
        case installedClaude
        case installedCodex
        case installedBoth
        case failed(String)

        func label(lang: ResolvedLanguage) -> String {
            switch self {
            case .unknown: return L10n.t(.hooksUnknown, lang)
            case .missing: return L10n.t(.hooksMissing, lang)
            case .installedBoth: return L10n.t(.hooksInstalledBoth, lang)
            case .installedClaude: return L10n.t(.hooksInstalledClaude, lang)
            case .installedCodex: return L10n.t(.hooksInstalledCodex, lang)
            case .failed(let m): return "\(L10n.t(.hooksFailed, lang)) · \(m)"
            }
        }

        func isInstalled(for agent: AgentID) -> Bool {
            switch (self, agent) {
            case (.installedBoth, .claude), (.installedBoth, .codex),
                 (.installedClaude, .claude), (.installedCodex, .codex):
                return true
            default:
                return false
            }
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
        let hasAsset = FileManager.default.isExecutableFile(atPath: launcher.path)
        guard hasAsset else { return .missing }

        let home = HooksInstaller.homeURL
        let claudeCandidates = [
            home.appendingPathComponent(".claude/settings.json"),
            home.appendingPathComponent(".claude/settings.local.json"),
        ]
        let codex = home.appendingPathComponent(".codex/config.toml")
        let claudeOK = claudeCandidates.contains { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return HooksInstaller.containsPulseMarker(text)
        }
        // Codex hooks live in two places: `config.toml` `notify` and, since
        // 18.0, `~/.codex/hooks.json` (Stop + UserPromptSubmit). Either one
        // carrying Pulse's marker means Codex is wired.
        let codexOK = codexHooked(
            configTOML: try? String(contentsOf: codex, encoding: .utf8),
            hooksJSON: try? String(contentsOf: HooksInstaller.codexHooksURL, encoding: .utf8)
        )
        switch (claudeOK, codexOK) {
        case (true, true): return .installedBoth
        case (true, false): return .installedClaude
        case (false, true): return .installedCodex
        case (false, false): return .missing
        }
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

    /// Remove Pulse hooks from Claude/Codex configs.
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

    /// Install native `pulse-hook` into Claude/Codex configs.
    @discardableResult
    static func install() -> Status {
        seedAssets()
        do {
            _ = try HooksInstaller.install()
        } catch {
            return .failed(error.localizedDescription)
        }
        let status = probeStatus()
        return status == .missing ? .missing : status
    }

    /// Exercise the native hook receiver end-to-end in an isolated temporary
    /// Pulse home. Never writes a fake wait into the user's attention log and
    /// never asks for Automation, Accessibility, or Screen Recording.
    static func selfTest() -> SelfTestResult {
        seedAssets()
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent(
            "pulse-hook-selftest-\(UUID().uuidString)",
            isDirectory: true
        )
        let previousOverride = AttentionIO.pathOverride
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            defer {
                AttentionIO.pathOverride = previousOverride
                try? fm.removeItem(at: temp)
            }
            AttentionIO.pathOverride = temp.appendingPathComponent("attention.tsv")
            PulseHookReceiver.appendEvent(
                agent: "codex",
                kind: PulseHookReceiver.normalizeKind("request_user_input"),
                message: "Pulse self-test",
                session: "selftest",
                cwd: ""
            )
            // Also exercise argv/stdin parsing the vendor path uses.
            _ = PulseHookReceiver.run(
                arguments: ["--hook", "codex", "request_user_input"],
                stdin: #"{"message":"Pulse self-test","session_id":"selftest"}"#
            )
            let text = try String(contentsOf: AttentionIO.path, encoding: .utf8)
            guard text.contains("codex\tquestion\t"),
                  text.contains("\tPulse self-test\tselftest\t")
            else { return .failed("hook output mismatch") }
            return .passed(Date())
        } catch {
            AttentionIO.pathOverride = previousOverride
            return .failed(error.localizedDescription)
        }
    }
}
