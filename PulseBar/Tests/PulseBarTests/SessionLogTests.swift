import Foundation
import SQLite3
import Testing
import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

// Session log: spans, waits, retention and the file it is saved to.

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
        row.state = .running
        row.harvestMs = now - minute
        return row
    }

    private func waiting(
        _ key: String, _ agent: AgentID = .claude, since: Int64? = nil, signal: WaitSignalKind = .hooks,
        ask: String = ""
    ) -> AgentRow {
        var row = running(key, agent)
        row.state = .blocked(RowWait(kind: "Permission", ask: ask, sinceMs: since ?? now - minute, signal: signal))
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
        let fresh = waiting("claude|a", ask: "Bash: npm test")
        let rows = [fresh, running("codex|b", .codex), waiting("cursor|c", .cursor)]
        let owed = WaitNotifier.queuedDeliveryRows(
            queued: ["claude|a", "codex|b", "gone|x", "cursor|c"],
            rows: rows,
            muted: [.cursor]
        )
        let keys = owed.map { $0.rowKey }
        #expect(keys == ["claude|a"], "only a key waiting now, unmuted, in a current row")
        #expect(owed.first?.wait?.ask == "Bash: npm test", "the current row, not a frozen copy")
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

    /// 23.0 bug: a session still present at relaunch kept its open span,
    /// and the first scan saw the same state and continued it — the strip
    /// claimed the hours Pulse was not running.
    @Test func aRelaunchDoesNotStretchALiveSessionsSpanOverTheDowntime() throws {
        var log = SessionLog()
        let here = running("codex|here", .codex)
        log.applyTimeline(SessionTimeline.transitions(previous: [], current: [here], nowMs: now))
        let saved = now + 10 * minute
        log.savedAtMs = saved
        let relaunch = now + 3 * 60 * minute
        // The first scan after launch: `previous` is empty, so the row is a
        // transition again — dated by its evidence, which predates the save.
        var seen = here
        seen.activityMs = now + 5 * minute
        let transitions = SessionTimeline.transitions(previous: [], current: [seen], nowMs: relaunch)
        let applied = log.resumeAfterLaunch(transitions, nowMs: relaunch)
        log.applyTimeline(applied)
        let spans = log.spans("codex|here")
        #expect(spans.count == 2)
        let first = try #require(spans.first)
        let last = try #require(spans.last)
        #expect(first.endMs == saved, "closed where the last run stopped watching")
        #expect(last.startMs == relaunch, "reopened when Pulse saw it again, not at the save")
        #expect(last.endMs == nil)
    }

    @Test func aRelaunchKeepsEvidenceDatedAfterTheSave() {
        var log = SessionLog()
        log.applyTimeline(SessionTimeline.transitions(previous: [], current: [running("claude|a")], nowMs: now))
        let saved = now + minute
        log.savedAtMs = saved
        let relaunch = now + 60 * minute
        let raisedWhileAway = waiting("claude|a", since: now + 30 * minute)
        let transitions = SessionTimeline.transitions(previous: [], current: [raisedWhileAway], nowMs: relaunch)
        let applied = log.resumeAfterLaunch(transitions, nowMs: relaunch)
        log.applyTimeline(applied)
        #expect(log.spans("claude|a").last?.startMs == now + 30 * minute, "a hook's own clock after the save is evidence")
    }

    // MARK: - A second ask on the same row

    /// 23.0 bug: a second permission on a row that was still waiting reused
    /// the open wait (same title, same kind) — no edge, no banner, and a
    /// dismissal of the first muted the second.
    @Test func aSecondAskOnTheSameRowIsItsOwnWait() throws {
        var log = SessionLog()
        log.reconcileWaits(rows: [waiting("claude|a", since: now - minute)], released: [], nowMs: now)
        let first = try #require(log.openWait("claude|a"))
        log.dismiss(waiting("claude|a", since: now - minute), soft: false, nowMs: now + 1_000)
        #expect(log.dismissedKeys == ["claude|a"])

        var second = waiting("claude|a", since: now + minute)
        second.activityMs = now + 50_000 // the next tool call began the second ask
        let changed = log.reconcileWaits(rows: [second], released: [], nowMs: now + minute + 2_000)
        #expect(changed)
        let open = try #require(log.openWait("claude|a"))
        #expect(open.id != first.id)
        #expect(open.sinceMs == now + minute)
        #expect(open.dismissedMs == nil, "the new ask inherits no dismissal")
        #expect(log.dismissedKeys.isEmpty)
        let waits = log.sessions["claude|a"]?.waits ?? []
        #expect(waits.count == 2)
        #expect(waits.first?.resolvedMs != nil, "the first ask is resolved")
        #expect(log.waitingSince["claude|a"] == now + minute)
    }

    @Test func theSameAskSaidTwiceIsOneWait() {
        var log = SessionLog()
        log.reconcileWaits(rows: [waiting("claude|a", since: now - minute)], released: [], nowMs: now)
        // Claude's Notification lands a second after its PermissionRequest,
        // with nothing done in between.
        let echo = waiting("claude|a", since: now - minute + 1_000)
        #expect(!SessionLog.isNewRaise(echo, previousSinceMs: now - minute))
        log.reconcileWaits(rows: [echo], released: [], nowMs: now + 2_000)
        let waits = log.sessions["claude|a"]?.waits ?? []
        #expect(waits.count == 1)
    }

    @Test func aFilePendingWhoseClockMovesIsNotANewAsk() {
        var log = SessionLog()
        log.reconcileWaits(rows: [waiting("opencode|a", .opencode, since: now - minute, signal: .pending)], released: [], nowMs: now)
        let moved = waiting("opencode|a", .opencode, since: now + 5 * minute, signal: .pending)
        #expect(!SessionLog.isNewRaise(moved, previousSinceMs: now - minute), "a pending stamps the file's clock")
        log.reconcileWaits(rows: [moved], released: [], nowMs: now + 5 * minute)
        let waits = log.sessions["opencode|a"]?.waits ?? []
        #expect(waits.count == 1)
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

/// 22.0 · Lamp — the session timeline and the lamp's explanation are pure
/// values; these pin what they say.
@Suite("Session timeline")
struct SessionTimelineTests {
    let now: Int64 = 1_800_000_000_000
    let minute: Int64 = 60_000

    private func row(_ key: String, _ agent: AgentID = .claude) -> AgentRow {
        var row = AgentRow(rowKey: key, agent: agent)
        row.sessionID = key
        row.task = "Fix the login test"
        row.liveProcess = true
        row.state = .running
        row.harvestMs = now - minute
        return row
    }

    private func waiting(_ row: AgentRow, since: Int64 = 0, inFront: Bool = false) -> AgentRow {
        var copy = row
        copy.state = .blocked(RowWait(kind: "Permission", sinceMs: since, signal: .hooks, inFront: inFront))
        return copy
    }

    // MARK: - Timeline

    @Test func theSameWorldTwiceIsSilent() {
        let rows = [row("claude|a"), row("codex|b", .codex)]
        #expect(SessionTimeline.transitions(previous: rows, current: rows, nowMs: now).isEmpty)
    }

    @Test func aWaitIsStampedWithTheHooksOwnClock() throws {
        let before = row("claude|a")
        let after = waiting(before, since: now - 3 * minute)
        let edges = SessionTimeline.transitions(previous: [before], current: [after], nowMs: now)
        let edge = try #require(edges.first)
        #expect(edge.state == .blocked)
        #expect(edge.evidence == .hook)
        #expect(edge.atMs == now - 3 * minute)
        #expect(edge.exact)
    }

    @Test func aSessionThatLeavesClosesItsSpan() {
        var log = SessionLog()
        let r = row("claude|a")
        log.applyTimeline(SessionTimeline.transitions(previous: [], current: [r], nowMs: now))
        log.applyTimeline(SessionTimeline.transitions(previous: [r], current: [], nowMs: now + 5 * minute))
        let spans = log.spans("claude|a")
        #expect(spans.count == 1)
        #expect(spans.first?.endMs == now + 5 * minute)
    }

    @Test func relaunchingDoesNotDuplicateAnOpenSpan() {
        var log = SessionLog()
        let r = row("claude|a")
        let first = log.applyTimeline(SessionTimeline.transitions(previous: [], current: [r], nowMs: now))
        #expect(first)
        // A fresh process has no previous rows and re-sees the same session.
        let again = log.applyTimeline(SessionTimeline.transitions(previous: [], current: [r], nowMs: now + minute))
        #expect(!again)
        #expect(log.spans("claude|a").count == 1)
    }

    @Test func theLogIsBounded() {
        var log = SessionLog()
        var previous: [AgentRow] = []
        for i in 0..<120 {
            let base = row("claude|a")
            let r = i % 2 == 0 ? waiting(base, since: now + Int64(i) * minute) : base
            log.applyTimeline(SessionTimeline.transitions(previous: previous, current: [r], nowMs: now + Int64(i) * minute))
            previous = [r]
        }
        #expect(log.spans("claude|a").count <= SessionLog.maxSpansPerSession)
        // The session leaves, closing its span; a day later nothing is kept.
        // (An open span is the session's present state and stays.)
        log.applyTimeline(SessionTimeline.transitions(previous: previous, current: [], nowMs: now + 121 * minute))
        log.prune(nowMs: now + SessionLog.retentionMs * 3)
        #expect(log.sessions.isEmpty, "a day later nothing is kept")
    }

    @Test func theStripSplitsTheHourByState() {
        let spans = [
            TimelineSpan(state: .running, evidence: .harvest, startMs: now - 40 * minute, endMs: now - 10 * minute),
            TimelineSpan(state: .blocked, evidence: .hook, kind: "Permission", startMs: now - 10 * minute, endMs: nil),
        ]
        let strip = TimelineStripModel.make(spans: spans, nowMs: now)
        let states = strip.segments.map { $0.state }
        #expect(states == [nil, .running, .blocked])
        let total = strip.segments.reduce(0.0) { $0 + $1.fraction }
        #expect(abs(total - 1.0) < 0.0001)
        let minutes = strip.minutesByState
        #expect(minutes.first?.0 == .blocked && minutes.first?.1 == 10)
    }

    // The lamp's explanation is pinned in `ExplainTests` (23.0).

    // MARK: - Why no banner

    @Test func skippedRowsSayWhy() {
        let front = waiting(row("claude|front"), inFront: true)
        let muted = waiting(row("codex|m", .codex))
        let delivery = WaitingDelivery(
            muted: [.codex], acknowledged: [], inFlight: [],
            canDeliverNow: true, msSinceLastNotification: 0, minimumIntervalMs: 0
        )
        let reasons = delivery.skipReasons([front, muted])
        #expect(reasons["claude|front"] == .inFront)
        #expect(reasons["codex|m"] == .muted)
    }

    @Test func theAuditKeepsWhenTheWaitBeganAndWhyThereWasNoBanner() {
        var log = SessionLog()
        let r = waiting(row("claude|a"))
        log.reconcileWaits(rows: [r], released: [], nowMs: now)
        let marked = log.markDelivery("claude|a", outcome: WaitingDelivery.SkipReason.inFront.rawValue, nowMs: now)
        #expect(marked)
        let markedAgain = log.markDelivery("claude|a", outcome: WaitingDelivery.SkipReason.inFront.rawValue, nowMs: now + 1)
        #expect(!markedAgain, "the same outcome twice is not a write")
        let wait = log.latestWait("claude|a")
        #expect(wait != nil)
        if let wait {
            let lines = NotificationAuditModel.make(wait: wait, nowMs: now, lang: .en).lines
            #expect(lines.count == 2)
            #expect(lines.first?.hasPrefix("Raised ") == true)
            #expect(lines.last?.contains("in front of you") == true)
        }
    }

    // MARK: - Activity

    @Test func theActivityLogMergesStateAndBanners() {
        var log = SessionLog()
        let before = row("claude|a")
        log.applyTimeline(SessionTimeline.transitions(previous: [], current: [before], nowMs: now - 10 * minute))
        let r = waiting(before, since: now - 5 * minute)
        log.applyTimeline(SessionTimeline.transitions(previous: [before], current: [r], nowMs: now))
        log.reconcileWaits(rows: [r], released: [], nowMs: now - 5 * minute)
        let marked = log.markDelivery("claude|a", outcome: "posted", nowMs: now - 5 * minute + 1_000)
        #expect(marked)
        let model = ActivityLogModel.make(log: log, rows: [r], lang: .en, nowMs: now)
        let texts = model.entries.map { $0.text }
        #expect(texts.count == 3)
        #expect(texts.first == L10n.t(.auditPosted, .en).replacingOccurrences(of: " %@", with: ""))
        #expect(texts.contains { $0.hasPrefix(L10n.t(.needsYou, .en)) })
    }
}

/// 0.99 Quiet Data — what Pulse writes down, and whether it says so.
///
/// 0.90–0.97 made the display honest and 0.98 made the collector honest. These
/// cover the surface neither of them touched: the bytes that outlive the scan.
final class SessionLogRetentionTests: XCTestCase {

    // MARK: - The session log stores what its comment says it stores

    /// The retention the type documents is the retention `prune` enforces:
    /// a resolved wait and a closed span outlive their end by a day, no more.
    func testResolvedWaitsAndClosedSpansExpireAtTheDocumentedRetention() {
        let now: Int64 = 1_800_000_000_000
        let hour: Int64 = 60 * 60 * 1000
        var log = SessionLog()
        var row = AgentRow(rowKey: "claude|a", agent: .claude)
        row.state = .blocked(RowWait(kind: "Permission", signal: .hooks))
        log.reconcileWaits(rows: [row], released: [], nowMs: now - 30 * hour)
        log.reconcileWaits(rows: [], released: [], nowMs: now - 26 * hour)
        var fresh = AgentRow(rowKey: "claude|b", agent: .claude)
        fresh.state = .blocked(RowWait(kind: "Permission", signal: .hooks))
        log.reconcileWaits(rows: [fresh], released: [], nowMs: now - 2 * hour)
        log.reconcileWaits(rows: [], released: [], nowMs: now - hour)

        log.prune(nowMs: now)
        XCTAssertNil(log.latestWait("claude|a"), "resolved more than a day ago")
        XCTAssertNotNil(log.latestWait("claude|b"))
    }

    /// The cap trims history, never live state.
    func testOpenWaitsAreNeverEvictedByTheSessionCap() {
        let now: Int64 = 1_800_000_000_000
        var log = SessionLog()
        let resolved = (0..<(SessionLog.maxSessions + 40)).map { index -> AgentRow in
            var row = AgentRow(rowKey: "claude|r\(index)", agent: .claude)
            row.state = .blocked(RowWait(kind: "Permission", signal: .hooks))
            return row
        }
        log.reconcileWaits(rows: resolved, released: [], nowMs: now - 2_000)
        log.reconcileWaits(rows: [], released: [], nowMs: now - 1_000)
        var live = AgentRow(rowKey: "codex|live", agent: .codex)
        live.task = "still waiting"
        live.state = .blocked(RowWait(kind: "Permission", signal: .hooks))
        log.reconcileWaits(rows: [live], released: [], nowMs: now)

        log.prune(nowMs: now)
        XCTAssertLessThanOrEqual(log.sessions.count, SessionLog.maxSessions)
        XCTAssertNotNil(log.openWait("codex|live"), "a live wait is product state, not history")
    }

    /// The stored title is bounded — the log records a headline, not a
    /// transcript.
    func testStoredTitleIsBoundedToOneHundredAndSixtyCharacters() throws {
        var log = SessionLog()
        var row = AgentRow(rowKey: "claude|long", agent: .claude)
        row.task = String(repeating: "goal ", count: 200)
        row.state = .blocked(RowWait(kind: "Permission", signal: .hooks))
        log.reconcileWaits(rows: [row], released: [], nowMs: 1_800_000_000_000)
        let title = try XCTUnwrap(log.openWait("claude|long")?.title)
        XCTAssertFalse(title.isEmpty)
        XCTAssertLessThanOrEqual(title.count, SessionLog.titleLimit, "the log records a headline, not a transcript")
        XCTAssertLessThan(title.count, row.task.count)
    }
}

/// Clarity fixes — each test pins one defect found by reading the code: the
/// value the user would have seen, before and after.
@MainActor
@Suite("Session log fixes", .serialized)
struct SessionLogFixTests {
    let now: Int64 = 1_800_000_000_000
    func session(_ id: AgentID, _ sessionID: String, skill: String = "", ageMs: Int64 = 70_000) -> ActivityHarvest.Row {
        ActivityHarvest.Row(
            id: id, task: "Fix the login flow", project: "p", cwd: "/p", skill: skill,
            tool: "", harvestMs: now - ageMs, subRunning: 0, subTotal: 0, sessionID: sessionID,
            evidence: .session
        )
    }

    // MARK: - 13 / 14 · jumping to a wait

    func waitingRow(_ key: String, _ agent: AgentID, session: String = "", since: Int64) -> AgentRow {
        var row = AgentRow(rowKey: key, agent: agent)
        row.sessionID = session
        row.state = .blocked(RowWait(kind: "Permission", sinceMs: since, signal: .hooks))
        return row
    }

    // MARK: - 16 · a scan that finds the same world writes no log

    @Test func reconcilingTheSameWaitsIsNotADurableChange() {
        let row = waitingRow("claude|s1", .claude, session: "s1", since: now)
        var log = SessionLog()
        log.reconcileWaits(rows: [row], released: [], nowMs: now)
        let before = log
        let again = log.reconcileWaits(rows: [row], released: [], nowMs: now + 3_000)
        #expect(!again)
        #expect(log.hasSameDurableState(as: before))
        log.reconcileWaits(rows: [], released: [], nowMs: now + 6_000)
        #expect(!log.hasSameDurableState(as: before), "a resolved wait is a change")
    }
}

/// 2.3 — the defects a fresh audit at the 2.2 baseline turned up.
///
/// Each of these is a place where the code said something it had not
/// measured, dropped work it had been asked to do, or let a click reach
/// nothing without saying so.
final class SessionLogFileTests: XCTestCase {
    func testTheSessionLogRoundTripsThroughItsPrivateWrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session-log.json")

        var log = SessionLog()
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.task = "Something the user actually typed"
        row.state = .blocked(RowWait(kind: "Permission", signal: .hooks))
        log.reconcileWaits(rows: [row], released: [], nowMs: 1_800_000_000_000)
        XCTAssertTrue(SessionLogFile.save(log, to: url, nowMs: 1_800_000_000_100))

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let loaded = SessionLogFile.load(from: url, nowMs: 1_800_000_000_200)
        XCTAssertEqual(loaded.waitingKeys, ["claude|s1"])
        XCTAssertEqual(loaded.savedAtMs, 1_800_000_000_100, "the write is stamped, for closing spans after a quit")
        XCTAssertTrue(loaded.hasSameDurableState(as: log))
    }
}

final class SessionLogPersistenceTests: XCTestCase {
    private func waitingRow(_ key: String = "codex|session-1") -> AgentRow {
        var row = AgentRow(rowKey: key, agent: .codex)
        row.sessionID = "session-1"
        row.task = "Approve test command"
        row.state = .blocked(RowWait(kind: "permission", signal: .hooks))
        row.project = "Pulse"
        return row
    }

    func testSessionLogPersistsQueueDismissalAndRateLimit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("session-log-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var log = SessionLog()
        log.reconcileWaits(rows: [waitingRow()], released: [], nowMs: 100)
        log.markQueued("codex|session-1", nowMs: 110)
        XCTAssertTrue(log.queuedKeys.contains("codex|session-1"))
        log.markNotified("codex|session-1", nowMs: 200)
        XCTAssertFalse(log.queuedKeys.contains("codex|session-1"), "a shown banner is no longer owed")
        XCTAssertFalse(log.canDeliver(nowMs: 1_000, minimumIntervalMs: 3_000))
        log.dismiss(waitingRow(), soft: false, nowMs: 300)
        SessionLogFile.save(log, to: url, nowMs: 400)
        let restored = SessionLogFile.load(from: url, nowMs: 500)
        XCTAssertTrue(restored.dismissedKeys.contains("codex|session-1"))
        XCTAssertEqual(restored.openWait("codex|session-1")?.notifiedMs, 200)
        XCTAssertEqual(restored.openWait("codex|session-1")?.queuedMs, 110, "the audit keeps when it was queued")
    }

    func testSessionLogNeverEvictsOpenWaits() {
        var log = SessionLog()
        let rows = (0..<300).map { index in
            waitingRow("codex|session-\(index)")
        }
        log.reconcileWaits(rows: rows, released: [], nowMs: 100)
        log.prune(nowMs: 100)

        XCTAssertEqual(log.waitingKeys.count, 300, "a live wait is product state, not history")
    }
}
