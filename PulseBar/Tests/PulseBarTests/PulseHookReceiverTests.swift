import CryptoKit
import XCTest
@testable import PulseBar

final class PulseHookReceiverTests: XCTestCase {
    private var tempHome: URL!
    private let now: Int64 = 1_800_000_000_000

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-hook-recv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        AttentionIO.pathOverride = tempHome.appendingPathComponent("attention.tsv")
        // Every test in this class must be isolated from the developer's real
        // Respond spool: a run() with a permission payload would otherwise
        // read (and on an opted-in machine, write) the real one.
        RespondSpool.rootOverride = tempHome.appendingPathComponent("respond.d", isDirectory: true)
    }

    override func tearDownWithError() throws {
        AttentionIO.pathOverride = nil
        RespondSpool.rootOverride = nil
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

    // MARK: - Respond hold (Mac-to-Mac parity with pulse_hook.py)

    private func writeRespondSecret(_ key: String = "sekrit\n") throws {
        try Data(key.utf8).write(to: tempHome.appendingPathComponent("respond-secret.key"))
    }

    private func writeVerdictFile(
        id: String, digest: String, host: String, allow: Bool, key: String = "sekrit"
    ) throws {
        let directory = tempHome.appendingPathComponent("respond.d/verdicts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let decided = now
        let expires = now + 90_000
        let message = "v1\n\(id)\n\(digest)\nclaude\n\(host)\n\(allow ? "allow" : "deny")\n\(decided)\n\(expires)"
        let hmac = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8), using: SymmetricKey(data: Data(key.utf8))
        ).map { String(format: "%02x", $0) }.joined()
        let object: [String: Any] = [
            "v": 1, "request_id": id, "digest": digest, "agent": "claude", "host": host,
            "allow": allow,
            "decided_at_ms": NSNumber(value: decided),
            "expires_at_ms": NSNumber(value: expires),
            "hmac": hmac,
        ]
        try JSONSerialization.data(withJSONObject: object)
            .write(to: directory.appendingPathComponent("\(id).json"))
    }

    private func permissionPayload(id: String = "toolu_x") -> [String: Any] {
        [
            "hook_event_name": "PermissionRequest",
            "tool_use_id": id,
            "tool_name": "Bash",
            "tool_input": ["command": "ls"],
            "session_id": "s1",
            "cwd": "/w",
        ]
    }

    func testHoldForVerdictClaimsAnExistingVerdictImmediately() throws {
        try writeRespondSecret()
        let digest = RespondDigest.of(Data("x".utf8))
        try writeVerdictFile(id: "toolu_h", digest: digest, host: "agentbox", allow: false)
        var sleeps = 0
        let allow = PulseHookReceiver.holdForVerdict(
            requestID: "toolu_h", digest: digest, agent: "claude", host: "agentbox",
            truncated: false, deadlineMs: now + 60_000,
            clockMs: { self.now }, sleepMs: { _ in sleeps += 1 }
        )
        XCTAssertEqual(allow, false)
        XCTAssertEqual(sleeps, 0, "a verdict already on disk must not cost a single sleep")
    }

    func testHoldForVerdictTimesOutOnAFakeClockWithoutRealWaiting() {
        var clock = now
        var sleeps = 0
        let allow = PulseHookReceiver.holdForVerdict(
            requestID: "toolu_none", digest: "d", agent: "claude", host: "agentbox",
            truncated: false, deadlineMs: now + 60_000,
            clockMs: { clock },
            sleepMs: { ms in
                sleeps += 1
                clock += Int64(ms)
            }
        )
        XCTAssertNil(allow)
        XCTAssertEqual(sleeps, 60_000 / 250, "60 s deadline at 250 ms per poll")
    }

    func testRespondDecisionJSONAnswersWithTheFrozenShape() throws {
        try writeRespondSecret()
        let payload = permissionPayload()
        let raw = try JSONSerialization.data(withJSONObject: payload)
        let digest = RespondDigest.of(raw)
        // The verdict is already there: the first poll claims it.
        try writeVerdictFile(id: "toolu_x", digest: digest, host: "agentbox", allow: true)
        var sleeps = 0
        let decision = PulseHookReceiver.respondDecisionJSON(
            agent: "claude", kind: "permission", payload: payload, rawStdin: raw,
            idleSeconds: 10_000,
            environment: ["PULSE_HOST": "agentbox"],
            clockMs: { self.now }, sleepMs: { _ in sleeps += 1 }
        )
        XCTAssertEqual(
            decision,
            "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\","
                + "\"decision\":{\"behavior\":\"allow\",\"message\":\"Answered via Pulse from agentbox\"}}}"
        )
        XCTAssertEqual(sleeps, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: tempHome.appendingPathComponent("respond.d/requests/toolu_x.json").path
            ),
            "the request must be spooled for the sync tool before the hold"
        )
    }

    func testRespondDecisionJSONTimesOutSilently() throws {
        try writeRespondSecret()
        let payload = permissionPayload()
        let raw = try JSONSerialization.data(withJSONObject: payload)
        var clock = now
        let decision = PulseHookReceiver.respondDecisionJSON(
            agent: "claude", kind: "permission", payload: payload, rawStdin: raw,
            idleSeconds: 10_000, environment: [:],
            clockMs: { clock },
            sleepMs: { ms in clock += Int64(ms) }
        )
        XCTAssertNil(decision, "a timeout leaves the vendor's own prompt in charge")
    }

    /// The regression the presence gate exists to prevent: freezing an agent
    /// in front of the person whose own prompt was about to appear anyway.
    func testRespondHoldIsSkippedWhenSomeoneIsAtThisMac() throws {
        try writeRespondSecret()
        let payload = permissionPayload()
        let raw = try JSONSerialization.data(withJSONObject: payload)
        let decision = PulseHookReceiver.respondDecisionJSON(
            agent: "claude", kind: "permission", payload: payload, rawStdin: raw,
            idleSeconds: 0, environment: [:],
            clockMs: { self.now },
            sleepMs: { _ in XCTFail("a present user must never cost a sleep") }
        )
        XCTAssertNil(decision)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tempHome.appendingPathComponent("respond.d/requests/toolu_x.json").path
            ),
            "a present user's request must not even be spooled"
        )
    }

    func testRespondStaysSilentWithoutTheOptInKey() throws {
        let payload = permissionPayload()
        let raw = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertNil(PulseHookReceiver.respondDecisionJSON(
            agent: "claude", kind: "permission", payload: payload, rawStdin: raw,
            idleSeconds: 10_000, environment: [:],
            clockMs: { self.now },
            sleepMs: { _ in XCTFail("no key must mean no hold") }
        ))
    }

    func testHoldAndAwayEnvKnobsAreClamped() {
        XCTAssertEqual(PulseHookReceiver.maxHoldSeconds(environment: [:]), 60)
        XCTAssertEqual(
            PulseHookReceiver.maxHoldSeconds(environment: ["PULSE_RESPOND_MAX_HOLD_SECONDS": "1"]), 5
        )
        XCTAssertEqual(
            PulseHookReceiver.maxHoldSeconds(environment: ["PULSE_RESPOND_MAX_HOLD_SECONDS": "900"]), 300
        )
        XCTAssertEqual(
            PulseHookReceiver.maxHoldSeconds(environment: ["PULSE_RESPOND_MAX_HOLD_SECONDS": "abc"]), 60
        )
        XCTAssertEqual(
            PulseHookReceiver.awayAfterSeconds(environment: [:]),
            RespondHold.defaultAwayAfterSeconds
        )
        XCTAssertEqual(
            PulseHookReceiver.awayAfterSeconds(environment: ["PULSE_RESPOND_AWAY_SECONDS": "5"]), 30
        )
        XCTAssertEqual(
            PulseHookReceiver.awayAfterSeconds(environment: ["PULSE_RESPOND_AWAY_SECONDS": "99999"]),
            3600
        )
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

        let previous = HooksInstaller.permissionRequestTimeoutSeconds
        defer { HooksInstaller.permissionRequestTimeoutSeconds = previous }
        HooksInstaller.permissionRequestTimeoutSeconds = 45
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
