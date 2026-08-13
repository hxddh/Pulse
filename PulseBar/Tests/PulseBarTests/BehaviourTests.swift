import XCTest
import AppKit
@testable import PulseBar

@MainActor
final class StatusPanelChromeTests: XCTestCase {
    func testRoundedMaterialOwnsItsShadowInsideATransparentWindow() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 444, height: 204),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        let root = NSView(frame: panel.contentView?.bounds ?? .zero)
        let shadow = NSView(frame: root.bounds.insetBy(
            dx: StatusPanelChrome.shadowInset,
            dy: StatusPanelChrome.shadowInset
        ))
        let effect = NSVisualEffectView(frame: shadow.frame)
        root.addSubview(shadow)
        root.addSubview(effect)
        panel.contentView = root

        StatusPanelChrome.apply(
            to: panel,
            rootView: root,
            shadowView: shadow,
            effectView: effect
        )

        XCTAssertFalse(panel.hasShadow, "WindowServer shadow is rectangular for this panel")
        XCTAssertEqual(effect.layer?.cornerRadius, StatusPanelChrome.cornerRadius)
        XCTAssertTrue(effect.layer?.masksToBounds == true)
        XCTAssertEqual(shadow.layer?.cornerRadius, StatusPanelChrome.cornerRadius)
        XCTAssertNotNil(shadow.layer?.shadowPath)
        XCTAssertGreaterThan(shadow.layer?.shadowOpacity ?? 0, 0)
        let background = root.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
        XCTAssertEqual(background?.alphaComponent, 0)

        root.layoutSubtreeIfNeeded()
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
            return XCTFail("window root did not produce a visual regression bitmap")
        }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let corners = [
            (0, 0),
            (bitmap.pixelsWide - 1, 0),
            (0, bitmap.pixelsHigh - 1),
            (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1),
        ]
        for (x, y) in corners {
            XCTAssertLessThan(
                bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 1,
                0.01,
                "the AppKit window root leaked an opaque square corner"
            )
        }
    }
}

final class StatusLampTests: XCTestCase {
    func testTrayIdentityGridKeepsSectionLampAndRowLampOnOneColumn() {
        XCTAssertEqual(
            TrayChrome.sectionAccentPrefix + TrayChrome.padX,
            TrayChrome.rowIdentityStart,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TrayChrome.rowIdentityStart
                + TrayChrome.identityLampSize
                + TrayChrome.identityLampToNameGap,
            TrayChrome.rowNameStart,
            accuracy: 0.001
        )
    }

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
        // Idle machines should not harvest every probe tick — empty cadence is
        // already ~30s; multiplying ticks keeps the menu bar cheap.
        XCTAssertGreaterThan(ProbeSchedule.harvestEveryNTicks(activity: .empty, trayOpen: false), 1)
        XCTAssertEqual(ProbeSchedule.harvestEveryNTicks(activity: .empty, trayOpen: true), 1)
    }
}

/// Focus honesty: never claim a TTY we cannot select.
final class FocusTierTests: XCTestCase {
    private let fullEnv = TerminalFocus.Environment(
        warpRunning: true, ttyHostRunning: true, allowTTYAutomation: true
    )

    func testWarpWins_WhenProcessRunsUnderWarp() {
        let tier = TerminalFocus.focusTier(tty: "ttys003", viaWarp: true, env: fullEnv)
        XCTAssertEqual(tier, .warp, "TTY tab select does not work inside Warp")
    }

    func testHostAppIsAdvertisedWithoutAutomation() {
        let env = TerminalFocus.Environment(
            warpRunning: false, ttyHostRunning: false, allowTTYAutomation: false
        )
        XCTAssertEqual(
            TerminalFocus.focusTier(
                tty: "", viaWarp: false, hostApp: .cursor, env: env
            ),
            .hostApp(.cursor)
        )
        XCTAssertEqual(
            TerminalFocus.focusTier(
                tty: "ttys003", viaWarp: false, hostApp: .vsCode, env: env
            ),
            .hostApp(.vsCode)
        )
    }

    func testAbsoluteWorkspacePromotesHostWorkspaceTier() {
        let env = TerminalFocus.Environment(
            warpRunning: false, ttyHostRunning: false, allowTTYAutomation: false
        )
        XCTAssertEqual(
            TerminalFocus.focusTier(
                tty: "",
                viaWarp: false,
                hostApp: .cursor,
                workspace: "/Users/me/code/Pulse",
                env: env
            ),
            .hostWorkspace(.cursor)
        )
        XCTAssertEqual(
            TerminalFocus.focusTier(
                tty: "",
                viaWarp: false,
                hostApp: .zed,
                workspace: "/",
                env: env
            ),
            .hostApp(.zed),
            "root is not a usable workspace advertisement"
        )
        XCTAssertFalse(TerminalFocus.isAbsoluteWorkspacePath(""))
        XCTAssertFalse(TerminalFocus.isAbsoluteWorkspacePath("relative/path"))
        XCTAssertTrue(TerminalFocus.isAbsoluteWorkspacePath("/Users/me/proj"))
    }

    func testWarpBeatsHostApp() {
        let env = TerminalFocus.Environment(
            warpRunning: true, ttyHostRunning: false, allowTTYAutomation: false
        )
        XCTAssertEqual(
            TerminalFocus.focusTier(
                tty: "", viaWarp: true, hostApp: .cursor, workspace: "/Users/me/p", env: env
            ),
            .warp
        )
    }

    func testTTYIsNotAdvertisedUntilAutomationOptIn() {
        let off = TerminalFocus.Environment(
            warpRunning: false, ttyHostRunning: true, allowTTYAutomation: false
        )
        XCTAssertNil(
            TerminalFocus.focusTier(tty: "ttys003", viaWarp: false, env: off),
            "default off — never advertise TTY before Shortcuts opt-in"
        )
        let on = TerminalFocus.Environment(
            warpRunning: false, ttyHostRunning: true, allowTTYAutomation: true
        )
        XCTAssertEqual(
            TerminalFocus.focusTier(tty: "ttys003", viaWarp: false, env: on),
            .tty
        )
    }

    func testCwdDoesNotPretendToBeAFocusHandle() {
        let env = TerminalFocus.Environment(
            warpRunning: false, ttyHostRunning: false, allowTTYAutomation: false
        )
        XCTAssertNil(TerminalFocus.focusTier(tty: "ttys003", viaWarp: false, env: env))
    }

    func testNoHandleMeansNoFocusButtonAtAll() {
        let env = TerminalFocus.Environment(
            warpRunning: false, ttyHostRunning: false, allowTTYAutomation: false
        )
        XCTAssertNil(TerminalFocus.focusTier(tty: "", viaWarp: false, env: env))
    }

    func testPlaceholderTTYValuesAreNotRealHandles() {
        let env = TerminalFocus.Environment(
            warpRunning: false, ttyHostRunning: true, allowTTYAutomation: true
        )
        for placeholder in ["", "?", "??", "-"] {
            XCTAssertNil(
                TerminalFocus.focusTier(tty: placeholder, viaWarp: false, env: env),
                "\(placeholder) should not count as a TTY"
            )
        }
    }

    func testFocusHostAppActionCopyIsProductNameNotGenericTerminal() {
        let enApp = L10n.t(.focusHostApp, .en)
        XCTAssertEqual(String(format: enApp, HostAppKind.cursor.displayName), "Focus Cursor (app)")
        let enWs = L10n.t(.focusHostWorkspace, .en)
        XCTAssertEqual(String(format: enWs, HostAppKind.zed.displayName), "Open workspace in Zed")
        XCTAssertEqual(L10n.t(.focusWarp, .en), "Focus Warp (app)")
        let zh = L10n.t(.focusHostApp, .zh)
        XCTAssertEqual(String(format: zh, "Cursor"), "聚焦 Cursor（应用）")
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
        for junk in [
            "-", "—", "Running", "Active", "none", "Agent session", "Chat",
            "Amp session", "OpenCode session", "Windsurf session", "Cline session",
        ] {
            let r = row { $0.task = junk }
            XCTAssertNil(r.usefulTask, "\(junk) is not a real session title")
        }
    }

    func testBarePathIsNotASessionTitle() {
        XCTAssertNil(row { $0.task = "/Users/me/code" }.usefulTask)
        XCTAssertNotNil(row { $0.task = "/Users/me fix the parser" }.usefulTask)
    }

    func testMarkdownLinksBecomeReadablePlainTitles() {
        let raw = "[hxddh/Pulse](https://github.com/hxddh/Pulse) 本地有安装最新版"
        let r = row { $0.task = raw }
        XCTAssertEqual(r.usefulTask, "hxddh/Pulse 本地有安装最新版")
        XCTAssertEqual(r.task, raw, "presentation cleanup must not rewrite evidence")
    }

    func testMarkdownImageSyntaxDoesNotLeakIntoTheTray() {
        XCTAssertEqual(
            row { $0.task = "Inspect ![failure](file:///tmp/failure.png)" }.usefulTask,
            "Inspect failure"
        )
    }

    func testLiveRowWithToolButNoTaskFallsBackToTool() {
        // Raw tool is never a session title; it remains a live-tool fallback
        // that the tray humanizes into the hero.
        let r = row {
            $0.liveProcess = true
            $0.tool = "Bash"
        }
        XCTAssertNil(r.sessionDetail)
        XCTAssertNil(r.usefulTask)
        XCTAssertTrue(r.hasLiveToolFallback)
        XCTAssertFalse(r.isProcessOnly, "a known tool is more than 'process detected'")
    }

    func testInternalToolIdentifiersAreNotSessionTitles() {
        XCTAssertNil(row {
            $0.task = "update_plan"
            $0.tool = "update_plan"
        }.usefulTask)
        XCTAssertEqual(row { $0.task = "update_auth" }.usefulTask, "update_auth")
        XCTAssertNil(row { $0.task = "Read Models.swift" }.usefulTask)
        XCTAssertNil(row { $0.task = "Models.swift" }.usefulTask)
        XCTAssertNotNil(row { $0.task = "Improve tray density" }.usefulTask)
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
            (.antigravity, "/Users/me/.local/bin/agy"),
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
            (.kimi, "kimi"),
            (.zcode, "/Applications/ZCode.app/Contents/MacOS/ZCode"),
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
        XCTAssertEqual(
            ProcessProbe.match(args: "⌘ Command Code · rustji COLORTERM=truecolor"),
            .commandCode,
            "process titles rewritten by Node must still identify Command Code"
        )
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
        XCTAssertNil(
            ProcessProbe.match(args: "/Users/me/.local/bin/cursor-agent worker start --worker-dir /Users/me/code/Pulse"),
            "Cursor's persistent worker is infrastructure until a composer session provides activity"
        )
        XCTAssertNil(
            ProcessProbe.match(args: "Cursor --type=renderer --app-path=/Applications/Cursor.app/Contents/Resources/app"),
            "Cursor helper processes must not inflate the GUI fallback count"
        )
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
