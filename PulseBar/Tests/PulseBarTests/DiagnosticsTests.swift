import Foundation
import SQLite3
import Testing
import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

// Diagnostics: the self-check, Health, reports, version and update check.

/// 19.0 · the self-check's judgement. It may only say what the facts show:
/// installed is not proven, silence is not success, and nothing it copies
/// identifies a person, a project or a session.
@Suite("Self-check")
struct DoctorTests {
    let now: Int64 = 1_800_000_000_000

    func healthy() -> DoctorModel.Facts {
        var f = DoctorModel.Facts()
        f.channel = "preview"
        f.macOS = "26.0.0"
        f.nowMs = now
        for agent in AgentID.allCases {
            f.hooks[agent.rawValue] = .init(present: true, events: Set(agent.spec.hooks.events.map { $0.name }))
            f.lastFire[agent.rawValue] = .init(kind: "turn", tsMs: now - 5 * 60_000)
        }
        f.claudeInstalled = true
        f.claudeAgents = .parsed(sessions: 2, waiting: 1)
        f.codexInstalled = true
        f.codexRollout = .paginated
        f.readCoverage = ["claude": .init(name: "Claude", sessions: 3, withTask: 3, withLastWord: 2)]
        return f
    }

    func verdict(_ facts: DoctorModel.Facts, _ id: String) -> DoctorModel.Verdict? {
        DoctorModel.evaluate(facts, lang: .en).checks.first { $0.id == id }?.verdict
    }

    @Test func aHealthyMacProvesEveryContract() {
        let report = DoctorModel.evaluate(healthy(), lang: .en)
        for check in report.checks where check.id != "codex-hooks" {
            #expect(check.verdict == .works, "\(check.id): \(check.detail)")
        }
        // The file cannot say Codex trusts it; the fired event is the proof.
        #expect(verdict(healthy(), "codex-hooks") == .unproven)
        #expect(verdict(healthy(), "codex-fired") == .works)
        // 24.0: one hook check and one fired check per agent.
        for agent in AgentID.allCases {
            #expect(verdict(healthy(), "\(agent.rawValue)-hooks") != nil, "\(agent.rawValue)")
            #expect(verdict(healthy(), "\(agent.rawValue)-fired") == .works, "\(agent.rawValue)")
        }
    }

    @Test func anAgentThatIsNotInstalledIsNotAFailure() {
        var f = healthy()
        f.claudeInstalled = false
        f.hooks["claude"] = .init()
        f.claudeAgents = .noCLI
        f.codexInstalled = false
        f.hooks["codex"] = .init()
        f.hooks["pi"] = .init()
        #expect(verdict(f, "claude-hooks") == .absent)
        #expect(verdict(f, "claude-agents") == .absent)
        #expect(verdict(f, "codex-hooks") == .absent)
        #expect(verdict(f, "pi-hooks") == .absent)
        #expect(verdict(f, "claude-fired") == nil)
        #expect(verdict(f, "codex-rollout") == nil)
    }

    @Test func aMissingEventIsNamed() throws {
        var f = healthy()
        f.hooks["claude"]?.events.remove("StopFailure")
        let check = try #require(DoctorModel.evaluate(f, lang: .en).checks.first { $0.id == "claude-hooks" })
        #expect(check.verdict == .attention)
        #expect(check.detail.contains("StopFailure"))
        #expect(!check.next.isEmpty)
    }

    @Test func aPresentVendorWithoutPulseAsksForTheInstall() {
        var f = healthy()
        f.hooks["gemini"] = .init(present: true)
        #expect(verdict(f, "gemini-hooks") == .attention)
    }

    @Test func aForbiddenPulseEntryIsFlagged() {
        var f = healthy()
        f.hooks["codex"]?.forbidden = ["PermissionRequest"]
        f.hooks["claude"]?.forbidden = ["PreToolUse"]
        #expect(verdict(f, "codex-hooks") == .attention)
        #expect(verdict(f, "claude-hooks") == .attention)
        #expect(DoctorModel.forbiddenEvents(.codex).contains("PermissionRequest"))
        #expect(!DoctorModel.forbiddenEvents(.claude).contains("PermissionRequest"), "Claude's runs async")
    }

    @Test func anAgentThatNeverReportsAWaitSaysSo() throws {
        let report = DoctorModel.evaluate(healthy(), lang: .en)
        let cursor = try #require(report.checks.first { $0.id == "cursor-hooks" })
        #expect(cursor.detail.contains(L10n.t(.doctorNoWaitNote, .en)))
        let gemini = try #require(report.checks.first { $0.id == "gemini-hooks" })
        #expect(!gemini.detail.contains(L10n.t(.doctorNoWaitNote, .en)))
    }

    @Test func silenceIsNotSuccess() {
        var f = healthy()
        f.lastFire = [:]
        #expect(verdict(f, "claude-fired") == .unproven)
        #expect(verdict(f, "codex-fired") == .unproven)
        f.lastFire = ["claude": .init(kind: "turn", tsMs: now - DoctorModel.staleFireMs - 1)]
        #expect(verdict(f, "claude-fired") == .unproven, "a hook that fired last month proves little about today")
    }

    @Test(arguments: [
        (DoctorModel.AgentsAnswer.parsed(sessions: 0, waiting: 0), DoctorModel.Verdict.works),
        (.failed(exitStatus: 1, timedOut: false), .attention),
        (.failed(exitStatus: 0, timedOut: true), .attention),
        (.unreadable(bytes: 40), .attention),
        (.noCLI, .attention),
    ])
    func claudeAgentsAnswers(answer: DoctorModel.AgentsAnswer, expected: DoctorModel.Verdict) {
        var f = healthy()
        f.claudeAgents = answer
        #expect(verdict(f, "claude-agents") == expected)
    }

    // MARK: - 20.0 · reading less

    @Test func aFormatThatReadsNothingIsFlaggedByName() throws {
        var f = healthy()
        f.readCoverage["gemini"] = .init(name: "Gemini", sessions: 4, withTask: 4, withLastWord: 0)
        let check = try #require(DoctorModel.evaluate(f, lang: .en).checks.first { $0.id == "reading" })
        #expect(check.verdict == .attention)
        #expect(check.detail.contains("Gemini"))
        #expect(!check.detail.contains("Claude"))
    }

    @Test func aFormatWithoutWordsIsNotAskedForThem() {
        var f = healthy()
        f.readCoverage["cursor"] = .init(name: "Cursor", sessions: 5, withTask: 5, withLastWord: 0, expectsLastWord: false)
        #expect(verdict(f, "reading") == .works)
    }

    @Test func oneSessionProvesNothingEitherWay() {
        var f = healthy()
        f.readCoverage["copilot"] = .init(name: "Copilot", sessions: 1, withTask: 0, withLastWord: 0)
        #expect(verdict(f, "reading") == .works)
        f.readCoverage = [:]
        #expect(verdict(f, "reading") == .absent)
    }

    @Test func fewerThanHalfIsUnproven() {
        var f = healthy()
        f.readCoverage["pi"] = .init(name: "Pi", sessions: 6, withTask: 6, withLastWord: 2)
        #expect(verdict(f, "reading") == .unproven)
    }

    @Test(arguments: [
        ("", DoctorModel.RolloutShape.none),
        (#"{"type":"event_msg","payload":{"type":"user_message","message":"x"}}"#, .legacy),
        (#"{"type":"event_msg","payload":{"type":"item_completed","item":{}}}"#, .paginated),
        (#"{"type":"event_msg","payload":{"type":"agent_message"}}"# + "\n" + #"{"type":"event_msg","payload":{"type":"item_completed"}}"#, .mixed),
        (#"{"type":"something_else"}"#, .unknown),
    ])
    func rolloutShapes(text: String, expected: DoctorModel.RolloutShape) {
        #expect(DoctorProbe.rolloutShape(text) == expected)
    }

    @Test func onlyPulseEntriesCount() throws {
        let json = #"""
        {"hooks":{
          "Stop":[{"hooks":[{"type":"command","command":"/Users/me/Library/Application Support/Pulse/pulse-hook claude stop"}]}],
          "PreToolUse":[{"hooks":[{"type":"command","command":"mytool --hook-dir x"}]}],
          "Notification":[{"matcher":"permission_prompt|elicitation_dialog","hooks":[{"type":"command","command":"pulse-hook claude"}]}]
        }}
        """#
        let table = try #require(DoctorProbe.hookTable(Data(json.utf8)))
        let found = DoctorProbe.pulseEvents(table)
        #expect(found.events == ["Stop", "Notification"])
        #expect(found.notificationMatcher == "permission_prompt|elicitation_dialog")
        #expect(DoctorProbe.hookTable(Data("not json".utf8)) == nil)
    }

    @Test(arguments: [ResolvedLanguage.en, .zh])
    func theCopiedReportCarriesNoHomePath(lang: ResolvedLanguage) {
        var report = DoctorModel.evaluate(healthy(), lang: lang)
        report.checks[0].detail += " /Users/alice/code/secret-project"
        let text = DoctorModel.text(report)
        #expect(!text.contains("alice"))
        #expect(!text.contains("/Users/"))
        #expect(text.hasPrefix("Pulse "))
    }
}

final class SupportHealthTests: XCTestCase {
    private func health(
        agent: AgentID = .gemini,
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

        // 24.0: every supported agent reads a structured session; one whose
        // hooks never report a wait says so beside its depth.
        let none = health(agent: .codex)
        XCTAssertEqual(AgentID.codex.waitingSource, .none)
        XCTAssertEqual(
            store.supportDepthDetail(none),
            "\(store.tr(.supportDepthWaitingNone)) · \(store.tr(.supportDepthSession))"
        )
    }

    func testAgentWithoutWaitingContractIsNotPermanentlyIncomplete() {
        let item = health(agent: .codex, progress: true, waitingReady: false)
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
        let item = health(agent: .gemini, progress: true, waitingReady: false)
        XCTAssertEqual(item.disposition, .needsAction)
        XCTAssertEqual(item.repair, .installHooks)
    }

    @MainActor
    func testNotificationSetupOutranksTheHooksOffer() {
        let store = StatusStore()
        store.installPreviewFixture("waiting")

        XCTAssertTrue(store.needsHooksNudge)
        // Without notification authorization a "needs you" cannot reach a
        // closed tray; that outranks the (optional) hooks offer.
        XCTAssertEqual(store.trayNotice?.kind, .notificationsOff)
        XCTAssertEqual(store.trayNotice?.action, .enableNotifications)
        XCTAssertFalse(store.tr(.emptyHint).localizedCaseInsensitiveContains("install hooks"))
    }

    @MainActor
    func testLiveClaudeWithoutHooksIsOfferedTheInstall() {
        let store = StatusStore()
        store.installPreviewFixture("waiting")
        store.notifyAuthorized = true

        XCTAssertTrue(store.needsHooksNudge)
        XCTAssertEqual(store.trayNotice?.text, store.tr(.hooksNudge),
                       "21.0: the tray offers the one-click Claude/Codex install")
        XCTAssertEqual(store.trayNotice?.action, .installHooks)
    }

    /// 23.0: an agent with no Waiting path is not a tray notice any more —
    /// its row menu offers the connection instead.
    @MainActor
    func testAnOpaqueLiveAgentIsNotATrayNotice() {
        let store = StatusStore()
        store.installPreviewFixture("waiting")
        store.hooksStatus = .all
        store.notifyAuthorized = true

        XCTAssertFalse(store.needsHooksNudge)
        XCTAssertNil(store.trayNotice)
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

    /// 23.0 bug: every Diagnostics redraw read (and locked) the attention
    /// file for "has this hook fired". The scan reads it once and the
    /// engine keeps the answer.
    @MainActor
    func testHookFireTimesComeFromTheLastScanNotTheFile() {
        let store = StatusStore()
        let fired: Int64 = 1_800_000_000_000
        store.engine.applyScan(
            procs: [], harvest: .skipped, processSignature: "", attention: [], ticket: 1,
            hookEventTimes: [.claude: fired]
        )
        XCTAssertEqual(store.engine.latestHookEventMs[.claude], fired)
        let claude = store.supportHealth.first { $0.agent == .claude }
        XCTAssertEqual(claude?.lastWaitingSignalMs, fired)
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
        XCTAssertTrue(observed.contains("Client"), observed)
        XCTAssertFalse(observed.localizedCaseInsensitiveContains("events"), observed)
    }

    @MainActor
    func testProcessSupportTimelineIncludesProcessAge() {
        let store = StatusStore()
        var item = health(
            agent: .codex,
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
        XCTAssertTrue(store.snapshot.rows[0].isBlocked)
        XCTAssertEqual(store.snapshot.rows[0].wait?.signal, .hooks)

        store.installPreviewFixture("status-running")
        XCTAssertEqual(store.snapshot.glance, .running)
        XCTAssertEqual(store.snapshot.rows.count, 1)
        XCTAssertFalse(store.snapshot.rows[0].isBlocked)
        XCTAssertEqual(store.snapshot.rows[0].planSteps.count, 2)

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
        store.settings.language = .en
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
        store.settings.language = .en
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
        store.settings.language = .en
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
        XCTAssertTrue(report.contains("waitingNone: codex,cursor"))
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
            agent: .codex,
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
        let none = Set(AgentID.allCases.filter { $0.waitingSource == .none })
        let listed = Set(AgentID.waitingNoneAgents)
        XCTAssertEqual(listed, none)
        XCTAssertFalse(listed.contains(.claude))
        XCTAssertEqual(listed, [.codex, .cursor])
    }

    @MainActor
    func testWaitingSignalsAreOneDeepLinkAway() {
        let store = StatusStore()
        store.settings.language = .en
        store.openSettings(focus: .waitingSignals)
        XCTAssertEqual(store.settingsFocus.target, .waitingSignals)
    }

    // MARK: collector explain on screen (M-4)

    @MainActor
    func testReadingLineNamesWhatTheAdapterActuallyRead() {
        let store = StatusStore()
        store.settings.language = .en
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
        store.settings.language = .en
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
        store.settings.language = .en
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
        store.settings.language = .en
        // A reason added by a future adapter must be visible the day it ships.
        // Falling back to "" would hide it until somebody noticed the blank.
        XCTAssertEqual(store.collectorEmptyReasonLabel("some_future_reason"), "some_future_reason")
        XCTAssertEqual(store.collectorOriginLabel("some_future_origin"), "some_future_origin")
    }

    @MainActor
    func testNothingReadPrintsNothingRatherThanZeros() {
        let store = StatusStore()
        store.settings.language = .en
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
        store.settings.language = .en
        let en = store.supportCollectorOutcomeDetail(item)
        store.settings.language = .zh
        let zh = store.supportCollectorOutcomeDetail(item)
        XCTAssertFalse(en.isEmpty)
        XCTAssertNotEqual(en, zh, "the diagnostics disclosure is user-facing copy, not a log line")
    }
}

/// The 0.5.0-vs-0.21.0 drift that shipped for months was invisible because
/// nothing ever compared the two.
final class PulseVersionTests: XCTestCase {
    func testSemverIsWellFormed() {
        let parts = PulseVersion.semver.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "semver must be MAJOR.MINOR.PATCH")
        for part in parts {
            XCTAssertNotNil(Int(part), "non-numeric component in \(PulseVersion.semver)")
        }
    }

    func testUnpackagedBuildReportsDevNotAFakeRelease() {
        // Tests run without an app bundle, so this exercises the honest path.
        guard PulseVersion.bundleVersion == nil else { return }
        XCTAssertTrue(PulseVersion.short.hasSuffix("-dev"))
        XCTAssertEqual(PulseVersion.commit, "dev")
        XCTAssertTrue(PulseVersion.buildLine.isEmpty)
        XCTAssertEqual(PulseVersion.fingerprint, "Pulse \(PulseVersion.short)")
    }

    func testUpdateComparisonIsNumericNotLexicographic() {
        // "0.9.0" > "0.21.0" as strings — the exact bug this guards.
        XCTAssertTrue(UpdateCheck.isNewer("0.21.0", than: "0.9.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.9.0", than: "0.21.0"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0.0", than: "0.99.99"))
        XCTAssertFalse(UpdateCheck.isNewer("0.21.1", than: "0.21.1"))
        XCTAssertTrue(UpdateCheck.isNewer("0.21.2", than: "0.21.1"))
    }

    func testUpdateTagNormalization() {
        XCTAssertEqual(UpdateCheck.normalize("v0.22.0"), "0.22.0")
        XCTAssertEqual(UpdateCheck.normalize(" 0.22.0 "), "0.22.0")
        XCTAssertEqual(UpdateCheck.normalize("V1.0.0"), "1.0.0")
    }

    func testPreReleaseSuffixDoesNotBeatRelease() {
        XCTAssertFalse(UpdateCheck.isNewer("0.21.1-beta.1", than: "0.21.1"))
    }

    func testInterpretRejectsGarbage() {
        let status = UpdateCheck.interpret(data: Data("not json".utf8), response: nil, error: nil)
        XCTAssertEqual(status, .failed(.badResponse))
    }

    func testInterpretFindsNewerRelease() {
        let json = """
        {
          "tag_name":"v99.0.0",
          "html_url":"https://example.com/r"
        }
        """
        let status = UpdateCheck.interpret(data: Data(json.utf8), response: nil, error: nil)
        XCTAssertEqual(
            status,
            .available(.init(version: "99.0.0", pageURL: "https://example.com/r"))
        )
    }

    func testInterpretReleasesListSkipsPrereleaseOnStableChannel() {
        let sha = String(repeating: "b", count: 64)
        let json = """
        [
          {
            "tag_name":"v99.1.0",
            "prerelease":true,
            "html_url":"https://example.com/pre",
            "body":"SHA-256: \(sha)",
            "assets":[{
              "name":"pulse-99.1.0.dmg",
              "browser_download_url":"https://example.com/pre.dmg",
              "size":100
            }]
          },
          {
            "tag_name":"v99.0.0",
            "prerelease":false,
            "html_url":"https://example.com/r",
            "body":"SHA-256: \(sha)",
            "assets":[{
              "name":"pulse-99.0.0.dmg",
              "browser_download_url":"https://example.com/pulse.dmg",
              "size":200
            }]
          }
        ]
        """
        let stable = UpdateCheck.interpret(
            data: Data(json.utf8),
            response: nil,
            error: nil,
            preferPrerelease: false
        )
        if case let .available(info) = stable {
            XCTAssertEqual(info.version, "99.0.0")
        } else {
            XCTFail("stable channel should pick the non-prerelease entry, got \(stable)")
        }

        let preview = UpdateCheck.interpret(
            data: Data(json.utf8),
            response: nil,
            error: nil,
            preferPrerelease: true
        )
        if case let .available(info) = preview {
            XCTAssertEqual(info.version, "99.1.0")
        } else {
            XCTFail("preview channel should accept the newest prerelease, got \(preview)")
        }
    }

    func testUnpackagedChannelDoesNotPreferPrerelease() {
        guard PulseVersion.bundleVersion == nil else { return }
        XCTAssertEqual(PulseVersion.distributionChannel, "dev")
        XCTAssertFalse(PulseVersion.prefersPrereleaseUpdates)
        XCTAssertFalse(PulseVersion.isNotarized)
        XCTAssertFalse(PulseVersion.isGatekeeperReady)
    }

    @MainActor
    func testUpdateCurrentCopyIsChannelRelative() {
        let store = StatusStore()
        store.settings.language = .en
        store.updateStatus = .current
        // Copy follows the running build's channel — not a fixed string.
        // XCTest on CI often sees Bundle.main version keys, so channel may be
        // preview rather than unpackaged dev; assert the mapping, not the host.
        let expected: L10n.Key
        if PulseVersion.prefersPrereleaseUpdates {
            expected = .updateCurrentPrerelease
        } else if PulseVersion.distributionChannel == "stable" {
            expected = .updateCurrentStable
        } else {
            expected = .updateCurrent
        }
        XCTAssertEqual(store.updateStatusText, store.tr(expected))
        XCTAssertNotEqual(store.tr(.updateCurrentPrerelease), store.tr(.updateCurrentStable))
        XCTAssertNotEqual(store.tr(.updateCurrent), store.tr(.updateCurrentPrerelease))
        XCTAssertTrue(store.tr(.updateCurrentStable).localizedCaseInsensitiveContains("prerelease"))
    }

    func testHookStatusIsPerAgentNotGlobal() {
        XCTAssertTrue(HooksSupport.Status.all.isInstalled(for: .claude))
        XCTAssertTrue(HooksSupport.Status.all.isInstalled(for: .pi))
        XCTAssertTrue(HooksSupport.Status.installed([.claude]).isInstalled(for: .claude))
        XCTAssertFalse(HooksSupport.Status.installed([.claude]).isInstalled(for: .codex))
        XCTAssertFalse(HooksSupport.Status.missing.isInstalled(for: .claude))
        XCTAssertEqual(
            HooksSupport.Status.installed([.claude, .gemini]).label(lang: .en),
            String(format: L10n.t(.hooksInstalledCount, .en), 2, AgentID.allCases.count)
        )
    }
}

/// 22.x · Lamp fixes — each pins one defect with the pure function that
/// decides it.
@Suite("Update status")
struct UpdateStatusTests {

    // MARK: - Background update checks keep a known answer

    private static let release = UpdateCheck.ReleaseInfo(
        version: "99.0.0",
        pageURL: "https://example.invalid/r"
    )

    @Test func aBackgroundFailureKeepsAnAvailableUpdate() {
        let previous = UpdateCheck.Status.available(Self.release)
        let next = UpdateCheck.resolve(previous: previous, result: .failed(.network("offline")), manual: false)
        #expect(next == previous)
    }

    @Test func aBackgroundFailureKeepsUpToDate() {
        let next = UpdateCheck.resolve(previous: .current, result: .failed(.http(503)), manual: false)
        #expect(next == .current)
    }

    @Test func aManualFailureIsShown() {
        let next = UpdateCheck.resolve(previous: .current, result: .failed(.http(503)), manual: true)
        #expect(next == .failed(.http(503)))
    }

    @Test func aBackgroundAnswerStillReplacesTheStatus() {
        let next = UpdateCheck.resolve(previous: .current, result: .available(Self.release), manual: false)
        #expect(next == .available(Self.release))
    }

    // MARK: - The health line reads the last scan, not the last publish

    @Test func lastReadPrefersTheNewerScan() {
        let published = Date(timeIntervalSince1970: 1_000)
        let scanned = Date(timeIntervalSince1970: 1_050)
        #expect(StatusStore.lastReadDate(lastScanAt: scanned, snapshotUpdatedAt: published) == scanned)
        #expect(StatusStore.lastReadDate(lastScanAt: nil, snapshotUpdatedAt: published) == published)
        #expect(StatusStore.lastReadDate(lastScanAt: nil, snapshotUpdatedAt: .distantPast) == nil)
        #expect(StatusStore.lastReadDate(lastScanAt: scanned, snapshotUpdatedAt: .distantPast) == scanned)
    }
}

/// 23.0 · the tray as values: the keyboard reducer, the frozen order, the
/// header and its freshness, the one notice, the row's second line, where a
/// banner click goes, and the Settings page's sections.
@Suite("Diagnostics model")
struct DiagnosticsModelTests {
    // MARK: - Diagnostics

    @Test func diagnosticsPutsProblemsFirstAndSortsAgentsByNeed() {
        let model = SurfaceFixtures.diagnostics(lang: .en)
        let first = model.problems.first?.id
        #expect(first == "scan", "standing problems come before the self-check's findings")
        let order = model.agents.map { $0.agent }
        #expect(order.first == .codex, "what needs action sorts first")
        #expect(order.last == .pi, "not installed sorts last")
    }
}

/// Clarity fixes — each test pins one defect found by reading the code: the
/// value the user would have seen, before and after.
@MainActor
@Suite("Update check", .serialized)
struct UpdateCheckTests {
    let now: Int64 = 1_800_000_000_000
    // MARK: - 10 / 21 · update checks

    @Test func aFailedUpdateCheckRetriesWithinTheHourAndSuccessWaitsADay() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UpdateCheck.isDue(now: t0, lastSuccess: nil, lastAttempt: nil))
        #expect(!UpdateCheck.isDue(now: t0.addingTimeInterval(30 * 60), lastSuccess: nil, lastAttempt: t0))
        #expect(UpdateCheck.isDue(now: t0.addingTimeInterval(61 * 60), lastSuccess: nil, lastAttempt: t0),
                "one offline launch used to silence the check for a day")
        #expect(!UpdateCheck.isDue(now: t0.addingTimeInterval(23 * 3600), lastSuccess: t0, lastAttempt: t0))
        #expect(UpdateCheck.isDue(now: t0.addingTimeInterval(25 * 3600), lastSuccess: t0, lastAttempt: t0))
    }

    @Test func updateFailuresAreTypedForTheSurface() throws {
        let url = try #require(URL(string: "https://example.com/feed"))
        let busy = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)
        #expect(UpdateCheck.interpret(data: Data(), response: busy, error: nil) == .failed(.http(503)))
        #expect(UpdateCheck.interpret(data: Data(#"{"tag_name":""}"#.utf8), response: nil, error: nil) == .failed(.noTag))
        #expect(UpdateCheck.Failure.http(503).detail == "HTTP 503")
    }
}

/// 0.99.2 Live Wire — the rest of the path 0.99.1 只修了一半.
///
/// 0.99.1 fixed how `lsof` output is parsed. These cover what happens to that
/// output afterwards: the gate that decided whether to keep it at all, the
/// subprocess wrapper underneath, and the code downstream that had never once
/// run with a working directory in hand.
final class SupportReportTests: XCTestCase {
    // MARK: - The login item says whether it worked

    @MainActor
    func testTheSupportReportRecordsWhetherLaunchAtLoginWasApplied() {
        let store = StatusStore()
        let report = store.safeSupportReport()
        XCTAssertTrue(
            report.contains("launchAtLogin:"),
            "a toggle whose result is never checked is how this project keeps shipping bugs"
        )
        XCTAssertTrue(report.contains("applied="), report)
    }
}

/// 2.9 Quality — second-grade freshness, and the measurement measuring itself.
///
/// The hook has stood in the vendor's event stream since 1.0, but only for
/// waits. These tests hold the new deal for activity events: state not
/// ledger, never a wait, present tense only inside the live window — and the
/// yield rules that stop "the agent is idle" and "Pulse stopped seeing" from
/// wearing the same clothes.
final class FactClassTests: XCTestCase {
    // MARK: - Yield: the measurement measuring itself

    func testFactClassesNameWhatActuallyCameOut() {
        var row = ActivityHarvest.Row(id: .claude, task: "t", project: "", cwd: "/w", skill: "")
        row.tool = "Edit"
        row.tokensIn = 100
        row.planStep = "Running the gates"
        let classes = ActivityHarvest.factClasses(of: [row])
        XCTAssertTrue(classes.isSuperset(of: ["task", "tool", "tokens", "plan", "workspace"]))
        XCTAssertFalse(classes.contains("word"))
        XCTAssertTrue(ActivityHarvest.factClasses(of: []).isEmpty)
    }

    func testDriftIsStructuredRowsWithZeroCoreFacts() {
        var health = ActivityHarvest.CollectorHealth(
            id: .claude, state: .observed, durationMs: 1, rowCount: 2,
            sourcePresent: true, errorKind: ""
        )
        XCTAssertTrue(health.looksDrifted, "rows with no core facts from a structured adapter is drift")
        health.factClasses = ["task"]
        XCTAssertFalse(health.looksDrifted)
        health.factClasses = []
        health.state = .noSessions
        XCTAssertFalse(health.looksDrifted, "no rows is idleness, not drift")
    }

    @MainActor
    func testTheSupportLineSaysDriftOutLoudAndYieldQuietly() {
        let store = StatusStore()
        store.settings.language = .en
        var item = AgentSupportHealth(
            agent: .claude, collectorState: .observed, collectorDurationMs: 1,
            collectorRows: 1, sourcePresent: true, collectorErrorKind: "",
            processDetected: false, processEvidence: nil, evidence: .session,
            lastSuccessfulReadMs: 0, lastWaitingSignalMs: 0,
            hasGoal: true, hasWorkspace: true, hasActivity: true,
            hasProgress: true, waitingSignalReady: true
        )
        item.factClasses = ["task", "tool", "tokens"]
        let quiet = store.supportYieldDetail(item)
        XCTAssertTrue(quiet.contains("task"), quiet)
        item.looksDrifted = true
        XCTAssertTrue(store.supportYieldDetail(item).contains("drift"),
                      store.supportYieldDetail(item))
    }
}
