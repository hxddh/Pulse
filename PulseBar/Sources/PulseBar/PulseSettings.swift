import Foundation

/// User settings as a value, plus the flat `key=value` format they persist in.
///
/// Split out of `StatusStore` so the parts that can silently lose a user's
/// configuration — the parser and the serializer — are testable without
/// touching `~/Library/Application Support`. 23.0 dropped every migration
/// from older versions: an unknown key is ignored, a missing one is default.
struct PulseSettings: Equatable {
    var notifyOnIdle = true
    var notifyOnWaiting = true
    var launchAtLogin = false
    var language: AppLanguage = .auto
    var updateCheckEnabled = true
    /// Deep app-data reads are protected by macOS TCC. Keep them opt-in so a
    /// new ad-hoc build never interrupts the tray with a cross-app prompt.
    var allowAppData = false
    /// Per-agent scope for the deep scan. An empty set means no protected
    /// source is enabled; `allowAppData` is the explicit "all" switch.
    var appDataAgents: Set<AgentID> = []
    /// Carbon global-hotkey registration can trigger an Apple Events privacy
    /// request on unsigned builds, so it stays opt-in: `.off` until chosen.
    /// 21.0: one control. The shortcut was a picker disabled until a toggle
    /// below it was switched on — two controls for one bit, in the wrong
    /// order. `.off` is the picker's own first choice now.
    var hotkey: HotkeyChoice = .off
    /// Terminal/iTerm tab Focus uses Apple Events. Default off — enabling may
    /// prompt Automation TCC on the first Focus click, never during a scan.
    var allowTerminalAutomation = false
    /// Muted agents still appear in the tray; they just stop notifying.
    var mutedAgents: Set<AgentID> = []
    /// Set when the user uninstalls the hooks: the tray stops suggesting
    /// them. Installing again clears it.
    var hooksNudgeOff = false

    /// Tolerant on purpose: a settings file is not a contract, and a stray line
    /// must never cost the user the rest of their configuration.
    static func parse(_ text: String) -> PulseSettings {
        var s = PulseSettings()
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let raw = parts[1]
            let on = !(raw == "0" || raw == "false")

            switch key {
            case "notify": s.notifyOnIdle = on
            case "notifyWaiting": s.notifyOnWaiting = on
            case "login": s.launchAtLogin = on
            case "updates": s.updateCheckEnabled = on
            case "appData": s.allowAppData = on
            case "appDataAgents":
                s.appDataAgents = Set(raw.split(separator: ",").compactMap { AgentID(rawValue: String($0)) })
            case "hotkey": s.hotkey = HotkeyChoice(rawValue: raw) ?? .off
            case "terminalAutomation": s.allowTerminalAutomation = on
            case "mute":
                s.mutedAgents = Set(raw.split(separator: ",").compactMap { AgentID(rawValue: String($0)) })
            case "lang": s.language = AppLanguage(rawValue: raw) ?? .auto
            case "hooksNudgeOff": s.hooksNudgeOff = on
            default: break
            }
        }

        return s
    }

    func serialized() -> String {
        let muted = mutedAgents.map(\.rawValue).sorted().joined(separator: ",")
        let appData = appDataAgents.map(\.rawValue).sorted().joined(separator: ",")
        return """
            notify=\(notifyOnIdle ? 1 : 0)
            notifyWaiting=\(notifyOnWaiting ? 1 : 0)
            lang=\(language.rawValue)
            login=\(launchAtLogin ? 1 : 0)
            updates=\(updateCheckEnabled ? 1 : 0)
            appData=\(allowAppData ? 1 : 0)
            appDataAgents=\(appData)
            hotkey=\(hotkey.rawValue)
            terminalAutomation=\(allowTerminalAutomation ? 1 : 0)
            hooksNudgeOff=\(hooksNudgeOff ? 1 : 0)
            mute=\(muted)
            """
    }

    /// One-line summary for the debug log.
    var debugDescription: String {
        "notifyIdle=\(notifyOnIdle) notifyWait=\(notifyOnWaiting) "
            + "lang=\(language.rawValue) login=\(launchAtLogin) "
            + "hotkey=\(hotkey.rawValue) "
            + "terminalAutomation=\(allowTerminalAutomation) "
            + "muted=\(mutedAgents.count) updates=\(updateCheckEnabled) "
            + "appData=\(allowAppData) "
            + "appDataAgents=\(appDataAgents.count) "
            + "hooksNudgeOff=\(hooksNudgeOff)"
    }

    /// Shared on-disk path so the menu-bar store and `--harvest-test` CLI read
    /// the same privacy grants.
    static func settingsFileURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appendingPathComponent("Library/Application Support/Pulse/settings.txt")
    }

    /// Load the user settings file, or defaults when missing/unreadable.
    static func loadFromDisk(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> PulseSettings {
        let url = settingsFileURL(home: home)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return PulseSettings()
        }
        return parse(text)
    }
}
