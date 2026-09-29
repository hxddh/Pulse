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

/// Why a row is in its state, and what the session did to get there.
///
/// 23.0: the lines are the session's spans from `SessionLog` — the state,
/// the wait kind, the evidence, and for a block the words the agent sent —
/// newest first. The hook-by-hook copy (`attention-history.json`) and its
/// TSV export are gone; the span record already says what the lamp showed
/// and why.
struct WhyCardModel: Equatable {
    var lang: ResolvedLanguage
    /// The one sentence; nil when the state needs no explaining.
    var why: String?
    /// Newest first, at most `maxLines`.
    var lines: [String]

    static let maxLines = 12

    var isEmpty: Bool { why == nil && lines.isEmpty }

    static func make(row: AgentRow, spans: [TimelineSpan], narrator: RowNarrator) -> WhyCardModel {
        WhyCardModel(
            lang: narrator.lang,
            why: narrator.whyLine(row),
            lines: spans.suffix(maxLines).reversed().map(narrator.spanLine)
        )
    }
}
