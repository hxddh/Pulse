import Foundation

/// User settings as a value, saved as `settings.json` (0600, `PrivateFile`).
///
/// A `Codable` struct; an old flat `settings.txt` is carried nothing over
/// from: found at load, it is deleted and the defaults apply. Only settings a person can reach from the
/// UI (or that Pulse genuinely needs) are kept. Decoding is tolerant — a
/// missing key is its default, an unknown enum value is its default, and an
/// unknown agent in the mute list is dropped — so one bad field never costs
/// the rest of the file.
struct PulseSettings: Equatable, Codable, Sendable {
    var launchAtLogin = false
    var language: AppLanguage = .auto
    /// The global shortcut that opens the tray, recorded in Settings: a key
    /// code and a Carbon modifier mask (`globalShortcut` on disk). Opt-in:
    /// nil until the person records one. The old `hotkey` preset names are
    /// read once as their keys (`Hotkey.legacy`) and never written again.
    var hotkey: Hotkey?
    var notifyOnWaiting = true
    /// Muted agents still appear in the tray; they just stop notifying.
    var mutedAgents: Set<AgentID> = []
    /// Terminal/iTerm tab Focus uses Apple Events. Default off — enabling may
    /// prompt Automation TCC on the first Focus click, never during a scan.
    /// A Settings toggle (General); a Go that lands on the app only for want
    /// of it says where that toggle is (`RowNotice.appOnly`), and the report
    /// says which way it is.
    var allowTerminalAutomation = false
    var updateCheckEnabled = true
    /// Set when the user uninstalls the hooks: the tray stops suggesting
    /// them. Installing again clears it.
    var hooksNudgeOff = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case launchAtLogin, language, globalShortcut, notifyOnWaiting, mutedAgents
        /// The retired preset name ("ctrl_opt_space", "cmd_opt_p"): read,
        /// migrated to `globalShortcut`, never written.
        case hotkey
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
        if c.contains(.globalShortcut) {
            hotkey = try? c.decodeIfPresent(Hotkey.self, forKey: .globalShortcut)
        } else {
            hotkey = string(.hotkey).flatMap(Hotkey.legacy) ?? d.hotkey
        }
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
        try c.encodeIfPresent(hotkey, forKey: .globalShortcut)
        try c.encode(notifyOnWaiting, forKey: .notifyOnWaiting)
        try c.encode(mutedAgents.map(\.rawValue).sorted(), forKey: .mutedAgents)
        try c.encode(allowTerminalAutomation, forKey: .allowTerminalAutomation)
        try c.encode(updateCheckEnabled, forKey: .updateCheckEnabled)
        try c.encode(hooksNudgeOff, forKey: .hooksNudgeOff)
    }

    /// One-line summary for the debug log.
    var debugDescription: String {
        "notifyWait=\(notifyOnWaiting) lang=\(language.rawValue) login=\(launchAtLogin) "
            + "hotkey=\(hotkey?.label ?? "off") terminalAutomation=\(allowTerminalAutomation) "
            + "muted=\(mutedAgents.count) updates=\(updateCheckEnabled) "
            + "hooksNudgeOff=\(hooksNudgeOff)"
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

    /// The old flat file. Deleted at load, never read.
    static func retiredFileURL(home: URL? = nil) -> URL {
        directory(home: home).appendingPathComponent("settings.txt")
    }

    /// The saved settings, or the defaults when there is no readable file.
    /// An old `settings.txt` is removed, unread.
    static func load(home: URL? = nil) -> PulseSettings {
        loadIfPresent(home: home) ?? PulseSettings()
    }

    /// The saved settings, or nil when there is no readable `settings.json`.
    /// An old `settings.txt` is removed, unread.
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
