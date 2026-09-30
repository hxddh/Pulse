import Foundation
import Testing
@testable import PulseApp
@testable import PulseQA
@testable import PulseCore
@testable import PulseHarvest

// Settings: the persisted settings and the Settings page model.

/// Settings are the one file Pulse keeps for the person: a `Codable` value
/// in `settings.json`; an old `settings.txt` is deleted, unread, and the
/// defaults apply.
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
        original.language = .zh
        original.hotkey = .optionCommandP
        original.notifyOnWaiting = false
        original.mutedAgents = [.claude, .codex]
        original.allowTerminalAutomation = true
        original.updateCheckEnabled = false
        original.hooksNudgeOff = true
        let reparsed = try roundTrip(original)
        #expect(reparsed == original)
    }

    @Test func defaultsRoundTrip() throws {
        let defaults = PulseSettings()
        let reparsed = try roundTrip(defaults)
        #expect(reparsed == defaults)
    }

    @Test func defaultsAreTheQuietOnes() {
        let d = PulseSettings()
        #expect(!d.launchAtLogin)
        #expect(d.hotkey == .off, "the global shortcut is opt-in")
        #expect(d.notifyOnWaiting)
        #expect(!d.allowTerminalAutomation)
        #expect(d.updateCheckEnabled)
        #expect(!d.hooksNudgeOff)
    }

    // MARK: Tolerance

    @Test func anEmptyObjectYieldsDefaults() throws {
        let decoded = try decode("{}")
        #expect(decoded == PulseSettings())
    }

    @Test func unknownValuesFallBackAndUnknownKeysAreIgnored() throws {
        let decoded = try decode("""
            {"language": "klingon", "hotkey": "cmd_shift_zzz", "someFutureKey": 42,
             "updateCheckEnabled": false, "mutedAgents": ["claude", "not_an_agent", "codex"]}
            """)
        #expect(decoded.language == .auto)
        #expect(decoded.hotkey == .off, "an unknown shortcut registers nothing")
        #expect(!decoded.updateCheckEnabled)
        #expect(decoded.mutedAgents == [.claude, .codex])
    }

    @Test func aWrongTypeCostsOnlyThatField() throws {
        let decoded = try decode(#"{"launchAtLogin": "yes", "language": "zh"}"#)
        #expect(!decoded.launchAtLogin)
        #expect(decoded.language == .zh)
    }

    /// A retired `readProtectedAppData` key is simply ignored —
    /// Pulse reads no other app's data any more.
    @Test func theRetiredAppDataKeyIsIgnored() throws {
        let decoded = try decode(#"{"readProtectedAppData": true, "notifyOnWaiting": false}"#)
        #expect(!decoded.notifyOnWaiting)
        let encoded = try JSONEncoder().encode(decoded)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("readProtectedAppData"))
    }

    // MARK: On disk

    @Test func saveThenLoadRoundTrips() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        var settings = PulseSettings()
        settings.allowTerminalAutomation = true
        settings.mutedAgents = [.gemini]
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

    /// No migration: the old file is removed and the defaults apply, even
    /// when it asked for something else.
    @Test func aLegacySettingsTxtIsRemovedAndDefaultsApply() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let legacy = PulseSettings.retiredFileURL(home: home)
        try "appData=1\nlang=zh\nhotkey=cmd_shift_u\n".write(to: legacy, atomically: true, encoding: .utf8)
        let loaded = PulseSettings.load(home: home)
        #expect(loaded == PulseSettings())
        let stillThere = FileManager.default.fileExists(atPath: legacy.path)
        #expect(!stillThere, "settings.txt is deleted, not read")
    }

    @Test func aLegacyFileDoesNotShadowTheNewOne() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        var settings = PulseSettings()
        settings.language = .zh
        settings.save(home: home)
        try "lang=en\n".write(to: PulseSettings.retiredFileURL(home: home), atomically: true, encoding: .utf8)
        let loaded = PulseSettings.load(home: home)
        #expect(loaded.language == .zh)
    }
}

/// What earlier versions kept beside the event log is deleted at
/// launch, never read: the agents' hooks are the only state that outlives a
/// launch.
@Suite("Retired files")
struct RetiredFileTests {
    @Test func theSessionLogIsDeletedNotRead() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-retired-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("session-log.json")
        let keep = dir.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: log)
        try Data("{}".utf8).write(to: keep)
        StatusStore.removeRetiredFiles(in: [dir])
        let logLeft = FileManager.default.fileExists(atPath: log.path)
        let settingsLeft = FileManager.default.fileExists(atPath: keep.path)
        #expect(!logLeft)
        #expect(settingsLeft, "settings.json is the person's")
    }

    /// The v4 attention file and the activity spool are deleted at launch,
    /// unread; the event log stays.
    @Test func theV4FilesAreDeletedAndTheEventLogStays() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-retired-\(UUID().uuidString)", isDirectory: true)
        let spool = dir.appendingPathComponent("activity.d", isDirectory: true)
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let attention = dir.appendingPathComponent("attention.tsv")
        let events = dir.appendingPathComponent(EventLog.fileName)
        try Data("# pulse-attention v4\n".utf8).write(to: attention)
        try Data("{}".utf8).write(to: spool.appendingPathComponent("claude-s1.json"))
        try Data("# pulse-events v5 g1\n".utf8).write(to: events)
        StatusStore.removeRetiredFiles(in: [dir])
        let attentionLeft = FileManager.default.fileExists(atPath: attention.path)
        let spoolLeft = FileManager.default.fileExists(atPath: spool.path)
        let eventsLeft = FileManager.default.fileExists(atPath: events.path)
        #expect(!attentionLeft)
        #expect(!spoolLeft)
        #expect(eventsLeft)
    }
}

/// The store changes a setting through one path, and only when it changed.
@Suite("Store settings")
@MainActor
struct StoreSettingsTests {
    @Test func muteToggles() {
        ScanEngine.suppressBackgroundScansForTesting = true
        defer { ScanEngine.suppressBackgroundScansForTesting = false }
        let store = StatusStore()
        store.toggleMute(.gemini)
        let mutedAfterFirst = store.settings.mutedAgents
        #expect(mutedAfterFirst == [.gemini])
        store.toggleMute(.gemini)
        let mutedAfterSecond = store.settings.mutedAgents
        #expect(mutedAfterSecond.isEmpty)
    }
}

/// The Settings page as a value: one page of five sections, deep links, the
/// muted agents.
@Suite("Settings model")
struct SettingsModelTests {
    // MARK: - Settings

    /// Terminal automation is a switch in General, not a section of its
    /// own.
    @Test func settingsIsOnePageOfFiveSections() {
        #expect(SettingsModel.sections == [.general, .shortcut, .notifications, .hooks, .updates])
        let titles = SettingsModel.sections.map { SettingsModel.title($0, lang: .zh) }
        #expect(Set(titles).count == titles.count, "every section has its own name")
    }

    @Test func deepLinksLandOnTheirSection() {
        #expect(SettingsModel.section(for: .waitingSignals) == .hooks)
        #expect(SettingsModel.section(for: .notifications) == .notifications)
        #expect(SettingsModel.section(for: .updates) == .updates)
    }

    @Test func mutedAgentsReadInOrder() {
        let muted = SettingsModel.sortedMuted([.gemini, .pi, .claude])
        let names = muted.map { $0.displayName }
        let ordered = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        #expect(names == ordered)
        #expect(SettingsModel.notifications(nil) == .notAsked)
        #expect(SettingsModel.notifications(false) == .denied)
    }

    @MainActor
    @Test func theSettingsPageReadsSettingsNotScans() {
        let store = StatusStore()
        store.settings.mutedAgents = [.codex]
        store.notifyAuthorized = false
        let model = store.settingsModel
        #expect(model.mutedAgents == [.codex])
        #expect(model.notifications == .denied)
        #expect(!model.notifyOnWaiting, "the switch shows what takes effect")
        store.performSettings(.unmute(.codex))
        #expect(store.settings.mutedAgents.isEmpty)
    }

    /// Every Hooks line has its own Install or Remove: the job names that
    /// one agent; the section's buttons name every agent.
    @Test func aLinesButtonInstallsOrRemovesOnlyItsAgent() {
        #expect(SettingsModel.hooksJob(.installHook(.gemini)) == .install([.gemini]))
        #expect(SettingsModel.hooksJob(.uninstallHook(.claude)) == .uninstall([.claude]))
        #expect(SettingsModel.hooksJob(.installHooks) == .install(nil))
        #expect(SettingsModel.hooksJob(.uninstallHooks) == .uninstall(nil))
        #expect(SettingsModel.hooksJob(.copyReport) == nil)
        let one = HooksSupport.Job.install([.gemini])
        #expect(one.agents == [.gemini], "one agent, never the roster")
    }

    /// A job over some agents keeps what it knew of the others: removing
    /// Claude's hook does not forget why Gemini's install failed.
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
    @Test func theSettingsPageShowsTheLoginItemAndTheAutomationSwitch() {
        let store = StatusStore()
        store.settings.launchAtLogin = true
        store.landLoginItem(.requiresApproval)
        store.settings.allowTerminalAutomation = true
        let model = store.settingsModel
        #expect(model.launchAtLogin)
        #expect(model.loginNote == .needsApproval)
        #expect(model.terminalAutomation)
        store.performSettings(.setTerminalAutomation(false))
        #expect(!store.settings.allowTerminalAutomation)
    }

    /// The LaunchAgent earlier versions wrote is retired only when it is
    /// Pulse's own: its label and a Pulse program.
    @Test func onlyPulsesOwnLegacyLaunchAgentIsRetired() throws {
        func plist(_ label: String, _ arguments: [String]) throws -> Data {
            try PropertyListSerialization.data(
                fromPropertyList: ["Label": label, "ProgramArguments": arguments, "RunAtLoad": true],
                format: .xml, options: 0
            )
        }
        let bundled = try plist("com.pulse.app", ["/usr/bin/open", "-a", "/Applications/Pulse.app"])
        let shell = try plist("com.pulse.app", ["/Users/me/Pulse/.build/debug/PulseBar"])
        let stranger = try plist("com.pulse.app", ["/usr/local/bin/something-else"])
        let otherLabel = try plist("com.other.app", ["/Applications/Pulse.app"])
        #expect(LoginItem.isPulsesOwnAgent(bundled))
        #expect(LoginItem.isPulsesOwnAgent(shell))
        #expect(!LoginItem.isPulsesOwnAgent(stranger), "not a Pulse program: not Pulse's to remove")
        #expect(!LoginItem.isPulsesOwnAgent(otherLabel))
        #expect(!LoginItem.isPulsesOwnAgent(Data("not a plist".utf8)))
    }
}

/// A settings change applies only what that setting needs: a mute or a
/// notification switch touches nothing outside the file; the shortcut
/// re-registers only for the shortcut; the language and Terminal
/// automation re-project.
@Suite("Setting effects")
struct SettingEffectTests {
    @Test func eachSettingAppliesOnlyWhatItNeeds() {
        let base = PulseSettings()
        func effects(_ change: (inout PulseSettings) -> Void) -> Set<SettingEffect> {
            var next = base
            change(&next)
            return StatusStore.effects(from: base, to: next)
        }
        let hotkey = effects { $0.hotkey = .optionCommandP }
        let login = effects { $0.launchAtLogin = true }
        let updates = effects { $0.updateCheckEnabled = false }
        let language = effects { $0.language = .zh }
        let automation = effects { $0.allowTerminalAutomation = true }
        let mute = effects { $0.mutedAgents = [.gemini] }
        let notify = effects { $0.notifyOnWaiting = false }
        let nothing = effects { _ in }
        #expect(hotkey == [.hotkey])
        #expect(login == [.loginItem])
        #expect(updates == [.updateCheck])
        #expect(language == [.bannerCategory, .reproject])
        #expect(automation == [.reproject])
        #expect(mute.isEmpty)
        #expect(notify.isEmpty)
        #expect(nothing.isEmpty)
        // Two settings, each with its own effect, applied once each.
        let both = effects {
            $0.launchAtLogin = true
            $0.allowTerminalAutomation = true
        }
        #expect(both == [.loginItem, .reproject])
    }

    /// The setup card's "Open at login" checkbox is the same setting as the
    /// Settings toggle: ticking it asks for the login item. It starts
    /// unticked — never ticked for the person.
    @MainActor
    @Test func theSetupCardsLoginCheckboxIsTheLoginSetting() {
        let store = StatusStore()
        store.presentAgents = [.claude]
        let card = store.trayNotice
        #expect(card?.kind == .setup)
        #expect(card?.openAtLogin == false, "unticked until the person ticks it")
        store.performTrayNotice(.setOpenAtLogin(true))
        #expect(store.settings.launchAtLogin)
        let ticked = store.trayNotice
        #expect(ticked?.openAtLogin == true)
        let login = StatusStore.effects(from: PulseSettings(), to: store.settings)
        #expect(login == [.loginItem])
    }

    /// "System" is said in the interface's language.
    @Test func theLanguagePickerSaysSystemInTheInterfacesLanguage() {
        #expect(AppLanguage.auto.menuLabel(.en) == "System")
        #expect(AppLanguage.auto.menuLabel(.zh) == L10n.t(.languageSystem, .zh))
        #expect(AppLanguage.auto.menuLabel(.zh) != "System")
        #expect(AppLanguage.zh.menuLabel(.en) == "简体中文", "Simplified is the one Chinese there is — said so")
        #expect(AppLanguage.en.menuLabel(.zh) == "English")
    }
}

/// "Don't suggest hooks" is the person's decision, and it persists.
@Suite("Hooks nudge setting")
struct HooksNudgeSettingTests {
    // MARK: - "Don't suggest hooks" persists

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
        let store = StatusStore()
        store.installPreviewFixture("waiting")
        store.presentAgents = [.claude, .codex]
        store.notifyAuthorized = true
        #expect(!store.setupAgents.isEmpty)
        store.settings.hooksNudgeOff = true
        #expect(store.setupAgents.isEmpty)
    }
}

/// Terminal automation is a Settings switch. A Go that reaches the app
/// only says so — and, when that switch is what stands between it and the
/// exact tab, names the switch.
@Suite("Terminal automation")
struct TerminalAutomationTests {
    private func row(_ handle: String) -> AgentRow {
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.state = .running
        row.cwd = "/w/a"
        row.landing = LandingHandle(handle)
        row.landingPlan = LandingPlan.make(handle: row.landing, cwd: row.cwd, allowAutomation: false)
        return row
    }

    @Test func anAppOnlyGoNamesTheSwitchOnlyWhenItWouldHelp() {
        let tab = row("tty:/dev/ttys004;term:Apple_Terminal")
        let named = RowNotice.appOnly(row: tab, automationAllowed: false, lang: .en)
        #expect(named.text == L10n.t(.focusAppOnlyAutomation, .en))
        let allowed = RowNotice.appOnly(row: tab, automationAllowed: true, lang: .en)
        #expect(allowed.text == L10n.t(.focusAppOnly, .en), "already on: nothing to point at")
        let ghostty = RowNotice.appOnly(row: row("tty:/dev/ttys002;term:ghostty"), automationAllowed: false, lang: .en)
        #expect(ghostty.text == L10n.t(.focusAppOnly, .en), "Ghostty: the switch would not help")
    }

    @Test func theSwitchIsRealCopyInBothLanguages() {
        for lang in [ResolvedLanguage.en, .zh] {
            #expect(!L10n.t(.terminalAutomation, lang).isEmpty)
            #expect(!L10n.t(.terminalAutomationHint, lang).isEmpty)
            #expect(L10n.t(.focusAppOnlyAutomation, lang).contains(L10n.t(.terminalAutomation, lang)),
                    "the notice names the switch by its own words")
        }
    }

    @MainActor
    @Test func theSwitchIsOneSettingAndReprojects() {
        let store = StatusStore()
        store.performSettings(.setTerminalAutomation(true))
        #expect(store.settings.allowTerminalAutomation)
        let effects = StatusStore.effects(from: PulseSettings(), to: store.settings)
        #expect(effects == [.reproject])
    }
}

/// Opening Pulse again — Finder, Spotlight, a second copy — opens the tray.
@Suite("Reopen")
@MainActor
struct ReopenTests {
    @Test func reopeningOpensTheTrayOnTheOldestWait() {
        let store = StatusStore()
        var opened = 0
        store.showTray = { opened += 1 }
        store.reopen()
        #expect(opened == 1)
        let pending = store.takePendingReveal()
        #expect(pending == nil, "no row named: the tray selects the oldest wait itself")
    }

    @Test func aSecondCopyAsksByADistributedNotificationWithNoPayload() {
        #expect(SingleInstanceGuard.reopenNotification.rawValue == "com.pulse.app.reopen")
    }
}

/// "Uninstall Pulse…": what it says it will remove, and when it stops.
@Suite("Uninstall plan")
struct UninstallPlanTests {
    let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)

    @Test func thePlanNamesEveryHookTheLoginItemAndTheFolder() {
        let plan = UninstallPlan.make(
            installed: [.gemini, .claude],
            loginItem: .requiresApproval,
            folder: home.appendingPathComponent("Library/Application Support/Pulse"),
            home: home
        )
        #expect(plan.hooks == [.claude, .gemini], "roster order")
        #expect(plan.loginItem)
        #expect(plan.folder == "~/Library/Application Support/Pulse")
        let en = plan.message(.en)
        #expect(en.contains("Claude") && en.contains("Gemini"))
        #expect(en.contains(L10n.t(.uninstallLogin, .en)))
        #expect(en.contains("~/Library/Application Support/Pulse"))
        #expect(en.hasSuffix(L10n.t(.uninstallThen, .en)))
        #expect(plan.message(.zh) != en)
    }

    @Test func nothingInstalledAndNoLoginItemSaySo() {
        let plan = UninstallPlan.make(
            installed: [], loginItem: .off,
            folder: URL(fileURLWithPath: "/tmp/pulse-home"), home: home
        )
        #expect(plan.hooks.isEmpty)
        #expect(!plan.loginItem)
        #expect(plan.folder == "/tmp/pulse-home", "a folder outside home is said in full")
        let en = plan.message(.en)
        #expect(en.hasPrefix(L10n.t(.uninstallNoHooks, .en)))
        #expect(!en.contains(L10n.t(.uninstallLogin, .en)))
    }

    /// The folder holds the record a byte-for-byte removal needs: it goes
    /// only when no hook of Pulse's is left anywhere.
    @Test func theFolderGoesOnlyWhenEveryHookIsOut() {
        let removed: [HooksSupport.Status] = [.missing, .installed([])]
        let kept: [HooksSupport.Status] = [
            .installed([.claude]),
            .installed([], failed: [.gemini: .invalidJSON]),
            .failed(.unwritable),
            .working,
            .unknown,
        ]
        let yes = removed.map(UninstallPlan.hooksRemoved)
        let no = kept.map(UninstallPlan.hooksRemoved)
        #expect(yes == [true, true])
        #expect(no == [false, false, false, false, false])
    }
}
