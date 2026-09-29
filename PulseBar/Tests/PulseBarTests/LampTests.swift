import Foundation
import Testing
@testable import PulseBar

/// 22.0 · Lamp — the session timeline and the lamp's explanation are pure
/// values; these pin what they say.
@Suite("Lamp")
struct LampTests {
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

