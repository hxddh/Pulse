import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

final class HarvestParsingTests: XCTestCase {
    /// The collector redacts credential-shaped content before a row exists.
    /// 0.99 deleted the legacy wire this used to be asserted through, so it is
    /// asserted where the boundary actually is now: a real scan of a real file.
    func testCollectorRedactsSecretsBeforeARowExists() throws {
        let fakeKey = "sk-proj-ExampleSecret123456789"
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-redact-\(UUID().uuidString)")
        let url = home.appendingPathComponent(".openhands/session.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        try #"{"sessionId":"redact-1","role":"user","content":"Deploy with KEY","cwd":"/tmp/redact"}"#
            .replacingOccurrences(of: "KEY", with: fakeKey)
            .write(to: url, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.openhands])
        let row = try XCTUnwrap(result.rows.first { $0.id == .openhands })
        XCTAssertFalse(row.task.contains(fakeKey))
        XCTAssertTrue(row.task.contains(ContentSanitizer.replacement))
    }

    func testSanitizerKeepsOrdinaryTechnicalText() {
        let safe = "Review token budget for sketch session 550e8400-e29b-41d4-a716-446655440000"
        XCTAssertEqual(ContentSanitizer.redact(safe), safe)
        XCTAssertEqual(
            ContentSanitizer.redact("Authorization: Bearer fakeBearerValue123"),
            "Authorization: Bearer ••••"
        )
        XCTAssertEqual(
            ContentSanitizer.redact("password=hunterExample123"),
            "password=••••"
        )
    }


    /// 23.0: a row key is the vendor's session id, whole — or, without one,
    /// a hash of the transcript path or of where and when the session began.
    func testRowKeysAreStableAndNeverCarryAPath() {
        let long = String(repeating: "a", count: 40)
        let key = RowIdentity.session(agent: .claude, sessionID: long)
        XCTAssertEqual(key, "claude|" + long)
        XCTAssertEqual(key, RowIdentity.session(agent: .claude, sessionID: long), "same input, same key")
        let placed = RowIdentity.session(agent: .codex, sessionID: "", cwd: "/a/b/Repo", startedMs: 5)
        XCTAssertTrue(placed.hasPrefix("codex|at:"))
        XCTAssertFalse(placed.contains("Repo"), "a key never carries a path")
        XCTAssertEqual(RowIdentity.session(agent: .codex, sessionID: ""), "codex|anon")
    }

    func testFreshnessRequiresAMtimeUnlessSubagentsAreRunning() {
        let now: Int64 = 1_700_000_000_000
        var row = ActivityHarvest.Row(id: .claude, task: "t", project: "", cwd: "", skill: "")
        XCTAssertFalse(ActivityHarvest.isFresh(row, nowMs: now), "no mtime is not a running signal")

        row.subRunning = 1
        XCTAssertTrue(ActivityHarvest.isFresh(row, nowMs: now))

        row.subRunning = 0
        row.harvestMs = now - 1000
        XCTAssertTrue(ActivityHarvest.isFresh(row, nowMs: now))

        row.harvestMs = now - ActivityHarvest.freshWindowMs - 1
        XCTAssertFalse(ActivityHarvest.isFresh(row, nowMs: now))
    }

    func testFarFutureActivityTimestampIsNotFresh() {
        let now: Int64 = 1_700_000_000_000
        var row = ActivityHarvest.Row(id: .codex, task: "t", project: "", cwd: "", skill: "")
        row.harvestMs = now + 5 * 60 * 1000 + 1
        XCTAssertFalse(ActivityHarvest.isFresh(row, nowMs: now))
    }

    func testCursorLocalSessionsUseBoundedWorkWindow() {
        let now: Int64 = 1_700_000_000_000
        var cursor = ActivityHarvest.Row(id: .cursor, task: "Local task", project: "", cwd: "", skill: "")
        cursor.mode = "local"
        cursor.harvestMs = now - ActivityHarvest.freshWindowMs - 1
        XCTAssertTrue(ActivityHarvest.isFresh(cursor, nowMs: now))

        cursor.harvestMs = now - ActivityHarvest.cursorLocalWindowMs - 1
        XCTAssertFalse(ActivityHarvest.isFresh(cursor, nowMs: now))

        var generic = cursor
        generic.id = .gemini
        generic.harvestMs = now - ActivityHarvest.freshWindowMs - 1
        XCTAssertFalse(ActivityHarvest.isFresh(generic, nowMs: now))
    }

    func testHealthCompletenessRequiresEveryUserFacingCollector() {
        let unscanned = ActivityHarvest.expectedCollectorIDs.map { ActivityHarvest.CollectorHealth.unscanned($0) }
        XCTAssertFalse(ActivityHarvest.isCompleteHealth(unscanned), "unscanned is an incomplete bounded scan")
        let complete = unscanned.map {
            ActivityHarvest.CollectorHealth(
                id: $0.id,
                state: .sourceAbsent,
                durationMs: 1,
                rowCount: 0,
                sourcePresent: false,
                errorKind: ""
            )
        }
        XCTAssertTrue(ActivityHarvest.isCompleteHealth(complete))
        XCTAssertFalse(ActivityHarvest.isCompleteHealth(Array(complete.dropLast())))

        var cursorAlias = complete.filter { $0.id != .cursor }
        cursorAlias.append(.unscanned(.cursorAgent))
        XCTAssertTrue(ActivityHarvest.isCompleteHealth(cursorAlias), "Cursor Agent is the same user-facing collector")
    }

    func testPartialHarvestKeepsAdaptersTheChildNeverReached() {
        let oldCodex = ActivityHarvest.Row(
            id: .codex,
            task: "Keep this session visible",
            project: "Pulse",
            cwd: "/Users/me/Pulse",
            skill: "",
            harvestMs: 1_700_000_000_000,
            sessionID: "codex-old"
        )
        let oldPi = ActivityHarvest.Row(
            id: .pi,
            task: "Replace after Pi reports",
            project: "Pulse",
            cwd: "/Users/me/Pulse",
            skill: "",
            harvestMs: 1_700_000_000_000,
            sessionID: "pi-old"
        )
        var freshCodex = oldCodex
        freshCodex.task = "Fresh Codex evidence"
        freshCodex.sessionID = "codex-new"
        let health = [
            ActivityHarvest.CollectorHealth(
                id: .codex,
                state: .observed,
                durationMs: 10,
                rowCount: 1,
                sourcePresent: true,
                errorKind: ""
            )
        ]

        let merged = ActivityHarvest.mergePartialRows(
            current: [freshCodex],
            health: health,
            previous: [oldCodex, oldPi]
        )

        XCTAssertEqual(merged.map(\.sessionID), ["codex-new", "pi-old"])
        XCTAssertFalse(merged.contains { $0.sessionID == "codex-old" })
    }

    func testAnAdapterThatTimedOutMidwayKeepsItsUnreachedSessions() {
        func codex(_ session: String, _ task: String) -> ActivityHarvest.Row {
            ActivityHarvest.Row(
                id: .codex, task: task, project: "Pulse", cwd: "/Users/me/Pulse",
                skill: "", harvestMs: 1_700_000_000_000, sessionID: session
            )
        }
        let previous = [codex("a", "old a"), codex("b", "old b"), codex("c", "old c")]
        let health = [
            ActivityHarvest.CollectorHealth(
                id: .codex, state: .failed, durationMs: 750, rowCount: 1,
                sourcePresent: true, errorKind: "native_timeout"
            )
        ]
        let merged = ActivityHarvest.mergePartialRows(
            current: [codex("a", "fresh a")], health: health, previous: previous
        )
        XCTAssertEqual(Set(merged.map(\.sessionID)), ["a", "b", "c"])
        XCTAssertEqual(merged.first { $0.sessionID == "a" }?.task, "fresh a", "fresh evidence wins")
        XCTAssertEqual(merged.filter { $0.sessionID == "a" }.count, 1, "no stale duplicate")
    }

    func testPartialHarvestWithNoAdapterBoundaryDoesNotEraseSnapshot() {
        var previous = ActivityHarvest.Row(
            id: .cursor,
            task: "Cursor task",
            project: "Client",
            cwd: "/Users/me/Client",
            skill: "",
            harvestMs: 1_700_000_000_000,
            sessionID: "cursor-1"
        )
        previous.mode = "local"
        let merged = ActivityHarvest.mergePartialRows(
            current: [],
            health: [],
            previous: [previous]
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.sessionID, previous.sessionID)
        XCTAssertEqual(merged.first?.task, previous.task)
        XCTAssertEqual(merged.first?.mode, previous.mode)
    }

    func testFailedEmptyAdapterRetainsLastGoodRowsUntilRetry() {
        let previous = ActivityHarvest.Row(
            id: .commandCode,
            task: "Keep command session visible",
            project: "Pulse",
            cwd: "/Users/me/Pulse",
            skill: "",
            harvestMs: 1_700_000_000_000,
            sessionID: "command-old"
        )
        let health = [
            ActivityHarvest.CollectorHealth(
                id: .commandCode,
                state: .failed,
                durationMs: 750,
                rowCount: 0,
                sourcePresent: true,
                errorKind: "native_timeout"
            )
        ]

        let merged = ActivityHarvest.mergePartialRows(
            current: [],
            health: health,
            previous: [previous]
        )

        XCTAssertEqual(merged.map(\.sessionID), ["command-old"])
    }

    func testEmptyPartialIssueBoundariesRetainLastGoodRows() {
        let previous = ActivityHarvest.Row(
            id: .cursor,
            task: "Keep Cursor session visible",
            project: "Client",
            cwd: "/Users/me/Client",
            skill: "",
            harvestMs: 1_700_000_000_000,
            sessionID: "cursor-old"
        )
        let states: [ActivityHarvest.CollectorState] = [
            .permissionDenied, .schemaMismatch, .unscanned,
        ]

        for state in states {
            let health = [ActivityHarvest.CollectorHealth(
                id: .cursor,
                state: state,
                durationMs: 10,
                rowCount: 0,
                sourcePresent: true,
                errorKind: "boundary"
            )]
            let merged = ActivityHarvest.mergePartialRows(
                current: [],
                health: health,
                previous: [previous]
            )
            XCTAssertEqual(
                merged.map(\.sessionID),
                ["cursor-old"],
                "empty \(state.rawValue) must not erase prior evidence"
            )
        }
    }

    func testAttentionFutureEventIsIgnored() {
        let now: Int64 = 1_700_000_000_000
        let text = "codex\tpermission\t\(now + 6 * 60 * 1000)\tApprove\tsession-1\t/Users/me/Pulse\t\t\n"
        XCTAssertTrue(AttentionReader.parse(text, nowMs: now).isEmpty)
    }

    func testCompletionClassificationUsesPhaseOrOutcome() {
        var row = ActivityHarvest.Row(id: .codex, task: "", project: "", cwd: "", skill: "")
        XCTAssertFalse(row.isCompleted)
        row.phase = "turn_complete"
        XCTAssertTrue(row.isCompleted)
        row.phase = ""
        row.outcome = "failed"
        XCTAssertTrue(row.isCompleted)
    }

    func testAgentAliasMapping() {
        XCTAssertEqual(ActivityHarvest.mapAgent("amazon-q"), .amazonQ)
        XCTAssertEqual(ActivityHarvest.mapAgent("auggie"), .augment)
        XCTAssertEqual(ActivityHarvest.mapAgent("factory-droid"), .droid)
        XCTAssertEqual(ActivityHarvest.mapAgent("cursor_agent"), .cursorAgent)
        XCTAssertEqual(ActivityHarvest.mapAgent("agy"), .antigravity)
        XCTAssertNil(ActivityHarvest.mapAgent("definitely-not-an-agent"))
    }
}

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

    func testAgentLevelDoneClearsEverySessionOfThatAgent() {
        let text = tsv([
            ["claude", "permission", "\(now - 5000)", "a", "s1", "/p"],
            ["claude", "permission", "\(now - 4000)", "b", "s2", "/q"],
            ["claude", "done", "\(now - 1000)", "", "", ""],
        ])
        XCTAssertTrue(AttentionReader.parse(text, nowMs: now).isEmpty)
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
