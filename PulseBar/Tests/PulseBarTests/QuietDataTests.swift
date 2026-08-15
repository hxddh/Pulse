import XCTest
@testable import PulseBar

/// 0.99 Quiet Data — what Pulse writes down, and whether it says so.
///
/// 0.90–0.97 made the display honest and 0.98 made the collector honest. These
/// cover the surface neither of them touched: the bytes that outlive the scan.
final class QuietDataTests: XCTestCase {

    // MARK: - The ledger stores what its comment says it stores

    /// The retention the type documents is the retention `prune` enforces.
    /// Before 0.99 the numbers were literals inside `prune` and the doc comment
    /// above them claimed the file "never stores prompts" — which stopped being
    /// true the moment 0.98 defined the hero as the user's real goal.
    func testResolvedEventsExpireAtTheDocumentedRetention() {
        var ledger = AttentionLedger()
        let now: Int64 = 1_800_000_000_000
        let day: Int64 = 24 * 60 * 60 * 1000
        let retention = Int64(AttentionLedger.retentionDays) * day

        var fresh = AttentionLedger.Event(
            id: "fresh", rowKey: "claude|a", agent: "claude", session: "a",
            title: "recent", kind: "Permission", project: "p",
            observedAtMs: now - day, lastSeenAtMs: now - day
        )
        fresh.resolvedAtMs = now - day
        var stale = fresh
        stale.id = "stale"
        stale.rowKey = "claude|b"
        stale.resolvedAtMs = now - retention - 1
        ledger.events = [fresh, stale]

        ledger.prune(nowMs: now)
        XCTAssertEqual(ledger.events.map(\.id), ["fresh"])
    }

    /// The cap trims history, never live state.
    func testActiveWaitsAreNeverEvictedByTheHistoryCap() {
        var ledger = AttentionLedger()
        let now: Int64 = 1_800_000_000_000
        for index in 0..<(AttentionLedger.maxEvents + 40) {
            var event = AttentionLedger.Event(
                id: "resolved-\(index)", rowKey: "claude|r\(index)", agent: "claude",
                session: "r\(index)", title: "t", kind: "Input", project: "p",
                observedAtMs: now - 1000, lastSeenAtMs: now - 1000
            )
            event.resolvedAtMs = now - Int64(index) - 1
            ledger.events.append(event)
        }
        let active = AttentionLedger.Event(
            id: "active", rowKey: "codex|live", agent: "codex", session: "live",
            title: "still waiting", kind: "Permission", project: "p",
            observedAtMs: now, lastSeenAtMs: now
        )
        ledger.events.append(active)

        ledger.prune(nowMs: now)
        XCTAssertLessThanOrEqual(ledger.events.count, AttentionLedger.maxEvents)
        XCTAssertTrue(
            ledger.events.contains { $0.id == "active" },
            "a live Waiting event is product state, not history"
        )
    }

    /// The stored title is bounded — the ledger records a headline, not a
    /// transcript.
    func testStoredTitleIsBoundedToOneHundredAndSixtyCharacters() throws {
        var ledger = AttentionLedger()
        var row = AgentRow(rowKey: "claude|long", agent: .claude)
        row.task = String(repeating: "goal ", count: 200)
        row.waiting = true
        ledger.observe(row: row, nowMs: 1_800_000_000_000)
        let title = try XCTUnwrap(ledger.events.first?.title)
        XCTAssertFalse(title.isEmpty)
        XCTAssertLessThanOrEqual(title.count, 160, "the ledger records a headline, not a transcript")
        XCTAssertLessThan(title.count, row.task.count)
    }

    /// The Preferences line that describes retention is generated from the
    /// ledger's own constants, so the sentence cannot drift away from it.
    @MainActor
    func testRetentionSentenceQuotesTheRealNumbers() {
        let store = StatusStore()
        store.language = .en
        let line = store.waitHistoryRetentionLine
        XCTAssertTrue(line.contains("\(AttentionLedger.retentionDays)"), line)
        XCTAssertTrue(line.contains("\(AttentionLedger.maxEvents)"), line)
    }

    // MARK: - One chrome vocabulary, not three

    /// 0.98 collapsed the collector's two copies. The third lived in
    /// `usefulTask`, was case-sensitive where the collector lowercases, and had
    /// never learned `Cascade session`.
    @MainActor
    func testChromeTitlesAreRejectedWhateverTheirCase() {
        for title in ["Cascade session", "CASCADE SESSION", "cascade session",
                      "New Chat", "new chat", "Running", "running", "  Untitled  "] {
            var row = AgentRow(rowKey: "k", agent: .cascade)
            row.task = title
            XCTAssertNil(row.usefulTask, "\(title) is not a user goal")
        }
    }

    /// The collector and the row must agree on every entry. Two lists that
    /// merely look alike are what 0.98 and 0.99 each had to unpick.
    @MainActor
    func testCollectorAndRowShareOneVocabulary() {
        for title in AgentRow.chromeTitles {
            XCTAssertTrue(
                AgentRow.isChromeTitle(title.uppercased()),
                "\(title) must be chrome in either case"
            )
            var row = AgentRow(rowKey: "k", agent: .claude)
            row.task = title
            XCTAssertNil(row.usefulTask, "\(title) reached a row as a goal")
        }
    }

    func testARealGoalIsNotMistakenForChrome() {
        XCTAssertFalse(AgentRow.isChromeTitle("Auth session"))
        XCTAssertFalse(AgentRow.isChromeTitle("Fix the tray hero"))
    }

    // MARK: - The debug log keeps the project name off disk

    /// `ActivityHarvest.sessionKey` falls back to the workspace leaf, so a row
    /// key is often a directory name from the user's disk.
    func testDebugLogKeyDropsTheProjectNameButStaysCorrelatable() {
        let key = DebugLog.key("claude|SecretProject")
        XCTAssertFalse(key.contains("SecretProject"))
        XCTAssertTrue(key.hasPrefix("claude|"))
        XCTAssertEqual(key, DebugLog.key("claude|SecretProject"), "stable across calls")
        XCTAssertNotEqual(key, DebugLog.key("claude|OtherProject"))
    }

    func testDebugLogKeyLeavesAKeylessStringAlone() {
        XCTAssertEqual(DebugLog.key("manual"), "manual")
    }

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
