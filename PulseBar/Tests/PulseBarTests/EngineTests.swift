import Foundation
import AppKit
import Observation
import Testing
import XCTest
@testable import PulseApp
@testable import PulseKit

// Engine: ScanEngine (the event feed and the projection), the tick and the
// process-scan cadence, scan quiet.

/// Surface — a projection that found the same world wakes no surface.
///
/// The store is `@Observable`. A view is invalidated by the properties
/// its body read, and Observation announces every assignment, equal or not.
/// This is the counter wall: track every observed property of the store,
/// project the same world twice, and nothing may fire. When it fails, it
/// names the property that did. An event-free period is exactly that — the
/// tick re-projects with no event, and must announce nothing.
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
            ("rows", \StatusStore.rows),
            ("hooksStatus", \StatusStore.hooksStatus),
            ("loginItem", \StatusStore.loginItem),
            ("notifyAuthorized", \StatusStore.notifyAuthorized),
            ("presentAgents", \StatusStore.presentAgents),
            ("rowActionNotices", \StatusStore.rowActionNotices),
            ("settings", \StatusStore.settings),
            ("settingsFocus", \StatusStore.settingsFocus),
            ("setupConnected", \StatusStore.setupConnected),
            ("snapshot", \StatusStore.snapshot),
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
            AttentionRecord(agent: .claude, kind: .working, ms: t0 - 10 * 60_000, session: "s-quiet", cwd: "/w/app"),
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
        // The launch baseline: the event log replayed once, empty.
        store.engine.landLog(.empty, nowMs: nowMs - 2_000)
        store.engine.apply(records: [
            AttentionRecord(agent: .claude, kind: .permission, ms: nowMs - 1_000, message: "Bash: npm test", session: "s-owed", cwd: "/w/app"),
        ], nowMs: nowMs)
        let owed = store.notifier.ledger.queuedKeys
        #expect(owed == [SessionKey(.claude, "s-owed")], "the edge is owed its banner")
        let fired = watch(store, Self.observed)
        tick(store, at: nowMs + 1)
        tick(store, at: nowMs + 2)
        #expect(fired.names == [], "the same owed wait is not news: \(fired.names)")
        let still = store.notifier.ledger.queuedKeys
        #expect(still == owed)
    }

    /// A wait already in the event log when Pulse starts is the baseline:
    /// the replay puts it on the list, and it is owed no banner.
    @Test func aWaitRaisedBeforeLaunchIsOwedNoBanner() {
        let store = quietStore()
        store.notifyAuthorized = nil
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let raise = AttentionRecord(agent: .claude, kind: .permission, ms: nowMs - 60_000, message: "Bash: make", session: "s-old", cwd: "/w/app", seq: 1)
        store.engine.landLog(EventLog.Chunk(header: AttentionProtocol.Header(next: 2, gen: "g"), records: [raise], end: 100), nowMs: nowMs)
        let blocked = store.rows.first?.isBlocked
        #expect(blocked == true)
        let owed = store.notifier.ledger.queuedKeys
        #expect(owed.isEmpty)
    }

    /// A burst of tool lines in a running session moves the book's facts
    /// — its steps, its clocks — and no observed property: nothing lands. The
    /// newest step is read from the book when the row is drawn. A line that
    /// changes a state — a block — lands at once.
    @Test func aBurstOfToolLinesAnnouncesNothing() {
        let store = quietStore()
        store.engine.setTrayOpen(true)
        let t0 = Int64(Date().timeIntervalSince1970 * 1000)
        store.engine.apply(records: [
            AttentionRecord(agent: .claude, kind: .working, ms: t0, message: "Fix it", session: "s-burst", cwd: "/w/app"),
        ], nowMs: t0)
        let fired = watch(store, Self.observed)
        for index in 0..<20 {
            let ms = t0 + 100 + Int64(index) * 50
            store.engine.apply(records: [
                AttentionRecord(agent: .claude, kind: .tool, ms: ms, message: "file\(index).swift", session: "s-burst", cwd: "/w/app", tool: "Read"),
            ], nowMs: ms)
        }
        #expect(fired.names == [], "a burst of steps is not news: \(fired.names)")
        let key = SessionKey(.claude, "s-burst")
        let step = store.facts(for: key).lastStep
        #expect(step?.target == "file19.swift", "the newest step, read from the book")
        let row = store.rows.first
        let face = row.map { store.trayRowModel($0) }
        #expect(face?.secondLine?.text.hasPrefix("Read · file19.swift") == true, "the row draws it")
        store.engine.apply(records: [
            AttentionRecord(agent: .claude, kind: .permission, ms: t0 + 5_100, message: "Bash: make", session: "s-burst", cwd: "/w/app", tool: "Bash"),
        ], nowMs: t0 + 5_100)
        #expect(fired.names.contains("rows"), "a block is state")
        let blocked = store.rows.first?.isBlocked
        #expect(blocked == true)
    }

    @Test func aChangedWorldIsStillAnnounced() {
        let store = quietStore()
        tick(store)
        let fired = watch(store, Self.observed)
        var next = store.snapshot
        next.title = "1"
        store.snapshot = next
        #expect(fired.names == ["snapshot"], "only what changed, and nothing else: \(fired.names)")
    }

    /// The generated source of `@Observable` lists the tracked properties;
    /// this reads the class's own stored properties and fails on one that is
    /// observed but missing from `observed`, so the wall above cannot go
    /// quietly partial.
    @Test func everyObservedPropertyIsListed() throws {
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
        store.settings.hooksNudgeOff = true
        #expect(fired.names == ["settings"], "\(fired.names)")
    }

    /// Setting a value to what it already is writes nothing.
    @Test func anUnchangedSettingWritesNothing() {
        let store = quietStore()
        let fired = watch(store, Self.observed)
        store.set(\.hooksNudgeOff, false)
        #expect(fired.names == [])
    }

    // MARK: - The status item

    @Test func theStatusItemLoopFollowsTheSnapshotOnly() async {
        let store = quietStore()
        let loop = ObservationLoop(track: { _ = store.snapshot }, onChange: {})
        defer { loop.cancel() }

        store.settings.hooksNudgeOff.toggle()
        store.waitingBannerFailed.toggle()
        for _ in 0..<10 { await Task.yield() }
        #expect(loop.deliveries == 0, "a settings write does not touch the lamp")

        var next = store.snapshot
        next.title = "2"
        store.snapshot = next
        next.title = "3"
        store.snapshot = next
        for _ in 0..<10 where loop.deliveries == 0 { await Task.yield() }
        #expect(loop.deliveries == 1, "a burst in one turn is one delivery")

        next.title = "4"
        store.snapshot = next
        for _ in 0..<10 where loop.deliveries == 1 { await Task.yield() }
        #expect(loop.deliveries == 2, "and the loop re-arms")
    }

    // MARK: - The same world

    /// A standing wait: two projections seconds apart are equal — rows and
    /// glance — so nothing lands; the glance moves when the menu-bar title's
    /// minute turns, and the rows carry no clock at all.
    @Test func aStandingWaitMovesOnlyWhenItsMinuteTurns() {
        let t0: Int64 = 1_800_000_000_000
        var book = SessionBook()
        book.apply(AttentionRecord(agent: .claude, kind: .permission, ms: t0 - 10 * 60_000, message: "Bash: make", session: "s1", cwd: "/w", pid: 0), nowMs: t0)
        func project(at nowMs: Int64) -> TrayState {
            TrayState.project(book: book, processes: [], context: TrayState.Context(nowMs: nowMs, lang: .en))
        }
        let first = project(at: t0)
        let second = project(at: t0 + 2_000)
        let later = project(at: t0 + 61_000)
        #expect(second.snapshot == first.snapshot, "a ten-minute wait two seconds later is the same world")
        #expect(second.rows == first.rows)
        #expect(later.snapshot.title != first.snapshot.title, "the title's age moves with its minute")
        #expect(later.rows == first.rows, "the rows carry no clock")
    }
}

/// The engine's feed: the event log replayed whole at launch, then read
/// from its cursor; a line is applied once, by its number.
@Suite("Event feed", .serialized)
@MainActor
struct EventFeedTests {
    private let t0 = Int64(Date().timeIntervalSince1970 * 1000)

    /// A read of one log (`gen`) holding these records.
    private func chunk(_ records: [AttentionRecord], gen: String = "g1", next: Int64? = nil, end: Int = 4_096) -> EventLog.Chunk {
        let header = AttentionProtocol.Header(next: next ?? (records.map(\.seq).max() ?? 0) + 1, gen: gen)
        return EventLog.Chunk(header: header, records: records, end: end)
    }

    /// Records numbered from `first`, as a log holds them.
    private func numbered(_ records: [AttentionRecord], from first: Int64 = 1) -> [AttentionRecord] {
        records.enumerated().map { index, record in
            var copy = record
            copy.seq = first + Int64(index)
            return copy
        }
    }

    private func tool(_ name: String, _ ms: Int64, session: String = "s1", seq: Int64 = 0) -> AttentionRecord {
        AttentionRecord(agent: .claude, kind: .tool, ms: ms, session: session, cwd: "/w/app", tool: name, seq: seq)
    }

    private func raise(_ ms: Int64, seq: Int64 = 1) -> AttentionRecord {
        AttentionRecord(agent: .claude, kind: .permission, ms: ms, message: "Bash: npm test", session: "s1", cwd: "/w/app", tool: "Bash", seq: seq)
    }

    @Test func aRewrittenLogDoesNotReapplyWhatItKept() {
        let store = StatusStore()
        let block = raise(t0 - 60_000)
        store.engine.landLog(chunk([block], end: 100), nowMs: t0)
        #expect(store.rows.first?.isBlocked == true)
        // The person answers in the vendor's prompt: the tool runs.
        let answer = tool("Bash", t0 - 30_000, seq: 2)
        store.engine.landLog(chunk([answer], end: 200), nowMs: t0)
        #expect(store.rows.first?.isRunning == true)
        // A compaction rewrote the log (the same `gen`, a new header) and
        // kept both: the block is not raised a second time.
        store.engine.landLog(chunk([block, answer], next: 9, end: 150), nowMs: t0 + 1_000)
        #expect(store.rows.first?.isRunning == true, "a line already applied is not news")
        #expect(store.engine.logCursor?.seq == 2)
        #expect(store.engine.logCursor?.offset == 150)
    }

    /// A failed read, or one that found no log, never resets what was
    /// applied — the next read of the same log does not replay an answered
    /// block.
    @Test func aFailedOrEmptyReadKeepsWhatWasApplied() {
        let store = StatusStore()
        let records = [raise(t0 - 60_000), tool("Bash", t0 - 30_000, seq: 2)]
        store.engine.landLog(chunk(records), nowMs: t0)
        #expect(store.rows.first?.isRunning == true)
        let cursor = store.engine.logCursor
        store.engine.logReadFailed()
        store.engine.landLog(.empty, nowMs: t0 + 500)
        #expect(store.engine.logCursor == cursor, "no log there moves nothing")
        // The whole log read again.
        store.engine.landLog(chunk(records), nowMs: t0 + 1_000)
        #expect(store.rows.first?.isRunning == true, "the answered block stays answered")
    }

    /// Approved, a long turn of tools, then a relaunch. The new engine
    /// replays the whole log before it projects: not red, and no banner owed
    /// for anything.
    @Test func aRelaunchReplaysTheLogAndIsNotRed() {
        var records = [
            AttentionRecord(agent: .claude, kind: .working, ms: t0 - 50 * 60_000, session: "s1", cwd: "/w/app"),
            raise(t0 - 49 * 60_000),
            tool("Bash", t0 - 48 * 60_000),
        ]
        for minute in 0..<40 { records.append(tool(minute % 2 == 0 ? "Read" : "Edit", t0 - Int64(47 - minute) * 60_000)) }
        records.append(AttentionRecord(agent: .claude, kind: .turn, ms: t0 - 60_000, session: "s1", cwd: "/w/app"))
        let relaunched = StatusStore()
        relaunched.notifyAuthorized = nil
        relaunched.engine.landLog(chunk(numbered(records)), nowMs: t0)
        let row = relaunched.rows.first
        #expect(row?.isBlocked == false)
        #expect(row?.isYourTurn == true)
        #expect(relaunched.snapshot.lamp != .waiting)
        let owed = relaunched.notifier.ledger.queuedKeys
        #expect(owed.isEmpty)
    }

    /// Parallel tools written before the answering one, all in one read —
    /// every line is applied, the answer too.
    @Test func parallelToolsBeforeTheAnswerInOneRead() {
        let store = StatusStore()
        store.engine.landLog(chunk([raise(t0 - 10_000)]), nowMs: t0)
        let tools = numbered([tool("Read", t0 - 9_000), tool("Grep", t0 - 8_500), tool("Bash", t0 - 8_000), tool("Read", t0 - 7_900)], from: 2)
        store.engine.landLog(chunk(tools), nowMs: t0)
        #expect(store.rows.first?.isRunning == true)
    }

    @Test func theLastEventPerAgentIsKept() {
        let store = StatusStore()
        let early = AttentionRecord(agent: .copilot, kind: .turn, ms: t0 - 60_000, session: "g1", seq: 1)
        store.engine.landLog(chunk([early]), nowMs: t0)
        store.engine.landLog(chunk([], gen: "g2"), nowMs: t0 + 1_000)
        #expect(store.engine.latestHookEventMs[.copilot] == t0 - 60_000)
        // A dismissal is Pulse's own line, not the agent speaking.
        store.engine.apply(records: [AttentionRecord(agent: .copilot, kind: .dismiss, ms: t0, session: "g1")], nowMs: t0)
        #expect(store.engine.latestHookEventMs[.copilot] == t0 - 60_000)
        // An ignored line is: the hook ran.
        store.engine.apply(records: [AttentionRecord(agent: .copilot, kind: .ignored, ms: t0 + 500, message: "not an installed event")], nowMs: t0 + 1_000)
        #expect(store.engine.latestHookEventMs[.copilot] == t0 + 500)
    }

    /// Settings' "last event" counts tool lines too.
    @Test func aToolLineIsAHookEventToo() {
        let store = StatusStore()
        store.engine.apply(records: [tool("Read", t0 - 5_000)], nowMs: t0)
        #expect(store.engine.latestHookEventMs[.claude] == t0 - 5_000)
    }

    /// A turn held inside a block's grace lands on the tick, with no event
    /// after it (a denied prompt).
    @Test func aHeldTurnLandsOnTheTick() {
        let store = StatusStore()
        let records = numbered([
            AttentionRecord(agent: .copilot, kind: .permission, ms: t0 - 10_000, message: "Allow?", session: "g1", cwd: "/w/app"),
            AttentionRecord(agent: .copilot, kind: .turn, ms: t0 - 7_000, session: "g1", cwd: "/w/app"),
        ])
        store.engine.landLog(chunk(records), nowMs: t0)
        #expect(store.rows.first?.isBlocked == true, "inside the grace")
        store.engine.project(nowMs: t0 + 15_000)
        #expect(store.rows.first?.isYourTurn == true, "the tick lands the held turn")
    }

    @Test func aProcessScanThatFailsKeepsTheLastGoodList() {
        let store = StatusStore()
        let hit = AgentProcesses.Hit(agent: .codex, pid: 999_999, cwd: "/w/app")
        store.engine.apply(processes: [hit], nowMs: t0)
        let found = store.rows.map { $0.key }
        #expect(found == [.process(.codex, pid: 999_999)])
        store.engine.apply(processes: nil, nowMs: t0 + 1_000)
        let kept = store.rows.map { $0.key }
        #expect(kept == [.process(.codex, pid: 999_999)], "a failed read never removes a row")
    }

    @Test func anExitEndsTheSessionAndDropsTheProcess() {
        let store = StatusStore()
        let hit = AgentProcesses.Hit(agent: .claude, pid: 999_998, cwd: "/w/app")
        store.engine.apply(processes: [hit], nowMs: t0)
        store.engine.processExited(999_998, nowMs: t0 + 1_000)
        #expect(store.rows.isEmpty)
    }

    /// A launch replay that found the log empty (or missing) is over: the
    /// first wait written after it is news, owed its banner.
    @Test func aWaitWrittenAfterAnEmptyReplayIsNews() {
        let store = StatusStore()
        store.notifyAuthorized = nil
        store.engine.landLog(.empty, nowMs: t0)
        store.engine.landLog(chunk([raise(t0 + 500)]), nowMs: t0 + 1_000)
        let owed = store.notifier.ledger.queuedKeys
        #expect(owed == [SessionKey(.claude, "s1")])
    }

    /// A failed read at launch lifts the hold but does not use up the
    /// baseline: the replay, when a read finally lands, is still the
    /// baseline — its old waits are owed no banner.
    @Test func aFailedLaunchReadLeavesTheReplayAsTheBaseline() {
        let store = StatusStore()
        store.notifyAuthorized = nil
        store.engine.logReadFailed()
        store.engine.landLog(chunk([raise(t0 - 60_000)]), nowMs: t0)
        #expect(store.rows.first?.isBlocked == true)
        let owed = store.notifier.ledger.queuedKeys
        #expect(owed.isEmpty)
    }

    /// One retry at a time, each waiting twice as long as the last: 5 s,
    /// 10 s, 20 s, 40 s, then a minute.
    @Test func aFailedReadIsRetriedWithBackoff() {
        var delay = ScanEngine.firstLogRetry
        var waits: [Duration] = []
        for _ in 0..<6 {
            waits.append(delay)
            delay = ScanEngine.nextLogRetry(after: delay)
        }
        #expect(waits == [.seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(60), .seconds(60)])
    }

    /// A line is identified by its number, not its text: the same text
    /// under a new number is applied again; a kept line is not.
    @Test func theSameTextUnderANewNumberIsApplied() {
        let store = StatusStore()
        let key = SessionKey(.claude, "s1")
        let first = tool("Read", t0 - 3_000, seq: 1)
        store.engine.landLog(chunk([first]), nowMs: t0)
        let steps = store.engine.book.sessions[key]?.steps.count
        #expect(steps == 1)
        // A compaction kept the line and the same text was appended again.
        var again = first
        again.seq = 2
        store.engine.landLog(chunk([first, again], next: 3), nowMs: t0 + 1_000)
        let after = store.engine.book.sessions[key]?.steps.count
        #expect(after == 2)
    }

    // MARK: - A line is applied once

    /// A temporary folder of this test's own: an explicit log, never a
    /// global override (suites run in parallel).
    final class Home {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("pulse-feed-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        var log: URL { url.appendingPathComponent(EventLog.fileName) }
    }

    /// Until no event read is in flight or asked for.
    private func settle(_ store: StatusStore) async throws {
        for _ in 0..<500 where store.engine.eventReadPending {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pending = store.engine.eventReadPending
        #expect(!pending, "the reads never landed")
    }

    /// The watcher fires again while a read is in flight (a burst of tool
    /// lines): no line is applied twice — a step is not doubled, an answered
    /// block is not raised again.
    @Test func aReReadAskedForDuringAReadAppliesNothingTwice() async throws {
        let home = Home()
        defer { withExtendedLifetime(home) {} }
        let log = home.log
        let store = StatusStore()
        store.engine.readLog = { EventLog.read(at: log, after: $0) }
        let now = ScanEngine.nowMs()
        EventLog.append(AttentionRecord(agent: .claude, kind: .working, ms: now - 5_000, message: "Fix it", session: "s1", cwd: "/w/app"), at: log, nowMs: now)
        store.engine.readEvents()
        try await settle(store)
        for index in 0..<3 {
            EventLog.append(tool("Read", now - 4_000 + Int64(index)), at: log, nowMs: now)
        }
        store.engine.readEvents()
        store.engine.readEvents()
        try await settle(store)
        let steps = store.engine.book.sessions[SessionKey(.claude, "s1")]?.steps.count
        #expect(steps == 3, "each tool line is one step")
    }

    /// A chunk read from a cursor the engine has since moved past applies
    /// only the lines numbered past it.
    @Test func aChunkReadBehindTheCursorAppliesOnlyWhatIsNew() throws {
        let home = Home()
        let now = ScanEngine.nowMs()
        let store = StatusStore()
        EventLog.append(AttentionRecord(agent: .claude, kind: .working, ms: now - 5_000, message: "Fix it", session: "s1", cwd: "/w/app"), at: home.log, nowMs: now)
        let first = try #require(EventLog.read(at: home.log, after: nil))
        store.engine.landLog(first, nowMs: now)
        let cursor = store.engine.logCursor
        EventLog.append(tool("Read", now - 4_000), at: home.log, nowMs: now)
        EventLog.append(tool("Grep", now - 3_900), at: home.log, nowMs: now)
        let early = try #require(EventLog.read(at: home.log, after: cursor))
        EventLog.append(tool("Edit", now - 3_800), at: home.log, nowMs: now)
        // Read from the same cursor: it holds the two lines above again.
        let late = try #require(EventLog.read(at: home.log, after: cursor))
        #expect(late.records.count == 3)
        store.engine.landLog(early, nowMs: now)
        store.engine.landLog(late, nowMs: now)
        let tools = store.engine.book.sessions[SessionKey(.claude, "s1")]?.steps.map(\.tool)
        #expect(tools == ["Read", "Grep", "Edit"])
    }
}

/// End to end, for each of the six agents: the vendor's own hook payload
/// → `pulse-hook` writes its line to an event log (a file of the test's
/// own) → the engine reads it after its cursor and applies it → the lamp →
/// the banner owed → the vendor's answer → the lamp goes out and the banner
/// is withdrawn. Codex and Cursor cannot say they wait: a
/// PermissionRequest-like payload never turns them red.
@Suite("Hook to banner", .serialized)
@MainActor
struct HookToBannerTests {
    typealias Event = (name: String, payload: String)

    struct Case {
        var agent: AgentID
        var session: String
        /// What happens before the ask.
        var before: [Event]
        /// The ask — for an agent that cannot block, what would be one.
        var ask: [Event]
        /// Events after the ask that are not its answer.
        var noise: [Event] = []
        /// The vendor's answer (for an agent that cannot block, its turn).
        var answer: Event
    }

    static let cases: [Case] = [
        Case(
            agent: .claude, session: "c1",
            before: [
                ("SessionStart", #"{"session_id":"c1","cwd":"/w/app","hook_event_name":"SessionStart","source":"startup"}"#),
                ("UserPromptSubmit", #"{"session_id":"c1","cwd":"/w/app","hook_event_name":"UserPromptSubmit","prompt":"Run the tests"}"#),
            ],
            ask: [("PermissionRequest", #"{"session_id":"c1","cwd":"/w/app","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm test"}}"#)],
            noise: [("Notification", #"{"session_id":"c1","cwd":"/w/app","hook_event_name":"Notification","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}"#)],
            answer: ("PostToolUse", #"{"session_id":"c1","cwd":"/w/app","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"npm test"}}"#)
        ),
        Case(
            agent: .copilot, session: "cp1",
            before: [("userPromptSubmitted", #"{"sessionId":"cp1","cwd":"/w/app","prompt":"Run the tests"}"#)],
            ask: [("notification", #"{"sessionId":"cp1","cwd":"/w/app","hook_event_name":"Notification","message":"Allow bash?","notification_type":"permission_prompt"}"#)],
            noise: [("errorOccurred", #"{"sessionId":"cp1","cwd":"/w/app","recoverable":true,"error":{"message":"Rate limited"}}"#)],
            answer: ("postToolUse", #"{"sessionId":"cp1","cwd":"/w/app","toolName":"bash","toolArgs":"{\"command\":\"npm test\"}"}"#)
        ),
        Case(
            agent: .opencode, session: "ses_1",
            before: [("session.created", #"{"sessionID":"ses_1","directory":"/w/app"}"#)],
            ask: [("permission.asked", #"{"sessionID":"ses_1","directory":"/w/app","permission":"bash","patterns":["npm test"]}"#)],
            noise: [("session.status", #"{"sessionID":"ses_1","directory":"/w/app","status":{"type":"busy"}}"#)],
            answer: ("permission.replied", #"{"sessionID":"ses_1","directory":"/w/app"}"#)
        ),
        Case(
            agent: .pi, session: "p1",
            before: [
                ("session_start", #"{"session_id":"p1","cwd":"/w/app"}"#),
                ("agent_start", #"{"session_id":"p1","cwd":"/w/app"}"#),
                ("message_start", #"{"session_id":"p1","cwd":"/w/app","prompt":"Clean the build"}"#),
            ],
            ask: [("ui_prompt_start", #"{"session_id":"p1","cwd":"/w/app","kind":"confirm","title":"Allow rm -rf build?"}"#)],
            answer: ("ui_prompt_end", #"{"session_id":"p1","cwd":"/w/app","kind":"confirm","title":"Allow rm -rf build?"}"#)
        ),
        Case(
            agent: .codex, session: "x1",
            before: [("UserPromptSubmit", #"{"session_id":"x1","cwd":"/w/app","hook_event_name":"UserPromptSubmit","prompt":"Add a retry"}"#)],
            ask: [
                ("PermissionRequest", #"{"session_id":"x1","cwd":"/w/app","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#),
            ],
            answer: ("Stop", #"{"session_id":"x1","cwd":"/w/app","hook_event_name":"Stop","last_assistant_message":"Done."}"#)
        ),
        Case(
            agent: .cursor, session: "cu1",
            before: [
                ("sessionStart", #"{"conversation_id":"cu1","workspace_roots":["/w/app"],"hook_event_name":"sessionStart"}"#),
                ("afterAgentResponse", #"{"conversation_id":"cu1","workspace_roots":["/w/app"],"hook_event_name":"afterAgentResponse","text":"Looking"}"#),
            ],
            ask: [
                ("beforeShellExecution", #"{"conversation_id":"cu1","workspace_roots":["/w/app"],"hook_event_name":"beforeShellExecution","command":"rm -rf build"}"#),
                ("beforeMCPExecution", #"{"conversation_id":"cu1","workspace_roots":["/w/app"],"hook_event_name":"beforeMCPExecution","tool_name":"deploy"}"#),
            ],
            answer: ("stop", #"{"conversation_id":"cu1","workspace_roots":["/w/app"],"hook_event_name":"stop","status":"completed"}"#)
        ),
    ]

    /// Banner ids the notifier withdrew.
    final class Withdrawn {
        var ids: [String] = []
    }

    /// One hook event, as the installed hook runs it: the two modules pass
    /// their payload as the last argument, the rest pipe it on stdin.
    private func deliver(_ agent: AgentID, _ event: Event, log: URL, at ms: Int64) {
        var arguments = ["PulseBar", "--hook", agent.rawValue, event.name]
        var stdin = event.payload
        if agent == .opencode || agent == .pi {
            arguments.append(event.payload)
            stdin = ""
        }
        PulseHookReceiver.run(
            arguments: arguments, stdin: stdin, logURL: log, nowMs: ms,
            locate: { _, _ in (0, "") }, front: { false }
        )
    }

    /// What the watcher does: read after the engine's cursor, land it.
    private func land(_ store: StatusStore, log: URL, at ms: Int64) {
        let chunk = EventLog.read(at: log, after: store.engine.logCursor)
        #expect(chunk != nil, "the log could not be read")
        if let chunk { store.engine.landLog(chunk, nowMs: ms) }
    }

    @Test func everyAgentFromItsHookToTheBannerAndBack() throws {
        let covered = Set(Self.cases.map(\.agent))
        #expect(covered == Set(AgentID.allCases), "every agent of the roster")
        for item in Self.cases {
            let name = item.agent.rawValue
            let home = EventFeedTests.Home()
            defer { withExtendedLifetime(home) {} }
            let log = home.log
            let store = StatusStore()
            store.notifyAuthorized = nil
            let withdrawn = Withdrawn()
            store.notifier.withdrawBanners = { withdrawn.ids += $0 }
            var ms = ScanEngine.nowMs() - 60_000
            // The launch replay: nothing in the log yet.
            land(store, log: log, at: ms)
            for event in item.before {
                ms += 1_000
                deliver(item.agent, event, log: log, at: ms)
                land(store, log: log, at: ms)
            }
            for event in item.ask {
                ms += 1_000
                deliver(item.agent, event, log: log, at: ms)
                land(store, log: log, at: ms)
            }
            let key = SessionKey(item.agent, item.session, cwd: "/w/app")
            let listed = store.rows.contains { $0.key == key }
            #expect(listed, "\(name): its session is a row")
            if item.agent.waitingSource == .none {
                let glance = store.snapshot.lamp
                #expect(glance != .waiting, "\(name) never reports a wait")
                let owed = store.notifier.ledger.queuedKeys
                #expect(owed.isEmpty, "\(name): no banner")
                ms += 1_000
                deliver(item.agent, item.answer, log: log, at: ms)
                land(store, log: log, at: ms)
                let turn = store.rows.first { $0.key == key }?.isYourTurn
                #expect(turn == true, "\(name): its turn is quiet")
                let after = store.snapshot.lamp
                #expect(after != .waiting, "\(name)")
                continue
            }
            let red = store.snapshot.lamp
            #expect(red == .waiting, "\(name): the ask turns the lamp red")
            let owed = store.notifier.ledger.queuedKeys
            #expect(owed == [key], "\(name): its banner is owed")
            for event in item.noise {
                ms += 1_000
                deliver(item.agent, event, log: log, at: ms)
                land(store, log: log, at: ms)
                let still = store.snapshot.lamp
                #expect(still == .waiting, "\(name): \(event.name) is not the answer")
            }
            // Notification Center accepts the banner.
            let banner = WaitLedger.bannerID(key)
            store.notifier.finishDelivery(key: key, bannerID: banner, success: true)
            ms += 1_000
            deliver(item.agent, item.answer, log: log, at: ms)
            land(store, log: log, at: ms)
            let out = store.snapshot.lamp
            #expect(out != .waiting, "\(name): the answer puts the lamp out")
            let blocked = store.rows.first { $0.key == key }?.isBlocked
            #expect(blocked == false, "\(name)")
            #expect(withdrawn.ids == [banner], "\(name): the banner is withdrawn")
            let left = store.notifier.ledger.queuedKeys
            #expect(left.isEmpty, "\(name)")
        }
    }
}

/// Cadence policy — no fixed probe interval: a tick for time-based
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

    /// A scan that finds the same processes backs the next one off,
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
        #expect(throttle.event(at: 10.1) == .armTrailing, "the second event is never dropped")
        #expect(throttle.event(at: 10.2) == .absorbed)
        #expect(abs(throttle.trailingDelay(at: 10.2) - 0.2) < 0.001)
        throttle.trailingFired(at: 10.4)
        #expect(throttle.event(at: 10.5) == .armTrailing)
        #expect(throttle.event(at: 11.0) == .absorbed, "the armed trailing fire carries it")
        throttle.trailingFired(at: 11.0)
        #expect(throttle.event(at: 11.5) == .fire)
    }
}
