import Foundation
import Testing
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

/// 23.0 · one record of what each session did. Each test pins a defect the
/// four overlapping files it replaced (ledger, hook history, timeline,
/// dismiss list) had, or a rule the one value now keeps.
@Suite("Session log")
struct SessionLogTests {
    let now: Int64 = 1_800_000_000_000
    let minute: Int64 = 60_000

    private func running(_ key: String, _ agent: AgentID = .claude) -> AgentRow {
        var row = AgentRow(rowKey: key, agent: agent)
        row.sessionID = key
        row.task = "Fix the login test"
        row.liveProcess = true
        row.harvestMs = now - minute
        return row
    }

    private func waiting(
        _ key: String, _ agent: AgentID = .claude, since: Int64? = nil, signal: WaitSignalKind = .hooks
    ) -> AgentRow {
        var row = running(key, agent)
        row.waiting = true
        row.waitSignal = signal
        row.waitKind = "Permission"
        row.waitSinceMs = since ?? now - minute
        return row
    }

    // MARK: - 1 · a resolved wait is owed no banner

    @Test func aWaitThatResolvedLeavesTheQueue() {
        var log = SessionLog()
        log.reconcileWaits(rows: [waiting("claude|a")], released: [], nowMs: now)
        log.markQueued("claude|a", nowMs: now)
        #expect(log.queuedKeys == ["claude|a"])
        log.reconcileWaits(rows: [running("claude|a")], released: [], nowMs: now + minute)
        #expect(log.queuedKeys.isEmpty, "the queue used to keep it, and post it later")
    }

    @Test func owedBannersAreRebuiltFromThisScansRows() {
        var fresh = waiting("claude|a")
        fresh.waitMessage = "Bash: npm test"
        let rows = [fresh, running("codex|b", .codex), waiting("cursor|c", .cursor)]
        let owed = WaitNotifier.queuedDeliveryRows(
            queued: ["claude|a", "codex|b", "gone|x", "cursor|c"],
            rows: rows,
            muted: [.cursor]
        )
        let keys = owed.map(\.rowKey)
        #expect(keys == ["claude|a"], "only a key waiting now, unmuted, in a current row")
        #expect(owed.first?.waitMessage == "Bash: npm test", "the current row, not a frozen copy")
    }

    // MARK: - 2 · spans a quit left open are closed

    @Test func aSpanAQuitLeftOpenIsClosedAtTheLastSave() {
        var log = SessionLog()
        let gone = running("claude|gone")
        let here = running("codex|here", .codex)
        log.applyTimeline(SessionTimeline.transitions(previous: [], current: [gone, here], nowMs: now))
        let saved = now + 10 * minute
        let closed = log.closeAbsent(liveKeys: ["codex|here"], atMs: saved)
        #expect(closed)
        #expect(log.spans("claude|gone").last?.endMs == saved)
        #expect(log.spans("codex|here").last?.endMs == nil, "a session still here stays open")
        let again = log.closeAbsent(liveKeys: ["codex|here"], atMs: saved + minute)
        #expect(!again, "closing is idempotent — a quiet scan changes nothing")
        log.prune(nowMs: saved + SessionLog.retentionMs + minute)
        #expect(log.sessions["claude|gone"] == nil, "a closed span ages out")
        #expect(log.sessions["codex|here"] != nil, "an open one is the present")
    }

    @MainActor
    @Test func theFirstScanAfterLaunchClosesWhatTheLastRunLeftOpen() {
        let store = StatusStore()
        var log = SessionLog()
        let wallNow = Int64(Date().timeIntervalSince1970 * 1000)
        log.applyTimeline([TimelineTransition(
            rowKey: "claude|old", state: .running, evidence: .harvest, kind: "",
            atMs: wallNow - 60 * minute, exact: true
        )])
        log.savedAtMs = wallNow - 30 * minute
        store.sessionLog = log
        store.engine.applyScan(procs: [], harvest: .skipped, processSignature: "", attention: [], ticket: 1)
        #expect(store.sessionLog.spans("claude|old").last?.endMs == wallNow - 30 * minute)
    }

    // MARK: - 3 · the same owed wait is not a write

    @Test func queuingTwiceIsOneChange() {
        var log = SessionLog()
        log.reconcileWaits(rows: [waiting("claude|a")], released: [], nowMs: now)
        let first = log.markQueued("claude|a", nowMs: now)
        let second = log.markQueued("claude|a", nowMs: now + 3_000)
        #expect(first)
        #expect(!second)
    }

    // MARK: - 4 · a click lands on the wait its banner was for

    @Test func aClickOnAnOldBannerCreditsTheOldWait() throws {
        var log = SessionLog()
        log.reconcileWaits(rows: [waiting("claude|a")], released: [], nowMs: now)
        let old = try #require(log.openWait("claude|a"))
        log.reconcileWaits(rows: [running("claude|a")], released: [], nowMs: now + minute)
        log.reconcileWaits(rows: [waiting("claude|a", since: now + 2 * minute)], released: [], nowMs: now + 2 * minute)
        let current = try #require(log.openWait("claude|a"))
        #expect(current.id != old.id)

        let clicked = log.markClicked(waitID: old.id, nowMs: now + 3 * minute)
        #expect(clicked)
        let waits = log.sessions["claude|a"]?.waits ?? []
        #expect(waits.first?.clickedMs == now + 3 * minute)
        #expect(waits.last?.clickedMs == nil, "the newest wait was never clicked")
        let twice = log.markClicked(waitID: old.id, nowMs: now + 4 * minute)
        #expect(!twice)
    }

    @MainActor
    @Test func aClickRedrawsTheAuditOnlyWhenItChangedSomething() throws {
        let store = StatusStore()
        var log = SessionLog()
        log.reconcileWaits(rows: [waiting("claude|a")], released: [], nowMs: now)
        store.sessionLog = log
        let id = try #require(log.openWait("claude|a")?.id)
        let before = store.logRevision
        store.notifier.recordBannerClick(waitIDs: [id])
        let after = store.logRevision
        #expect(after != before, "the detail view's notification section follows the click")
        store.notifier.recordBannerClick(waitIDs: [id, "unknown|1"])
        let again = store.logRevision
        #expect(again == after)
    }

    // MARK: - 5 · a better key merges history

    @Test func aRemapMergesBothHistories() {
        var log = SessionLog()
        let old = running("claude|pid-1")
        log.applyTimeline(SessionTimeline.transitions(previous: [], current: [old], nowMs: now - 20 * minute))
        log.closeAbsent(liveKeys: [], atMs: now - 15 * minute)
        let renamed = running("claude|s1")
        log.applyTimeline(SessionTimeline.transitions(previous: [], current: [renamed], nowMs: now - 10 * minute))
        // Both keys hold an open wait for the same session.
        log.reconcileWaits(
            rows: [waiting("claude|pid-1", since: now - 6 * minute), waiting("claude|s1", since: now - 5 * minute)],
            released: [], nowMs: now - 4 * minute
        )

        let moved = log.remap(from: "claude|pid-1", to: "claude|s1")
        #expect(moved)
        #expect(log.sessions["claude|pid-1"] == nil)
        let spans = log.spans("claude|s1")
        #expect(spans.count == 2, "the old key's span used to be dropped when the new key had one")
        let openSpans = spans.filter { $0.endMs == nil }
        #expect(openSpans.count == 1)
        let waits = log.sessions["claude|s1"]?.waits ?? []
        let open = waits.filter { $0.isOpen }
        #expect(waits.count == 2)
        #expect(open.count == 1, "one open wait per key")
        #expect(open.first?.raisedMs == now - 5 * minute, "the newest stands")
    }

    // MARK: - Dismissal lives in the log

    @Test func aSoftDismissalHoldsUntilItsSourceLetsGo() {
        var log = SessionLog()
        let pending = waiting("cursor|a", .cursor, signal: .pending)
        log.reconcileWaits(rows: [pending], released: [], nowMs: now)
        log.dismiss(pending, soft: true, nowMs: now + 1_000)
        #expect(log.suppressedKeys == ["cursor|a"])
        #expect(!log.waitingKeys.contains("cursor|a"))

        // Suppressed, the row is not waiting; the dismissal still holds.
        log.reconcileWaits(rows: [running("cursor|a")], released: [], nowMs: now + minute)
        #expect(log.suppressedKeys == ["cursor|a"])

        // The builder saw the pending clear.
        log.reconcileWaits(rows: [running("cursor|a")], released: ["cursor|a"], nowMs: now + 2 * minute)
        #expect(log.suppressedKeys.isEmpty)
        #expect(log.latestWait("cursor|a")?.resolvedMs == now + 2 * minute)
    }

    @Test func aNewWaitOnADismissedKeyEndsTheDismissal() {
        var log = SessionLog()
        let pending = waiting("cursor|a", .cursor, signal: .pending)
        log.reconcileWaits(rows: [pending], released: [], nowMs: now)
        log.dismiss(pending, soft: true, nowMs: now + 1_000)
        log.reconcileWaits(rows: [waiting("cursor|a", .cursor, since: now + minute)], released: [], nowMs: now + minute)
        #expect(log.suppressedKeys.isEmpty)
        #expect(log.waitingKeys == ["cursor|a"])
        #expect(log.openWait("cursor|a")?.dismissedMs == nil)
    }

    @Test func aHardDismissalIsNotASuppression() {
        var log = SessionLog()
        let hook = waiting("claude|a")
        log.reconcileWaits(rows: [hook], released: [], nowMs: now)
        log.markQueued("claude|a", nowMs: now)
        log.dismiss(hook, soft: false, nowMs: now + 1_000)
        #expect(log.suppressedKeys.isEmpty)
        #expect(log.dismissedKeys == ["claude|a"])
        #expect(log.queuedKeys.isEmpty, "a dismissed wait is owed no banner")
    }

    // MARK: - 6 · the day is said when it is not today

    @Test func theClockSaysTheDayWhenItIsNotToday() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let hour: Int64 = 60 * minute
        let day: Int64 = 24 * hour
        // 2027-01-15 08:00 UTC, a Friday.
        #expect(LogClock.label(ms: now - 3 * hour, nowMs: now, lang: .en, timeZone: utc) == "05:00")
        #expect(LogClock.label(ms: now - 9 * hour, nowMs: now, lang: .en, timeZone: utc) == "Thu 23:00")
        #expect(LogClock.label(ms: now - 2 * day, nowMs: now, lang: .en, timeZone: utc) == "Wed 08:00")
        #expect(LogClock.label(ms: now - 2 * day, nowMs: now, lang: .zh, timeZone: utc) == "周三 08:00")
        #expect(LogClock.label(ms: now - 10 * day, nowMs: now, lang: .en, timeZone: utc) == "1/5 08:00")
        #expect(LogClock.label(ms: now - 10 * day, nowMs: now, lang: .zh, timeZone: utc) == "1/5 08:00")
    }

    @Test func theAuditAndTheActivityLogUseTheSameClock() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        var log = SessionLog()
        let day: Int64 = 24 * 60 * minute
        log.reconcileWaits(rows: [waiting("claude|a", since: now - 2 * day)], released: [], nowMs: now - 2 * day)
        log.markDelivery("claude|a", outcome: "posted", nowMs: now - 2 * day)
        let wait = try #require(log.latestWait("claude|a"))
        let audit = NotificationAuditModel.make(wait: wait, nowMs: now, lang: .en, timeZone: utc)
        #expect(audit.lines.first == String(format: L10n.t(.auditRaised, .en), "Wed 08:00"))
        let activity = ActivityLogModel.make(log: log, rows: [], lang: .en, nowMs: now, timeZone: utc)
        #expect(activity.entries.first?.clock == "Wed 08:00")
    }

    // MARK: - Bounds and durability

    @Test func theSameWorldTwiceIsNotADurableChange() {
        var log = SessionLog()
        let rows = [running("claude|a"), waiting("codex|b")]
        log.applyTimeline(SessionTimeline.transitions(previous: [], current: rows, nowMs: now))
        log.reconcileWaits(rows: rows, released: [], nowMs: now)
        let before = log
        let spans = log.applyTimeline(SessionTimeline.transitions(previous: rows, current: rows, nowMs: now + 3_000))
        let waits = log.reconcileWaits(rows: rows, released: [], nowMs: now + 3_000)
        let pruned = log.prune(nowMs: now + 3_000)
        #expect(!spans)
        #expect(!waits)
        #expect(!pruned)
        #expect(log.hasSameDurableState(as: before))
        var stamped = log
        stamped.savedAtMs = now
        #expect(stamped.hasSameDurableState(as: before), "the save stamp is not content")
    }

    @Test func resolvedWaitsPerSessionAreCapped() {
        var log = SessionLog()
        for index in 0..<(SessionLog.maxWaitsPerSession + 10) {
            let at = now + Int64(index) * 2 * minute
            log.reconcileWaits(rows: [waiting("claude|a", since: at)], released: [], nowMs: at)
            log.reconcileWaits(rows: [], released: [], nowMs: at + minute)
        }
        log.prune(nowMs: now + 60 * minute)
        let count = log.sessions["claude|a"]?.waits.count ?? 0
        #expect(count == SessionLog.maxWaitsPerSession)
    }
}
