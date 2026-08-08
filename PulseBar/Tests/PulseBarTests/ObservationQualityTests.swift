import XCTest
@testable import PulseBar

final class ObservationQualityTests: XCTestCase {
    func testSessionRowHighConfidenceWhenCoreFactsPresent() {
        let quality = ObservationQuality.derive(
            task: "Fix the tray",
            workspace: "/Users/me/Pulse",
            action: "edit",
            phase: "editing",
            model: "gpt",
            progressDone: 1,
            progressTotal: 3,
            errors: 0,
            waiting: false,
            waitMessage: "",
            evidence: .session,
            harvestMs: 1_700_000_000_000,
            processStartedMs: 0,
            privacyLimited: false,
            agentHarvestSource: .structuredSession,
            waitingSource: .hooks
        )
        XCTAssertEqual(quality.confidence, .high)
        XCTAssertTrue(quality.facts.contains(.task))
        XCTAssertTrue(quality.facts.contains(.workspace))
        XCTAssertTrue(quality.facts.contains(.evidence))
        XCTAssertFalse(quality.isLimited)
    }

    func testProcessOnlyExplainsMissingFacts() {
        let quality = ObservationQuality.derive(
            task: "",
            workspace: "",
            action: "",
            phase: "",
            model: "",
            progressDone: 0,
            progressTotal: 0,
            errors: 0,
            waiting: false,
            waitMessage: "",
            evidence: .process,
            harvestMs: 0,
            processStartedMs: 1_700_000_000_000,
            privacyLimited: true,
            agentHarvestSource: .bestEffortCache,
            waitingSource: .none
        )
        XCTAssertEqual(quality.confidence, .low)
        XCTAssertTrue(quality.isLimited)
        XCTAssertTrue(quality.missing.contains(where: { $0.reason == "privacy_limited" }))
        XCTAssertTrue(quality.missing.contains(where: { $0.nextStep == "enable_app_data" }))
        XCTAssertTrue(quality.missing.contains(where: { $0.key == .waitingReason && $0.reason == "waiting_unsupported" }))
    }

    func testCacheAgentGetsMediumConfidenceWithPartialFacts() {
        let quality = ObservationQuality.derive(
            task: "Cache title",
            workspace: "/tmp/proj",
            action: "",
            phase: "",
            model: "cache-model",
            progressDone: 0,
            progressTotal: 0,
            errors: 0,
            waiting: false,
            waitMessage: "",
            evidence: .cache,
            harvestMs: 1_700_000_000_000,
            processStartedMs: 0,
            privacyLimited: false,
            agentHarvestSource: .bestEffortCache,
            waitingSource: .none
        )
        XCTAssertEqual(quality.confidence, .medium)
        XCTAssertTrue(quality.missing.contains(where: { $0.reason == "cache_conditional" }))
    }

    func testThinBestEffortCacheStaysLimitedNeverHigh() {
        let quality = ObservationQuality.derive(
            task: "Only a title",
            workspace: "",
            action: "",
            phase: "",
            model: "x",
            progressDone: 0,
            progressTotal: 0,
            errors: 0,
            waiting: false,
            waitMessage: "",
            evidence: .cache,
            harvestMs: 1_700_000_000_000,
            processStartedMs: 0,
            privacyLimited: false,
            agentHarvestSource: .bestEffortCache,
            waitingSource: .harvestPending
        )
        XCTAssertEqual(quality.confidence, .low)
        XCTAssertTrue(quality.isLimited)
        XCTAssertTrue(quality.missing.contains(where: { $0.reason == "cache_conditional" }))
        XCTAssertFalse(quality.missing.contains(where: { $0.nextStep == "enable_app_data" }))
    }

    func testPrivacyLimitedCacheStillOffersEnableAppData() {
        let quality = ObservationQuality.derive(
            task: "",
            workspace: "",
            action: "",
            phase: "",
            model: "",
            progressDone: 0,
            progressTotal: 0,
            errors: 0,
            waiting: false,
            waitMessage: "",
            evidence: .cache,
            harvestMs: 0,
            processStartedMs: 0,
            privacyLimited: true,
            agentHarvestSource: .bestEffortCache,
            waitingSource: .harvestPending
        )
        XCTAssertTrue(quality.isLimited)
        XCTAssertTrue(quality.missing.contains(where: {
            $0.reason == "privacy_limited" && $0.nextStep == "enable_app_data"
        }))
    }

    func testAgentRowRefreshObservationQuality() {
        var row = AgentRow(rowKey: "codex|s1", agent: .codex)
        row.task = "Ship 0.50"
        row.cwd = "/Users/me/Pulse"
        row.tool = "bash"
        row.observationSource = .session
        row.harvestMs = 1_700_000_000_000
        row.refreshObservationQuality()
        XCTAssertTrue(row.quality.facts.contains(.task))
        XCTAssertEqual(row.quality.confidence, .high)
    }
}

final class SessionIndexTests: XCTestCase {
    func testRetainCeilingAllowsFiveHundredSessions() {
        var harvest: [ActivityHarvest.Row] = []
        for index in 0..<520 {
            harvest.append(ActivityHarvest.Row(
                id: .opencode,
                task: "Session \(index)",
                project: "Pulse",
                cwd: "/tmp/pulse-\(index)",
                skill: "",
                harvestMs: 1_700_000_000_000 + Int64(index),
                sessionID: "s-\(index)",
                evidence: .session
            ))
        }
        let result = SnapshotBuilder.build(
            SnapshotBuilder.Input(harvest: harvest),
            previous: SnapshotBuilder.Previous(),
            context: SnapshotBuilder.Context(
                nowMs: 1_700_000_000_000 + 10_000,
                terminal: TerminalFocus.Environment(warpRunning: false, ttyHostRunning: false),
                lang: .en,
                maxSessionsPerAgent: SnapshotBuilder.maxSessionsPerAgent,
                maxVisibleRows: SnapshotBuilder.maxVisibleRows
            )
        )
        XCTAssertEqual(SnapshotBuilder.maxSessionsPerAgent, 500)
        XCTAssertEqual(result.rows.count, 500)
        XCTAssertEqual(result.snapshot.cappedSessions, 20)
        XCTAssertEqual(result.snapshot.rows.count, SnapshotBuilder.maxVisibleRows)
        XCTAssertEqual(result.snapshot.totalCount, 500)
        XCTAssertTrue(result.rows.allSatisfy { !$0.quality.facts.isEmpty || !$0.quality.missing.isEmpty })
    }

    func testPressureLevelsFourTwentyOneHundred() {
        for count in [4, 20, 100] {
            var harvest: [ActivityHarvest.Row] = []
            for index in 0..<count {
                harvest.append(ActivityHarvest.Row(
                    id: .codex,
                    task: "Pressure \(index)",
                    project: "Pulse",
                    cwd: "/tmp/\(index)",
                    skill: "",
                    harvestMs: 1_700_000_000_000 + Int64(index),
                    sessionID: "p-\(index)",
                    evidence: .session
                ))
            }
            let result = SnapshotBuilder.build(
                SnapshotBuilder.Input(harvest: harvest),
                previous: SnapshotBuilder.Previous(),
                context: SnapshotBuilder.Context(
                    nowMs: 1_700_000_000_000 + 5_000,
                    terminal: TerminalFocus.Environment(warpRunning: false, ttyHostRunning: false),
                    lang: .en
                )
            )
            XCTAssertEqual(result.rows.count, count, "lost sessions at pressure \(count)")
            XCTAssertEqual(result.snapshot.cappedSessions, 0)
        }
    }
}
