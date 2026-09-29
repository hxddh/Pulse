import Foundation

/// 19.0 · the cards that open under a tray row, as values.
///
/// 17.0 made the row's face a value and left the cards beneath it —
/// Respond's full request, the expanded inspector, the digest — reading the
/// store. They are where the user acts, so they are where a stale or wrong
/// render costs most. Each is now a pure function of the row, the narrator
/// and the few facts only the store knows (the matched request and its
/// fate), passed in as plain values; the views render these and send
/// `Action`s back.
///
/// The product rules stay in the model, where tests can reach them: Allow
/// exists only beside the full request (`canOfferAllow`), a truncated ask
/// withdraws it, and a Respond verdict carries the id and digest of the
/// request that was on screen.
struct RowCardModel: Equatable {
    enum Action: Equatable {
        /// The request as rendered — a verdict is only ever about what the
        /// user was looking at.
        case respondDeny(requestID: String, digest: String)
        case respondAllow(requestID: String, digest: String)
        case dismiss, snooze, unsnooze
    }

    /// Respond's full request (scenes AR/AU/BB).
    struct Respond: Equatable {
        var heading: String
        var fullRequest: String
        var requestID: String
        var digest: String
        /// Once a verdict is written, the receipt replaces the buttons.
        var fateNote: String?
        var canOfferAllow: Bool
        var deny: String
        var allow: String
    }

    struct Plan: Equatable {
        struct Step: Equatable {
            var mark: String
            var text: String
            var current: Bool
            var done: Bool
        }
        var progress: String?
        var steps: [Step]
        /// Steps beyond the four the compact face shows.
        var overflow: Int
    }

    /// 11.0-α (scene BV) — the digest tier: information in place.
    struct Brief: Equatable {
        var fullWords: String?
        var planStep: String?

        var isEmpty: Bool { fullWords == nil && planStep == nil }
    }

    var lang: ResolvedLanguage
    var rowKey: String

    // Understand
    var task: String?
    var lastWord: String?
    var errorText: String?
    var plan: Plan?
    var workFacts: [String]
    var panorama: [String]
    var brief: Brief

    // Act
    var respond: Respond?
    var waitActions: [WaitAction]

    struct WaitAction: Equatable {
        var action: Action
        var title: String
    }

    /// Anything in the in-list "needs you now" card.
    var hasAsks: Bool { respond != nil }

    /// Store-only facts, as values.
    struct Input {
        var row: AgentRow
        var narrator: RowNarrator
        /// The matched full request, when the row is waiting on one.
        var inbound: RespondSpool.InboundRequest? = nil
        var fateNote: String? = nil
    }

    static let heroClipThreshold = 96
    static let compactPlanSteps = 4

    static func make(_ input: Input) -> RowCardModel {
        let row = input.row
        let n = input.narrator
        func t(_ key: L10n.Key) -> String { n.tr(key) }

        var waitActions: [WaitAction] = []
        if row.waiting {
            waitActions.append(WaitAction(action: .dismiss, title: t(.dismissWait)))
            waitActions.append(row.isSnoozed
                ? WaitAction(action: .unsnooze, title: t(.snoozed))
                : WaitAction(action: .snooze, title: t(.snooze)))
        }

        return RowCardModel(
            lang: n.lang,
            rowKey: row.rowKey,
            task: row.usefulTask,
            lastWord: row.selfReportFresh && !row.lastWord.isEmpty ? row.lastWord : nil,
            errorText: row.lastErrorText.isEmpty ? nil : row.lastErrorText,
            plan: row.selfReportFresh && !row.planSteps.isEmpty ? plan(row, narrator: n) : nil,
            workFacts: n.workDetailFacts(row),
            panorama: [
                n.rowStoryLine(row),
                n.rowSignalLine(row),
                n.rowObservationLine(row),
                n.rowWorkLine(row),
                n.rowContextLine(row),
            ].filter { !$0.isEmpty },
            brief: brief(row, narrator: n),
            respond: row.waiting ? input.inbound.map { respond($0, row: row, fateNote: input.fateNote, narrator: n) } : nil,
            waitActions: waitActions
        )
    }

    static func respond(
        _ inbound: RespondSpool.InboundRequest,
        row: AgentRow,
        fateNote: String?,
        narrator n: RowNarrator
    ) -> Respond {
        Respond(
            heading: "\(n.tr(.respondFullRequest)) · \(inbound.toolName.isEmpty ? row.agent.displayName : inbound.toolName)",
            fullRequest: inbound.request.fullRequest,
            requestID: inbound.request.id,
            digest: inbound.request.digest,
            fateNote: fateNote,
            canOfferAllow: inbound.request.canOfferAllow,
            deny: n.tr(.respondDeny),
            allow: n.tr(.respondAllow)
        )
    }

    static func plan(_ row: AgentRow, narrator n: RowNarrator) -> Plan {
        Plan(
            progress: row.progressTotal > 0
                ? String(format: n.tr(.progressFact), row.progressDone, row.progressTotal)
                : nil,
            steps: row.planSteps.prefix(compactPlanSteps).map { step in
                Plan.Step(
                    mark: step.state == .done ? "✓" : step.state == .current ? "▸" : "·",
                    text: step.text,
                    current: step.state == .current,
                    done: step.state == .done
                )
            },
            overflow: max(0, row.planSteps.count - compactPlanSteps)
        )
    }

    /// Mirrors the hero's clip: below it the hero already shows the whole
    /// sentence and repeating it would be the same fact twice.
    static func brief(_ row: AgentRow, narrator n: RowNarrator) -> Brief {
        let step = row.planStep.trimmingCharacters(in: .whitespacesAndNewlines)
        return Brief(
            fullWords: row.selfReportFresh && row.lastWord.count > heroClipThreshold ? row.lastWord : nil,
            planStep: row.selfReportFresh && !step.isEmpty && !n.rowMetaOwnsPlanStep(row) ? row.planStep : nil
        )
    }
}
