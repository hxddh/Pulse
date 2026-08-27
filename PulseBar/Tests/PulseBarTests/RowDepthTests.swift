import XCTest
@testable import PulseBar

/// 11.0-α (scene BV) — the depth a row earns before any click, pinned as a
/// table. The chevron stops being the door to information; it remains the
/// door to actions.
final class RowDepthTests: XCTestCase {

    func testExplicitExpansionAlwaysWinsFullDepth() {
        XCTAssertEqual(
            RowDepth.tier(expanded: true, needsYou: true, live: false, crowded: true),
            .full
        )
        XCTAssertEqual(
            RowDepth.tier(expanded: true, needsYou: false, live: true, crowded: false),
            .full
        )
    }

    func testNeedsYouStaysMinimalBeneathItsCards() {
        // The ask card IS the depth; digest noise beside a question would
        // dilute the one thing the row exists to say.
        XCTAssertEqual(
            RowDepth.tier(expanded: false, needsYou: true, live: true, crowded: false),
            .minimal
        )
    }

    func testALiveRowOnACalmPanelGetsTheDigestByDefault() {
        XCTAssertEqual(
            RowDepth.tier(expanded: false, needsYou: false, live: true, crowded: false),
            .digest
        )
    }

    func testCrowdingDropsLiveRowsBackToMinimal() {
        XCTAssertEqual(
            RowDepth.tier(expanded: false, needsYou: false, live: true, crowded: true),
            .minimal
        )
    }

    func testIdleStaysMinimal() {
        XCTAssertEqual(
            RowDepth.tier(expanded: false, needsYou: false, live: false, crowded: false),
            .minimal
        )
    }
}
