import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

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

    func testV3SeparatesAQuestionFromYourTurn() {
        XCTAssertEqual(PulseHookReceiver.normalizeKind("request_user_input"), "question")
        XCTAssertEqual(PulseHookReceiver.normalizeKind("exec_approval_request"), "permission")
        // 16.0: a finished turn is "your turn", not a clear and not a wait.
        XCTAssertEqual(PulseHookReceiver.normalizeKind("agent-turn-complete"), "turn")
        XCTAssertEqual(AttentionProtocol.normalizeKind("idle"), "turn")
        XCTAssertEqual(AttentionProtocol.normalizeKind("idle_prompt"), "turn",
                       "Claude's idle_prompt is a 60 s timer after every finished turn")
        XCTAssertEqual(AttentionProtocol.normalizeKind("stop"), "turn")
        XCTAssertNotEqual(AttentionProtocol.kind("idle_prompt")?.isBlocking, true)
        XCTAssertEqual(AttentionProtocol.kind("elicitation_dialog")?.isBlocking, true)
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
        XCTAssertTrue(text.contains("codex\tquestion\t"))
        XCTAssertTrue(text.contains("\tApprove shell\tsess-1\t/tmp/pulse"))
        XCTAssertTrue(
            text.hasPrefix(AttentionProtocol.header.trimmingCharacters(in: .newlines)),
            "writer must stamp the current Attention Protocol header"
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

    // MARK: - A permission ask must say what is being asked

    /// Regression: Claude's PermissionRequest payload carries no `message`,
    /// and the receiver only looked for prose keys — so the banner, the row
    /// and Details all showed a bare "Permission" for the single most
    /// important event in the product.
    func testPermissionRequestNamesTheToolAndItsTarget() throws {
        let stdin = #"""
        {"hook_event_name":"PermissionRequest","tool_use_id":"toolu_a","tool_name":"Bash",
         "tool_input":{"command":"npm run build"},"session_id":"c9","cwd":"/w"}
        """#
        _ = PulseHookReceiver.run(arguments: ["--hook", "claude"], stdin: stdin)
        let text = try String(contentsOf: AttentionIO.path, encoding: .utf8)
        XCTAssertTrue(text.contains("\tBash: npm run build\t"), text)
    }

    func testFilePathAndURLAreNamedWhenThereIsNoCommand() {
        XCTAssertEqual(
            PulseHookReceiver.toolDescriptor(from: [
                "tool_name": "Edit", "tool_input": ["file_path": "/repo/src/main.swift"],
            ]),
            "Edit: /repo/src/main.swift"
        )
        XCTAssertEqual(
            PulseHookReceiver.toolDescriptor(from: [
                "tool_name": "WebFetch", "tool_input": ["url": "https://example.com/x"],
            ]),
            "WebFetch: https://example.com/x"
        )
        // A tool with nothing nameable is still better than silence.
        XCTAssertEqual(
            PulseHookReceiver.toolDescriptor(from: ["tool_name": "MultiEdit", "tool_input": ["edits": []]]),
            "MultiEdit"
        )
        XCTAssertEqual(PulseHookReceiver.toolDescriptor(from: ["tool_input": ["command": "ls"]]), "")
    }

    func testDescriptorFoldsAndBoundsWhatItShows() {
        XCTAssertEqual(
            PulseHookReceiver.condenseOneLine("git commit \\\n  -m  'two   lines'"),
            "git commit \\ -m 'two lines'"
        )
        let long = PulseHookReceiver.condenseOneLine(String(repeating: "x", count: 400))
        XCTAssertEqual(long.count, 140)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testACredentialInsideACommandIsStillRedacted() throws {
        let stdin = #"""
        {"hook_event_name":"PermissionRequest","tool_use_id":"toolu_b","tool_name":"Bash",
         "tool_input":{"command":"curl -H 'Authorization: Bearer abcdefgh12345678' https://x"},
         "session_id":"c10"}
        """#
        _ = PulseHookReceiver.run(arguments: ["--hook", "claude"], stdin: stdin)
        let text = try String(contentsOf: AttentionIO.path, encoding: .utf8)
        XCTAssertTrue(text.contains("Bash: curl"), text)
        XCTAssertFalse(text.contains("abcdefgh12345678"), "naming the ask must not leak the secret in it")
    }

    // MARK: - 23.0: nothing is held, every line is a full v3 record

    func testAPermissionRequestIsWrittenAndNeverHeld() throws {
        let stdin = #"{"hook_event_name":"PermissionRequest","tool_use_id":"toolu_x","tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"s1","cwd":"/w"}"#
        let started = Date()
        let code = PulseHookReceiver.run(arguments: ["--hook", "claude"], stdin: stdin)
        XCTAssertEqual(code, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the receiver exits at once")
        let text = try String(contentsOf: AttentionIO.path, encoding: .utf8)
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("claude\t") })
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
        XCTAssertEqual(columns.count, AttentionProtocol.columnCount)
        XCTAssertEqual(columns[1], "permission")
        XCTAssertEqual(columns[6], "", "the host column is written empty")
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

    /// 19.0: the self-check reads what the real installer wrote and calls
    /// it complete — so a new event added to one and not the other fails here.
    func testTheSelfCheckRecognisesAFreshInstall() throws {
        _ = try HooksInstaller.install()
        let facts = DoctorProbe.gather(home: tempHome, nowMs: 1_800_000_000_000)
        XCTAssertEqual(facts.claudeHookEvents, Set(DoctorModel.claudeEvents))
        XCTAssertTrue(DoctorModel.matcherTokens.allSatisfy { facts.claudeNotificationMatcher?.contains($0) == true })
        XCTAssertEqual(facts.codexHookEvents, Set(DoctorModel.codexEvents))
        XCTAssertFalse(facts.codexPermissionHook)
        XCTAssertTrue(facts.codexNotifyInstalled)

        let report = DoctorModel.evaluate(facts, lang: .en)
        XCTAssertEqual(report.checks.first { $0.id == "claude-hooks" }?.verdict, .works)
        XCTAssertEqual(report.checks.first { $0.id == "codex-hooks" }?.verdict, .unproven,
                       "installed is not trusted: only a fired event proves Codex runs them")

        _ = try HooksInstaller.uninstall()
        let after = DoctorProbe.gather(home: tempHome, nowMs: 1_800_000_000_000)
        XCTAssertTrue(after.claudeHookEvents.isEmpty)
        XCTAssertTrue(after.codexHookEvents.isEmpty)
    }

    func testNativeInstallWritesClaudeAndCodex() throws {
        try HooksInstaller.ensureLauncher()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: HooksInstaller.launcherURL.path))

        _ = try HooksInstaller.install()
        let claude = try String(
            contentsOf: tempHome.appendingPathComponent(".claude/settings.json"),
            encoding: .utf8
        )
        XCTAssertTrue(claude.contains("pulse-hook"))
        XCTAssertTrue(claude.contains("PermissionRequest"))
        // 2.9: the hook finally speaks about work, not just waits.
        XCTAssertTrue(claude.contains("PreToolUse"))
        XCTAssertTrue(claude.contains("UserPromptSubmit"))

        let codex = try String(
            contentsOf: tempHome.appendingPathComponent(".codex/config.toml"),
            encoding: .utf8
        )
        XCTAssertTrue(codex.contains("pulse-hook"))
        XCTAssertTrue(codex.contains("notify = "))
        // 18.0: Codex hooks — Stop and UserPromptSubmit, never PermissionRequest.
        let codexHooks = try String(contentsOf: HooksInstaller.codexHooksURL, encoding: .utf8)
        XCTAssertTrue(codexHooks.contains("\"Stop\""))
        XCTAssertTrue(codexHooks.contains("\"UserPromptSubmit\""))
        XCTAssertFalse(codexHooks.contains("PermissionRequest"),
                       "Codex fires it before auto-review: it is not proof anyone is asked")
        XCTAssertTrue(codexHooks.contains("pulse-hook"))
        // 18.0: Claude questions and failed turns reach Pulse.
        XCTAssertTrue(claude.contains("elicitation_dialog"))
        XCTAssertTrue(claude.contains("StopFailure"))

        XCTAssertEqual(HooksSupport.probeStatus(), .installedBoth)

        _ = try HooksInstaller.uninstall()
        let claudeAfter = try String(
            contentsOf: tempHome.appendingPathComponent(".claude/settings.json"),
            encoding: .utf8
        )
        XCTAssertFalse(HooksInstaller.containsPulseMarker(claudeAfter))
        XCTAssertFalse(HooksInstaller.containsPulseMarker(
            try String(contentsOf: HooksInstaller.codexHooksURL, encoding: .utf8)
        ))
        XCTAssertEqual(HooksSupport.probeStatus(), .missing)
    }

    func testInstallNeverOverwritesTheUsersOwnCodexNotify() throws {
        let cfg = tempHome.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: cfg.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = """
        model = "gpt"
        notify = [
          "terminal-notifier",
          "-title", "Codex",
        ]

        [mcp]
        enabled = true

        """
        try original.write(to: cfg, atomically: true, encoding: .utf8)

        try HooksInstaller.ensureLauncher()
        _ = try HooksInstaller.install()
        XCTAssertEqual(try String(contentsOf: cfg, encoding: .utf8), original, "their notify is theirs")
    }

    func testInstallWritesThroughASymlinkedSettingsFile() throws {
        let real = tempHome.appendingPathComponent("dotfiles/settings.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}\n".write(to: real, atomically: true, encoding: .utf8)
        let settings = tempHome.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: real)

        try HooksInstaller.ensureLauncher()
        _ = try HooksInstaller.install()
        let attributes = try FileManager.default.attributesOfItem(atPath: settings.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink, "the link survives")
        XCTAssertTrue(try String(contentsOf: real, encoding: .utf8).contains("pulse-hook"))
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
