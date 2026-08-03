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
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse")
    }

    /// Seed hook scripts into Application Support — never downgrade a flock-aware hook.
    static func seedAssets() {
        let fm = FileManager.default
        let dir = supportDir()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["pulse_hook.py", "install_hooks.py"] {
            guard let src = resourceURL(named: name) else { continue }
            let dest = dir.appendingPathComponent(name)
            let srcText = (try? String(contentsOf: src, encoding: .utf8)) ?? ""
            if fm.fileExists(atPath: dest.path),
               let destText = try? String(contentsOf: dest, encoding: .utf8) {
                if destText == srcText { continue }
                // Never replace a flock-aware hook with a weaker bundled copy.
                if name == "pulse_hook.py",
                   destText.contains("fcntl.flock"),
                   !srcText.contains("fcntl.flock") {
                    DebugLog.write("seed skip downgrade \(name)")
                    continue
                }
                try? fm.removeItem(at: dest)
            }
            try? fm.copyItem(at: src, to: dest)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        }
    }

    static func probeStatus() -> Status {
        let hook = supportDir().appendingPathComponent("pulse_hook.py")
        guard FileManager.default.fileExists(atPath: hook.path) else { return .missing }
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Claude Code merges settings.json with settings.local.json; hooks in
        // either file are live, so checking only the first reported a false
        // "not installed" and nagged users who had wired it up themselves.
        let claudeCandidates = [
            home.appendingPathComponent(".claude/settings.json"),
            home.appendingPathComponent(".claude/settings.local.json"),
        ]
        let codex = home.appendingPathComponent(".codex/config.toml")
        let claudeOK = claudeCandidates.contains { url in
            (try? String(contentsOf: url, encoding: .utf8))?.contains("pulse_hook.py") == true
        }
        let codexOK = (try? String(contentsOf: codex, encoding: .utf8))?.contains("pulse_hook.py") == true
        switch (claudeOK, codexOK) {
        case (true, true): return .installedBoth
        case (true, false): return .installedClaude
        case (false, true): return .installedCodex
        case (false, false): return .missing
        }
    }

    /// Remove Pulse hooks from Claude/Codex configs. Leaving dead hook commands
    /// behind after uninstall made both tools spawn a missing script every turn.
    @discardableResult
    static func uninstall() -> Status {
        let script = supportDir().appendingPathComponent("install_hooks.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            return .failed("install_hooks.py missing")
        }
        let result = run(script: script, arguments: ["--uninstall"])
        if case .failure(let message) = result { return .failed(message) }
        return probeStatus()
    }

    @discardableResult
    static func install() -> Status {
        seedAssets()
        let script = supportDir().appendingPathComponent("install_hooks.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            return .failed("install_hooks.py missing")
        }
        let result = run(script: script, arguments: [])
        if case .failure(let message) = result { return .failed(message) }
        let status = probeStatus()
        return status == .missing ? .missing : status
    }

    /// Exercise the shipped hook receiver end-to-end in an isolated temporary
    /// Pulse home. This never writes a fake wait into the user's attention log
    /// and never asks for Automation, Accessibility, or Screen Recording.
    static func selfTest() -> SelfTestResult {
        seedAssets()
        let hook = supportDir().appendingPathComponent("pulse_hook.py")
        guard FileManager.default.fileExists(atPath: hook.path) else {
            return .failed("pulse_hook.py missing")
        }
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent(
            "pulse-hook-selftest-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: temp) }
            let task = Process()
            guard let python = RuntimeResolver.python3() else {
                return .failed("optional Python runtime unavailable")
            }
            task.executableURL = python
            task.arguments = [hook.path, "codex", "request_user_input"]
            var environment = ProcessInfo.processInfo.environment
            environment["PULSE_HOME"] = temp.path
            task.environment = environment
            let input = Pipe()
            task.standardInput = input
            // The self-test only validates the hook file, not its console
            // output. Null devices avoid creating unread pipes that could
            // block if a future hook adds diagnostic output.
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try task.run()
            input.fileHandleForWriting.write(
                Data(#"{"message":"Pulse self-test","session_id":"selftest"}"#.utf8)
            )
            try? input.fileHandleForWriting.close()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else {
                return .failed("hook exit \(task.terminationStatus)")
            }
            let attention = temp.appendingPathComponent("attention.tsv")
            let text = try String(contentsOf: attention, encoding: .utf8)
            guard text.contains("codex\tidle_prompt\t"),
                  text.contains("\tPulse self-test\tselftest\t")
            else { return .failed("hook output mismatch") }
            return .passed(Date())
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private enum RunResult {
        case success
        case failure(String)
    }

    private static func run(script: URL, arguments: [String]) -> RunResult {
        guard let python = RuntimeResolver.python3() else {
            return .failure("optional Python runtime unavailable")
        }
        guard let result = ProcessIO.run(
            executable: python.path,
            arguments: [script.path] + arguments,
            timeout: 4.0
        ) else {
            return .failure("could not start hook installer")
        }
        if result.timedOut {
            return .failure("hook installer timed out")
        }
        if result.status != 0 {
            let msg = String(data: result.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .failure(msg.isEmpty ? "exit \(result.status)" : msg)
        }
        return .success
    }

    private static func resourceURL(named name: String) -> URL? {
        let fm = FileManager.default
        // Prefer repo src/ in dev so seed never ships stale Resources.
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repo = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("src/\(name)")
        if Bundle.main.bundleURL.pathExtension != "app",
           fm.fileExists(atPath: repo.path) {
            return repo
        }
        if let res = Bundle.main.resourceURL?.appendingPathComponent(name),
           fm.fileExists(atPath: res.path) {
            return res
        }
        if let url = PulseResources.url(forResource: name.replacingOccurrences(of: ".py", with: ""), withExtension: "py") {
            return url
        }
        let bundled = here.appendingPathComponent("Resources/\(name)")
        if fm.fileExists(atPath: bundled.path) { return bundled }
        return nil
    }
}
