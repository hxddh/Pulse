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

    static var codexConfigURL: URL { homeURL.appendingPathComponent(".codex/config.toml") }

    /// Whether the vendor's own directory exists — Pulse installs nothing
    /// for an agent that is not on this Mac.
    static func vendorPresent(_ agent: AgentID) -> Bool {
        var isDirectory: ObjCBool = false
        let path = homeURL.appendingPathComponent(agent.spec.hooks.home).path
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Install / uninstall

    /// Why one agent's install or removal did not happen. The UI says it in
    /// the person's language (`L10n`); the path goes to the debug log only.
    enum Failure: String, Equatable, Sendable {
        /// Its config is not valid JSON, or not a JSON object: Pulse never
        /// rewrites it.
        case invalidJSON
        /// A file Pulse did not write is where its module goes.
        case notOurs
        /// The file could not be read or written.
        case unwritable
    }

    /// One agent's install or removal.
    struct AgentResult: Equatable, Sendable {
        var agent: AgentID
        /// What was done, with paths — for the debug log and tests, never
        /// the UI.
        var report: String
        var failure: Failure?

        var line: String {
            agent.rawValue + ": " + (failure.map { "failed (\($0.rawValue)) — " } ?? "") + report
        }
    }

    static func failure(of error: Error) -> Failure {
        switch error as? InstallError {
        case .invalidJSON?: return .invalidJSON
        case .notOurs?: return .notOurs
        case nil: return .unwritable
        }
    }

    /// Install for every agent whose vendor directory exists (or exactly
    /// `agents`, when given). One result per agent: a config Pulse must not
    /// rewrite stops that agent only, never the ones after it. Throws only
    /// when the launcher itself cannot be written — then nothing was done.
    @discardableResult
    static func install(agents: [AgentID]? = nil) throws -> [AgentResult] {
        try ensureLauncher()
        let targets = agents ?? AgentID.priority.filter(vendorPresent)
        return targets.map { agent in each(agent) { try install(agent) } }
    }

    /// Remove Pulse from every agent's config. One result per agent; one
    /// agent's failure does not stop the others.
    @discardableResult
    static func uninstall(agents: [AgentID] = AgentID.priority) -> [AgentResult] {
        agents.map { agent in each(agent) { try uninstall(agent) } }
    }

    private static func each(_ agent: AgentID, _ body: () throws -> String) -> AgentResult {
        do {
            return AgentResult(agent: agent, report: try body(), failure: nil)
        } catch {
            let reason = Self.failure(of: error)
            DebugLog.write("hooks \(agent.rawValue) \(reason.rawValue): \(error.localizedDescription)")
            return AgentResult(agent: agent, report: error.localizedDescription, failure: reason)
        }
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
    /// format. Pure — the status line reads it.
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
    /// Only the `hooks` member is rewritten (`JSONSplice`): every other key,
    /// its order and its formatting stay exactly as the user wrote them.
    static func renderNested(_ agent: AgentID, _ contract: HookContract, existing: String?) throws -> String {
        let entries = contract.events.map { event -> (String, [String]) in
            var body: [(String, String)] = [
                ("type", literal("command")),
                ("command", literal(hookCommand(agent: agent, event: event.name))),
            ]
            switch contract.format {
            case .claudeSettings:
                // Async: Claude runs it in the background and ignores any
                // decision it could return.
                body.append(("timeout", String(hookTimeoutSeconds)))
                body.append(("async", "true"))
            case .codexHooks:
                // Codex always runs SessionEnd synchronously, caps its
                // timeout at 3 s, and warns when either is asked otherwise.
                if event.name == "SessionEnd" {
                    body.append(("timeout", String(min(hookTimeoutSeconds, 3))))
                } else {
                    body.append(("timeout", String(hookTimeoutSeconds)))
                    body.append(("async", "true"))
                }
            case .geminiSettings:
                body.append(("name", literal("pulse-\(event.name)")))
                body.append(("timeout", String(hookTimeoutSeconds * 1000)))
            case .cursorHooks, .copilotHooks, .openCodePlugin, .piExtension:
                break
            }
            var entry: [(String, String)] = []
            if let matcher = event.matcher { entry.append(("matcher", literal(matcher))) }
            entry.append(("hooks", "[" + JSONSplice.inlineObject(body) + "]"))
            return (event.name, [JSONSplice.inlineObject(entry)])
        }
        return try splice(existing, agent: agent, pulse: entries, version: false, dropEmptyHooks: false)
    }

    /// Cursor's `{"version": 1, "hooks": {event: [{"command": …}]}}`.
    static func renderVersioned(_ agent: AgentID, _ contract: HookContract, existing: String?, key: String) throws -> String {
        let entries = contract.events.map { event in
            (event.name, [JSONSplice.inlineObject([(key, literal(hookCommand(agent: agent, event: event.name)))])])
        }
        return try splice(existing, agent: agent, pulse: entries, version: true, dropEmptyHooks: false)
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

    /// The user's file without Pulse's entries; a `hooks` left empty goes.
    static func stripNested(_ text: String, path: String) throws -> String? {
        try splice(text, path: path, pulse: [], version: false, dropEmptyHooks: true)
    }

    /// Cursor's file without Pulse's entries (its `hooks` stays, maybe empty).
    static func stripVersioned(_ text: String, path: String) throws -> String? {
        try splice(text, path: path, pulse: [], version: false, dropEmptyHooks: false)
    }

    private static func splice(
        _ text: String?, agent: AgentID, pulse: [(String, [String])], version: Bool, dropEmptyHooks: Bool
    ) throws -> String {
        try splice(text, path: configURL(for: agent).path, pulse: pulse, version: version, dropEmptyHooks: dropEmptyHooks)
    }

    /// Validate `text` as a JSON object (the refusal keeps the user's file
    /// untouched), then rewrite only its `hooks` member.
    static func splice(
        _ text: String?, path: String, pulse: [(String, [String])], version: Bool, dropEmptyHooks: Bool
    ) throws -> String {
        _ = try jsonObject(text, path: path)
        do {
            return try JSONSplice.replacingHooks(
                in: text ?? "",
                pulse: pulse,
                isPulse: containsPulseMarker,
                ensureVersion: version,
                dropEmptyHooks: dropEmptyHooks
            )
        } catch {
            throw InstallError.invalidJSON(path, "not valid JSON")
        }
    }

    /// A string as a JSON literal, slashes unescaped.
    static func literal(_ text: String) -> String {
        HookModules.literal(text)
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

    /// Pulse's own files (Copilot's hook file) only — never a user's config.
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

    /// The ledger holds the user's own config text: 0600 from the first
    /// byte (`PrivateFile`), never world-readable while it is written.
    static func saveLedger(_ ledger: [String: LedgerEntry]) throws {
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        if ledger.isEmpty {
            try? FileManager.default.removeItem(at: ledgerURL)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard PrivateFile.write(try encoder.encode(ledger), to: ledgerURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
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

/// 24.0 · rewrite one member of a user's JSON config and leave every other
/// byte as they wrote it.
///
/// `JSONSerialization` round-trips lose key order, spacing and number
/// spelling, so an install used to rewrite the whole `settings.json` in its
/// own style. This reads the text with byte offsets — enough to find the
/// root object's `hooks` member, its events and their entries — and splices
/// one replacement into the original bytes. The caller validates the text
/// with `JSONSerialization` first; a shape this reader does not follow
/// throws, and the file is refused rather than guessed at.
enum JSONSplice {
    struct Malformed: Error {}

    struct Member {
        var key: String
        /// Offset of the key's opening quote.
        var start: Int
        var valueStart: Int
        /// One past the value's last byte.
        var valueEnd: Int
    }

    struct Reader {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8], at index: Int = 0) {
            self.bytes = bytes
            self.index = index
        }

        static func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }

        mutating func skipSpace() {
            while index < bytes.count, Self.isSpace(bytes[index]) { index += 1 }
        }

        mutating func expect(_ byte: UInt8) throws {
            guard index < bytes.count, bytes[index] == byte else { throw Malformed() }
            index += 1
        }

        /// One value from here; its byte range.
        mutating func skipValue() throws -> Range<Int> {
            skipSpace()
            guard index < bytes.count else { throw Malformed() }
            let start = index
            switch bytes[index] {
            case UInt8(ascii: "{"): _ = try members()
            case UInt8(ascii: "["): _ = try elements()
            case UInt8(ascii: "\""): _ = try string()
            default:
                while index < bytes.count, !Self.isSpace(bytes[index]),
                      bytes[index] != UInt8(ascii: ","), bytes[index] != UInt8(ascii: "}"), bytes[index] != UInt8(ascii: "]") {
                    index += 1
                }
                guard index > start else { throw Malformed() }
            }
            return start..<index
        }

        /// A string from its opening quote, decoded.
        mutating func string() throws -> String {
            let open = index
            try expect(UInt8(ascii: "\""))
            while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard index < bytes.count else { throw Malformed() }
            index += 1
            let raw = Data(bytes[open..<index])
            guard let text = try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]) as? String else {
                throw Malformed()
            }
            return text
        }

        /// An object from its `{`: the members in order.
        mutating func members() throws -> [Member] {
            try expect(UInt8(ascii: "{"))
            var out: [Member] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return out
            }
            while true {
                skipSpace()
                let start = index
                let key = try string()
                skipSpace()
                try expect(UInt8(ascii: ":"))
                let value = try skipValue()
                out.append(Member(key: key, start: start, valueStart: value.lowerBound, valueEnd: value.upperBound))
                skipSpace()
                guard index < bytes.count else { throw Malformed() }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                try expect(UInt8(ascii: "}"))
                return out
            }
        }

        /// An array from its `[`: the elements' ranges in order.
        mutating func elements() throws -> [Range<Int>] {
            try expect(UInt8(ascii: "["))
            var out: [Range<Int>] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return out
            }
            while true {
                out.append(try skipValue())
                skipSpace()
                guard index < bytes.count else { throw Malformed() }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                try expect(UInt8(ascii: "]"))
                return out
            }
        }
    }

    /// `{"a": 1, "b": "x"}` from members whose values are already JSON text.
    static func inlineObject(_ members: [(String, String)]) -> String {
        "{" + members.map { HookModules.literal($0.0) + ": " + $0.1 }.joined(separator: ", ") + "}"
    }

    /// `text` with its root object's `hooks` member rebuilt: the user's own
    /// events and entries verbatim and in their order, every entry
    /// `isPulse` says is Pulse's dropped, `pulse`'s entries appended per
    /// event (new events after the user's). Every byte outside `hooks` is
    /// kept. `ensureVersion` adds `"version": 1` when the root has none;
    /// `dropEmptyHooks` removes a `hooks` member left empty.
    static func replacingHooks(
        in text: String,
        pulse: [(String, [String])],
        isPulse: (String) -> Bool,
        ensureVersion: Bool,
        dropEmptyHooks: Bool
    ) throws -> String {
        let bytes = Array(text.utf8)
        let unit = indentUnit(bytes)
        func slice(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // No file (or an empty one): a document of Pulse's own.
            var members: [String] = []
            if ensureVersion { members.append(unit + "\"version\": 1") }
            let hooks = hooksObject(merge([], pulse: pulse, isPulse: isPulse), indent: unit, unit: unit, inline: false)
            if hooks != "{}" || !dropEmptyHooks { members.append(unit + "\"hooks\": " + hooks) }
            return members.isEmpty ? "{}\n" : "{\n" + members.joined(separator: ",\n") + "\n}\n"
        }

        var reader = Reader(bytes)
        reader.skipSpace()
        let open = reader.index
        let root = try reader.members()
        let close = reader.index - 1
        let found = root.last { $0.key == "hooks" }

        // The events the file already has, in order.
        var existing: [Event] = []
        if let found, bytes[found.valueStart] == UInt8(ascii: "{") {
            var inner = Reader(bytes, at: found.valueStart)
            for member in try inner.members() {
                var event = Event(key: member.key, raw: slice(member.valueStart..<member.valueEnd), entries: nil)
                if bytes[member.valueStart] == UInt8(ascii: "[") {
                    var list = Reader(bytes, at: member.valueStart)
                    event.entries = try list.elements().map(slice)
                }
                existing.append(event)
            }
        }
        let merged = merge(existing, pulse: pulse, isPulse: isPulse)
        let dropHooks = merged.isEmpty && dropEmptyHooks

        // Non-overlapping edits, applied from the end of the file.
        var edits: [(range: Range<Int>, text: String)] = []
        if let found {
            let indent = lineIndent(bytes, at: found.start)
            let isObject = bytes[found.valueStart] == UInt8(ascii: "{")
            let changed = !isObject || merged.count != existing.count || merged.contains(where: \.changed)
            if dropHooks {
                edits.append((removalRange(of: found, in: root, open: open, close: close), ""))
            } else if changed {
                let hooks = hooksObject(merged, indent: indent ?? "", unit: unit, inline: indent == nil)
                edits.append((found.valueStart..<found.valueEnd, hooks))
            }
        }
        // New members go after the last one, indented like it.
        let indent: String?
        if let last = root.last {
            indent = lineIndent(bytes, at: last.start)
        } else {
            indent = unit
        }
        var added: [(String, String)] = []
        if ensureVersion, !root.contains(where: { $0.key == "version" }) { added.append(("version", "1")) }
        if found == nil, !dropHooks {
            added.append(("hooks", hooksObject(merged, indent: indent ?? "", unit: unit, inline: indent == nil)))
        }
        if !added.isEmpty {
            let lead = indent.map { "\n" + $0 } ?? " "
            let body = added.map { lead + HookModules.literal($0.0) + ": " + $0.1 }.joined(separator: ",")
            if let last = root.last {
                edits.append((last.valueEnd..<last.valueEnd, "," + body))
            } else {
                edits.append(((open + 1)..<close, body + (indent == nil ? " " : "\n")))
            }
        }
        guard !edits.isEmpty else { return text }
        var out = bytes
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            out.replaceSubrange(edit.range, with: Array(edit.text.utf8))
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// One event of the `hooks` object.
    struct Event {
        var key: String
        /// The value exactly as written.
        var raw: String
        /// Its entries' texts, when the value is an array.
        var entries: [String]?
        /// Pulse's entries were removed or added.
        var changed = false
    }

    /// The user's events with Pulse's entries taken out and `pulse`'s put
    /// in; an event left with nothing goes.
    static func merge(_ existing: [Event], pulse: [(String, [String])], isPulse: (String) -> Bool) -> [Event] {
        var out: [Event] = []
        var placed: Set<String> = []
        for event in existing {
            guard let entries = event.entries else {
                out.append(event)
                continue
            }
            var kept = entries.filter { !isPulse($0) }
            var changed = kept.count != entries.count
            if let mine = pulse.first(where: { $0.0 == event.key })?.1, !placed.contains(event.key) {
                kept += mine
                changed = changed || !mine.isEmpty
                placed.insert(event.key)
            }
            guard !kept.isEmpty else { continue }
            out.append(Event(key: event.key, raw: event.raw, entries: kept, changed: changed))
        }
        for (key, entries) in pulse where !placed.contains(key) && !entries.isEmpty {
            placed.insert(key)
            out.append(Event(key: key, raw: "", entries: entries, changed: true))
        }
        return out
    }

    /// The `hooks` object's text. An event nobody changed keeps its bytes.
    static func hooksObject(_ events: [Event], indent: String, unit: String, inline: Bool) -> String {
        guard !events.isEmpty else { return "{}" }
        func value(_ event: Event) -> String {
            guard event.changed, let entries = event.entries else { return event.raw }
            if inline { return "[" + entries.joined(separator: ", ") + "]" }
            let inner = indent + unit + unit
            return "[\n" + entries.map { inner + $0 }.joined(separator: ",\n") + "\n" + indent + unit + "]"
        }
        if inline {
            return "{" + events.map { HookModules.literal($0.key) + ": " + value($0) }.joined(separator: ", ") + "}"
        }
        return "{\n" + events.map { indent + unit + HookModules.literal($0.key) + ": " + value($0) }.joined(separator: ",\n")
            + "\n" + indent + "}"
    }

    /// The whitespace before `offset` on its line, or nil when something
    /// else precedes it there (the member is inline).
    static func lineIndent(_ bytes: [UInt8], at offset: Int) -> String? {
        var start = offset
        while start > 0, bytes[start - 1] != 0x0A {
            guard bytes[start - 1] == 0x20 || bytes[start - 1] == 0x09 else { return nil }
            start -= 1
        }
        return String(decoding: bytes[start..<offset], as: UTF8.self)
    }

    /// The file's own indentation step: the leading whitespace of its first
    /// indented line, else two spaces.
    static func indentUnit(_ bytes: [UInt8]) -> String {
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0A {
                var end = index + 1
                while end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
                if end > index + 1, end < bytes.count, bytes[end] != 0x0A {
                    return String(decoding: bytes[(index + 1)..<end], as: UTF8.self)
                }
            }
            index += 1
        }
        return "  "
    }

    /// The bytes that remove `member` and one separator beside it.
    static func removalRange(of member: Member, in members: [Member], open: Int, close: Int) -> Range<Int> {
        guard let position = members.firstIndex(where: { $0.start == member.start }) else {
            return member.start..<member.valueEnd
        }
        if position > 0 { return members[position - 1].valueEnd..<member.valueEnd }
        if members.count > 1 { return member.start..<members[1].start }
        return (open + 1)..<close
    }
}
