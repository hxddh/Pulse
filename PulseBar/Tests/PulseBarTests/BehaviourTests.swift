import XCTest
@testable import PulseBar

/// Cadence policy — the fix for "Pulse is using significant energy".
final class ProbeScheduleTests: XCTestCase {
    private let awake = ProbeSchedule.Power()

    func testBusierStatesProbeFaster() {
        let waiting = ProbeSchedule.interval(activity: .waiting, power: awake, trayOpen: false)!
        let running = ProbeSchedule.interval(activity: .running, power: awake, trayOpen: false)!
        let recent = ProbeSchedule.interval(activity: .recent, power: awake, trayOpen: false)!
        let empty = ProbeSchedule.interval(activity: .empty, power: awake, trayOpen: false)!
        XCTAssertLessThan(waiting, running)
        XCTAssertLessThan(running, recent)
        XCTAssertLessThan(recent, empty)
    }

    func testIdleMachineIsDramaticallyCheaperThanTheOldFixedCadence() {
        let empty = ProbeSchedule.interval(activity: .empty, power: awake, trayOpen: false)!
        XCTAssertGreaterThanOrEqual(empty, 30, "pre-0.22 probed every 3s regardless")
    }

    func testParkedWhenDisplayAsleepUnlessTrayIsOpen() {
        var power = ProbeSchedule.Power()
        power.displayAsleep = true
        XCTAssertNil(ProbeSchedule.interval(activity: .waiting, power: power, trayOpen: false))
        XCTAssertNotNil(ProbeSchedule.interval(activity: .waiting, power: power, trayOpen: true))
    }

    func testScreenLockAlsoParks() {
        var power = ProbeSchedule.Power()
        power.screenLocked = true
        XCTAssertTrue(power.parked)
        XCTAssertNil(ProbeSchedule.interval(activity: .running, power: power, trayOpen: false))
    }

    func testLowPowerModeSlowsButNeverParks() {
        var power = ProbeSchedule.Power()
        power.lowPowerMode = true
        let normal = ProbeSchedule.interval(activity: .running, power: awake, trayOpen: false)!
        let saving = ProbeSchedule.interval(activity: .running, power: power, trayOpen: false)!
        XCTAssertEqual(saving, normal * 2)
    }

    func testOpenTrayNeverSlowsThingsDown() {
        for activity in [ProbeSchedule.Activity.waiting, .running, .recent, .empty] {
            let closed = ProbeSchedule.interval(activity: activity, power: awake, trayOpen: false)!
            let open = ProbeSchedule.interval(activity: activity, power: awake, trayOpen: true)!
            XCTAssertLessThanOrEqual(open, closed, "\(activity) got slower with the tray open")
        }
    }

    func testHarvestRunsEveryTickWhileWaitingOrWatching() {
        XCTAssertEqual(ProbeSchedule.harvestEveryNTicks(activity: .waiting, trayOpen: false), 1)
        XCTAssertEqual(ProbeSchedule.harvestEveryNTicks(activity: .running, trayOpen: true), 1)
        XCTAssertGreaterThan(ProbeSchedule.harvestEveryNTicks(activity: .running, trayOpen: false), 1)
    }
}

/// Focus honesty: never claim a TTY we cannot select.
final class FocusTierTests: XCTestCase {
    private let fullEnv = TerminalFocus.Environment(
        warpRunning: true, ttyHostRunning: true, anyTerminalInstalled: true
    )

    func testWarpWins_WhenProcessRunsUnderWarp() {
        let tier = TerminalFocus.focusTier(tty: "ttys003", viaWarp: true, cwdExists: true, env: fullEnv)
        XCTAssertEqual(tier, .warp, "TTY tab select does not work inside Warp")
    }

    func testTTYUsedWhenTerminalOrITermIsRunning() {
        let env = TerminalFocus.Environment(
            warpRunning: false, ttyHostRunning: true, anyTerminalInstalled: true
        )
        XCTAssertEqual(
            TerminalFocus.focusTier(tty: "ttys003", viaWarp: false, cwdExists: true, env: env),
            .tty
        )
    }

    func testFallsBackToOpenCwdWhenNoTTYHost() {
        let env = TerminalFocus.Environment(
            warpRunning: false, ttyHostRunning: false, anyTerminalInstalled: true
        )
        XCTAssertEqual(
            TerminalFocus.focusTier(tty: "ttys003", viaWarp: false, cwdExists: true, env: env),
            .openCwd
        )
    }

    func testNoHandleMeansNoFocusButtonAtAll() {
        let env = TerminalFocus.Environment(
            warpRunning: false, ttyHostRunning: false, anyTerminalInstalled: true
        )
        XCTAssertNil(TerminalFocus.focusTier(tty: "", viaWarp: false, cwdExists: false, env: env))
    }

    func testPlaceholderTTYValuesAreNotRealHandles() {
        let env = TerminalFocus.Environment(
            warpRunning: false, ttyHostRunning: true, anyTerminalInstalled: false
        )
        for placeholder in ["", "?", "??", "-"] {
            XCTAssertNil(
                TerminalFocus.focusTier(tty: placeholder, viaWarp: false, cwdExists: false, env: env),
                "\(placeholder) should not count as a TTY"
            )
        }
    }
}

/// Row presentation rules from EXPERIENCE.md.
final class AgentRowTests: XCTestCase {
    private func row(_ mutate: (inout AgentRow) -> Void) -> AgentRow {
        var r = AgentRow(rowKey: "claude|s1", agent: .claude)
        mutate(&r)
        return r
    }

    func testPlaceholderTitlesAreNotTreatedAsSessions() {
        for junk in ["-", "—", "Running", "Active", "none", "Agent session", "Chat"] {
            let r = row { $0.task = junk }
            XCTAssertNil(r.usefulTask, "\(junk) is not a real session title")
        }
    }

    func testBarePathIsNotASessionTitle() {
        XCTAssertNil(row { $0.task = "/Users/me/code" }.usefulTask)
        XCTAssertNotNil(row { $0.task = "/Users/me fix the parser" }.usefulTask)
    }

    func testLiveRowWithToolButNoTaskFallsBackToTool() {
        // This fallback existed but was never wired into the tray before 0.22.
        let r = row {
            $0.liveProcess = true
            $0.tool = "Bash"
        }
        XCTAssertEqual(r.sessionDetail, "Bash")
        XCTAssertFalse(r.isProcessOnly, "a known tool is more than 'process detected'")
    }

    func testLiveRowWithNothingToSayIsProcessOnly() {
        let r = row { $0.liveProcess = true }
        XCTAssertNil(r.sessionDetail)
        XCTAssertTrue(r.isProcessOnly)
    }

    func testWaitingRowsHideTokens() {
        let r = row {
            $0.waiting = true
            $0.tokensIn = 5000
            $0.tokensOut = 900
        }
        XCTAssertFalse(r.metaLine?.contains("↑") ?? false, "status comes before accounting")
    }

    func testTokenFormattingStaysCompact() {
        XCTAssertEqual(AgentRow.compactToken(0), "")
        XCTAssertEqual(AgentRow.compactToken(999), "999")
        XCTAssertEqual(AgentRow.compactToken(1500), "1.5k")
        XCTAssertEqual(AgentRow.compactToken(23_000), "23k")
        XCTAssertEqual(AgentRow.compactToken(2_400_000), "2.4M")
    }

    func testShortProjectDropsOpaqueHashes() {
        XCTAssertEqual(AgentRow.shortProject("/Users/me/code/Pulse"), "Pulse")
        XCTAssertEqual(AgentRow.shortProject("a1b2c3d4e5f60718"), "", "hash is not a project name")
        XCTAssertEqual(AgentRow.shortProject(""), "")
    }

    func testLongProjectNamesAreTruncated() {
        let long = String(repeating: "x", count: 40)
        let short = AgentRow.shortProject(long)
        XCTAssertLessThanOrEqual(short.count, 24)
        XCTAssertTrue(short.hasSuffix("…"))
    }
}

/// `ps` parsing and the harvest-skip fingerprint.
final class ProcessProbeTests: XCTestCase {
    func testSignatureIsOrderIndependent() {
        let a = ProcessProbe.Hit(id: .claude, count: 1, viaWarp: false, pid: 10)
        let b = ProcessProbe.Hit(id: .codex, count: 2, viaWarp: false, pid: 20)
        XCTAssertEqual(ProcessProbe.signature([a, b]), ProcessProbe.signature([b, a]))
    }

    func testSignatureChangesWhenTheAgentSetChanges() {
        let a = ProcessProbe.Hit(id: .claude, count: 1, viaWarp: false, pid: 10)
        let more = ProcessProbe.Hit(id: .claude, count: 2, viaWarp: false, pid: 10)
        XCTAssertNotEqual(ProcessProbe.signature([a]), ProcessProbe.signature([more]))
        XCTAssertNotEqual(ProcessProbe.signature([a]), ProcessProbe.signature([]))
    }
}

/// Quiet hours now carry minute precision and still wrap midnight.
@MainActor
final class QuietHoursTests: XCTestCase {
    private func store(start: Int, end: Int) -> StatusStore {
        let s = StatusStore()
        s.quietHoursEnabled = true
        s.quietStartMinute = start
        s.quietEndMinute = end
        return s
    }

    private func at(_ hour: Int, _ minute: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 27
        c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c)!
    }

    func testHalfPastStartIsRespected() {
        let s = store(start: 22 * 60 + 30, end: 8 * 60)
        XCTAssertFalse(s.isInQuietHours(now: at(22, 15)), "22:15 is before a 22:30 start")
        XCTAssertTrue(s.isInQuietHours(now: at(22, 45)))
    }

    func testWindowWrapsPastMidnight() {
        let s = store(start: 22 * 60, end: 8 * 60)
        XCTAssertTrue(s.isInQuietHours(now: at(23, 0)))
        XCTAssertTrue(s.isInQuietHours(now: at(3, 0)))
        XCTAssertFalse(s.isInQuietHours(now: at(12, 0)))
    }

    func testSameStartAndEndDisablesRatherThanSilencingAllDay() {
        let s = store(start: 9 * 60, end: 9 * 60)
        XCTAssertFalse(s.isInQuietHours(now: at(9, 0)))
        XCTAssertFalse(s.isInQuietHours(now: at(21, 0)))
    }

    func testDisabledMeansNeverQuiet() {
        let s = store(start: 0, end: 23 * 60 + 59)
        s.quietHoursEnabled = false
        XCTAssertFalse(s.isInQuietHours(now: at(3, 0)))
    }

    func testMinutesAreClamped() {
        XCTAssertEqual(StatusStore.clampMinute(-5), 0)
        XCTAssertEqual(StatusStore.clampMinute(99_999), 24 * 60 - 1)
    }
}

/// Notification copy — the banner has to say what is wanted.
@MainActor
final class NotificationCopyTests: XCTestCase {
    func testBodyCarriesReasonAndMessageNotJustNeedsYou() {
        let store = StatusStore()
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.waiting = true
        row.waitKind = "Permission"
        row.waitMessage = "Approve shell command"
        row.project = "/Users/me/code/Pulse"

        let body = store.notificationBody(row)
        XCTAssertTrue(body.contains("Approve shell command"))
        XCTAssertTrue(store.notificationTitle(row).contains("Claude"))
        XCTAssertTrue(store.notificationTitle(row).contains("Pulse"), "title should locate the work")
    }

    func testLongMessagesAreTruncated() {
        let store = StatusStore()
        var row = AgentRow(rowKey: "k", agent: .codex)
        row.waiting = true
        row.waitMessage = String(repeating: "x", count: 400)
        XCTAssertLessThanOrEqual(store.notificationBody(row).count, 160)
    }

    func testTitleFallsBackToAgentWhenNoProject() {
        let store = StatusStore()
        var row = AgentRow(rowKey: "k", agent: .codex)
        row.waiting = true
        XCTAssertEqual(store.notificationTitle(row), "Codex")
    }
}

/// Every localized key must resolve in both languages.
final class L10nTests: XCTestCase {
    func testNoKeyIsBlankInEitherLanguage() {
        for key in L10n.Key.allCases {
            XCTAssertFalse(L10n.t(key, .en).isEmpty, "empty en string for \(key)")
            XCTAssertFalse(L10n.t(key, .zh).isEmpty, "empty zh string for \(key)")
        }
    }

    func testFormatSpecifiersMatchAcrossLanguages() {
        // A %d that exists in one language but not the other crashes String(format:).
        for key in L10n.Key.allCases {
            let en = L10n.t(key, .en)
            let zh = L10n.t(key, .zh)
            XCTAssertEqual(
                en.components(separatedBy: "%d").count,
                zh.components(separatedBy: "%d").count,
                "%d count differs for \(key)"
            )
            XCTAssertEqual(
                en.components(separatedBy: "%@").count,
                zh.components(separatedBy: "%@").count,
                "%@ count differs for \(key)"
            )
        }
    }

    func testDurationUnitsAreLocalized() {
        XCTAssertNotEqual(L10n.t(.durMin, .en), L10n.t(.durMin, .zh), "zh tray showed English units")
    }
}
