import Foundation

/// 19.0 · the self-check's reads. Read-only by construction: it opens the
/// agents' own hook configurations for reading and reduces them, with the
/// newest hook event per agent the engine has seen, to `DoctorModel.Facts`
/// — event names and timestamps. Nothing here writes, and nothing it keeps
/// can identify a session or a project.
///
/// Runs only on the user's click, off the main actor.
enum DoctorProbe {
    /// `lastFire`: the newest hook event per agent — `ScanEngine`'s record of
    /// every attention line and activity event since launch (the attention
    /// file keeps only 80 lines; the activity spool a day).
    static func gather(home: URL, nowMs: Int64, lastFire: [AgentID: DoctorModel.HookFire]) -> DoctorModel.Facts {
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
        // What the hooks said, newest per agent.
        for (agent, fire) in lastFire {
            facts.lastFire[agent.rawValue] = fire
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
}
