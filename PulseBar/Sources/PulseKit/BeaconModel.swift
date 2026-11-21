import Foundation

/// Pure value model for the optional Floating Waiting Beacon HUD.
///
/// The beacon is completely invisible (`make` returns `nil`) whenever no agent
/// is blocked. The moment any agent needs user attention — even in Full Screen
/// IDE spaces or on a secondary display where the menu bar is hidden — it
/// surfaces one compact, non-activating pill naming the oldest wait. Pure.
package struct BeaconModel: Equatable, Sendable {
    package enum Action: Equatable, Sendable {
        /// Jump straight to the oldest blocked terminal (or cycle to the next wait).
        case jump
        /// Open the main Pulse tray popover.
        case openTray
        /// Ignore the primary wait shown in the beacon.
        case ignorePrimary
        /// Snooze notification banners for `minutes`.
        case quiet(minutes: Int)
        /// Turn off the floating beacon setting.
        case hideBeacon
    }

    package var lang: ResolvedLanguage
    package var blockedCount: Int
    package var primaryKey: SessionKey
    package var agent: AgentID
    package var project: String
    package var headline: String
    package var waitAge: String
    /// True when the primary wait (or another blocked session) also has a file conflict.
    package var hasConflict: Bool
    /// True while notification banners are snoozed (quiet mode).
    package var quiet: Bool
    package var accessibilityLabel: String

    package static func make(
        rows: [AgentRow],
        lang: ResolvedLanguage,
        nowMs: Int64,
        quiet: Bool = false
    ) -> BeaconModel? {
        let blocked = rows.filter(\.isBlocked)
        guard let primary = blocked.first else { return nil }

        let rawAsk = TrayRowModel.ask(primary)
        let baseHeadline: String
        if let rawAsk, !rawAsk.isEmpty {
            baseHeadline = rawAsk
        } else if let task = primary.usefulTask {
            baseHeadline = task
        } else if let wait = primary.wait {
            baseHeadline = L10n.waitKind(wait.kind, lang)
        } else {
            baseHeadline = L10n.t(.needsYou, lang)
        }

        let headline = TrayRowModel.truncate(baseHeadline, 44)
        let project = TrayRowModel.truncate(primary.project, 18)
        let age: String
        if let since = primary.wait?.sinceMs, since > 0 {
            let seconds = Double(max(0, nowMs - since)) / 1000.0
            age = seconds >= 60 ? L10n.duration(seconds, lang) : ""
        } else {
            age = ""
        }
        let hasConflict = blocked.contains { !$0.conflictingFiles.isEmpty }

        var spoken = [
            blocked.count == 1
                ? "1 \(L10n.t(.waiting1, lang))"
                : "\(blocked.count) \(L10n.t(.waitingN, lang))",
            primary.agent.displayName,
        ]
        if !project.isEmpty { spoken.append(project) }
        spoken.append(headline)
        if !age.isEmpty { spoken.append(age) }

        return BeaconModel(
            lang: lang,
            blockedCount: blocked.count,
            primaryKey: primary.key,
            agent: primary.agent,
            project: project,
            headline: headline,
            waitAge: age,
            hasConflict: hasConflict,
            quiet: quiet,
            accessibilityLabel: spoken.joined(separator: ", ")
        )
    }
}
