import XCTest
@testable import PulseBar

/// Settings are a one-way door: the 0.22 whole-hours → minutes migration runs
/// once on every existing user's first launch, and a bug there silently costs
/// them their configuration with no way to notice.
final class PulseSettingsTests: XCTestCase {

    // MARK: Migration

    /// Exactly what a pre-0.22 install has on disk.
    private let legacyFile = """
        auto=1
        notify=1
        notifyWaiting=1
        quiet=1
        quietStart=22
        quietEnd=8
        lang=zh
        login=0
        """

    func testLegacyWholeHoursBecomeMinutes() {
        let s = PulseSettings.parse(legacyFile)
        XCTAssertTrue(s.quietHoursEnabled)
        XCTAssertEqual(s.quietStartMinute, 22 * 60)
        XCTAssertEqual(s.quietEndMinute, 8 * 60)
        XCTAssertEqual(s.language, .zh, "the rest of the file must survive the migration")
    }

    func testMinuteKeysWinOverLegacyHourKeys() {
        // A file written by 0.22 that still carries the old keys must not be
        // dragged back to whole hours.
        let mixed = legacyFile + "\nquietStartMin=1350\nquietEndMin=450"
        let s = PulseSettings.parse(mixed)
        XCTAssertEqual(s.quietStartMinute, 1350, "22:30 must not become 22:00")
        XCTAssertEqual(s.quietEndMinute, 450)
    }

    func testMigrationDoesNotRunTwice() {
        let migrated = PulseSettings.parse(legacyFile)
        var edited = migrated
        edited.quietStartMinute = 22 * 60 + 30
        let reparsed = PulseSettings.parse(edited.serialized())
        XCTAssertEqual(reparsed.quietStartMinute, 22 * 60 + 30)
    }

    func testFileWithoutQuietKeysKeepsDefaults() {
        let s = PulseSettings.parse("auto=1\nlang=en")
        XCTAssertEqual(s.quietStartMinute, 22 * 60)
        XCTAssertEqual(s.quietEndMinute, 8 * 60)
    }

    // MARK: Round trip

    func testRoundTripPreservesEverything() {
        var original = PulseSettings()
        original.autoProbe = false
        original.notifyOnIdle = false
        original.notifyOnWaiting = true
        original.quietHoursEnabled = true
        original.quietStartMinute = 23 * 60 + 15
        original.quietEndMinute = 7 * 60 + 45
        original.launchAtLogin = true
        original.language = .zh
        original.updateCheckEnabled = false
        original.hotkey = .controlOptionP
        original.mutedAgents = [.claude, .codex]

        XCTAssertEqual(PulseSettings.parse(original.serialized()), original)
    }

    func testDefaultsRoundTrip() {
        let d = PulseSettings()
        XCTAssertEqual(PulseSettings.parse(d.serialized()), d)
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
            auto=0
            this line has no equals sign
            =novalue
            lang=zh

            notify=0
            """)
        XCTAssertFalse(s.autoProbe)
        XCTAssertFalse(s.notifyOnIdle)
        XCTAssertEqual(s.language, .zh)
    }

    func testUnknownKeysAreIgnoredNotFatal() {
        let s = PulseSettings.parse("auto=0\nsomeFutureKey=42\nlang=en")
        XCTAssertFalse(s.autoProbe)
        XCTAssertEqual(s.language, .en)
    }

    func testUnparseableEnumsFallBackToDefaults() {
        let s = PulseSettings.parse("lang=klingon\nhotkey=cmd_shift_zzz")
        XCTAssertEqual(s.language, .auto)
        XCTAssertEqual(s.hotkey, .commandShiftP)
    }

    func testNonNumericMinutesKeepDefaultsRatherThanZeroing() {
        let s = PulseSettings.parse("quietStartMin=abc\nquietEndMin=")
        XCTAssertEqual(s.quietStartMinute, 22 * 60)
        XCTAssertEqual(s.quietEndMinute, 8 * 60)
    }

    func testEmptyFileYieldsDefaults() {
        XCTAssertEqual(PulseSettings.parse(""), PulseSettings())
    }

    func testBooleansAcceptBothSpellings() {
        let off = PulseSettings.parse("auto=false\nnotify=0")
        XCTAssertFalse(off.autoProbe)
        XCTAssertFalse(off.notifyOnIdle)
        let on = PulseSettings.parse("auto=1\nnotify=true")
        XCTAssertTrue(on.autoProbe)
        XCTAssertTrue(on.notifyOnIdle)
    }

    // MARK: Clamping

    func testOutOfRangeMinutesAreClamped() {
        XCTAssertEqual(PulseSettings.clampMinute(-5), 0)
        XCTAssertEqual(PulseSettings.clampMinute(99_999), 24 * 60 - 1)
        let s = PulseSettings.parse("quietStartMin=-100\nquietEndMin=5000")
        XCTAssertEqual(s.quietStartMinute, 0)
        XCTAssertEqual(s.quietEndMinute, 24 * 60 - 1)
    }

    func testSerializerNeverEmitsAnOutOfRangeMinute() {
        var s = PulseSettings()
        s.quietStartMinute = 99_999
        XCTAssertTrue(s.serialized().contains("quietStartMin=\(24 * 60 - 1)"))
    }

    // MARK: Quiet hours

    private func at(_ hour: Int, _ minute: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 27
        c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c)!
    }

    private func quiet(_ start: Int, _ end: Int) -> PulseSettings {
        var s = PulseSettings()
        s.quietHoursEnabled = true
        s.quietStartMinute = start
        s.quietEndMinute = end
        return s
    }

    func testMinutePrecisionIsRespected() {
        let s = quiet(22 * 60 + 30, 8 * 60)
        XCTAssertFalse(s.isInQuietHours(now: at(22, 15)), "22:15 is before a 22:30 start")
        XCTAssertTrue(s.isInQuietHours(now: at(22, 45)))
    }

    func testWindowWrapsPastMidnight() {
        let s = quiet(22 * 60, 8 * 60)
        XCTAssertTrue(s.isInQuietHours(now: at(23, 0)))
        XCTAssertTrue(s.isInQuietHours(now: at(3, 0)))
        XCTAssertFalse(s.isInQuietHours(now: at(12, 0)))
    }

    func testEqualStartAndEndDisablesRatherThanSilencingAllDay() {
        let s = quiet(9 * 60, 9 * 60)
        XCTAssertFalse(s.isInQuietHours(now: at(9, 0)))
        XCTAssertFalse(s.isInQuietHours(now: at(21, 0)))
    }

    func testDisabledMeansNeverQuiet() {
        var s = quiet(0, 24 * 60 - 1)
        s.quietHoursEnabled = false
        XCTAssertFalse(s.isInQuietHours(now: at(3, 0)))
    }

    func testBoundariesAreHalfOpen() {
        let s = quiet(22 * 60, 8 * 60)
        XCTAssertTrue(s.isInQuietHours(now: at(22, 0)), "start is inclusive")
        XCTAssertFalse(s.isInQuietHours(now: at(8, 0)), "end is exclusive")
    }
}

/// The store must round-trip through the value type without losing anything.
@MainActor
final class StoreSettingsBridgeTests: XCTestCase {
    func testApplyThenReadBackIsIdentity() {
        let store = StatusStore()
        var s = PulseSettings()
        s.autoProbe = false
        s.quietHoursEnabled = true
        s.quietStartMinute = 21 * 60 + 30
        s.language = .zh
        s.hotkey = .commandShiftU
        s.mutedAgents = [.gemini]
        s.updateCheckEnabled = false

        store.apply(s)
        XCTAssertEqual(store.currentSettings, s)
    }

    func testStoreQuietHoursDelegateToTheValueType() {
        let store = StatusStore()
        store.quietHoursEnabled = true
        store.quietStartMinute = 22 * 60 + 30
        store.quietEndMinute = 8 * 60

        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 27; c.hour = 22; c.minute = 45
        let inWindow = Calendar.current.date(from: c)!
        XCTAssertTrue(store.isInQuietHours(now: inWindow))
    }

    // MARK: 0.24 additions

    func testGroupingAndSoundRoundTrip() {
        var s = PulseSettings()
        s.trayGrouping = .project
        s.playSoundOnWaiting = true
        let back = PulseSettings.parse(s.serialized())
        XCTAssertEqual(back.trayGrouping, .project)
        XCTAssertTrue(back.playSoundOnWaiting)
    }

    /// A settings file written before 0.24 must not change how the tray groups
    /// or start making noise.
    func testPre024FileKeepsQuietDefaults() {
        let old = """
            auto=1
            notify=1
            lang=zh
            hotkey=cmd_shift_p
            """
        let s = PulseSettings.parse(old)
        XCTAssertEqual(s.trayGrouping, .status)
        XCTAssertFalse(s.playSoundOnWaiting)
    }

    func testUnknownGroupingFallsBackToStatus() {
        let s = PulseSettings.parse("grouping=byVibes")
        XCTAssertEqual(s.trayGrouping, .status)
    }

}
