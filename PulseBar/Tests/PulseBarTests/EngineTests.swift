import Foundation
import AppKit
import Observation
import SQLite3
import Testing
import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

// Engine: ScanEngine, the probe schedule and stats, the harvest supervisor, scan quiet.

/// 12.4 Surface — a scan that found the same world wakes no surface.
///
/// 19.0: the store is `@Observable`. A view is invalidated by the properties
/// its body read, and Observation announces every assignment, equal or not.
/// This is the counter wall: track every observed property of the store,
/// apply the same scan twice, and nothing may fire. When it fails, it names
/// the property that did.
@Suite("Scan quiet", .serialized)
@MainActor
struct ScanQuietTests {
    /// Written only from the main actor: Observation calls `onChange`
    /// synchronously on the writing thread, and every write here is a
    /// main-actor store write.
    final class Fired: @unchecked Sendable {
        var names: [String] = []
    }

    /// Every property of `StatusStore` a view can be invalidated by. A new
    /// observed property belongs here; `everyObservedPropertyIsListed` fails
    /// until it is.
    static var observed: [(String, PartialKeyPath<StatusStore>)] {
        [
            ("cachedAll", \StatusStore.cachedAll),
            ("collectorScanIncomplete", \StatusStore.collectorScanIncomplete),
            ("diagnostics", \StatusStore.diagnostics),
            ("hookSelfTestResult", \StatusStore.hookSelfTestResult),
            ("hooksStatus", \StatusStore.hooksStatus),
            ("hotkeyRegistered", \StatusStore.hotkeyRegistered),
            ("logRevision", \StatusStore.logRevision),
            ("loginItemApplied", \StatusStore.loginItemApplied),
            ("notifyAuthorized", \StatusStore.notifyAuthorized),
            ("rowActionNotices", \StatusStore.rowActionNotices),
            ("settings", \StatusStore.settings),
            ("settingsFocus", \StatusStore.settingsFocus),
            ("showAllAgents", \StatusStore.showAllAgents),
            ("snapshot", \StatusStore.snapshot),
            ("traySessionToken", \StatusStore.traySessionToken),
            ("updateStatus", \StatusStore.updateStatus),
            ("waitingBannerFailed", \StatusStore.waitingBannerFailed),
        ]
    }

    private func quietStore() -> StatusStore {
        // This test drives the scans itself.
        StatusStore()
    }

    private func scan(_ store: StatusStore, ticket: UInt64) {
        store.engine.applyScan(procs: [], harvest: .skipped, processSignature: "", attention: [], ticket: ticket)
    }

    private func watch(_ store: StatusStore, _ properties: [(String, PartialKeyPath<StatusStore>)]) -> Fired {
        let fired = Fired()
        for (name, keyPath) in properties {
            withObservationTracking {
                _ = store[keyPath: keyPath]
            } onChange: {
                fired.names.append(name)
            }
        }
        return fired
    }

    @Test func aSecondIdenticalScanAnnouncesNothing() {
        let store = quietStore()
        scan(store, ticket: 1)
        let fired = watch(store, Self.observed)

        scan(store, ticket: 2)
        scan(store, ticket: 3)

        #expect(fired.names == [], "observed properties written by an unchanged scan: \(fired.names)")
    }

    /// 23.0: a wait that crossed while macOS had not yet allowed Pulse to
    /// notify is owed a banner once. The ledger used to be rewritten on every
    /// scan after that for as long as authorization stayed unresolved; the
    /// session log changes (and `logRevision` moves) only when the wait did.
    @Test func anOwedBannerWhileUnauthorizedIsRecordedOnce() {
        let store = quietStore()
        store.notifyAuthorized = nil
        scan(store, ticket: 1)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let raised = AttentionReader.Entry(
            id: .claude, kind: "Permission", message: "Bash: npm test",
            tsMs: nowMs - 1_000, session: "s-owed", cwd: "/w/app"
        )
        store.engine.applyScan(procs: [], harvest: .skipped, processSignature: "", attention: [raised], ticket: 2)
        let owed = store.sessionLog.queuedKeys
        #expect(owed.count == 1, "the edge is owed its banner")
        let fired = watch(store, [("logRevision", \StatusStore.logRevision)])
        store.engine.applyScan(procs: [], harvest: .skipped, processSignature: "", attention: [raised], ticket: 3)
        store.engine.applyScan(procs: [], harvest: .skipped, processSignature: "", attention: [raised], ticket: 4)
        #expect(fired.names == [], "the same owed wait is not news")
    }

    @Test func aChangedWorldIsStillAnnounced() {
        let store = quietStore()
        scan(store, ticket: 1)
        let fired = watch(store, Self.observed)
        var next = store.snapshot
        next.headerTitle = "1 running"
        store.snapshot = next
        #expect(fired.names == ["snapshot"], "only what changed, and nothing else: \(fired.names)")
    }

    /// The generated source of `@Observable` lists the tracked properties;
    /// this reads the class's own stored properties and fails on one that is
    /// observed but missing from `observed`, so the wall above cannot go
    /// quietly partial.
    @Test func everyObservedPropertyIsListed() throws {
        // 23.0: the model stays small — engine and banner bookkeeping live in
        // `ScanEngine` and `WaitNotifier`, which nothing observes.
        let count = Self.observed.count
        #expect(count <= 25, "the observed model grew to \(count) properties")
        let listed = Set(Self.observed.map(\.0))
        let stored = Mirror(reflecting: quietStore()).children.compactMap(\.label)
        // `@Observable` stores a tracked property as `_name`; an ignored one
        // keeps its own name.
        let tracked = Set(stored.filter { $0.hasPrefix("_") && $0 != "_$observationRegistrar" }.map { String($0.dropFirst()) })
        #expect(tracked.subtracting(listed).sorted() == [], "observed but not in the quiet wall")
        #expect(listed.subtracting(tracked).sorted() == [], "listed but no longer observed")
    }

    // MARK: - Settings

    /// A settings change is one observed write, and it does not touch the
    /// snapshot the lamp follows.
    @Test func aSettingChangeWakesOnlySettings() {
        let store = quietStore()
        let fired = watch(store, Self.observed)
        store.settings.notifyOnWaiting = false
        #expect(fired.names == ["settings"], "\(fired.names)")
    }

    /// Setting a value to what it already is writes nothing.
    @Test func anUnchangedSettingWritesNothing() {
        let store = quietStore()
        let fired = watch(store, Self.observed)
        store.set(\.notifyOnWaiting, true)
        store.setReadProtectedAppData(false)
        #expect(fired.names == [])
    }

    // MARK: - The status item

    @Test func theStatusItemLoopFollowsTheSnapshotOnly() async {
        let store = quietStore()
        let loop = ObservationLoop(track: { _ = store.snapshot }, onChange: {})
        defer { loop.cancel() }

        store.settings.notifyOnWaiting.toggle()
        store.showAllAgents.toggle()
        for _ in 0..<10 { await Task.yield() }
        #expect(loop.deliveries == 0, "a settings write does not touch the lamp")

        var next = store.snapshot
        next.headerTitle = "2 running"
        store.snapshot = next
        next.headerTitle = "3 running"
        store.snapshot = next
        for _ in 0..<10 where loop.deliveries == 0 { await Task.yield() }
        #expect(loop.deliveries == 1, "a burst in one turn is one delivery")

        next.headerTitle = "4 running"
        store.snapshot = next
        for _ in 0..<10 where loop.deliveries == 1 { await Task.yield() }
        #expect(loop.deliveries == 2, "and the loop re-arms")
    }

    // MARK: - The publish decision (unchanged since 12.4)

    @Test func aChangedWorldStillPublishes() {
        var current = PulseSnapshot()
        current.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var next = current
        next.updatedAt = current.updatedAt.addingTimeInterval(2)
        #expect(!PulseSnapshot.needsPublish(next: next, current: current), "same world, two seconds later")

        next.headerTitle = "1 running"
        #expect(PulseSnapshot.needsPublish(next: next, current: current), "content moved")
    }

    /// 23.0 bug: the snapshot carried the oldest wait's age in seconds, so
    /// every scan while anything was blocked differed from the last and
    /// republished — the tray and the lamp woke on every tick.
    @Test func aStandingWaitIsQuietBetweenMinuteLabels() {
        let t0: Int64 = 1_800_000_000_000
        func scan(at nowMs: Int64) -> PulseSnapshot {
            let entry = AttentionReader.Entry(
                id: .claude, kind: "Permission", message: "Bash: make", tsMs: t0 - 10 * 60_000, session: "s1", cwd: "/w"
            )
            var snap = SnapshotBuilder.build(
                SnapshotBuilder.Input(attention: [entry]),
                previous: .init(),
                context: SnapshotBuilder.Context(
                    nowMs: nowMs,
                    terminal: TerminalFocus.Environment(warpRunning: false, ttyHostRunning: false),
                    lang: .en
                )
            ).snapshot
            snap.updatedAt = Date(timeIntervalSince1970: Double(nowMs) / 1000)
            return snap
        }
        let first = scan(at: t0)
        let second = scan(at: t0 + 2_000)
        #expect(second.sameContent(as: first), "a ten-minute wait two seconds later is the same world")
        #expect(!PulseSnapshot.needsPublish(next: second, current: first))
    }

    /// Only a wait's age is drawn in seconds; a running row's fresh activity
    /// is no reason to redraw every scan.
    @Test func freshActivityOnARunningRowDoesNotRepublish() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var current = PulseSnapshot()
        current.updatedAt = t0
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.state = .running
        row.activityMs = Int64(t0.timeIntervalSince1970 * 1000) - 5_000
        current.rows = [row]
        var next = current
        next.updatedAt = t0.addingTimeInterval(2)
        #expect(!PulseSnapshot.needsPublish(next: next, current: current))
    }

    @Test func theFirstScanAlwaysLands() {
        var next = PulseSnapshot()
        next.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(PulseSnapshot.needsPublish(next: next, current: PulseSnapshot()))
    }

    @Test func relativeTimeLabelsStillMove() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var current = PulseSnapshot()
        current.updatedAt = t0
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.state = .blocked(RowWait(kind: "Permission", sinceMs: Int64(t0.timeIntervalSince1970 * 1000) - 20_000, signal: .hooks))
        current.rows = [row]

        var next = current
        next.updatedAt = t0.addingTimeInterval(2)
        #expect(PulseSnapshot.needsPublish(next: next, current: current), "a 20 s wait is drawn in seconds — it moves every scan")

        current.rows[0].state = .blocked(RowWait(kind: "Permission", sinceMs: Int64(t0.timeIntervalSince1970 * 1000) - 600_000, signal: .hooks))
        next.rows = current.rows
        #expect(!PulseSnapshot.needsPublish(next: next, current: current), "a ten-minute wait holds for a minute")
        next.updatedAt = t0.addingTimeInterval(61)
        #expect(PulseSnapshot.needsPublish(next: next, current: current), "and moves once the minute turns")
    }
}

/// Cadence policy — the fix for "Pulse is using significant energy".
final class ProbeScheduleTests: XCTestCase {
    private let awake = ProbeSchedule.Power()

    func testBusierStatesProbeFaster() {
        let waiting = ProbeSchedule.interval(activity: .waiting, power: awake, trayOpen: false)!
        let running = ProbeSchedule.interval(activity: .running, power: awake, trayOpen: false)!
        let recent = ProbeSchedule.interval(activity: .recent, power: awake, trayOpen: false)!
        let empty = ProbeSchedule.interval(activity: .empty, power: awake, trayOpen: false)!
        XCTAssertLessThan(waiting, running)
        XCTAssertLessThan(running, recent)
        XCTAssertLessThan(recent, empty)
    }

    func testIdleMachineIsDramaticallyCheaperThanTheOldFixedCadence() {
        let empty = ProbeSchedule.interval(activity: .empty, power: awake, trayOpen: false)!
        XCTAssertGreaterThanOrEqual(empty, 30, "pre-0.22 probed every 3s regardless")
    }

    func testParkedWhenDisplayAsleepUnlessTrayIsOpen() {
        var power = ProbeSchedule.Power()
        power.displayAsleep = true
        XCTAssertNil(ProbeSchedule.interval(activity: .waiting, power: power, trayOpen: false))
        XCTAssertNotNil(ProbeSchedule.interval(activity: .waiting, power: power, trayOpen: true))
    }

    func testScreenLockAlsoParks() {
        var power = ProbeSchedule.Power()
        power.screenLocked = true
        XCTAssertTrue(power.parked)
        XCTAssertNil(ProbeSchedule.interval(activity: .running, power: power, trayOpen: false))
    }

    func testLowPowerModeSlowsButNeverParks() {
        var power = ProbeSchedule.Power()
        power.lowPowerMode = true
        let normal = ProbeSchedule.interval(activity: .running, power: awake, trayOpen: false)!
        let saving = ProbeSchedule.interval(activity: .running, power: power, trayOpen: false)!
        XCTAssertEqual(saving, normal * 2)
    }

    func testOpenTrayNeverSlowsThingsDown() {
        for activity in [ProbeSchedule.Activity.waiting, .running, .recent, .empty] {
            let closed = ProbeSchedule.interval(activity: activity, power: awake, trayOpen: false)!
            let open = ProbeSchedule.interval(activity: activity, power: awake, trayOpen: true)!
            XCTAssertLessThanOrEqual(open, closed, "\(activity) got slower with the tray open")
        }
    }

    func testHarvestRunsEveryTickWhileWaitingOrWatching() {
        XCTAssertEqual(ProbeSchedule.harvestEveryNTicks(activity: .waiting, trayOpen: false), 1)
        XCTAssertEqual(ProbeSchedule.harvestEveryNTicks(activity: .running, trayOpen: true), 1)
        XCTAssertGreaterThan(ProbeSchedule.harvestEveryNTicks(activity: .running, trayOpen: false), 1)
        // Idle machines should not harvest every probe tick — empty cadence is
        // already ~30s; multiplying ticks keeps the menu bar cheap.
        XCTAssertGreaterThan(ProbeSchedule.harvestEveryNTicks(activity: .empty, trayOpen: false), 1)
        XCTAssertEqual(ProbeSchedule.harvestEveryNTicks(activity: .empty, trayOpen: true), 1)
    }
}

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

final class HarvestSupervisorTests: XCTestCase {
    func testSupervisorBacksOffOnlyFailedAdapterAndRecovers() {
        var supervisor = HarvestSupervisor()
        let now: Int64 = 1_000
        let failed = ActivityHarvest.CollectorHealth(
            id: .cursor, state: .failed, durationMs: 6_000, rowCount: 0,
            sourcePresent: true, errorKind: "timeout"
        )
        supervisor.record([failed], nowMs: now)
        let plan = supervisor.plan(nowMs: now + 100, agents: [.cursor, .codex])
        XCTAssertFalse(plan.attempted.contains(.cursor))
        XCTAssertTrue(plan.attempted.contains(.codex))
        XCTAssertTrue(plan.deferred.contains(.cursor))
        supervisor.record([.init(id: .cursor, state: .observed, durationMs: 1, rowCount: 1, sourcePresent: true, errorKind: "")], nowMs: now + 2_000)
        XCTAssertEqual(supervisor.state(for: .cursor).consecutiveFailures, 0)
        XCTAssertTrue(supervisor.plan(nowMs: now + 2_001, agents: [.cursor]).attempted.contains(.cursor))
    }

    func testSupervisorOpensCircuitAfterThreeFailuresAndAllowsHalfOpenProbe() {
        var supervisor = HarvestSupervisor()
        let failed = ActivityHarvest.CollectorHealth(
            id: .amp, state: .failed, durationMs: 10, rowCount: 0,
            sourcePresent: true, errorKind: "locked"
        )
        for index in 0..<3 { supervisor.record([failed], nowMs: Int64(index * 10_000)) }
        let blocked = supervisor.plan(nowMs: 30_001, agents: [.amp, .codex])
        XCTAssertTrue(blocked.deferred.contains(.amp))
        XCTAssertTrue(blocked.attempted.contains(.codex))
        let probe = supervisor.plan(nowMs: 60_001, agents: [.amp])
        XCTAssertTrue(probe.attempted.contains(.amp))
    }

    @MainActor
    func testSupervisorDeferralDoesNotMakeHealthyPartialScanUnreliable() {
        var supervisor = HarvestSupervisor()
        let failure = ActivityHarvest.CollectorHealth(
            id: .amp, state: .failed, durationMs: 10, rowCount: 0,
            sourcePresent: true, errorKind: "locked"
        )
        supervisor.record([failure], nowMs: 1_000)
        let plan = supervisor.plan(nowMs: 1_100, agents: [.amp, .codex])
        let healthyCodex = ActivityHarvest.CollectorHealth(
            id: .codex, state: .observed, durationMs: 10, rowCount: 1,
            sourcePresent: true, errorKind: ""
        )

        XCTAssertTrue(
            ScanEngine.isIntentionalSupervisorPartial(
                health: [healthyCodex],
                plan: plan
            )
        )

        let failedCodex = ActivityHarvest.CollectorHealth(
            id: .codex, state: .failed, durationMs: 10, rowCount: 0,
            sourcePresent: true, errorKind: "timeout"
        )
        XCTAssertFalse(
            ScanEngine.isIntentionalSupervisorPartial(
                health: [failedCodex],
                plan: plan
            )
        )

        let store = StatusStore()
        store.engine.recordCollectorHealth([healthyCodex], complete: false, intentionalPartial: true)
        XCTAssertFalse(store.collectorScanIncomplete)
        store.engine.recordCollectorHealth([failedCodex], complete: false, intentionalPartial: false)
        XCTAssertTrue(store.collectorScanIncomplete)
    }

    func testSupervisorFailureTimelineOrdersNewestFirst() {
        var supervisor = HarvestSupervisor()
        let now: Int64 = 100_000
        supervisor.record(
            [
                .init(
                    id: .codex,
                    state: .failed,
                    durationMs: 10,
                    rowCount: 0,
                    sourcePresent: true,
                    errorKind: "locked"
                )
            ],
            nowMs: now
        )
        supervisor.record(
            [
                .init(
                    id: .claude,
                    state: .failed,
                    durationMs: 10,
                    rowCount: 0,
                    sourcePresent: true,
                    errorKind: "native_timeout"
                )
            ],
            nowMs: now + 5_000
        )
        let timeline = supervisor.failureTimeline(nowMs: now + 6_000)
        XCTAssertEqual(timeline.map(\.agent), [.claude, .codex])
        XCTAssertEqual(timeline.map(\.error), ["native_timeout", "locked"])
    }
}

/// Clarity fixes — each test pins one defect found by reading the code: the
/// value the user would have seen, before and after.
@MainActor
@Suite("Coalescing throttle", .serialized)
struct CoalescingThrottleTests {
    // MARK: - 15 · coalesced events get a trailing fire

    @Test func aCoalescedEventIsDeliveredAtTheEndOfTheWindow() {
        var throttle = CoalescingThrottle(window: 0.35)
        #expect(throttle.event(at: 10.0) == .fire)
        #expect(throttle.event(at: 10.1) == .armTrailing, "the second event used to be dropped")
        #expect(throttle.event(at: 10.2) == .absorbed)
        #expect(abs(throttle.trailingDelay(at: 10.2) - 0.2) < 0.001)
        throttle.trailingFired(at: 10.4)
        #expect(throttle.event(at: 10.5) == .armTrailing)
        #expect(throttle.event(at: 11.0) == .absorbed, "the armed trailing fire carries it")
        throttle.trailingFired(at: 11.0)
        #expect(throttle.event(at: 11.5) == .fire)
    }
}

/// 2.3 — the defects a fresh audit at the 2.2 baseline turned up.
///
/// Each of these is a place where the code said something it had not
/// measured, dropped work it had been asked to do, or let a click reach
/// nothing without saying so.
final class PendingRefreshTests: XCTestCase {
    // MARK: D-3 · a coalesced refresh keeps its scope

    @MainActor
    func testMergingTwoScopedRefreshesKeepsBoth() {
        var pending = ScanEngine.PendingRefresh(
            reason: "permission-cursor",
            agentFilter: [.cursor]
        )
        pending.absorb(reason: "permission-cline", agentFilter: [.cline])
        XCTAssertEqual(pending.agentFilter, [.cursor, .cline])
        XCTAssertEqual(pending.reason, "permission-cline")
    }

    @MainActor
    func testAFullScanAbsorbsAScopedOne() {
        var pending = ScanEngine.PendingRefresh(
            reason: "permission-cursor",
            agentFilter: [.cursor]
        )
        pending.absorb(reason: "timer", agentFilter: nil)
        XCTAssertNil(pending.agentFilter, "a full scan already covers the scoped one")

        var full = ScanEngine.PendingRefresh(reason: "timer", agentFilter: nil)
        full.absorb(reason: "permission-cursor", agentFilter: [.cursor])
        XCTAssertNil(full.agentFilter, "and narrowing it afterwards would drop the rest")
    }
}

/// 0.99 Quiet Data — what Pulse writes down, and whether it says so.
///
/// 0.90–0.97 made the display honest and 0.98 made the collector honest. These
/// cover the surface neither of them touched: the bytes that outlive the scan.
final class SupervisorBudgetTests: XCTestCase {
    // MARK: - Budget starvation leaves a trace

    /// 0.98 made the global cutoff rotate. The supervisor still treated
    /// `unscanned` as nothing at all, so a diagnostic could not show it.
    func testSupervisorRecordsBudgetCutoffWithoutCallingItAFailure() {
        var supervisor = HarvestSupervisor()
        let now: Int64 = 1_800_000_000_000
        supervisor.record([.unscanned(.zcode)], nowMs: now)

        let state = supervisor.state(for: .zcode)
        XCTAssertEqual(state.lastUnscannedAtMs, now)
        XCTAssertEqual(state.consecutiveFailures, 0, "a budget cutoff is not an adapter failure")
        XCTAssertFalse(state.isCircuitOpen)
        XCTAssertTrue(supervisor.summary(nowMs: now).contains("zcode"))
    }

    func testAnOldBudgetCutoffFallsOutOfTheSummary() {
        var supervisor = HarvestSupervisor()
        let now: Int64 = 1_800_000_000_000
        supervisor.record([.unscanned(.zcode)], nowMs: now - 60 * 60_000)
        XCTAssertFalse(supervisor.summary(nowMs: now).contains("zcode"))
    }
}
