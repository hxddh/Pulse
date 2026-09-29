import Foundation

/// 23.0 · one session, in full, as a value — what `SessionDetailFace` draws.
///
/// The row is one line; this is what a person reads after deciding to look,
/// in the order it is worth reading: the ask (and what to do about it), the
/// why, the last hour, the agent's last message and plan, the last error,
/// what happened to the banner, and a few plain facts. How Pulse reads the
/// session is folded away at the bottom. Nothing is shown as a placeholder:
/// a fact Pulse does not have is not a row.
struct DetailModel: Equatable {
    struct Plan: Equatable {
        struct Step: Equatable {
            var mark: String
            var text: String
            var current: Bool
            var done: Bool
        }
        /// "2/5 complete", from the steps themselves.
        var progress: String?
        var steps: [Step]
        /// Steps beyond the ones shown.
        var overflow: Int
    }

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
    var plan: Plan?
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

    static let maxPlanSteps = 8

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

        var error: String?
        if !row.lastErrorText.isEmpty {
            error = row.lastErrorText
        } else if row.errors > 0 {
            error = row.errors == 1 ? t(.errorFactOne) : String(format: t(.errorsFact), row.errors)
        }

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
            plan: fresh && !row.planSteps.isEmpty ? plan(row.planSteps, lang: lang) : nil,
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

    /// How Pulse reads this session, in words: the session id, the evidence
    /// behind a wait, how it would be focused, the process, the last change
    /// and any sessions of the same agent left out of the list.
    static func diagnostics(_ row: AgentRow, lang: ResolvedLanguage, nowMs: Int64) -> [Fact] {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        var out: [Fact] = []
        if !row.sessionID.isEmpty { out.append(Fact(label: t(.detailSession), value: row.sessionID)) }
        if let wait = row.wait {
            let signal: String
            switch wait.signal {
            case .hooks: signal = t(.signalHooks)
            case .pending: signal = t(.signalPending)
            case .vendor: signal = t(.signalVendor)
            }
            out.append(Fact(label: t(.detailWaitSignal), value: signal))
        }
        out.append(Fact(
            label: t(.detailGo),
            value: row.canFocusTerminal ? Explain.focusTitle(row, lang: lang) : t(.detailGoNone)
        ))
        if row.liveProcess, row.pid > 0 {
            out.append(Fact(label: t(.detailProcess), value: "pid \(row.pid)"))
        }
        if row.harvestMs > 0, row.harvestMs <= nowMs {
            out.append(Fact(label: t(.detailLastChange), value: LogClock.label(ms: row.harvestMs, nowMs: nowMs, lang: lang)))
        }
        if row.hiddenSessions > 0 {
            out.append(Fact(label: t(.detailMoreSessions), value: "\(row.hiddenSessions)"))
        }
        return out
    }

    static func plan(_ steps: [ActivityHarvest.PlanStep], lang: ResolvedLanguage) -> Plan {
        let done = steps.filter { $0.state == .done }.count
        return Plan(
            progress: steps.count > 1 ? String(format: L10n.t(.progressFact, lang), done, steps.count) : nil,
            steps: steps.prefix(maxPlanSteps).map { step in
                Plan.Step(
                    mark: step.state == .done ? "✓" : step.state == .current ? "▸" : "·",
                    text: step.text,
                    current: step.state == .current,
                    done: step.state == .done
                )
            },
            overflow: max(0, steps.count - maxPlanSteps)
        )
    }
}
