import XCTest
@testable import PulseBar

/// 0.96 Return Truth — Look after the opening scan, wait generation, Glance
/// width, Attention compact/rekey, and Details honesty.
@MainActor
final class ReturnTruthTests: XCTestCase {

    private func snap(
        key: String,
        agent: String = "claude",
        waiting: Bool = false,
        waitSinceMs: Int64 = 0,
        harvestMs: Int64 = 1_000,
        phase: String = "working",
        tool: String = "Bash",
        task: String = "Work",
        changeTag: String = "",
        tokensIn: Int = 0,
        tokensOut: Int = 0,
        progressDone: Int = 0,
        activityChangedMs: Int64 = 0,
        waitKind: String = ""
    ) -> StatusStore.TrayLookFingerprint.RowSnap {
        .init(
            rowKey: key,
            agentRaw: agent,
            label: "\(agent) · \(task)",
            waiting: waiting,
            waitKind: waitKind,
            phase: phase,
            tool: tool,
            task: task,
            harvestMs: harvestMs,
            activityChangedMs: activityChangedMs,
            changeTag: changeTag,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            progressDone: progressDone,
            waitSinceMs: waitSinceMs
        )
    }

    private func fingerprint(
        _ rows: [StatusStore.TrayLookFingerprint.RowSnap],
        closedAt: Date = Date()
    ) -> StatusStore.TrayLookFingerprint {
        .init(closedAt: closedAt, rows: rows)
    }

    // MARK: P0 Look Continuity

    func testLookContinuityAppliesAfterTrayOpenScan() {
        let store = StatusStore()
        store.installPreviewFixture("status-running")
        store.trayDidDisappear()
        store.installPreviewFixture("status-waiting")
        store.trayDidAppear()
        XCTAssertEqual(store.lookNewWaitsWhileAway, 1)
        XCTAssertEqual(store.lookContinuityItems.first?.kind, .newWait)
        XCTAssertEqual(store.lookContinuityPrimaryRevealKey, "status-fixture")
    }

    func testSameRowNewWaitGenerationOutranksEnded() {
        let prior = fingerprint([
            snap(key: "claude|s1", waiting: true, waitSinceMs: 1_000, waitKind: "Permission"),
        ])
        let current = fingerprint([
            snap(
                key: "claude|s1",
                waiting: true,
                waitSinceMs: 9_000,
                harvestMs: 2_000,
                phase: "waiting",
                tool: "",
                changeTag: "phase",
                waitKind: "Idle prompt"
            ),
        ])
        let keys = StatusStore.lookContinuityKeyDelta(prior: prior, current: current)
        XCTAssertEqual(keys.newWaitKeys, ["claude|s1"])
        XCTAssertTrue(keys.movedKeys.isEmpty, "new wait generation must not also count as moved")
    }

    func testEndedWaitIsNotAlsoMoved() {
        let store = StatusStore()
        store.installPreviewFixture("status-waiting")
        let prior = store.captureLookFingerprint()
        store.seedWaitHistory([
            .init(
                rowKey: "status-fixture",
                agent: .cursor,
                title: "Approve the packaging step",
                kind: "Permission",
                project: "Pulse",
                resolvedAt: Date(),
                waitedSeconds: 120
            ),
        ])
        store.installPreviewFixture("status-running")
        store.applyLookContinuity(prior: prior, closedAt: prior.closedAt)
        XCTAssertEqual(store.lookContinuityItems.map(\.kind), [.endedWait])
        XCTAssertFalse(store.lookMovedRowKeys.contains("status-fixture"))
        XCTAssertEqual(store.lookMovedWhileAway, 0, "ended key must not also count as moved")
    }

    func testGlanceTitleBudgetFitsEightCells() {
        XCTAssertEqual(GlanceTitle.cells("Claude…"), 7)
        XCTAssertEqual(GlanceTitle.cells("Claude · 4m"), 11)
        XCTAssertEqual(GlanceTitle.cells("1 · 4m"), 6)
        XCTAssertEqual(GlanceTitle.cells("中"), 2)
        XCTAssertEqual(GlanceTitle.fit("Claude · 4m", "1 · 4m", "1"), "1 · 4m")
        XCTAssertEqual(GlanceTitle.fit("Claude…", "1"), "Claude…")
        XCTAssertEqual(GlanceTitle.fit("Antigravity", "1"), "1")
        XCTAssertLessThanOrEqual(GlanceTitle.cells("Claude…"), GlanceTitle.maxCells)
    }

    func testIdleGlanceStaysEmpty() {
        let r = SnapshotBuilder.build(
            SnapshotBuilder.Input(procs: [], harvest: [], harvestUnreliable: false, attention: []),
            previous: .init(),
            context: SnapshotBuilder.Context(
                nowMs: 1_700_000_000_000,
                terminal: TerminalFocus.Environment(warpRunning: false, ttyHostRunning: false),
                lang: .en
            )
        )
        XCTAssertEqual(r.snapshot.glance, .idle)
        XCTAssertEqual(r.snapshot.title, "")
    }

    func testSampleRevealWaitsUntilTheRowExists() {
        let store = StatusStore()
        store.installPreviewFixture("status-running")
        store.clearPendingRevealRowKey()
        store.testingRevealSampleIfPresent(session: "pulse-sample")
        XCTAssertTrue(store.testingHasPendingSampleReveal)
        XCTAssertNil(store.pendingRevealRowKey)

        store.installPreviewFixture("status-waiting")
        store.clearPendingRevealRowKey()
        store.testingRevealSampleIfPresent(session: "status-fixture")
        XCTAssertEqual(store.pendingRevealRowKey, "status-fixture")
        XCTAssertFalse(store.testingHasPendingSampleReveal)
    }

    // MARK: P1 identity / compact

    func testAttentionCompactKeepsUnresolvedRaise() {
        var lines: [String] = []
        for index in 0..<90 {
            lines.append("amp\tdone\t\(1_700_000_000_000 + index)\tok\tsess-\(index)\t/tmp")
        }
        lines.insert("amp\tpermission\t1\tapprove\tkeep-me\t/tmp", at: 0)
        let compacted = AttentionIO.compactLines(lines, cap: 80)
        XCTAssertEqual(compacted.count, 80)
        XCTAssertTrue(
            compacted.contains(where: { $0.contains("keep-me") }),
            "unresolved permission must survive the 80-line cap"
        )
    }

    func testAttentionLedgerRemapFollowsNewRowKey() {
        var ledger = AttentionLedger()
        var row = AgentRow(rowKey: "codex", agent: .codex)
        row.waiting = true
        row.waitKind = "Permission"
        ledger.reconcile(activeRows: [row], nowMs: 1_000)
        ledger.snooze(rowKey: "codex", untilMs: 9_000)
        ledger.remapRowKey(from: "codex", to: "codex|sess")
        XCTAssertEqual(ledger.activeKeys, ["codex|sess"])
        XCTAssertNotNil(ledger.snoozedUntil["codex|sess"])
        XCTAssertNil(ledger.snoozedUntil["codex"])
    }

    // MARK: P2 Details / story honesty

    func testActionableObservationGapsSortFirst() {
        let store = StatusStore()
        let gaps = [
            ObservationGap(key: .task, reason: "not_emitted", nextStep: "open_agent_for_session"),
            ObservationGap(key: .waitingReason, reason: "waiting_unsupported", nextStep: "use_attention_bridge"),
            ObservationGap(key: .workspace, reason: "privacy_limited", nextStep: "enable_app_data"),
            ObservationGap(key: .model, reason: "cache_thin", nextStep: "wait_for_vendor_cache"),
        ]
        let ranked = store.prioritizedObservationGaps(gaps)
        XCTAssertEqual(ranked.map(\.nextStep).prefix(2).sorted(), ["enable_app_data", "use_attention_bridge"])
        XCTAssertEqual(ranked.last?.nextStep, "wait_for_vendor_cache")
    }

    func testQuietStoryDoesNotRepeatObservationModelTokens() {
        let store = StatusStore()
        var row = AgentRow(rowKey: "k", agent: .claude)
        row.task = "Quiet live session"
        row.model = "gpt-5"
        row.tokensIn = 900
        row.tokensOut = 40
        row.phase = ""
        row.tool = ""
        row.liveProcess = true
        row.observationSource = .session
        row.refreshObservationQuality()
        let story = store.rowStoryLine(row)
        let observation = store.rowObservationLine(row)
        XCTAssertEqual(story, "", "observation owns model/tokens: \(story)")
        XCTAssertTrue(
            observation.contains("gpt 5") || observation.contains("Model") || observation.contains("模型"),
            observation
        )
    }

    func testOpaqueCacheStoryDoesNotRepeatIdentityLabel() throws {
        let store = StatusStore()
        var row = AgentRow(rowKey: "amp", agent: .amp)
        row.task = ""
        row.tool = ""
        row.liveProcess = false
        row.observationSource = .cache
        row.harvestMs = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        row.refreshObservationQuality()
        let story = store.rowStoryLine(row)
        let label = try XCTUnwrap(store.rowSourceLabel(row))
        XCTAssertEqual(label, store.tr(.cacheEvidence))
        let bits = story.split(separator: "·").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertFalse(bits.contains(label), "identity tag must not repeat on story: \(story)")
        XCTAssertFalse(story.hasPrefix(label), story)
    }

    func testStoryOwnsChangeSoDetailsCanSkipDuplicate() {
        let store = StatusStore()
        var row = AgentRow(rowKey: "k", agent: .claude)
        row.task = "Ship"
        row.phase = "working"
        row.tool = "Edit"
        row.liveProcess = true
        row.activityChange = .toolChanged
        XCTAssertTrue(store.storyOwnsChange(row))
        XCTAssertFalse(store.rowStoryLine(row).isEmpty)
    }
}
