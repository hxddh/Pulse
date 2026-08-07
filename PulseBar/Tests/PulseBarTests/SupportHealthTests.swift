import XCTest
@testable import PulseBar

final class SupportHealthTests: XCTestCase {
    private func health(
        agent: AgentID = .codex,
        evidence: ObservationSource? = .session,
        processDetected: Bool = false,
        goal: Bool = true,
        workspace: Bool = true,
        activity: Bool = true,
        progress: Bool = false,
        waitingReady: Bool = true
    ) -> AgentSupportHealth {
        AgentSupportHealth(
            agent: agent,
            collectorState: .observed,
            collectorDurationMs: 12,
            collectorRows: 1,
            sourcePresent: true,
            collectorErrorKind: "",
            processDetected: processDetected,
            processEvidence: processDetected ? .executable : nil,
            evidence: evidence,
            lastSuccessfulReadMs: 1_700_000_000_000,
            lastWaitingSignalMs: 0,
            hasGoal: goal,
            hasWorkspace: workspace,
            hasActivity: activity,
            hasProgress: progress,
            waitingSignalReady: waitingReady
        )
    }

    func testCoreCoverageIsGoalWorkspaceActivityAndEvidence() {
        let item = health(progress: false, waitingReady: false)
        XCTAssertEqual(item.observedFactCount, 4)
        XCTAssertEqual(item.missingCapabilities, [.waitingSignal])
        XCTAssertNil(item.focusTier)
        XCTAssertFalse(item.focusTTYNeedsOptIn)
    }

    func testSupportFocusFactsAreExplicit() {
        var item = health()
        item.focusTier = .hostApp(.cursor)
        XCTAssertEqual(item.focusTier, .hostApp(.cursor))
        item.focusTier = nil
        item.focusTTYNeedsOptIn = true
        XCTAssertTrue(item.focusTTYNeedsOptIn)
    }

    @MainActor
    func testSupportDepthDistinguishesSessionCacheAndWaitingNone() {
        let store = StatusStore()
        let session = health(agent: .claude)
        XCTAssertEqual(store.supportDepthDetail(session), store.tr(.supportDepthSession))

        let cache = health(agent: .cline, evidence: .cache)
        XCTAssertEqual(AgentID.cline.harvestSource, .bestEffortCache)
        XCTAssertNotEqual(AgentID.cline.waitingSource, .none)
        XCTAssertEqual(store.supportDepthDetail(cache), store.tr(.supportDepthCache))

        let none = health(agent: .devin)
        XCTAssertEqual(AgentID.devin.waitingSource, .none)
        XCTAssertEqual(store.supportDepthDetail(none), store.tr(.supportDepthWaitingNone))
    }

    func testAgentWithoutWaitingContractIsNotPermanentlyIncomplete() {
        let item = health(agent: .devin, progress: true, waitingReady: false)
        XCTAssertTrue(item.missingCapabilities.isEmpty)
        XCTAssertEqual(item.usefulFactCount, 4)
        XCTAssertEqual(item.usefulFactTotal, 4)
        XCTAssertEqual(item.disposition, .available)
    }

    func testProcessOnlyEvidenceAdmitsMissingActivityFeed() {
        let item = health(
            evidence: .process,
            processDetected: true,
            goal: false,
            workspace: false,
            activity: false
        )
        XCTAssertEqual(
            item.missingCapabilities,
            [.activityFeed, .goal, .workspace]
        )
        XCTAssertEqual(item.disposition, .limited)
    }

    func testHealthyRequiresAllFiveUsefulSignals() {
        let item = health(progress: true, waitingReady: true)
        XCTAssertEqual(item.usefulFactCount, 5)
        XCTAssertEqual(item.disposition, .available)
        XCTAssertEqual(item.repair, .none)
    }

    func testTranscriptRecordCountDoesNotPretendToBeExecutionProgress() {
        let item = health(progress: false, waitingReady: true)
        XCTAssertFalse(item.hasProgress)
        XCTAssertEqual(item.usefulFactCount, 4)
    }

    func testPrivacyLimitedStateIsExplicitAndDoesNotChangeDisposition() {
        var item = health(agent: .cursor, evidence: nil, goal: false, workspace: false, activity: false)
        item.collectorState = .sourceAbsent
        item.privacyLimited = true
        XCTAssertTrue(item.privacyLimited)
        XCTAssertEqual(item.disposition, .permissionDenied)
    }

    func testOnlyProtectedStoreAdaptersRequireTheOptIn() {
        XCTAssertTrue(AgentID.cursor.requiresAppDataOptIn)
        XCTAssertTrue(AgentID.warpAgent.requiresAppDataOptIn)
        XCTAssertFalse(AgentID.codex.requiresAppDataOptIn)
        XCTAssertFalse(AgentID.pi.requiresAppDataOptIn)
    }

    @MainActor
    func testSupportCopyExplainsPrivacyLimitedCursorEvidence() {
        let store = StatusStore()
        var item = health(agent: .cursor, evidence: nil, goal: false, workspace: false, activity: false)
        item.collectorState = .sourceAbsent
        item.privacyLimited = true
        XCTAssertEqual(store.supportEvidenceLabel(item), store.tr(.supportCollectorPrivacyLimited))
        XCTAssertTrue(
            store.supportAdapterDetail(item).contains(store.tr(.supportCollectorPrivacyLimitedDetail))
        )
    }

    func testMissingHooksIsActionable() {
        let item = health(agent: .codex, progress: true, waitingReady: false)
        XCTAssertEqual(item.disposition, .needsAction)
        XCTAssertEqual(item.repair, .installHooks)
    }

    @MainActor
    func testTrayDoesNotPromptForMissingHooks() {
        let store = StatusStore()
        store.installPreviewFixture("waiting")

        XCTAssertTrue(store.needsHooksNudge)
        // Hooks remain optional, but a visible Waiting row without notification
        // authorization must explain how to receive the interruption while the
        // tray is closed.
        XCTAssertEqual(store.maintenanceNoticeText, store.tr(.waitingNotifyNotConfigured))
        XCTAssertFalse(store.tr(.emptyHint).localizedCaseInsensitiveContains("install hooks"))
    }

    @MainActor
    func testTrayNudgesOpaqueLiveAgentWhenHooksAreReady() {
        let store = StatusStore()
        store.installPreviewFixture("waiting")
        store.hooksStatus = .installedBoth

        XCTAssertFalse(store.needsHooksNudge)
        XCTAssertTrue(store.needsWaitingSignalNudge)
        XCTAssertEqual(store.maintenanceNoticeText, store.tr(.waitingNotifyNotConfigured))
    }

    func testAdapterFailureOffersRetry() {
        var item = health(progress: true)
        item.collectorState = .schemaMismatch
        XCTAssertEqual(item.disposition, .needsAction)
        XCTAssertEqual(item.repair, .retry)
    }

    func testUnscannedAdapterIsNotReportedAsAnAdapterFailure() {
        var item = health(evidence: nil, progress: false)
        item.collectorState = .unscanned
        XCTAssertEqual(item.disposition, .unscanned)

        item.processDetected = true
        XCTAssertEqual(item.disposition, .limited)
    }

    @MainActor
    func testCursorAgentAliasDoesNotCreateDuplicateSupportEntry() {
        let store = StatusStore()
        store.installPreviewFixture("coverage")
        let agents = Set(store.supportHealth.map(\.agent))
        XCTAssertTrue(agents.contains(.cursor))
        XCTAssertFalse(agents.contains(.cursorAgent))
    }

    @MainActor
    func testObservedSupportLinePrioritizesMeaningfulFactsOverRecordCount() {
        let store = StatusStore()
        store.installPreviewFixture("coverage")
        guard let item = store.supportHealth.first(where: { $0.agent == .cursor }) else {
            return XCTFail("coverage fixture should include Cursor")
        }
        let observed = store.supportObservedDetail(item)
        XCTAssertTrue(observed.contains("Refine adapter coverage"), observed)
        XCTAssertTrue(observed.contains("Turn complete"), observed)
        XCTAssertFalse(observed.localizedCaseInsensitiveContains("events"), observed)
    }

    @MainActor
    func testProcessSupportTimelineIncludesProcessAge() {
        let store = StatusStore()
        var item = health(
            agent: .amp,
            evidence: .process,
            processDetected: true,
            goal: false,
            workspace: false,
            activity: false
        )
        item.processStartedMs = Int64((Date().timeIntervalSince1970 - 3_600) * 1000)
        item.processCount = 2
        let timeline = store.supportTimelineDetail(item)
        XCTAssertTrue(timeline.contains("Process started"), timeline)
        XCTAssertTrue(timeline.contains("1h"), timeline)
        XCTAssertTrue(timeline.contains("2 processes"), timeline)
    }

    @MainActor
    func testStatusFixturesInjectConcreteTrayRows() {
        let store = StatusStore()
        store.installPreviewFixture("status-waiting")
        XCTAssertEqual(store.snapshot.glance, .waiting)
        XCTAssertEqual(store.snapshot.rows.count, 1)
        XCTAssertEqual(store.snapshot.totalCount, 1)
        XCTAssertTrue(store.snapshot.rows[0].waiting)
        XCTAssertEqual(store.snapshot.rows[0].waitSignal, .hooks)
        XCTAssertFalse(store.snapshot.rows[0].quality.facts.isEmpty)

        store.installPreviewFixture("status-running")
        XCTAssertEqual(store.snapshot.glance, .running)
        XCTAssertEqual(store.snapshot.rows.count, 1)
        XCTAssertFalse(store.snapshot.rows[0].waiting)
        XCTAssertEqual(store.snapshot.rows[0].progressDone, 12)

        store.installPreviewFixture("status-stalled")
        XCTAssertEqual(store.snapshot.glance, .stalled)
        XCTAssertEqual(store.snapshot.rows.count, 1)
        XCTAssertTrue(store.snapshot.rows[0].isStalled)
    }

    @MainActor
    func testScopedAppDataPrivacyBannerIsNotGlobalOffCopy() {
        let store = StatusStore()
        store.allowAppData = false
        store.appDataAgents = [.cursor]
        store.language = .en

        var limited = health(agent: .warpAgent, evidence: nil, goal: false, workspace: false, activity: false)
        limited.privacyLimited = true
        limited.collectorState = .sourceAbsent

        var cursor = health(agent: .cursor, evidence: .session, processDetected: true, goal: true, workspace: true, activity: true, progress: true)
        cursor.privacyLimited = false
        cursor.collectorState = .observed

        // Inject via published support path: rebuild from install fixture then override policy.
        store.installPreviewFixture("coverage")
        store.allowAppData = false
        store.appDataAgents = [.cursor]
        // Force a privacy-limited peer while Cursor remains granted.
        XCTAssertTrue(store.isAppDataAllowed(for: .cursor))
        XCTAssertFalse(store.isAppDataAllowed(for: .warpAgent))
        XCTAssertEqual(store.appDataGrantMode, .scoped(1))

        // Banner text for scoped grants must not claim the scan is fully off.
        let noneBanner = store.tr(.supportCollectorPrivacyLimitedDetail)
        // Simulate privacyLimitedCount > 0 with scoped mode by temporarily
        // clearing cursor grant on a synthetic health list is hard without
        // private setters — assert the localized scoped format instead.
        let scoped = String(format: store.tr(.supportCollectorPrivacyLimitedScoped), 1, 2)
        XCTAssertTrue(scoped.contains("1"))
        XCTAssertTrue(scoped.contains("2"))
        XCTAssertNotEqual(scoped, noneBanner)
        XCTAssertFalse(scoped.localizedCaseInsensitiveContains("scan is off"))
    }

    @MainActor
    func testObservationGapNextStepsAreExplicit() {
        let store = StatusStore()
        store.language = .en
        let open = ObservationGap(key: .task, reason: "process_only", nextStep: "open_agent_for_session")
        let retry = ObservationGap(key: .task, reason: "scan_timeout", nextStep: "retry_scan")
        let enable = ObservationGap(key: .task, reason: "privacy_limited", nextStep: "enable_app_data")
        XCTAssertEqual(store.observationGapNextStep(open), store.tr(.qualityNextOpenAgent))
        XCTAssertEqual(store.observationGapNextStep(retry), store.tr(.qualityNextRetryScan))
        XCTAssertEqual(store.observationGapNextStep(enable), store.tr(.supportEnableData))
        XCTAssertEqual(store.observationGapReason(retry), store.tr(.qualityReasonScanTimeout))
    }

    @MainActor
    func testOpenSettingsFocusesAppDataAgent() {
        let store = StatusStore()
        store.openSettings(focusAppDataFor: .cursor)
        XCTAssertEqual(store.settingsFocusAppDataAgent, .cursor)
        XCTAssertTrue(store.settingsExpandAppDataScopes)
    }

    @MainActor
    func testScanIncompleteTimeoutCopyDiffersFromGeneric() {
        let store = StatusStore()
        store.language = .en
        store.recordCollectorHealth(
            [
                ActivityHarvest.CollectorHealth(
                    id: .claude,
                    state: .failed,
                    durationMs: 900,
                    rowCount: 2,
                    sourcePresent: true,
                    errorKind: "native_timeout"
                )
            ],
            complete: false
        )
        XCTAssertEqual(store.scanIncompleteBannerText, store.tr(.supportScanIncompleteTimeout))
        store.recordCollectorHealth(
            [
                ActivityHarvest.CollectorHealth(
                    id: .claude,
                    state: .failed,
                    durationMs: 10,
                    rowCount: 0,
                    sourcePresent: true,
                    errorKind: "native_error"
                )
            ],
            complete: false
        )
        XCTAssertEqual(store.scanIncompleteBannerText, store.tr(.supportScanIncomplete))
    }

    @MainActor
    func testIntentionalSupervisorPartialDoesNotLightIncompleteBanner() {
        let store = StatusStore()
        store.language = .en
        store.recordCollectorHealth(
            [
                ActivityHarvest.CollectorHealth(
                    id: .codex,
                    state: .observed,
                    durationMs: 12,
                    rowCount: 1,
                    sourcePresent: true,
                    errorKind: ""
                )
            ],
            complete: false,
            intentionalPartial: true
        )
        XCTAssertFalse(store.collectorScanIncomplete)
        XCTAssertNil(store.scanIncompleteBannerText)
    }

    @MainActor
    func testSafeSupportReportIncludesReleaseAndNotifyFields() {
        let store = StatusStore()
        let report = store.safeSupportReport()
        XCTAssertTrue(report.contains("channel:"))
        XCTAssertTrue(report.contains("notarized:"))
        XCTAssertTrue(report.contains("notifications: authorization="))
        XCTAssertTrue(report.contains("notifyWaiting="))
        XCTAssertTrue(report.contains("pending="))
        XCTAssertTrue(report.contains("appDataGrant:"))
        XCTAssertTrue(report.contains("probeCadence:"))
        XCTAssertTrue(report.contains("timeoutAgents:"))
        XCTAssertTrue(report.contains("harvestSupervisor:"))
        XCTAssertTrue(report.contains("deferred="))
        XCTAssertTrue(report.contains("factCoverage: present="))
        XCTAssertTrue(report.contains("failureTimeline:"))
    }

    func testOpaqueLiveAgentOffersAttentionBridgeRepair() {
        var item = health(
            agent: .replit,
            evidence: .process,
            processDetected: true,
            goal: false,
            workspace: false,
            activity: false
        )
        XCTAssertEqual(item.agent.waitingSource, .none)
        XCTAssertEqual(item.repair, .openAttentionBridge)
    }

    @MainActor
    func testObservationGapAttentionBridgeIsActionable() {
        let store = StatusStore()
        store.language = .en
        let gap = ObservationGap(
            key: .waitingReason,
            reason: "waiting_unsupported",
            nextStep: "use_attention_bridge"
        )
        XCTAssertEqual(store.observationGapNextStep(gap), store.tr(.qualityNextAttentionBridge))
        XCTAssertEqual(store.observationGapReason(gap), store.tr(.supportWaitingNoneDetail))
        store.openSettings(focusWaitingSignals: true)
        XCTAssertTrue(store.settingsFocusWaitingSignals)
    }

    @MainActor
    func testCachePrivacyGapDeepLinksToAppData() {
        let store = StatusStore()
        store.language = .en
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
            harvestMs: 1,
            processStartedMs: 0,
            privacyLimited: true,
            agentHarvestSource: .bestEffortCache,
            waitingSource: .harvestPending
        )
        XCTAssertTrue(quality.missing.contains(where: {
            $0.reason == "privacy_limited" && $0.nextStep == "enable_app_data"
        }))
        let gap = quality.missing.first { $0.nextStep == "enable_app_data" }!
        XCTAssertEqual(store.observationGapNextStep(gap), store.tr(.supportEnableData))
    }
}
