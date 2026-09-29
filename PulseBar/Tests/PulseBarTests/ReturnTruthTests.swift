import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

/// 0.96 Return Truth — Glance width and Attention compact. (23.0: the rekey
/// and story-honesty tests went with the remap and `RowNarrator`.)
final class ReturnTruthTests: XCTestCase {

    @MainActor
    func testGlanceTitleBudgetFitsEightCells() {
        XCTAssertEqual(GlanceTitle.cells("Claude…"), 7)
        XCTAssertEqual(GlanceTitle.cells("Claude · 4m"), 11)
        XCTAssertEqual(GlanceTitle.cells("1 · 4m"), 6)
        XCTAssertEqual(GlanceTitle.cells("中"), 2)
        XCTAssertEqual(GlanceTitle.fit("Claude · 4m", "1 · 4m", "1"), "1 · 4m")
        XCTAssertEqual(GlanceTitle.fit("Claude…", "1"), "Claude…")
        XCTAssertEqual(GlanceTitle.fit("Antigravity", "1"), "1")
        XCTAssertLessThanOrEqual(GlanceTitle.cells("Claude…"), GlanceTitle.maxCells)
    }

    @MainActor
    func testIdleGlanceStaysEmpty() {
        let r = SnapshotBuilder.build(
            SnapshotBuilder.Input(procs: [], harvest: [], attention: []),
            previous: .init(),
            context: SnapshotBuilder.Context(
                nowMs: 1_700_000_000_000,
                terminal: TerminalFocus.Environment(warpRunning: false, ttyHostRunning: false),
                lang: .en
            )
        )
        XCTAssertEqual(r.snapshot.glance, .idle)
        XCTAssertEqual(r.snapshot.title, "")
    }

    // MARK: P1 identity / compact

    @MainActor
    func testAttentionCompactKeepsUnresolvedRaise() {
        var lines: [String] = []
        for index in 0..<90 {
            lines.append("amp\tdone\t\(1_700_000_000_000 + index)\tok\tsess-\(index)\t/tmp\t\t")
        }
        lines.insert("amp\tpermission\t1\tapprove\tkeep-me\t/tmp\t\t", at: 0)
        let compacted = AttentionIO.compactLines(lines, cap: 80)
        XCTAssertEqual(compacted.count, 80)
        XCTAssertTrue(
            compacted.contains(where: { $0.contains("keep-me") }),
            "unresolved permission must survive the 80-line cap"
        )
    }
}
