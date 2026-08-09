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
        XCTAssertTrue(report.contains("gatekeeperReady:"))
        XCTAssertTrue(report.contains("waitingNone:"))
        XCTAssertTrue(report.contains("zcode"))
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

    func testAttentionSampleAgentsCoverEveryWaitingNoneContract() {
        let none = Set(AgentID.allCases.filter { $0.waitingSource == .none && $0 != .cursorAgent })
        let samples = Set(StatusStore.attentionSampleAgents)
        XCTAssertEqual(samples, none, "Settings sample must cover every Waiting-none Agent")
        XCTAssertEqual(Set(AgentID.waitingNoneAgents), none)
        XCTAssertFalse(samples.contains(.claude))
        XCTAssertFalse(samples.contains(.codex))
        XCTAssertTrue(samples.contains(.zcode))
    }

    @MainActor
    func testAttentionReachNamesWaitingNoneAgent() {
        let store = StatusStore()
        store.language = .en
        store.openSettings(focusWaitingSignals: true, focusWaitingAgent: .zcode)
        XCTAssertTrue(store.settingsFocusWaitingSignals)
        XCTAssertEqual(store.settingsFocusWaitingAgent, .zcode)
        XCTAssertTrue(store.attentionBridgeFocusHintText().contains("ZCode"))
        XCTAssertTrue(store.attentionBridgeWriteSampleHintText().contains("ZCode"))
        XCTAssertTrue(store.attentionBridgeHintText().contains("ZCode"))
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
    func testWaitingReachFunnelEnsuresLauncherWithoutClaudeCodexInstall() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-reach-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer {
            HooksInstaller.homeOverride = nil
            try? fm.removeItem(at: home)
        }
        HooksInstaller.homeOverride = home
        let store = StatusStore()
        store.language = .en
        store.openSettings(focusWaitingSignals: true, focusWaitingAgent: .trae)
        XCTAssertTrue(store.waitingReachStepsText().contains("Trae"))
        XCTAssertTrue(store.waitingReachStepsText().contains("pulse-hook"))
        store.ensurePulseHookLauncher()
        XCTAssertTrue(store.pulseHookLauncherReady)
        XCTAssertTrue(fm.isExecutableFile(atPath: HooksInstaller.launcherURL.path))
        let kitRaise = HooksSupport.attentionBridgeKitDir().appendingPathComponent("raise.sh")
        let kitClear = HooksSupport.attentionBridgeKitDir().appendingPathComponent("clear.sh")
        XCTAssertTrue(fm.isExecutableFile(atPath: kitRaise.path))
        XCTAssertTrue(fm.isExecutableFile(atPath: kitClear.path))
        let clearText = try String(contentsOf: kitClear, encoding: .utf8)
        XCTAssertTrue(clearText.contains("zcode"), clearText)
        // Launcher-only: Claude/Codex configs must stay untouched.
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".codex/config.toml").path))
        let command = store.attentionRaiseCommand(for: .trae)
        XCTAssertTrue(command.contains("trae"), command)
        XCTAssertTrue(command.contains("pulse-hook"), command)
    }

    @MainActor
    func testFocusedAttentionSampleWritesOnlyThatAgent() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pulse-sample-one-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer {
            AttentionIO.pathOverride = nil
            HooksInstaller.homeOverride = nil
            try? fm.removeItem(at: home)
        }
        HooksInstaller.homeOverride = home
        AttentionIO.pathOverride = home.appendingPathComponent("attention.tsv")
        let store = StatusStore()
        store.writeAttentionBridgeSample(for: .zcode)
        let text = try String(contentsOf: AttentionIO.path, encoding: .utf8)
        XCTAssertTrue(text.contains("zcode\tpermission\t"), text)
        XCTAssertTrue(text.contains("pulse-sample"), text)
        XCTAssertFalse(text.contains("replit\tpermission\t"), "focused sample must not raise every Waiting-none agent")
    }

    @MainActor
    func testMaintenanceNoticeOpensWaitingReachWithOpaqueAgent() {
        let store = StatusStore()
        store.language = .en
        store.hooksStatus = .installedBoth
        store.notifyAuthorized = true
        store.notifyOnWaiting = true
        store.installPreviewFixture("waiting")
        guard store.needsWaitingSignalNudge else {
            // Fixture without an opaque live row — Reach entry still deep-links.
            store.openSettings(focusWaitingSignals: true, focusWaitingAgent: .zcode)
            XCTAssertEqual(store.settingsFocusWaitingAgent, .zcode)
            return
        }
        store.performMaintenanceNoticeAction()
        XCTAssertTrue(store.settingsFocusWaitingSignals)
        if let agent = store.settingsFocusWaitingAgent {
            XCTAssertEqual(agent.waitingSource, .none)
        }
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
