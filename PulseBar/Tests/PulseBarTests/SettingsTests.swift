import Foundation
import Testing
@testable import PulseApp
@testable import PulseQA
@testable import PulseCore
@testable import PulseHarvest

// Settings: the persisted settings and the Settings page model.

/// Settings are the one file Pulse keeps for the person. 23.0: a `Codable`
/// value in `settings.json`; a pre-23.0 `settings.txt` is deleted, unread,
/// and the defaults apply.
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
        original.hotkey = .controlOptionP
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

    /// 24.0: a `readProtectedAppData` key from 23.0 is simply ignored —
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

    /// Terminal control is not a section: the automation setting stays in
    /// `settings.json`, and the landing plan reads it.
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
        store.notifyAuthorized = true
        #expect(store.needsHooksNudge)
        store.settings.hooksNudgeOff = true
        #expect(!store.needsHooksNudge)
    }
}
