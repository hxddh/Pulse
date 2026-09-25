import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest
@testable import PulseRespond

/// 12.0 · a scan does not redraw Settings; a setting does.
@MainActor
final class StoreObservationTests: XCTestCase {
    func testAScanDoesNotReachTheObserverButASettingDoes() {
        let store = StatusStore()
        var now: Int64 = 1_800_000_000_000
        let observation = StoreObservation(store: store, scanRefreshInterval: 30, nowMs: { now })

        for _ in 0..<5 {
            now += 2_000
            store.isApplyingScan = true
            store.snapshot = PulseSnapshot()
            store.isApplyingScan = false
        }
        XCTAssertEqual(observation.forwardedChanges, 0, "five scans inside the interval redraw nothing")

        store.stallMinutes += 1
        XCTAssertEqual(observation.forwardedChanges, 1, "a setting the form shows redraws it")
    }

    func testScanDerivedFactsStillRefreshOnTheSlowCadence() {
        let store = StatusStore()
        var now: Int64 = 1_800_000_000_000
        let observation = StoreObservation(store: store, scanRefreshInterval: 30, nowMs: { now })

        now += 31_000
        store.isApplyingScan = true
        store.snapshot = PulseSnapshot()
        store.snapshot = PulseSnapshot()
        store.isApplyingScan = false
        XCTAssertEqual(observation.forwardedChanges, 1, "once per interval, not once per publish")
    }
}
