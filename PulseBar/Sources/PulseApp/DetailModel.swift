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
    /// What the last Go did when it did not land exactly (`RowNotice`) —
    /// the same words the row says.
    var notice: String? = nil

    static func make(
        row: AgentRow,
        lang: ResolvedLanguage,
        nowMs: Int64,
        muted: Bool = false,
        notice: String? = nil,
        locale: Locale? = nil,
        timeZone: TimeZone = .current
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
            facts.append(Fact(
                label: t(.detailStarted),
                value: LogClock.label(ms: row.startedMs, nowMs: nowMs, lang: lang, timeZone: timeZone, locale: locale)
            ))
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
            muted: muted,
            notice: notice
        )
    }
}

/// One clock for every moment the detail page names. A time alone says
/// nothing about which day: yesterday's 14:02 reads as today's. Today is the
/// time of day, the last week the weekday and the time, anything older the
/// month, the day and the time — each in the locale's own pattern
/// (`setLocalizedDateFormatFromTemplate`: "3:04 PM" in the US, "15:04" in
/// Britain and China, and the person's 12/24-hour choice), in the app's
/// language.
enum LogClock {
    static func label(
        ms: Int64,
        nowMs: Int64,
        lang: ResolvedLanguage,
        timeZone: TimeZone = .current,
        locale: Locale? = nil
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let now = Date(timeIntervalSince1970: Double(nowMs) / 1000)
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day ?? 0
        let formatter = DateFormatter()
        formatter.locale = locale ?? Self.locale(for: lang)
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        if days == 0 {
            formatter.setLocalizedDateFormatFromTemplate("jmm")
        } else if days > 0, days < 7 {
            formatter.setLocalizedDateFormatFromTemplate("EEEjmm")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("Mdjmm")
        }
        return formatter.string(from: date)
    }

    /// The person's locale when it speaks the app's language — their region
    /// and their 12/24-hour choice — else the app's language in their
    /// region, so a Chinese interface on an English system still says 周三.
    static func locale(for lang: ResolvedLanguage, current: Locale = .autoupdatingCurrent) -> Locale {
        let wanted = lang == .zh ? "zh" : "en"
        if current.language.languageCode?.identifier == wanted { return current }
        let base = lang == .zh ? "zh_Hans" : "en"
        guard let region = current.region?.identifier else { return Locale(identifier: base) }
        return Locale(identifier: "\(base)_\(region)")
    }
}
