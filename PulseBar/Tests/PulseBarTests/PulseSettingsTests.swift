import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

/// Settings are the one file Pulse keeps for the person. 23.0 dropped every
/// migration from older versions; what is left is the parser's tolerance
/// and a lossless round trip.
final class PulseSettingsTests: XCTestCase {

    // MARK: Round trip

    func testRoundTripPreservesEverything() {
        var original = PulseSettings()
        original.notifyOnIdle = false
        original.notifyOnWaiting = true
        original.launchAtLogin = true
        original.language = .zh
        original.updateCheckEnabled = false
        original.hotkey = .controlOptionP
        original.allowTerminalAutomation = true
        original.mutedAgents = [.claude, .codex]
        original.appDataAgents = [.cursor, .warpAgent]

        XCTAssertEqual(PulseSettings.parse(original.serialized()), original)
    }

    func testTerminalAutomationDefaultsOffAndRoundTrips() {
        let defaults = PulseSettings()
        XCTAssertFalse(defaults.allowTerminalAutomation)
        XCTAssertFalse(PulseSettings.parse(defaults.serialized()).allowTerminalAutomation)

        var on = PulseSettings()
        on.allowTerminalAutomation = true
        XCTAssertTrue(PulseSettings.parse(on.serialized()).allowTerminalAutomation)
        XCTAssertTrue(PulseSettings.parse("terminalAutomation=1").allowTerminalAutomation)
        XCTAssertFalse(PulseSettings.parse("terminalAutomation=0").allowTerminalAutomation)
    }

    func testDefaultsRoundTrip() {
        let d = PulseSettings()
        XCTAssertEqual(PulseSettings.parse(d.serialized()), d)
    }

    func testLoadFromDiskReadsScopedAppDataAgents() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-settings-\(UUID().uuidString)", isDirectory: true)
        let dir = home.appendingPathComponent("Library/Application Support/Pulse", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        var settings = PulseSettings()
        settings.allowAppData = false
        settings.appDataAgents = [.cursor]
        try settings.serialized().write(
            to: PulseSettings.settingsFileURL(home: home),
            atomically: true,
            encoding: .utf8
        )

        let loaded = PulseSettings.loadFromDisk(home: home)
        XCTAssertFalse(loaded.allowAppData)
        XCTAssertEqual(loaded.appDataAgents, [.cursor])
    }

    func testGlobalShortcutIsOptInAndRoundTrips() {
        XCTAssertEqual(PulseSettings().hotkey, .off)
        XCTAssertEqual(PulseSettings.parse("hotkey=cmd_opt_p").hotkey, .commandOptionP)

        var enabled = PulseSettings()
        enabled.hotkey = .commandShiftU
        let reparsed = PulseSettings.parse(enabled.serialized())
        XCTAssertEqual(reparsed.hotkey, .commandShiftU)
    }

    func testMuteListSurvivesAndIgnoresUnknownAgents() {
        let s = PulseSettings.parse("mute=claude,not_an_agent,codex")
        XCTAssertEqual(s.mutedAgents, [.claude, .codex])
    }

    func testEmptyMuteListParsesAsNone() {
        XCTAssertTrue(PulseSettings.parse("mute=").mutedAgents.isEmpty)
    }

    // MARK: Tolerance

    func testGarbageLinesDoNotCostTheRestOfTheFile() {
        let s = PulseSettings.parse("""
            updates=0
            this line has no equals sign
            =novalue
            lang=zh

            notify=0
            """)
        XCTAssertFalse(s.updateCheckEnabled)
        XCTAssertFalse(s.notifyOnIdle)
        XCTAssertEqual(s.language, .zh)
    }

    func testUnknownKeysAreIgnoredNotFatal() {
        let s = PulseSettings.parse("updates=0\nsomeFutureKey=42\nlang=en")
        XCTAssertFalse(s.updateCheckEnabled)
        XCTAssertEqual(s.language, .en)
    }

    func testUnparseableEnumsFallBackToDefaults() {
        let s = PulseSettings.parse("lang=klingon\nhotkey=cmd_shift_zzz")
        XCTAssertEqual(s.language, .auto)
        XCTAssertEqual(s.hotkey, .off, "an unknown shortcut registers nothing")
    }

    func testEmptyFileYieldsDefaults() {
        XCTAssertEqual(PulseSettings.parse(""), PulseSettings())
    }

    func testBooleansAcceptBothSpellings() {
        let off = PulseSettings.parse("updates=false\nnotify=0")
        XCTAssertFalse(off.updateCheckEnabled)
        XCTAssertFalse(off.notifyOnIdle)
        let on = PulseSettings.parse("updates=1\nnotify=true")
        XCTAssertTrue(on.updateCheckEnabled)
        XCTAssertTrue(on.notifyOnIdle)
    }
}

/// The store must round-trip through the value type without losing anything.
final class StoreSettingsBridgeTests: XCTestCase {
    @MainActor
    func testApplyThenReadBackIsIdentity() {
        let store = StatusStore()
        var s = PulseSettings()
        s.notifyOnIdle = false
        s.language = .zh
        s.hotkey = .commandShiftU
        s.mutedAgents = [.gemini]
        s.updateCheckEnabled = false

        store.apply(s)
        XCTAssertEqual(store.currentSettings, s)
    }
}
