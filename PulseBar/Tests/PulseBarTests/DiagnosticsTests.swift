import Foundation
import Testing
import XCTest
@testable import PulseApp
@testable import PulseQA
@testable import PulseCore
@testable import PulseHarvest

// Diagnostics: Settings → Hooks (one line per agent, "Copy report"), the
// tray's one notice, the version.

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
            launchAtLogin: true,
            loginItem: .off
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

    @Test func theReportSaysNotificationsAndTheLoginItem() {
        let text = SettingsModel.report(input())
        #expect(text.contains("notifications: denied\n"), "\(text)")
        #expect(text.contains("open at login: on, macOS: not registered"),
                "a toggle whose result is never checked is how this project keeps shipping bugs")
        #expect(!text.contains("shortcut"), "\(text)")
        #expect(!text.contains("automation"), "\(text)")
        var unasked = input()
        unasked.notifyAuthorized = nil
        unasked.loginItem = nil
        let other = SettingsModel.report(unasked)
        #expect(other.contains("notifications: not asked"))
        #expect(other.contains("macOS: not read"))
        var pending = input()
        pending.loginItem = .requiresApproval
        let waiting = SettingsModel.report(pending)
        #expect(waiting.contains("open at login: on, macOS: requires approval"), "\(waiting)")
    }

    /// The input has no field for a path, a prompt, a session or a
    /// project; the text says only states, counts and ages.
    @Test func theReportCarriesNoPathSessionOrProject() {
        var withSession = input()
        var row = AgentRow(rowKey: "claude|secret-session", agent: .claude)
        row.sessionID = "secret-session"
        row.cwd = "/Users/me/secret-project"
        row.project = "secret-project"
        row.task = "a private prompt"
        withSession.sessions = [SettingsModel.ReportSession(row)]
        let text = SettingsModel.report(withSession)
        #expect(!text.contains("/"), "not even a folder: \(text)")
        #expect(!text.contains("secret"), "\(text)")
        #expect(!text.contains("private"), "\(text)")
    }

    /// How Pulse reads each listed session — once on the detail page — is
    /// in the report: its state, where its facts come from, how a click
    /// lands, whether its process is watched and when it last spoke.
    @Test func theReportSaysHowPulseReadsEachSession() {
        var hooked = AgentRow(rowKey: "claude|s1", agent: .claude)
        hooked.state = .running
        hooked.source = .hooks
        hooked.liveProcess = true
        hooked.pid = 42
        hooked.lastEventMs = now - 7_000
        hooked.landingPlan = LandingPlan(steps: [.ttyTab(tty: "ttys003")])
        var process = AgentRow(rowKey: "cursor|p", agent: .cursor)
        process.state = .processOnly
        process.liveProcess = true
        var chosen = input()
        chosen.sessions = [hooked, process].map(SettingsModel.ReportSession.init)
        let text = SettingsModel.report(chosen)
        #expect(text.contains("\nsessions:\n"), "\(text)")
        #expect(text.contains("  claude: running, from hooks, go exact, process watched, last event 7s ago"), "\(text)")
        #expect(text.contains("  cursor: process only, from process only, go none, process watched, no event"), "\(text)")
        #expect(SettingsModel.report(input()).hasSuffix("sessions: none listed"))
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
        #expect(report.contains("open at login: "))
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
        let store = StatusStore(lang: .en)
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

        XCTAssertFalse(store.trayNoticeInput.unconnected.isEmpty)
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
        XCTAssertEqual(store.trayNoticeInput.unconnected, [.claude, .codex], "roster order")
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
        XCTAssertTrue(store.trayNoticeInput.unconnected.isEmpty, "running is not being on this Mac")
        store.presentAgents = [.gemini]
        XCTAssertEqual(store.trayNoticeInput.unconnected, [.gemini])
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
        XCTAssertEqual(store.trayNoticeInput.unconnected, [.codex], "Gemini failed: not offered again")
        XCTAssertEqual(store.trayNotice?.kind, .setup)
        store.hooksStatus = .installed([.claude, .codex], failed: [.gemini: .invalidJSON])
        XCTAssertTrue(store.trayNoticeInput.unconnected.isEmpty)
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

        XCTAssertTrue(store.trayNoticeInput.unconnected.isEmpty)
        XCTAssertNil(store.trayNotice)
    }

    @MainActor
    func testStatusFixturesInjectConcreteTrayRows() {
        let store = StatusStore()
        store.installPreviewFixture("status-waiting")
        XCTAssertEqual(store.snapshot.lamp, .waiting)
        XCTAssertEqual(store.snapshot.rows.count, 1)
        XCTAssertTrue(store.snapshot.rows[0].isBlocked)

        store.installPreviewFixture("status-running")
        XCTAssertEqual(store.snapshot.lamp, .running)
        XCTAssertEqual(store.snapshot.rows.count, 1)
        XCTAssertFalse(store.snapshot.rows[0].isBlocked)

        store.installPreviewFixture("status-stalled")
        XCTAssertEqual(store.snapshot.lamp, .stalled)
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

    func testAnUnpackagedBuildIsNeitherPreviewNorStable() {
        guard PulseVersion.bundleVersion == nil else { return }
        XCTAssertEqual(PulseVersion.distributionChannel, "dev")
        XCTAssertFalse(PulseVersion.isNotarized)
    }

    /// A preview build is said to be ad-hoc signed, never "unsigned".
    func testThePreviewBuildIsSaidAsAdHocSigned() {
        XCTAssertTrue(L10n.t(.buildPreview, .en).contains("ad-hoc"))
        XCTAssertFalse(L10n.t(.buildPreview, .en).localizedCaseInsensitiveContains("unsigned"))
        XCTAssertFalse(L10n.t(.buildPreview, .zh).contains("未签名"))
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
