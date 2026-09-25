import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest
@testable import PulseManaged
@testable import PulseRespond

/// 12.3 δ — narration is a value. Everything it used to read from the store
/// implicitly (the clock, tray crowding, the managed fleet) is an input, so
/// these tests need no `StatusStore`, no main actor and no live clock.
final class RowNarratorTests: XCTestCase {
    private let now: Int64 = 1_800_000_000_000
    private let minute: Int64 = 60_000

    private func remoteRow(heardAgo: Int64) -> AgentRow {
        var row = AgentRow(rowKey: "claude|s1@devbox", agent: .claude)
        row.host = "devbox"
        row.observationSource = .remote
        row.lastHeardMs = now - heardAgo
        return row
    }

    func testTheSameRowAndInstantAlwaysTellTheSameStory() {
        let narrator = RowNarrator(lang: .en, nowMs: now)
        let row = remoteRow(heardAgo: 3 * minute)
        XCTAssertEqual(narrator.rowStoryLine(row), narrator.rowStoryLine(row))
        XCTAssertEqual(narrator.rowStoryLine(row), narrator.remoteStatusLine(row))
    }

    func testThePinnedClockIsTheOneTheSentenceMeasuresFrom() throws {
        let row = remoteRow(heardAgo: 3 * minute)
        let early = try XCTUnwrap(RowNarrator(lang: .en, nowMs: now).remoteStatusLine(row))
        let later = try XCTUnwrap(RowNarrator(lang: .en, nowMs: now + 60 * minute).remoteStatusLine(row))
        XCTAssertNotEqual(early, later, "an hour later the gap must read differently")
        // An explicit instant still overrides the narrator's own.
        XCTAssertEqual(
            RowNarrator(lang: .en, nowMs: now + 60 * minute).remoteStatusLine(row, nowMs: now),
            early
        )
    }

    func testManagedOutcomeFactsComeFromTheInjectedFleetOnly() {
        var row = AgentRow(rowKey: "claude|m1", agent: .claude)
        row.managedID = "m1"
        row.task = "Fix the auth module"
        row.liveProcess = true
        row.observationSource = .session
        row.harvestMs = now
        var model = ManagedSession.Model(id: "m1", task: "t", root: "/tmp/w", isWorktree: true, nowMs: now)
        model.totalCostUSD = 1.5
        model.turns = 3
        let bare = RowNarrator(lang: .en, nowMs: now)
        let managed = RowNarrator(lang: .en, nowMs: now, managedModels: ["m1": model])
        XCTAssertFalse(bare.rowObservationLine(row).contains("$1.50"))
        XCTAssertTrue(managed.rowObservationLine(row).contains("$1.50"), managed.rowObservationLine(row))
    }

    func testLanguageIsAnInputNotAStoreSetting() {
        let row = remoteRow(heardAgo: 3 * minute)
        XCTAssertNotEqual(
            RowNarrator(lang: .en, nowMs: now).remoteStatusLine(row),
            RowNarrator(lang: .zh, nowMs: now).remoteStatusLine(row)
        )
    }
}
