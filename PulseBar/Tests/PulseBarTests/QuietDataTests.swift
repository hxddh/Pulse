import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

/// 0.99 Quiet Data — what Pulse writes down, and whether it says so.
///
/// 0.90–0.97 made the display honest and 0.98 made the collector honest. These
/// cover the surface neither of them touched: the bytes that outlive the scan.
final class QuietDataTests: XCTestCase {

    // MARK: - The session log stores what its comment says it stores

    /// The retention the type documents is the retention `prune` enforces:
    /// a resolved wait and a closed span outlive their end by a day, no more.
    func testResolvedWaitsAndClosedSpansExpireAtTheDocumentedRetention() {
        let now: Int64 = 1_800_000_000_000
        let hour: Int64 = 60 * 60 * 1000
        var log = SessionLog()
        var row = AgentRow(rowKey: "claude|a", agent: .claude)
        row.waiting = true
        log.reconcileWaits(rows: [row], released: [], nowMs: now - 30 * hour)
        log.reconcileWaits(rows: [], released: [], nowMs: now - 26 * hour)
        var fresh = AgentRow(rowKey: "claude|b", agent: .claude)
        fresh.waiting = true
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
            row.waiting = true
            return row
        }
        log.reconcileWaits(rows: resolved, released: [], nowMs: now - 2_000)
        log.reconcileWaits(rows: [], released: [], nowMs: now - 1_000)
        var live = AgentRow(rowKey: "codex|live", agent: .codex)
        live.task = "still waiting"
        live.waiting = true
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
        row.waiting = true
        log.reconcileWaits(rows: [row], released: [], nowMs: 1_800_000_000_000)
        let title = try XCTUnwrap(log.openWait("claude|long")?.title)
        XCTAssertFalse(title.isEmpty)
        XCTAssertLessThanOrEqual(title.count, SessionLog.titleLimit, "the log records a headline, not a transcript")
        XCTAssertLessThan(title.count, row.task.count)
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
