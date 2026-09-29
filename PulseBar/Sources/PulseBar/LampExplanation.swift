import Foundation

/// 22.0 · Lamp — why the menu-bar lamp is this colour, right now, in one
/// sentence.
///
/// 23.0 cut it to the rule alone: the tooltip used to append up to three
/// sessions and what was left out, a five-line dump that repeated the tray.
/// The sentence names the rule; the tray names the sessions. Pure: rows in,
/// a rule out.
struct LampExplanation: Equatable, Sendable {
    enum Rule: String, Equatable, Sendable {
        case blocked, stalled, running, processOnly, yourTurn, recent, idle
    }

    var rule: Rule

    static func make(rows: [AgentRow], glance: GlanceKind) -> LampExplanation {
        LampExplanation(rule: rule(rows: rows, glance: glance))
    }

    /// The rule that set the lamp. A grey lamp says the most useful thing
    /// that is true: a finished turn, then a live process Pulse can only see
    /// from outside, then recent sessions.
    static func rule(rows: [AgentRow], glance: GlanceKind) -> Rule {
        switch glance {
        case .waiting: return .blocked
        case .stalled: return .stalled
        case .running: return .running
        case .idle:
            if rows.contains(where: \.isYourTurn) { return .yourTurn }
            if rows.contains(where: \.isProcessOnly) { return .processOnly }
            if rows.contains(where: \.isRecent) { return .recent }
            return .idle
        }
    }

    /// The one line the tooltip and VoiceOver say.
    func sentence(_ lang: ResolvedLanguage) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        switch rule {
        case .blocked: return t(.lampRuleBlocked)
        case .stalled: return t(.lampRuleStalled)
        case .running: return t(.lampRuleRunning)
        case .processOnly: return t(.lampRuleProcessOnly)
        case .yourTurn: return t(.lampRuleTurn)
        case .recent: return t(.lampRuleRecent)
        case .idle: return t(.lampRuleIdle)
        }
    }
}
