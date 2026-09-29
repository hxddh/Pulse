import Foundation
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
        f.hooks["claude"] = .init()
        f.hooks["codex"] = .init()
        f.hooks["pi"] = .init()
        #expect(verdict(f, "claude-hooks") == .absent)
        #expect(verdict(f, "codex-hooks") == .absent)
        #expect(verdict(f, "pi-hooks") == .absent)
        #expect(verdict(f, "claude-fired") == nil)
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

    /// 24.0: the self-check checks the hooks and nothing else — no vendor
    /// CLI is run, no session store is walked.
    @Test func theSelfCheckIsTheHooks() {
        let ids = DoctorModel.evaluate(healthy(), lang: .en).checks.map(\.id)
        #expect(ids.count == AgentID.allCases.count * 2)
        #expect(ids.allSatisfy { $0.hasSuffix("-hooks") || $0.hasSuffix("-fired") })
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

/// 24.0 · Diagnostics per agent: its hook, whether it fired, and what is
/// on the list — the only facts left once the collector went.
final class SupportHealthTests: XCTestCase {
    private func health(
        agent: AgentID = .gemini,
        hook: Bool = true,
        present: Bool = true,
        lastEventMs: Int64 = 1_800_000_000_000,
        sessions: Int = 1,
        processOnly: Int = 0
    ) -> AgentSupportHealth {
        AgentSupportHealth(
            agent: agent, hookInstalled: hook, vendorPresent: present,
            lastEventMs: lastEventMs, sessionCount: sessions, processOnlyCount: processOnly
        )
    }

    func testAHookedAgentWithSessionsIsAvailable() {
        XCTAssertEqual(health().disposition, .available)
        XCTAssertNil(DiagnosticsModel.fix(for: health()))
    }

    func testMissingHooksIsActionable() {
        let item = health(hook: false)
        XCTAssertEqual(item.disposition, .needsAction)
        XCTAssertEqual(DiagnosticsModel.fix(for: item), .installHooks)
        XCTAssertEqual(health(hook: false, present: false, sessions: 0, processOnly: 1).disposition, .needsAction,
                       "a running agent without its hook needs it even before its directory exists")
        XCTAssertEqual(health(hook: false, present: false, sessions: 0).disposition, .notInstalled)
    }

    func testInstalledIsNotProven() {
        XCTAssertEqual(health(lastEventMs: 0, sessions: 0).disposition, .unproven)
        XCTAssertEqual(health(sessions: 0).disposition, .noRecentSession)
    }

    /// 24.0: no setting makes Codex or Cursor report a wait, so their
    /// line offers no "connect" action — it says what they do not report.
    @MainActor
    func testAWaitingNoneAgentIsOfferedNoImpossibleFix() {
        for agent in AgentID.waitingNoneAgents {
            let item = health(agent: agent, sessions: 1, processOnly: 1)
            XCTAssertNil(DiagnosticsModel.fix(for: item), agent.rawValue)
        }
        XCTAssertEqual(L10n.t(.supportWaitingNoneDetail, .en), "Doesn't report when it waits — running and your turn only")
        XCTAssertTrue(L10n.t(.supportWaitingNoneDetail, .zh).hasPrefix("不会告诉我们它在等你"))
        for lang in [ResolvedLanguage.en, .zh] {
            let copy = L10n.t(.supportWaitingNoneDetail, lang) + L10n.t(.settingsHookNoWait, lang)
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("bridge"))
            XCTAssertFalse(copy.contains("桥"))
        }
    }

    func testWaitingNoneAgentsCoverEveryWaitingNoneContract() {
        let none = Set(AgentID.allCases.filter { $0.waitingSource == .none })
        let listed = Set(AgentID.waitingNoneAgents)
        XCTAssertEqual(listed, none)
        XCTAssertFalse(listed.contains(.claude))
        XCTAssertEqual(listed, [.codex, .cursor])
    }

    @MainActor
    func testTheDetailsSayTheHookTheSessionsAndTheProcesses() {
        let store = StatusStore()
        store.settings.language = .en
        let details = store.supportDetails(health(agent: .claude, sessions: 2, processOnly: 1))
        XCTAssertTrue(details.contains(store.tr(.settingsHookInstalled)), "\(details)")
        XCTAssertTrue(details.contains(String(format: store.tr(.supportSessions), 2)), "\(details)")
        XCTAssertTrue(details.contains(String(format: store.tr(.supportProcessOnly), 1)), "\(details)")
        XCTAssertTrue(details.contains(store.tr(.supportWaitingHooks)))
        XCTAssertTrue(store.supportDetails(health(agent: .codex)).contains(store.tr(.supportWaitingNoneDetail)))
        XCTAssertTrue(store.supportDetails(health(agent: .cursor)).contains(store.tr(.supportSharedCursor)))
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
        XCTAssertEqual(store.trayNotice?.text, store.tr(.hooksNudge))
        XCTAssertEqual(store.trayNotice?.action, .installHooks)
    }

    /// 23.0: an agent with no Waiting path is not a tray notice (24.0: and
    /// nothing offers it a connection it cannot have).
    @MainActor
    func testAnOpaqueLiveAgentIsNotATrayNotice() {
        let store = StatusStore()
        store.installPreviewFixture("waiting")
        store.hooksStatus = .all
        store.notifyAuthorized = true

        XCTAssertFalse(store.needsHooksNudge)
        XCTAssertNil(store.trayNotice)
    }

    /// 23.0 bug: every Diagnostics redraw read (and locked) the attention
    /// file for "has this hook fired". The engine reads it once and keeps
    /// the answer.
    @MainActor
    func testHookFireTimesComeFromTheEngineNotTheFile() {
        let store = StatusStore()
        let fired: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let line = AttentionRecord(agent: "claude", kind: "turn", ms: fired, session: "s1").line
        store.engine.landAttention(AttentionProtocol.header + line + "\n")
        XCTAssertEqual(store.engine.latestHookEventMs[.claude], fired)
        let claude = store.supportHealth.first { $0.agent == .claude }
        XCTAssertEqual(claude?.lastEventMs, fired)
    }

    @MainActor
    func testStatusFixturesInjectConcreteTrayRows() {
        let store = StatusStore()
        store.installPreviewFixture("status-waiting")
        XCTAssertEqual(store.snapshot.glance, .waiting)
        XCTAssertEqual(store.snapshot.rows.count, 1)
        XCTAssertEqual(store.snapshot.totalCount, 1)
        XCTAssertTrue(store.snapshot.rows[0].isBlocked)

        store.installPreviewFixture("status-running")
        XCTAssertEqual(store.snapshot.glance, .running)
        XCTAssertEqual(store.snapshot.rows.count, 1)
        XCTAssertFalse(store.snapshot.rows[0].isBlocked)

        store.installPreviewFixture("status-stalled")
        XCTAssertEqual(store.snapshot.glance, .stalled)
        XCTAssertEqual(store.snapshot.rows.count, 1)
        XCTAssertTrue(store.snapshot.rows[0].isStalled)
    }

    @MainActor
    func testSafeSupportReportCarriesCountsAndStatesOnly() {
        let store = StatusStore()
        let report = store.safeSupportReport()
        XCTAssertTrue(report.contains("channel:"))
        XCTAssertTrue(report.contains("notarized:"))
        XCTAssertTrue(report.contains("gatekeeperReady:"))
        XCTAssertTrue(report.contains("waitingNone: codex,cursor"))
        XCTAssertTrue(report.contains("notifications: authorization="))
        XCTAssertTrue(report.contains("queued="))
        XCTAssertTrue(report.contains("sessionLog: sessions="))
        XCTAssertTrue(report.contains("processScan:"))
        XCTAssertTrue(report.contains("sessions: book="))
        for agent in AgentID.allCases {
            XCTAssertTrue(report.contains("\(agent.rawValue): "), agent.rawValue)
        }
    }

    @MainActor
    func testWaitingSignalsAreOneDeepLinkAway() {
        let store = StatusStore()
        store.settings.language = .en
        store.openSettings(focus: .waitingSignals)
        XCTAssertEqual(store.settingsFocus.target, .waitingSignals)
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
        #expect(first == "hooks", "standing problems come before the self-check's findings")
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

/// The support report says whether a setting took effect.
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
