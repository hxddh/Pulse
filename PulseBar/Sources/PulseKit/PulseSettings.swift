import Foundation

/// User settings as a value, saved as `settings.json` (0600, `PrivateFile`).
///
/// Whether Pulse opens at login, whether the person removed the hooks on
/// purpose, whether the global shortcut is on, and the agents whose banners
/// are muted. Decoding is tolerant — a missing or mistyped key is its
/// default, an unknown key is ignored — so one bad field never costs the
/// rest of the file.
package struct PulseSettings: Equatable, Codable, Sendable {
    package var launchAtLogin = false
    /// Set when the user removes the hooks: the tray stops suggesting
    /// them. Installing again clears it.
    package var hooksNudgeOff = false
    /// The global shortcut (⌃⌥⌘P) opens the tray on the oldest wait.
    package var globalShortcut = true
    /// Agents whose "needs you" banners are not posted. The lamp, the tray
    /// and the count still say it: muting is about interruptions only.
    package var mutedAgents: [AgentID] = []

    package init() {}

    private enum CodingKeys: String, CodingKey {
        case launchAtLogin, hooksNudgeOff, globalShortcut, mutedAgents
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? false
        hooksNudgeOff = (try? c.decodeIfPresent(Bool.self, forKey: .hooksNudgeOff)) ?? false
        globalShortcut = (try? c.decodeIfPresent(Bool.self, forKey: .globalShortcut)) ?? true
        let muted = (try? c.decodeIfPresent([String].self, forKey: .mutedAgents)) ?? []
        mutedAgents = muted.compactMap(AgentID.init(rawValue:))
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(hooksNudgeOff, forKey: .hooksNudgeOff)
        try c.encode(globalShortcut, forKey: .globalShortcut)
        try c.encode(mutedAgents.map(\.rawValue), forKey: .mutedAgents)
    }

    /// Whether `agent`'s banners are muted.
    package func isMuted(_ agent: AgentID) -> Bool { mutedAgents.contains(agent) }

    /// The settings with `agent` muted or not, in roster order.
    package func muting(_ agent: AgentID, _ muted: Bool) -> PulseSettings {
        var next = self
        var set = Set(mutedAgents)
        if muted { set.insert(agent) } else { set.remove(agent) }
        next.mutedAgents = AgentID.allCases.filter(set.contains)
        return next
    }

    /// One-line summary for the debug log.
    package var debugDescription: String {
        "login=\(launchAtLogin) hooksNudgeOff=\(hooksNudgeOff) shortcut=\(globalShortcut) muted=\(mutedAgents.map(\.rawValue))"
    }

    // MARK: - On disk

    package static let readLimit = 64 * 1024

    /// Where `settings.json` lives: next to `events.tsv`, so `PULSE_HOME`
    /// moves both. A `home` (tests) names a home directory instead.
    package static func directory(home: URL? = nil) -> URL {
        guard let home else { return EventLog.directory }
        return home.appendingPathComponent("Library/Application Support/Pulse", isDirectory: true)
    }

    /// Where `settings.json` is.
    package static func fileURL(home: URL? = nil) -> URL {
        directory(home: home).appendingPathComponent("settings.json")
    }

    /// The saved settings, or the defaults when there is no readable file.
    package static func load(home: URL? = nil) -> PulseSettings {
        loadIfPresent(home: home) ?? PulseSettings()
    }

    /// The saved settings, or nil when there is no readable `settings.json`.
    package static func loadIfPresent(home: URL? = nil) -> PulseSettings? {
        guard let data = SafeRead.regularFile(atPath: fileURL(home: home).path, limit: readLimit) else {
            return nil
        }
        return try? JSONDecoder().decode(PulseSettings.self, from: data)
    }

    @discardableResult
    package func save(home: URL? = nil) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(self) else { return false }
        return PrivateFile.write(data, to: Self.fileURL(home: home))
    }
}
