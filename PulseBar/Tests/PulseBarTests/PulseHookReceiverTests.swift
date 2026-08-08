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
        XCTAssertTrue(text.hasPrefix(AttentionIO.header.trimmingCharacters(in: .newlines)) || text.contains("Pulse attention log"))
    }

    func testPermissionEventFromClaudeJSON() throws {
        let stdin = #"{"hook_event_name":"PermissionRequest","message":"Edit file","session_id":"c1"}"#
        _ = PulseHookReceiver.run(arguments: ["--hook", "claude"], stdin: stdin)
        let text = try String(contentsOf: AttentionIO.path, encoding: .utf8)
        XCTAssertTrue(text.contains("claude\tpermission\t"))
        XCTAssertTrue(text.contains("\tEdit file\tc1\t"))
    }

    func testSelfTestDoesNotNeedPython() {
        let result = HooksSupport.selfTest()
        guard case .passed = result else {
            XCTFail("native self-test must pass without Python: \(result)")
            return
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
