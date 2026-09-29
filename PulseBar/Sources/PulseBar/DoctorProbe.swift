import Foundation

/// 19.0 · the self-check's reads. Read-only by construction: it opens the
/// agents' own hook configurations for reading and reduces them, with the
/// attention file's newest line per agent, to `DoctorModel.Facts` — event
/// names and timestamps. Nothing here writes, and nothing it keeps can
/// identify a session or a project.
///
/// Runs only on the user's click, off the main actor.
enum DoctorProbe {
    static func gather(home: URL, nowMs: Int64) -> DoctorModel.Facts {
        var facts = DoctorModel.Facts()
        facts.channel = PulseVersion.distributionChannel
        let os = ProcessInfo.processInfo.operatingSystemVersion
        facts.macOS = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        facts.nowMs = nowMs

        // 24.0: every agent's hook, by its own contract.
        for agent in AgentID.priority {
            facts.hooks[agent.rawValue] = hookFacts(agent, home: home)
        }

        // Codex: its legacy notify line.
        let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        if let config = try? String(contentsOf: codexDir.appendingPathComponent("config.toml"), encoding: .utf8) {
            facts.codexNotifyInstalled = config.split(separator: "\n").contains { line in
                line.trimmingCharacters(in: .whitespaces).hasPrefix("notify")
                    && HooksInstaller.containsPulseMarker(String(line))
            }
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
}
