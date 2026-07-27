import XCTest
@testable import PulseBar

/// The 0.22 release note claims the energy rework cut Python forks from
/// ~28,800/day to ~2,880/day. That was arithmetic. These counters are what
/// makes it checkable on a real machine.
final class ProbeStatsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func stats(probes: Int, harvestEvery: Int, spacing: TimeInterval, harvestMs: Int? = 300) -> ProbeStats {
        var s = ProbeStats()
        for i in 0..<probes {
            let harvested = i % harvestEvery == 0
            s.record(.init(
                at: t0.addingTimeInterval(Double(i) * spacing),
                harvested: harvested,
                harvestMs: harvested ? harvestMs : nil
            ))
        }
        return s
    }

    func testCountsSeparateProbesFromHarvests() {
        let s = stats(probes: 20, harvestEvery: 4, spacing: 5)
        let now = t0.addingTimeInterval(100)
        XCTAssertEqual(s.probeCount(now: now), 20)
        XCTAssertEqual(s.harvestCount(now: now), 5, "only every 4th tick pays for Python")
    }

    func testSamplesOlderThanAnHourFallOut() {
        var s = ProbeStats()
        s.record(.init(at: t0, harvested: true, harvestMs: 100))
        s.record(.init(at: t0.addingTimeInterval(30), harvested: false, harvestMs: nil))
        let muchLater = t0.addingTimeInterval(ProbeStats.window + 60)
        XCTAssertEqual(s.probeCount(now: muchLater), 0)
    }

    func testPruningKeepsTheWindowBounded() {
        var s = ProbeStats()
        // A full day at the busiest cadence must not grow without bound.
        for i in 0..<43_200 {
            s.record(.init(at: t0.addingTimeInterval(Double(i) * 2), harvested: false, harvestMs: nil))
        }
        let end = t0.addingTimeInterval(86_398)
        XCTAssertLessThan(s.samples.count, 2_000, "an hour at 2s is ~1800 samples, not a day's worth")
        XCTAssertEqual(s.probeCount(now: end), 1_801, "exactly the trailing hour")
        XCTAssertEqual(
            s.probeCount(now: end.addingTimeInterval(ProbeStats.window + 1)),
            0,
            "an idle hour empties the window"
        )
    }

    func testAverageHarvestDurationIgnoresSkippedTicks() {
        var s = ProbeStats()
        s.record(.init(at: t0, harvested: true, harvestMs: 200))
        s.record(.init(at: t0.addingTimeInterval(5), harvested: false, harvestMs: nil))
        s.record(.init(at: t0.addingTimeInterval(10), harvested: true, harvestMs: 400))
        XCTAssertEqual(s.averageHarvestMs(now: t0.addingTimeInterval(15)), 300)
    }

    func testNoHarvestsMeansNoAverageRatherThanZero() {
        var s = ProbeStats()
        s.record(.init(at: t0, harvested: false, harvestMs: nil))
        XCTAssertNil(s.averageHarvestMs(now: t0.addingTimeInterval(5)))
    }

    func testProjectionMatchesTheObservedRate() {
        // Idle cadence: a harvest every 30s → 2,880 a day, the 0.22 claim.
        let s = stats(probes: 120, harvestEvery: 1, spacing: 30)
        let now = t0.addingTimeInterval(120 * 30)
        let daily = s.projectedDailyHarvests(now: now)
        XCTAssertNotNil(daily)
        XCTAssertEqual(Double(daily!), 2880, accuracy: 100, "should land on the published figure")
    }

    func testProjectionRefusesToExtrapolateFromAlmostNothing() {
        var s = ProbeStats()
        s.record(.init(at: t0, harvested: true, harvestMs: 100))
        s.record(.init(at: t0.addingTimeInterval(2), harvested: true, harvestMs: 100))
        XCTAssertNil(
            s.projectedDailyHarvests(now: t0.addingTimeInterval(2)),
            "two samples over two seconds must not become a daily figure"
        )
    }

    func testParkedTimeAccumulatesAndIgnoresNonsense() {
        var s = ProbeStats()
        s.addParked(600)
        s.addParked(-50)
        s.addParked(300)
        XCTAssertEqual(s.parkedSeconds, 900)
    }

    func testSummaryIsHonestBeforeAnythingHappened() {
        XCTAssertEqual(ProbeStats().summary(now: t0), "1h: no scans yet")
    }

    func testSummaryCarriesTheNumbersABugReportNeeds() {
        var s = stats(probes: 120, harvestEvery: 2, spacing: 30)
        s.addParked(720)
        let line = s.summary(now: t0.addingTimeInterval(120 * 30))
        XCTAssertTrue(line.contains("probes"))
        XCTAssertTrue(line.contains("harvests"))
        XCTAssertTrue(line.contains("/day"), "the projection is the point")
        XCTAssertTrue(line.contains("avg"))
        XCTAssertTrue(line.contains("parked 12m"))
    }

    func testShortParkingIsNotWorthReporting() {
        var s = stats(probes: 4, harvestEvery: 1, spacing: 5)
        s.addParked(20)
        XCTAssertFalse(s.summary(now: t0.addingTimeInterval(20)).contains("parked"))
    }
}
