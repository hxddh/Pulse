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
        row.harvestMs = now - minute
        return row
    }

    // MARK: - Timeline

    @Test func theSameWorldTwiceIsSilent() {
        let rows = [row("claude|a"), row("codex|b", .codex)]
        #expect(SessionTimeline.transitions(previous: rows, current: rows, nowMs: now).isEmpty)
    }

    @Test func aWaitIsStampedWithTheHooksOwnClock() throws {
        let before = row("claude|a")
        var after = before
        after.waiting = true
        after.waitSignal = .hooks
        after.waitKind = "Permission"
        after.waitSinceMs = now - 3 * minute
        let edges = SessionTimeline.transitions(previous: [before], current: [after], nowMs: now)
        let edge = try #require(edges.first)
        #expect(edge.state == .blocked)
        #expect(edge.evidence == .hook)
        #expect(edge.atMs == now - 3 * minute)
        #expect(edge.exact)
    }

    @Test func aSessionThatLeavesClosesItsSpan() {
        var book = SessionTimelineBook()
        let r = row("claude|a")
        book.apply(SessionTimeline.transitions(previous: [], current: [r], nowMs: now))
        book.apply(SessionTimeline.transitions(previous: [r], current: [], nowMs: now + 5 * minute))
        let spans = book.spans["claude|a"] ?? []
        #expect(spans.count == 1)
        #expect(spans.first?.endMs == now + 5 * minute)
    }

    @Test func relaunchingDoesNotDuplicateAnOpenSpan() {
        var book = SessionTimelineBook()
        let r = row("claude|a")
        let first = book.apply(SessionTimeline.transitions(previous: [], current: [r], nowMs: now))
        #expect(first)
        // A fresh process has no previous rows and re-sees the same session.
        let again = book.apply(SessionTimeline.transitions(previous: [], current: [r], nowMs: now + minute))
        #expect(!again)
        #expect(book.spans["claude|a"]?.count == 1)
    }

    @Test func aRemappedKeyKeepsItsHistory() {
        let old = row("claude|pid-1")
        var renamed = old
        renamed.rowKey = "claude|s1"
        let edges = SessionTimeline.transitions(
            previous: [old], current: [renamed], remapped: ["claude|pid-1": "claude|s1"], nowMs: now
        )
        #expect(edges.isEmpty, "the same session under a better key is not a new edge")
    }

    @Test func theBookIsBounded() {
        var book = SessionTimelineBook()
        var previous: [AgentRow] = []
        for i in 0..<120 {
            var r = row("claude|a")
            r.waiting = i % 2 == 0
            r.waitSignal = r.waiting ? .hooks : nil
            r.waitSinceMs = r.waiting ? now + Int64(i) * minute : 0
            book.apply(SessionTimeline.transitions(previous: previous, current: [r], nowMs: now + Int64(i) * minute))
            previous = [r]
        }
        #expect((book.spans["claude|a"]?.count ?? 0) <= SessionTimelineBook.maxSpansPerSession)
        // The session leaves, closing its span; a day later nothing is kept.
        // (An open span is the session's present state and stays.)
        book.apply(SessionTimeline.transitions(previous: previous, current: [], nowMs: now + 121 * minute))
        book.prune(nowMs: now + SessionTimelineBook.retentionMs * 3)
        #expect(book.spans.isEmpty, "a day later nothing is kept")
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

    // MARK: - Explain the lamp

    @Test func aRedLampNamesWhoIsWaitingAndHow() {
        var waiting = row("claude|a")
        waiting.project = "pulse"
        waiting.waiting = true
        waiting.waitSignal = .hooks
        waiting.waitKind = "Permission"
        waiting.waitSinceMs = now - 4 * minute
        let explanation = LampExplanation.make(
            rows: [waiting, row("codex|b", .codex)],
            glance: .waiting,
            staleHidden: 3,
            narrator: RowNarrator(lang: .en, nowMs: now)
        )
        #expect(explanation.rule == .blocked)
        let keys = explanation.drivers.map { $0.rowKey }
        #expect(keys == ["claude|a"])
        let lines = explanation.lines(.en)
        #expect(lines.first == L10n.t(.lampRuleBlocked, .en))
        #expect(lines[1].hasPrefix("Claude · pulse — "))
        #expect(lines.last?.contains("3") == true, "what was left out is said")
    }

    @Test func anOrangeLampWithoutAStallIsAProcessOnlySession() {
        var process = AgentRow(rowKey: "cursor|p", agent: .cursor)
        process.liveProcess = true
        let explanation = LampExplanation.make(
            rows: [process], glance: .stalled, staleHidden: 0, narrator: RowNarrator(lang: .zh, nowMs: now)
        )
        #expect(explanation.rule == .thinRunning)
        #expect(explanation.drivers.first?.agent == .cursor)
    }

    // MARK: - Why no banner

    @Test func skippedRowsSayWhy() {
        var front = row("claude|front")
        front.waiting = true
        front.waitRaisedInFront = true
        var muted = row("codex|m", .codex)
        muted.waiting = true
        let delivery = WaitingDelivery(
            muted: [.codex], acknowledged: [], inFlight: [],
            canDeliverNow: true, msSinceLastNotification: 0, minimumIntervalMs: 0
        )
        let reasons = delivery.skipReasons([front, muted])
        #expect(reasons["claude|front"] == .inFront)
        #expect(reasons["codex|m"] == .muted)
    }

    @Test func theAuditKeepsWhenTheWaitBeganAndWhyThereWasNoBanner() {
        var ledger = AttentionLedger()
        var r = row("claude|a")
        r.waiting = true
        ledger.observe(row: r, nowMs: now)
        let marked = ledger.markDelivery(rowKey: "claude|a", outcome: WaitingDelivery.SkipReason.inFront.rawValue, nowMs: now)
        #expect(marked)
        let markedAgain = ledger.markDelivery(rowKey: "claude|a", outcome: WaitingDelivery.SkipReason.inFront.rawValue, nowMs: now + 1)
        #expect(!markedAgain, "the same outcome twice is not a write")
        let event = ledger.latestEvent(rowKey: "claude|a")
        #expect(event != nil)
        if let event {
            let lines = NotificationAuditModel.make(event: event, lang: .en).lines
            #expect(lines.count == 2)
            #expect(lines.first?.hasPrefix("Raised ") == true)
            #expect(lines.last?.contains("in front of you") == true)
        }
    }

    // MARK: - Activity

    @Test func theActivityLogMergesStateAndBanners() {
        var book = SessionTimelineBook()
        var r = row("claude|a")
        book.apply(SessionTimeline.transitions(previous: [], current: [r], nowMs: now - 10 * minute))
        let before = r
        r.waiting = true
        r.waitSignal = .hooks
        r.waitSinceMs = now - 5 * minute
        book.apply(SessionTimeline.transitions(previous: [before], current: [r], nowMs: now))
        var ledger = AttentionLedger()
        ledger.observe(row: r, nowMs: now - 5 * minute)
        let marked = ledger.markDelivery(rowKey: "claude|a", outcome: "posted", nowMs: now - 5 * minute + 1_000)
        #expect(marked)
        let log = ActivityLogModel.make(book: book, ledger: ledger, rows: [r], lang: .en)
        let texts = log.entries.map { $0.text }
        #expect(texts.count == 3)
        #expect(texts.first == L10n.t(.auditPosted, .en).replacingOccurrences(of: " %@", with: ""))
        #expect(texts.contains { $0.hasPrefix(L10n.t(.needsYou, .en)) })
    }
}

