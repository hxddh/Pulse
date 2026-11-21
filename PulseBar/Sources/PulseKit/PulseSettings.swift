import Foundation

/// Notification banner sound preference.
package enum NotificationSound: String, CaseIterable, Sendable, Codable {
    case `default`
    case silent
}

/// How much text sits beside the menu-bar lamp.
package enum MenuBarStyle: String, CaseIterable, Sendable, Codable {
    /// Default: icon alone unless blocked (then `2 · 4m`).
    case minimal
    /// Icon alone always — ideal for crowded MacBook notches.
    case compact
    /// Shows compact active/done counts even when nothing is blocked.
    case counts
}

/// User settings as a value, saved as `settings.json` (0600, `PrivateFile`).
///
/// Whether Pulse opens at login, whether the person removed the hooks on
/// purpose, whether the global shortcuts are on, and notification preferences.
/// Decoding is tolerant — a missing or mistyped key is its default, an unknown
/// key is ignored — so one bad field never costs the rest of the file.
package struct PulseSettings: Equatable, Codable, Sendable {
    package var launchAtLogin = false
    /// Set when the user removes the hooks: the tray stops suggesting
    /// them. Installing again clears it.
    package var hooksNudgeOff = false
    /// The global shortcut (⌃⌥⌘P) opens the tray on the oldest wait.
    package var globalShortcut = true
    /// Optional second global shortcut (⌃⌥⌘↩) jumps straight to the oldest
    /// blocked terminal without opening the tray.
    package var directJumpShortcut = false
    /// Agents whose "needs you" banners are not posted. The lamp, the tray
    /// and the count still say it: muting is about interruptions only.
    package var mutedAgents: [AgentID] = []
    /// Agents whose finished turns automatically post a quiet "Done" banner
    /// (opt-in; ideal for Codex/Cursor which do not report waits).
    package var notifyDoneAgents: [AgentID] = []
    /// Automatically post a "Done" banner when any non-muted turn lasting at
    /// least this many seconds finishes (0 = off).
    package var notifyLongTurnSeconds = 0
    /// Whether Pulse banners play the system notification sound.
    package var notificationSound: NotificationSound = .default
    /// Epoch ms until which all notification banners are snoozed (0 = off).
    /// The menu-bar lamp still lights red honestly.
    package var quietUntilMs: Int64 = 0
    /// The chord the global shortcut uses.
    package var shortcut: ShortcutChoice = .default
    /// The tray groups its rows by project.
    package var groupByProject = false
    /// Menu bar label density beside the lamp.
    package var menuBarStyle: MenuBarStyle = .minimal

    package init() {}

    private enum CodingKeys: String, CodingKey {
        case launchAtLogin, hooksNudgeOff, globalShortcut, directJumpShortcut
        case mutedAgents, notifyDoneAgents, notifyLongTurnSeconds, notificationSound
        case quietUntilMs, shortcut, groupByProject, menuBarStyle
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? false
        hooksNudgeOff = (try? c.decodeIfPresent(Bool.self, forKey: .hooksNudgeOff)) ?? false
        globalShortcut = (try? c.decodeIfPresent(Bool.self, forKey: .globalShortcut)) ?? true
        directJumpShortcut = (try? c.decodeIfPresent(Bool.self, forKey: .directJumpShortcut)) ?? false
        let muted = (try? c.decodeIfPresent([String].self, forKey: .mutedAgents)) ?? []
        mutedAgents = muted.compactMap(AgentID.init(rawValue:))
        let doneAgents = (try? c.decodeIfPresent([String].self, forKey: .notifyDoneAgents)) ?? []
        notifyDoneAgents = doneAgents.compactMap(AgentID.init(rawValue:))
        let longSeconds = (try? c.decodeIfPresent(Int.self, forKey: .notifyLongTurnSeconds)) ?? 0
        notifyLongTurnSeconds = max(0, longSeconds)
        let soundRaw = (try? c.decodeIfPresent(String.self, forKey: .notificationSound)) ?? nil
        notificationSound = soundRaw.flatMap(NotificationSound.init(rawValue:)) ?? .default
        let quiet = (try? c.decodeIfPresent(Int64.self, forKey: .quietUntilMs)) ?? 0
        quietUntilMs = max(0, quiet)
        let chord = (try? c.decodeIfPresent(String.self, forKey: .shortcut)) ?? nil
        shortcut = chord.flatMap(ShortcutChoice.init(rawValue:)) ?? .default
        groupByProject = (try? c.decodeIfPresent(Bool.self, forKey: .groupByProject)) ?? false
        let barRaw = (try? c.decodeIfPresent(String.self, forKey: .menuBarStyle)) ?? nil
        menuBarStyle = barRaw.flatMap(MenuBarStyle.init(rawValue:)) ?? .minimal
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(hooksNudgeOff, forKey: .hooksNudgeOff)
        try c.encode(globalShortcut, forKey: .globalShortcut)
        try c.encode(directJumpShortcut, forKey: .directJumpShortcut)
        try c.encode(mutedAgents.map(\.rawValue), forKey: .mutedAgents)
        try c.encode(notifyDoneAgents.map(\.rawValue), forKey: .notifyDoneAgents)
        try c.encode(notifyLongTurnSeconds, forKey: .notifyLongTurnSeconds)
        try c.encode(notificationSound.rawValue, forKey: .notificationSound)
        try c.encode(quietUntilMs, forKey: .quietUntilMs)
        try c.encode(shortcut.rawValue, forKey: .shortcut)
        try c.encode(groupByProject, forKey: .groupByProject)
        try c.encode(menuBarStyle.rawValue, forKey: .menuBarStyle)
    }

    /// Whether banners are temporarily snoozed at `nowMs`.
    package func isQuiet(at nowMs: Int64) -> Bool {
        quietUntilMs > nowMs
    }

    /// Remaining quiet duration label at `nowMs`, or nil when not snoozed.
    package func quietRemaining(at nowMs: Int64, lang: ResolvedLanguage) -> String? {
        guard quietUntilMs > nowMs else { return nil }
        let seconds = max(60, Double(quietUntilMs - nowMs) / 1000.0)
        return L10n.duration(seconds, lang)
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

    /// Whether `agent`'s finished turns automatically post a "Done" banner.
    package func notifiesDone(_ agent: AgentID) -> Bool { notifyDoneAgents.contains(agent) }

    /// The settings with `agent`'s turn-done banner on or off, in roster order.
    package func notifyingDone(_ agent: AgentID, _ enabled: Bool) -> PulseSettings {
        var next = self
        var set = Set(notifyDoneAgents)
        if enabled { set.insert(agent) } else { set.remove(agent) }
        next.notifyDoneAgents = AgentID.allCases.filter(set.contains)
        return next
    }

    /// Supported long-turn thresholds (seconds; 0 = off).
    package static let longTurnOptions = [0, 120, 300, 600]

    /// One-line summary for the debug log.
    package var debugDescription: String {
        "login=\(launchAtLogin) hooksNudgeOff=\(hooksNudgeOff) shortcut=\(globalShortcut ? shortcut.display : "off") directJump=\(directJumpShortcut) group=\(groupByProject) bar=\(menuBarStyle.rawValue) sound=\(notificationSound.rawValue) quiet=\(quietUntilMs) longTurn=\(notifyLongTurnSeconds)s muted=\(mutedAgents.map(\.rawValue)) done=\(notifyDoneAgents.map(\.rawValue))"
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
