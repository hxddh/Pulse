import Foundation

/// User settings as a value, saved as `settings.json` (0600, `PrivateFile`).
///
/// Two settings: whether Pulse opens at login, and whether the person
/// removed the hooks on purpose. Decoding is tolerant — a missing or
/// mistyped key is its default, an unknown key is ignored — so one bad field
/// never costs the rest of the file.
struct PulseSettings: Equatable, Codable, Sendable {
    var launchAtLogin = false
    /// Set when the user removes the hooks: the tray stops suggesting
    /// them. Installing again clears it.
    var hooksNudgeOff = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case launchAtLogin, hooksNudgeOff
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? false
        hooksNudgeOff = (try? c.decodeIfPresent(Bool.self, forKey: .hooksNudgeOff)) ?? false
    }

    /// One-line summary for the debug log.
    var debugDescription: String {
        "login=\(launchAtLogin) hooksNudgeOff=\(hooksNudgeOff)"
    }

    // MARK: - On disk

    static let readLimit = 64 * 1024

    /// Where `settings.json` lives: next to `events.tsv`, so `PULSE_HOME`
    /// moves both. A `home` (tests) names a home directory instead.
    static func directory(home: URL? = nil) -> URL {
        guard let home else { return EventLog.directory }
        return home.appendingPathComponent("Library/Application Support/Pulse", isDirectory: true)
    }

    /// Where `settings.json` is.
    static func fileURL(home: URL? = nil) -> URL {
        directory(home: home).appendingPathComponent("settings.json")
    }

    /// The saved settings, or the defaults when there is no readable file.
    static func load(home: URL? = nil) -> PulseSettings {
        loadIfPresent(home: home) ?? PulseSettings()
    }

    /// The saved settings, or nil when there is no readable `settings.json`.
    static func loadIfPresent(home: URL? = nil) -> PulseSettings? {
        guard let data = SafeRead.regularFile(atPath: fileURL(home: home).path, limit: readLimit) else {
            return nil
        }
        return try? JSONDecoder().decode(PulseSettings.self, from: data)
    }

    @discardableResult
    func save(home: URL? = nil) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(self) else { return false }
        return PrivateFile.write(data, to: Self.fileURL(home: home))
    }
}
