import Foundation
import SQLite3
import Testing
import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

// Attention: the reader and protocol, the hook receiver and activity spool, the hooks installer, `claude agents`.

final class AttentionReaderTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000

    /// Rows are padded to the eight v3 columns (host and front empty).
    private func tsv(_ rows: [[String]]) -> String {
        rows.map { row in
            (row + Array(repeating: "", count: max(0, AttentionProtocol.columnCount - row.count)))
                .joined(separator: "\t")
        }.joined(separator: "\n") + "\n"
    }

    func testLastEventWinsPerSession() {
        let text = tsv([
            ["claude", "permission", "\(now - 5000)", "first", "s1", "/p"],
            ["claude", "question", "\(now - 1000)", "second", "s1", "/p"],
        ])
        let entries = AttentionReader.parse(text, nowMs: now)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].kind, "Input")
        XCTAssertEqual(entries[0].message, "second")
    }

    func testDoneClearsTheSession() {
        let text = tsv([
            ["claude", "permission", "\(now - 5000)", "approve", "s1", "/p"],
            ["claude", "done", "\(now - 1000)", "", "s1", ""],
        ])
        XCTAssertTrue(AttentionReader.parse(text, nowMs: now).isEmpty)
    }

    /// 23.0 bug: dismissing a session-less hook wait wrote a session-less
    /// `done`, which cleared every session of that agent — the other
    /// terminals' permissions went dark with them. A `done` clears exactly
    /// what it names: an empty session, only the session-less entry.
    func testASessionlessDoneClearsOnlyTheSessionlessEntry() {
        let text = tsv([
            ["claude", "permission", "\(now - 5000)", "a", "s1", "/p"],
            ["claude", "permission", "\(now - 4000)", "b", "s2", "/q"],
            ["claude", "permission", "\(now - 3000)", "c", "", "/r"],
            ["claude", "done", "\(now - 1000)", "", "", ""],
        ])
        let entries = AttentionReader.parse(text, nowMs: now)
        let sessions = Set(entries.map(\.session))
        XCTAssertEqual(sessions, ["s1", "s2"], "the sessions' own waits stay")
    }

    func testStopKeepsAFreshPermissionWithinGrace() {
        // The order of Claude's events is not ours; a turn ending moments
        // after a permission was raised must not wipe it.
        let text = tsv([
            ["claude", "permission", "\(now - 1000)", "approve", "s1", "/p"],
            ["claude", "stop", "\(now)", "", "s1", ""],
        ])
        let entries = AttentionReader.parse(text, nowMs: now)
        XCTAssertEqual(entries.count, 1, "recent permission survives a Stop")
    }

    func testStopClearsAnAgedPermissionAndLeavesYourTurn() {
        let old = now - AttentionReader.stopGraceMs - 5000
        let text = tsv([
            ["claude", "permission", "\(old)", "approve", "s1", "/p"],
            ["claude", "stop", "\(now)", "", "s1", ""],
        ])
        let entries = AttentionReader.parse(text, nowMs: now)
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].isTurn)
        XCTAssertFalse(entries[0].isBlocking, "the permission is gone; what is left is not red")
    }

    func testExpiredEntriesAreDropped() {
        let stale = now - AttentionReader.ttlMs - 1
        let text = tsv([["claude", "permission", "\(stale)", "old", "s1", "/p"]])
        XCTAssertTrue(AttentionReader.parse(text, nowMs: now).isEmpty)
    }

    func testSubagentEventsNeverRaiseWaiting() {
        let text = tsv([["claude", "subagent_start", "\(now)", "", "s1", "/p"]])
        XCTAssertTrue(AttentionReader.parse(text, nowMs: now).isEmpty)
    }

    func testUnknownKindNeverRaisesWaiting() {
        let text = tsv([["replit", "totally_fake_kind", "\(now)", "nope", "s1", "/p"]])
        XCTAssertTrue(
            AttentionReader.parse(text, nowMs: now).isEmpty,
            "free-text kinds must never light Waiting"
        )
    }

    func testProtocolHeaderIsIgnoredAsComment() {
        let text = AttentionProtocol.header + tsv([
            ["junie", "waiting", "\(now - 1000)", "Need choice", "j1", "/w"],
        ])
        let entries = AttentionReader.parse(text, nowMs: now)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, .junie)
        XCTAssertEqual(entries[0].kind, "Waiting")
    }

    func testCommentsAndShortRowsAreSkipped() {
        let text = "# header\nclaude\tpermission\n\n"
        XCTAssertTrue(AttentionReader.parse(text, nowMs: now).isEmpty)
    }

    /// 23.0: v3 needs all eight columns. A v1 (six-column) or v2
    /// (seven-column) line is not read.
    func testAnOlderShorterLineIsNotRead() {
        let v1 = "claude\tpermission\t\(now - 1000)\tapprove\ts1\t/p\n"
        let v2 = "claude\tpermission\t\(now - 1000)\tapprove\ts1\t/p\t\n"
        XCTAssertTrue(AttentionReader.parse(v1, nowMs: now).isEmpty)
        XCTAssertTrue(AttentionReader.parse(v2, nowMs: now).isEmpty)
        let v3 = "claude\tpermission\t\(now - 1000)\tapprove\ts1\t/p\t\t\n"
        XCTAssertEqual(AttentionReader.parse(v3, nowMs: now).count, 1)
    }

    func testALaterSilentEventDoesNotEraseTheReason() throws {
        // One approval makes Claude raise both Notification and
        // PermissionRequest; only one carries text and the order is not ours.
        // Last-write-wins alone turned a named ask back into a bare kind.
        let text = tsv([
            ["claude", "permission", "\(now - 2000)", "Bash: npm run build", "c1", "/w"],
            ["claude", "permission", "\(now - 1000)", "", "c1", "/w"],
        ])
        let entries = AttentionReader.parse(text, nowMs: now)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].message, "Bash: npm run build")
        XCTAssertEqual(entries[0].tsMs, now - 1000, "the newer event still owns the clock")
    }

    func testNormalizeTimestampParsesVendorISO8601() {
        // Regression: the fractional-second form is what Claude and Pi
        // actually write; it used to parse to 0, so every record fell back to
        // file mtime and per-record ordering inside one file collapsed.
        XCTAssertEqual(
            NativeActivityHarvest.normalizeTimestamp("2024-12-03T14:00:01.000Z"),
            1_733_234_401_000
        )
        XCTAssertEqual(
            NativeActivityHarvest.normalizeTimestamp("2024-12-03T14:00:01Z"),
            1_733_234_401_000
        )
        XCTAssertEqual(
            NativeActivityHarvest.normalizeTimestamp("2024-12-03T14:00:01.250Z"),
            1_733_234_401_250
        )
        // T-separated without zone, and the legacy space-separated forms.
        XCTAssertEqual(
            NativeActivityHarvest.normalizeTimestamp("2024-12-03T14:00:01.000"),
            1_733_234_401_000
        )
        XCTAssertEqual(
            NativeActivityHarvest.normalizeTimestamp("2024-12-03 14:00:01"),
            1_733_234_401_000
        )
        // Numbers keep their seconds/milliseconds heuristic.
        XCTAssertEqual(NativeActivityHarvest.normalizeTimestamp(1_733_234_401), 1_733_234_401_000)
        XCTAssertEqual(NativeActivityHarvest.normalizeTimestamp("garbage"), 0)
    }

    // MARK: - 2.2 · `incomplete` is not `complete`

    /// Regression (B-13): `isCompleted` matched substrings, so the vendor
    /// word **`incomplete`** satisfied `contains("complete")` and a run that
    /// had explicitly not finished was classified as finished. A row that
    /// says "done" about work still going is the one direction of this error
    /// that costs the user something.
    func testIncompleteIsNotMistakenForCompleted() {
        var row = ActivityHarvest.Row(id: .codex, task: "", project: "", cwd: "", skill: "")
        for state in ["incomplete", "not_completed", "never completed"] {
            row.phase = state
            row.outcome = ""
            XCTAssertFalse(row.isCompleted, "\(state) is the opposite of completed")
            row.phase = ""
            row.outcome = state
            XCTAssertFalse(row.isCompleted, "\(state) is the opposite of completed")
        }
        // The shapes vendors actually write still classify.
        row.outcome = ""
        for phase in ["turn_complete", "task_complete", "completed", "complete", "cancelled", "canceled"] {
            row.phase = phase
            XCTAssertTrue(row.isCompleted, phase)
        }
        row.phase = ""
        row.outcome = "failed"
        XCTAssertTrue(row.isCompleted)
    }

    // MARK: - 2.2 · one shared root, one lamp — across scans

    /// Regression (B-9 / `H-M3`): Cascade and Windsurf read the same
    /// `~/.windsurf` tree, and the rule that Windsurf yields to Cascade lived
    /// inside a single complete scan. A rotating adapter cursor, a tripped
    /// collector or a scoped rescan all deliver Windsurf's fresh rows while
    /// Cascade's rows are merely *retained* — and the same pending session
    /// then lit two red lamps, which is precisely what 0.95 exists to prevent.
    func testWindsurfDoesNotLightBesideARetainedCascadeRow() {
        let cascade = ActivityHarvest.Row(
            id: .cascade,
            task: "Approve the edit",
            project: "Pulse",
            cwd: "/Users/me/Pulse",
            skill: "pending",
            harvestMs: 1_700_000_000_000,
            sessionID: "shared-1"
        )
        let windsurf = ActivityHarvest.Row(
            id: .windsurf,
            task: "Approve the edit",
            project: "Pulse",
            cwd: "/Users/me/Pulse",
            skill: "pending",
            harvestMs: 1_700_000_000_500,
            sessionID: "shared-1"
        )
        // This pass reached Windsurf only; Cascade was never reported, so its
        // row survives the partial merge.
        let health = [ActivityHarvest.CollectorHealth(
            id: .windsurf,
            state: .observed,
            durationMs: 8,
            rowCount: 1,
            sourcePresent: true,
            errorKind: ""
        )]

        let merged = ActivityHarvest.mergePartialRows(
            current: [windsurf],
            health: health,
            previous: [cascade]
        )
        XCTAssertEqual(
            merged.map(\.id), [.cascade],
            "one session, one lamp — the shell adapter yields to Cascade"
        )
    }

    /// The other half of the same rule: with no Cascade row anywhere, the
    /// Windsurf shell row is the only evidence there is and must stay.
    func testWindsurfSurvivesWhenCascadeHasNoRow() {
        let windsurf = ActivityHarvest.Row(
            id: .windsurf,
            task: "Approve the edit",
            project: "Pulse",
            cwd: "/Users/me/Pulse",
            skill: "pending",
            harvestMs: 1_700_000_000_500,
            sessionID: "shared-2"
        )
        let health = [ActivityHarvest.CollectorHealth(
            id: .windsurf,
            state: .observed,
            durationMs: 8,
            rowCount: 1,
            sourcePresent: true,
            errorKind: ""
        )]
        let merged = ActivityHarvest.mergePartialRows(
            current: [windsurf], health: health, previous: []
        )
        XCTAssertEqual(merged.map(\.sessionID), ["shared-2"])
    }

    // MARK: - 2.2 · the stop grace

    /// Claude emits `Stop` right after a permission prompt; a Stop inside
    /// the grace window must not put the lamp out while the agent waits.
    func testAStopInsideTheGraceKeepsThePermission() throws {
        let now: Int64 = 1_700_000_000_000
        let raised = now - 60_000
        let text = [
            "claude\tpermission\t\(raised)\tBash: npm run build\tsession-9\t/Users/me/Pulse\t\t",
            "claude\tstop\t\(raised + 1)\t\tsession-9\t\t\t",
        ].joined(separator: "\n") + "\n"
        let entries = AttentionReader.parse(text, nowMs: now)
        let entry = try XCTUnwrap(entries.first, "the permission survived its own Stop")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entry.kind, "Permission")
    }

    /// `attention.tsv` is this Mac's file. A value in the `host` column
    /// makes no separate wait — the same session with or without it is one
    /// wait, and one `done` clears it.
    func testTheHostColumnIsIgnored() {
        let now: Int64 = 1_700_000_000_000
        let raised = now - 60_000
        let text = [
            "claude\tpermission\t\(raised)\tBash: make\tsession-1\t/x\tbox\t",
            "claude\tdone\t\(raised + 1_000)\t\tsession-1\t/x\t\t",
        ].joined(separator: "\n") + "\n"
        XCTAssertTrue(AttentionReader.parse(text, nowMs: now).isEmpty)
        let raisedOnly = "claude\tpermission\t\(raised)\tBash: make\tsession-1\t/x\tbox\t\n"
        XCTAssertEqual(AttentionReader.parse(raisedOnly, nowMs: now).map(\.mapKey), ["claude|session-1"])
    }

    /// And the grace still expires on the clock it is measured against: a
    /// permission that really has been open past the window is cleared —
    /// and since 16.0 what is left is "your turn", never a blocked wait.
    func testAStopStillClearsAPermissionPastTheGraceWindow() {
        let now: Int64 = 1_700_000_000_000
        let old = now - 60_000
        let text = [
            "claude\tpermission\t\(old)\tBash: npm run build\tsession-10\t/Users/me/Pulse\t\t",
            // The Stop itself lands past the window: the grace is measured
            // between the two lines, not against the reader's clock.
            "claude\tstop\t\(old + AttentionReader.stopGraceMs + 1)\t\tsession-10\t\t\t",
        ].joined(separator: "\n") + "\n"
        let entries = AttentionReader.parse(text, nowMs: now)
        XCTAssertFalse(entries.contains(where: \.isBlocking))
        XCTAssertEqual(entries.map(\.isTurn), [true])
    }
}

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
        XCTAssertEqual(AttentionProtocol.normalizeKind("request_user_input"), "question")
        XCTAssertEqual(AttentionProtocol.normalizeKind("exec_approval_request"), "permission")
        // 16.0: a finished turn is "your turn", not a clear and not a wait.
        XCTAssertEqual(AttentionProtocol.normalizeKind("agent-turn-complete"), "turn")
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

    /// 23.0 bug: a hook call that named no kind — no argv kind, no
    /// `notification_type`, no event — was written as `waiting` and lit the
    /// red lamp. Empty is rejected like any unknown kind.
    func testAnEmptyKindIsRejectedWithoutWrite() throws {
        let code = PulseHookReceiver.run(
            arguments: ["PulseBar", "--hook", "replit"],
            stdin: #"{"message":"says nothing about what it is","session_id":"x"}"#
        )
        XCTAssertEqual(code, 0, "vendor hooks must never block")
        XCTAssertFalse(FileManager.default.fileExists(atPath: AttentionIO.path.path))
        XCTAssertEqual(PulseHookReceiver.parseKind(from: ["message": "hello"]), "")
        XCTAssertEqual(AttentionProtocol.normalizeKind(""), "")
        XCTAssertEqual(AttentionProtocol.normalizeKind("   "), "")
        XCTAssertFalse(AttentionProtocol.acceptsWrite(kind: ""))
        XCTAssertFalse(PulseHookReceiver.appendEvent(agent: "replit", kind: "", message: "nope"))
        let line = "replit\t\t\(Int64(Date().timeIntervalSince1970 * 1000))\tnope\tx\t/p\t\t\n"
        XCTAssertTrue(
            AttentionReader.parse(line, nowMs: Int64(Date().timeIntervalSince1970 * 1000)).isEmpty,
            "a line with an empty kind column is not Waiting either"
        )
    }

    /// Codex `notify` hands its JSON as the last argument; stdin is then not
    /// read at all, so a pipe nobody closes cannot hold the hook.
    func testAPayloadInArgvSkipsStdin() {
        XCTAssertTrue(PulseHookReceiver.payloadInArguments(
            ["pulse-hook", "--hook", "codex", #"{"type":"agent-turn-complete"}"#]
        ))
        XCTAssertFalse(PulseHookReceiver.payloadInArguments(["pulse-hook", "--hook", "claude"]))
        XCTAssertFalse(PulseHookReceiver.payloadInArguments(["pulse-hook", "--hook", "junie", "permission"]))
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
        let before = AttentionIO.pathOverride
        let result = HooksSupport.selfTest()
        guard case .passed = result else {
            XCTFail("native self-test must pass without Python: \(result)")
            return
        }
        // 23.0: it writes its own temporary file, passed explicitly — the
        // global path a scan reads is never redirected, even for a moment.
        XCTAssertEqual(AttentionIO.pathOverride, before)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: AttentionIO.path.path),
            "the self-test's lines never reach the attention file a scan reads"
        )
    }

    /// 23.0 bug: the file was decoded strictly, so one invalid byte (a hook
    /// cut off mid-character) read as an empty file — every wait vanished.
    func testOneBadByteDoesNotHideEveryWait() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var bytes = Data(AttentionIO.header.utf8)
        bytes.append(Data("claude\tpermission\t\(now - 1_000)\tBash: make\ts1\t/p\t\t\n".utf8))
        bytes.append(contentsOf: [0x63, 0x6C, 0xE2, 0x82, 0x0A]) // "cl" + a truncated "€"
        try bytes.write(to: AttentionIO.path)
        let text = AttentionIO.readText()
        XCTAssertFalse(text.isEmpty)
        let entries = AttentionReader.parse(text, nowMs: now)
        XCTAssertEqual(entries.map(\.session), ["s1"])
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

/// Re-arming attention.tsv used to tear down every other watch with it
/// (U-4). Since 22.0 removed the remote inbox the other watch is the
/// activity spool, and the rule is the same: each watch re-arms alone.
final class AttentionWatcherReArmTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        AttentionIO.pathOverride = home.appendingPathComponent("attention.tsv")
    }

    override func tearDownWithError() throws {
        AttentionIO.pathOverride = nil
        try? FileManager.default.removeItem(at: home)
    }

    func testReArmingTheFileWatchLeavesTheActivityWatchAlone() {
        let watcher = AttentionWatcher()
        defer { watcher.stop() }
        watcher.start(onChange: {}, onActivity: {})
        XCTAssertTrue(watcher.isWatchingFile)
        XCTAssertTrue(watcher.isWatchingActivity)

        // What the delete/rename handler does after an atomic replace — which
        // is what every hook write looks like from the outside.
        watcher.arm()
        XCTAssertTrue(watcher.isWatchingFile)
        XCTAssertTrue(
            watcher.isWatchingActivity,
            "activity.d/ must keep waking Pulse after attention.tsv is replaced"
        )
    }

    func testReArmingTheActivityWatchLeavesTheFileWatchAlone() {
        let watcher = AttentionWatcher()
        defer { watcher.stop() }
        watcher.start(onChange: {}, onActivity: {})
        watcher.armActivity()
        XCTAssertTrue(watcher.isWatchingFile)
        XCTAssertTrue(watcher.isWatchingActivity)
    }

    /// A deleted file cannot be reopened, so the watch would have stayed dead
    /// for the life of the process.
    func testAFileThatWasDeletedIsRecreatedAndWatchedAgain() throws {
        let watcher = AttentionWatcher()
        defer { watcher.stop() }
        watcher.start {}
        let file = try XCTUnwrap(AttentionIO.pathOverride)
        try FileManager.default.removeItem(at: file)

        watcher.arm()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(watcher.isWatchingFile)
    }

    func testStopTearsDownEveryWatch() {
        let watcher = AttentionWatcher()
        watcher.start(onChange: {}, onActivity: {})
        watcher.stop()
        XCTAssertFalse(watcher.isWatchingFile)
        XCTAssertFalse(watcher.isWatchingActivity)
    }
}

/// 16.0 · Turn — vendor event sequences, from the attention file to the lamp.
///
/// 18.0: Swift Testing. Every sequence is one row of `TurnTruthTests.cases`
/// and one named test in the report, so a failing vendor order reads as
/// "claude · finished turn → your turn, not red" rather than as one assertion
/// buried in a hundred-line method. Each row is a sequence of lines exactly as
/// the hooks write them, read by the real reader and merged by the real
/// builder; the expectations are what the user would see.
@Suite("Turn truth table", .serialized)
struct TurnTruthTests {
    static let now: Int64 = 1_800_000_000_000
    static let second: Int64 = 1_000

    static func line(
        _ agent: String, _ kind: String, ago: Int64, message: String = "",
        session: String = "s1", cwd: String = "/p", front: String? = nil
    ) -> String {
        // v3: all eight columns; host empty, front as given (empty = unknown).
        let cols = [agent, kind, "\(now - ago)", message, session, cwd, "", front ?? ""]
        return cols.joined(separator: "\t")
    }

    static func session(_ id: AgentID, _ session: String = "s1", ageMs: Int64 = 70_000) -> ActivityHarvest.Row {
        ActivityHarvest.Row(
            id: id, task: "Fix the login flow", project: "p", cwd: "/p", skill: "",
            tool: "", harvestMs: now - ageMs, subRunning: 0, subTotal: 0, sessionID: session,
            evidence: .session
        )
    }

    static func world(
        _ lines: [String],
        harvest: [ActivityHarvest.Row],
        activity: [ActivitySpool.Event] = []
    ) -> SnapshotBuilder.Result {
        let text = AttentionProtocol.header + lines.joined(separator: "\n") + "\n"
        let entries = AttentionReader.parse(text, nowMs: now)
        return SnapshotBuilder.build(
            SnapshotBuilder.Input(procs: [], harvest: harvest, attention: entries, activity: activity),
            previous: .init(),
            context: SnapshotBuilder.Context(
                nowMs: now,
                terminal: TerminalFocus.Environment(warpRunning: false, ttyHostRunning: false),
                lang: .en,
                maxSessionsPerAgent: SnapshotBuilder.maxSessionsPerAgent,
                maxVisibleRows: SnapshotBuilder.maxVisibleRows,
                dismissedPendingKeys: [],
                showAllAgents: false,
                stalledSeconds: AgentRow.stalledSeconds
            )
        )
    }

    static func delivery(_ rows: [AgentRow]) -> WaitingDelivery.Plan {
        WaitingDelivery(
            muted: [], acknowledged: [], inFlight: [], canDeliverNow: true,
            msSinceLastNotification: 60_000, minimumIntervalMs: 0
        ).plan(rows)
    }

    // MARK: - The table

    /// What the user should see after a sequence.
    struct Expect: Sendable {
        var waiting: Bool
        var yourTurn: Bool
        var red: Bool
        var banner: Bool
        var waitKind: String? = nil
        var inFront: Bool = false
    }

    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var lines: [String]
        var agent: AgentID = .claude
        var harvestAgeMs: Int64 = 70_000
        var expect: Expect
        var testDescription: String { name }
    }

    static let blocked = Expect(waiting: true, yourTurn: false, red: true, banner: true)
    static let turn = Expect(waiting: false, yourTurn: true, red: false, banner: false)
    static let quiet = Expect(waiting: false, yourTurn: false, red: false, banner: false)

    static let cases: [Case] = [
        Case(
            name: "claude · finished turn, idle_prompt a minute later → your turn, not red",
            lines: [
                line("claude", "permission", ago: 180 * second, message: "Bash: npm test"),
                line("claude", "stop", ago: 61 * second),
                line("claude", "idle_prompt", ago: 1 * second),
            ],
            expect: turn
        ),
        Case(
            name: "claude · permission → red, banner",
            lines: [line("claude", "permission", ago: 5 * second, message: "Bash: rm -rf build")],
            expect: Expect(waiting: true, yourTurn: false, red: true, banner: true, waitKind: "Permission")
        ),
        Case(
            name: "claude · elicitation question → red, says Input",
            lines: [line("claude", "elicitation_dialog", ago: 5 * second, message: "Which database?")],
            expect: Expect(waiting: true, yourTurn: false, red: true, banner: true, waitKind: "Input")
        ),
        Case(
            name: "claude · URL elicitation (18.0) → red, says Input",
            lines: [line("claude", "elicitation_url_dialog", ago: 5 * second, message: "Sign in to continue")],
            expect: Expect(waiting: true, yourTurn: false, red: true, banner: true, waitKind: "Input")
        ),
        Case(
            name: "claude · turn ends moments after a permission → the permission stands",
            lines: [
                line("claude", "permission", ago: 6 * second, message: "Bash: npm run build"),
                line("claude", "stop", ago: 1 * second),
            ],
            expect: blocked
        ),
        Case(
            name: "claude · turn watched finishing (front = 1) → nothing owed",
            lines: [line("claude", "turn", ago: 2 * second, front: "1")],
            expect: quiet
        ),
        Case(
            name: "claude · submitted prompt after a turn → cleared",
            lines: [line("claude", "stop", ago: 30 * second), line("claude", "done", ago: 2 * second)],
            expect: quiet
        ),
        Case(
            name: "claude · transcript grew well after the turn → work resumed",
            lines: [line("claude", "stop", ago: 60 * second)],
            harvestAgeMs: 10 * second,
            expect: quiet
        ),
        Case(
            name: "claude · vendor's last write right after Stop → still your turn",
            lines: [line("claude", "stop", ago: 60 * second)],
            harvestAgeMs: 55 * second,
            expect: turn
        ),
        Case(
            name: "claude · StopFailure (18.0) → your turn, never red",
            lines: [line("claude", "stop_failure", ago: 10 * second, message: "rate_limit")],
            expect: turn
        ),
        Case(
            name: "codex · agent-turn-complete → your turn",
            lines: [line("codex", "agent-turn-complete", ago: 10 * second)],
            agent: .codex,
            expect: turn
        ),
        Case(
            name: "codex · exec approval → red",
            lines: [line("codex", "exec_approval_request", ago: 3 * second, message: "git push")],
            agent: .codex,
            expect: blocked
        ),
        Case(
            name: "presence · blocked prompt already in front → lamp, no banner",
            lines: [line("claude", "permission", ago: 2 * second, message: "Bash: ls", front: "1")],
            expect: Expect(waiting: true, yourTurn: false, red: true, banner: false, inFront: true)
        ),
        Case(
            name: "presence · unknown → banner as usual",
            lines: [line("claude", "permission", ago: 2 * second, message: "Bash: ls", front: "")],
            expect: blocked
        ),
        Case(
            name: "legacy · an older hook's idle_prompt line reads as your turn",
            lines: [line("claude", "idle_prompt", ago: 2 * second)],
            expect: turn
        ),
    ]

    /// 23.0: a finished turn is grey even while its CLI stays open — the
    /// green ring is for a session that is working, and "your turn" is not.
    @Test func aFinishedTurnWithALiveProcessIsAGreyLamp() throws {
        let text = AttentionProtocol.header + Self.line("claude", "turn", ago: 2 * Self.second, front: "") + "\n"
        let entries = AttentionReader.parse(text, nowMs: Self.now)
        let r = SnapshotBuilder.build(
            SnapshotBuilder.Input(
                procs: [ProcessProbe.Hit(id: .claude, count: 1, viaWarp: false, pid: 42)],
                harvest: [Self.session(.claude)],
                attention: entries
            ),
            previous: .init(),
            context: SnapshotBuilder.Context(
                nowMs: Self.now,
                terminal: TerminalFocus.Environment(warpRunning: false, ttyHostRunning: false),
                lang: .en
            )
        )
        let row = try #require(r.rows.first)
        #expect(row.isYourTurn)
        #expect(row.liveProcess)
        #expect(r.snapshot.glance == .idle)
        #expect(r.snapshot.lamp == LampFace(shape: .hollow, tone: .idle))
        #expect(r.snapshot.title == "")
        #expect(r.snapshot.tooltip == L10n.t(.lampRuleTurn, .en))
    }

    @Test(arguments: cases)
    func sequence(_ c: Case) throws {
        let r = Self.world(c.lines, harvest: [Self.session(c.agent, ageMs: c.harvestAgeMs)])
        let row = try #require(r.rows.first)
        #expect(row.isBlocked == c.expect.waiting)
        #expect(row.isYourTurn == c.expect.yourTurn)
        #expect((r.snapshot.glance == .waiting) == c.expect.red)
        let turns = r.rows.filter { $0.isYourTurn }.count
        #expect(turns == (c.expect.yourTurn ? 1 : 0))
        #expect((row.wait?.inFront ?? false) == c.expect.inFront)
        if let kind = c.expect.waitKind { #expect(row.wait?.kind == kind) }
        let bannered: Bool
        if case .post(let rows, _) = Self.delivery(r.rows) {
            bannered = rows.contains { $0.rowKey == row.rowKey }
        } else {
            bannered = false
        }
        #expect(bannered == c.expect.banner)
    }

    // MARK: - Beyond the table

    @Test func aToolCallAfterTheTurnEndsYourTurn() throws {
        let tool = ActivitySpool.Event(
            agent: "claude", session: "s1", event: "tool", tool: "Edit", target: "a.swift",
            prompt: "", cwd: "/p", tsMs: Self.now - 5 * Self.second
        )
        let r = Self.world([Self.line("claude", "stop", ago: 30 * Self.second)], harvest: [Self.session(.claude)], activity: [tool])
        let row = try #require(r.rows.first)
        #expect(!row.isYourTurn)
    }

    @Test func aFinishedTurnNeverInventsARow() {
        let r = Self.world([Self.line("claude", "stop", ago: 5 * Self.second, session: "unknown")], harvest: [])
        #expect(r.rows.isEmpty, "a row made only of 'it finished' would have no other evidence")
    }

    @Test func theReceiverWritesTheV3Kinds() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-turn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        AttentionIO.pathOverride = home.appendingPathComponent("attention.tsv")
        ActivitySpool.directoryOverride = home.appendingPathComponent("activity.d", isDirectory: true)
        defer {
            AttentionIO.pathOverride = nil
            ActivitySpool.directoryOverride = nil
            try? FileManager.default.removeItem(at: home)
        }
        #expect(PulseHookReceiver.parseKind(from: ["hook_event_name": "Stop"]) == "turn")
        #expect(PulseHookReceiver.parseKind(from: ["hook_event_name": "StopFailure"]) == "stop_failure")
        #expect(PulseHookReceiver.parseKind(from: ["hook_event_name": "SubagentStop"]) == "subagent_stop")

        // The installed Claude Stop hook passes `stop` explicitly.
        PulseHookReceiver.run(arguments: ["PulseBar", "--hook", "claude", "stop"],
                              stdin: #"{"session_id":"s1","cwd":"/p","last_assistant_message":"All tests pass."}"#)
        PulseHookReceiver.run(arguments: ["PulseBar", "--hook", "claude", "prompt"],
                              stdin: #"{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/p","prompt":"next"}"#)
        let lines = try String(contentsOf: AttentionIO.path, encoding: .utf8)
            .split(separator: "\n").filter { !$0.hasPrefix("#") }
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
        #expect(lines.map { String($0[1]) } == ["turn", "done"])
        #expect(lines.allSatisfy { $0.count == AttentionProtocol.columnCount })
        #expect(String(lines[0][3]) == "All tests pass.")
    }

    @Test func everyKindHasOneMeaning() {
        for kind in AttentionKind.allCases {
            #expect(AttentionProtocol.kind(kind.rawValue) == kind)
        }
        #expect(AttentionKind.allCases.filter(\.isBlocking) == [.permission, .question, .waiting])
        #expect(!AttentionKind.turn.isBlocking)
        #expect(AttentionKind.turn.isOpen)
    }
}

/// 18.0 · Claude's own report of who is waiting (`claude agents --json`).
@Suite("Claude agents probe")
struct ClaudeAgentsProbeTests {
    let now: Int64 = 1_800_000_000_000

    // MARK: - Parse

    @Test func aTopLevelArrayOrAWrappedListParses() throws {
        let array = #"[{"sessionId":"s1","pid":4242,"cwd":"/p","status":"waiting","waitingFor":"permission prompt","kind":"interactive"}]"#
        let wrapped = #"{"agents":[{"sessionId":"s2","pid":7,"cwd":"/q","status":"busy"}]}"#
        #expect(try #require(ClaudeAgentsProbe.parse(Data(array.utf8))).first?.waitingFor == "permission prompt")
        #expect(try #require(ClaudeAgentsProbe.parse(Data(wrapped.utf8))).first?.sessionID == "s2")
        #expect(ClaudeAgentsProbe.parse(Data("Unknown command: agents".utf8)) == nil, "an older claude is no answer, not an empty fleet")
    }

    @Test(arguments: [
        ("waiting", "permission prompt", AttentionKind?.some(.permission)),
        ("waiting", "sandbox request", .some(.permission)),
        ("waiting", "input needed", .some(.question)),
        ("waiting", "dialog open", .some(.waiting)),
        ("blocked", "worker request", .some(.waiting)),
        ("busy", "permission prompt", nil),
        ("idle", "", nil),
    ])
    func onlyAWaitingStatusIsAWait(status: String, waitingFor: String, expected: AttentionKind?) {
        #expect(ClaudeAgentsProbe.kind(status: status, waitingFor: waitingFor) == expected)
    }

    @Test func aWaitKeepsTheTimePulseFirstSawIt() {
        let agent = ClaudeAgentsProbe.Agent(sessionID: "s1", pid: 1, cwd: "/p", status: "waiting", waitingFor: "permission prompt")
        let first = ClaudeAgentsProbe.waits([agent], previous: [], nowMs: now)
        let later = ClaudeAgentsProbe.waits([agent], previous: first, nowMs: now + 60_000)
        #expect(later.first?.sinceMs == now, "the vendor gives no stamp; the wait's age must not reset every sample")
    }

    // MARK: - The ration

    @Test func itRunsOnlyWhereItAddsSomethingAndNotTooOften() {
        var state = ClaudeAgentsProbe.State()
        #expect(!ClaudeAgentsProbe.shouldRun(state: state, nowMs: now, claudeLive: false, hooksInstalled: false))
        #expect(!ClaudeAgentsProbe.shouldRun(state: state, nowMs: now, claudeLive: true, hooksInstalled: true),
                "the hooks already say it, sooner")
        #expect(ClaudeAgentsProbe.shouldRun(state: state, nowMs: now, claudeLive: true, hooksInstalled: false))
        state.lastRunMs = now
        #expect(!ClaudeAgentsProbe.shouldRun(state: state, nowMs: now + 5_000, claudeLive: true, hooksInstalled: false))
        #expect(ClaudeAgentsProbe.shouldRun(state: state, nowMs: now + ClaudeAgentsProbe.minIntervalMs, claudeLive: true, hooksInstalled: false))
    }

    @Test func repeatedFailuresBackOffAndClearTheWaits() {
        var state = ClaudeAgentsProbe.State()
        state.waits = [ClaudeAgentsProbe.Wait(sessionID: "s1", pid: 1, cwd: "", kind: .permission, reason: "", sinceMs: now)]
        for index in 0..<ClaudeAgentsProbe.failuresBeforeBackoff {
            ClaudeAgentsProbe.record(nil, into: &state, nowMs: now + Int64(index))
        }
        #expect(state.waits.isEmpty, "no answer is never 'still waiting'")
        #expect(state.disabledUntilMs > now)
        #expect(!ClaudeAgentsProbe.shouldRun(state: state, nowMs: now + ClaudeAgentsProbe.minIntervalMs * 2, claudeLive: true, hooksInstalled: false))
    }

    // MARK: - Into the tray

    private func build(_ waits: [ClaudeAgentsProbe.Wait], attention: [AttentionReader.Entry] = [], dismissed: Set<String> = []) -> SnapshotBuilder.Result {
        let row = ActivityHarvest.Row(
            id: .claude, task: "Fix the login flow", project: "p", cwd: "/p", skill: "", tool: "",
            harvestMs: now - 30_000, subRunning: 0, subTotal: 0, sessionID: "s1", evidence: .session
        )
        return SnapshotBuilder.build(
            SnapshotBuilder.Input(harvest: [row], attention: attention, vendorWaits: waits),
            previous: .init(),
            context: SnapshotBuilder.Context(
                nowMs: now,
                terminal: TerminalFocus.Environment(warpRunning: false, ttyHostRunning: false),
                lang: .en,
                maxSessionsPerAgent: SnapshotBuilder.maxSessionsPerAgent,
                maxVisibleRows: SnapshotBuilder.maxVisibleRows,
                dismissedPendingKeys: dismissed,
                showAllAgents: false,
                stalledSeconds: AgentRow.stalledSeconds
            )
        )
    }

    private var permissionWait: ClaudeAgentsProbe.Wait {
        ClaudeAgentsProbe.Wait(sessionID: "s1", pid: 0, cwd: "/p", kind: .permission, reason: "permission prompt", sinceMs: now - 90_000)
    }

    @Test func aVendorReportedWaitLightsTheLampAndSaysSo() throws {
        let r = build([permissionWait])
        let row = try #require(r.rows.first)
        #expect(row.isBlocked)
        #expect(row.wait?.kind == "Permission")
        #expect(row.wait?.signal == .vendor)
        #expect(row.wait?.sinceMs == now - 90_000)
        #expect(r.snapshot.glance == .waiting)
        let explain = Explain.make(row, lang: .en, nowMs: now)
        #expect(explain.why.hasPrefix("Claude itself"))
        #expect(explain.ask == "permission prompt", "Claude's own words are the ask")
    }

    @Test func aHookRaiseForTheSameSessionWins() throws {
        let hook = AttentionReader.Entry(id: .claude, kind: "Input", message: "Which DB?", tsMs: now - 1_000, session: "s1", cwd: "/p")
        let row = try #require(build([permissionWait], attention: [hook]).rows.first)
        #expect(row.wait?.signal == .hooks)
        #expect(row.wait?.kind == "Input")
    }

    @Test func aDismissedVendorWaitStaysQuietAndNoRowIsInvented() throws {
        let key = try #require(build([]).rows.first).rowKey
        let dismissed = try #require(build([permissionWait], dismissed: [key]).rows.first)
        #expect(!dismissed.isBlocked)
        var stranger = permissionWait
        stranger.sessionID = "someone-else"
        #expect(build([stranger]).rows.count == 1, "a report with no row has no other evidence")
        let strangerRow = try #require(build([stranger]).rows.first)
        #expect(!strangerRow.isBlocked)
    }
}

/// 2.9 Quality — second-grade freshness, and the measurement measuring itself.
///
/// The hook has stood in the vendor's event stream since 1.0, but only for
/// waits. These tests hold the new deal for activity events: state not
/// ledger, never a wait, present tense only inside the live window — and the
/// yield rules that stop "the agent is idle" and "Pulse stopped seeing" from
/// wearing the same clothes.
final class ActivitySpoolTests: XCTestCase {
    private var wallNow: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ActivitySpool.directoryOverride = directory
    }

    override func tearDownWithError() throws {
        ActivitySpool.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - The receiver's side: what an event becomes on disk

    func testAPreToolUseEventBecomesAStateFileAndNeverAttention() throws {
        let stdin = #"""
        {"hook_event_name":"PreToolUse","session_id":"sess-a","tool_name":"Edit",
         "tool_input":{"file_path":"/repo/src/Main.swift"},"cwd":"/repo"}
        """#
        _ = PulseHookReceiver.run(arguments: ["--hook", "claude", "activity"], stdin: stdin)
        let events = ActivitySpool.readEvents(nowMs: wallNow)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(event.agent, "claude")
        XCTAssertEqual(event.session, "sess-a")
        XCTAssertEqual(event.event, "tool")
        XCTAssertEqual(event.tool, "Edit")
        XCTAssertEqual(event.target, "/repo/src/Main.swift")
        let url = directory.appendingPathComponent("claude-sess-a.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testTheEventNameAloneDispatchesWithoutAKindArgument() throws {
        let stdin = #"{"hook_event_name":"UserPromptSubmit","session_id":"sess-b","prompt":"Fix the login bug\nsecond line"}"#
        _ = PulseHookReceiver.run(arguments: ["--hook", "claude"], stdin: stdin)
        let event = try XCTUnwrap(ActivitySpool.readEvents(nowMs: wallNow).first)
        XCTAssertEqual(event.event, "prompt")
        XCTAssertEqual(event.prompt, "Fix the login bug second line")
        XCTAssertEqual(event.tool, "")
    }

    func testLatestEventWinsBecauseActivityIsAStateNotALedger() throws {
        for (kind, body) in [
            ("activity", #"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Edit","tool_input":{"file_path":"/a"}}"#),
            ("activity", #"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Bash","tool_input":{"command":"swift test"}}"#),
        ] {
            _ = PulseHookReceiver.run(arguments: ["--hook", "claude", kind], stdin: body)
        }
        let events = ActivitySpool.readEvents(nowMs: wallNow)
        XCTAssertEqual(events.count, 1, "one session, one state file")
        XCTAssertEqual(events.first?.tool, "Bash")
    }

    func testASessionlessEventWritesNothing() {
        _ = PulseHookReceiver.run(
            arguments: ["--hook", "claude", "activity"],
            stdin: #"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#
        )
        XCTAssertTrue(ActivitySpool.readEvents(nowMs: wallNow).isEmpty)
    }

    func testSecretsNeverReachTheSpool() throws {
        let stdin = #"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Bash","tool_input":{"command":"deploy with Bearer abc123secretvalue"}}"#
        _ = PulseHookReceiver.run(arguments: ["--hook", "claude", "activity"], stdin: stdin)
        let event = try XCTUnwrap(ActivitySpool.readEvents(nowMs: wallNow).first)
        XCTAssertFalse(event.target.contains("abc123secretvalue"), event.target)
    }

    // MARK: - The reader's side: identity and age

    func testABodyThatDisagreesWithItsFilenameIsRefused() throws {
        let body: [String: Any] = [
            "v": 1, "agent": "claude", "session": "other",
            "event": "tool", "tool": "Edit", "target": "", "prompt": "",
            "cwd": "", "ts_ms": wallNow,
        ]
        try JSONSerialization.data(withJSONObject: body)
            .write(to: directory.appendingPathComponent("claude-sess-x.json"))
        XCTAssertTrue(ActivitySpool.readEvents(nowMs: wallNow).isEmpty,
                      "the filename decides who this is; a disagreeing body is somebody being clever")
    }

    func testAnAncientEventIsNotServedAndAFutureStampIsClamped() throws {
        _ = ActivitySpool.write(ActivitySpool.Event(
            agent: "claude", session: "old", event: "tool",
            tool: "Edit", target: "", prompt: "", cwd: "",
            tsMs: wallNow - ActivitySpool.maxAgeMs - 60_000
        ))
        XCTAssertTrue(ActivitySpool.readEvents(nowMs: wallNow).isEmpty)

        _ = ActivitySpool.write(ActivitySpool.Event(
            agent: "claude", session: "future", event: "tool",
            tool: "Edit", target: "", prompt: "", cwd: "",
            tsMs: wallNow + 10 * 60 * 1000
        ))
        let event = try XCTUnwrap(ActivitySpool.readEvents(nowMs: wallNow).first)
        XCTAssertLessThanOrEqual(event.tsMs, wallNow,
                                 "the writer is this machine — a future stamp is a broken clock")
    }
}

/// 0.96 Return Truth — Glance width and Attention compact. (23.0: the rekey
/// and story-honesty tests went with the remap and `RowNarrator`.)
final class AttentionCompactTests: XCTestCase {
    // MARK: P1 identity / compact

    @MainActor
    func testAttentionCompactKeepsUnresolvedRaise() {
        var lines: [String] = []
        for index in 0..<90 {
            lines.append("amp\tdone\t\(1_700_000_000_000 + index)\tok\tsess-\(index)\t/tmp\t\t")
        }
        lines.insert("amp\tpermission\t1\tapprove\tkeep-me\t/tmp\t\t", at: 0)
        let compacted = AttentionIO.compactLines(lines, cap: 80)
        XCTAssertEqual(compacted.count, 80)
        XCTAssertTrue(
            compacted.contains(where: { $0.contains("keep-me") }),
            "unresolved permission must survive the 80-line cap"
        )
    }
}

/// Clarity fixes — each test pins one defect found by reading the code: the
/// value the user would have seen, before and after.
@MainActor
@Suite("Attention fixes", .serialized)
struct AttentionFixTests {
    let now: Int64 = 1_800_000_000_000
    static let minute: Int64 = 60_000

    // MARK: - Harness

    final class Home {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("pulse-clarity-\(UUID().uuidString)", isDirectory: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        @discardableResult
        func write(_ relative: String, _ text: String, modified: Date? = nil) throws -> URL {
            let file = url.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
            if let modified {
                try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
            }
            return file
        }

        func database(_ relative: String, _ statements: [String]) throws {
            let file = url.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var db: OpaquePointer?
            guard sqlite3_open(file.path, &db) == SQLITE_OK, let db else { throw CocoaError(.fileWriteUnknown) }
            defer { sqlite3_close(db) }
            for sql in statements {
                guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "clarity", code: 1, userInfo: [NSLocalizedDescriptionKey: sql])
                }
            }
        }

        func rows(_ id: AgentID) -> [ActivityHarvest.Row] {
            NativeActivityHarvest.scan(
                allowAppData: true, appDataAgents: [id], home: url, agentFilter: [id]
            ).rows.filter { $0.id == id }
        }
    }

    // MARK: - 6 · a failed probe run is no answer

    @Test func aFailedAgentsRunKeepsTheLastAnswer() {
        var state = ClaudeAgentsProbe.State()
        let wait = ClaudeAgentsProbe.Wait(sessionID: "s1", pid: 1, cwd: "", kind: .permission, reason: "", sinceMs: now)
        state.waits = [wait]
        ClaudeAgentsProbe.record(nil, into: &state, nowMs: now)
        #expect(state.waits == [wait], "one timeout must not blink a real wait off")
        ClaudeAgentsProbe.record([], into: &state, nowMs: now + 20_000)
        #expect(state.waits.isEmpty, "a successful empty answer clears")
    }

    // MARK: - 2 · the stop grace is a function of the two lines

    @Test func theStopGraceDoesNotDependOnWhenTheFileIsRead() {
        let raise = now - 10 * Self.minute
        let text = [
            ["claude", "permission", "\(raise)", "Bash: npm test", "s1", "/p", "", ""],
            ["claude", "stop", "\(raise + 1_000)", "", "s1", "", "", ""],
        ].map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n"
        let soon = AttentionReader.parse(text, nowMs: raise + 2_000)
        let later = AttentionReader.parse(text, nowMs: now)
        let soonKinds = soon.map { $0.kind }
        let laterKinds = later.map { $0.kind }
        #expect(soonKinds == ["Permission"])
        #expect(laterKinds == soonKinds, "re-reading ten minutes later flipped the verdict")
    }

    // MARK: - 17 · one bad byte never erases the attention file

    @Test func anInvalidByteDoesNotEraseOpenWaits() throws {
        let home = Home()
        let file = home.url.appendingPathComponent("attention.tsv")
        try FileManager.default.createDirectory(at: home.url, withIntermediateDirectories: true)
        var bytes = Data(AttentionIO.header.utf8)
        bytes.append(Data("claude\tpermission\t\(now)\tBash: npm test\ts1\t/p\t\t\n".utf8))
        bytes.append(Data([0x63, 0x6f, 0xff, 0x0a]))
        try bytes.write(to: file)
        AttentionIO.pathOverride = file
        defer { AttentionIO.pathOverride = nil }

        AttentionIO.appendRawLine("codex\tdone\t\(now)\t\ts2\t\t\t")
        let written = try Data(contentsOf: file)
        let text = String(decoding: written, as: UTF8.self)
        #expect(text.contains("claude\tpermission"), "the rewrite used to start from an empty decode")
        #expect(text.contains("codex\tdone"))
    }
}

/// 22.x · Lamp fixes — each pins one defect with the pure function that
/// decides it.
@Suite("Codex hooks detection")
struct CodexHooksDetectionTests {
    // MARK: - Codex hooks.json counts as installed

    @Test func codexHooksJSONAloneCountsAsInstalled() {
        let hooks = #"{"hooks":{"Stop":[{"hooks":[{"command":"/x/pulse-hook --agent codex"}]}]}}"#
        #expect(HooksSupport.codexHooked(configTOML: nil, hooksJSON: hooks))
        #expect(HooksSupport.codexHooked(configTOML: "notify = [\"/x/pulse-hook\"]", hooksJSON: nil))
        #expect(!HooksSupport.codexHooked(configTOML: "model = \"o3\"", hooksJSON: "{}"))
    }
}
