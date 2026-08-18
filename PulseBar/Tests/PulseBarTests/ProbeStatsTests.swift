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

/// The CPU axis, and the one rule that makes it worth having: an unsampled
/// process says **-1 (not known)**, never 0. "It is not computing" is a real
/// answer about a real agent, and inventing it from a missing measurement is
/// the failure this whole file exists to prevent.
final class ProcessProbeCPUTests: XCTestCase {
    // MARK: cputime parsing

    func testParseCPUTimeReadsEveryShapePSPrints() {
        XCTAssertEqual(ProcessProbe.parseCPUTime("0:00.00"), 0, accuracy: 0.0001)
        XCTAssertEqual(ProcessProbe.parseCPUTime("12:34.56"), 754.56, accuracy: 0.0001)
        XCTAssertEqual(ProcessProbe.parseCPUTime("1:02:03"), 3_723, accuracy: 0.0001)
        XCTAssertEqual(ProcessProbe.parseCPUTime("1-02:03:04"), 93_784, accuracy: 0.0001)
        XCTAssertEqual(ProcessProbe.parseCPUTime("  2:30.50 "), 150.5, accuracy: 0.0001)
    }

    func testParseCPUTimeRefusesGarbageRatherThanReturningZero() {
        // -1 is "the field said nothing". 0 would claim the process has never
        // used the CPU, which is a measurement, not a parse failure.
        for junk in ["", "   ", "not-a-time", "abc", "12:", ":", "1-2-3", "12:ab", "inf", "nan:00"] {
            XCTAssertEqual(ProcessProbe.parseCPUTime(junk), -1, "\(junk) is not a time")
        }
    }

    // MARK: rate

    func testTwoSamplesGiveTheOccupancyOfThatInterval() {
        // One CPU-second burned across two wall-clock seconds is half a core.
        XCTAssertEqual(
            ProcessProbe.cpuPercent(
                previousCPUSeconds: 10,
                previousAtMs: 1_000_000,
                currentCPUSeconds: 11,
                currentAtMs: 1_002_000
            ),
            50,
            accuracy: 0.0001
        )
    }

    func testFirstSightOfAProcessIsUnknownNotIdle() {
        // No previous tick to subtract from. `ps %cpu` would happily print a
        // lifetime average here; that number is about an agent's whole history,
        // not about now, and showing it as "busy" is the lie being avoided.
        XCTAssertEqual(
            ProcessProbe.cpuPercent(
                previousCPUSeconds: 0,
                previousAtMs: 0,
                currentCPUSeconds: 900,
                currentAtMs: 1_000_000
            ),
            -1
        )
    }

    func testTooShortAWindowIsUnknown() {
        XCTAssertEqual(
            ProcessProbe.cpuPercent(
                previousCPUSeconds: 10,
                previousAtMs: 1_000_000,
                currentCPUSeconds: 10.4,
                currentAtMs: 1_000_999
            ),
            -1,
            "under a second the quantised cputime field measures the sampler"
        )
        XCTAssertEqual(
            ProcessProbe.cpuPercent(
                previousCPUSeconds: 10,
                previousAtMs: 1_000_000,
                currentCPUSeconds: 10.4,
                currentAtMs: 1_001_000
            ),
            40,
            accuracy: 0.0001,
            "exactly the minimum window is enough"
        )
    }

    func testACounterGoingBackwardsIsUnknownNotNegative() {
        // pid reuse: a new process wearing a dead one's number. Its predecessor's
        // history describes a different program.
        XCTAssertEqual(
            ProcessProbe.cpuPercent(
                previousCPUSeconds: 900,
                previousAtMs: 1_000_000,
                currentCPUSeconds: 0.2,
                currentAtMs: 1_060_000
            ),
            -1
        )
    }

    func testZeroIsAnAnswerAndIsNotUnknown() {
        let idle = ProcessProbe.cpuPercent(
            previousCPUSeconds: 42,
            previousAtMs: 1_000_000,
            currentCPUSeconds: 42,
            currentAtMs: 1_060_000
        )
        XCTAssertEqual(idle, 0, accuracy: 0.0001, "sampled twice, burned nothing: it really has stopped")
        XCTAssertNotEqual(idle, -1, "not knowing and not computing are different facts")
    }

    func testParallelWorkIsAllowedPastOneHundredPercent() {
        // A parallel build genuinely occupies four cores. Clamping this to 100
        // would erase the difference between "busy" and "flat out".
        XCTAssertEqual(
            ProcessProbe.cpuPercent(
                previousCPUSeconds: 0,
                previousAtMs: 1_000_000,
                currentCPUSeconds: 4,
                currentAtMs: 1_002_000
            ),
            400,
            accuracy: 0.0001
        )
    }

    func testAbsurdValuesAreClampedRatherThanPrinted() {
        XCTAssertEqual(
            ProcessProbe.cpuPercent(
                previousCPUSeconds: 0,
                previousAtMs: 1_000_000,
                currentCPUSeconds: 100_000,
                currentAtMs: 1_001_000
            ),
            ProcessProbe.maxCPUPercent,
            accuracy: 0.0001
        )
    }

    // MARK: sample store

    func testTheSampleStoreStaysBounded() {
        var samples: [Int: (cpuSeconds: Double, atMs: Int64)] = [:]
        for pid in 1...(ProcessProbe.maxCPUSamples + 200) {
            samples[pid] = (cpuSeconds: 1, atMs: Int64(1_000_000 + pid))
        }
        let bounded = ProcessProbe.boundedCPUSamples(samples)
        XCTAssertEqual(bounded.count, ProcessProbe.maxCPUSamples)
        XCTAssertNotNil(bounded[ProcessProbe.maxCPUSamples + 200], "the freshest sample survives")
        XCTAssertNil(bounded[1], "the stalest one is what goes")
    }

    // MARK: ps line parsing

    /// Real `ps -axo pid=,ppid=,tty=,etime=,cputime=,rss=,args=` output, columns
    /// padded the way `ps` pads them.
    private let psOutput = """
          4432   4401 ttys003      02:04:12      0:11.42   72112 node /Users/me/.local/bin/claude --model opus --resume
          9001      1 ??         5-00:00:00   1-02:03:04 1048576 /Applications/Pulse.app/Contents/MacOS/Pulse --serve
          3 fields only
        """

    func testProcessLinesKeepArgumentsWhole() {
        let procs = ProcessProbe.parseProcessLines(psOutput)
        XCTAssertEqual(procs.count, 2, "a line without every column is dropped, not half-read")

        let claude = procs[0]
        XCTAssertEqual(claude.pid, 4432)
        XCTAssertEqual(claude.ppid, 4401)
        XCTAssertEqual(claude.tty, "ttys003")
        XCTAssertEqual(claude.elapsedSeconds, 7_452, accuracy: 0.0001)
        XCTAssertEqual(claude.cpuSeconds, 11.42, accuracy: 0.0001)
        XCTAssertEqual(claude.rssBytes, 72_112 * 1_024)
        XCTAssertEqual(
            claude.args,
            "node /Users/me/.local/bin/claude --model opus --resume",
            "args is the last column precisely because it contains spaces"
        )
        XCTAssertEqual(claude.cpuPercent, -1, "parsing alone cannot know a rate")

        let pulse = procs[1]
        XCTAssertEqual(pulse.pid, 9001)
        XCTAssertEqual(pulse.tty, "??")
        XCTAssertEqual(pulse.elapsedSeconds, 432_000, accuracy: 0.0001)
        XCTAssertEqual(pulse.cpuSeconds, 93_784, accuracy: 0.0001)
        XCTAssertEqual(pulse.rssBytes, 1_048_576 * 1_024)
        XCTAssertEqual(pulse.args, "/Applications/Pulse.app/Contents/MacOS/Pulse --serve")
    }

    func testAProcessWithNoUsableCPUFieldStaysUnknown() {
        let procs = ProcessProbe.parseProcessLines(
            "  7 1 ttys001 01:00 - 4096 /bin/zsh -l"
        )
        XCTAssertEqual(procs.count, 1)
        XCTAssertEqual(procs[0].cpuSeconds, -1, "an unreadable cputime is not zero CPU")
        XCTAssertEqual(procs[0].rssBytes, 4_096 * 1_024)
    }

    func testTheDegradedFieldListStillListsProcesses() {
        // If a `ps` ever refuses `cputime`/`rss`, the fleet must still be seen.
        // Losing the CPU axis is a smaller loss than showing no agents at all,
        // and the rows say "not known" rather than inventing an idle reading.
        let procs = ProcessProbe.parseProcessLines(
            "  4432   4401 ttys003      02:04:12 node /Users/me/.local/bin/claude --model opus",
            includesCPU: false
        )
        XCTAssertEqual(procs.count, 1)
        XCTAssertEqual(procs[0].pid, 4432)
        XCTAssertEqual(procs[0].elapsedSeconds, 7_452, accuracy: 0.0001)
        XCTAssertEqual(procs[0].args, "node /Users/me/.local/bin/claude --model opus")
        XCTAssertEqual(procs[0].cpuSeconds, -1)
        XCTAssertEqual(procs[0].cpuPercent, -1)
        XCTAssertEqual(procs[0].rssBytes, 0)
    }

    // MARK: the fingerprint

    func testTheFingerprintIgnoresCPUAndMemory() {
        // Folding a per-tick number into the fingerprint would make it differ
        // from itself forever, the harvest skip would never fire again, and a
        // resident menu-bar app would burn battery continuously.
        var quiet = ProcessProbe.Hit(id: .claude, count: 1, viaWarp: false, pid: 10)
        XCTAssertEqual(quiet.cpuPercent, -1, "unknown until two samples exist")
        XCTAssertEqual(quiet.rssBytes, 0)
        let before = ProcessProbe.signature([quiet])
        quiet.cpuPercent = 380
        quiet.rssBytes = 900_000_000
        XCTAssertEqual(ProcessProbe.signature([quiet]), before)
    }
}
