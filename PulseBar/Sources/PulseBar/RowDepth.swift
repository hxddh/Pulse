import Foundation

/// 11.0-α (scene BV) — the depth a row earns BEFORE any click.
///
/// The chevron tax was the popup's most awkward beat: information the user
/// opens the popup for sat behind one click per row. The answer is not
/// "everything open" (five full cards stacked is the 8.x wall again) but
/// attention-adaptive defaults, the way Raycast pairs a list with an
/// always-on detail pane and Conductor renders complete-but-bounded cards:
///
/// - explicit expansion (chevron / Go-Look reveal) → **full** depth;
/// - a row that needs you → **minimal** beneath its ask cards — the ask IS
///   the depth, and digest noise beside a question would dilute it;
/// - a live row on an uncrowded panel → **digest**: information in place
///   (full words, current step, what landed), actions still behind the
///   chevron;
/// - everything else — idle rows, crowded panels — stays **minimal**.
///
/// Pure and pinned by `RowDepthTests`; the view only maps tier → blocks.
enum RowDepth {

    enum Tier: Equatable {
        /// Identity strip + hero + meta line only.
        case minimal
        /// Minimal plus the information brief — never an act surface.
        case digest
        /// The whole expanded card: panorama, work detail, actions.
        case full
    }

    static func tier(
        expanded: Bool,
        needsYou: Bool,
        live: Bool,
        crowded: Bool
    ) -> Tier {
        if expanded { return .full }
        if needsYou { return .minimal }
        if live, !crowded { return .digest }
        return .minimal
    }
}
