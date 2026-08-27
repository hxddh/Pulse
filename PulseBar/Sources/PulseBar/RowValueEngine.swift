import Foundation

/// 8.0-α — the value engine (scene BN).
///
/// The verdict this version answers: tools, tokens, skill, model, context —
/// all collected for versions — were "completely unobservable" in the popup.
/// The cause was structural, not a missing field: one budgeted line ranked
/// standing facts last, so the budget did not *order* them, it *deleted*
/// them, every beat, on every row.
///
/// The engine changes what the budget means: it decides which line a fact
/// lives on, never whether it exists. The observation line keeps exactly its
/// 2.1 composition (tiers, order, budget — byte-identical, pinned by the
/// existing suite); every work-class fact the budget cuts moves to the work
/// line instead of dying. Facts that never competed before (the last tool)
/// lead the work line. A fact appears on exactly one of the two lines.
enum RowValueEngine {

    struct Split: Equatable {
        /// The observation line: outcome + whatever work facts fit the budget
        /// + volume — the historical composition, unchanged.
        var observation: [String]
        /// The work line: leading facts that never enter the observation
        /// line, then every work fact the budget displaced.
        var work: [String]
    }

    /// - Parameters:
    ///   - outcome: faults + advance, in rank order (they own the front).
    ///   - work: motion + reach + standing, in rank order.
    ///   - volume: records + caveats (last, as always).
    ///   - leadingWork: facts reserved for the work line (e.g. the last
    ///     tool) — they lead it and never count against the budget.
    ///   - budget: the observation line's fact budget (2.1 semantics).
    static func split(
        outcome: [String],
        work: [String],
        volume: [String],
        leadingWork: [String],
        budget: Int
    ) -> Split {
        let facts = outcome + work + volume
        let observation = Array(facts.prefix(max(0, budget)))
        let shown = Set(observation)
        let displaced = work.filter { !shown.contains($0) }
        return Split(observation: observation, work: leadingWork + displaced)
    }
}
