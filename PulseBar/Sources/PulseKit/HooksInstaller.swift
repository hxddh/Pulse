import Foundation

/// Installs Pulse's hook for every supported agent, driven by the catalog's
/// `HookContract`s.
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
package enum HooksInstaller {
    /// Tests redirect installs away from the real user home.
    package nonisolated(unsafe) static var homeOverride: URL?

    package static var homeURL: URL {
        homeOverride ?? FileManager.default.homeDirectoryForCurrentUser
    }

    package static var supportDir: URL {
        if let homeOverride {
            return homeOverride.appendingPathComponent("Library/Application Support/Pulse")
        }
        return HooksSupport.supportDir()
    }

    package static var launcherName: String { "pulse-hook" }
    package static var runnerPathName: String { "hook-runner.path" }

    package static var launcherURL: URL {
        supportDir.appendingPathComponent(launcherName)
    }

    package static var runnerPathURL: URL {
        supportDir.appendingPathComponent(runnerPathName)
    }

    /// The record of what each install replaced.
    package static var ledgerURL: URL {
        supportDir.appendingPathComponent("hook-installs.json")
    }

    /// What marks an entry as Pulse's: the launcher `pulse-hook` as a whole
    /// command token — a path ending in `/pulse-hook`, or the bare word —
    /// never a substring (a user's `impulse-hook.sh` must never be taken for
    /// Pulse's and removed). The quote and backslash boundaries cover the
    /// command as it sits inside JSON and JavaScript text.
    package static let pulseMarkerPattern = #"(?:^|[\s/"'\\])pulse-hook(?:$|[\s"'\\])"#

    /// Seconds a hook may run before the vendor gives up on it. Pulse's hook
    /// exits at once; this only bounds a pathological case.
    package nonisolated(unsafe) static var hookTimeoutSeconds = 5

    package static func hookCommand(agent: AgentID, event: String) -> String {
        let launcher = launcherURL.path
        let quoted = launcher.contains(" ") ? "\"\(launcher)\"" : launcher
        return "\(quoted) \(agent.rawValue) \(event)"
    }

    package static func configURL(for agent: AgentID) -> URL {
        homeURL.appendingPathComponent(agent.spec.hooks.path)
    }

    /// Whether the vendor's own directory exists — Pulse installs nothing
    /// for an agent that is not on this Mac.
    package static func vendorPresent(_ agent: AgentID) -> Bool {
        var isDirectory: ObjCBool = false
        let path = homeURL.appendingPathComponent(agent.spec.hooks.home).path
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Whether a home-relative folder exists (`.pi/agent`).
    package static func homeFolderExists(_ relative: String) -> Bool {
        var isDirectory: ObjCBool = false
        let path = homeURL.appendingPathComponent(relative).path
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Install / uninstall

    /// Why one agent's install or removal did not happen. The UI says it in
    /// the person's language (`L10n`); the path goes to the debug log only.
    package enum Failure: String, Equatable, Sendable {
        /// Its config is not valid JSON, or not a JSON object: Pulse never
        /// rewrites it.
        case invalidJSON
        /// A file Pulse did not write is where its module goes.
        case notOurs
        /// The file could not be read or written.
        case unwritable
        /// It has `//` or `/* */` comments (JSONC) — Pulse's JSON
        /// reader would lose them, so it is not rewritten.
        case hasComments
        /// Its `hooks` (or one event under it) is not the shape the
        /// vendor documents — an object of arrays — so Pulse's entries have
        /// nowhere safe to go.
        case unexpectedShape
    }

    /// One agent's install or removal.
    package struct AgentResult: Equatable, Sendable {
        package var agent: AgentID
        /// What was done, with paths — for the debug log and tests, never
        /// the UI.
        package var report: String
        package var failure: Failure?

        package var line: String {
            agent.rawValue + ": " + (failure.map { "failed (\($0.rawValue)) — " } ?? "") + report
        }
    }

    package static func failure(of error: Error) -> Failure {
        switch error as? InstallError {
        case .invalidJSON?: return .invalidJSON
        case .notOurs?: return .notOurs
        case .hasComments?: return .hasComments
        case .unexpectedShape?: return .unexpectedShape
        case nil: return .unwritable
        }
    }

    /// Install for every agent whose vendor directory exists (or exactly
    /// `agents`, when given). One result per agent: a config Pulse must not
    /// rewrite stops that agent only, never the ones after it. Throws only
    /// when the launcher itself cannot be written — then nothing was done.
    @discardableResult
    package static func install(agents: [AgentID]? = nil) throws -> [AgentResult] {
        try ensureLauncher()
        let targets = agents ?? AgentID.priority.filter(vendorPresent)
        return targets.map { agent in each(agent) { try install(agent) } }
    }

    /// Remove Pulse from every agent's config. One result per agent; one
    /// agent's failure does not stop the others.
    @discardableResult
    package static func uninstall(agents: [AgentID] = AgentID.priority) -> [AgentResult] {
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

    package static func install(_ agent: AgentID) throws -> String {
        let contract = agent.spec.hooks
        let url = configURL(for: agent)
        switch contract.format {
        case .nested(let flavor):
            try edit(url) { try renderNested(agent, contract, flavor: flavor, existing: $0) }
            if let note = flavor.installNote {
                return url.path + " (" + contract.events.map(\.name).joined(separator: ", ") + " — " + note + ")"
            }
        case .versioned(let key):
            try edit(url) { try renderVersioned(agent, contract, existing: $0, key: key) }
        case .ownedJSON, .module:
            try edit(url) { existing in
                if let existing, !containsPulseMarker(existing) {
                    throw InstallError.notOurs(url.path)
                }
                return ownedFile(agent, contract)
            }
        }
        return url.path
    }

    package static func uninstall(_ agent: AgentID) throws -> String {
        let contract = agent.spec.hooks
        let url = configURL(for: agent)
        let changed: Bool
        switch contract.format {
        case .nested:
            changed = try revert(url) { try stripNested($0, path: url.path) }
        case .versioned:
            changed = try revert(url) { try stripVersioned($0, path: url.path) }
        case .ownedJSON, .module:
            changed = try revert(url) { _ in nil }
        }
        return url.path + (changed ? "" : " (nothing to remove)")
    }

    /// Which events carry Pulse's command in `text` (the config file's
    /// contents) — every one, also an event the contract no longer installs;
    /// for a module, the events its `EVENTS` list hands on. Nil when the file
    /// cannot be read as its format. Pure — the status line and the
    /// connection read it.
    package static func installedEvents(_ agent: AgentID, text: String) -> Set<String>? {
        let contract = agent.spec.hooks
        if case .module = contract.format {
            return containsPulseMarker(text) ? moduleEvents(text) : []
        }
        guard let root = try? JSONSerialization.jsonObject(with: Data(JSONSplice.splitBOM(text).body.utf8)) as? [String: Any] else {
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

    /// The event names a module's `const EVENTS = …[…]` list holds (both
    /// modules render one, `HookModules.literal` per name); none when it has
    /// no such list.
    package static func moduleEvents(_ text: String) -> Set<String> {
        guard let start = text.range(of: "const EVENTS = "),
              let open = text[start.upperBound...].firstIndex(of: "["),
              let close = text[open...].firstIndex(of: "]")
        else { return [] }
        let list = "[" + text[text.index(after: open)..<close] + "]"
        let names = (try? JSONSerialization.jsonObject(with: Data(list.utf8))) as? [String]
        return Set(names ?? [])
    }

    /// Every absolute launcher path `text` (a config, or a module) names:
    /// the path ending in each `/pulse-hook` token, JSON's `\/` read as `/`.
    /// A path may hold spaces (`Application Support`), never a quote, a
    /// backslash or a line break. Pure — a hook that names another path
    /// than this Pulse's launcher is stale.
    package static func launcherPaths(in text: String) -> Set<String> {
        let plain = text.replacingOccurrences(of: "\\/", with: "/")
        guard let regex = try? NSRegularExpression(pattern: #"/[^"'\\\n]*/pulse-hook(?=$|[\s"'\\])"#) else { return [] }
        let matches = regex.matches(in: plain, range: NSRange(plain.startIndex..., in: plain))
        return Set(matches.compactMap { match in Range(match.range, in: plain).map { String(plain[$0]) } })
    }

    // MARK: - Rendering

    /// Claude and Codex share the nested shape:
    /// `{"hooks": {Event: [{"matcher"?, "hooks": [{"type": "command", …}]}]}}`.
    /// Only the `hooks` member is rewritten (`JSONSplice`): every other key,
    /// its order and its formatting stay exactly as the user wrote them.
    package static func renderNested(_ agent: AgentID, _ contract: HookContract, flavor: NestedFlavor, existing: String?) throws -> String {
        let entries = contract.events.map { event -> (String, [String]) in
            var body: [(String, String)] = [
                ("type", literal("command")),
                ("command", literal(hookCommand(agent: agent, event: event.name))),
            ]
            if let cap = flavor.synchronous[event.name] {
                // The vendor always runs it synchronously, caps its timeout,
                // and warns when either is asked otherwise.
                body.append(("timeout", String(min(hookTimeoutSeconds, cap))))
            } else {
                body.append(("timeout", String(hookTimeoutSeconds)))
                // Async: the vendor runs it in the background and ignores any
                // decision it could return.
                if flavor.async { body.append(("async", "true")) }
            }
            var entry: [(String, String)] = []
            if let matcher = event.matcher { entry.append(("matcher", literal(matcher))) }
            entry.append(("hooks", "[" + JSONSplice.inlineObject(body) + "]"))
            return (event.name, [JSONSplice.inlineObject(entry)])
        }
        return try splice(existing, agent: agent, pulse: entries, version: false, dropEmptyHooks: false)
    }

    /// `{"version": 1, "hooks": {event: [{<key>: …}]}}` (Cursor).
    package static func renderVersioned(_ agent: AgentID, _ contract: HookContract, existing: String?, key: String) throws -> String {
        let entries = contract.events.map { event in
            (event.name, [JSONSplice.inlineObject([(key, literal(hookCommand(agent: agent, event: event.name)))])])
        }
        return try splice(existing, agent: agent, pulse: entries, version: true, dropEmptyHooks: false)
    }

    /// A file Pulse owns whole: a JSON hook file (Copilot's) or a module
    /// (the OpenCode plugin, the Pi extension).
    package static func ownedFile(_ agent: AgentID, _ contract: HookContract) -> String {
        switch contract.format {
        case .ownedJSON(let commandKey, let timeoutKey):
            var hooks: [String: Any] = [:]
            for event in contract.events {
                let entry: [String: Any] = [
                    "type": "command",
                    commandKey: hookCommand(agent: agent, event: event.name),
                    timeoutKey: hookTimeoutSeconds,
                ]
                hooks[event.name] = [entry]
            }
            let root: [String: Any] = ["version": 1, "hooks": hooks]
            return (try? serialize(root)) ?? "{}\n"
        case .module(let render):
            return render(launcherURL.path, contract.events.map(\.name))
        case .nested, .versioned:
            return ""
        }
    }

    /// The user's file without Pulse's entries; a `hooks` left empty goes.
    package static func stripNested(_ text: String, path: String) throws -> String? {
        try splice(text, path: path, pulse: [], version: false, dropEmptyHooks: true)
    }

    /// Cursor's file without Pulse's entries (its `hooks` stays, maybe empty).
    package static func stripVersioned(_ text: String, path: String) throws -> String? {
        try splice(text, path: path, pulse: [], version: false, dropEmptyHooks: false)
    }

    private static func splice(
        _ text: String?, agent: AgentID, pulse: [(String, [String])], version: Bool, dropEmptyHooks: Bool
    ) throws -> String {
        try splice(text, path: configURL(for: agent).path, pulse: pulse, version: version, dropEmptyHooks: dropEmptyHooks)
    }

    /// Validate `text` as a JSON object (the refusal keeps the user's file
    /// untouched), then rewrite only its `hooks` member.
    package static func splice(
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
        } catch is JSONSplice.UnexpectedShape {
            throw InstallError.unexpectedShape(path)
        } catch {
            throw InstallError.invalidJSON(path, "not valid JSON")
        }
    }

    /// A string as a JSON literal, slashes unescaped.
    package static func literal(_ text: String) -> String {
        HookModules.literal(text)
    }

    private static func blob(_ entry: [String: Any]) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: entry), encoding: .utf8)) ?? ""
    }

    private static func jsonObject(_ raw: String?, path: String) throws -> [String: Any] {
        guard let raw else { return [:] }
        // A UTF-8 byte-order mark is not JSON; it is kept as it was.
        let text = JSONSplice.splitBOM(raw).body
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        // JSONC (VS Code-style comments) is not JSON: rewriting it would
        // either fail or drop the user's comments.
        if JSONSplice.hasComments(text) { throw InstallError.hasComments(path) }
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
    package struct LedgerEntry: Codable, Equatable {
        /// The file existed before Pulse first wrote it.
        package var existed: Bool
        /// Its exact contents then — nil when Pulse cannot know them (it
        /// already carried a Pulse entry this ledger has no record of).
        package var original: String?
        /// What Pulse wrote last.
        package var written: String
        /// Directories Pulse created for it, outermost first.
        package var createdDirectories: [String]

        /// Uninstall can put the file back exactly.
        package var exact: Bool { !existed || original != nil }
    }

    package static func loadLedger() -> [String: LedgerEntry] {
        guard let data = try? Data(contentsOf: ledgerURL),
              let ledger = try? JSONDecoder().decode([String: LedgerEntry].self, from: data)
        else { return [:] }
        return ledger
    }

    /// The ledger holds the user's own config text: 0600 from the first
    /// byte (`PrivateFile`), never world-readable while it is written.
    package static func saveLedger(_ ledger: [String: LedgerEntry]) throws {
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
    package static func edit(_ url: URL, render: (String?) throws -> String) throws {
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
    package static func revert(_ url: URL, strip: (String) throws -> String?) throws -> Bool {
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

    package static func ensureLauncher() throws {
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
    package static func refreshRunnerPath() {
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

    // MARK: - Files

    /// Write a vendor config in place of the file the user actually has.
    ///
    /// `String.write(atomically:)` replaces the path it is given: a
    /// settings.json symlinked from a dotfiles repo became a plain file, and
    /// its mode reset to the umask. Resolve the link first and carry the
    /// existing mode across.
    package static func writeConfig(_ text: String, to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        let mode = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions]
        try text.write(to: target, atomically: true, encoding: .utf8)
        if let mode {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
        }
    }

    package static func containsPulseMarker(_ text: String) -> Bool {
        text.range(of: pulseMarkerPattern, options: .regularExpression) != nil
    }

    package enum InstallError: LocalizedError {
        case invalidJSON(String, String)
        case notOurs(String)
        case hasComments(String)
        case unexpectedShape(String)

        package var errorDescription: String? {
            switch self {
            case .invalidJSON(let path, let reason):
                return "refusing to rewrite \(path): \(reason). Fix or move the file, then install hooks again."
            case .notOurs(let path):
                return "refusing to replace \(path): it is not Pulse's. Move it, then install hooks again."
            case .hasComments(let path):
                return "refusing to rewrite \(path): it has comments. Remove them, then install hooks again."
            case .unexpectedShape(let path):
                return "refusing to rewrite \(path): its hooks are not an object of arrays. Fix it, then install hooks again."
            }
        }
    }
}
