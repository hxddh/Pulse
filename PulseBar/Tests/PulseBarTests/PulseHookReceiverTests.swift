import XCTest
@testable import PulseBar

final class PulseHookReceiverTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-hook-recv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        AttentionIO.pathOverride = tempHome.appendingPathComponent("attention.tsv")
    }

    override func tearDownWithError() throws {
        AttentionIO.pathOverride = nil
        try? FileManager.default.removeItem(at: tempHome)
    }

    func testRequestUserInputBecomesIdlePrompt() {
        XCTAssertEqual(PulseHookReceiver.normalizeKind("request_user_input"), "idle_prompt")
        XCTAssertEqual(PulseHookReceiver.normalizeKind("exec_approval_request"), "permission")
        XCTAssertEqual(PulseHookReceiver.normalizeKind("agent-turn-complete"), "done")
        XCTAssertEqual(AttentionProtocol.normalizeKind("idle"), "idle_prompt")
        XCTAssertTrue(AttentionProtocol.acceptsWrite(kind: "permission"))
        XCTAssertFalse(AttentionProtocol.acceptsWrite(kind: "totally_made_up_kind"))
    }

    func testRunWritesFlockedAttentionLineWithoutPython() throws {
        let code = PulseHookReceiver.run(
            arguments: ["PulseBar", "--hook", "codex", "request_user_input"],
            stdin: #"{"message":"Approve shell","session_id":"sess-1","cwd":"/tmp/pulse"}"#
        )
        XCTAssertEqual(code, 0)
        let text = try String(contentsOf: AttentionIO.path, encoding: .utf8)
        XCTAssertTrue(text.contains("codex\tidle_prompt\t"))
        XCTAssertTrue(text.contains("\tApprove shell\tsess-1\t/tmp/pulse"))
        XCTAssertTrue(
            text.hasPrefix(AttentionProtocol.header.trimmingCharacters(in: .newlines)),
            "writer must stamp Attention Protocol v1 header"
        )
    }

    func testUnknownKindIsRejectedWithoutWrite() throws {
        let code = PulseHookReceiver.run(
            arguments: ["PulseBar", "--hook", "replit", "made_up_vendor_event"],
            stdin: #"{"message":"should not land","session_id":"x"}"#
        )
        XCTAssertEqual(code, 0, "vendor hooks must never block")
        XCTAssertFalse(FileManager.default.fileExists(atPath: AttentionIO.path.path))
        XCTAssertFalse(PulseHookReceiver.appendEvent(
            agent: "replit",
            kind: "made_up_vendor_event",
            message: "nope"
        ))
    }

    func testExternalRaiseBecomesAttentionWaiting() throws {
        XCTAssertTrue(PulseHookReceiver.appendEvent(
            agent: "replit",
            kind: "permission",
            message: "Approve deploy",
            session: "ext-1",
            cwd: "/tmp/ext"
        ))
        let text = try String(contentsOf: AttentionIO.path, encoding: .utf8)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let entries = AttentionReader.parse(text, nowMs: now)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, .replit)
        XCTAssertEqual(entries[0].kind, "Permission")
        XCTAssertEqual(entries[0].session, "ext-1")
        XCTAssertEqual(entries[0].message, "Approve deploy")
    }

    func testPermissionEventFromClaudeJSON() throws {
        let stdin = #"{"hook_event_name":"PermissionRequest","message":"Edit file","session_id":"c1"}"#
        _ = PulseHookReceiver.run(arguments: ["--hook", "claude"], stdin: stdin)
        let text = try String(contentsOf: AttentionIO.path, encoding: .utf8)
        XCTAssertTrue(text.contains("claude\tpermission\t"))
        XCTAssertTrue(text.contains("\tEdit file\tc1\t"))
    }

    func testSelfTestDoesNotNeedPython() {
        // Route seedAssets away from the real support dir: without this, the
        // self-test rewrote the user's actual hook-runner.path to the xctest
        // binary — breaking the machine's Waiting path until Pulse relaunches.
        HooksInstaller.homeOverride = tempHome
        defer { HooksInstaller.homeOverride = nil }
        let result = HooksSupport.selfTest()
        guard case .passed = result else {
            XCTFail("native self-test must pass without Python: \(result)")
            return
        }
    }

    func testRunnerPathRefusesTestHarnessBinaries() throws {
        // The guard behind the fix above: even when seeding runs in a test
        // process, hook-runner.path must never point at xctest.
        HooksInstaller.homeOverride = tempHome
        defer { HooksInstaller.homeOverride = nil }
        HooksInstaller.refreshRunnerPath()
        if let written = try? String(contentsOf: HooksInstaller.runnerPathURL, encoding: .utf8) {
            XCTAssertFalse(
                written.lowercased().contains("xctest"),
                "hook-runner.path must never point at a test harness binary"
            )
        }
    }
}

final class HooksInstallerTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-hooks-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        HooksInstaller.homeOverride = tempHome
    }

    override func tearDownWithError() throws {
        HooksInstaller.homeOverride = nil
        try? FileManager.default.removeItem(at: tempHome)
    }

    func testNativeInstallWritesClaudeAndCodexWithoutPython() throws {
        try HooksInstaller.ensureLauncher()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: HooksInstaller.launcherURL.path))

        _ = try HooksInstaller.install()
        let claude = try String(
            contentsOf: tempHome.appendingPathComponent(".claude/settings.json"),
            encoding: .utf8
        )
        XCTAssertTrue(claude.contains("pulse-hook"))
        XCTAssertFalse(claude.contains("pulse_hook.py"), "fresh install must prefer native launcher")
        XCTAssertTrue(claude.contains("PermissionRequest"))

        let codex = try String(
            contentsOf: tempHome.appendingPathComponent(".codex/config.toml"),
            encoding: .utf8
        )
        XCTAssertTrue(codex.contains("pulse-hook"))
        XCTAssertTrue(codex.contains("notify = "))

        XCTAssertEqual(HooksSupport.probeStatus(), .installedBoth)

        _ = try HooksInstaller.uninstall()
        let claudeAfter = try String(
            contentsOf: tempHome.appendingPathComponent(".claude/settings.json"),
            encoding: .utf8
        )
        XCTAssertFalse(HooksInstaller.containsPulseMarker(claudeAfter))
        XCTAssertEqual(HooksSupport.probeStatus(), .missing)
    }

    func testInstallMigratesLegacyPythonNotify() throws {
        let cfg = tempHome.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: cfg.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        model = "gpt"
        notify = ["python3", "/tmp/pulse_hook.py", "codex"]

        [mcp]
        enabled = true
        """.write(to: cfg, atomically: true, encoding: .utf8)

        try HooksInstaller.ensureLauncher()
        _ = try HooksInstaller.install()
        let text = try String(contentsOf: cfg, encoding: .utf8)
        XCTAssertTrue(text.contains("pulse-hook"))
        XCTAssertFalse(text.contains("pulse_hook.py"))
        // Root-table notify must stay before the first [section].
        let notifyIdx = try XCTUnwrap(text.range(of: "notify = "))
        let sectionIdx = try XCTUnwrap(text.range(of: "[mcp]"))
        XCTAssertLessThan(notifyIdx.lowerBound, sectionIdx.lowerBound)
    }

    func testRootTableEndFindsFirstSection() {
        let text = "a = 1\n\n[profile]\nx = 1\n"
        let end = HooksInstaller.rootTableEnd(text)
        XCTAssertEqual(String(text.prefix(end)).trimmingCharacters(in: .newlines), "a = 1")
    }

    func testInstallAndUninstallKeepUserHooksWithHookLikeTokens() throws {
        // Regression: pulseMarkers used to include a bare "--hook", so a
        // user's own `mytool --hook-dir …` entry was silently deleted by the
        // strip that runs on every install, and by uninstall.
        let settings = tempHome.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "command": "/usr/local/bin/mytool --hook-dir /tmp claude stop" } ] }
            ]
          }
        }
        """.write(to: settings, atomically: true, encoding: .utf8)

        try HooksInstaller.ensureLauncher()
        _ = try HooksInstaller.install()
        var text = try String(contentsOf: settings, encoding: .utf8)
        XCTAssertTrue(text.contains("--hook-dir"), "install must not delete the user's own hook entry")
        XCTAssertTrue(text.contains("pulse-hook"), "a user entry containing 'claude stop' must not suppress Pulse's own Stop entry")

        _ = try HooksInstaller.uninstall()
        text = try String(contentsOf: settings, encoding: .utf8)
        XCTAssertTrue(text.contains("--hook-dir"), "uninstall must not delete the user's own hook entry")
        XCTAssertFalse(text.contains("pulse-hook"))

        // Legacy direct-binary entries are still ours.
        XCTAssertTrue(HooksInstaller.containsPulseMarker(
            #"/Applications/Pulse.app/Contents/MacOS/PulseBar --hook claude"#
        ))
        XCTAssertFalse(HooksInstaller.containsPulseMarker("mytool --hook-dir /tmp"))
    }

    func testReinstallMigratesPulseEntriesToCurrentShape() throws {
        // Regression: ensureClaudeEvent used to early-return on a marker hit,
        // so an installed entry kept its old command and timeout forever.
        try HooksInstaller.ensureLauncher()
        _ = try HooksInstaller.install()

        let previous = HooksInstaller.claudeHookTimeoutSeconds
        defer { HooksInstaller.claudeHookTimeoutSeconds = previous }
        HooksInstaller.claudeHookTimeoutSeconds = 45
        _ = try HooksInstaller.install()

        let settings = tempHome.appendingPathComponent(".claude/settings.json")
        let data = try JSONSerialization.jsonObject(
            with: Data(contentsOf: settings)
        ) as? [String: Any]
        let hooks = data?["hooks"] as? [String: Any]
        let permission = hooks?["PermissionRequest"] as? [[String: Any]]
        XCTAssertEqual(permission?.count, 1, "re-install must not duplicate Pulse entries")
        let body = (permission?.first?["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(body?["timeout"] as? Int, 45, "re-install must migrate timeout to the current value")
    }

    func testInstallRefusesInvalidClaudeJSON() throws {
        let settings = tempHome.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not-json".write(to: settings, atomically: true, encoding: .utf8)
        try HooksInstaller.ensureLauncher()
        XCTAssertThrowsError(try HooksInstaller.install()) { error in
            let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(text.contains("refusing to rewrite"), text)
        }
        // Original untouched.
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "not-json")
    }
}
