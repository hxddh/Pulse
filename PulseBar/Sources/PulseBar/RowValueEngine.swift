import Foundation

/// 8.0/8.1 — the value engine (scene BN).
///
/// The verdict this axis answers: tools, tokens, skill, model, context —
/// collected for versions — were "completely unobservable" in the popup.
/// 8.0 diagnosed the observation budget deleting them and rehoused only the
/// *overflow*; real rows rarely overflowed, so the maze survived with a new
/// entrance. 8.1 makes the contract unconditional: the work line is built
/// directly from the fields, in value order, and a measured fact renders —
/// the only competition left is order, never existence.
///
/// The engine is deliberately tiny and pure: slots arrive in value order,
/// absent facts are nil, the limit caps the line. What earns a slot — and
/// which other line may claim one first — is the store's decision, pinned
/// by `RowValueEngineTests` at the store level.
enum RowValueEngine {

    /// Value-ordered slots → the rendered facts. nil = the fact was not
    /// measured (absent, never zero); order is preserved; `limit` caps the
    /// line without reordering.
    static func line(_ slots: [String?], limit: Int) -> [String] {
        Array(slots.compactMap { $0 }.prefix(max(0, limit)))
    }
}
