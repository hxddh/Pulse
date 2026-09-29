import Foundation

/// 19.0 · the self-check's reads. Read-only by construction: it opens the
/// agents' own config files and logs for reading, runs `claude agents
/// --json` once (the same bounded call the scan makes), and reduces all of
/// it to `DoctorModel.Facts` — counts, event names and timestamps. Nothing
/// here writes, and nothing it keeps can identify a session or a project.
///
/// Runs only on the user's click, off the main actor.
enum DoctorProbe {
    /// How many bytes of the newest rollout are looked at for its format.
    static let rolloutHeadBytes = 256 * 1024
    /// Only logs this recent say anything about the Codex installed today.
    static let rolloutWindow: TimeInterval = 7 * 24 * 60 * 60

    struct RespondTally: Sendable {
        var enabled = false
        var written = 0
        var taken = 0
        var expired = 0
    }

    static func gather(home: URL, respond: RespondTally, nowMs: Int64) -> DoctorModel.Facts {
        var facts = DoctorModel.Facts()
        facts.channel = PulseVersion.distributionChannel
        let os = ProcessInfo.processInfo.operatingSystemVersion
        facts.macOS = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        facts.nowMs = nowMs

        // Claude
        let fm = FileManager.default
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        let claudeCLI = ClaudeCLI.executable()
        facts.claudeInstalled = fm.fileExists(atPath: claudeDir.path) || claudeCLI != nil
        for name in ["settings.json", "settings.local.json"] {
            let url = claudeDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let hooks = hookTable(data) else {
                facts.claudeSettingsUnreadable = true
                continue
            }
            let found = pulseEvents(hooks)
            facts.claudeHookEvents.formUnion(found.events)
            if let matcher = found.notificationMatcher { facts.claudeNotificationMatcher = matcher }
        }
        if !facts.claudeHookEvents.isEmpty { facts.claudeSettingsUnreadable = false }
        facts.claudeAgents = agentsAnswer(executable: claudeCLI)

        // Codex
        let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        facts.codexInstalled = fm.fileExists(atPath: codexDir.path)
        if let data = try? Data(contentsOf: codexDir.appendingPathComponent("hooks.json")),
           let hooks = hookTable(data) {
            let found = pulseEvents(hooks)
            facts.codexHookEvents = found.events
            facts.codexPermissionHook = found.events.contains("PermissionRequest")
        }
        if let config = try? String(contentsOf: codexDir.appendingPathComponent("config.toml"), encoding: .utf8) {
            facts.codexNotifyInstalled = config.split(separator: "\n").contains { line in
                line.trimmingCharacters(in: .whitespaces).hasPrefix("notify")
                    && HooksInstaller.containsPulseMarker(String(line))
            }
        }
        let rollouts = recentRollouts(codexDir.appendingPathComponent("sessions", isDirectory: true), nowMs: nowMs)
        facts.codexCompressedRollouts = rollouts.compressed
        if let newest = rollouts.newest {
            facts.codexRollout = rolloutShape(head(of: newest, bytes: rolloutHeadBytes))
        }

        // What the hooks said, newest per agent.
        for events in AttentionHistoryStore.current.events.values {
            for event in events {
                let agent = ActivityHarvest.mapAgent(event.agent)?.surfaceID.rawValue ?? event.agent
                if (facts.lastFire[agent]?.tsMs ?? 0) < event.tsMs {
                    facts.lastFire[agent] = DoctorModel.HookFire(kind: event.kind, tsMs: event.tsMs)
                }
            }
        }

        facts.respondEnabled = respond.enabled
        facts.respondWritten = respond.written
        facts.respondTaken = respond.taken
        facts.respondExpired = respond.expired
        return facts
    }

    // MARK: - Pure pieces (tested)

    /// The `hooks` table of a Claude- or Codex-shaped hooks file; nil when
    /// the file is not a JSON object (the user's file, never repaired here).
    static func hookTable(_ data: Data) -> [String: Any]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["hooks"] as? [String: Any] ?? [:]
    }

    /// Which events carry a Pulse command, and the matcher on Pulse's
    /// Notification entry.
    static func pulseEvents(_ hooks: [String: Any]) -> (events: Set<String>, notificationMatcher: String?) {
        var events: Set<String> = []
        var matcher: String?
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                let commands = (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
                guard commands.contains(where: HooksInstaller.containsPulseMarker) else { continue }
                events.insert(event)
                if event == "Notification" { matcher = group["matcher"] as? String ?? "" }
            }
        }
        return (events, matcher)
    }

    static func rolloutShape(_ text: String) -> DoctorModel.RolloutShape {
        var legacy = false
        var paginated = false
        var any = false
        for line in text.split(separator: "\n") where line.contains("\"event_msg\"") {
            any = true
            if line.contains("\"item_completed\"") { paginated = true }
            if line.contains("\"user_message\"") || line.contains("\"agent_message\"") { legacy = true }
        }
        switch (legacy, paginated) {
        case (true, true): return .mixed
        case (true, false): return .legacy
        case (false, true): return .paginated
        case (false, false): return any || !text.isEmpty ? .unknown : .none
        }
    }

    static func agentsAnswer(executable: String?) -> DoctorModel.AgentsAnswer {
        guard let executable else { return .noCLI }
        guard let result = ProcessIO.run(
            executable: executable,
            arguments: ["agents", "--json"],
            timeout: ClaudeAgentsProbe.timeoutSeconds,
            outputLimit: ClaudeAgentsProbe.outputLimit
        ) else { return .failed(exitStatus: -1, timedOut: false) }
        guard result.status == 0, !result.timedOut else {
            return .failed(exitStatus: result.status, timedOut: result.timedOut)
        }
        guard let agents = ClaudeAgentsProbe.parse(result.stdout) else {
            return .unreadable(bytes: result.stdout.count)
        }
        let waiting = agents.filter { ClaudeAgentsProbe.kind(status: $0.status, waitingFor: $0.waitingFor) != nil }.count
        return .parsed(sessions: agents.count, waiting: waiting)
    }

    // MARK: - Files

    private static func recentRollouts(_ root: URL, nowMs: Int64) -> (newest: URL?, compressed: Int) {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return (nil, 0) }
        let horizon = Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000 - rolloutWindow)
        var newest: (URL, Date)?
        var compressed = 0
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited > 20_000 { break }
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-") else { continue }
            if name.hasSuffix(".zst") { compressed += 1; continue }
            guard url.pathExtension == "jsonl",
                  let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  date >= horizon
            else { continue }
            if newest == nil || date > newest!.1 { newest = (url, date) }
        }
        return (newest?.0, compressed)
    }

    private static func head(of url: URL, bytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: bytes)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
