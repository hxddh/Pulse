import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

/// 12.3 δ — narration is a value. Everything it used to read from the store
/// implicitly (the clock, tray crowding) is an input, so these tests need no
/// `StatusStore`, no main actor and no live clock.
final class RowNarratorTests: XCTestCase {
    private let now: Int64 = 1_800_000_000_000
    private let minute: Int64 = 60_000

    private func waitingRow(raisedAgo: Int64) -> AgentRow {
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.sessionID = "s1"
        row.observationSource = .session
        row.waiting = true
        row.waitKind = "Permission"
        row.waitSignal = .hooks
        row.waitSinceMs = now - raisedAgo
        return row
    }

    func testTheSameRowAndInstantAlwaysTellTheSameStory() {
        let narrator = RowNarrator(lang: .en, nowMs: now)
        let row = waitingRow(raisedAgo: 3 * minute)
        XCTAssertEqual(narrator.rowStoryLine(row), narrator.rowStoryLine(row))
        XCTAssertEqual(narrator.whyLine(row), narrator.whyLine(row))
    }

    func testThePinnedClockIsTheOneTheSentenceMeasuresFrom() throws {
        let row = waitingRow(raisedAgo: 3 * minute)
        let early = try XCTUnwrap(RowNarrator(lang: .en, nowMs: now).whyLine(row))
        let later = try XCTUnwrap(RowNarrator(lang: .en, nowMs: now + 60 * minute).whyLine(row))
        XCTAssertNotEqual(early, later, "an hour later the gap must read differently")
    }

    func testLanguageIsAnInputNotAStoreSetting() {
        let row = waitingRow(raisedAgo: 3 * minute)
        XCTAssertNotEqual(
            RowNarrator(lang: .en, nowMs: now).whyLine(row),
            RowNarrator(lang: .zh, nowMs: now).whyLine(row)
        )
    }
}
