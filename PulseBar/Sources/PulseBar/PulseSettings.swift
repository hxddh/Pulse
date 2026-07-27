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
    var hotkey: HotkeyChoice = .commandShiftP
    /// Muted agents still appear in the tray; they just stop notifying.
    var mutedAgents: Set<AgentID> = []
    /// How the tray groups rows. Status is the default because "who needs me"
    /// is the question the product exists to answer; project grouping is for
    /// people running several repos at once.
    var trayGrouping: TrayGrouping = .status
    /// Off by default — an unsolicited sound is a bigger interruption than the
    /// one it is reporting.
    var playSoundOnWaiting = false

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
            case "hotkey": s.hotkey = HotkeyChoice(rawValue: raw) ?? .commandShiftP
            case "mute":
                s.mutedAgents = Set(raw.split(separator: ",").compactMap { AgentID(rawValue: String($0)) })
            case "lang": s.language = AppLanguage(rawValue: raw) ?? .auto
            case "grouping": s.trayGrouping = TrayGrouping(rawValue: raw) ?? .status
            case "waitSound": s.playSoundOnWaiting = on
            default: break
            }
        }

        // Only migrate when the file predates the minute-precision keys.
        if !sawMinuteKeys {
            if let h = legacyStartHour { s.quietStartMinute = h * 60 }
            if let h = legacyEndHour { s.quietEndMinute = h * 60 }
        }
        s.quietStartMinute = clampMinute(s.quietStartMinute)
        s.quietEndMinute = clampMinute(s.quietEndMinute)
        return s
    }

    func serialized() -> String {
        let muted = mutedAgents.map(\.rawValue).sorted().joined(separator: ",")
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
            hotkey=\(hotkey.rawValue)
            grouping=\(trayGrouping.rawValue)
            waitSound=\(playSoundOnWaiting ? 1 : 0)
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
            + "hotkey=\(hotkey.rawValue) muted=\(mutedAgents.count) updates=\(updateCheckEnabled) "
            + "grouping=\(trayGrouping.rawValue) waitSound=\(playSoundOnWaiting)"
    }
}
