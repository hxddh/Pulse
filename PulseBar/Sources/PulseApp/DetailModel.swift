import Foundation

/// One session, in full, as a value — what `SessionDetailFace` draws.
///
/// The row is one line; this is what a person reads after deciding to look,
/// in the order it is worth reading: the headline as the page's title (in
/// its header, once), the ask (and what to do about it), the why (when the
/// row's second line did not already say it), the recent steps, the agent's
/// last message, the last error and the folder — all from the session's own
/// events, in the words the row uses (`TrayRowModel`). Each thing is said
/// once: no headline block under a header that names it, no state-and-age
/// beside "This turn", no start time. How Pulse reads a session is not on
/// the page; it is in Settings → Hooks → "Copy report". Nothing is shown as
/// a placeholder: a fact Pulse does not have is not a row. Tokens, context,
/// cost, model and plan are never shown — a decision.
struct DetailModel: Equatable {
    struct Fact: Equatable {
        var label: String
        var value: String
    }

    /// What the detail page can ask for.
    enum Action: Equatable { case back, focus, dismiss }

    var lang: ResolvedLanguage
    var rowKey: String
    var agent: AgentID
    var lamp: LampFace
    /// `TrayRowModel.headline` — the page's title, in its header.
    var headline: String
    var headlineQuiet: Bool
    /// The full question of a blocked row.
    var ask: String?
    /// `TrayRowModel.why` — nil when it is the row's own second line (a
    /// stalled row's why), which would say the same sentence twice.
    var why: String?
    /// Up to `SessionBook.maxSteps` recent steps, newest first: how long
    /// ago, and "tool · target".
    var steps: [Fact]
    var lastMessage: String?
    var error: String?
    /// This turn's duration (the page's one clock) and the folder.
    var facts: [Fact]
    var canFocus: Bool
    var focusTitle: String
    var canDismiss: Bool
    /// What the last Go did when it did not land exactly (`RowNotice`) —
    /// the same words as the row.
    var notice: RowNotice? = nil

    static func make(
        row: AgentRow,
        lang: ResolvedLanguage,
        nowMs: Int64,
        notice: RowNotice? = nil
    ) -> DetailModel {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        typealias Words = TrayRowModel
        let fresh = row.selfReportFresh(at: nowMs)

        var facts: [Fact] = []
        if row.state == .running || row.isBlocked {
            let turn = Words.turnDuration(row, nowMs: nowMs, lang: lang)
            if !turn.isEmpty { facts.append(Fact(label: t(.stepThisTurn), value: turn)) }
        }
        if !row.displayPath.isEmpty { facts.append(Fact(label: t(.detailFolder), value: row.displayPath)) }

        let steps = row.recentSteps.reversed().map { step in
            Fact(label: Words.minuteAgo(step.ms, nowMs: nowMs, lang: lang), value: Words.stepText(step))
        }
        let lamp = LampFace.row(row)
        let why = Words.why(row, lang: lang, nowMs: nowMs)
        let second = Words.secondLine(row, why: why, lamp: lamp, lang: lang, nowMs: nowMs)

        return DetailModel(
            lang: lang,
            rowKey: row.rowKey,
            agent: row.agent,
            lamp: lamp,
            headline: Words.headline(row, lang: lang, nowMs: nowMs),
            headlineQuiet: row.isProcessOnly,
            ask: Words.ask(row),
            why: second?.text == why ? nil : why,
            steps: steps,
            lastMessage: fresh && !row.lastWord.isEmpty ? row.lastWord : nil,
            error: row.lastErrorText.isEmpty ? nil : row.lastErrorText,
            facts: facts,
            canFocus: row.canFocusTerminal,
            focusTitle: Words.focusTitle(row, lang: lang),
            canDismiss: row.isBlocked,
            notice: notice
        )
    }
}
