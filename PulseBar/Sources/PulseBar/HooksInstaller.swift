import Foundation

/// Installs Pulse's hook for every supported agent (24.0), driven by the
/// catalog's `HookContract`s.
///
/// The rule: install only each vendor's documented hook, plugin or
/// extension; only events that cannot change the agent's decisions (never a
/// gating event, never anything that returns a decision — the command is the
/// native `pulse-hook` launcher, which prints nothing and exits 0); and every
/// install is reversible byte for byte.
///
/// Reversibility: before Pulse first writes a file it records the file's
/// exact bytes (or that it did not exist) in `hook-installs.json` beside the
/// launcher, with the text Pulse wrote. Uninstall restores those bytes when
/// the file is still exactly what Pulse wrote; if the user has edited it
/// since, it removes only Pulse-marked entries and keeps everything else.
/// Invalid JSON is never rewritten, and a module file Pulse did not write is
/// never overwritten.
enum HooksInstaller {
    /// Tests redirect installs away from the real user home.
    nonisolated(unsafe) static var homeOverride: URL?

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

    static var launcherURL: URL {
        supportDir.appendingPathComponent(launcherName)
    }

    static var runnerPathURL: URL {
        supportDir.appendingPathComponent(runnerPathName)
    }

    /// The record of what each install replaced.
    static var ledgerURL: URL {
        supportDir.appendingPathComponent("hook-installs.json")
    }

    /// Tokens that unambiguously mean "Pulse owns this hook entry".
    ///
    /// A bare `--hook` is deliberately NOT in this list: uninstall runs on
    /// the user's own settings, and a user entry like `mytool --hook-dir …`
    /// must never be treated as ours. Legacy installs that pointed straight
    /// at the binary (`…/PulseBar --hook claude`) are still recognized by the
    /// `--hook` + `PulseBar` combination in `containsPulseMarker`.
    static let pulseMarkers = ["pulse-hook"]

    /// Seconds a hook may run before the vendor gives up on it. Pulse's hook
    /// exits at once; this only bounds a pathological case.
    nonisolated(unsafe) static var hookTimeoutSeconds = 5

    static func hookCommand(agent: AgentID, event: String) -> String {
        let launcher = launcherURL.path
        let quoted = launcher.contains(" ") ? "\"\(launcher)\"" : launcher
        return "\(quoted) \(agent.rawValue) \(event)"
    }

    static func codexNotifyArgv() -> [String] {
        [launcherURL.path, "codex"]
    }

    static func configURL(for agent: AgentID) -> URL {
        homeURL.appendingPathComponent(agent.spec.hooks.path)
    }

    static var codexHooksURL: URL { configURL(for: .codex) }
    static var codexConfigURL: URL { homeURL.appendingPathComponent(".codex/config.toml") }

    /// Whether the vendor's own directory exists — Pulse installs nothing
    /// for an agent that is not on this Mac.
    static func vendorPresent(_ agent: AgentID) -> Bool {
        var isDirectory: ObjCBool = false
        let path = homeURL.appendingPathComponent(agent.spec.hooks.home).path
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Install / uninstall

    /// Install for every agent whose vendor directory exists (or exactly
    /// `agents`, when given). One line per agent.
    @discardableResult
    static func install(agents: [AgentID]? = nil) throws -> [String] {
        try ensureLauncher()
        let targets = agents ?? AgentID.priority.filter(vendorPresent)
        return try targets.map { "\($0.rawValue): " + (try install($0)) }
    }

    /// Remove Pulse from every agent's config. One line per agent.
    @discardableResult
    static func uninstall(agents: [AgentID] = AgentID.priority) throws -> [String] {
        try agents.map { "\($0.rawValue): " + (try uninstall($0)) }
    }

    static func install(_ agent: AgentID) throws -> String {
        let contract = agent.spec.hooks
        let url = configURL(for: agent)
        switch contract.format {
        case .claudeSettings, .geminiSettings:
            try edit(url) { try renderNested(agent, contract, existing: $0) }
        case .codexHooks:
            try edit(url) { try renderNested(agent, contract, existing: $0) }
            let notify = try installCodexNotify()
            return url.path + " (" + contract.events.map(\.name).joined(separator: ", ")
                + " — trust them once in Codex: /hooks); " + notify
        case .cursorHooks:
            try edit(url) { try renderVersioned(agent, contract, existing: $0, key: "command") }
        case .copilotHooks, .openCodePlugin, .piExtension:
            try edit(url) { existing in
                if let existing, !containsPulseMarker(existing) {
                    throw InstallError.notOurs(url.path)
                }
                return ownedFile(agent, contract)
            }
        }
        return url.path
    }

    static func uninstall(_ agent: AgentID) throws -> String {
        let contract = agent.spec.hooks
        let url = configURL(for: agent)
        let changed: Bool
        switch contract.format {
        case .claudeSettings, .geminiSettings, .codexHooks:
            changed = try revert(url) { try stripNested($0, path: url.path) }
        case .cursorHooks:
            changed = try revert(url) { try stripVersioned($0, path: url.path) }
        case .copilotHooks, .openCodePlugin, .piExtension:
            changed = try revert(url) { _ in nil }
        }
        var report = url.path + (changed ? "" : " (nothing to remove)")
        if contract.format == .codexHooks {
            report += "; " + (try uninstallCodexNotify())
        }
        return report
    }

    /// Which of an agent's contract events carry Pulse's command in `text`
    /// (the config file's contents); nil when the file cannot be read as its
    /// format. Pure — the status line and the self-check share it.
    static func installedEvents(_ agent: AgentID, text: String) -> Set<String>? {
        let contract = agent.spec.hooks
        switch contract.format {
        case .copilotHooks, .openCodePlugin, .piExtension:
            return containsPulseMarker(text) ? Set(contract.events.map(\.name)) : []
        case .claudeSettings, .geminiSettings, .codexHooks, .cursorHooks:
            guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                return nil
            }
            let hooks = root["hooks"] as? [String: Any] ?? [:]
            var found: Set<String> = []
            for (event, value) in hooks {
                guard let entries = value as? [[String: Any]] else { continue }
                if entries.contains(where: { containsPulseMarker(blob($0)) }) { found.insert(event) }
            }
            return found
        }
    }

    // MARK: - Rendering

    /// Claude, Codex and Gemini share the nested shape:
    /// `{"hooks": {Event: [{"matcher"?, "hooks": [{"type": "command", …}]}]}}`.
    static func renderNested(_ agent: AgentID, _ contract: HookContract, existing: String?) throws -> String {
        var root = try jsonObject(existing, path: configURL(for: agent).path)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        stripPulseEntries(&hooks)
        for event in contract.events {
            var body: [String: Any] = [
                "type": "command",
                "command": hookCommand(agent: agent, event: event.name),
            ]
            switch contract.format {
            case .claudeSettings:
                // Async: Claude runs it in the background and ignores any
                // decision it could return.
                body["timeout"] = hookTimeoutSeconds
                body["async"] = true
            case .codexHooks:
                // Codex always runs SessionEnd synchronously, caps its
                // timeout at 3 s, and warns when either is asked otherwise.
                if event.name == "SessionEnd" {
                    body["timeout"] = min(hookTimeoutSeconds, 3)
                } else {
                    body["timeout"] = hookTimeoutSeconds
                    body["async"] = true
                }
            case .geminiSettings:
                body["name"] = "pulse-\(event.name)"
                body["timeout"] = hookTimeoutSeconds * 1000
            case .cursorHooks, .copilotHooks, .openCodePlugin, .piExtension:
                break
            }
            var entry: [String: Any] = ["hooks": [body]]
            if let matcher = event.matcher { entry["matcher"] = matcher }
            var entries = hooks[event.name] as? [[String: Any]] ?? []
            entries.append(entry)
            hooks[event.name] = entries
        }
        root["hooks"] = hooks
        return try serialize(root)
    }

    /// Cursor's `{"version": 1, "hooks": {event: [{"command": …}]}}`.
    static func renderVersioned(_ agent: AgentID, _ contract: HookContract, existing: String?, key: String) throws -> String {
        var root = try jsonObject(existing, path: configURL(for: agent).path)
        if root["version"] == nil { root["version"] = 1 }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        stripPulseEntries(&hooks)
        for event in contract.events {
            var entries = hooks[event.name] as? [[String: Any]] ?? []
            entries.append([key: hookCommand(agent: agent, event: event.name)])
            hooks[event.name] = entries
        }
        root["hooks"] = hooks
        return try serialize(root)
    }

    /// A file Pulse owns whole: Copilot's hook file, the OpenCode plugin, the
    /// Pi extension.
    static func ownedFile(_ agent: AgentID, _ contract: HookContract) -> String {
        switch contract.format {
        case .copilotHooks:
            var hooks: [String: Any] = [:]
            for event in contract.events {
                let entry: [String: Any] = [
                    "type": "command",
                    "bash": hookCommand(agent: agent, event: event.name),
                    "timeoutSec": hookTimeoutSeconds,
                ]
                hooks[event.name] = [entry]
            }
            let root: [String: Any] = ["version": 1, "hooks": hooks]
            return (try? serialize(root)) ?? "{}\n"
        case .openCodePlugin:
            return HookModules.openCodePlugin(launcher: launcherURL.path, events: contract.events.map(\.name))
        case .piExtension:
            return HookModules.piExtension(launcher: launcherURL.path, events: contract.events.map(\.name))
        case .claudeSettings, .codexHooks, .geminiSettings, .cursorHooks:
            return ""
        }
    }

    static func stripNested(_ text: String, path: String) throws -> String? {
        var root = try jsonObject(text, path: path)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        stripPulseEntries(&hooks)
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return try serialize(root)
    }

    static func stripVersioned(_ text: String, path: String) throws -> String? {
        var root = try jsonObject(text, path: path)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        stripPulseEntries(&hooks)
        root["hooks"] = hooks
        return try serialize(root)
    }

    /// Drop every Pulse-owned entry, and an event left with none.
    static func stripPulseEntries(_ hooks: inout [String: Any]) {
        for event in Array(hooks.keys) {
            guard let entries = hooks[event] as? [[String: Any]] else { continue }
            let kept = entries.filter { !containsPulseMarker(blob($0)) }
            if kept.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = kept
            }
        }
    }

    private static func blob(_ entry: [String: Any]) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: entry), encoding: .utf8)) ?? ""
    }

    private static func jsonObject(_ text: String?, path: String) throws -> [String: Any] {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(text.utf8))
        } catch {
            throw InstallError.invalidJSON(path, "not valid JSON (\(error.localizedDescription))")
        }
        guard let object = parsed as? [String: Any] else {
            throw InstallError.invalidJSON(path, "top level is not a JSON object")
        }
        return object
    }

    private static func serialize(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        var text = String(decoding: data, as: UTF8.self)
        if !text.hasSuffix("\n") { text += "\n" }
        return text
    }

    // MARK: - Reversible edits

    /// What one install replaced.
    struct LedgerEntry: Codable, Equatable {
        /// The file existed before Pulse first wrote it.
        var existed: Bool
        /// Its exact contents then — nil when Pulse cannot know them (it
        /// already carried a Pulse entry from an older install).
        var original: String?
        /// What Pulse wrote last.
        var written: String
        /// Directories Pulse created for it, outermost first.
        var createdDirectories: [String]

        /// Uninstall can put the file back exactly.
        var exact: Bool { !existed || original != nil }
    }

    static func loadLedger() -> [String: LedgerEntry] {
        guard let data = try? Data(contentsOf: ledgerURL),
              let ledger = try? JSONDecoder().decode([String: LedgerEntry].self, from: data)
        else { return [:] }
        return ledger
    }

    static func saveLedger(_ ledger: [String: LedgerEntry]) throws {
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        if ledger.isEmpty {
            try? FileManager.default.removeItem(at: ledgerURL)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ledger).write(to: ledgerURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledgerURL.path)
    }

    /// Write `render(current contents)` to `url`, recording what it replaced.
    static func edit(_ url: URL, render: (String?) throws -> String) throws {
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath()
        let existed = fm.fileExists(atPath: target.path)
        let current: String?
        if existed {
            current = try String(contentsOf: target, encoding: .utf8)
        } else {
            current = nil
        }
        let text = try render(current)
        var ledger = loadLedger()
        var entry: LedgerEntry
        if let prior = ledger[target.path], prior.written == current {
            // Pulse wrote what is there: the first install's record stands.
            entry = prior
        } else {
            let pristine = current.map { !containsPulseMarker($0) } ?? true
            entry = LedgerEntry(
                existed: existed,
                original: pristine ? current : nil,
                written: "",
                createdDirectories: try createDirectories(for: target)
            )
        }
        if current == text {
            // Already exactly this install.
            entry.written = text
            ledger[target.path] = entry
            try saveLedger(ledger)
            return
        }
        try writeConfig(text, to: target)
        entry.written = text
        ledger[target.path] = entry
        try saveLedger(ledger)
    }

    /// Undo `edit`. `strip` turns a file the user has changed since into one
    /// without Pulse (nil: the file was all Pulse's — delete it). Returns
    /// whether anything changed.
    @discardableResult
    static func revert(_ url: URL, strip: (String) throws -> String?) throws -> Bool {
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath()
        let current = try? String(contentsOf: target, encoding: .utf8)
        var ledger = loadLedger()
        let entry = ledger.removeValue(forKey: target.path)
        if let entry, entry.exact, current == entry.written {
            if entry.existed, let original = entry.original {
                try writeConfig(original, to: target)
            } else {
                try fm.removeItem(at: target)
                for directory in entry.createdDirectories.reversed() {
                    let contents = (try? fm.contentsOfDirectory(atPath: directory)) ?? ["?"]
                    if contents.isEmpty { try? fm.removeItem(atPath: directory) }
                }
            }
            try saveLedger(ledger)
            return true
        }
        try saveLedger(ledger)
        guard let current, containsPulseMarker(current) else { return false }
        if let stripped = try strip(current) {
            try writeConfig(stripped, to: target)
        } else {
            try fm.removeItem(at: target)
        }
        return true
    }

    /// Create the parents of `url` that do not exist; the ones created,
    /// outermost first.
    private static func createDirectories(for url: URL) throws -> [String] {
        let fm = FileManager.default
        var missing: [URL] = []
        var directory = url.deletingLastPathComponent()
        while !fm.fileExists(atPath: directory.path), directory.path != "/" {
            missing.append(directory)
            directory = directory.deletingLastPathComponent()
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return missing.reversed().map(\.path)
    }

    // MARK: - Launcher

    static func ensureLauncher() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        # Pulse native attention hook.
        # Prints nothing and soft-fails (exit 0) when the PulseBar runner is
        # missing, so no vendor agent is ever blocked or steered by it.
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
        exec "$RUNNER" --hook "$@" >/dev/null 2>&1
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
            let processPath = ProcessInfo.processInfo.arguments.first ?? ""
            if !processPath.isEmpty, fm.isExecutableFile(atPath: processPath) {
                return processPath
            }
            return Bundle.main.executableURL?.path ?? processPath
        }()
        guard !runner.isEmpty else { return }
        // A test harness must never become the hook runner: pointing
        // hook-runner.path at xctest breaks the real Waiting path until the
        // next Pulse launch overwrites it.
        let basename = (runner as NSString).lastPathComponent.lowercased()
        guard !basename.contains("xctest") else { return }
        try? (runner + "\n").write(to: runnerPathURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Codex notify

    /// Codex's legacy `notify` argv (`agent-turn-complete`), kept beside
    /// hooks.json for Codex builds without hooks. Codex runs exactly one
    /// notify: a user's own is kept and Pulse's is not added.
    private static func installCodexNotify() throws -> String {
        let cfg = codexConfigURL
        var report = cfg.path
        try edit(cfg) { existing in
            let text = existing ?? ""
            let argv = codexNotifyArgv()
            let quoted = argv.map { value -> String in
                let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\""
            }.joined(separator: ", ")
            let end = rootTableEnd(text)
            var root = String(text.prefix(end))
            let rest = String(text.dropFirst(end))
            if root.range(of: #"(?m)^\s*notify\s*=.*pulse-hook"#, options: .regularExpression) != nil {
                return text
            }
            if root.range(of: #"(?m)^\s*notify\s*="#, options: .regularExpression) != nil {
                report += " (kept your own notify — Codex allows one; Pulse was not added)"
                return text
            }
            if !root.isEmpty, !root.hasSuffix("\n") { root += "\n" }
            root += "\n# Pulse attention hooks\nnotify = [\(quoted)]\n"
            if !rest.isEmpty {
                if !root.hasSuffix("\n") { root += "\n" }
                if !root.hasSuffix("\n\n") { root += "\n" }
            }
            return root + rest
        }
        return report
    }

    private static func uninstallCodexNotify() throws -> String {
        let cfg = codexConfigURL
        let changed = try revert(cfg) { text in
            var kept: [String] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                if containsPulseMarker(line) { continue }
                if line.trimmingCharacters(in: .whitespaces) == "# Pulse attention hooks" { continue }
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
            return body
        }
        return cfg.path + (changed ? "" : " (nothing to remove)")
    }

    // MARK: - Files

    /// Write a vendor config in place of the file the user actually has.
    ///
    /// `String.write(atomically:)` replaces the path it is given: a
    /// settings.json symlinked from a dotfiles repo became a plain file, and
    /// its mode reset to the umask. Resolve the link first and carry the
    /// existing mode across.
    static func writeConfig(_ text: String, to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        let mode = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions]
        try text.write(to: target, atomically: true, encoding: .utf8)
        if let mode {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
        }
    }

    /// Offset where Codex's root table ends (start of the first `[section]`).
    static func rootTableEnd(_ text: String) -> Int {
        if let regex = try? NSRegularExpression(pattern: #"(?m)^[ \t]*\["#),
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
        case invalidJSON(String, String)
        case notOurs(String)

        var errorDescription: String? {
            switch self {
            case .invalidJSON(let path, let reason):
                return "refusing to rewrite \(path): \(reason). Fix or move the file, then install hooks again."
            case .notOurs(let path):
                return "refusing to replace \(path): it is not Pulse's. Move it, then install hooks again."
            }
        }
    }
}
