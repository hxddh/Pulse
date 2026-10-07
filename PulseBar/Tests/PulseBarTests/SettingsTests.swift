import Foundation
import Testing
@testable import PulseApp
@testable import PulseQA
@testable import PulseCore
@testable import PulseHarvest

// Settings: the persisted settings and the Settings page model.

/// Settings are the one file Pulse keeps for the person: a `Codable` value
/// in `settings.json` — whether Pulse opens at login, and whether the
/// person removed the hooks on purpose.
@Suite("Settings")
struct PulseSettingsTests {
    private func roundTrip(_ settings: PulseSettings) throws -> PulseSettings {
        let data = try JSONEncoder().encode(settings)
        return try JSONDecoder().decode(PulseSettings.self, from: data)
    }

    private func decode(_ json: String) throws -> PulseSettings {
        try JSONDecoder().decode(PulseSettings.self, from: Data(json.utf8))
    }

    /// A fresh home directory with the Application Support folder in it.
    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: PulseSettings.directory(home: home), withIntermediateDirectories: true
        )
        return home
    }

    // MARK: Round trip

    @Test func jsonRoundTripPreservesEverything() throws {
        var original = PulseSettings()
        original.launchAtLogin = true
        original.hooksNudgeOff = true
        let reparsed = try roundTrip(original)
        #expect(reparsed == original)
    }

    @Test func defaultsAreTheQuietOnes() throws {
        let d = PulseSettings()
        #expect(!d.launchAtLogin)
        #expect(!d.hooksNudgeOff)
        let reparsed = try roundTrip(d)
        #expect(reparsed == d)
    }

    /// Only the two keys are written: nothing else is a setting.
    @Test func onlyTheCurrentKeysAreWritten() throws {
        let data = try JSONEncoder().encode(PulseSettings())
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let keys = Set(object?.keys.map { $0 } ?? [])
        #expect(keys == ["launchAtLogin", "hooksNudgeOff"])
    }

    // MARK: Tolerance

    @Test func anEmptyObjectYieldsDefaults() throws {
        let decoded = try decode("{}")
        #expect(decoded == PulseSettings())
    }

    /// A key Pulse does not know is ignored, never read into a setting.
    @Test func unknownKeysAreIgnored() throws {
        let decoded = try decode(#"{"someFutureKey": 42, "language": "zh", "hooksNudgeOff": true}"#)
        #expect(decoded.hooksNudgeOff)
        #expect(!decoded.launchAtLogin)
    }

    @Test func aWrongTypeCostsOnlyThatField() throws {
        let decoded = try decode(#"{"launchAtLogin": "yes", "hooksNudgeOff": true}"#)
        #expect(!decoded.launchAtLogin)
        #expect(decoded.hooksNudgeOff)
    }

    // MARK: On disk

    @Test func saveThenLoadRoundTrips() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        var settings = PulseSettings()
        settings.launchAtLogin = true
        let saved = settings.save(home: home)
        #expect(saved)
        let loaded = PulseSettings.load(home: home)
        #expect(loaded == settings)
    }

    @Test func theFileIsPrivate() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        PulseSettings().save(home: home)
        let attributes = try FileManager.default.attributesOfItem(atPath: PulseSettings.fileURL(home: home).path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
    }

    @Test func noFileMeansDefaults() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let present = PulseSettings.loadIfPresent(home: home)
        #expect(present == nil)
        let loaded = PulseSettings.load(home: home)
        #expect(loaded == PulseSettings())
    }
}

/// The Settings page as a value: one page of three sections, deep links,
/// Install all / Remove all.
@Suite("Settings model")
struct SettingsModelTests {
    @Test func settingsIsOnePageOfThreeSections() {
        #expect(SettingsModel.sections == [.general, .notifications, .hooks])
        let titles = SettingsModel.sections.map { SettingsModel.title($0, lang: .zh) }
        #expect(Set(titles).count == titles.count, "every section has its own name")
    }

    @Test func deepLinksLandOnTheirSection() {
        #expect(SettingsModel.section(for: .waitingSignals) == .hooks)
        #expect(SettingsModel.section(for: .notifications) == .notifications)
    }

    @Test func notificationsSayWhatMacOSAllows() {
        #expect(SettingsModel.notifications(nil) == .notAsked)
        #expect(SettingsModel.notifications(false) == .denied)
        #expect(SettingsModel.notifications(true) == .allowed)
    }

    @MainActor
    @Test func theSettingsPageReadsSettingsNotScans() {
        let store = StatusStore(lang: .en)
        store.notifyAuthorized = false
        let model = store.settingsModel
        #expect(model.notifications == .denied)
        #expect(model.lang == .en)
    }

    /// Hooks are installed and removed for every agent at once; a line per
    /// agent says its state, never offers its own button.
    @Test func theHookButtonsAreInstallAllAndRemoveAll() {
        #expect(SettingsModel.hooksJob(.installHooks) == .install)
        #expect(SettingsModel.hooksJob(.uninstallHooks) == .uninstall)
        #expect(SettingsModel.hooksJob(.copyReport) == nil)
        #expect(SettingsModel.hooksJob(.openReleases) == nil)
    }

    /// A job keeps what it knew of agents it did not touch: an install
    /// that skips an agent not on this Mac does not forget why its last
    /// install failed.
    @Test func aJobKeepsTheFailuresOfAgentsItDidNotTouch() {
        let results = [HooksInstaller.AgentResult(agent: .claude, report: "", failure: nil)]
        let kept = HooksSupport.failures(after: results, keeping: [.gemini: .invalidJSON, .claude: .unwritable])
        #expect(kept == [.gemini: .invalidJSON], "Claude was done again; Gemini's reason stays")
        let failedAgain = [HooksInstaller.AgentResult(agent: .gemini, report: "", failure: .hasComments)]
        let replaced = HooksSupport.failures(after: failedAgain, keeping: [.gemini: .invalidJSON])
        #expect(replaced == [.gemini: .hasComments], "this run's reason wins")
    }

    /// The login toggle shows what macOS says: on while approval is
    /// pending (with a line to Login Items), off when macOS did not take it
    /// (with a line saying so), and what was asked until macOS is read.
    @Test func theLoginToggleShowsWhatMacOSSays() {
        let pending = SettingsModel.loginLine(asked: true, state: .requiresApproval)
        #expect(pending.isOn)
        #expect(pending.note == .needsApproval)
        let refused = SettingsModel.loginLine(asked: true, state: .off)
        #expect(!refused.isOn)
        #expect(refused.note == .failed)
        let removedElsewhere = SettingsModel.loginLine(asked: false, state: .off)
        #expect(!removedElsewhere.isOn)
        #expect(removedElsewhere.note == nil)
        let enabled = SettingsModel.loginLine(asked: true, state: .enabled)
        #expect(enabled.isOn)
        #expect(enabled.note == nil)
        let unread = SettingsModel.loginLine(asked: true, state: nil)
        #expect(unread.isOn)
        #expect(unread.note == nil)
        #expect(LoginItemState.requiresApproval.isOn)
        #expect(!LoginItemState.unavailable.isOn)
    }

    @MainActor
    @Test func theSettingsPageShowsTheLoginItem() {
        let store = StatusStore(lang: .en)
        store.settings.launchAtLogin = true
        store.land(\.loginItem, .requiresApproval)
        let model = store.settingsModel
        #expect(model.launchAtLogin)
        #expect(model.loginNote == .needsApproval)
    }

    /// The footer's one way to a newer Pulse: the releases page, in the
    /// browser. Pulse itself never asks the network.
    @Test func releasesOpensTheReleasesPage() {
        #expect(SettingsModel.releasesURL == "https://github.com/hxddh/Pulse/releases")
        for lang in [ResolvedLanguage.en, .zh] {
            #expect(!L10n.t(.releases, lang).isEmpty)
        }
    }

    /// The setup card carries no login checkbox: Settings keeps the one
    /// login toggle.
    @MainActor
    @Test func theSetupCardIsOneActionWithoutACheckbox() {
        let store = StatusStore(lang: .en)
        store.presentAgents = [.claude]
        let card = store.trayNotice
        #expect(card?.kind == .setup)
        #expect(card?.action == .connect)
    }
}

/// The interface follows the system language: Chinese of any script reads
/// the one Chinese table, everything else English.
@Suite("System language")
@MainActor
struct SystemLanguageTests {
    @Test func theStoreSpeaksTheLanguageItWasGiven() {
        let zh = StatusStore(lang: .zh).lang
        let en = StatusStore(lang: .en).lang
        #expect(zh == .zh)
        #expect(en == .en)
    }

    @Test func theSystemLanguageIsOneOfTheTwoTables() {
        let system = ResolvedLanguage.system
        let code = Locale.preferredLanguages.first ?? "en"
        #expect(system == (code.hasPrefix("zh") ? .zh : .en))
    }
}

/// "Don't suggest hooks" is the person's decision, and it persists.
@Suite("Hooks nudge setting")
struct HooksNudgeSettingTests {
    @Test func hooksNudgeOffRoundTrips() throws {
        var settings = PulseSettings()
        settings.hooksNudgeOff = true
        let data = try JSONEncoder().encode(settings)
        let reparsed = try JSONDecoder().decode(PulseSettings.self, from: data)
        #expect(reparsed.hooksNudgeOff)
        let absent = try JSONDecoder().decode(PulseSettings.self, from: Data("{}".utf8))
        #expect(!absent.hooksNudgeOff)
    }

    @MainActor
    @Test func anUninstalledChoiceSilencesTheHooksNudge() {
        let store = StatusStore(lang: .en)
        store.installPreviewFixture("waiting")
        store.presentAgents = [.claude, .codex]
        store.notifyAuthorized = true
        #expect(!store.trayNoticeInput.unconnected.isEmpty)
        store.settings.hooksNudgeOff = true
        #expect(store.trayNoticeInput.unconnected.isEmpty)
    }
}

/// Exact Terminal / iTerm landing is always tried; macOS's own Automation
/// prompt is the consent. A Go that reaches the app only says so — and,
/// when a tab script was tried, where that permission is.
@Suite("Terminal automation")
struct TerminalAutomationTests {
    private func row(_ handle: String) -> AgentRow {
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.state = .running
        row.cwd = "/w/a"
        row.landing = LandingHandle(handle)
        row.landingPlan = LandingPlan.make(handle: row.landing, cwd: row.cwd)
        return row
    }

    @Test func aTerminalTabIsAlwaysTried() {
        let tab = row("tty:/dev/ttys004;term:Apple_Terminal")
        #expect(tab.landingPlan.steps.first == .ttyTab(tty: "ttys004"))
        #expect(tab.landingPlan.precision == .exact)
        let iterm = row("iterm:w0t1p0:ABC;tty:/dev/ttys009;term:iTerm.app")
        #expect(iterm.landingPlan.steps.first == .iTermSession(uniqueID: "ABC"))
    }

    @Test func anAppOnlyGoSaysWhereAutomationIsOnlyWhenAScriptWasTried() {
        let tab = RowNotice.appOnly(row: row("tty:/dev/ttys004;term:Apple_Terminal"), lang: .en)
        #expect(tab.text == L10n.t(.focusAppOnlyAutomation, .en))
        let ghostty = RowNotice.appOnly(row: row("tty:/dev/ttys002;term:ghostty"), lang: .en)
        #expect(ghostty.text == L10n.t(.focusAppOnly, .en), "Ghostty: no script was tried")
    }

    @Test func theNoticeNamesAutomationInBothLanguages() {
        #expect(L10n.t(.focusAppOnlyAutomation, .en).contains("Automation"))
        #expect(L10n.t(.focusAppOnlyAutomation, .zh).contains("自动化"))
    }
}

/// Opening Pulse again — Finder, Spotlight, Raycast, a second copy — opens
/// the tray.
@Suite("Reopen")
@MainActor
struct ReopenTests {
    @Test func reopeningOpensTheTrayOnTheOldestWait() {
        let store = StatusStore(lang: .en)
        var opened = 0
        store.showTray = { opened += 1 }
        store.requestTrayReveal()
        #expect(opened == 1)
        let pending = store.takePendingReveal()
        #expect(pending == nil, "no row named: the tray selects the oldest wait itself")
    }

    @Test func aSecondCopyAsksByADistributedNotificationWithNoPayload() {
        #expect(SingleInstanceGuard.reopenNotification.rawValue == "com.pulse.app.reopen")
    }
}
