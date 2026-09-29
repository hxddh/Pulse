import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

/// 0.96 Return Truth — Glance width, Attention compact/rekey, and Details
/// honesty.
final class ReturnTruthTests: XCTestCase {

    @MainActor
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

    @MainActor
    func testIdleGlanceStaysEmpty() {
        let r = SnapshotBuilder.build(
            SnapshotBuilder.Input(procs: [], harvest: [], attention: []),
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

    // MARK: P1 identity / compact

    @MainActor
    func testAttentionCompactKeepsUnresolvedRaise() {
        var lines: [String] = []
        for index in 0..<90 {
            lines.append("amp\tdone\t\(1_700_000_000_000 + index)\tok\tsess-\(index)\t/tmp\t\t")
        }
        lines.insert("amp\tpermission\t1\tapprove\tkeep-me\t/tmp\t\t", at: 0)
        let compacted = AttentionIO.compactLines(lines, cap: 80)
        XCTAssertEqual(compacted.count, 80)
        XCTAssertTrue(
            compacted.contains(where: { $0.contains("keep-me") }),
            "unresolved permission must survive the 80-line cap"
        )
    }

    @MainActor
    func testSessionLogRemapFollowsNewRowKey() {
        var log = SessionLog()
        var row = AgentRow(rowKey: "codex", agent: .codex)
        row.waiting = true
        row.waitKind = "Permission"
        log.reconcileWaits(rows: [row], released: [], nowMs: 1_000)
        log.remap(from: "codex", to: "codex|sess")
        XCTAssertEqual(log.waitingKeys, ["codex|sess"])
        XCTAssertNil(log.openWait("codex"))
    }

    // MARK: P2 Details / story honesty

    @MainActor
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

    @MainActor
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
        let work = store.rowWorkLine(row)
        XCTAssertEqual(story, "", "the work line owns model/tokens: \(story)")
        XCTAssertTrue(
            work.contains("gpt 5") || work.contains("Model") || work.contains("模型"),
            work
        )
    }

    @MainActor
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

    @MainActor
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
