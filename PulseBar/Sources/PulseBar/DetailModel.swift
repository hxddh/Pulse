import Foundation

/// 23.0 · one session, in full, as a value — what `SessionDetailFace` draws.
///
/// The row is one line; this is what a person reads after deciding to look:
/// the task, `Explain`'s why, the full ask, the agent's own last words and
/// plan, the last error, a few plain facts (model, source, folder, start),
/// what happened to the banner (`SessionLog`), and the last hour as a strip.
/// It replaced `RowCardModel`, the Why card and the diagnostics card.
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

    /// What the detail page can ask the store to do.
    enum Action: Equatable { case back, focus, dismiss }

    var lang: ResolvedLanguage
    /// The row's face: lamp, name, project, chip, time.
    var face: TrayRowModel
    var task: String?
    var why: String
    /// The full question of a blocked row.
    var ask: String?
    var lastWord: String?
    var error: String?
    var plan: Plan?
    var facts: [Fact]
    /// `NotificationAuditModel.lines` for the latest wait; empty when none.
    var audit: [String]
    var timeline: TimelineStripModel?
    var canFocus: Bool
    var focusTitle: String
    var canDismiss: Bool

    static let maxPlanSteps = 8

    static func make(
        row: AgentRow,
        face: TrayRowModel,
        lang: ResolvedLanguage,
        nowMs: Int64,
        stallMinutes: Int = 0,
        audit: NotificationAuditModel? = nil,
        timeline: TimelineStripModel? = nil
    ) -> DetailModel {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        let explain = Explain.make(row, lang: lang, nowMs: nowMs, stallMinutes: stallMinutes)
        let fresh = row.selfReportFresh(at: nowMs)

        var facts: [Fact] = []
        let model = row.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { facts.append(Fact(label: t(.detailModel), value: model)) }
        facts.append(Fact(label: t(.detailSource), value: explain.source))
        if !row.displayPath.isEmpty { facts.append(Fact(label: t(.detailFolder), value: row.displayPath)) }
        if row.startedMs > 0, row.startedMs <= nowMs {
            facts.append(Fact(label: t(.detailStarted), value: Explain.ago(row.startedMs, nowMs: nowMs, lang: lang)))
        }

        var error: String?
        if !row.lastErrorText.isEmpty {
            error = row.lastErrorText
        } else if row.errors > 0 {
            error = row.errors == 1 ? t(.errorFactOne) : String(format: t(.errorsFact), row.errors)
        }

        return DetailModel(
            lang: lang,
            face: face,
            task: row.usefulTask,
            why: explain.why,
            ask: explain.ask,
            lastWord: fresh && !row.lastWord.isEmpty ? row.lastWord : nil,
            error: error,
            plan: fresh && !row.planSteps.isEmpty ? plan(row.planSteps, lang: lang) : nil,
            facts: facts,
            audit: audit?.lines ?? [],
            timeline: timeline,
            canFocus: row.canFocusTerminal,
            focusTitle: Explain.focusTitle(row, lang: lang),
            canDismiss: row.isBlocked
        )
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
