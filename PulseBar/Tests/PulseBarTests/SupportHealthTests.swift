import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

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

        let thin = health(agent: .cline, evidence: .cache, goal: false, workspace: false, activity: false)
        XCTAssertEqual(AgentID.cline.harvestSource, .bestEffortCache)
        XCTAssertNotEqual(AgentID.cline.waitingSource, .none)
        XCTAssertEqual(store.supportDepthDetail(thin), store.tr(.supportDepthCacheThin))

        let rich = health(agent: .cline, evidence: .cache, goal: true, workspace: true, activity: true)
        XCTAssertEqual(store.supportDepthDetail(rich), store.tr(.supportDepthCachePartial))

        let none = health(agent: .devin, evidence: .cache, goal: false, workspace: false, activity: false)
        XCTAssertEqual(AgentID.devin.waitingSource, .none)
        XCTAssertEqual(AgentID.devin.harvestSource, .bestEffortCache)
        XCTAssertEqual(
            store.supportDepthDetail(none),
            "\(store.tr(.supportDepthWaitingNone)) · \(store.tr(.supportDepthCacheThin))"
        )

        let richNone = health(agent: .zcode, evidence: .cache, goal: true, workspace: true, activity: true)
        XCTAssertEqual(AgentID.zcode.waitingSource, .none)
        XCTAssertEqual(
            store.supportDepthDetail(richNone),
            "\(store.tr(.supportDepthWaitingNone)) · \(store.tr(.supportDepthCachePartial))"
        )
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
    func testNotificationSetupOutranksTheHooksOffer() {
        let store = StatusStore()
        store.installPreviewFixture("waiting")

        XCTAssertTrue(store.needsHooksNudge)
        // A visible Waiting row without notification authorization must
        // explain how to receive the interruption while the tray is closed;
        // that outranks the (optional) hooks offer.
        XCTAssertEqual(store.maintenanceNoticeText, store.tr(.waitingNotifyNotConfigured))
        XCTAssertFalse(store.tr(.emptyHint).localizedCaseInsensitiveContains("install hooks"))
    }

    @MainActor
    func testLiveClaudeWithoutHooksIsOfferedTheInstall() {
        let store = StatusStore()
        store.installPreviewFixture("waiting")
        store.notifyAuthorized = true

        XCTAssertTrue(store.needsHooksNudge)
        XCTAssertEqual(store.maintenanceNoticeText, store.tr(.hooksNudge),
                       "21.0: the tray offers the one-click Claude/Codex install")
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

    /// 23.0: one app-data switch. With it off, a fixture that has
    /// protected agents shows the privacy banner; with it on, nothing is
    /// privacy-limited and the banner is gone.
    @MainActor
    func testOneAppDataSwitchDrivesThePrivacyBanner() {
        let store = StatusStore()
        store.language = .en
        store.installPreviewFixture("coverage")
        store.settings.readProtectedAppData = false
        XCTAssertTrue(store.settings.isPrivacyLimited(.cursor))
        XCTAssertGreaterThan(store.privacyLimitedCount, 0)
        XCTAssertEqual(store.privacyBannerText, store.tr(.supportCollectorPrivacyLimitedDetail))

        store.settings.readProtectedAppData = true
        XCTAssertFalse(store.settings.isPrivacyLimited(.cursor))
        XCTAssertEqual(store.privacyLimitedCount, 0)
        XCTAssertNil(store.privacyBannerText)
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
    func testOpenSettingsFocusesAppData() {
        let store = StatusStore()
        let before = store.settingsFocus.token
        store.openSettings(focus: .appData)
        XCTAssertEqual(store.settingsFocus.target, .appData)
        XCTAssertNotEqual(store.settingsFocus.token, before, "a deep link moves the token")
    }

    @MainActor
    func testScanIncompleteTimeoutCopyDiffersFromGeneric() {
        let store = StatusStore()
        store.language = .en
        store.engine.recordCollectorHealth(
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
        store.engine.recordCollectorHealth(
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
        store.engine.recordCollectorHealth(
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
        XCTAssertTrue(report.contains("gatekeeperReady:"))
        XCTAssertTrue(report.contains("waitingNone:"))
        XCTAssertTrue(report.contains("zcode"))
        XCTAssertTrue(report.contains("notifications: authorization="))
        XCTAssertTrue(report.contains("notifyWaiting="))
        XCTAssertTrue(report.contains("queued="))
        XCTAssertTrue(report.contains("sessionLog: sessions="))
        XCTAssertTrue(report.contains("appDataGrant:"))
        XCTAssertTrue(report.contains("probeCadence:"))
        XCTAssertTrue(report.contains("timeoutAgents:"))
        XCTAssertTrue(report.contains("harvestSupervisor:"))
        XCTAssertTrue(report.contains("deferred="))
        XCTAssertTrue(report.contains("factCoverage: present="))
        XCTAssertTrue(report.contains("failureTimeline:"))
    }

    func testOpaqueLiveAgentOffersAttentionBridgeRepair() {
        let item = health(
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

    func testWaitingNoneAgentsCoverEveryWaitingNoneContract() {
        let none = Set(AgentID.allCases.filter { $0.waitingSource == .none && $0 != .cursorAgent })
        let listed = Set(AgentID.waitingNoneAgents)
        XCTAssertEqual(listed, none)
        XCTAssertFalse(listed.contains(.claude))
        XCTAssertFalse(listed.contains(.codex))
        XCTAssertTrue(listed.contains(.zcode))
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
        store.openSettings(focus: .waitingSignals)
        XCTAssertEqual(store.settingsFocus.target, .waitingSignals)
    }

    @MainActor
    func testMaintenanceNoticeOpensWaitingReachWithOpaqueAgent() {
        let store = StatusStore()
        store.language = .en
        store.hooksStatus = .installedBoth
        // Prefer opaque Reach over notify setup: disable Waiting notifications.
        store.settings.notifyOnWaiting = false
        store.installPreviewFixture("waiting")
        guard store.needsWaitingSignalNudge else {
            store.openSettings(focus: .waitingSignals)
            XCTAssertEqual(store.settingsFocus.target, .waitingSignals)
            return
        }
        store.performMaintenanceNoticeAction()
        XCTAssertEqual(store.settingsFocus.target, .waitingSignals)
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

    // MARK: collector explain on screen (M-4)

    @MainActor
    func testReadingLineNamesWhatTheAdapterActuallyRead() {
        let store = StatusStore()
        store.language = .en
        var item = health()
        item.collectorExplain = ActivityHarvest.CollectorExplain(
            filesRead: 3,
            bytesRead: 41 * 1024,
            truncated: false,
            factsParsed: 7,
            heroOrigin: "user_prompt",
            emptyReason: ""
        )
        let reading = store.supportReadingDetail(item)
        XCTAssertTrue(reading.contains("3"), reading)
        XCTAssertTrue(reading.contains("7"), reading)
        XCTAssertFalse(reading.contains("floors"), "nothing was truncated, so nothing is a floor")
        XCTAssertEqual(
            store.supportCollectorOutcomeDetail(item),
            String(format: store.tr(.supportExplainHero), store.tr(.supportOriginUserPrompt))
        )
    }

    @MainActor
    func testATruncatedWindowSaysTheCountsAreFloors() {
        let store = StatusStore()
        store.language = .en
        var item = health()
        item.collectorExplain = ActivityHarvest.CollectorExplain(
            filesRead: 2,
            bytesRead: 1024,
            truncated: true,
            factsParsed: 4
        )
        // A number read from a head+tail window is a floor. Printing it beside
        // no truncation marker would be the estimate-as-total this project
        // forbids everywhere else.
        XCTAssertTrue(
            store.supportReadingDetail(item).contains(store.tr(.supportExplainTruncated)),
            store.supportReadingDetail(item)
        )
    }

    @MainActor
    func testAnEmptyAdapterSaysWhichLayerLostIt() {
        let store = StatusStore()
        store.language = .en
        var item = health(goal: false)
        for (tag, key) in [
            ("no_source", L10n.Key.supportEmptyNoSource),
            ("deadline", .supportEmptyDeadline),
            ("no_readable_file", .supportEmptyNoReadableFile),
            ("no_parsable_record", .supportEmptyNoParsableRecord),
            ("facts_without_display_signal", .supportEmptyNoDisplaySignal),
            ("no_user_goal_in_records", .supportEmptyNoUserGoal),
        ] {
            item.collectorExplain = ActivityHarvest.CollectorExplain(emptyReason: tag)
            XCTAssertEqual(
                store.supportCollectorOutcomeDetail(item),
                String(format: store.tr(.supportExplainEmpty), store.tr(key)),
                tag
            )
        }
    }

    @MainActor
    func testAnUnknownTagIsShownRatherThanSwallowed() {
        let store = StatusStore()
        store.language = .en
        // A reason added by a future adapter must be visible the day it ships.
        // Falling back to "" would hide it until somebody noticed the blank.
        XCTAssertEqual(store.collectorEmptyReasonLabel("some_future_reason"), "some_future_reason")
        XCTAssertEqual(store.collectorOriginLabel("some_future_origin"), "some_future_origin")
    }

    @MainActor
    func testNothingReadPrintsNothingRatherThanZeros() {
        let store = StatusStore()
        store.language = .en
        var item = health()
        item.collectorExplain = ActivityHarvest.CollectorExplain()
        XCTAssertEqual(store.supportReadingDetail(item), "")
        XCTAssertEqual(store.supportCollectorOutcomeDetail(item), "")
    }

    @MainActor
    func testExplainIsTranslatedInBothLanguages() {
        let store = StatusStore()
        var item = health()
        item.collectorExplain = ActivityHarvest.CollectorExplain(
            filesRead: 1,
            bytesRead: 2048,
            factsParsed: 1,
            emptyReason: "deadline"
        )
        store.language = .en
        let en = store.supportCollectorOutcomeDetail(item)
        store.language = .zh
        let zh = store.supportCollectorOutcomeDetail(item)
        XCTAssertFalse(en.isEmpty)
        XCTAssertNotEqual(en, zh, "the diagnostics disclosure is user-facing copy, not a log line")
    }
}
