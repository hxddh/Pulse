import XCTest
@testable import PulseBar

final class StatusLampTests: XCTestCase {
    func testStatusBarLampsKeepTheirStateColors() {
        let states: [GlanceKind] = [.waiting, .running, .idle, .stalled]
        for state in states {
            XCTAssertFalse(
                PulseBrand.statusBarIcon(for: state).isTemplate,
                "\(state) must not be recolored by the menu bar"
            )
        }

        let waiting = PulseBrand.statusColor(for: .waiting).usingColorSpace(.deviceRGB)!
        let running = PulseBrand.statusColor(for: .running).usingColorSpace(.deviceRGB)!
        let stalled = PulseBrand.statusColor(for: .stalled).usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(waiting.redComponent, waiting.greenComponent)
        XCTAssertGreaterThan(running.greenComponent, running.redComponent)
        XCTAssertGreaterThan(stalled.redComponent, stalled.blueComponent)
        XCTAssertGreaterThan(stalled.greenComponent, stalled.blueComponent)
    }
}

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
        warpRunning: true, ttyHostRunning: true
    )

    func testWarpWins_WhenProcessRunsUnderWarp() {
        let tier = TerminalFocus.focusTier(tty: "ttys003", viaWarp: true, env: fullEnv)
        XCTAssertEqual(tier, .warp, "TTY tab select does not work inside Warp")
    }

    func testTTYIsNotAdvertisedBecauseItWouldRequestAutomationPermission() {
        let env = TerminalFocus.Environment(
            warpRunning: false, ttyHostRunning: true
        )
        XCTAssertNil(
            TerminalFocus.focusTier(tty: "ttys003", viaWarp: false, env: env),
            "a real TTY is still not permission-free focus"
        )
    }

    func testCwdDoesNotPretendToBeAFocusHandle() {
        let env = TerminalFocus.Environment(
            warpRunning: false, ttyHostRunning: false
        )
        XCTAssertNil(TerminalFocus.focusTier(tty: "ttys003", viaWarp: false, env: env))
    }

    func testNoHandleMeansNoFocusButtonAtAll() {
        let env = TerminalFocus.Environment(
            warpRunning: false, ttyHostRunning: false
        )
        XCTAssertNil(TerminalFocus.focusTier(tty: "", viaWarp: false, env: env))
    }

    func testPlaceholderTTYValuesAreNotRealHandles() {
        let env = TerminalFocus.Environment(
            warpRunning: false, ttyHostRunning: true
        )
        for placeholder in ["", "?", "??", "-"] {
            XCTAssertNil(
                TerminalFocus.focusTier(tty: placeholder, viaWarp: false, env: env),
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
    func testEverySupportedAgentHasACanonicalProcessSignature() {
        let samples: [(AgentID, String)] = [
            (.claude, "/Users/me/.local/bin/claude"),
            (.codex, "/opt/homebrew/bin/codex app-server"),
            (.cursor, "/Applications/Cursor.app/Contents/MacOS/Cursor"),
            (.cursorAgent, "/Users/me/.local/bin/cursor-agent"),
            (.grok, "/Users/me/.grok/bin/grok"),
            (.pi, "pi"),
            (.amp, "amp"),
            (.aider, "aider"),
            (.gemini, "gemini"),
            (.copilot, "/opt/homebrew/bin/copilot"),
            (.opencode, "opencode"),
            (.goose, "goose"),
            (.openhands, "openhands"),
            (.cline, "/tmp/saoudrizwan.claude-dev/cline"),
            (.roo, "roo"),
            (.continue_, "continue"),
            (.amazonQ, "/opt/homebrew/bin/q chat"),
            (.cascade, "/tmp/cascade-agent"),
            (.windsurf, "/Applications/Windsurf.app/Contents/MacOS/Windsurf"),
            (.augment, "augment"),
            (.zedAgent, "/tmp/zed-agent"),
            (.trae, "/tmp/trae-agent"),
            (.warpAgent, "/tmp/warp-agent"),
            (.devin, "devin"),
            (.kiro, "kiro"),
            (.junie, "junie"),
            (.kilo, "kilo"),
            (.replit, "replit"),
            (.droid, "droid"),
            (.commandCode, "cmd"),
            (.antigravity, "/Applications/Antigravity.app/Contents/MacOS/Antigravity"),
            (.kimi, "kimi"),
        ]

        XCTAssertEqual(samples.count, AgentID.allCases.count)
        XCTAssertEqual(Set(samples.map(\.0)), Set(AgentID.allCases))
        for (agent, argv) in samples {
            XCTAssertEqual(ProcessProbe.match(args: argv), agent, "\(agent.displayName): \(argv)")
        }
    }

    func testProcessMatchExplainsRuleWithoutKeepingArgv() {
        XCTAssertEqual(
            ProcessProbe.matchEvidence(args: "/Applications/Antigravity.app/Contents/MacOS/Antigravity")?.evidence,
            .pathSignature
        )
        XCTAssertEqual(ProcessProbe.matchEvidence(args: "amp")?.evidence, .executable)
    }

    func testShortAgentNamesDoNotReintroduceKnownFalsePositives() {
        let falsePositives = [
            "/usr/bin/pip install pulse",
            "/usr/local/bin/pip3",
            "/usr/sbin/pihole",
            "/System/Library/PrivateFrameworks/AMPDevices.framework/AMPDeviceDiscoveryAgent",
            "/opt/android/droidcam",
            "/opt/android/cmdline-tools",
        ]
        for argv in falsePositives {
            XCTAssertNil(ProcessProbe.match(args: argv), argv)
        }
    }

    func testParsesProcessElapsedTimeWithoutCallingItSessionAge() {
        XCTAssertEqual(ProcessProbe.parseElapsed("04:12"), 252)
        XCTAssertEqual(ProcessProbe.parseElapsed("02:04:12"), 7_452)
        XCTAssertEqual(ProcessProbe.parseElapsed("3-02:04:12"), 266_652)
        XCTAssertEqual(ProcessProbe.parseElapsed("not-a-time"), 0)
    }

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

    func testWorkingDirectoryParserKeepsEachPidAttachedToItsCwd() {
        let output = """
        p101
        fcwd
        n/Users/me/code/Pulse
        p202
        fcwd
        n/Users/me/code/Other
        """
        XCTAssertEqual(ProcessProbe.parseWorkingDirectories(output)[101], "/Users/me/code/Pulse")
        XCTAssertEqual(ProcessProbe.parseWorkingDirectories(output)[202], "/Users/me/code/Other")
    }

    func testWorkingDirectoryFilterRejectsInfrastructurePaths() {
        XCTAssertEqual(ProcessProbe.usefulWorkingDirectory("/"), "")
        XCTAssertEqual(ProcessProbe.usefulWorkingDirectory("/Applications/Pulse.app"), "")
        XCTAssertEqual(ProcessProbe.usefulWorkingDirectory("/Users/me/code/Pulse"), "/Users/me/code/Pulse")
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
