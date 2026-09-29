import Foundation

/// 22.0 · Lamp — why the menu-bar lamp is this colour, right now.
///
/// Names the rule that fired, up to three sessions that drove it (in the
/// lamp's own order), each with `Explain`'s why (23.0 — one sentence per row,
/// the same one the tray and the detail page say), and what was left out
/// (sessions too old to show). Pure: rows in, sentences out.
struct LampExplanation: Equatable, Sendable {
    enum Rule: String, Equatable, Sendable {
        case blocked, stalled, thinRunning, running, yourTurn, recent, idle, cantRefresh
    }

    struct Driver: Equatable, Sendable {
        var rowKey: String
        var agent: AgentID
        var project: String
        /// `Explain.why` for the row.
        var reason: String
    }

    var rule: Rule
    var drivers: [Driver]
    var staleHidden: Int

    static let maxDrivers = 3

    static func make(
        rows: [AgentRow],
        glance: GlanceKind,
        staleHidden: Int,
        lang: ResolvedLanguage,
        nowMs: Int64,
        stallMinutes: Int = 0
    ) -> LampExplanation {
        let rule: Rule
        let chosen: [AgentRow]
        switch glance {
        case .error:
            rule = .cantRefresh
            chosen = []
        case .waiting:
            rule = .blocked
            chosen = rows.filter(\.isBlocked)
        case .stalled:
            let stalled = rows.filter(\.isStalled)
            if stalled.isEmpty {
                rule = .thinRunning
                chosen = rows.filter { !$0.isBlocked && ($0.isProcessOnly || $0.isThinRunning) }
            } else {
                rule = .stalled
                chosen = stalled
            }
        case .running:
            rule = .running
            chosen = rows.filter { $0.state == .running }
        case .idle:
            let turns = rows.filter(\.isYourTurn)
            if !turns.isEmpty {
                rule = .yourTurn
                chosen = turns
            } else if rows.contains(where: \.isRecent) {
                rule = .recent
                chosen = []
            } else {
                rule = .idle
                chosen = []
            }
        }
        return LampExplanation(
            rule: rule,
            drivers: chosen.prefix(maxDrivers).map { row in
                Driver(
                    rowKey: row.rowKey,
                    agent: row.agent,
                    project: row.shortPlace,
                    reason: Explain.why(row, lang: lang, nowMs: nowMs, stallMinutes: stallMinutes)
                )
            },
            staleHidden: staleHidden
        )
    }

    /// The sentence for the colour, then one line per driver, then what was
    /// left out — at most five lines, for the tooltip and VoiceOver.
    func lines(_ lang: ResolvedLanguage) -> [String] {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        var out: [String] = []
        switch rule {
        case .blocked: out.append(t(.lampRuleBlocked))
        case .stalled: out.append(t(.lampRuleStalled))
        case .thinRunning: out.append(t(.lampRuleThin))
        case .running: out.append(t(.lampRuleRunning))
        case .yourTurn: out.append(t(.lampRuleTurn))
        case .recent: out.append(t(.lampRuleRecent))
        case .idle: out.append(t(.lampRuleIdle))
        case .cantRefresh: out.append(t(.lampRuleCantRefresh))
        }
        for driver in drivers {
            let place = driver.project.isEmpty ? driver.agent.displayName : "\(driver.agent.displayName) · \(driver.project)"
            out.append("\(place) — \(driver.reason)")
        }
        if staleHidden > 0 { out.append(String(format: t(.lampLeftStale), staleHidden)) }
        return out
    }
}
