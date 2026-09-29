import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

/// The merge core. Until 0.23 this logic lived inside `StatusStore.applyScan`
/// with zero coverage, despite being the single most regression-prone part of
/// the product.
final class SnapshotBuilderTests: XCTestCase {

    // MARK: Fixtures

    private let now: Int64 = 1_700_000_000_000

    /// No terminal anywhere — keeps focus resolution out of the way unless a
    /// test opts into it.
    private var bareTerminal: TerminalFocus.Environment {
        TerminalFocus.Environment(warpRunning: false, ttyHostRunning: false)
    }

    private func context(
        dismissed: Set<String> = [],
        showAll: Bool = false,
        maxSessions: Int = SnapshotBuilder.maxSessionsPerAgent,
        maxRows: Int = SnapshotBuilder.maxVisibleRows,
        terminal: TerminalFocus.Environment? = nil,
        lang: ResolvedLanguage = .en,
        stalledSeconds: Double = AgentRow.stalledSeconds
    ) -> SnapshotBuilder.Context {
        SnapshotBuilder.Context(
            nowMs: now,
            terminal: terminal ?? bareTerminal,
            lang: lang,
            maxSessionsPerAgent: maxSessions,
            maxVisibleRows: maxRows,
            dismissedPendingKeys: dismissed,
            showAllAgents: showAll,
            stalledSeconds: stalledSeconds
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
        subTotal: Int = 0,
        evidence: ObservationSource = .session,
        phase: String = "",
        mode: String = ""
    ) -> ActivityHarvest.Row {
        var row = ActivityHarvest.Row(
            id: id, task: task, project: project, cwd: cwd, skill: skill,
            tool: tool, harvestMs: now - ageMs,
            subRunning: subRunning, subTotal: subTotal, sessionID: session,
            evidence: evidence
        )
        row.phase = phase
        row.mode = mode
        return row
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
        previous: SnapshotBuilder.Previous = .init(),
        context ctx: SnapshotBuilder.Context? = nil
    ) -> SnapshotBuilder.Result {
        SnapshotBuilder.build(
            SnapshotBuilder.Input(
                procs: procs, harvest: rows, attention: entries
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

    func testStructuredObservabilityFactsSurviveMerge() {
        var source = harvest(
            .grok,
            task: "Fix multipart upload",
            session: "grok-1",
            cwd: "/Users/me/Pulse"
        )
        source.phase = "turn_complete"
        source.outcome = "completed"
        source.model = "grok-4.5"
        source.mode = "build-plan"
        source.errors = 1
        source.progressDone = 4

        source.lastWord = "Uploaded in 4 parts."
        source.planStep = "Retry the last part"

        let result = build(procs: [hit(.grok)], harvest: [source])
        let row = try! XCTUnwrap(result.rows.first)
        XCTAssertEqual(row.model, "grok-4.5")
        XCTAssertEqual(row.errors, 1)
        XCTAssertEqual(row.lastWord, "Uploaded in 4 parts.")
        XCTAssertEqual(row.planSteps.map(\.text), ["Retry the last part"], "a lone current step is still the plan")
        XCTAssertEqual(row.state, .recent)
        XCTAssertEqual(row.section, .recent, "a completed turn is not still Running just because its CLI stays open")
        XCTAssertFalse(row.isStalled, "completed work cannot simultaneously be stalled")
        XCTAssertEqual(result.snapshot.sectionTotals[.running], 0)
        XCTAssertEqual(result.snapshot.sectionTotals[.recent], 1)
        XCTAssertEqual(result.snapshot.glance, .idle)
    }

    func testOldCompletedSessionDoesNotRideForeverOnPersistentCLI() {
        var source = harvest(
            .codex,
            task: "Old completed work",
            session: "old",
            ageMs: ActivityHarvest.freshWindowMs + 1
        )
        source.phase = "turn_complete"
        source.outcome = "completed"

        let result = build(procs: [hit(.codex)], harvest: [source])
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertTrue(result.rows[0].isProcessOnly)
        XCTAssertNotEqual(result.rows[0].sessionID, "old")
        XCTAssertNil(result.rows[0].usefulTask)
    }

    /// 23.0: how a process was matched is Health's fact, kept by the scan
    /// engine — the row no longer carries it.
    func testLiveProcessDetectionEvidenceReachesHealth() {
        var process = hit(.amp)
        process.evidence = .pathSignature
        process.elapsedSeconds = 60
        let facts = ProcessFacts.byAgent([process], nowMs: now)
        XCTAssertEqual(facts[.amp]?.evidence, .pathSignature)
        XCTAssertEqual(facts[.amp]?.startedMs, now - 60_000)
    }

    func testLiveProcessSuppressesErrorEvenWhenHarvestFailed() {
        // An empty harvest is not a dead machine — `ps` still saw the agent.
        // Live Continuity: process-only is orange honesty, never the red error
        // lamp, and never a healthy green "fully observed" claim.
        let r = build(procs: [.init(id: .claude, count: 1, viaWarp: false, pid: 10)])
        XCTAssertEqual(r.snapshot.glance, .stalled, "probe-only liveness is not healthy green")
        XCTAssertNotEqual(r.snapshot.glance, .error)
        XCTAssertNil(r.snapshot.probeError)
    }

    func testRuntimeEvidenceTierSurvivesTheMerge() {
        let r = build(
            harvest: [
                harvest(.roo, task: "Refactor auth", evidence: .cache),
                harvest(.codex, task: "Fix parser", evidence: .session),
            ]
        )
        XCTAssertEqual(r.rows.first(where: { $0.agent == .roo })?.source, .cache)
        XCTAssertEqual(r.rows.first(where: { $0.agent == .codex })?.source, .session)
    }

    func testHarvestOnlySessionDoesNotInventAProcessCount() {
        let r = build(harvest: [
            harvest(.codex, task: "Review telemetry", session: "s1", cwd: "/work/Pulse")
        ])
        let row = try! XCTUnwrap(r.rows.first)
        XCTAssertFalse(row.liveProcess, "liveness comes only from ProcessProbe")
        XCTAssertEqual(row.pid, 0)
        XCTAssertEqual(row.source, .session)
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

    func testDefaultCapacityKeepsMoreThanFourConcurrentSessions() {
        let rows = (1...6).map {
            harvest(.cursor, task: "Cursor task \($0)", session: "cursor-\($0)")
        }
        let r = build(harvest: rows)
        XCTAssertEqual(r.rows.count, 6)
        XCTAssertEqual(r.snapshot.cappedSessions, 0)
        XCTAssertEqual(Set(r.rows.map(\.sessionID)), Set((1...6).map { "cursor-\($0)" }))
    }

    func testRemoteSessionWithExplicitRunningPhaseIsRunningWithoutLocalProcess() {
        let r = build(harvest: [
            harvest(
                .cursor,
                task: "Cloud task",
                session: "cloud-1",
                phase: "running",
                mode: "cloud"
            ),
        ])
        XCTAssertEqual(r.rows.first?.section, .running)
        XCTAssertFalse(r.rows.first?.isRecent ?? true)
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

    func testCollectorCanReportMoreThanTheDefaultSessionBudget() {
        let overflow = 12
        let rows = (1...(SnapshotBuilder.maxSessionsPerAgent + overflow)).map {
            harvest(.cursor, task: "Cursor task \($0)", session: "cursor-\($0)")
        }
        let r = build(harvest: rows)
        XCTAssertEqual(r.rows.count, SnapshotBuilder.maxSessionsPerAgent)
        XCTAssertEqual(r.snapshot.cappedSessions, overflow)
        XCTAssertEqual(r.rows.filter { $0.hiddenSessions > 0 }.count, 1)
    }

    func testTenConcurrentWaitingSessionsRemainIndependentAndVisible() {
        let agents = Array(AgentID.priority.prefix(10))
        let result = build(
            procs: agents.enumerated().map { index, agent in
                hit(agent, pid: 400 + index)
            },
            attention: agents.enumerated().map { index, agent in
                attention(
                    agent,
                    kind: index.isMultiple(of: 2) ? "Permission" : "Input",
                    message: "Approve session \(index + 1)",
                    session: "waiting-\(index + 1)",
                    ageMs: Int64((index + 1) * 1_000)
                )
            }
        )
        XCTAssertEqual(result.rows.filter(\.isBlocked).count, 10)
        XCTAssertEqual(result.newlyWaiting.count, 10)
        XCTAssertEqual(result.snapshot.sectionTotals[.needsYou], 10)
        XCTAssertEqual(result.snapshot.hiddenCount, 0, "ten waits fit within the twelve-row glance")
        XCTAssertEqual(Set(result.rows.filter(\.isBlocked).map(\.rowKey)).count, 10)
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

    func testOneStaleHarvestSurvivesWhenItIsTheOnlyProcessContext() {
        let stale = harvest(.gemini, task: "old", ageMs: ActivityHarvest.freshWindowMs + 60_000)
        let r = build(procs: [.init(id: .gemini, count: 1, viaWarp: false, pid: 7)], harvest: [stale])
        XCTAssertEqual(r.rows.count, 1)
        XCTAssertTrue(r.rows[0].liveProcess)
    }

    func testFreshSessionPreventsStaleSiblingsRidingTheSameLiveProcess() {
        var ancientWorking = harvest(
            .codex,
            task: "Ancient automation",
            session: "ancient-working",
            ageMs: 436 * 60 * 60 * 1000
        )
        ancientWorking.phase = "working"
        let ancientUnknown = harvest(
            .codex,
            task: "Ancient unknown",
            session: "ancient-unknown",
            ageMs: 552 * 60 * 60 * 1000
        )
        let current = harvest(
            .codex,
            task: "Current work",
            session: "current",
            ageMs: 1_000
        )

        let r = build(
            procs: [hit(.codex)],
            harvest: [ancientWorking, ancientUnknown, current]
        )
        XCTAssertEqual(r.rows.map(\.sessionID), ["current"])
        XCTAssertEqual(r.rows.filter(\.liveProcess).count, 1)
        XCTAssertEqual(r.snapshot.sectionTotals[.stalled], 0)
    }

    func testOnlyNewestStaleUnfinishedSessionCanBackLiveProcess() {
        let older = harvest(
            .amp,
            task: "Older known goal",
            session: "older",
            ageMs: ActivityHarvest.freshWindowMs + 120_000
        )
        let newer = harvest(
            .amp,
            task: "Newest known goal",
            session: "newer",
            ageMs: ActivityHarvest.freshWindowMs + 60_000
        )

        let r = build(procs: [hit(.amp)], harvest: [older, newer])
        XCTAssertEqual(r.rows.count, 1)
        XCTAssertEqual(r.rows.first?.sessionID, "newer")
        XCTAssertTrue(r.rows.first?.liveProcess ?? false)
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
        XCTAssertEqual(r.rows.filter { $0.pid == 42 }.count, 1, "the pid is not inherited")
        XCTAssertEqual(r.rows.filter { !$0.liveProcess && !$0.tty.isEmpty }.count, 0, "siblings are harvest-only")
    }

    func testLiveProcessWithNoHarvestStillProducesARow() {
        let r = build(procs: [.init(id: .amp, count: 1, viaWarp: true, pid: 9)])
        XCTAssertEqual(r.rows.count, 1)
        XCTAssertTrue(r.rows[0].liveProcess)
        XCTAssertTrue(r.rows[0].viaWarp)
        XCTAssertTrue(r.rows[0].isProcessOnly)
    }

    func testCursorAppProcessCreatesAnHonestFallbackRowWithoutAppData() {
        let r = build(procs: [
            .init(
                id: .cursor,
                count: 1,
                viaWarp: false,
                pid: 91,
                evidence: .pathSignature
            )
        ])
        XCTAssertEqual(r.rows.count, 1)
        XCTAssertEqual(r.rows[0].agent, .cursor)
        XCTAssertTrue(r.rows[0].liveProcess)
        XCTAssertTrue(r.rows[0].isProcessOnly)
        XCTAssertEqual(r.rows[0].rowKey, "cursor|pid:91")
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
        let r = build(harvest: [harvest(.gemini, task: "Ask", session: "s1", skill: "pending")])
        XCTAssertTrue(r.rows[0].isBlocked)
        XCTAssertEqual(r.rows[0].wait?.signal, .pending)
        XCTAssertEqual(r.snapshot.glance, .waiting)
    }

    /// 23.0: Cursor's on-disk format is `unverified` in vendor-formats.json,
    /// so its spec says `waiting: .none` — a harvest `pending` row from it is
    /// not evidence of a block and must never light the lamp.
    func testUnverifiedAgentHarvestPendingIsNotWaiting() {
        XCTAssertEqual(AgentID.cursor.waitingSource, .none)
        let r = build(harvest: [harvest(.cursor, task: "Ask", session: "s1", skill: "pending")])
        XCTAssertEqual(r.rows.count, 1)
        XCTAssertFalse(r.rows[0].isBlocked)
        XCTAssertNil(r.rows[0].wait)
        XCTAssertNotEqual(r.snapshot.glance, .waiting)
    }

    func testDismissedPendingStaysDismissed() {
        let row = harvest(.gemini, task: "Ask", session: "s1", skill: "pending")
        let key = RowIdentity.session(agent: .gemini, sessionID: "s1")
        let r = build(harvest: [row], context: context(dismissed: [key]))
        XCTAssertFalse(r.rows[0].isBlocked, "a soft-dismissed pending must not come back")
    }

    func testPendingClearingReportsTheKeySoTheDismissCanBeForgotten() {
        let row = harvest(.gemini, task: "Done", session: "s1", skill: "")
        let key = RowIdentity.session(agent: .gemini, sessionID: "s1")
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
        let waiting = r.rows.filter(\.isBlocked)
        XCTAssertEqual(waiting.count, 1)
        XCTAssertEqual(waiting[0].sessionID, "sess-bbb", "must not light up the wrong session")
        XCTAssertEqual(waiting[0].wait?.signal, .hooks)
    }

    func testCursorAgentAttentionUsesTheSingleCursorSurfaceRow() {
        let r = build(
            procs: [.init(id: .cursor, count: 1, viaWarp: false, pid: 77)],
            harvest: [harvest(.cursor, task: "Compose", session: "cursor-session")],
            attention: [attention(.cursorAgent, message: "approve", session: "cursor-session")]
        )
        XCTAssertEqual(r.rows.count, 1, "Cursor Agent is one user-facing Cursor session")
        XCTAssertEqual(r.rows.first?.agent, .cursor)
        XCTAssertTrue(r.rows.first?.isBlocked == true)
        XCTAssertEqual(r.rows.first?.wait?.signal, .hooks)
    }

    func testAttentionFallsBackToCwdWhenSessionIsUnknown() {
        let r = build(
            harvest: [
                harvest(.codex, task: "A", session: "s1", cwd: "/work/alpha"),
                harvest(.codex, task: "B", session: "s2", cwd: "/work/beta"),
            ],
            attention: [attention(.codex, session: "", cwd: "/work/beta")]
        )
        XCTAssertEqual(r.rows.filter(\.isBlocked).map(\.cwd), ["/work/beta"])
    }

    func testAttentionWithNoMatchingRowCreatesOne() {
        let r = build(attention: [attention(.droid, message: "approve", session: "d1", cwd: "/work/x")])
        XCTAssertEqual(r.rows.count, 1)
        XCTAssertTrue(r.rows[0].isBlocked)
        XCTAssertEqual(r.rows[0].agent, .droid)
        XCTAssertEqual(r.rows[0].wait?.ask, "approve")
        XCTAssertEqual(r.rows[0].rowKey, "droid|d1")
        XCTAssertEqual(r.rows[0].source, .hooks)
    }

    func testAttentionUnknownSessionDoesNotLightSiblingRows() {
        let r = build(
            harvest: [
                harvest(.claude, task: "A", session: "sess-aaa"),
                harvest(.claude, task: "B", session: "sess-bbb"),
            ],
            attention: [attention(.claude, message: "approve tool", session: "sess-zzz")]
        )
        let waiting = r.rows.filter(\.isBlocked)
        XCTAssertEqual(waiting.count, 1, "must create a dedicated Waiting row")
        XCTAssertEqual(waiting[0].sessionID, "sess-zzz")
        XCTAssertEqual(waiting[0].wait?.ask, "approve tool")
        XCTAssertEqual(waiting[0].wait?.signal, .hooks)
        let siblings = r.rows.filter { ["sess-aaa", "sess-bbb"].contains($0.sessionID) }
        XCTAssertEqual(siblings.count, 2)
        XCTAssertTrue(siblings.allSatisfy { !$0.isBlocked }, "named session must not smear onto siblings")
    }

    /// 23.0: a process-only row never adopts a wait. The hook's session
    /// gets its own row — keyed like the session it names — and the
    /// process attaches to it, so there is still one row.
    func testAttentionNamedSessionMakesOneRowWithTheProcess() {
        let r = build(
            procs: [hit(.codex, pid: 42)],
            attention: [attention(.codex, message: "approve shell", session: "codex-wait-1")]
        )
        XCTAssertEqual(r.rows.count, 1, "the process attaches to the hook's row")
        XCTAssertTrue(r.rows[0].isBlocked)
        XCTAssertEqual(r.rows[0].sessionID, "codex-wait-1")
        XCTAssertTrue(r.rows[0].liveProcess)
        XCTAssertEqual(r.rows[0].rowKey, "codex|codex-wait-1")
        XCTAssertEqual(r.snapshot.hiddenCount, 0)
    }

    func testTheSameWaitNextScanIsNotANewEdge() {
        let first = build(
            procs: [hit(.codex, pid: 42)],
            attention: [attention(.codex, message: "approve shell", session: "codex-wait-1")]
        )
        XCTAssertEqual(first.newlyWaiting.count, 1)
        let second = build(
            procs: [hit(.codex, pid: 42)],
            attention: [attention(.codex, message: "approve shell", session: "codex-wait-1")],
            previous: .init(rows: first.rows, waitingKeys: first.waitingKeys)
        )
        XCTAssertTrue(second.newlyWaiting.isEmpty, "the key never moved, so nothing is new")
        XCTAssertTrue(second.resolvedWaits.isEmpty)
        XCTAssertEqual(second.rows[0].rowKey, "codex|codex-wait-1")
    }

    func testHooksSignalOutranksHarvestPendingOnTheSameRow() {
        let r = build(
            harvest: [harvest(.codex, task: "A", session: "s1", skill: "pending")],
            attention: [attention(.codex, kind: "Permission", message: "approve", session: "s1")]
        )
        XCTAssertEqual(r.rows[0].wait?.signal, .hooks, "hooks is the more credible signal")
        XCTAssertEqual(r.rows[0].wait?.kind, "Permission")
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
        XCTAssertTrue(r.rows[0].isBlocked, "Waiting always leads")
    }

    func testActiveRowsSortAboveRecentTitledSessions() {
        let r = build(
            procs: [.init(id: .aider, count: 1, viaWarp: false, pid: 4)],
            harvest: [harvest(.goose, task: "Real title", session: "g1")]
        )
        XCTAssertEqual(r.rows[0].agent, .aider)
        XCTAssertTrue(r.rows[0].isProcessOnly)
        XCTAssertEqual(r.rows[1].agent, .goose)
    }

    // MARK: Glance encoding

    func testSingleWaitingNamesTheAgent() {
        let r = build(harvest: [harvest(.claude, task: "x", session: "s1", skill: "pending")])
        XCTAssertEqual(r.snapshot.title, "Claude…")
        XCTAssertEqual(r.snapshot.headerTitle, "1 \(L10n.t(.waitingN, .en))")
    }

    /// A fresh wait says "now", which the lamp already conveys. The label
    /// earns its space by escalating once the number means something.
    func testSingleWaitGainsItsAgeOnceItIsWorthSaying() {
        let r = build(procs: [hit(.claude)], attention: [attention(.claude, ageMs: 240_000)])
        XCTAssertEqual(r.snapshot.title, "1 · 4m")
        XCTAssertLessThanOrEqual(GlanceTitle.cells(r.snapshot.title), GlanceTitle.maxCells)
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
        XCTAssertEqual(zh.snapshot.headerTitle, "1 \(L10n.t(.waitingN, .zh))")
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
            warpRunning: true, ttyHostRunning: false
        )
        let r = build(
            procs: [.init(id: .claude, count: 1, viaWarp: true, pid: 1, tty: "ttys004")],
            context: context(terminal: env)
        )
        XCTAssertEqual(r.rows[0].focusTier, .warp)
        XCTAssertTrue(r.rows[0].canFocusTerminal)
    }

    func testHostAppFocusTierIsResolvedFromProcessHit() {
        var proc = ProcessProbe.Hit(id: .claude, count: 1, viaWarp: false, pid: 11)
        proc.hostApp = .cursor
        let r = build(procs: [proc], context: context())
        XCTAssertEqual(r.rows[0].hostApp, .cursor)
        XCTAssertEqual(r.rows[0].focusTier, .hostApp(.cursor))
        XCTAssertTrue(r.rows[0].canFocusTerminal)
    }

    func testHostWorkspaceFocusTierUsesAbsoluteCwd() {
        var proc = ProcessProbe.Hit(id: .claude, count: 1, viaWarp: false, pid: 12)
        proc.hostApp = .vsCode
        let r = build(
            procs: [proc],
            harvest: [harvest(.claude, task: "A", session: "s1", cwd: "/Users/me/work")],
            context: context()
        )
        XCTAssertEqual(r.rows[0].focusTier, .hostWorkspace(.vsCode))
    }

    func testRowsWithoutFocusHaveNoPrimaryNavigationAction() {
        let r = build(
            harvest: [harvest(.claude, task: "A", session: "s1", cwd: "/gone")]
        )
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
        let waiting = r.rows.filter(\.isBlocked)
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
        let waiting = r.rows.filter(\.isBlocked)
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

    // MARK: Stall threshold

    func testTheStallThresholdComesFromTheContext() {
        let quiet = harvest(.claude, task: "build", ageMs: 7 * 60 * 1000)
        let strict = build(
            procs: [hit(.claude)], harvest: [quiet], context: context(stalledSeconds: 5 * 60)
        )
        XCTAssertTrue(strict.rows.contains { $0.isStalled })

        let lenient = build(
            procs: [hit(.claude)], harvest: [quiet], context: context(stalledSeconds: 60 * 60)
        )
        XCTAssertFalse(lenient.rows.contains { $0.isStalled })
    }

    func testStallCanBeTurnedOffEntirely() {
        let r = build(
            procs: [hit(.claude)],
            harvest: [harvest(.claude, task: "build", ageMs: 10 * 60 * 60 * 1000)],
            context: context(stalledSeconds: 0)
        )
        XCTAssertFalse(r.rows.contains { $0.isStalled })
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

    /// A long-silent live session is worth a badge; the builder decides that
    /// against the scan's clock, so it is deterministic.
    func testLongSilenceIsMarkedStalledAtScanTime() {
        let r = build(
            procs: [hit(.claude)],
            harvest: [harvest(.claude, task: "x", session: "s1", ageMs: 30 * 60 * 1000)]
        )
        XCTAssertEqual(r.rows.first?.isStalled, true)
        XCTAssertEqual(r.rows.first?.section, .stalled)
        XCTAssertEqual(r.snapshot.sectionTotals[.stalled], 1)
        XCTAssertEqual(r.snapshot.sectionTotals[.running], 0)
        XCTAssertEqual(r.snapshot.glance, .stalled)
    }

    func testHeaderSeparatesActiveStalledAndRecent() {
        let r = build(
            procs: [hit(.claude), hit(.codex)],
            harvest: [
                harvest(.claude, task: "active", session: "s1", ageMs: 1_000),
                harvest(.codex, task: "quiet", session: "s2", ageMs: 30 * 60 * 1000),
                harvest(.gemini, task: "done", session: "s3", ageMs: 60_000),
            ]
        )
        XCTAssertEqual(r.snapshot.sectionTotals[.running], 1)
        XCTAssertEqual(r.snapshot.sectionTotals[.stalled], 1)
        XCTAssertEqual(r.snapshot.sectionTotals[.recent], 1)
        XCTAssertTrue(r.snapshot.headerTitle.contains("1 running"), r.snapshot.headerTitle)
        XCTAssertTrue(r.snapshot.headerTitle.lowercased().contains("1 stalled"), r.snapshot.headerTitle)
        XCTAssertTrue(r.snapshot.headerTitle.contains("1 recent"), r.snapshot.headerTitle)
        // Live Continuity: stall wins the lamp over a healthy runner.
        XCTAssertEqual(r.snapshot.glance, .stalled)
        XCTAssertTrue(r.snapshot.tooltip.lowercased().contains("stalled"), r.snapshot.tooltip)
    }

    /// A hook activity event moves the live clock even when the transcript's
    /// mtime did not — that is still live, not stalled.
    func testALiveActivityEventPreventsAFalseStall() {
        let quiet = harvest(.claude, task: "build", session: "s1", ageMs: 30 * 60 * 1000)
        let prior = build(procs: [hit(.claude)], harvest: [quiet], context: context(stalledSeconds: 5 * 60))
        XCTAssertEqual(prior.rows.first?.isStalled, true)

        let event = ActivitySpool.Event(
            agent: "claude", session: "s1", event: "tool", tool: "Bash", target: "",
            prompt: "", cwd: "", tsMs: now - 10_000
        )
        let moved = SnapshotBuilder.build(
            SnapshotBuilder.Input(procs: [hit(.claude)], harvest: [quiet], activity: [event]),
            previous: .init(rows: prior.rows, waitingKeys: []),
            context: context(stalledSeconds: 5 * 60)
        )
        XCTAssertEqual(moved.rows.first?.activityMs, now - 10_000)
        XCTAssertFalse(moved.rows.contains { $0.isStalled }, "a live event must refresh the stall clock")
        XCTAssertEqual(moved.snapshot.glance, .running)
    }

    /// Process-only liveness is orange in the tray — the menu bar must not claim healthy green.
    func testProcessOnlyRunningIsNotHealthyGreenGlance() {
        let r = build(procs: [hit(.amp)])
        XCTAssertTrue(r.rows.contains { $0.isProcessOnly && $0.section == .running })
        XCTAssertEqual(r.snapshot.glance, .stalled)
        XCTAssertNotEqual(r.snapshot.glance, .running)
    }

    /// Running with a live session is ordinary and gets no badge.
    func testOrdinaryRunningRowNeedsNoChip() throws {
        let r = build(
            procs: [hit(.claude)],
            harvest: [harvest(.claude, task: "Refactor", session: "s1", cwd: "/tmp/alpha")]
        )
        let row = try XCTUnwrap(r.rows.first)
        let face = TrayRowModel.make(TrayRowModel.Input(row: row, lang: .en, nowMs: now))
        XCTAssertNil(face.chip)
        XCTAssertEqual(face.lamp, .running)
        XCTAssertEqual(r.snapshot.glance, .running)
    }

    func testProcessOnlyAndWaitingRowsLookDifferent() {
        let r = build(procs: [hit(.amp)], attention: [attention(.claude)])
        for row in r.rows {
            let face = TrayRowModel.make(TrayRowModel.Input(row: row, lang: .en, nowMs: now))
            if row.isBlocked {
                XCTAssertEqual(face.chip?.kind, .waiting, "\(row.agent) should be badged")
            } else {
                XCTAssertEqual(face.lamp, .process, "\(row.agent) should read as a process")
            }
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
            case .needsYou: XCTAssertTrue(row.isBlocked)
            case .running: XCTAssertTrue(row.liveProcess || row.state == .running)
            case .stalled: XCTAssertTrue(row.isStalled)
            case .recent: XCTAssertFalse(row.isBlocked)
            }
        }
    }

    func testHarvestApprovalToolIsPermissionWaitKind() {
        let r = build(harvest: [
            harvest(.cline, task: "Ask", session: "s1", skill: "pending", tool: "request_approval"),
        ])
        XCTAssertTrue(r.rows[0].isBlocked)
        XCTAssertEqual(r.rows[0].wait?.kind, "Permission")
    }

    func testHarvestFollowupToolStaysInputWaitKind() {
        let r = build(harvest: [
            harvest(.roo, task: "Ask", session: "s1", skill: "pending", tool: "ask_followup_question"),
        ])
        XCTAssertTrue(r.rows[0].isBlocked)
        XCTAssertEqual(r.rows[0].wait?.kind, "Input")
    }

    func testSectionTotalsCountTheFleetNotTheWindow() {
        let rows = (1...15).map {
            harvest(.claude, task: "T\($0)", session: "s\($0)", cwd: "/tmp/p", ageMs: 60_000)
        }
        let r = build(harvest: rows, context: context(maxSessions: 99, maxRows: 12))
        XCTAssertEqual(r.snapshot.sectionTotals[.recent], 15)
        XCTAssertEqual(r.snapshot.rows.count, 12)
        XCTAssertEqual(r.snapshot.hiddenCount, 3)
    }

    // MARK: Row key stability (U-6)

    /// The suffix used to be "how many rows of this agent came before me",
    /// which is a fact about the array, not about the session. Two scans that
    /// enumerate the same two sessions in opposite order must still address
    /// the same rows — soft-dismiss and notification de-duplication are
    /// stored against `rowKey`.
    func testRowKeysSurviveADifferentHarvestOrder() throws {
        let a = harvest(.codex, task: "Fix auth", project: "/w/Repo", cwd: "/w/Repo/api")
        let b = harvest(.codex, task: "Write docs", project: "/w/Repo", cwd: "/w/Repo/docs")

        let forward = build(harvest: [a, b])
        let backward = build(harvest: [b, a])

        let forwardKeys = Dictionary(
            uniqueKeysWithValues: forward.rows.map { ($0.cwd, $0.rowKey) }
        )
        let backwardKeys = Dictionary(
            uniqueKeysWithValues: backward.rows.map { ($0.cwd, $0.rowKey) }
        )
        XCTAssertEqual(forwardKeys.count, 2)
        XCTAssertEqual(forwardKeys, backwardKeys, "row identity must not depend on harvest order")
    }

    /// A dismissal made while two sessions shared a project must survive the
    /// sibling going stale. Under the ordinal suffix the survivor silently
    /// changed key, and the dismissal went with it.
    func testARowKeepsItsKeyWhenASiblingSessionDisappears() throws {
        let a = harvest(.codex, task: "Fix auth", project: "/w/Repo", cwd: "/w/Repo/api")
        let b = harvest(.codex, task: "Write docs", project: "/w/Repo", cwd: "/w/Repo/docs")

        let both = build(harvest: [a, b])
        let alone = build(harvest: [a])

        let pairKey = try XCTUnwrap(both.rows.first { $0.cwd == "/w/Repo/api" }?.rowKey)
        let soloKey = try XCTUnwrap(alone.rows.first { $0.cwd == "/w/Repo/api" }?.rowKey)
        XCTAssertEqual(pairKey, soloKey)
    }

    /// A dismissal outlives a relaunch, so the key has to as well. `hashValue` is
    /// seeded per process; this digest is not, and the literal below is the
    /// wall that keeps it that way.
    func testTheIdentityDigestIsTheSameInEveryProcess() {
        XCTAssertEqual(RowIdentity.stableHash("pulse"), "b3f797f2")
        XCTAssertEqual(RowIdentity.stableHash("c:/w/Repo/api"), RowIdentity.stableHash("c:/w/Repo/api"))
        XCTAssertNotEqual(RowIdentity.stableHash("c:/w/Repo/api"), RowIdentity.stableHash("c:/w/Repo/docs"))
    }

    /// Sessions a moving title cannot be told apart by anything else still get
    /// two rows, and the same two keys next time.
    func testTitleOnlySessionsStillGetStableDistinctKeys() {
        let a = harvest(.codex, task: "A", project: "/a/Repo")
        let b = harvest(.codex, task: "B", project: "/a/Repo")
        let first = build(harvest: [a, b])
        let second = build(harvest: [b, a])
        XCTAssertEqual(Set(first.rows.map(\.rowKey)).count, 2)
        XCTAssertEqual(Set(first.rows.map(\.rowKey)), Set(second.rows.map(\.rowKey)))
    }

    /// A session id already makes the key unique; it must not gain a suffix.
    func testASessionIdKeyIsLeftAlone() throws {
        let r = build(harvest: [harvest(.claude, task: "Fix", session: "s-1", cwd: "/w/Repo")])
        XCTAssertEqual(r.rows.first?.rowKey, "claude|s-1")
    }

    // MARK: Soft-dismiss bookkeeping (U-5)

    /// `clearedPendingKeys` is what the store should forget, not a census of
    /// every row that is not pending. Reporting the latter made the store
    /// rewrite `dismissed-pending.json` every scan for an unchanged set.
    func testClearedPendingOnlyNamesKeysTheStoreIsActuallyHolding() {
        let running = harvest(.cursor, task: "Refactor", session: "s1")
        let idle = build(harvest: [running])
        XCTAssertTrue(
            idle.clearedPendingKeys.isEmpty,
            "a plain running session has no soft dismiss to clear"
        )

        let key = RowIdentity.session(agent: .cursor, sessionID: "s1")
        let held = build(harvest: [running], context: context(dismissed: [key]))
        XCTAssertEqual(held.clearedPendingKeys, [key])
    }

    // MARK: A cleared wait is a resolved wait

    func testAWaitThatClearedIsRecordedAsResolved() {
        let raised = AttentionReader.Entry(
            id: .claude,
            kind: "Permission",
            message: "Approve deploy",
            tsMs: now - 60_000,
            session: "s-2",
            cwd: "/srv/app"
        )
        let lit = build(attention: [raised])
        let cleared = build(previous: .init(rows: lit.rows, waitingKeys: lit.waitingKeys))
        XCTAssertEqual(cleared.resolvedWaits.count, 1)
    }

    // MARK: Tooltip copy (U-9)

    /// `Permission` is a protocol token. A Chinese tray showing a bare English
    /// word in the glance tooltip is the same defect as any other untranslated
    /// string — EXPERIENCE §4 admits no exceptions.
    func testTheGlanceTooltipTranslatesTheWaitKind() {
        let entry = attention(.claude, kind: "Permission", message: "", session: "s1")
        let zh = build(attention: [entry], context: context(lang: .zh))
        XCTAssertTrue(
            zh.snapshot.tooltip.contains(L10n.t(.kindPermission, .zh)),
            "tooltip was \(zh.snapshot.tooltip)"
        )
        XCTAssertFalse(zh.snapshot.tooltip.contains("Permission"))

        let en = build(attention: [entry], context: context(lang: .en))
        XCTAssertTrue(en.snapshot.tooltip.contains(L10n.t(.kindPermission, .en)))
    }

    /// 22.0: "N older hidden" counts sessions that went quiet today, not
    /// every transcript ever written.
    func testStaleHiddenCountsOnlyTheLastDay() {
        let r = build(
            harvest: [
                harvest(.claude, task: "earlier", session: "s1", ageMs: 3 * 60 * 60 * 1000),
                harvest(.claude, task: "last month", session: "s2", ageMs: 30 * 24 * 60 * 60 * 1000),
            ]
        )
        XCTAssertEqual(r.snapshot.staleHidden, 1)
    }
}
