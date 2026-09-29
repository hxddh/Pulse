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

    static func gather(
        home: URL, coverage: [String: DoctorModel.Coverage] = [:], nowMs: Int64
    ) -> DoctorModel.Facts {
        var facts = DoctorModel.Facts()
        facts.readCoverage = coverage
        facts.channel = PulseVersion.distributionChannel
        let os = ProcessInfo.processInfo.operatingSystemVersion
        facts.macOS = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        facts.nowMs = nowMs

        let fm = FileManager.default
        // 24.0: every agent's hook, by its own contract.
        for agent in AgentID.priority {
            facts.hooks[agent.rawValue] = hookFacts(agent, home: home)
        }
        let claudeCLI = ClaudeCLI.executable()
        facts.claudeInstalled = facts.hooks[AgentID.claude.rawValue]?.present == true || claudeCLI != nil
        facts.claudeAgents = agentsAnswer(executable: claudeCLI)

        // Codex: its legacy notify line and the rollout format.
        let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        facts.codexInstalled = fm.fileExists(atPath: codexDir.path)
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

        // What the hooks said, newest per agent, from the attention file.
        for (agent, event) in AttentionIO.latestEvents() {
            facts.lastFire[agent.rawValue] = DoctorModel.HookFire(kind: event.kind, tsMs: event.tsMs)
        }
        return facts
    }

    /// One agent's hook as installed under `home`: whether the vendor is
    /// there, which contract events carry Pulse's command, and any Pulse
    /// entry on an event Pulse must never use.
    static func hookFacts(_ agent: AgentID, home: URL) -> DoctorModel.AgentHooks {
        var item = DoctorModel.AgentHooks()
        let contract = agent.spec.hooks
        var isDirectory: ObjCBool = false
        item.present = FileManager.default.fileExists(
            atPath: home.appendingPathComponent(contract.home).path, isDirectory: &isDirectory
        ) && isDirectory.boolValue
        guard let text = try? String(contentsOf: home.appendingPathComponent(contract.path), encoding: .utf8) else {
            return item
        }
        guard let found = HooksInstaller.installedEvents(agent, text: text) else {
            item.unreadable = true
            return item
        }
        let wanted = Set(contract.events.map(\.name))
        item.events = found.intersection(wanted)
        item.forbidden = found.intersection(DoctorModel.forbiddenEvents(agent))
        return item
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
