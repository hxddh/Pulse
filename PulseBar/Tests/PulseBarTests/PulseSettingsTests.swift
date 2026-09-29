import Foundation
import Testing
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

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
        original.readProtectedAppData = true
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
        #expect(!d.readProtectedAppData, "protected app data is opt-in")
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

    // MARK: The app-data switch

    @Test func oneSwitchCoversEveryProtectedAgent() {
        var settings = PulseSettings()
        let protected = AgentID.allCases.filter(\.requiresAppDataOptIn)
        #expect(!protected.isEmpty)
        let limitedWhenOff = protected.allSatisfy { settings.isPrivacyLimited($0) }
        #expect(limitedWhenOff)
        settings.readProtectedAppData = true
        let limitedWhenOn = protected.contains { settings.isPrivacyLimited($0) }
        #expect(!limitedWhenOn)
        let open = AgentID.allCases.filter { !$0.requiresAppDataOptIn }
        let openLimited = open.contains { PulseSettings().isPrivacyLimited($0) }
        #expect(!openLimited, "an agent that needs no opt-in is never privacy-limited")
    }

    // MARK: On disk

    @Test func saveThenLoadRoundTrips() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        var settings = PulseSettings()
        settings.readProtectedAppData = true
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

    @Test func theAppDataSwitchIsOneBoolean() {
        ScanEngine.suppressBackgroundScansForTesting = true
        defer { ScanEngine.suppressBackgroundScansForTesting = false }
        let store = StatusStore()
        store.setReadProtectedAppData(true)
        #expect(store.settings.readProtectedAppData)
        let cursorLimited = store.settings.isPrivacyLimited(.cursor)
        #expect(!cursorLimited)
    }
}
