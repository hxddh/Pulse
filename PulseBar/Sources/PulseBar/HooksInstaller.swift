import Foundation

/// Native Claude/Codex hook installer — no Python required.
///
/// Ports the merge rules from `src/install_hooks.py`: refuse to wipe invalid
/// JSON, keep one `.pulse-backup`, put Codex `notify` in the root table, and
/// strip both legacy `pulse_hook.py` and native `pulse-hook` markers.
enum HooksInstaller {
    /// Tests redirect installs away from the real user home.
    static var homeOverride: URL?

    static var homeURL: URL {
        homeOverride ?? FileManager.default.homeDirectoryForCurrentUser
    }

    static var supportDir: URL {
        if let homeOverride {
            return homeOverride.appendingPathComponent("Library/Application Support/Pulse")
        }
        return HooksSupport.supportDir()
    }

    static var launcherName: String { "pulse-hook" }
    static var runnerPathName: String { "hook-runner.path" }
    static var legacyHookName: String { "pulse_hook.py" }

    static var launcherURL: URL {
        supportDir.appendingPathComponent(launcherName)
    }

    static var runnerPathURL: URL {
        supportDir.appendingPathComponent(runnerPathName)
    }

    /// Tokens that unambiguously mean "Pulse owns this hook entry".
    ///
    /// A bare `--hook` is deliberately NOT in this list: strip/uninstall run
    /// on the user's own settings, and a user entry like `mytool --hook-dir …`
    /// must never be treated as ours. Legacy installs that pointed straight at
    /// the binary (`…/PulseBar --hook claude`) are still recognized by the
    /// `--hook` + `PulseBar` combination in `containsPulseMarker`.
    static let pulseMarkers = ["pulse-hook", "pulse_hook.py"]

    static func hookCommand(agent: String, kind: String = "") -> String {
        let launcher = launcherURL.path
        let quoted = launcher.contains(" ") ? "\"\(launcher)\"" : launcher
        if kind.isEmpty { return "\(quoted) \(agent)" }
        return "\(quoted) \(agent) \(kind)"
    }

    static func codexNotifyArgv() -> [String] {
        [launcherURL.path, "codex"]
    }

    // MARK: - Install / uninstall

    @discardableResult
    static func install() throws -> [String] {
        try ensureLauncher()
        var reports: [String] = []
        reports.append("claude: " + (try installClaude()))
        reports.append("codex: " + (try installCodex()))
        return reports
    }

    @discardableResult
    static func uninstall() throws -> [String] {
        var reports: [String] = []
        reports.append("claude: " + (try uninstallClaude()))
        reports.append("codex: " + (try uninstallCodex()))
        return reports
    }

    static func ensureLauncher() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        # Pulse native attention hook — no Python required.
        # Soft-fails (exit 0) when the PulseBar runner is missing so vendor
        # agents are never blocked by a missing Waiting path.
        DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
        RUNNER=""
        if [ -f "$DIR/\(runnerPathName)" ]; then
          RUNNER=$(cat "$DIR/\(runnerPathName)" 2>/dev/null)
        fi
        if [ -z "$RUNNER" ] || [ ! -x "$RUNNER" ]; then
          for c in \\
            "/Applications/Pulse.app/Contents/MacOS/PulseBar" \\
            "$HOME/Applications/Pulse.app/Contents/MacOS/PulseBar"
          do
            if [ -x "$c" ]; then RUNNER="$c"; break; fi
          done
        fi
        if [ -z "$RUNNER" ] || [ ! -x "$RUNNER" ]; then
          exit 0
        fi
        exec "$RUNNER" --hook "$@"
        """
        let data = Data(script.utf8)
        try data.write(to: launcherURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherURL.path)
        refreshRunnerPath()
    }

    /// Point Application Support launcher at the currently running PulseBar.
    static func refreshRunnerPath() {
        let fm = FileManager.default
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let runner: String = {
            if let exe = Bundle.main.executableURL?.path,
               fm.isExecutableFile(atPath: exe),
               Bundle.main.bundleURL.pathExtension == "app" {
                return exe
            }
            // `swift run` / XCTest: prefer the process executable.
            let processPath = CommandLine.arguments.first ?? ""
            if !processPath.isEmpty, fm.isExecutableFile(atPath: processPath) {
                return processPath
            }
            return Bundle.main.executableURL?.path ?? processPath
        }()
        guard !runner.isEmpty else { return }
        // A test harness must never become the hook runner: pointing
        // hook-runner.path at xctest breaks the real Waiting path until the
        // next Pulse launch overwrites it, and a test suite run on a dev
        // machine is exactly the situation where that used to happen.
        let basename = (runner as NSString).lastPathComponent.lowercased()
        guard !basename.contains("xctest") else { return }
        try? (runner + "\n").write(to: runnerPathURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Claude

    private static func installClaude() throws -> String {
        let home = homeURL
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var data: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: settings.path) {
            let raw = try String(contentsOf: settings, encoding: .utf8)
            do {
                guard let parsed = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
                    throw InstallError.invalidClaudeJSON(settings.path, "top level is not a JSON object")
                }
                data = parsed
            } catch let error as InstallError {
                throw error
            } catch {
                throw InstallError.invalidClaudeJSON(
                    settings.path,
                    "not valid JSON (\(error.localizedDescription))"
                )
            }
            let backup = settings.deletingPathExtension().appendingPathExtension("json.pulse-backup")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try raw.write(to: backup, atomically: true, encoding: .utf8)
            }
        }
        var hooks = data["hooks"] as? [String: Any] ?? [:]
        // Migrate legacy python markers out so install always lands on native.
        stripPulseHooks(&hooks)
        ensureClaudeEvent(
            &hooks,
            event: "Notification",
            command: hookCommand(agent: "claude"),
            matcher: "permission_prompt|idle_prompt|agent_needs_input"
        )
        ensureClaudeEvent(
            &hooks,
            event: "Stop",
            command: hookCommand(agent: "claude", kind: "stop"),
            matcher: nil
        )
        ensureClaudeEvent(
            &hooks,
            event: "SubagentStart",
            command: hookCommand(agent: "claude", kind: "subagent_start"),
            matcher: nil
        )
        ensureClaudeEvent(
            &hooks,
            event: "SubagentStop",
            command: hookCommand(agent: "claude", kind: "subagent_stop"),
            matcher: nil
        )
        ensureClaudeEvent(
            &hooks,
            event: "PermissionRequest",
            command: hookCommand(agent: "claude", kind: "permission"),
            matcher: nil
        )
        data["hooks"] = hooks
        let out = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
        var text = String(data: out, encoding: .utf8) ?? "{}"
        if !text.hasSuffix("\n") { text += "\n" }
        try text.write(to: settings, atomically: true, encoding: .utf8)
        return settings.path
    }

    private static func stripPulseHooks(_ hooks: inout [String: Any]) {
        for event in Array(hooks.keys) {
            guard let entries = hooks[event] as? [[String: Any]] else { continue }
            let kept = entries.filter { entry in
                let blob = (try? String(data: JSONSerialization.data(withJSONObject: entry), encoding: .utf8)) ?? ""
                return !containsPulseMarker(blob)
            }
            if kept.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = kept
            }
        }
    }

    /// One knob for every Claude hook entry Pulse writes. A re-install
    /// migrates existing entries to the current values (see
    /// `ensureClaudeEvent` — it rewrites Pulse-owned entries, it does not
    /// skip them).
    static var claudeHookTimeoutSeconds = 5
    /// PermissionRequest is the one event where the hook may deliberately
    /// wait (a remote Respond hold). The vendor default is 600s; 90 caps the
    /// hold well below that while leaving room for a human answer. Every
    /// other event keeps the tight budget — the receiver exits immediately.
    static var permissionRequestTimeoutSeconds = 90

    private static func ensureClaudeEvent(
        _ hooks: inout [String: Any],
        event: String,
        command: String,
        matcher: String?
    ) {
        var entries = hooks[event] as? [[String: Any]] ?? []
        // Idempotency by ownership, not token sniffing: earlier this matched
        // loose strings like "claude stop" against the whole event blob, so a
        // user's own entry containing that text suppressed ours — and an
        // already-installed Pulse entry was never updated to a new command or
        // timeout. Rewriting our own entries is the migration path.
        entries.removeAll { entry in
            let blob = (try? String(data: JSONSerialization.data(withJSONObject: entry), encoding: .utf8)) ?? ""
            return containsPulseMarker(blob)
        }
        let timeout = event == "PermissionRequest"
            ? permissionRequestTimeoutSeconds
            : claudeHookTimeoutSeconds
        let hookBody: [String: Any] = [
            "type": "command",
            "command": command,
            "timeout": timeout,
        ]
        var entry: [String: Any] = ["hooks": [hookBody]]
        if let matcher { entry["matcher"] = matcher }
        entries.append(entry)
        hooks[event] = entries
    }

    private static func uninstallClaude() throws -> String {
        let home = homeURL
        let targets = [
            home.appendingPathComponent(".claude/settings.json"),
            home.appendingPathComponent(".claude/settings.local.json"),
        ]
        var removed = 0
        for target in targets {
            guard FileManager.default.fileExists(atPath: target.path) else { continue }
            let raw = try String(contentsOf: target, encoding: .utf8)
            guard containsPulseMarker(raw) else { continue }
            guard var data = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
                throw InstallError.invalidClaudeJSON(target.path, "not valid JSON")
            }
            guard var hooks = data["hooks"] as? [String: Any] else { continue }
            for event in Array(hooks.keys) {
                guard let entries = hooks[event] as? [[String: Any]] else { continue }
                let kept = entries.filter { entry in
                    let blob = (try? String(data: JSONSerialization.data(withJSONObject: entry), encoding: .utf8)) ?? ""
                    return !containsPulseMarker(blob)
                }
                removed += entries.count - kept.count
                if kept.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = kept
                }
            }
            if hooks.isEmpty {
                data.removeValue(forKey: "hooks")
            } else {
                data["hooks"] = hooks
            }
            let out = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
            var text = String(data: out, encoding: .utf8) ?? "{}"
            if !text.hasSuffix("\n") { text += "\n" }
            try text.write(to: target, atomically: true, encoding: .utf8)
        }
        return "\(home.path)/.claude/settings.json (\(removed) hook entries removed)"
    }

    // MARK: - Codex

    private static func installCodex() throws -> String {
        let home = homeURL
        let cfg = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: cfg.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let text = (try? String(contentsOf: cfg, encoding: .utf8)) ?? ""
        let argv = codexNotifyArgv()
        let quoted = argv.map { value -> String in
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }.joined(separator: ", ")
        let line = "notify = [\(quoted)]\n"

        let end = rootTableEnd(text)
        var root = String(text.prefix(end))
        let rest = String(text.dropFirst(end))

        if root.range(of: #"(?m)^\s*notify\s*=.*(pulse-hook|pulse_hook\.py)"#, options: .regularExpression) != nil {
            // Rewrite legacy python notify onto the native launcher.
            if root.contains("pulse_hook.py"), !root.contains("pulse-hook") {
                root = root.replacingOccurrences(
                    of: #"(?m)^\s*notify\s*=.*$"#,
                    with: line.trimmingCharacters(in: .newlines),
                    options: .regularExpression,
                    range: nil
                )
                if !root.hasSuffix("\n") { root += "\n" }
                if !rest.isEmpty {
                    if !root.hasSuffix("\n") { root += "\n" }
                    if !root.hasSuffix("\n\n") { root += "\n" }
                }
                try (root + rest).write(to: cfg, atomically: true, encoding: .utf8)
                return cfg.path + " (migrated)"
            }
            return cfg.path + " (already present)"
        }
        if root.range(of: #"(?m)^\s*notify\s*="#, options: .regularExpression) != nil {
            root = root.replacingOccurrences(
                of: #"(?m)^\s*notify\s*=.*$"#,
                with: line.trimmingCharacters(in: .newlines),
                options: .regularExpression,
                range: nil
            )
            if !root.hasSuffix("\n") { root += "\n" }
        } else {
            if !root.isEmpty, !root.hasSuffix("\n") { root += "\n" }
            root += "\n# Pulse attention hooks\n" + line
        }
        if !rest.isEmpty {
            if !root.hasSuffix("\n") { root += "\n" }
            if !root.hasSuffix("\n\n") { root += "\n" }
        }
        try (root + rest).write(to: cfg, atomically: true, encoding: .utf8)
        return cfg.path
    }

    private static func uninstallCodex() throws -> String {
        let home = homeURL
        let cfg = home.appendingPathComponent(".codex/config.toml")
        guard FileManager.default.fileExists(atPath: cfg.path) else {
            return "\(cfg.path) (absent)"
        }
        let text = try String(contentsOf: cfg, encoding: .utf8)
        guard containsPulseMarker(text) else {
            return "\(cfg.path) (nothing to remove)"
        }
        var kept: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if containsPulseMarker(line) { continue }
            if line.trimmingCharacters(in: .whitespaces) == "# Pulse attention hooks" { continue }
            if line.trimmingCharacters(in: .whitespaces) == "# Pulse v2 attention hooks" { continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty,
               let last = kept.last,
               last.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            kept.append(line)
        }
        var body = kept.joined(separator: "\n")
        while body.hasSuffix("\n\n") { body = String(body.dropLast()) }
        if !body.hasSuffix("\n") { body += "\n" }
        try body.write(to: cfg, atomically: true, encoding: .utf8)
        return cfg.path
    }

    /// Offset where Codex's root table ends (start of the first `[section]`).
    static func rootTableEnd(_ text: String) -> Int {
        if let regex = try? NSRegularExpression(pattern: #"(?m)^\s*\["#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            return text.distance(from: text.startIndex, to: range.lowerBound)
        }
        return text.count
    }

    static func containsPulseMarker(_ text: String) -> Bool {
        if pulseMarkers.contains(where: { text.contains($0) }) { return true }
        // Legacy direct-binary entries only; never a bare `--hook` by itself.
        return text.contains("--hook") && text.contains("PulseBar")
    }

    enum InstallError: LocalizedError {
        case invalidClaudeJSON(String, String)

        var errorDescription: String? {
            switch self {
            case .invalidClaudeJSON(let path, let reason):
                return "refusing to rewrite \(path): \(reason). Fix or move the file, then install hooks again."
            }
        }
    }
}
