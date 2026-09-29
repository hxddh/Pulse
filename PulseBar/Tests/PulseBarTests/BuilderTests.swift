import Foundation
import AppKit
import SQLite3
import Testing
import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

// Builder: SnapshotBuilder, row identity, row state and what a row carries.

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
        // 23.0: a process with no session is a grey dotted lamp — never the
        // error lamp, never orange, never a healthy green claim.
        let r = build(procs: [.init(id: .claude, count: 1, viaWarp: false, pid: 10)])
        XCTAssertEqual(r.snapshot.glance, .idle, "probe-only liveness is not green and not orange")
        XCTAssertEqual(r.snapshot.lamp, LampFace(shape: .dotted, tone: .idle))
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

    /// 23.0: a hook entry that names no session never lands on a row that
    /// owns one — its `done` could not name that row's session — so it
    /// keeps its own `agent|hook:<folder>` row, in its folder.
    func testASessionlessHookKeepsItsOwnRowBesideSessionRows() {
        let r = build(
            harvest: [
                harvest(.codex, task: "A", session: "s1", cwd: "/work/alpha"),
                harvest(.codex, task: "B", session: "s2", cwd: "/work/beta"),
            ],
            attention: [attention(.codex, session: "", cwd: "/work/beta")]
        )
        let blocked = r.rows.filter(\.isBlocked)
        XCTAssertEqual(blocked.map(\.cwd), ["/work/beta"])
        XCTAssertEqual(blocked.first?.rowKey, RowIdentity.hook(agent: .codex, session: "", cwd: "/work/beta"))
        XCTAssertEqual(blocked.first?.attentionSession, "")
        XCTAssertFalse(r.rows.contains { $0.sessionID == "s2" && $0.isBlocked }, "the session row stays as it was")
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

    /// 23.0: the menu bar says how many are blocked and how long the oldest
    /// has waited — never a name.
    func testSingleWaitingIsACount() {
        let r = build(harvest: [harvest(.claude, task: "x", session: "s1", skill: "pending")])
        XCTAssertEqual(r.snapshot.title, "1")
        XCTAssertEqual(r.snapshot.headerTitle, "1 \(L10n.t(.waiting1, .en))", "one needs you, not \"1 need you\"")
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
        XCTAssertEqual(r.snapshot.title, "1")
    }

    /// 23.0: the icon alone unless something is blocked.
    func testNothingBlockedMeansNoTitle() {
        let r = build(procs: [hit(.claude)], harvest: [harvest(.claude, task: "x", session: "s1")])
        XCTAssertEqual(r.snapshot.glance, .running)
        XCTAssertEqual(r.snapshot.title, "")
    }

    func testMultipleWaitingCollapsesToACount() {
        let r = build(harvest: [
            harvest(.claude, task: "x", session: "s1", skill: "pending"),
            harvest(.codex, task: "y", session: "s2", skill: "pending"),
        ])
        XCTAssertEqual(r.snapshot.title, "2")
        // 23.0: one line — the rule, not a list of who.
        XCTAssertEqual(r.snapshot.tooltip, L10n.t(.lampRuleBlocked, .en))
        XCTAssertFalse(r.snapshot.tooltip.contains("\n"))
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
        XCTAssertEqual(zh.snapshot.headerTitle, "1 \(L10n.t(.waiting1, .zh))")
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
        XCTAssertEqual(r.snapshot.tooltip, L10n.t(.lampRuleStalled, .en))
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

    /// 23.0: process-only liveness is grey and dotted — the menu bar
    /// claims neither healthy green nor an orange problem.
    func testProcessOnlyRunningIsAGreyDottedGlance() {
        let r = build(procs: [hit(.amp)])
        XCTAssertTrue(r.rows.contains { $0.isProcessOnly && $0.section == .running })
        XCTAssertEqual(r.snapshot.glance, .idle)
        XCTAssertEqual(r.snapshot.lamp.shape, .dotted)
        XCTAssertEqual(r.snapshot.tooltip, L10n.t(.lampRuleProcessOnly, .en))
    }

    /// Running with a live session is ordinary and gets no badge.
    func testOrdinaryRunningRowNeedsNoChip() throws {
        let r = build(
            procs: [hit(.claude)],
            harvest: [harvest(.claude, task: "Refactor", session: "s1", cwd: "/tmp/alpha")]
        )
        let row = try XCTUnwrap(r.rows.first)
        let face = TrayRowModel.make(TrayRowModel.Input(row: row, lang: .en, nowMs: now))
        XCTAssertNil(face.secondLine)
        XCTAssertEqual(face.lamp, LampFace(shape: .ring, tone: .running))
        XCTAssertEqual(r.snapshot.glance, .running)
    }

    func testProcessOnlyAndWaitingRowsLookDifferent() {
        let r = build(procs: [hit(.amp)], attention: [attention(.claude)])
        for row in r.rows {
            let face = TrayRowModel.make(TrayRowModel.Input(row: row, lang: .en, nowMs: now))
            if row.isBlocked {
                XCTAssertEqual(face.lamp, LampFace(shape: .filled, tone: .waiting), "\(row.agent) should be filled red")
            } else {
                XCTAssertEqual(face.lamp, LampFace(shape: .dotted, tone: .idle), "\(row.agent) should read as a process")
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
    func testTheGlanceTooltipIsInTheResolvedLanguage() {
        let entry = attention(.claude, kind: "Permission", message: "", session: "s1")
        let zh = build(attention: [entry], context: context(lang: .zh))
        XCTAssertEqual(zh.snapshot.tooltip, L10n.t(.lampRuleBlocked, .zh))
        XCTAssertFalse(zh.snapshot.tooltip.contains("Permission"))

        let en = build(attention: [entry], context: context(lang: .en))
        XCTAssertEqual(en.snapshot.tooltip, L10n.t(.lampRuleBlocked, .en))
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

/// 23.0 · a row's key is decided once (`RowIdentity`) and never changes; a
/// process-only row never "upgrades" into a session — it disappears when a
/// session row for its agent exists. These replace the remap tests: there
/// is nothing left to remap.
@Suite("Row identity")
struct RowIdentityTests {
    let now: Int64 = 1_800_000_000_000
    let minute: Int64 = 60_000

    private var context: SnapshotBuilder.Context {
        SnapshotBuilder.Context(
            nowMs: now,
            terminal: TerminalFocus.Environment(warpRunning: false, ttyHostRunning: false),
            lang: .en
        )
    }

    private func hit(_ id: AgentID, pid: Int = 4242, cwd: String = "") -> ProcessProbe.Hit {
        var value = ProcessProbe.Hit(id: id, count: 1, viaWarp: false, pid: pid, tty: "ttys004")
        value.cwd = cwd
        return value
    }

    private func session(
        _ id: AgentID,
        _ sessionID: String,
        task: String = "Fix the login test",
        cwd: String = "/w/app",
        ageMs: Int64 = 30_000
    ) -> ActivityHarvest.Row {
        ActivityHarvest.Row(
            id: id, task: task, project: "", cwd: cwd, skill: "",
            harvestMs: now - ageMs, sessionID: sessionID, evidence: .session
        )
    }

    private func attention(
        _ id: AgentID, kind: String = "Permission", session: String = "", cwd: String = "", ageMs: Int64 = 5_000
    ) -> AttentionReader.Entry {
        AttentionReader.Entry(id: id, kind: kind, message: "Bash: npm test", tsMs: now - ageMs, session: session, cwd: cwd)
    }

    private func build(
        procs: [ProcessProbe.Hit] = [],
        harvest: [ActivityHarvest.Row] = [],
        attention: [AttentionReader.Entry] = [],
        previous: SnapshotBuilder.Previous = .init(),
        at nowMs: Int64? = nil
    ) -> SnapshotBuilder.Result {
        var ctx = context
        if let nowMs { ctx.nowMs = nowMs }
        return SnapshotBuilder.build(
            SnapshotBuilder.Input(procs: procs, harvest: harvest, attention: attention),
            previous: previous,
            context: ctx
        )
    }

    // MARK: - The keys

    @Test func eachKindOfRowHasItsOwnKey() {
        #expect(RowIdentity.session(agent: .claude, sessionID: "abc") == "claude|abc")
        #expect(RowIdentity.process(agent: .codex, pid: 7) == "codex|pid:7")
        #expect(RowIdentity.hook(agent: .claude, session: "abc", cwd: "/w") == "claude|abc",
                "a hook naming a session takes that session's key")
        let byFile = RowIdentity.session(agent: .gemini, sessionID: "", transcriptPath: "/Users/me/.gemini/chat.json")
        #expect(byFile.hasPrefix("gemini|file:"))
        #expect(!byFile.contains("/Users/me"), "a key never carries a path")
        #expect(RowIdentity.isProcessKey("codex|pid:7"))
        #expect(!RowIdentity.isProcessKey("codex|abc"))
    }

    @Test func theHashIsStableAcrossLaunches() {
        #expect(RowIdentity.stableHash("pulse") == "b3f797f2")
        #expect(RowIdentity.stableHash("c:/w/Repo/api") != RowIdentity.stableHash("c:/w/Repo/docs"))
    }

    @Test func cursorAgentSessionsAreKeyedAsCursor() {
        #expect(RowIdentity.session(agent: .cursorAgent, sessionID: "s") == "cursor|s")
    }

    // MARK: - (a) a process and a session of the same agent are one row

    @Test func aProcessAndASessionForTheSameAgentAndFolderAreOneRow() throws {
        let r = build(procs: [hit(.claude, cwd: "/w/app")], harvest: [session(.claude, "s1")])
        #expect(r.rows.count == 1)
        let row = try #require(r.rows.first)
        #expect(row.rowKey == "claude|s1", "the session row, never the process row")
        #expect(row.liveProcess)
        #expect(row.pid == 4242)
        #expect(row.state == .running)
    }

    @Test func aProcessAloneIsAnEphemeralProcessOnlyRow() throws {
        let r = build(procs: [hit(.claude, cwd: "/w/app")])
        let row = try #require(r.rows.first)
        #expect(row.rowKey == "claude|pid:4242")
        #expect(row.isProcessOnly)
        #expect(row.source == .process)
    }

    @Test func whenTheSessionAppearsTheProcessRowSimplyGoes() throws {
        let first = build(procs: [hit(.claude, cwd: "/w/app")])
        let second = build(
            procs: [hit(.claude, cwd: "/w/app")], harvest: [session(.claude, "s1")],
            previous: .init(rows: first.rows, waitingKeys: first.waitingKeys)
        )
        let keys = second.rows.map { $0.rowKey }
        #expect(keys == ["claude|s1"])
    }

    // MARK: - (b) a session row keeps its key as its facts change

    @Test func aSessionRowKeepsItsKeyAcrossScansAsFactsChange() throws {
        let a = build(harvest: [session(.claude, "s1", task: "First title", ageMs: 60_000)])
        var moved = session(.claude, "s1", task: "Renamed by the vendor", cwd: "/w/app/sub", ageMs: 1_000)
        moved.lastWord = "Done with step one."
        moved.errors = 2
        let b = build(procs: [hit(.claude)], harvest: [moved], previous: .init(rows: a.rows, waitingKeys: a.waitingKeys))
        let c = build(
            procs: [hit(.claude)], harvest: [moved], attention: [attention(.claude, session: "s1")],
            previous: .init(rows: b.rows, waitingKeys: b.waitingKeys)
        )
        let keyA = try #require(a.rows.first?.rowKey)
        let keyB = try #require(b.rows.first?.rowKey)
        let rowC = try #require(c.rows.first)
        #expect(keyA == "claude|s1")
        #expect(keyB == keyA)
        #expect(rowC.rowKey == keyA)
        #expect(rowC.isBlocked)
        let edges = c.newlyWaiting.map { $0.rowKey }
        #expect(edges == ["claude|s1"])
    }

    @Test func aHookWaitBeforeTheTranscriptKeepsItsKeyWhenTheTranscriptAppears() throws {
        let wait = attention(.claude, session: "s9", cwd: "/w/app")
        let first = build(procs: [hit(.claude)], attention: [wait])
        let hookRow = try #require(first.rows.first)
        #expect(hookRow.rowKey == "claude|s9")
        #expect(hookRow.source == .hooks)
        #expect(hookRow.liveProcess, "the process attaches to the hook row; no process-only twin")
        #expect(first.rows.count == 1)

        let second = build(
            procs: [hit(.claude)], harvest: [session(.claude, "s9")], attention: [wait],
            previous: .init(rows: first.rows, waitingKeys: first.waitingKeys)
        )
        let row = try #require(second.rows.first)
        #expect(second.rows.count == 1)
        #expect(row.rowKey == "claude|s9")
        #expect(row.source == .session)
        #expect(second.newlyWaiting.isEmpty, "the same wait under the same key is not a second edge")
        #expect(second.resolvedWaits.isEmpty)
    }

    // MARK: - (c) attention by folder attaches to the right session row

    @Test func attentionByFolderAttachesToTheSessionInThatFolder() throws {
        var api = session(.codex, "", task: "API work", cwd: "/w/api")
        api.startedMs = now - 30 * minute
        var docs = session(.codex, "", task: "Docs work", cwd: "/w/docs")
        docs.startedMs = now - 20 * minute
        let r = build(harvest: [api, docs], attention: [attention(.codex, cwd: "/w/docs")])
        #expect(r.rows.count == 2)
        let blocked = r.rows.filter { $0.isBlocked }
        let row = try #require(blocked.first)
        #expect(blocked.count == 1)
        #expect(row.task == "Docs work")
        #expect(row.rowKey == docs.rowKey)
    }

    @Test func aHookNamingAnotherSessionNeverLandsOnASiblingByFolder() throws {
        let r = build(
            harvest: [session(.claude, "s1", cwd: "/w/app")],
            attention: [attention(.claude, session: "s2", cwd: "/w/app")]
        )
        #expect(r.rows.count == 2)
        let sibling = try #require(r.rows.first { $0.rowKey == "claude|s1" })
        #expect(!sibling.isBlocked)
        let hook = try #require(r.rows.first { $0.rowKey == "claude|s2" })
        #expect(hook.isBlocked)
    }

    @Test func aHookWaitNeverLandsOnAProcessOnlyRow() throws {
        let r = build(procs: [hit(.codex, cwd: "/w/app")], attention: [attention(.codex, cwd: "/w/app")])
        #expect(r.rows.count == 1, "the process attaches to the hook row instead")
        let row = try #require(r.rows.first)
        #expect(row.isBlocked)
        #expect(!RowIdentity.isProcessKey(row.rowKey))
        #expect(row.rowKey.hasPrefix("codex|hook:"))
    }

    @Test func aTurnWithNoSessionRowMakesNoRow() {
        let r = build(attention: [attention(.claude, kind: "Turn", session: "s1")])
        #expect(r.rows.isEmpty)
    }
}

/// Row presentation rules from EXPERIENCE.md.
final class AgentRowTests: XCTestCase {
    private func row(_ mutate: (inout AgentRow) -> Void) -> AgentRow {
        var r = AgentRow(rowKey: "claude|s1", agent: .claude)
        mutate(&r)
        return r
    }

    func testPlaceholderTitlesAreNotTreatedAsSessions() {
        for junk in [
            "-", "—", "Running", "Active", "none", "Agent session", "Chat",
            "Amp session", "OpenCode session", "Windsurf session", "Cline session",
        ] {
            let r = row { $0.task = junk }
            XCTAssertNil(r.usefulTask, "\(junk) is not a real session title")
        }
    }

    func testBarePathIsNotASessionTitle() {
        XCTAssertNil(row { $0.task = "/Users/me/code" }.usefulTask)
        XCTAssertNotNil(row { $0.task = "/Users/me fix the parser" }.usefulTask)
    }

    func testMarkdownLinksBecomeReadablePlainTitles() {
        let raw = "[hxddh/Pulse](https://github.com/hxddh/Pulse) 本地有安装最新版"
        let r = row { $0.task = raw }
        XCTAssertEqual(r.usefulTask, "hxddh/Pulse 本地有安装最新版")
        XCTAssertEqual(r.task, raw, "presentation cleanup must not rewrite evidence")
    }

    func testMarkdownImageSyntaxDoesNotLeakIntoTheTray() {
        XCTAssertEqual(
            row { $0.task = "Inspect ![failure](file:///tmp/failure.png)" }.usefulTask,
            "Inspect failure"
        )
    }

    func testInternalToolIdentifiersAreNotSessionTitles() {
        XCTAssertNil(row { $0.task = "update_plan" }.usefulTask)
        XCTAssertEqual(row { $0.task = "update_auth" }.usefulTask, "update_auth")
        XCTAssertNil(row { $0.task = "Read Models.swift" }.usefulTask)
        XCTAssertNil(row { $0.task = "Models.swift" }.usefulTask)
        XCTAssertNotNil(row { $0.task = "Improve tray density" }.usefulTask)
    }

    func testShortProjectDropsOpaqueHashes() {
        XCTAssertEqual(AgentRow.shortProject("/Users/me/code/Pulse"), "Pulse")
        XCTAssertEqual(AgentRow.shortProject("a1b2c3d4e5f60718"), "", "hash is not a project name")
        XCTAssertEqual(AgentRow.shortProject(""), "")
    }

    func testLongProjectNamesAreTruncated() {
        let long = String(repeating: "x", count: 40)
        let short = AgentRow.shortProject(long)
        XCTAssertLessThanOrEqual(short.count, 24)
        XCTAssertTrue(short.hasSuffix("…"))
    }
}

/// Screenshots of 0.24.0 showed one fact stated three and four times over.
final class RowRedundancyTests: XCTestCase {
    private func row(agent: AgentID, task: String = "", project: String = "") -> AgentRow {
        var r = AgentRow(rowKey: "k", agent: agent)
        r.task = task
        r.project = project
        r.liveProcess = true
        r.state = .running
        return r
    }

    /// `Cursor · Cursor` — the dedupe compared the project to the hero only.
    func testProjectThatRestatesTheAgentIsDropped() {
        let r = row(agent: .cursor, task: "Pulse installation guide", project: "Cursor")
        XCTAssertEqual(AgentRow.shortProject(r.project), "Cursor")
        XCTAssertEqual(r.agent.displayName, "Cursor")
    }

    /// A bare process row said "Process detected", "process", and "Amp".
    func testProcessOnlyRowHasNoSessionTitleToShow() {
        var r = row(agent: .amp)
        r.state = .processOnly
        XCTAssertNil(r.usefulTask)
        // Hero must not fall back to the agent product name (already on identity).
        let hero = Explain.make(r, lang: .en, nowMs: 1_700_000_000_000).headline
        XCTAssertNotEqual(hero, r.agent.displayName)
    }

    func testEveryAgentDropsItsOwnGenericSessionPlaceholder() {
        for agent in AgentID.allCases {
            var r = row(agent: agent, task: "\(agent.displayName) session")
            r.sessionID = "real-id"
            XCTAssertNil(r.usefulTask, "\(agent.displayName) placeholder escaped as a task")
        }
    }

    func testEveryAgentDropsItsOwnBareDisplayName() {
        for agent in AgentID.allCases {
            var r = row(agent: agent, task: agent.displayName)
            r.sessionID = "real-id"
            XCTAssertNil(r.usefulTask, "\(agent.displayName) alone is identity, not a goal")
        }
    }
}

/// The two facts a row could never state, both collected from the start.
final class RowContextTests: XCTestCase {
    private func row(cwd: String = "", project: String = "", harvestMs: Int64 = 0) -> AgentRow {
        var r = AgentRow(rowKey: "k", agent: .claude)
        r.cwd = cwd
        r.project = project
        r.harvestMs = harvestMs
        return r
    }

    /// Home itself is not a location worth naming; anything under it is.
    func testPathsUnderHomeUseTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(row(cwd: home).displayPath, "", "home is not a project")
        XCTAssertEqual(row(cwd: home + "/code").displayPath, "~/code")
    }

    /// The middle of a deep path carries no identity; the tail does.
    func testDeepPathsKeepTheirTail() {
        let p = row(cwd: "/a/b/c/d/e/Pulse").displayPath
        XCTAssertTrue(p.hasSuffix("e/Pulse"), p)
        XCTAssertTrue(p.contains("…"), p)
    }

    func testShallowPathsAreLeftAlone() {
        XCTAssertEqual(row(cwd: "/tmp/alpha").displayPath, "/tmp/alpha")
    }

    func testNoLocationYieldsNoPathRatherThanAPlaceholder() {
        XCTAssertEqual(row().displayPath, "")
    }

    func testProjectIsUsedWhenThereIsNoCwd() {
        XCTAssertEqual(row(project: "Pulse").displayPath, "Pulse")
    }

    func testUnknownActivityIsZeroNotEpoch() {
        XCTAssertEqual(row().lastActivitySeconds(at: 1_700_000_000_000), 0)
    }

    func testActivityAgeCountsFromTheHarvestStamp() {
        let now: Int64 = 1_700_000_000_000
        XCTAssertEqual(row(harvestMs: now - 600_000).lastActivitySeconds(at: now), 600, accuracy: 0.001)
    }
}

/// Each of these is a defect visible in a 0.25.0 screenshot.
final class RowPresentationTests: XCTestCase {
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    private func row(cwd: String = "", project: String = "", harvestMs: Int64 = 0, live: Bool = false) -> AgentRow {
        var r = AgentRow(rowKey: "k", agent: .claude)
        r.cwd = cwd
        r.project = project
        r.harvestMs = harvestMs
        r.liveProcess = live
        r.state = live ? .running : .recent
        return r
    }

    /// The panel grouped two sessions under "~" and a third under
    /// "users-rustjia" — the same directory, twice, and a header claiming
    /// three projects where there were two.
    func testHomeIsNotAProject() {
        XCTAssertEqual(row(cwd: home).displayPath, "")
        XCTAssertEqual(row(project: "~").displayPath, "")
    }

    func testEncodedHomeCollapsesToTheSamePlaceAsHome() {
        let user = (home as NSString).lastPathComponent
        XCTAssertTrue(AgentRow.isHomeLike("users-\(user)", home: home))
        XCTAssertTrue(AgentRow.isHomeLike(user, home: home))
        XCTAssertEqual(row(project: "users-\(user)").displayPath, "")
    }

    func testARealProjectIsStillAProject() {
        XCTAssertEqual(row(cwd: home + "/Documents/Cursor").displayPath, "~/Documents/Cursor")
        XCTAssertFalse(AgentRow.isHomeLike("/tmp/alpha", home: home))
    }

    /// "New Session" was shown as a row title.
    func testPlaceholderTitlesAreNotTitles() {
        for junk in ["New Session", "Untitled", "New Chat", "Agent session"] {
            var r = row()
            r.task = junk
            XCTAssertNil(r.usefulTask, "\(junk) is a placeholder, not a task")
        }
    }

    /// Live for twenty minutes with nothing happening looked like health.
    ///
    /// Evaluated against the scan's clock, so these pass an explicit `nowMs`
    /// rather than depending on when the suite happens to run.
    private let now: Int64 = 1_700_000_000_000

    private func stalled(agoSeconds: Double) -> Bool {
        AgentRow.stalled(lastActivityMs: now - Int64(agoSeconds * 1000), nowMs: now)
    }

    func testLongSilenceWhileLiveIsStalled() {
        XCTAssertTrue(stalled(agoSeconds: 25 * 60))
    }

    func testRecentActivityIsNotStalled() {
        XCTAssertFalse(stalled(agoSeconds: 60))
    }

    func testUnknownActivityIsNotStalled() {
        XCTAssertFalse(
            AgentRow.stalled(lastActivityMs: 0, nowMs: now),
            "no timestamp is not evidence of silence"
        )
    }

    /// A stalled row is one the user should react to: an orange ring, and
    /// its why on a second line (23.0 — no badge).
    func testStalledRowsSayWhy() {
        var r = row(harvestMs: now - 25 * 60 * 1000, live: true)
        r.isStalled = true
        let face = TrayRowModel.make(TrayRowModel.Input(row: r, lang: .en, nowMs: now))
        XCTAssertEqual(face.lamp, LampFace(shape: .ring, tone: .attention))
        XCTAssertEqual(face.secondLine?.kind, .warning)
        XCTAssertEqual(face.secondLine?.text, face.why)
    }
}

/// The stall threshold used to be compiled in at twenty minutes.
final class StallThresholdTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000

    private func stalled(agoSeconds: Double, threshold: Double) -> Bool {
        AgentRow.stalled(lastActivityMs: now - Int64(agoSeconds * 1000), nowMs: now, threshold: threshold)
    }

    func testAShorterThresholdCatchesAShorterSilence() {
        XCTAssertTrue(stalled(agoSeconds: 6 * 60, threshold: 5 * 60))
        XCTAssertFalse(stalled(agoSeconds: 6 * 60, threshold: 20 * 60))
    }

    /// "Never" must read as never stalled, not as always stalled.
    func testZeroDisablesRatherThanTripping() {
        XCTAssertFalse(stalled(agoSeconds: 10 * 60 * 60, threshold: 0))
        XCTAssertFalse(stalled(agoSeconds: 10 * 60 * 60, threshold: -1))
    }

    func testTheDefaultIsUnchanged() {
        XCTAssertEqual(AgentRow.stalledSeconds, 20 * 60)
        XCTAssertTrue(stalled(agoSeconds: 21 * 60, threshold: AgentRow.stalledSeconds))
    }
}

/// 0.94 Waiting Proof — harvest ask → tray Waiting → dismiss → clear → re-raise,
/// Attention raise→clear for Waiting-none, and honesty guards (no fake Waiting).
final class WaitingProofTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000

    @MainActor
    private var bareTerminal: TerminalFocus.Environment {
        TerminalFocus.Environment(warpRunning: false, ttyHostRunning: false)
    }

    @MainActor
    private func context(dismissed: Set<String> = []) -> SnapshotBuilder.Context {
        SnapshotBuilder.Context(
            nowMs: now,
            terminal: bareTerminal,
            lang: .en,
            dismissedPendingKeys: dismissed
        )
    }

    @MainActor
    private func harvest(
        _ id: AgentID,
        task: String = "Ask",
        session: String = "s1",
        cwd: String = "/Users/me/Pulse",
        skill: String = "",
        tool: String = "",
        evidence: ObservationSource = .cache,
        ageMs: Int64 = 1_000,
        phase: String = ""
    ) -> ActivityHarvest.Row {
        var row = ActivityHarvest.Row(
            id: id, task: task, project: "", cwd: cwd, skill: skill,
            tool: tool, harvestMs: now - ageMs,
            subRunning: 0, subTotal: 0, sessionID: session,
            evidence: evidence
        )
        row.phase = phase
        return row
    }

    @MainActor
    private func attention(
        _ id: AgentID,
        kind: String = "Permission",
        message: String = "approve",
        session: String = "",
        cwd: String = "",
        ageMs: Int64 = 500
    ) -> AttentionReader.Entry {
        AttentionReader.Entry(
            id: id, kind: kind, message: message,
            tsMs: now - ageMs, session: session, cwd: cwd
        )
    }

    @MainActor
    private func build(
        harvest rows: [ActivityHarvest.Row] = [],
        attention entries: [AttentionReader.Entry] = [],
        dismissed: Set<String> = []
    ) -> SnapshotBuilder.Result {
        SnapshotBuilder.build(
            SnapshotBuilder.Input(
                procs: [], harvest: rows, attention: entries
            ),
            previous: .init(),
            context: context(dismissed: dismissed)
        )
    }

    // MARK: P0-1 harvest → Waiting → dismiss → re-raise

    @MainActor
    func testClinePendingRaisesWaitingAndSoftDismissSuppresses() {
        let pending = harvest(.cline, session: "cl-1", skill: "pending")
        let key = RowIdentity.session(agent: .cline, sessionID: "cl-1")
        let lit = build(harvest: [pending])
        XCTAssertTrue(lit.rows[0].isBlocked)
        XCTAssertEqual(lit.rows[0].wait?.signal, .pending)
        XCTAssertEqual(lit.snapshot.glance, .waiting)

        let dismissed = build(harvest: [pending], dismissed: [key])
        XCTAssertFalse(dismissed.rows[0].isBlocked, "soft-dismiss must suppress harvest pending")

        let cleared = harvest(.cline, session: "cl-1", skill: "")
        let afterClear = build(harvest: [cleared], dismissed: [key])
        XCTAssertTrue(afterClear.clearedPendingKeys.contains(key))

        let again = build(harvest: [pending])
        XCTAssertTrue(again.rows[0].isBlocked, "new pending after natural clear can re-raise")
    }

    @MainActor
    func testRooAskToolPendingRaisesWaiting() {
        let row = harvest(.roo, session: "roo-1", skill: "pending", tool: "ask_followup_question")
        let lit = build(harvest: [row])
        XCTAssertTrue(lit.rows[0].isBlocked)
        XCTAssertEqual(lit.rows[0].wait?.signal, .pending)
        XCTAssertEqual(lit.rows[0].wait?.kind, "Input", "a follow-up question is an ask, not a permission")
    }

    @MainActor
    func testUnverifiedCascadePendingDoesNotRaiseWaiting() {
        // 23.0: Windsurf/Cascade formats are unverified — `waiting: .none`.
        let row = harvest(
            .windsurf, session: "ws-1", skill: "pending", tool: "ask_clarifying_question"
        )
        let lit = build(harvest: [row])
        XCTAssertFalse(lit.rows[0].isBlocked)
        XCTAssertEqual(lit.rows[0].source, .cache)
    }

    @MainActor
    func testUnverifiedCursorBlockingFlagDoesNotRaiseWaiting() {
        // 23.0: Cursor's format is unverified — `waiting: .none`.
        let row = harvest(.cursor, session: "composer-1", skill: "pending", evidence: .session)
        let lit = build(harvest: [row])
        XCTAssertFalse(lit.rows[0].isBlocked)
    }

    @MainActor
    func testDependingNeverRaisesWaiting() {
        let row = harvest(.goose, session: "g-dep", skill: "", phase: "depending")
        let lit = build(harvest: [row])
        XCTAssertFalse(lit.rows[0].isBlocked)
    }

    // MARK: P0-3 Attention raise → clear

    @MainActor
    func testAttentionRaiseLightsExactSessionThenDoneClears() {
        let lit = build(
            harvest: [
                harvest(.zcode, task: "A", session: "z-a", skill: ""),
                harvest(.zcode, task: "B", session: "z-b", skill: ""),
            ],
            attention: [attention(.zcode, session: "z-b")]
        )
        let waiting = lit.rows.filter(\.isBlocked)
        XCTAssertEqual(waiting.count, 1)
        XCTAssertEqual(waiting[0].sessionID, "z-b")
        XCTAssertEqual(waiting[0].wait?.signal, .hooks)

        let cleared = build(
            harvest: [
                harvest(.zcode, task: "A", session: "z-a", skill: ""),
                harvest(.zcode, task: "B", session: "z-b", skill: ""),
            ],
            attention: []
        )
        XCTAssertFalse(cleared.rows.contains(where: \.isBlocked))
    }

    // MARK: P0-4 Waiting-none Reach

    @MainActor
    func testWaitingNoneNeedsReachAndOpenSettings() {
        let store = StatusStore()
        var row = AgentRow(rowKey: "zcode|live", agent: .zcode)
        row.liveProcess = true
        row.state = .running
        XCTAssertTrue(store.isWaitingNoneNeedsReach(row))
        store.openWaitingReach()
        XCTAssertEqual(store.settingsFocus.target, .waitingSignals)
    }

    @MainActor
    func testHarvestPendingDoesNotNeedWaitingNoneReach() {
        let store = StatusStore()
        var row = AgentRow(rowKey: "cline|live", agent: .cline)
        row.liveProcess = true
        row.state = .running
        XCTAssertFalse(store.isWaitingNoneNeedsReach(row))
    }
}

/// 0.95 Extinguish Honesty — false Waiting must not light; clear stays clear
/// until genuine new evidence.
final class WaitClearingTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000

    @MainActor
    private var bareTerminal: TerminalFocus.Environment {
        TerminalFocus.Environment(warpRunning: false, ttyHostRunning: false)
    }

    @MainActor
    private func context(dismissed: Set<String> = []) -> SnapshotBuilder.Context {
        SnapshotBuilder.Context(
            nowMs: now,
            terminal: bareTerminal,
            lang: .en,
            dismissedPendingKeys: dismissed
        )
    }

    @MainActor
    private func harvest(
        _ id: AgentID,
        task: String = "Ask",
        session: String = "s1",
        cwd: String = "/Users/me/Pulse",
        skill: String = "",
        tool: String = "",
        evidence: ObservationSource = .cache,
        ageMs: Int64 = 1_000
    ) -> ActivityHarvest.Row {
        ActivityHarvest.Row(
            id: id, task: task, project: "", cwd: cwd, skill: skill,
            tool: tool, harvestMs: now - ageMs,
            subRunning: 0, subTotal: 0, sessionID: session,
            evidence: evidence
        )
    }

    @MainActor
    private func build(
        harvest rows: [ActivityHarvest.Row] = [],
        attention entries: [AttentionReader.Entry] = [],
        dismissed: Set<String> = []
    ) -> SnapshotBuilder.Result {
        SnapshotBuilder.build(
            SnapshotBuilder.Input(
                procs: [], harvest: rows, attention: entries
            ),
            previous: .init(),
            context: context(dismissed: dismissed)
        )
    }

    // MARK: Soft-dismiss absence

    @MainActor
    func testDismissedKeyClearsWhenHarvestAbsentOnReliableScan() {
        let key = RowIdentity.session(agent: .cline, sessionID: "cl-gone")
        let gone = build(harvest: [], dismissed: [key])
        XCTAssertTrue(gone.clearedPendingKeys.contains(key))
    }

    @MainActor
    func testAbsentThenPendingCanReraiseAfterTombstoneCleared() {
        let pending = harvest(.cline, session: "cl-reraise", skill: "pending")
        let key = RowIdentity.session(agent: .cline, sessionID: "cl-reraise")
        let absent = build(harvest: [], dismissed: [key])
        XCTAssertTrue(absent.clearedPendingKeys.contains(key))
        let again = build(harvest: [pending], dismissed: [])
        XCTAssertTrue(again.rows[0].isBlocked)
    }

    // MARK: Attention match uniqueness

    @MainActor
    func testAmbiguousSessionPrefixDoesNotSmearAttention() {
        let lit = build(
            harvest: [
                harvest(.zcode, task: "A", session: "sess-aaa"),
                harvest(.zcode, task: "B", session: "sess-bbb"),
            ],
            attention: [
                AttentionReader.Entry(
                    id: .zcode, kind: "Permission", message: "approve",
                    tsMs: now - 500, session: "sess", cwd: ""
                )
            ]
        )
        XCTAssertFalse(lit.rows.contains(where: \.isBlocked), "ambiguous prefix must not smear")
    }

    @MainActor
    func testExactSessionAttentionStillLights() {
        let lit = build(
            harvest: [
                harvest(.zcode, task: "A", session: "sess-aaa"),
                harvest(.zcode, task: "B", session: "sess-bbb"),
            ],
            attention: [
                AttentionReader.Entry(
                    id: .zcode, kind: "Permission", message: "approve",
                    tsMs: now - 500, session: "sess-bbb", cwd: ""
                )
            ]
        )
        let waiting = lit.rows.filter(\.isBlocked)
        XCTAssertEqual(waiting.count, 1)
        XCTAssertEqual(waiting[0].sessionID, "sess-bbb")
    }

    // MARK: Stop grace for Waiting kind

    @MainActor
    func testGenericWaitingSurvivesImmediateStopWithinGrace() {
        let nowMs = now
        let text = [
            AttentionProtocol.header.trimmingCharacters(in: .newlines),
            "zcode\twaiting\t\(nowMs - 1_000)\tNeed you\tz-1\t/tmp\t\t",
            "zcode\tstop\t\(nowMs)\t\tz-1\t/tmp\t\t",
        ].joined(separator: "\n") + "\n"
        let entries = AttentionReader.parse(text, nowMs: nowMs)
        XCTAssertEqual(entries.count, 1, "Waiting + Stop within grace must keep the raise")
        XCTAssertEqual(entries[0].kind, "Waiting")
    }
}

/// Clarity fixes — each test pins one defect found by reading the code: the
/// value the user would have seen, before and after.
@MainActor
@Suite("Builder fixes", .serialized)
struct BuilderFixTests {
    let now: Int64 = 1_800_000_000_000
    static let minute: Int64 = 60_000

    func session(_ id: AgentID, _ sessionID: String, skill: String = "", ageMs: Int64 = 70_000) -> ActivityHarvest.Row {
        ActivityHarvest.Row(
            id: id, task: "Fix the login flow", project: "p", cwd: "/p", skill: skill,
            tool: "", harvestMs: now - ageMs, subRunning: 0, subTotal: 0, sessionID: sessionID,
            evidence: .session
        )
    }

    func build(
        procs: [ProcessProbe.Hit] = [],
        harvest: [ActivityHarvest.Row] = [],
        attention: [AttentionReader.Entry] = [],
        vendorWaits: [ClaudeAgentsProbe.Wait] = [],
        dismissed: Set<String> = []
    ) -> SnapshotBuilder.Result {
        var input = SnapshotBuilder.Input(procs: procs, harvest: harvest, attention: attention)
        input.vendorWaits = vendorWaits
        return SnapshotBuilder.build(
            input,
            previous: .init(),
            context: SnapshotBuilder.Context(
                nowMs: now,
                terminal: TerminalFocus.Environment(warpRunning: false, ttyHostRunning: false),
                lang: .en,
                dismissedPendingKeys: dismissed
            )
        )
    }

    func turn(session: String, ago: Int64 = 2_000) -> [AttentionReader.Entry] {
        let line = ["claude", "turn", "\(now - ago)", "", session, "/p", "", ""].joined(separator: "\t")
        return AttentionReader.parse(AttentionProtocol.header + line + "\n", nowMs: now)
    }

    // MARK: - 1 · a dismissed vendor wait stays dismissed

    @Test func aDismissedVendorWaitIsNotReleasedWhileClaudeStillReportsIt() throws {
        let wait = ClaudeAgentsProbe.Wait(
            sessionID: "s1", pid: 0, cwd: "/p", kind: .permission, reason: "permission prompt", sinceMs: now
        )
        let raised = build(harvest: [session(.claude, "s1")], vendorWaits: [wait])
        let firstWaiting = raised.rows.first { $0.isBlocked }
        let key = try #require(firstWaiting).rowKey

        let dismissed = build(harvest: [session(.claude, "s1")], vendorWaits: [wait], dismissed: [key])
        let dismissedRow = dismissed.rows.first { $0.rowKey == key }
        #expect(dismissedRow?.isBlocked == false)
        #expect(!dismissed.clearedPendingKeys.contains(key), "releasing it here relit the lamp on the next scan")

        let moved = build(harvest: [session(.claude, "s1")], dismissed: [key])
        #expect(moved.clearedPendingKeys.contains(key), "once Claude stops reporting it, the tombstone may go")
    }

    // MARK: - 5 · a turn marks a session, never a bare process

    /// 23.0: a process-only row is not a session a hook can speak for, and a
    /// turn with no session row makes none — so the process stays a process.
    @Test func aTurnNeverLandsOnAProcessOnlyRow() throws {
        let hit = ProcessProbe.Hit(id: .claude, count: 1, viaWarp: false, pid: 4242)
        let r = build(procs: [hit], attention: turn(session: "s-turn"))
        let row = try #require(r.rows.first)
        #expect(r.rows.count == 1)
        #expect(row.isProcessOnly)
        #expect(!row.isYourTurn)
    }

    @Test func aPrefixMatchedTurnIsClearedUnderTheFilesSpelling() throws {
        let r = build(harvest: [session(.claude, "sess-full")], attention: turn(session: "sess-full-123"))
        let row = try #require(r.rows.first)
        #expect(row.isYourTurn)
        #expect(row.sessionID == "sess-full")
        #expect(row.attentionSession == "sess-full-123", "a done under the row's id would clear nothing")
    }

    // MARK: - 20 · an old file ask with nothing alive is not red

    @Test func aStaleFilePendingWithNoProcessIsNotRed() throws {
        let stale = build(harvest: [session(.cline, "cl-1", skill: "pending", ageMs: 31 * Self.minute)])
        #expect(stale.rows.first?.isBlocked == false)

        let alive = build(
            procs: [ProcessProbe.Hit(id: .cline, count: 1, viaWarp: false, pid: 77)],
            harvest: [session(.cline, "cl-1", skill: "pending", ageMs: 31 * Self.minute)]
        )
        #expect(alive.rows.first?.isBlocked == true, "a live process keeps the vendor's own ask red")

        let recent = build(harvest: [session(.cline, "cl-1", skill: "pending", ageMs: 5 * Self.minute)])
        #expect(recent.rows.first?.isBlocked == true)
    }
}

/// 0.99.2 Live Wire — the rest of the path 0.99.1 只修了一半.
///
/// 0.99.1 fixed how `lsof` output is parsed. These cover what happens to that
/// output afterwards: the gate that decided whether to keep it at all, the
/// subprocess wrapper underneath, and the code downstream that had never once
/// run with a working directory in hand.
final class ProcessOnlyRowTests: XCTestCase {

    private let now: Int64 = 1_700_000_000_000

    // MARK: - Downstream: code that had never seen a working directory

    private func context() -> SnapshotBuilder.Context {
        SnapshotBuilder.Context(
            nowMs: now,
            terminal: TerminalFocus.Environment(warpRunning: false, ttyHostRunning: false),
            lang: .en,
            maxSessionsPerAgent: SnapshotBuilder.maxSessionsPerAgent,
            maxVisibleRows: SnapshotBuilder.maxVisibleRows,
            dismissedPendingKeys: [],
            showAllAgents: false,
            stalledSeconds: AgentRow.stalledSeconds
        )
    }

    private func build(
        procs: [ProcessProbe.Hit],
        harvest rows: [ActivityHarvest.Row] = []
    ) -> SnapshotBuilder.Result {
        SnapshotBuilder.build(
            SnapshotBuilder.Input(
                procs: procs, harvest: rows, attention: []
            ),
            previous: .init(),
            context: context()
        )
    }

    private func staleRow(_ id: AgentID, session: String, cwd: String, ageMs: Int64) -> ActivityHarvest.Row {
        ActivityHarvest.Row(
            id: id, task: "Wire up the probe", project: "", cwd: cwd, skill: "",
            tool: "", harvestMs: now - ageMs,
            subRunning: 0, subTotal: 0, sessionID: session,
            evidence: .session
        )
    }

    /// A process-only row — an agent with no readable session store — gets its
    /// workspace and project name from the probe. This is the fact 0.99.1's
    /// release notes said had been missing for every such row.
    func testAProcessOnlyRowTakesItsProjectFromTheProbe() throws {
        var probe = ProcessProbe.Hit(id: .aider, count: 1, viaWarp: false, pid: 4242)
        probe.cwd = "/Users/me/code/Pulse"

        let result = build(procs: [probe])
        let row = try XCTUnwrap(result.rows.first { $0.agent == .aider })
        XCTAssertEqual(row.cwd, "/Users/me/code/Pulse")
        XCTAssertEqual(row.project, AgentRow.shortProject("/Users/me/code/Pulse"))
        XCTAssertFalse(row.project.isEmpty, "a process-only row used to have no project at all")
    }

    /// `SnapshotBuilder` picks one stale session per agent to keep, and breaks
    /// the tie with the live process's working directory. Because `hit.cwd` was
    /// always empty, that tie-break had never once executed; from 0.99.1 it
    /// decides which session the user sees.
    func testTheStaleSessionMatchingTheLiveWorkingDirectoryWins() throws {
        let stale: Int64 = 90 * 60 * 1000
        let matching = staleRow(.claude, session: "older-but-here", cwd: "/Users/me/code/Pulse", ageMs: stale + 60_000)
        let newer = staleRow(.claude, session: "newer-elsewhere", cwd: "/Users/me/code/Other", ageMs: stale)

        var probe = ProcessProbe.Hit(id: .claude, count: 1, viaWarp: false, pid: 77)
        probe.cwd = "/Users/me/code/Pulse"

        let rows = build(procs: [probe], harvest: [newer, matching]).rows
            .filter { $0.agent == .claude }
        XCTAssertEqual(rows.count, 1, "one stale fallback per agent")
        XCTAssertEqual(rows.first?.cwd, "/Users/me/code/Pulse")
    }

    /// Without a probe cwd the tie-break must fall back to recency, exactly as
    /// it did before the wire carried anything.
    func testWithoutAProbeWorkingDirectoryTheNewestStaleSessionWins() throws {
        let stale: Int64 = 90 * 60 * 1000
        let older = staleRow(.claude, session: "older", cwd: "/Users/me/code/Pulse", ageMs: stale + 60_000)
        let newer = staleRow(.claude, session: "newer", cwd: "/Users/me/code/Other", ageMs: stale)

        let rows = build(
            procs: [ProcessProbe.Hit(id: .claude, count: 1, viaWarp: false, pid: 77)],
            harvest: [older, newer]
        ).rows.filter { $0.agent == .claude }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.cwd, "/Users/me/code/Other")
    }
}

/// 2.9 Quality — second-grade freshness, and the measurement measuring itself.
///
/// The hook has stood in the vendor's event stream since 1.0, but only for
/// waits. These tests hold the new deal for activity events: state not
/// ledger, never a wait, present tense only inside the live window — and the
/// yield rules that stop "the agent is idle" and "Pulse stopped seeing" from
/// wearing the same clothes.
final class ActivityEventBuilderTests: XCTestCase {

    private let now: Int64 = 1_800_000_000_000
    // MARK: - The builder's side: what an event may become

    private func build(
        harvest: [ActivityHarvest.Row] = [],
        activity: [ActivitySpool.Event] = []
    ) -> [AgentRow] {
        SnapshotBuilder.build(
            SnapshotBuilder.Input(harvest: harvest, activity: activity),
            previous: SnapshotBuilder.Previous(),
            context: SnapshotBuilder.Context(
                nowMs: now,
                terminal: TerminalFocus.Environment(
                    warpRunning: false, ttyHostRunning: false, allowTTYAutomation: false
                ),
                lang: .en
            )
        ).rows
    }

    private func harvestRow(session: String = "sess-a") -> ActivityHarvest.Row {
        var row = ActivityHarvest.Row(
            id: .claude, task: "Fix the auth module", project: "repo",
            cwd: "/work/repo", skill: ""
        )
        row.sessionID = session
        row.harvestMs = now - 60_000
        row.evidence = .session
        return row
    }

    private func toolEvent(session: String = "sess-a", tsMs: Int64? = nil) -> ActivitySpool.Event {
        ActivitySpool.Event(
            agent: "claude", session: session, event: "tool",
            tool: "Edit", target: "/work/repo/src/Main.swift", prompt: "",
            cwd: "/work/repo", tsMs: tsMs ?? now - 5_000
        )
    }

    func testAFreshEventMovesTheLiveClock() throws {
        let rows = build(harvest: [harvestRow()], activity: [toolEvent()])
        let row = try XCTUnwrap(rows.first { $0.sessionID == "sess-a" })
        XCTAssertEqual(row.activityMs, now - 5_000, "the event is live-signal evidence, on the live-signal clock")
        XCTAssertEqual(row.harvestMs, now - 60_000, "the harvested facts are still as old as their harvest")
    }

    func testAnEventNeverCreatesARowAndNeverAWait() {
        let alone = build(activity: [toolEvent(session: "nobody-home")])
        XCTAssertTrue(alone.isEmpty, "an event without a row has no other evidence — no row")
        let rows = build(harvest: [harvestRow()], activity: [toolEvent()])
        XCTAssertFalse(rows.contains(where: \.isBlocked), "activity must never become Waiting")
    }

    func testAFutureEventStampIsClampedByTheBuilderToo() throws {
        let rows = build(harvest: [harvestRow()], activity: [toolEvent(tsMs: now + 600_000)])
        let row = try XCTUnwrap(rows.first { $0.sessionID == "sess-a" })
        XCTAssertLessThanOrEqual(row.activityMs, now)
    }
}

/// 23.0 audit — each test pins a defect a person would have seen: a lamp
/// that stayed red after the answer, a second ask with no banner, a dismiss
/// that cleared other terminals, a cadence held fast by a bare process.
@Suite("Builder audit fixes")
struct BuilderAuditTests {
    let now: Int64 = 1_800_000_000_000
    let second: Int64 = 1_000

    private func session(_ id: AgentID, _ sessionID: String, cwd: String = "/w/app") -> ActivityHarvest.Row {
        ActivityHarvest.Row(
            id: id, task: "Fix the login test", project: "", cwd: cwd, skill: "",
            harvestMs: now - 60 * second, sessionID: sessionID, evidence: .session
        )
    }

    private func hook(
        _ id: AgentID = .claude, session: String = "s1", cwd: String = "/w/app", ago: Int64 = 30_000
    ) -> AttentionReader.Entry {
        AttentionReader.Entry(
            id: id, kind: "Permission", message: "Bash: npm test", tsMs: now - ago, session: session, cwd: cwd
        )
    }

    private func tool(session: String = "s1", at tsMs: Int64) -> ActivitySpool.Event {
        ActivitySpool.Event(
            agent: "claude", session: session, event: "tool", tool: "Bash", target: "npm test",
            prompt: "", cwd: "/w/app", tsMs: tsMs
        )
    }

    private func build(
        procs: [ProcessProbe.Hit] = [],
        harvest: [ActivityHarvest.Row] = [],
        attention: [AttentionReader.Entry] = [],
        activity: [ActivitySpool.Event] = [],
        previous: SnapshotBuilder.Previous = .init(),
        lang: ResolvedLanguage = .en
    ) -> SnapshotBuilder.Result {
        SnapshotBuilder.build(
            SnapshotBuilder.Input(procs: procs, harvest: harvest, attention: attention, activity: activity),
            previous: previous,
            context: SnapshotBuilder.Context(
                nowMs: now,
                terminal: TerminalFocus.Environment(warpRunning: false, ttyHostRunning: false),
                lang: lang
            )
        )
    }

    // MARK: - 1 · a permission answered in the terminal goes out

    @Test func aHookWaitGoesOutWhenTheSessionMovesAfterIt() throws {
        let raised = build(harvest: [session(.claude, "s1")], attention: [hook()])
        let waiting = try #require(raised.rows.first)
        #expect(waiting.isBlocked)

        // Approved in the terminal: the tool runs, the next tool's
        // PreToolUse lands after the raise. Nothing wrote `done`.
        let answered = build(
            harvest: [session(.claude, "s1")], attention: [hook()], activity: [tool(at: now - 10 * second)]
        )
        let row = try #require(answered.rows.first)
        #expect(!row.isBlocked, "the answer was given in the vendor's own prompt")
        #expect(answered.snapshot.glance != .waiting)
    }

    @Test func thePreToolUseBeforeTheRaiseDoesNotClearIt() throws {
        // PreToolUse for the tool being asked about fires before the
        // PermissionRequest: activity older than the raise is not an answer.
        let r = build(
            harvest: [session(.claude, "s1")], attention: [hook()], activity: [tool(at: now - 31 * second)]
        )
        let row = try #require(r.rows.first)
        #expect(row.isBlocked)
    }

    @Test func activityInAnotherSessionNeverClearsAWait() throws {
        let r = build(
            harvest: [session(.claude, "s1"), session(.claude, "s2", cwd: "/w/other")],
            attention: [hook(session: "s1")],
            activity: [tool(session: "s2", at: now - second)]
        )
        let row = try #require(r.rows.first { $0.sessionID == "s1" })
        #expect(row.isBlocked, "No fake resolution either: only the wait's own session can answer it")
    }

    // MARK: - 2 · a second ask on the same row is a new edge

    @Test func aSecondAskOnAWaitingRowIsANewEdge() throws {
        let first = build(harvest: [session(.claude, "s1")], attention: [hook(ago: 60 * second)])
        let firstRow = try #require(first.rows.first)
        let edgesFirst = first.newlyWaiting.map { $0.rowKey }
        #expect(edgesFirst == [firstRow.rowKey])
        let since = try #require(firstRow.wait?.sinceMs)

        let previous = SnapshotBuilder.Previous(
            rows: first.rows, waitingKeys: first.waitingKeys, waitingSince: [firstRow.rowKey: since]
        )
        let same = build(harvest: [session(.claude, "s1")], attention: [hook(ago: 60 * second)], previous: previous)
        #expect(same.newlyWaiting.isEmpty, "the same ask is not a second edge")

        // The first was approved, the next tool began, and it asks again —
        // all between two scans.
        let again = build(
            harvest: [session(.claude, "s1")],
            attention: [hook(ago: 5 * second)],
            activity: [tool(at: now - 20 * second)],
            previous: previous
        )
        let edges = again.newlyWaiting.map { $0.rowKey }
        #expect(edges == [firstRow.rowKey], "a new raise on a key that was waiting gets its own edge")
    }

    // MARK: - 4 · a session-less hook wait is dismissed on its own

    @Test func dismissingASessionlessHookWaitNamesNoSession() throws {
        let r = build(
            harvest: [session(.gemini, "g1")],
            attention: [hook(.gemini, session: "", cwd: "/w/app")]
        )
        let blocked = r.rows.filter { $0.isBlocked }
        let row = try #require(blocked.first)
        #expect(blocked.count == 1)
        #expect(row.sessionID.isEmpty, "not the session row in the same folder")
        let done = try #require(StatusStore.doneLine(for: row))
        #expect(done.session == "", "the done names exactly the entry: no session")
        #expect(done.agent == .gemini)

        let sessionRow = try #require(r.rows.first { $0.sessionID == "g1" })
        #expect(StatusStore.doneLine(for: sessionRow) == nil, "a row that is not a hook wait writes no done")
    }

    @Test func aHookWaitOnASessionRowIsDismissedUnderTheFilesSpelling() throws {
        let r = build(harvest: [session(.claude, "sess-full")], attention: [hook(session: "sess-full-123")])
        let row = try #require(r.rows.first)
        #expect(row.isBlocked)
        let done = try #require(StatusStore.doneLine(for: row))
        #expect(done.session == "sess-full-123")
    }

    // MARK: - 7 · cadence and census by state

    @Test func aBareProcessDoesNotHoldTheRunningCadence() {
        let r = build(procs: [ProcessProbe.Hit(id: .claude, count: 1, viaWarp: false, pid: 42)])
        #expect(r.rows.first?.isProcessOnly == true)
        #expect(r.activity == .recent, "a process with no session is not work in progress")
        #expect(!r.snapshot.headerTitle.contains(L10n.t(.runningN, .en)), "and VoiceOver does not call it running")
        #expect(r.snapshot.headerTitle == "1 \(L10n.t(.processOnlyN, .en))")
    }

    @Test func aFinishedTurnWithItsCLIOpenIsNotRunning() throws {
        let turn = AttentionReader.Entry(
            id: .claude, kind: "Turn", message: "", tsMs: now - 5 * second, session: "s1", cwd: "/w/app"
        )
        let r = build(
            procs: [ProcessProbe.Hit(id: .claude, count: 1, viaWarp: false, pid: 42)],
            harvest: [session(.claude, "s1")],
            attention: [turn]
        )
        let row = try #require(r.rows.first)
        #expect(row.isYourTurn)
        #expect(r.activity == .recent)
        #expect(r.snapshot.headerTitle == "1 \(L10n.t(.yourTurnN, .en))")
    }

    @Test func aRunningSessionStillHoldsTheRunningCadence() {
        let r = build(
            procs: [ProcessProbe.Hit(id: .claude, count: 1, viaWarp: false, pid: 42)],
            harvest: [session(.claude, "s1")]
        )
        #expect(r.activity == .running)
    }

    // MARK: - 15 · one wait is singular

    @Test func oneWaitIsSaidInTheSingular() {
        let r = build(harvest: [session(.claude, "s1")], attention: [hook()])
        #expect(r.snapshot.headerTitle == "1 \(L10n.t(.waiting1, .en))")
        let zh = build(harvest: [session(.claude, "s1")], attention: [hook()], lang: .zh)
        #expect(zh.snapshot.headerTitle == "1 \(L10n.t(.waiting1, .zh))")
        let two = build(
            harvest: [session(.claude, "s1"), session(.claude, "s2", cwd: "/w/b")],
            attention: [hook(session: "s1"), hook(session: "s2", cwd: "/w/b")]
        )
        #expect(two.snapshot.headerTitle == "2 \(L10n.t(.waitingN, .en))")
    }
}
