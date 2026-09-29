import Foundation

/// 23.0 · one session, in full, as a value — what `SessionDetailFace` draws.
///
/// The row is one line; this is what a person reads after deciding to look,
/// in the order it is worth reading: the ask (and what to do about it), the
/// why, the last hour, the agent's last message, the last error, what
/// happened to the banner, and a few plain facts (24.0: the message, model
/// and error come from the session's transcript, read when this opens). How Pulse reads the
/// session is folded away at the bottom. Nothing is shown as a placeholder:
/// a fact Pulse does not have is not a row.
struct DetailModel: Equatable {
    struct Fact: Equatable {
        var label: String
        var value: String
    }

    /// What the detail page can ask for.
    enum Action: Equatable { case back, focus, dismiss, mute }

    var lang: ResolvedLanguage
    var rowKey: String
    var agent: AgentID
    var agentName: String
    /// The short project name; "" when unknown.
    var project: String
    var lamp: LampFace
    /// `Explain.state` — "Needs you", "Running", "Your turn"…
    var state: String
    /// How long a wait has been open, else when the session last moved.
    var age: String
    /// `Explain.headline`.
    var headline: String
    var headlineQuiet: Bool
    /// The full question of a blocked row.
    var ask: String?
    var why: String
    var timeline: TimelineStripModel?
    var lastMessage: String?
    var error: String?
    /// `NotificationAuditModel.lines` for the latest wait; empty when none.
    var notification: [String]
    var facts: [Fact]
    /// How Pulse reads this session — folded away by default.
    var diagnostics: [Fact]
    var canFocus: Bool
    var focusTitle: String
    var canDismiss: Bool
    var muted: Bool

    static func make(
        row: AgentRow,
        lang: ResolvedLanguage,
        nowMs: Int64,
        muted: Bool = false,
        audit: NotificationAuditModel? = nil,
        timeline: TimelineStripModel? = nil
    ) -> DetailModel {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        let explain = Explain.make(row, lang: lang, nowMs: nowMs)
        let fresh = row.selfReportFresh(at: nowMs)

        var facts: [Fact] = []
        let model = row.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { facts.append(Fact(label: t(.detailModel), value: model)) }
        facts.append(Fact(label: t(.detailSource), value: explain.source))
        if !row.displayPath.isEmpty { facts.append(Fact(label: t(.detailFolder), value: row.displayPath)) }
        if row.startedMs > 0, row.startedMs <= nowMs {
            facts.append(Fact(label: t(.detailStarted), value: LogClock.label(ms: row.startedMs, nowMs: nowMs, lang: lang)))
        }

        let error: String? = row.lastErrorText.isEmpty ? nil : row.lastErrorText

        let age = row.isBlocked
            ? Explain.waitDuration(row, nowMs: nowMs, lang: lang)
            : Explain.activityLabel(row, nowMs: nowMs, lang: lang)

        return DetailModel(
            lang: lang,
            rowKey: row.rowKey,
            agent: row.agent,
            agentName: row.agent.displayName,
            project: row.shortPlace,
            lamp: LampFace.row(row),
            state: explain.state,
            age: age,
            headline: explain.headline,
            headlineQuiet: row.isProcessOnly,
            ask: explain.ask,
            why: explain.why,
            timeline: timeline,
            lastMessage: fresh && !row.lastWord.isEmpty ? row.lastWord : nil,
            error: error,
            notification: audit?.lines ?? [],
            facts: facts,
            diagnostics: diagnostics(row, lang: lang, nowMs: nowMs),
            canFocus: row.canFocusTerminal,
            focusTitle: Explain.focusTitle(row, lang: lang),
            canDismiss: row.isBlocked,
            muted: muted
        )
    }

    /// How Pulse reads this session, in words: the session id, how it would
    /// be focused, the process and the last event.
    static func diagnostics(_ row: AgentRow, lang: ResolvedLanguage, nowMs: Int64) -> [Fact] {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        var out: [Fact] = []
        if !row.sessionID.isEmpty { out.append(Fact(label: t(.detailSession), value: row.sessionID)) }
        out.append(Fact(
            label: t(.detailGo),
            value: row.canFocusTerminal ? Explain.focusTitle(row, lang: lang) : t(.detailGoNone)
        ))
        if row.liveProcess, row.pid > 0 {
            out.append(Fact(label: t(.detailProcess), value: "pid \(row.pid)"))
        }
        if row.eventMs > 0, row.eventMs <= nowMs {
            out.append(Fact(label: t(.detailLastChange), value: LogClock.label(ms: row.eventMs, nowMs: nowMs, lang: lang)))
        }
        return out
    }
}
