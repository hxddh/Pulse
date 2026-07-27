import Foundation

enum HooksSupport {
    enum Status: Equatable {
        case unknown
        case missing
        case installed
        case installedClaude
        case installedCodex
        case installedBoth
        case failed(String)

        func label(lang: ResolvedLanguage) -> String {
            switch self {
            case .unknown: return L10n.t(.hooksUnknown, lang)
            case .missing: return L10n.t(.hooksMissing, lang)
            case .installed, .installedBoth: return L10n.t(.hooksInstalledBoth, lang)
            case .installedClaude: return L10n.t(.hooksInstalledClaude, lang)
            case .installedCodex: return L10n.t(.hooksInstalledCodex, lang)
            case .failed(let m): return "\(L10n.t(.hooksFailed, lang)) · \(m)"
            }
        }
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

    private enum RunResult {
        case success
        case failure(String)
    }

    private static func run(script: URL, arguments: [String]) -> RunResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = [script.path] + arguments
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do {
            try task.run()
            _ = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                let msg = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return .failure(msg.isEmpty ? "exit \(task.terminationStatus)" : msg)
            }
            return .success
        } catch {
            return .failure(error.localizedDescription)
        }
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
        if fm.fileExists(atPath: repo.path) { return repo }
        if let res = Bundle.main.resourceURL?.appendingPathComponent(name),
           fm.fileExists(atPath: res.path) {
            return res
        }
        if let url = Bundle.module.url(forResource: name.replacingOccurrences(of: ".py", with: ""), withExtension: "py") {
            return url
        }
        let bundled = here.appendingPathComponent("Resources/\(name)")
        if fm.fileExists(atPath: bundled.path) { return bundled }
        return nil
    }
}
