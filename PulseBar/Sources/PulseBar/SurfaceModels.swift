import Foundation

// Surfaces as values (15.0). A surface is a pure function from plain inputs
// to an `Equatable` value; the SwiftUI view renders the value and sends
// intents, and the store maps intents to verbs. That is what lets a fixture
// render every state in CI (`SurfaceCapture`) and lets a test assert the
// product's rules on the value itself.
//
// 22.0 removed the Workbench's Mission board and working-copy card with the
// orchestrator they belonged to; the Why card remains.

// MARK: - 17.0 · Why

/// Why a row is in its state, and what the hooks said to put it there.
struct WhyCardModel: Equatable {
    var lang: ResolvedLanguage
    /// The one sentence; nil when the state needs no explaining.
    var why: String?
    /// Newest first, at most `maxLines`.
    var lines: [String]
    /// Events kept for this session (what an export would copy).
    var eventCount: Int

    static let maxLines = 12

    var isEmpty: Bool { why == nil && lines.isEmpty }

    static func make(row: AgentRow, history: [AttentionHistory.Event], narrator: RowNarrator) -> WhyCardModel {
        WhyCardModel(
            lang: narrator.lang,
            why: narrator.whyLine(row),
            lines: history.suffix(maxLines).reversed().map(narrator.historyLine),
            eventCount: history.count
        )
    }
}

enum WhyIntent: Equatable {
    case export
}
