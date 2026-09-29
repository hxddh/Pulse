import Foundation
import PulseCore

/// Everything the scan remembers from one pass to the next, with one owner.
///
/// 12.3 γ. Before this, five `static var`s across `NativeActivityHarvest` and
/// `ProcessProbe` carried state between scans, each documented as safe
/// because scans run on `ScanEngine.scanQueue`. They are now fields of one
/// value behind one lock (`Guarded`), so an off-queue caller — the CLI, the
/// self-test, a future second queue — cannot race them, and the app target's
/// concurrency checking sees a `Sendable` owner instead of global mutation.
package struct ScanMemory {
    /// Resolved Claude/Pi dash-encoded project directories. Cleared at the
    /// start of every `NativeActivityHarvest.scan`, so an answer about the
    /// disk never outlives the pass that made it.
    package var dashPaths: [String: (path: String, verified: Bool)] = [:]
    /// `lsof` cwd answers per pid, including negative ones.
    package var cwd: [Int: (path: String, observedAt: TimeInterval)] = [:]
    /// No `lsof` before this instant after a denied or empty lookup.
    package var cwdLookupBackoffUntil: TimeInterval = 0
}

package enum HarvestMemory {
    package static let memory = Guarded(ScanMemory())
}
