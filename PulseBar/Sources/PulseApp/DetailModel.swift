import Foundation

/// One session, in full, as a value — what `SessionDetailFace` draws.
///
/// The row is one line; this is what a person reads after deciding to look,
/// in the order it is worth reading: the ask (and what to do about it), the
/// why, the recent steps, the agent's last message, the last error and a few
/// plain facts — all from the session's own events. How Pulse reads the
/// session is folded away at the bottom. Nothing is shown as a placeholder:
/// a fact Pulse does not have is not a row. Tokens, context, cost, model and
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
    /// Up to `SessionBook.maxSteps` recent steps, newest first: how long
    /// ago, and "tool · target".
    var steps: [Fact]
    var lastMessage: String?
    var error: String?
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
        muted: Bool = false
    ) -> DetailModel {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        let explain = Explain.make(row, lang: lang, nowMs: nowMs)
        let fresh = row.selfReportFresh(at: nowMs)

        var facts: [Fact] = []
        if row.state == .running || row.isBlocked {
            let turn = Explain.turnDuration(row, nowMs: nowMs, lang: lang)
            if !turn.isEmpty { facts.append(Fact(label: t(.stepThisTurn), value: turn)) }
        }
        facts.append(Fact(label: t(.detailSource), value: explain.source))
        if !row.displayPath.isEmpty { facts.append(Fact(label: t(.detailFolder), value: row.displayPath)) }
        if row.startedMs > 0, row.startedMs <= nowMs {
            facts.append(Fact(label: t(.detailStarted), value: LogClock.label(ms: row.startedMs, nowMs: nowMs, lang: lang)))
        }

        let error: String? = row.lastErrorText.isEmpty ? nil : row.lastErrorText

        let age = row.isBlocked
            ? Explain.waitDuration(row, nowMs: nowMs, lang: lang)
            : Explain.activityLabel(row, nowMs: nowMs, lang: lang)
        let steps = row.recentSteps.reversed().map { step in
            Fact(label: Explain.minuteAgo(step.ms, nowMs: nowMs, lang: lang), value: Explain.stepText(step))
        }

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
            steps: steps,
            lastMessage: fresh && !row.lastWord.isEmpty ? row.lastWord : nil,
            error: error,
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
        if row.lastEventMs > 0, row.lastEventMs <= nowMs {
            out.append(Fact(label: t(.detailLastChange), value: LogClock.label(ms: row.lastEventMs, nowMs: nowMs, lang: lang)))
        }
        return out
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
