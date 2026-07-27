import XCTest
@testable import PulseBar

/// The merge core. Until 0.23 this logic lived inside `StatusStore.applyScan`
/// with zero coverage, despite being the single most regression-prone part of
/// the product.
final class SnapshotBuilderTests: XCTestCase {

    // MARK: Fixtures

    private let now: Int64 = 1_700_000_000_000

    /// No terminal anywhere — keeps focus resolution out of the way unless a
    /// test opts into it.
    private var bareTerminal: TerminalFocus.Environment {
        TerminalFocus.Environment(warpRunning: false, ttyHostRunning: false, anyTerminalInstalled: false)
    }

    private func context(
        dismissed: Set<String> = [],
        showAll: Bool = false,
        maxSessions: Int = SnapshotBuilder.maxSessionsPerAgent,
        maxRows: Int = SnapshotBuilder.maxVisibleRows,
        exists: @escaping (String) -> Bool = { _ in false },
        terminal: TerminalFocus.Environment? = nil,
        lang: ResolvedLanguage = .en
    ) -> SnapshotBuilder.Context {
        SnapshotBuilder.Context(
            nowMs: now,
            terminal: terminal ?? bareTerminal,
            pathExists: exists,
            lang: lang,
            maxSessionsPerAgent: maxSessions,
            maxVisibleRows: maxRows,
            dismissedPendingKeys: dismissed,
            showAllAgents: showAll
        )
    }

    private func hit(_ id: AgentID, count: Int = 1, pid: Int = 100, tty: String = "") -> ProcessProbe.Hit {
        ProcessProbe.Hit(id: id, count: count, viaWarp: false, pid: pid, tty: tty)
    }

    private func harvest(
        _ id: AgentID,
        task: String = "",
        session: String = "",
        project: String = "",
        cwd: String = "",
        skill: String = "",
        tool: String = "",
        ageMs: Int64 = 1000,
        subRunning: Int = 0,
        subTotal: Int = 0
    ) -> ActivityHarvest.Row {
        ActivityHarvest.Row(
            id: id, task: task, project: project, cwd: cwd, skill: skill,
            tool: tool, harvestMs: now - ageMs,
            subRunning: subRunning, subTotal: subTotal, sessionID: session
        )
    }

    private func attention(
        _ id: AgentID,
        kind: String = "Permission",
        message: String = "",
        session: String = "",
        cwd: String = "",
        ageMs: Int64 = 500
    ) -> AttentionReader.Entry {
        AttentionReader.Entry(id: id, kind: kind, message: message, tsMs: now - ageMs, session: session, cwd: cwd)
    }

    private func build(
        procs: [ProcessProbe.Hit] = [],
        harvest rows: [ActivityHarvest.Row] = [],
        attention entries: [AttentionReader.Entry] = [],
        unreliable: Bool = false,
        previous: SnapshotBuilder.Previous = .init(),
        context ctx: SnapshotBuilder.Context? = nil
    ) -> SnapshotBuilder.Result {
        SnapshotBuilder.build(
            SnapshotBuilder.Input(
                procs: procs, harvest: rows, harvestUnreliable: unreliable, attention: entries
            ),
            previous: previous,
            context: ctx ?? context()
        )
    }

    // MARK: Empty / error

    func testNothingAtAllIsIdleNotError() {
        let r = build()
        XCTAssertTrue(r.rows.isEmpty)
        XCTAssertEqual(r.snapshot.glance, .idle)
        XCTAssertEqual(r.activity, .empty)
        XCTAssertNil(r.snapshot.probeError)
    }

    func testErrorOnlyWhenHarvestFailedAndNothingIsLive() {
        let r = build(unreliable: true)
        XCTAssertEqual(r.snapshot.glance, .error)
        XCTAssertEqual(r.snapshot.title, "!")
        XCTAssertNotNil(r.snapshot.probeError)
    }

    func testLiveProcessSuppressesErrorEvenWhenHarvestFailed() {
        // A dead harvest is not a dead machine — `ps` still saw the agent.
        let r = build(procs: [.init(id: .claude, count: 1, viaWarp: false, pid: 10)], unreliable: true)
        XCTAssertEqual(r.snapshot.glance, .running, "probe still had an answer")
        XCTAssertNil(r.snapshot.probeError)
    }

    // MARK: Multi-session

    func testEachSessionBecomesItsOwnRow() {
        let r = build(harvest: [
            harvest(.claude, task: "Fix parser", session: "s1", project: "/a/Pulse"),
            harvest(.claude, task: "Write docs", session: "s2", project: "/a/Pulse"),
        ])
        XCTAssertEqual(r.rows.count, 2)
        XCTAssertEqual(Set(r.rows.map(\.sessionID)), ["s1", "s2"])
    }

    func testSessionsBeyondTheCapAreCountedNotDropped() {
        let rows = (1...7).map { harvest(.claude, task: "T\($0)", session: "s\($0)") }
        let r = build(harvest: rows, context: context(maxSessions: 4))
        XCTAssertEqual(r.rows.count, 4)
        XCTAssertEqual(r.snapshot.cappedSessions, 3, "the other three must be admitted to")
    }

    func testHiddenSessionsAreCreditedToOneRowOnly() {
        let rows = (1...6).map { harvest(.claude, task: "T\($0)", session: "s\($0)") }
        let r = build(harvest: rows, context: context(maxSessions: 4))
        XCTAssertEqual(r.rows.filter { $0.hiddenSessions > 0 }.count, 1, "badge appears once, not per sibling")
    }

    func testSessionsWithoutIdsDoNotCollideIntoOneRow() {
        let r = build(harvest: [
            harvest(.codex, task: "A", project: "/a/Repo"),
            harvest(.codex, task: "B", project: "/a/Repo"),
        ])
        XCTAssertEqual(r.rows.count, 2, "identical keys must be uniquified")
        XCTAssertEqual(Set(r.rows.map(\.rowKey)).count, 2)
    }

    // MARK: Freshness

    func testStaleHarvestIsDroppedWhenNoProcessBacksIt() {
        let stale = harvest(.gemini, task: "old", ageMs: ActivityHarvest.freshWindowMs + 60_000)
        let r = build(harvest: [stale])
        XCTAssertTrue(r.rows.isEmpty)
        XCTAssertTrue(r.debugNotes.contains { $0.contains("drop stale harvest gemini") })
    }

    func testStaleHarvestSurvivesWhenTheProcessIsLive() {
        let stale = harvest(.gemini, task: "old", ageMs: ActivityHarvest.freshWindowMs + 60_000)
        let r = build(procs: [.init(id: .gemini, count: 1, viaWarp: false, pid: 7)], harvest: [stale])
        XCTAssertEqual(r.rows.count, 1)
        XCTAssertTrue(r.rows[0].liveProcess)
    }

    // MARK: Live-process attachment

    func testLiveProcessAttachesToExactlyOneSessionRow() {
        let r = build(
            procs: [.init(id: .claude, count: 3, viaWarp: false, pid: 42, tty: "ttys003")],
            harvest: [
                harvest(.claude, task: "A", session: "s1"),
                harvest(.claude, task: "B", session: "s2"),
            ]
        )
        XCTAssertEqual(r.rows.filter(\.liveProcess).count, 1, "must not smear across sessions")
        XCTAssertEqual(r.rows.filter { $0.processCount > 1 }.count, 1, "×N must not be inherited")
    }

    func testLiveProcessWithNoHarvestStillProducesARow() {
        let r = build(procs: [.init(id: .amp, count: 1, viaWarp: true, pid: 9)])
        XCTAssertEqual(r.rows.count, 1)
        XCTAssertTrue(r.rows[0].liveProcess)
        XCTAssertTrue(r.rows[0].viaWarp)
        XCTAssertTrue(r.rows[0].isProcessOnly)
    }

    func testCursorAgentProcessCountsAsCursor() {
        let r = build(procs: [.init(id: .cursorAgent, count: 1, viaWarp: false, pid: 5)])
        XCTAssertEqual(r.rows.map(\.agent), [.cursor], "cursor_agent merges into Cursor")
    }

    func testCursorAgentHarvestMergesIntoTheCursorRow() {
        let r = build(
            procs: [.init(id: .cursorAgent, count: 1, viaWarp: false, pid: 5)],
            harvest: [harvest(.cursorAgent, task: "Compose", session: "c1")]
        )
        XCTAssertEqual(r.rows.count, 1)
        XCTAssertEqual(r.rows[0].agent, .cursor)
        XCTAssertEqual(r.rows[0].usefulTask, "Compose")
    }

    // MARK: Waiting from harvest pending

    func testPendingSkillRaisesWaiting() {
        let r = build(harvest: [harvest(.cursor, task: "Ask", session: "s1", skill: "pending")])
        XCTAssertTrue(r.rows[0].waiting)
        XCTAssertEqual(r.rows[0].waitSignal, .pending)
        XCTAssertEqual(r.snapshot.glance, .waiting)
    }

    func testDismissedPendingStaysDismissed() {
        let row = harvest(.cursor, task: "Ask", session: "s1", skill: "pending")
        let key = ActivityHarvest.sessionKey(id: .cursor, sessionID: "s1", project: "", cwd: "")
        let r = build(harvest: [row], context: context(dismissed: [key]))
        XCTAssertFalse(r.rows[0].waiting, "a soft-dismissed pending must not come back")
    }

    func testPendingClearingReportsTheKeySoTheDismissCanBeForgotten() {
        let row = harvest(.cursor, task: "Done", session: "s1", skill: "")
        let key = ActivityHarvest.sessionKey(id: .cursor, sessionID: "s1", project: "", cwd: "")
        let r = build(harvest: [row], context: context(dismissed: [key]))
        XCTAssertTrue(r.clearedPendingKeys.contains(key))
    }

    // MARK: Waiting from hooks

    func testAttentionMatchesTheRowWithTheSameSession() {
        let r = build(
            harvest: [
                harvest(.claude, task: "A", session: "sess-aaa"),
                harvest(.claude, task: "B", session: "sess-bbb"),
            ],
            attention: [attention(.claude, message: "approve", session: "sess-bbb")]
        )
        let waiting = r.rows.filter(\.waiting)
        XCTAssertEqual(waiting.count, 1)
        XCTAssertEqual(waiting[0].sessionID, "sess-bbb", "must not light up the wrong session")
        XCTAssertEqual(waiting[0].waitSignal, .hooks)
    }

    func testAttentionFallsBackToCwdWhenSessionIsUnknown() {
        let r = build(
            harvest: [
                harvest(.codex, task: "A", session: "s1", cwd: "/work/alpha"),
                harvest(.codex, task: "B", session: "s2", cwd: "/work/beta"),
            ],
            attention: [attention(.codex, session: "", cwd: "/work/beta")]
        )
        XCTAssertEqual(r.rows.filter(\.waiting).map(\.cwd), ["/work/beta"])
    }

    func testAttentionWithNoMatchingRowCreatesOne() {
        let r = build(attention: [attention(.droid, message: "approve", session: "d1", cwd: "/work/x")])
        XCTAssertEqual(r.rows.count, 1)
        XCTAssertTrue(r.rows[0].waiting)
        XCTAssertEqual(r.rows[0].agent, .droid)
        XCTAssertEqual(r.rows[0].waitMessage, "approve")
    }

    func testHooksSignalOutranksHarvestPendingOnTheSameRow() {
        let r = build(
            harvest: [harvest(.codex, task: "A", session: "s1", skill: "pending")],
            attention: [attention(.codex, kind: "Permission", message: "approve", session: "s1")]
        )
        XCTAssertEqual(r.rows[0].waitSignal, .hooks, "hooks is the more credible signal")
        XCTAssertEqual(r.rows[0].waitKind, "Permission")
    }

    // MARK: Ordering

    func testWaitingSortsAboveEverythingElse() {
        let r = build(
            procs: [.init(id: .codex, count: 1, viaWarp: false, pid: 3)],
            harvest: [
                harvest(.codex, task: "Running work", session: "s1"),
                harvest(.gemini, task: "Needs input", session: "g1", skill: "pending"),
            ]
        )
        XCTAssertTrue(r.rows[0].waiting, "Waiting always leads")
    }

    func testTitledSessionsSortAboveProcessOnlyRows() {
        let r = build(
            procs: [.init(id: .aider, count: 1, viaWarp: false, pid: 4)],
            harvest: [harvest(.goose, task: "Real title", session: "g1")]
        )
        XCTAssertEqual(r.rows[0].agent, .goose)
        XCTAssertTrue(r.rows[1].isProcessOnly)
    }

    // MARK: Glance encoding

    func testSingleWaitingNamesTheAgent() {
        let r = build(harvest: [harvest(.claude, task: "x", session: "s1", skill: "pending")])
        XCTAssertEqual(r.snapshot.title, "Claude…")
        XCTAssertEqual(r.snapshot.headerTitle, L10n.t(.needsYou, .en))
    }

    /// A fresh wait says "now", which the lamp already conveys. The label
    /// earns its space by escalating once the number means something.
    func testSingleWaitGainsItsAgeOnceItIsWorthSaying() {
        let r = build(procs: [hit(.claude)], attention: [attention(.claude, ageMs: 240_000)])
        XCTAssertEqual(r.snapshot.title, "Claude · 4m")
    }

    func testFreshWaitDoesNotSpendMenuBarSpaceOnNow() {
        let r = build(procs: [hit(.claude)], attention: [attention(.claude, ageMs: 1_000)])
        XCTAssertEqual(r.snapshot.title, "Claude…")
    }

    func testMultipleWaitingCollapsesToACount() {
        let r = build(harvest: [
            harvest(.claude, task: "x", session: "s1", skill: "pending"),
            harvest(.codex, task: "y", session: "s2", skill: "pending"),
        ])
        XCTAssertEqual(r.snapshot.title, "2")
        XCTAssertTrue(r.snapshot.tooltip.contains("Claude"))
        XCTAssertTrue(r.snapshot.tooltip.contains("Codex"))
    }

    func testIdleGlanceCarriesNoTitle() {
        let r = build(harvest: [harvest(.claude, task: "old work", session: "s1")])
        XCTAssertEqual(r.snapshot.glance, .idle)
        XCTAssertEqual(r.snapshot.title, "", "Idle must stay quiet in the menu bar")
        XCTAssertEqual(r.activity, .recent)
    }

    func testGlanceFollowsTheResolvedLanguage() {
        let en = build(harvest: [harvest(.claude, task: "x", session: "s1", skill: "pending")])
        let zh = build(
            harvest: [harvest(.claude, task: "x", session: "s1", skill: "pending")],
            context: context(lang: .zh)
        )
        XCTAssertNotEqual(en.snapshot.headerTitle, zh.snapshot.headerTitle)
        XCTAssertEqual(zh.snapshot.headerTitle, L10n.t(.needsYou, .zh))
    }

    // MARK: Edges

    func testFirstSightOfAWaitIsReportedAsNew() {
        let r = build(harvest: [harvest(.claude, task: "x", session: "s1", skill: "pending")])
        XCTAssertEqual(r.newlyWaiting.count, 1)
    }

    func testAWaitAlreadyKnownIsNotReportedAgain() {
        let rows = [harvest(.claude, task: "x", session: "s1", skill: "pending")]
        let first = build(harvest: rows)
        let second = build(
            harvest: rows,
            previous: .init(rows: first.rows, waitingKeys: first.waitingKeys)
        )
        XCTAssertTrue(second.newlyWaiting.isEmpty, "edge-triggered, not level-triggered")
    }

    func testResolvedWaitsAreReported() {
        let waiting = build(harvest: [harvest(.claude, task: "x", session: "s1", skill: "pending")])
        let cleared = build(
            harvest: [harvest(.claude, task: "x", session: "s1")],
            previous: .init(rows: waiting.rows, waitingKeys: waiting.waitingKeys)
        )
        XCTAssertEqual(cleared.resolvedWaits.count, 1)
        XCTAssertTrue(cleared.newlyWaiting.isEmpty)
    }

    func testWentIdleOnlyFiresOnTheBusyToIdleTransition() {
        let busy = build(procs: [.init(id: .claude, count: 1, viaWarp: false, pid: 1)])
        let idle = build(previous: .init(rows: busy.rows, waitingKeys: busy.waitingKeys))
        XCTAssertTrue(idle.wentIdle)

        let stillIdle = build(previous: .init(rows: idle.rows, waitingKeys: idle.waitingKeys))
        XCTAssertFalse(stillIdle.wentIdle, "must not repeat every tick")
    }

    // MARK: Row window

    func testRowsFoldAtTheVisibleLimit() {
        let rows = (1...9).map { harvest(.claude, task: "T\($0)", session: "s\($0)") }
        let r = build(harvest: rows, context: context(maxSessions: 99, maxRows: 5))
        XCTAssertEqual(r.snapshot.rows.count, 5)
        XCTAssertEqual(r.snapshot.hiddenCount, 4)
        XCTAssertEqual(r.snapshot.totalCount, 9)
    }

    func testShowAllCollapsesOnceTheListIsShortAgain() {
        let r = build(
            harvest: [harvest(.claude, task: "A", session: "s1")],
            context: context(showAll: true, maxRows: 5)
        )
        XCTAssertFalse(r.showAllAgents, "expanded state must not stick when there is nothing to expand")
    }

    // MARK: Focus resolution

    func testFocusTierIsResolvedOncePerScanNotInTheView() {
        let env = TerminalFocus.Environment(
            warpRunning: false, ttyHostRunning: true, anyTerminalInstalled: true
        )
        let r = build(
            procs: [.init(id: .claude, count: 1, viaWarp: false, pid: 1, tty: "ttys004")],
            context: context(exists: { _ in true }, terminal: env)
        )
        XCTAssertEqual(r.rows[0].focusTier, .tty)
        XCTAssertTrue(r.rows[0].canFocusTerminal)
    }

    func testMissingPathsMeanNoOpenFolderAction() {
        let r = build(
            harvest: [harvest(.claude, task: "A", session: "s1", cwd: "/gone")],
            context: context(exists: { _ in false })
        )
        XCTAssertFalse(r.rows[0].canOpenFolder)
        XCTAssertNil(r.rows[0].focusTier)
    }

    // MARK: 0.24 — legibility

    /// Three agents blocked at once: the list has to answer "who first".
    func testWaitingRowsAreOrderedOldestFirst() {
        let r = build(
            procs: [hit(.claude), hit(.codex), hit(.cursor)],
            attention: [
                attention(.claude, ageMs: 60_000),
                attention(.codex, ageMs: 900_000),
                attention(.cursor, ageMs: 5_000),
            ]
        )
        let waiting = r.rows.filter(\.waiting)
        XCTAssertEqual(waiting.count, 3)
        XCTAssertEqual(waiting.map(\.agent), [.codex, .claude, .cursor], "oldest wait must lead")
    }

    /// An unknown wait start must not jump the queue by sorting as "epoch".
    func testUnknownWaitAgeSortsLastAmongWaiting() {
        var stale = attention(.cursor, ageMs: 0)
        stale.tsMs = 0
        let r = build(
            procs: [hit(.claude), hit(.cursor)],
            attention: [stale, attention(.claude, ageMs: 30_000)]
        )
        let waiting = r.rows.filter(\.waiting)
        XCTAssertEqual(waiting.first?.agent, .claude)
    }

    func testSectionTotalsCountTheWholeListNotTheWindow() {
        let r = build(
            procs: [hit(.claude), hit(.codex)],
            harvest: [harvest(.gemini, task: "build"), harvest(.aider, task: "test")],
            attention: [attention(.claude)],
            context: context(maxRows: 1)
        )
        XCTAssertEqual(r.snapshot.rows.count, 1, "window is one row")
        XCTAssertEqual(r.snapshot.sectionTotals[.needsYou], 1)
        XCTAssertGreaterThan(r.snapshot.sectionTotals[.running] ?? 0, 0)
        XCTAssertEqual(
            (r.snapshot.sectionTotals.values.reduce(0, +)),
            r.snapshot.totalCount,
            "totals must partition the full list"
        )
    }

    func testLongestWaitReachesTheSnapshot() {
        let r = build(
            procs: [hit(.claude), hit(.codex)],
            attention: [attention(.claude, ageMs: 30_000), attention(.codex, ageMs: 600_000)]
        )
        XCTAssertEqual(r.snapshot.longestWaitSeconds, 600, accuracy: 2)
    }

    func testNoWaitsMeansNoLongestWait() {
        let r = build(procs: [hit(.claude)], harvest: [harvest(.claude, task: "x")])
        XCTAssertEqual(r.snapshot.longestWaitSeconds, 0)
    }

    /// The menu bar has to carry count and age — that is the whole point of
    /// glancing at it instead of opening the panel.
    func testMenuBarTitleCarriesCountAndAge() {
        let r = build(
            procs: [hit(.claude), hit(.codex)],
            attention: [attention(.claude, ageMs: 120_000), attention(.codex, ageMs: 600_000)]
        )
        XCTAssertTrue(r.snapshot.title.contains("2"), "count missing from \(r.snapshot.title)")
        XCTAssertTrue(r.snapshot.title.contains("10m"), "age missing from \(r.snapshot.title)")
    }

    // MARK: 0.25 — the header may only speak in aggregates

    /// It was a constant ("just now"), then the agent names — which every row
    /// already carried. Now it says nothing rather than repeat them.
    func testHeaderStaysSilentWhenRowsSayItAll() {
        let r = build(procs: [hit(.claude)], attention: [attention(.claude)])
        XCTAssertEqual(r.snapshot.headerDetail, "", "must not restate what the rows show")
    }

    func testOneProjectIsNotWorthTheHeaderLine() {
        let r = build(harvest: [
            harvest(.claude, task: "a", session: "s1", cwd: "/tmp/alpha"),
            harvest(.codex, task: "b", session: "s2", cwd: "/tmp/alpha"),
        ])
        XCTAssertEqual(r.snapshot.projectCount, 1)
        XCTAssertEqual(r.snapshot.headerDetail, "")
    }

    /// Spread across projects is a genuine aggregate — no single row shows it.
    func testSpreadAcrossProjectsIsAnAggregateWorthSaying() {
        let r = build(harvest: [
            harvest(.claude, task: "a", session: "s1", cwd: "/tmp/alpha"),
            harvest(.codex, task: "b", session: "s2", cwd: "/tmp/beta"),
        ])
        XCTAssertEqual(r.snapshot.projectCount, 2)
        XCTAssertTrue(r.snapshot.headerDetail.contains("2"), r.snapshot.headerDetail)
    }

    func testHiddenRowsOutrankProjectSpread() {
        let rows = (1...9).map { harvest(.claude, task: "T\($0)", session: "s\($0)", cwd: "/tmp/p\($0)") }
        let r = build(harvest: rows, context: context(maxSessions: 99, maxRows: 3))
        XCTAssertGreaterThan(r.snapshot.hiddenCount, 0)
        XCTAssertTrue(r.snapshot.headerDetail.contains("\(r.snapshot.hiddenCount)"), r.snapshot.headerDetail)
    }

    /// The header said "2 running" above four rows.
    func testHeaderCountsEveryRowItSitsAbove() {
        let r = build(
            procs: [hit(.claude)],
            harvest: [
                harvest(.claude, task: "live", session: "s1", cwd: "/tmp/a"),
                harvest(.gemini, task: "done", session: "s2", cwd: "/tmp/b", ageMs: 60_000),
            ]
        )
        let running = r.snapshot.sectionTotals[.running] ?? 0
        let recent = r.snapshot.sectionTotals[.recent] ?? 0
        XCTAssertGreaterThan(recent, 0, "fixture needs a non-live row")
        XCTAssertTrue(
            r.snapshot.headerTitle.contains("\(running)") && r.snapshot.headerTitle.contains("\(recent)"),
            "header must account for every row: \(r.snapshot.headerTitle)"
        )
    }

    /// Two sessions in the home directory plus one whose project decoded to
    /// the same place were counted as three projects.
    func testHomeDoesNotInflateTheProjectCount() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let user = (home as NSString).lastPathComponent
        let r = build(harvest: [
            harvest(.claude, task: "a", session: "s1", cwd: home),
            harvest(.codex, task: "b", session: "s2", cwd: home),
            harvest(.amp, task: "c", session: "s3", project: "users-\(user)"),
            harvest(.gemini, task: "d", session: "s4", cwd: "/tmp/real"),
        ])
        XCTAssertEqual(r.snapshot.projectCount, 1, "only /tmp/real is a project")
    }

    /// Running with a live session is ordinary and gets no badge.
    func testOrdinaryRunningRowNeedsNoChip() {
        let r = build(
            procs: [hit(.claude)],
            harvest: [harvest(.claude, task: "Refactor", session: "s1", cwd: "/tmp/alpha")]
        )
        let row = try? XCTUnwrap(r.rows.first)
        XCTAssertEqual(row?.needsStatusChip, false)
    }

    func testProcessOnlyAndWaitingRowsDoGetAChip() {
        let r = build(procs: [hit(.amp)], attention: [attention(.claude)])
        for row in r.rows where row.waiting || row.isProcessOnly {
            XCTAssertTrue(row.needsStatusChip, "\(row.agent) should be badged")
        }
    }

    func testSectionsPartitionEveryRow() {
        let r = build(
            procs: [hit(.claude), hit(.codex)],
            harvest: [harvest(.gemini, task: "compile", ageMs: 1000)],
            attention: [attention(.claude)]
        )
        for row in r.rows {
            switch row.section {
            case .needsYou: XCTAssertTrue(row.waiting)
            case .running: XCTAssertTrue(row.liveProcess || row.subRunning > 0)
            case .recent: XCTAssertFalse(row.waiting)
            }
        }
    }

}
