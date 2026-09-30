import Foundation
import AppKit
import Observation
import Testing
import XCTest
@testable import PulseApp
@testable import PulseCore
@testable import PulseHarvest

// Engine: ScanEngine (the event feed and the projection), the tick and the
// process-scan cadence, scan quiet.

/// 12.4 Surface — a projection that found the same world wakes no surface.
///
/// 19.0: the store is `@Observable`. A view is invalidated by the properties
/// its body read, and Observation announces every assignment, equal or not.
/// This is the counter wall: track every observed property of the store,
/// project the same world twice, and nothing may fire. When it fails, it
/// names the property that did. 24.0: an event-free period is exactly that
/// — the tick re-projects with no event, and must announce nothing.
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
            ("hooksStatus", \StatusStore.hooksStatus),
            ("hotkeyRegistered", \StatusStore.hotkeyRegistered),
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
        // This test drives the engine itself.
        StatusStore()
    }

    /// A tick: the book re-projected with no event.
    private func tick(_ store: StatusStore, at nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        store.engine.project(nowMs: nowMs)
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

    @Test func aSecondIdenticalProjectionAnnouncesNothing() {
        let store = quietStore()
        tick(store)
        let fired = watch(store, Self.observed)

        tick(store)
        tick(store)

        #expect(fired.names == [], "observed properties written by an unchanged projection: \(fired.names)")
    }

    /// An event-free period with sessions on the list: the tick moves no
    /// observed property while nothing on screen is due to change.
    @Test func anEventFreePeriodPublishesNothing() {
        let store = quietStore()
        let t0 = Int64(Date().timeIntervalSince1970 * 1000)
        store.engine.apply(records: [
            AttentionRecord(agent: "claude", kind: "working", ms: t0 - 10 * 60_000, session: "s-quiet", cwd: "/w/app"),
        ], nowMs: t0)
        let fired = watch(store, Self.observed)
        tick(store, at: t0 + 2_000)
        tick(store, at: t0 + 4_000)
        #expect(fired.names == [], "\(fired.names)")
    }

    /// A wait that crossed while macOS had not yet allowed Pulse to notify
    /// is owed a banner once; the ticks after it change nothing a view
    /// draws, and owe it no second time.
    @Test func anOwedBannerWhileUnauthorizedIsOwedOnce() {
        let store = quietStore()
        store.notifyAuthorized = nil
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // The launch baseline: the attention file read once, empty.
        store.engine.landAttention(AttentionProtocol.header, nowMs: nowMs - 2_000)
        store.engine.apply(records: [
            AttentionRecord(agent: "claude", kind: "permission", ms: nowMs - 1_000, message: "Bash: npm test", session: "s-owed", cwd: "/w/app"),
        ], nowMs: nowMs)
        let owed = store.notifier.ledger.queuedKeys
        #expect(owed == ["claude|s-owed"], "the edge is owed its banner")
        // The snapshot moves (a wait under a minute is drawn in seconds);
        // the rows do not.
        let fired = watch(store, [("cachedAll", \StatusStore.cachedAll)])
        tick(store, at: nowMs + 1)
        tick(store, at: nowMs + 2)
        #expect(fired.names == [], "the same owed wait is not news: \(fired.names)")
        let still = store.notifier.ledger.queuedKeys
        #expect(still == owed)
    }

    /// A wait already in the attention file when Pulse starts is the
    /// baseline: it is on the list, and owed no banner.
    @Test func aWaitRaisedBeforeLaunchIsOwedNoBanner() {
        let store = quietStore()
        store.notifyAuthorized = nil
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let raise = AttentionRecord(agent: "claude", kind: "permission", ms: nowMs - 60_000, message: "Bash: make", session: "s-old", cwd: "/w/app")
        store.engine.landAttention(AttentionProtocol.header + raise.line + "\n", nowMs: nowMs)
        let blocked = store.cachedAll.first?.isBlocked
        #expect(blocked == true)
        let owed = store.notifier.ledger.queuedKeys
        #expect(owed.isEmpty)
    }

    @Test func aChangedWorldIsStillAnnounced() {
        let store = quietStore()
        tick(store)
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
        // The model stays small — the book, the watchers and banner
        // bookkeeping live in `ScanEngine` and `WaitNotifier`.
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
        var book = SessionBook()
        book.apply(AttentionRecord(agent: "claude", kind: "permission", ms: t0 - 10 * 60_000, message: "Bash: make", session: "s1", cwd: "/w", pid: 0), nowMs: t0)
        func project(at nowMs: Int64) -> PulseSnapshot {
            var snap = TrayState.project(
                book: book, processes: [], summaries: [:],
                context: TrayState.Context(nowMs: nowMs, lang: .en)
            ).snapshot
            snap.updatedAt = Date(timeIntervalSince1970: Double(nowMs) / 1000)
            return snap
        }
        let first = project(at: t0)
        let second = project(at: t0 + 2_000)
        #expect(second.sameContent(as: first), "a ten-minute wait two seconds later is the same world")
        #expect(!PulseSnapshot.needsPublish(next: second, current: first))
    }

    /// Only a wait's age is drawn in seconds; a running row's fresh activity
    /// is no reason to redraw every tick.
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
        row.state = .blocked(RowWait(kind: "Permission", sinceMs: Int64(t0.timeIntervalSince1970 * 1000) - 20_000))
        current.rows = [row]

        var next = current
        next.updatedAt = t0.addingTimeInterval(2)
        #expect(PulseSnapshot.needsPublish(next: next, current: current), "a 20 s wait is drawn in seconds — it moves every tick")

        current.rows[0].state = .blocked(RowWait(kind: "Permission", sinceMs: Int64(t0.timeIntervalSince1970 * 1000) - 600_000))
        next.rows = current.rows
        #expect(!PulseSnapshot.needsPublish(next: next, current: current), "a ten-minute wait holds for a minute")
        next.updatedAt = t0.addingTimeInterval(61)
        #expect(PulseSnapshot.needsPublish(next: next, current: current), "and moves once the minute turns")
    }
}

/// 24.0 · the engine's feed: the attention file is re-read whole, and only
/// the lines it has not seen reach the book.
@Suite("Event feed", .serialized)
@MainActor
struct EventFeedTests {
    private let t0 = Int64(Date().timeIntervalSince1970 * 1000)

    private func file(_ records: [AttentionRecord]) -> String {
        AttentionProtocol.header + records.map(\.line).joined(separator: "\n") + "\n"
    }

    @Test func aLineIsAppliedOnceHoweverOftenTheFileIsRead() {
        let store = StatusStore()
        let raise = AttentionRecord(agent: "claude", kind: "permission", ms: t0 - 60_000, message: "Bash: npm test", session: "s1", cwd: "/w/app")
        store.engine.landAttention(file([raise]), nowMs: t0)
        #expect(store.cachedAll.first?.isBlocked == true)
        // The person answers in the vendor's prompt: the tool runs.
        store.engine.apply(activity: [
            ActivitySpool.Event(agent: "claude", session: "s1", event: "tool", tool: "Bash", target: "", prompt: "", cwd: "/w/app", tsMs: t0 - 30_000),
        ], nowMs: t0)
        #expect(store.cachedAll.first?.state == .running)
        // The same file again must not raise the answered wait a second time.
        store.engine.landAttention(file([raise]), nowMs: t0 + 1_000)
        #expect(store.cachedAll.first?.state == .running, "a line already applied is not news")
    }

    @Test func aCompactedFileDoesNotReplayWhatItKept() {
        let store = StatusStore()
        let start = AttentionRecord(agent: "codex", kind: "start", ms: t0 - 120_000, session: "c1", cwd: "/w/app")
        let turn = AttentionRecord(agent: "codex", kind: "turn", ms: t0 - 60_000, session: "c1", cwd: "/w/app")
        store.engine.landAttention(file([start, turn]), nowMs: t0)
        #expect(store.cachedAll.first?.isYourTurn == true)
        // Compaction dropped the start; the turn is the same line, not a new one.
        store.engine.landAttention(file([turn]), nowMs: t0 + 1_000)
        #expect(store.cachedAll.first?.isYourTurn == true)
        #expect(store.engine.book.sessions.count == 1)
    }

    @Test func theLastEventPerAgentOutlivesCompaction() {
        let store = StatusStore()
        let early = AttentionRecord(agent: "gemini", kind: "turn", ms: t0 - 60_000, session: "g1")
        store.engine.landAttention(file([early]), nowMs: t0)
        store.engine.landAttention(file([]), nowMs: t0 + 1_000)
        #expect(store.engine.latestHookEventMs[.gemini] == t0 - 60_000)
    }

    /// Settings' "last event" counts activity events too, and remembers
    /// them past the attention file's 80 lines.
    @Test func anActivityEventIsAHookEventToo() {
        let store = StatusStore()
        store.engine.apply(activity: [
            ActivitySpool.Event(agent: "claude", session: "s1", event: "tool", tool: "Read", target: "", prompt: "", cwd: "/w", tsMs: t0 - 5_000),
        ], nowMs: t0)
        #expect(store.engine.latestHookEventMs[.claude] == t0 - 5_000)
    }

    /// A turn held inside a block's grace lands on the tick, with no event
    /// after it (a denied prompt).
    @Test func aHeldTurnLandsOnTheTick() {
        let store = StatusStore()
        let raise = AttentionRecord(agent: "gemini", kind: "permission", ms: t0 - 10_000, message: "Allow?", session: "g1", cwd: "/w/app")
        let turn = AttentionRecord(agent: "gemini", kind: "turn", ms: t0 - 7_000, session: "g1", cwd: "/w/app")
        store.engine.landAttention(file([raise, turn]), nowMs: t0)
        #expect(store.cachedAll.first?.isBlocked == true, "inside the grace")
        store.engine.project(nowMs: t0 + 15_000)
        #expect(store.cachedAll.first?.isYourTurn == true, "the tick lands the held turn")
    }

    @Test func aProcessScanThatFailsKeepsTheLastGoodList() {
        let store = StatusStore()
        let hit = AgentProcesses.Hit(agent: .codex, pid: 999_999, cwd: "/w/app")
        store.engine.apply(processes: [hit], nowMs: t0)
        #expect(store.cachedAll.map(\.rowKey) == ["codex|pid:999999"])
        store.engine.apply(processes: nil, nowMs: t0 + 1_000)
        #expect(store.cachedAll.map(\.rowKey) == ["codex|pid:999999"], "a failed read never removes a row")
    }

    @Test func anExitEndsTheSessionAndDropsTheProcess() {
        let store = StatusStore()
        let hit = AgentProcesses.Hit(agent: .claude, pid: 999_998, cwd: "/w/app")
        store.engine.apply(processes: [hit], nowMs: t0)
        store.engine.processExited(999_998, nowMs: t0 + 1_000)
        #expect(store.cachedAll.isEmpty)
    }

    /// A transcript is read at the moments a person looks: a finished turn
    /// or a wait — never while it works, and never without a path.
    @Test func aTranscriptIsWantedOnlyAtATurnOrAWait() {
        func session(_ state: SessionBook.State, transcript: String = "/t.jsonl") -> SessionBook.Session {
            var s = SessionBook.Session(key: "claude|s1", agent: .claude, session: "s1")
            s.state = state
            s.transcript = transcript
            s.pid = 42
            s.lastEventMs = t0
            return s
        }
        #expect(ScanEngine.wantsTranscript(session(.yourTurn(sinceMs: t0)), nowMs: t0))
        #expect(ScanEngine.wantsTranscript(session(.blocked(.init(kind: .permission, ask: "", sinceMs: t0, inFront: false))), nowMs: t0))
        #expect(!ScanEngine.wantsTranscript(session(.working), nowMs: t0))
        #expect(!ScanEngine.wantsTranscript(session(.yourTurn(sinceMs: t0), transcript: ""), nowMs: t0))
    }
}

/// 24.0 cadence policy — no fixed probe interval: a tick for time-based
/// facts, a slow process scan, nothing while the display sleeps.
final class ProbeScheduleTests: XCTestCase {
    private let awake = ProbeSchedule.Power()

    func testNothingOnScreenMeansNoTick() {
        XCTAssertNil(ProbeSchedule.tick(activity: .empty, power: awake, trayOpen: false))
        XCTAssertNotNil(ProbeSchedule.tick(activity: .empty, power: awake, trayOpen: true))
    }

    func testTheTickIsAMinuteUnlessSecondsAreOnScreen() {
        XCTAssertEqual(ProbeSchedule.tick(activity: .running, power: awake, trayOpen: false), 60)
        XCTAssertEqual(ProbeSchedule.tick(activity: .waiting, power: awake, trayOpen: false), 60)
        XCTAssertEqual(ProbeSchedule.tick(activity: .waiting, power: awake, trayOpen: false, freshWait: true), 5)
        XCTAssertEqual(ProbeSchedule.tick(activity: .recent, power: awake, trayOpen: true), 5)
    }

    func testDisplayAsleepParksEverythingUnlessTheTrayIsOpen() {
        var power = ProbeSchedule.Power()
        power.displayAsleep = true
        XCTAssertNil(ProbeSchedule.tick(activity: .waiting, power: power, trayOpen: false))
        XCTAssertNotNil(ProbeSchedule.tick(activity: .waiting, power: power, trayOpen: true))
        XCTAssertNil(ProbeSchedule.processScan(power: power))
    }

    func testLockedScreenParksToo() {
        var power = ProbeSchedule.Power()
        power.screenLocked = true
        XCTAssertNil(ProbeSchedule.tick(activity: .running, power: power, trayOpen: false))
        XCTAssertNil(ProbeSchedule.processScan(power: power))
    }

    func testLowPowerModeSlowsBoth() {
        var power = ProbeSchedule.Power()
        power.lowPowerMode = true
        XCTAssertGreaterThan(
            ProbeSchedule.tick(activity: .running, power: power, trayOpen: false)!,
            ProbeSchedule.tick(activity: .running, power: awake, trayOpen: false)!
        )
        XCTAssertGreaterThan(ProbeSchedule.processScan(power: power)!, ProbeSchedule.processScan(power: awake)!)
    }

    func testTheProcessScanIsSlow() {
        XCTAssertEqual(ProbeSchedule.processScan(power: awake), 30)
    }

    /// 24.0: a scan that finds the same processes backs the next one off,
    /// 30 s → 5 min; any change brings it back to 30 s.
    func testTheProcessScanBacksOffWhileNothingChanges() {
        XCTAssertEqual(ProbeSchedule.processScan(power: awake, quietScans: 1), 60)
        XCTAssertEqual(ProbeSchedule.processScan(power: awake, quietScans: 3), 240)
        XCTAssertEqual(ProbeSchedule.processScan(power: awake, quietScans: 4), ProbeSchedule.processScanMaxSeconds)
        XCTAssertEqual(ProbeSchedule.processScan(power: awake, quietScans: 50), ProbeSchedule.processScanMaxSeconds)
        var lowPower = ProbeSchedule.Power()
        lowPower.lowPowerMode = true
        XCTAssertEqual(ProbeSchedule.processScan(power: lowPower, quietScans: 4), ProbeSchedule.processScanMaxSeconds, "never past the cap")
        XCTAssertEqual(ProbeSchedule.nextQuietScans(0, same: true), 1)
        XCTAssertEqual(ProbeSchedule.nextQuietScans(3, same: true), 4)
        XCTAssertEqual(ProbeSchedule.nextQuietScans(3, same: false), 0)
    }
}

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
