import Foundation

/// How the tray groups its rows.
enum TrayGrouping: String, CaseIterable, Identifiable {
    case status
    case project

    var id: String { rawValue }

    var labelKey: L10n.Key {
        switch self {
        case .status: return .groupByAgent
        case .project: return .groupByProject
        }
    }
}

/// User settings as a value, plus the flat `key=value` format they persist in.
///
/// Split out of `StatusStore` so the parts that can silently lose a user's
/// configuration — the parser, the serializer, and the 0.22 whole-hours →
/// minutes migration that runs once on every upgrade — are testable without
/// touching `~/Library/Application Support`.
struct PulseSettings: Equatable {
    /// Deep app-data grants are intentionally versioned. A pre-0.48 settings
    /// file may contain `appData=1` from the old all-or-nothing switch; carrying
    /// that grant into the scoped policy can immediately trigger a new TCC
    /// prompt after an ad-hoc update. The user must opt in again under the
    /// current, per-agent policy.
    static let appDataPolicyVersion = 2

    var autoProbe = true
    var notifyOnIdle = true
    var notifyOnWaiting = true
    var quietHoursEnabled = false
    /// Minutes since midnight — whole hours were too coarse for a 22:30 bedtime.
    var quietStartMinute = 22 * 60
    var quietEndMinute = 8 * 60
    var launchAtLogin = false
    var language: AppLanguage = .auto
    var updateCheckEnabled = true
    /// Deep app-data reads are protected by macOS TCC. Keep them opt-in so a
    /// new ad-hoc build never interrupts the tray with a cross-app prompt.
    var allowAppData = false
    /// Per-agent scope for the deep scan. An empty set means no protected
    /// source is enabled; `allowAppData` is the explicit "all" switch.
    var appDataAgents: Set<AgentID> = []
    var hotkey: HotkeyChoice = .commandShiftP
    /// Carbon global-hotkey registration can trigger an Apple Events privacy
    /// request on unsigned builds. Keep it opt-in; choosing a shortcut in the
    /// settings UI enables it explicitly.
    var hotkeyEnabled = false
    /// Terminal/iTerm tab Focus uses Apple Events. Default off — enabling may
    /// prompt Automation TCC on the first Focus click, never during a scan.
    var allowTerminalAutomation = false
    /// Read what has landed in each agent's working copy. On by default: it
    /// runs read-only git plumbing, reads no file contents and writes
    /// nothing, and an evidence axis nobody switches on is worth nothing.
    var measureWorkspaceEffect = true
    /// Muted agents still appear in the tray; they just stop notifying.
    var mutedAgents: Set<AgentID> = []
    /// How the tray groups rows. Status is the default because "who needs me"
    /// is the question the product exists to answer; project grouping is for
    /// people running several repos at once.
    var trayGrouping: TrayGrouping = .status
    /// Off by default — an unsolicited sound is a bigger interruption than the
    /// one it is reporting.
    var playSoundOnWaiting = false
    /// Minutes of silence before a live row is called stalled; 0 turns it off.
    ///
    /// Was a hardcoded twenty. Twenty fits nobody in particular: a long build
    /// is not stalled at twenty minutes, and a short back-and-forth is stuck
    /// well before it.
    var stallMinutes = 20
    /// How long "Later" silences a wait, in minutes.
    var snoozeMinutes = 10

    static let minutesPerDay = 24 * 60

    static func clampMinute(_ m: Int) -> Int {
        min(minutesPerDay - 1, max(0, m))
    }

    /// Tolerant on purpose: a settings file is not a contract, and a stray line
    /// must never cost the user the rest of their configuration.
    static func parse(_ text: String) -> PulseSettings {
        var s = PulseSettings()
        // Pre-0.22 wrote whole hours; keep reading them so nobody loses a window.
        var legacyStartHour: Int?
        var legacyEndHour: Int?
        var sawMinuteKeys = false
        var sawCurrentAppDataPolicy = false

        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let raw = parts[1]
            let on = !(raw == "0" || raw == "false")

            switch key {
            case "auto": s.autoProbe = on
            case "notify": s.notifyOnIdle = on
            case "notifyWaiting": s.notifyOnWaiting = on
            case "quiet": s.quietHoursEnabled = on
            case "quietStart": legacyStartHour = Int(raw)
            case "quietEnd": legacyEndHour = Int(raw)
            case "quietStartMin":
                if let v = Int(raw) { s.quietStartMinute = v; sawMinuteKeys = true }
            case "quietEndMin":
                if let v = Int(raw) { s.quietEndMinute = v; sawMinuteKeys = true }
            case "login": s.launchAtLogin = on
            case "updates": s.updateCheckEnabled = on
            case "appData": s.allowAppData = on
            case "appDataAgents":
                s.appDataAgents = Set(raw.split(separator: ",").compactMap { AgentID(rawValue: String($0)) })
            case "appDataPolicyVersion":
                sawCurrentAppDataPolicy = Int(raw) == Self.appDataPolicyVersion
            case "hotkey": s.hotkey = HotkeyChoice(rawValue: raw) ?? .commandShiftP
            case "hotkeyEnabled": s.hotkeyEnabled = on
            case "terminalAutomation": s.allowTerminalAutomation = on
            case "workspaceEffect": s.measureWorkspaceEffect = on
            case "mute":
                s.mutedAgents = Set(raw.split(separator: ",").compactMap { AgentID(rawValue: String($0)) })
            case "lang": s.language = AppLanguage(rawValue: raw) ?? .auto
            case "grouping": s.trayGrouping = TrayGrouping(rawValue: raw) ?? .status
            case "waitSound": s.playSoundOnWaiting = on
            case "stallMin": if let v = Int(raw) { s.stallMinutes = max(0, min(240, v)) }
            case "snoozeMin": if let v = Int(raw) { s.snoozeMinutes = max(1, min(240, v)) }
            default: break
            }
        }

        // Only migrate when the file predates the minute-precision keys.
        if !sawMinuteKeys {
            if let h = legacyStartHour { s.quietStartMinute = h * 60 }
            if let h = legacyEndHour { s.quietEndMinute = h * 60 }
        }
        if !sawCurrentAppDataPolicy {
            // Do not silently replay an old broad TCC grant. The next explicit
            // toggle writes the scoped policy marker and makes the choice
            // durable without reintroducing a background permission request.
            s.allowAppData = false
            s.appDataAgents.removeAll()
        }
        s.quietStartMinute = clampMinute(s.quietStartMinute)
        s.quietEndMinute = clampMinute(s.quietEndMinute)
        return s
    }

    func serialized() -> String {
        let muted = mutedAgents.map(\.rawValue).sorted().joined(separator: ",")
        let appData = appDataAgents.map(\.rawValue).sorted().joined(separator: ",")
        return """
            auto=\(autoProbe ? 1 : 0)
            notify=\(notifyOnIdle ? 1 : 0)
            notifyWaiting=\(notifyOnWaiting ? 1 : 0)
            quiet=\(quietHoursEnabled ? 1 : 0)
            quietStartMin=\(Self.clampMinute(quietStartMinute))
            quietEndMin=\(Self.clampMinute(quietEndMinute))
            lang=\(language.rawValue)
            login=\(launchAtLogin ? 1 : 0)
            updates=\(updateCheckEnabled ? 1 : 0)
            appData=\(allowAppData ? 1 : 0)
            appDataAgents=\(appData)
            appDataPolicyVersion=\(Self.appDataPolicyVersion)
            hotkey=\(hotkey.rawValue)
            hotkeyEnabled=\(hotkeyEnabled ? 1 : 0)
            terminalAutomation=\(allowTerminalAutomation ? 1 : 0)
            workspaceEffect=\(measureWorkspaceEffect ? 1 : 0)
            grouping=\(trayGrouping.rawValue)
            waitSound=\(playSoundOnWaiting ? 1 : 0)
            stallMin=\(stallMinutes)
            snoozeMin=\(snoozeMinutes)
            mute=\(muted)
            """
    }

    /// Quiet window may wrap midnight (e.g. 22:30 → 08:00). Equal start/end
    /// disables it rather than silencing the whole day.
    func isInQuietHours(now: Date, calendar: Calendar = .current) -> Bool {
        guard quietHoursEnabled else { return false }
        let start = Self.clampMinute(quietStartMinute)
        let end = Self.clampMinute(quietEndMinute)
        if start == end { return false }
        let comps = calendar.dateComponents([.hour, .minute], from: now)
        let minute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        if start < end {
            return minute >= start && minute < end
        }
        return minute >= start || minute < end
    }

    /// One-line summary for the debug log.
    var debugDescription: String {
        "auto=\(autoProbe) notifyIdle=\(notifyOnIdle) notifyWait=\(notifyOnWaiting) "
            + "quiet=\(quietHoursEnabled) \(quietStartMinute)-\(quietEndMinute) "
            + "lang=\(language.rawValue) login=\(launchAtLogin) "
            + "hotkey=\(hotkey.rawValue) hotkeyEnabled=\(hotkeyEnabled) "
            + "terminalAutomation=\(allowTerminalAutomation) workspaceEffect=\(measureWorkspaceEffect) "
            + "muted=\(mutedAgents.count) updates=\(updateCheckEnabled) "
            + "appData=\(allowAppData) "
            + "appDataAgents=\(appDataAgents.count) "
            + "grouping=\(trayGrouping.rawValue) waitSound=\(playSoundOnWaiting) "
            + "stall=\(stallMinutes) snooze=\(snoozeMinutes)"
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
