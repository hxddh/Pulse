import Foundation
import Testing
import XCTest
@testable import PulseApp
@testable import PulseQA
@testable import PulseCore
@testable import PulseHarvest

// Diagnostics: Settings → Hooks (one line per agent, "Copy report"), the
// tray's one notice, the version and the update check.

/// The report "Copy report" puts on the clipboard: plain text, the facts a
/// person would be asked for, and nothing that names them, a project or a
/// session.
@Suite("Report")
struct ReportTests {
    let now: Int64 = 1_800_000_000_000

    func input() -> SettingsModel.ReportInput {
        SettingsModel.ReportInput(
            version: "Pulse 25.0.0 · preview",
            macOS: "26.0.0",
            installed: [.claude, .gemini],
            present: [.claude, .codex, .gemini],
            failed: [.copilot: .unwritable],
            lastEventMs: [.claude: now - 42_000],
            nowMs: now,
            notifyAuthorized: false,
            notifyOnWaiting: true,
            terminalAutomation: true,
            launchAtLogin: true,
            loginItemApplied: false
        )
    }

    @Test func theReportSaysEachAgentsHookAndItsLastEvent() {
        let text = SettingsModel.report(input())
        #expect(text.hasPrefix("Pulse report"))
        #expect(text.contains("Pulse 25.0.0 · preview"))
        #expect(text.contains("  claude: installed, last event 42s ago"), "\(text)")
        #expect(text.contains("  gemini: installed, no event yet"), "\(text)")
        #expect(text.contains("  codex: not installed"), "\(text)")
        #expect(text.contains("  copilot: install failed (unwritable)"), "\(text)")
        #expect(text.contains("  pi: not on this Mac"), "\(text)")
        for agent in AgentID.allCases {
            #expect(text.contains("  \(agent.rawValue): "), "\(agent.rawValue)")
        }
    }

    @Test func theReportSaysNotificationsAutomationAndTheLoginItem() {
        let text = SettingsModel.report(input())
        #expect(text.contains("notifications: denied, needs-you banners on"), "\(text)")
        #expect(text.contains("terminal automation: allowed"), "\(text)")
        #expect(text.contains("launch at login: on, applied: no"),
                "a toggle whose result is never checked is how this project keeps shipping bugs")
        var unasked = input()
        unasked.notifyAuthorized = nil
        unasked.terminalAutomation = false
        unasked.loginItemApplied = nil
        let other = SettingsModel.report(unasked)
        #expect(other.contains("notifications: not asked"))
        #expect(other.contains("terminal automation: off"))
        #expect(other.contains("applied: untouched"))
    }

    /// The shortcut and the automation offer are in the report.
    @Test func theReportSaysTheShortcutAndTheAutomationOffer() {
        var chosen = input()
        chosen.hotkey = .controlOptionSpace
        chosen.hotkeyRegistered = false
        chosen.automationOfferAnswered = true
        let text = SettingsModel.report(chosen)
        #expect(text.contains("shortcut: ctrl_opt_space, registered: no — taken"), "\(text)")
        #expect(text.contains("terminal automation: allowed, offer answered"), "\(text)")
        let off = SettingsModel.report(input())
        #expect(off.contains("shortcut: off\n"), "\(off)")
        #expect(off.contains("offer not answered"), "\(off)")
    }

    /// The input has no field for a path, a prompt, a session or a
    /// project; the text says only states, counts and ages.
    @Test func theReportCarriesNoPathSessionOrProject() {
        let text = SettingsModel.report(input())
        #expect(!text.contains("/"), "not even a folder: \(text)")
    }

    /// The store's report reads the engine's last events, never the file.
    @MainActor
    @Test func theStoresReportReadsTheEngine() {
        let store = StatusStore()
        let fired: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let line = AttentionRecord(agent: "claude", kind: "turn", ms: fired, session: "s1").line
        store.engine.landLog(EventLog.Chunk(header: "# g", lines: [line], end: 200, fresh: true))
        #expect(store.engine.latestHookEventMs[.claude] == fired)
        let report = store.reportText
        #expect(report.contains("  claude: "))
        #expect(report.contains("launch at login: "))
    }
}

/// The hooks section is where an agent's missing hook is fixed, one deep
/// link away from the tray.
@Suite("Hooks section")
struct HooksSectionTests {
    /// No setting makes Codex or Cursor report a wait, so their line offers
    /// no "connect" action — it says what they do not report.
    @Test func aWaitingNoneAgentSaysWhatItDoesNotReport() {
        #expect(L10n.t(.settingsHookNoWait, .en) == "Doesn't report when it waits — running and your turn only")
        #expect(L10n.t(.settingsHookNoWait, .zh).hasPrefix("不会报告它在等你"))
        for lang in [ResolvedLanguage.en, .zh] {
            let copy = L10n.t(.settingsHookNoWait, lang)
            #expect(!copy.localizedCaseInsensitiveContains("bridge"))
            #expect(!copy.contains("桥"))
        }
        let lines = SettingsModel.hookAgents(
            installed: Set(AgentID.allCases), present: Set(AgentID.allCases),
            lastEventMs: [:], nowMs: 0, lang: .en
        )
        for line in lines {
            #expect(line.needsFix == false, "\(line.agent.rawValue)")
            #expect((line.note != nil) == AgentID.waitingNoneAgents.contains(line.agent), "\(line.agent.rawValue)")
        }
    }

    @Test func waitingNoneAgentsCoverEveryWaitingNoneContract() {
        let none = Set(AgentID.allCases.filter { $0.waitingSource == .none })
        let listed = Set(AgentID.waitingNoneAgents)
        #expect(listed == none)
        #expect(!listed.contains(.claude))
        #expect(listed == [.codex, .cursor])
    }

    @MainActor
    @Test func waitingSignalsAreOneDeepLinkAway() {
        let store = StatusStore()
        store.settings.language = .en
        store.openSettings(focus: .waitingSignals)
        #expect(store.settingsFocus.target == .waitingSignals)
        #expect(store.settingsModel.focus == .hooks)
    }
}

/// The tray's one notice, and the fixtures the tray captures are made of.
final class TrayNoticeTests: XCTestCase {
    /// The setup card comes first — without a hook there is nothing
    /// to notify. It names the agents on this Mac unconnected.
    @MainActor
    func testTheSetupCardOutranksNotificationSetup() {
        let store = StatusStore()
        store.installPreviewFixture("waiting")
        store.presentAgents = [.claude, .codex]

        XCTAssertFalse(store.setupAgents.isEmpty)
        XCTAssertEqual(store.trayNotice?.kind, .setup)
        XCTAssertEqual(store.trayNotice?.action, .connect)
        XCTAssertFalse(store.tr(.emptyHint).localizedCaseInsensitiveContains("install hooks"))
        XCTAssertFalse(store.tr(.emptyHint).contains("45"), "the empty state says what is true now")
    }

    /// An agent on this Mac with nothing running is offered too — the empty
    /// tray's first run.
    @MainActor
    func testAnAgentOnThisMacWithNothingRunningIsOfferedTheSetup() {
        let store = StatusStore()
        store.notifyAuthorized = true
        store.presentAgents = [.codex, .claude]
        XCTAssertEqual(store.setupAgents, [.claude, .codex], "roster order")
        XCTAssertEqual(store.trayNotice?.text, String(format: store.tr(.setupFound), "Claude, Codex"))
        store.hooksStatus = .installed([.claude, .codex])
        XCTAssertNil(store.trayNotice, "connected: nothing to set up")
    }

    /// A live agent process whose vendor folder is not on this Mac is not
    /// offered: "Connect" installs only where the folder is, so offering it
    /// would ask again after every click.
    @MainActor
    func testOnlyAgentsWhoseFolderIsHereAreOffered() {
        let store = StatusStore()
        store.installPreviewFixture("waiting")
        store.notifyAuthorized = true
        store.presentAgents = []
        XCTAssertTrue(store.cachedAll.contains { $0.liveProcess })
        XCTAssertTrue(store.setupAgents.isEmpty, "running is not being on this Mac")
        store.presentAgents = [.gemini]
        XCTAssertEqual(store.setupAgents, [.gemini])
    }

    /// An agent whose install failed is never offered "Connect" again —
    /// it would fail the same way, card after card. The card says why,
    /// in the failure's own words, and opens Settings.
    @MainActor
    func testAFailedInstallIsSaidNotOfferedAgain() {
        let store = StatusStore()
        store.notifyAuthorized = true
        store.presentAgents = [.claude, .codex, .gemini]
        store.hooksStatus = .installed([.claude], failed: [.gemini: .invalidJSON])
        XCTAssertEqual(store.setupAgents, [.codex], "Gemini failed: not offered again")
        XCTAssertEqual(store.trayNotice?.kind, .setup)
        store.hooksStatus = .installed([.claude, .codex], failed: [.gemini: .invalidJSON])
        XCTAssertTrue(store.setupAgents.isEmpty)
        let card = store.trayNotice
        XCTAssertEqual(card?.kind, .setupFailed)
        XCTAssertEqual(card?.action, .openHooksSettings)
        XCTAssertEqual(card?.text, HooksSupport.Status.failureText([.gemini: .invalidJSON], lang: store.lang))
        store.settings.hooksNudgeOff = true
        XCTAssertNil(store.trayNotice, "hooks removed on purpose: nothing to say")
    }

    /// After "Connect" the card shows what is left, until "Got it".
    @MainActor
    func testTheCardShowsTheRemainingStepsUntilDismissed() {
        let store = StatusStore()
        store.notifyAuthorized = true
        store.hooksStatus = .installed([.claude, .codex])
        store.setupConnected = [.codex, .claude]
        let card = store.trayNotice
        XCTAssertEqual(card?.kind, .setupDone)
        XCTAssertEqual(card?.steps, [store.tr(.setupStepCodex), store.tr(.setupStepRestart)])
        store.performTrayNotice(.dismissSetup)
        XCTAssertNil(store.setupConnected)
        XCTAssertNil(store.trayNotice)
    }

    /// An agent with no Waiting path is not a tray notice, and nothing
    /// offers it a connection it cannot have.
    @MainActor
    func testAnOpaqueLiveAgentIsNotATrayNotice() {
        let store = StatusStore()
        store.installPreviewFixture("waiting")
        store.hooksStatus = .all
        store.notifyAuthorized = true

        XCTAssertTrue(store.setupAgents.isEmpty)
        XCTAssertNil(store.trayNotice)
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
}

/// A version drift once shipped for months, invisible because nothing ever
/// compared the two.
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
        XCTAssertTrue(store.tr(.updateCurrentStable).localizedCaseInsensitiveContains("stable"))
        // A preview build is ad-hoc signed, not "unsigned".
        XCTAssertTrue(store.tr(.updateCurrentPrerelease).contains("ad-hoc"))
        XCTAssertFalse(store.tr(.updateCurrentPrerelease).localizedCaseInsensitiveContains("unsigned"))
        XCTAssertFalse(L10n.t(.updateCurrentPrerelease, .zh).contains("未签名"))
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

/// A background check never replaces a known answer with a failure.
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
}

/// When the update check runs, and what its failures say.
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
