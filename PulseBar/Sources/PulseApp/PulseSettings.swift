import Foundation

/// User settings as a value, saved as `settings.json` (0600, `PrivateFile`).
///
/// 23.0 replaced the flat `key=value` `settings.txt` with this `Codable`
/// struct and carries nothing over: a `settings.txt` found at load is
/// deleted and the defaults apply. Only settings a person can reach from the
/// UI (or that Pulse genuinely needs) are kept. Decoding is tolerant — a
/// missing key is its default, an unknown enum value is its default, and an
/// unknown agent in the mute list is dropped — so one bad field never costs
/// the rest of the file.
struct PulseSettings: Equatable, Codable, Sendable {
    var launchAtLogin = false
    var language: AppLanguage = .auto
    /// Carbon global-hotkey registration can trigger an Apple Events privacy
    /// request on unsigned builds, so it stays opt-in: `.off` until chosen.
    var hotkey: HotkeyChoice = .off
    var notifyOnWaiting = true
    /// Muted agents still appear in the tray; they just stop notifying.
    var mutedAgents: Set<AgentID> = []
    /// Terminal/iTerm tab Focus uses Apple Events. Default off — enabling may
    /// prompt Automation TCC on the first Focus click, never during a scan.
    var allowTerminalAutomation = false
    var updateCheckEnabled = true
    /// Set when the user uninstalls the hooks: the tray stops suggesting
    /// them. Installing again clears it.
    var hooksNudgeOff = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case launchAtLogin, language, hotkey, notifyOnWaiting, mutedAgents
        case allowTerminalAutomation, updateCheckEnabled, hooksNudgeOff
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PulseSettings()
        func bool(_ key: CodingKeys, _ fallback: Bool) -> Bool {
            (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? fallback
        }
        func string(_ key: CodingKeys) -> String? {
            try? c.decodeIfPresent(String.self, forKey: key)
        }
        launchAtLogin = bool(.launchAtLogin, d.launchAtLogin)
        language = string(.language).flatMap(AppLanguage.init(rawValue:)) ?? d.language
        hotkey = string(.hotkey).flatMap(HotkeyChoice.init(rawValue:)) ?? d.hotkey
        notifyOnWaiting = bool(.notifyOnWaiting, d.notifyOnWaiting)
        let muted = (try? c.decodeIfPresent([String].self, forKey: .mutedAgents)) ?? []
        mutedAgents = Set(muted.compactMap(AgentID.init(rawValue:)))
        allowTerminalAutomation = bool(.allowTerminalAutomation, d.allowTerminalAutomation)
        updateCheckEnabled = bool(.updateCheckEnabled, d.updateCheckEnabled)
        hooksNudgeOff = bool(.hooksNudgeOff, d.hooksNudgeOff)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(language.rawValue, forKey: .language)
        try c.encode(hotkey.rawValue, forKey: .hotkey)
        try c.encode(notifyOnWaiting, forKey: .notifyOnWaiting)
        try c.encode(mutedAgents.map(\.rawValue).sorted(), forKey: .mutedAgents)
        try c.encode(allowTerminalAutomation, forKey: .allowTerminalAutomation)
        try c.encode(updateCheckEnabled, forKey: .updateCheckEnabled)
        try c.encode(hooksNudgeOff, forKey: .hooksNudgeOff)
    }

    /// One-line summary for the debug log.
    var debugDescription: String {
        "notifyWait=\(notifyOnWaiting) lang=\(language.rawValue) login=\(launchAtLogin) "
            + "hotkey=\(hotkey.rawValue) terminalAutomation=\(allowTerminalAutomation) "
            + "muted=\(mutedAgents.count) updates=\(updateCheckEnabled) "
            + "hooksNudgeOff=\(hooksNudgeOff)"
    }

    // MARK: - On disk

    static let readLimit = 64 * 1024

    /// Where `settings.json` lives: next to `attention.tsv`, so `PULSE_HOME`
    /// moves both. A `home` (tests) names a home directory instead.
    static func directory(home: URL? = nil) -> URL {
        guard let home else { return AttentionIO.path.deletingLastPathComponent() }
        return home.appendingPathComponent("Library/Application Support/Pulse", isDirectory: true)
    }

    /// Where `settings.json` is.
    static func fileURL(home: URL? = nil) -> URL {
        directory(home: home).appendingPathComponent("settings.json")
    }

    /// The pre-23.0 file. Deleted at load, never read.
    static func retiredFileURL(home: URL? = nil) -> URL {
        directory(home: home).appendingPathComponent("settings.txt")
    }

    /// The saved settings, or the defaults when there is no readable file.
    /// A `settings.txt` from before 23.0 is removed, unread.
    static func load(home: URL? = nil) -> PulseSettings {
        loadIfPresent(home: home) ?? PulseSettings()
    }

    /// The saved settings, or nil when there is no readable `settings.json`.
    /// A `settings.txt` from before 23.0 is removed, unread.
    static func loadIfPresent(home: URL? = nil) -> PulseSettings? {
        let retired = retiredFileURL(home: home)
        if FileManager.default.fileExists(atPath: retired.path) {
            try? FileManager.default.removeItem(at: retired)
        }
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
