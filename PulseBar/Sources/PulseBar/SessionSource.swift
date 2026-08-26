import Foundation

// 5.0-α — the engine boundary (docs/plan-5.0.md).
//
// Every top product in this category owns the sessions it shows; Pulse was
// the market's one pure observer, and its pipeline was written that way: the
// harvest/builder machinery WAS the store's row supply, end to end. 5.0 adds
// a second producer (the managed runtime, 5.0-β), which forces the seam 3.0
// kept deferring with "seams follow use" — the use has arrived.
//
// `SessionSource` is the producer contract. The coordinator owns the merge:
// per-source order preserved, sources ranked by registration, first
// registration wins a rowKey collision. With a single source the merge is a
// verbatim passthrough — the full test suite freezes that behavior.

/// A producer of session rows. Conformers own their rows; the coordinator
/// owns the merge. Nothing here is async — sources update themselves on the
/// main actor and the store pulls the merge at its established apply points,
/// so the scan pipeline's threading discipline is unchanged.
@MainActor
protocol SessionSource: AnyObject {
    /// Stable identity for diagnostics and ordering ties.
    var sourceID: String { get }
    /// The sessions this source currently vouches for, in its own order.
    var sessions: [AgentRow] { get }
}

/// The observed pipeline — harvest, builder, attention, fleet — behind the
/// boundary. The engine replaces this source's rows where it used to assign
/// `cachedAll` directly, and patches them where the activity light path used
/// to patch in place. One owner, no second truth.
@MainActor
final class ObservedSessionSource: SessionSource {
    let sourceID = "observed"
    private(set) var sessions: [AgentRow] = []

    func replaceSessions(_ rows: [AgentRow]) {
        sessions = rows
    }

    /// In-place patch for the 2.9 activity light path. Returns whether the
    /// mutator reported a change, so the caller re-merges only when needed.
    func patchSessions(_ mutate: (inout [AgentRow]) -> Bool) -> Bool {
        mutate(&sessions)
    }
}

/// Merges every registered source into the one row list the store caches.
@MainActor
final class SessionSourceCoordinator {
    private(set) var sources: [SessionSource]

    init(sources: [SessionSource] = []) {
        self.sources = sources
    }

    /// Later registrations rank after existing sources: the observed
    /// pipeline registers first and stays the ground truth for any rowKey
    /// it also produces.
    func register(_ source: SessionSource) {
        guard !sources.contains(where: { $0 === source }) else { return }
        sources.append(source)
    }

    /// Per-source order preserved; first source wins a rowKey collision.
    /// Display concerns (sections, windows, priority) stay downstream —
    /// the merge is a supply, not a layout.
    func merged() -> [AgentRow] {
        var seen = Set<String>()
        var out: [AgentRow] = []
        for source in sources {
            for row in source.sessions where seen.insert(row.rowKey).inserted {
                out.append(row)
            }
        }
        return out
    }
}
