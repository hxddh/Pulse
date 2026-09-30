import Foundation

/// One session, in full, as a value — what `SessionDetailFace` draws.
///
/// The row is one line; this is what a person reads after deciding to look,
/// in the order it is worth reading: the ask (and what to do about it), the
/// why, the recent steps, the agent's last message, the last error and a few
/// plain facts — all from the session's own events, in the words the row
/// uses (`TrayRowModel`). How Pulse reads a session is not on the page; it is
/// in Settings → Hooks → "Copy report". Nothing is shown as a placeholder: a
/// fact Pulse does not have is not a row. Tokens, context, cost, model and
/// plan are never shown — a decision.
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
    /// `TrayRowModel.stateText` — "Needs you", "Running", "Your turn"…
    var state: String
    /// How long a wait has been open, else when the session last moved.
    var age: String
    /// `TrayRowModel.headline`.
    var headline: String
    var headlineQuiet: Bool
    /// The full question of a blocked row.
    var ask: String?
    var why: String
    /// Up to `SessionBook.maxSteps` recent steps, newest first: how long
    /// ago, and "tool · target".
    var steps: [Fact]
    var lastMessage: String?
    var error: String?
    var facts: [Fact]
    var canFocus: Bool
    var focusTitle: String
    var canDismiss: Bool
    var muted: Bool

    static func make(
        row: AgentRow,
        lang: ResolvedLanguage,
        nowMs: Int64,
        muted: Bool = false
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
        if row.startedMs > 0, row.startedMs <= nowMs {
            facts.append(Fact(label: t(.detailStarted), value: LogClock.label(ms: row.startedMs, nowMs: nowMs, lang: lang)))
        }

        let age = row.isBlocked
            ? Words.waitDuration(row, nowMs: nowMs, lang: lang)
            : Words.activityLabel(row, nowMs: nowMs, lang: lang)
        let steps = row.recentSteps.reversed().map { step in
            Fact(label: Words.minuteAgo(step.ms, nowMs: nowMs, lang: lang), value: Words.stepText(step))
        }

        return DetailModel(
            lang: lang,
            rowKey: row.rowKey,
            agent: row.agent,
            agentName: row.agent.displayName,
            project: row.shortPlace,
            lamp: LampFace.row(row),
            state: Words.stateText(row, lang: lang),
            age: age,
            headline: Words.headline(row, lang: lang, nowMs: nowMs),
            headlineQuiet: row.isProcessOnly,
            ask: Words.ask(row),
            why: Words.why(row, lang: lang, nowMs: nowMs),
            steps: steps,
            lastMessage: fresh && !row.lastWord.isEmpty ? row.lastWord : nil,
            error: row.lastErrorText.isEmpty ? nil : row.lastErrorText,
            facts: facts,
            canFocus: row.canFocusTerminal,
            focusTitle: Words.focusTitle(row, lang: lang),
            canDismiss: row.isBlocked,
            muted: muted
        )
    }
}

/// One clock for every moment the detail page names. `HH:mm` alone says
/// nothing about which day: yesterday's 14:02 reads as today's. Today is `HH:mm`,
/// the last week `Mon HH:mm` / `周一 HH:mm`, anything older `M/d HH:mm` —
/// always in the app's language, not the system's.
enum LogClock {
    static func label(ms: Int64, nowMs: Int64, lang: ResolvedLanguage, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let now = Date(timeIntervalSince1970: Double(nowMs) / 1000)
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day ?? 0
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: lang == .zh ? "zh-Hans" : "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        if days == 0 {
            formatter.dateFormat = "HH:mm"
        } else if days > 0, days < 7 {
            formatter.dateFormat = "EEE HH:mm"
        } else {
            formatter.dateFormat = "M/d HH:mm"
        }
        return formatter.string(from: date)
    }
}
