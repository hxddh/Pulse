import Foundation

/// 19.0 · the cards that open under a tray row, as values.
///
/// 17.0 made the row's face a value and left the cards beneath it — the
/// expanded inspector, the digest — reading the store. They are where the
/// user acts, so they are where a stale or wrong render costs most. Each is
/// now a pure function of the row and the narrator.
struct RowCardModel: Equatable {
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

    var lang: ResolvedLanguage
    var rowKey: String

    // Understand
    var task: String?
    var lastWord: String?
    var errorText: String?
    var plan: Plan?
    var workFacts: [String]
    var panorama: [String]

    /// Store-only facts, as values.
    struct Input {
        var row: AgentRow
        var narrator: RowNarrator
    }

    static let compactPlanSteps = 4

    static func make(_ input: Input) -> RowCardModel {
        let row = input.row
        let n = input.narrator
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
            ].filter { !$0.isEmpty }
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

}
