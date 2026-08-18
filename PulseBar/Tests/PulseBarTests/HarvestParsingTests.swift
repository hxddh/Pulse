import XCTest
@testable import PulseBar

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


    func testSessionKeyIsStableAndElidesLongIds() {
        let long = String(repeating: "a", count: 40)
        let key = ActivityHarvest.sessionKey(id: .claude, sessionID: long, project: "", cwd: "")
        XCTAssertTrue(key.hasPrefix("claude|"))
        XCTAssertTrue(key.contains("…"), "long ids should elide")
        XCTAssertEqual(
            key,
            ActivityHarvest.sessionKey(id: .claude, sessionID: long, project: "", cwd: ""),
            "same input must produce the same key"
        )
    }

    func testSessionKeyFallsBackToProjectThenCwd() {
        XCTAssertEqual(
            ActivityHarvest.sessionKey(id: .codex, sessionID: "", project: "/a/b/Pulse", cwd: ""),
            "codex|Pulse"
        )
        XCTAssertEqual(
            ActivityHarvest.sessionKey(id: .codex, sessionID: "", project: "", cwd: "/a/b/Repo"),
            "codex|Repo"
        )
        XCTAssertEqual(
            ActivityHarvest.sessionKey(id: .codex, sessionID: "", project: "", cwd: ""),
            "codex"
        )
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
        let text = "codex\tpermission\t\(now + 6 * 60 * 1000)\tApprove\tsession-1\t/Users/me/Pulse\n"
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

    private func tsv(_ rows: [[String]]) -> String {
        rows.map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n"
    }

    func testLastEventWinsPerSession() {
        let text = tsv([
            ["claude", "permission", "\(now - 5000)", "first", "s1", "/p"],
            ["claude", "idle_prompt", "\(now - 1000)", "second", "s1", "/p"],
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
        // Claude emits idle_prompt then Stop; wiping instantly loses the wait.
        let text = tsv([
            ["claude", "permission", "\(now - 1000)", "approve", "s1", "/p"],
            ["claude", "stop", "\(now)", "", "s1", ""],
        ])
        let entries = AttentionReader.parse(text, nowMs: now)
        XCTAssertEqual(entries.count, 1, "recent permission survives a Stop")
    }

    func testStopClearsAnAgedPermission() {
        let old = now - AttentionReader.stopGraceMs - 5000
        let text = tsv([
            ["claude", "permission", "\(old)", "approve", "s1", "/p"],
            ["claude", "stop", "\(now)", "", "s1", ""],
        ])
        XCTAssertTrue(AttentionReader.parse(text, nowMs: now).isEmpty)
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

    // MARK: - 2.2 · the stop grace uses the clock the reader trusts

    /// Regression (B-13): `clockVerdict` refuses a remote stamp that
    /// disagrees with arrival and measures the wait from arrival instead —
    /// but the Stop grace window alone still measured against the raw stamp.
    /// On a box whose clock runs half an hour behind, the `Stop` that Claude
    /// emits right after a permission prompt therefore wiped that permission
    /// instantly: the lamp went out while the agent was still waiting.
    func testAStopRespectsTheSameClockTheReaderStandsBehind() throws {
        let now: Int64 = 1_700_000_000_000
        let skewed = now - 40 * 60 * 1000
        let text = [
            "claude\tpermission\t\(skewed)\tBash: npm run build\tsession-9\t/Users/me/Pulse\tbox",
            "claude\tstop\t\(skewed + 1)\t\tsession-9\t\tbox",
        ].joined(separator: "\n") + "\n"

        let entries = AttentionReader.parse(
            text, nowMs: now, defaultHost: "box", receivedAtMs: now
        )
        let entry = try XCTUnwrap(entries.first, "the permission survived its own Stop")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entry.kind, "Permission")
        XCTAssertTrue(entry.clockSuspect, "the stamp was refused, arrival carries the event")
        XCTAssertEqual(entry.effectiveMs, now)
    }

    /// And the grace still expires on the clock it is measured against: a
    /// permission that really has been open past the window is cleared.
    func testAStopStillClearsAPermissionPastTheGraceWindow() {
        let now: Int64 = 1_700_000_000_000
        let old = now - 60_000
        let text = [
            "claude\tpermission\t\(old)\tBash: npm run build\tsession-10\t/Users/me/Pulse",
            "claude\tstop\t\(old + 1)\t\tsession-10\t",
        ].joined(separator: "\n") + "\n"
        XCTAssertTrue(AttentionReader.parse(text, nowMs: now).isEmpty)
    }
}
