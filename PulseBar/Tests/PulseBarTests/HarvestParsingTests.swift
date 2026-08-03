import XCTest
@testable import PulseBar

final class HarvestParsingTests: XCTestCase {
    private func line(_ cols: [String]) -> String {
        cols.joined(separator: "\t")
    }

    func testParsesFullRow() {
        let text = line([
            "claude", "Refactor probe", "1200", "340", "Bash", "",
            "Pulse", "/Users/me/Pulse", "1700000000000", "2", "5", "sess-abc",
            "34", "1699999000000", "session",
            "testing", "completed", "agent-4", "build",
            "2", "7", "41", "3", "5",
        ]) + "\n"
        let rows = ActivityHarvest.parse(text)
        XCTAssertEqual(rows.count, 1)
        let r = rows[0]
        XCTAssertEqual(r.id, .claude)
        XCTAssertEqual(r.task, "Refactor probe")
        XCTAssertEqual(r.tokensIn, 1200)
        XCTAssertEqual(r.tokensOut, 340)
        XCTAssertEqual(r.tool, "Bash")
        XCTAssertEqual(r.project, "Pulse")
        XCTAssertEqual(r.cwd, "/Users/me/Pulse")
        XCTAssertEqual(r.harvestMs, 1_700_000_000_000)
        XCTAssertEqual(r.subRunning, 2)
        XCTAssertEqual(r.subTotal, 5)
        XCTAssertEqual(r.sessionID, "sess-abc")
        XCTAssertEqual(r.records, 34)
        XCTAssertEqual(r.startedMs, 1_699_999_000_000)
        XCTAssertEqual(r.evidence, .session)
        XCTAssertEqual(r.phase, "testing")
        XCTAssertEqual(r.outcome, "completed")
        XCTAssertEqual(r.model, "agent-4")
        XCTAssertEqual(r.mode, "build")
        XCTAssertEqual(r.errors, 2)
        XCTAssertEqual(r.files, 7)
        XCTAssertEqual(r.contextPercent, 41)
        XCTAssertEqual(r.progressDone, 3)
        XCTAssertEqual(r.progressTotal, 5)
    }

    func testParsesVersionedJSONRowEnvelope() {
        let text = "{\"schema\":2,\"type\":\"row\",\"agent\":\"command_code\",\"task\":\"Run tests\",\"tokensIn\":12,\"tokensOut\":3,\"tool\":\"swift_test\",\"skill\":\"\",\"project\":\"Pulse\",\"cwd\":\"/Users/me/Pulse\",\"harvestMs\":1700000000000,\"subRunning\":0,\"subTotal\":0,\"sessionID\":\"cmd-1\",\"records\":9,\"startedMs\":1699999000000,\"evidence\":\"session\",\"phase\":\"testing\",\"outcome\":\"\",\"model\":\"gpt-5\",\"mode\":\"\",\"errors\":0,\"files\":2,\"contextPercent\":31,\"progressDone\":4,\"progressTotal\":8}\n"
        let rows = ActivityHarvest.parse(text)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, .commandCode)
        XCTAssertEqual(rows[0].phase, "testing")
        XCTAssertEqual(rows[0].progressTotal, 8)
        XCTAssertEqual(rows[0].evidence, .session)
    }

    func testRedactsSecretsAtHarvestBoundary() {
        let fakeKey = "sk-proj-ExampleSecret123456789"
        let text = line([
            "codex", "Deploy with \(fakeKey)", "0", "0", "web_fetch", "",
            "Pulse", "/Users/me/Pulse", "1700000000000", "0", "0", "sess-redact",
        ]) + "\n"
        let row = ActivityHarvest.parse(text)[0]
        XCTAssertFalse(row.task.contains(fakeKey))
        XCTAssertTrue(row.task.contains(ContentSanitizer.replacement))
        XCTAssertEqual(row.project, "Pulse")
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

    func testOldRowsDegradeToCacheEvidenceInsteadOfClaimingASession() {
        let text = line([
            "roo", "Refactor auth", "0", "0", "", "",
            "App", "/Users/me/App", "1700000000000", "0", "0", "state",
        ]) + "\n"
        XCTAssertEqual(ActivityHarvest.parse(text).first?.evidence, .cache)
    }

    /// A harvest killed on timeout leaves a half-written final line. Parsing it
    /// would invent a row with fields shifted into the wrong columns.
    func testDropsIncompleteTrailingLine() {
        let complete = line(["claude", "Task A", "0", "0", "", "", "P", "/p", "1700000000000", "0", "0", "s1"])
        let truncated = "codex\tTask B\t0\t0"
        let rows = ActivityHarvest.parse(complete + "\n" + truncated)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, .claude)
    }

    func testIgnoresUnknownAgentAndCommentLines() {
        let text = """
        # a comment
        notanagent\tTask\t0\t0
        claude\tReal\t0\t0\t\t\tP\t/p\t1700000000000\t0\t0\ts1

        """
        let rows = ActivityHarvest.parse(text)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].task, "Real")
    }

    func testParsesCollectorRuntimeHealthWithoutTreatingItAsARow() {
        let text = """
        #health\tclaude\tobserved\t12\t2\t
        #health\tamp\tno_recent_data\t3\t0\t
        #health\tcodex\tfailed\t21\t0\tJSONDecodeError

        """
        XCTAssertTrue(ActivityHarvest.parse(text).isEmpty)
        let health = ActivityHarvest.parseHealth(text)
        XCTAssertEqual(health.count, 3)
        XCTAssertEqual(health[0].id, .claude)
        XCTAssertEqual(health[0].state, .observed)
        XCTAssertEqual(health[0].rowCount, 2)
        XCTAssertEqual(health[1].state, .noRecentData)
        XCTAssertEqual(health[2].state, .failed)
        XCTAssertEqual(health[2].errorKind, "JSONDecodeError")
    }

    func testParsesVersionedJSONCollectorHealth() {
        let text = "{\"schema\":2,\"type\":\"health\",\"agent\":\"cursor\",\"state\":\"observed\",\"durationMs\":42,\"rowCount\":4,\"sourcePresent\":true,\"errorKind\":\"\"}\n"
        XCTAssertTrue(ActivityHarvest.parse(text).isEmpty)
        let health = ActivityHarvest.parseHealth(text)
        XCTAssertEqual(health.count, 1)
        XCTAssertEqual(health[0].id, .cursor)
        XCTAssertEqual(health[0].state, .observed)
        XCTAssertEqual(health[0].durationMs, 42)
        XCTAssertEqual(health[0].rowCount, 4)
        XCTAssertTrue(health[0].sourcePresent)
    }

    func testCollectorPreflightFailureProducesActionableHealthForEveryAdapter() {
        let health = ActivityHarvest.unavailableHealth("native_unavailable")
        XCTAssertEqual(Set(health.map(\.id)), ActivityHarvest.expectedCollectorIDs)
        XCTAssertTrue(health.allSatisfy { $0.state == .failed && $0.errorKind == "native_unavailable" })
    }

    func testDropsIncompleteTrailingCollectorHealth() {
        let text = "#health\tclaude\tobserved\t12\t1\t\n#health\tcodex\tfailed"
        XCTAssertEqual(ActivityHarvest.parseHealth(text).map(\.id), [.claude])
    }

    func testParsesActionableCollectorStatesAndSourcePresence() {
        let text = """
        #health\tamp\tsource_absent\t2\t0\t\t0
        #health\tcodex\tno_sessions\t4\t0\t\t1
        #health\tclaude\tpermission_denied\t5\t0\tPermissionError\t1
        #health\tcursor\tschema_mismatch\t8\t0\tJSONDecodeError\t1

        """
        let health = ActivityHarvest.parseHealth(text)
        XCTAssertEqual(health.map(\.state), [
            .sourceAbsent, .noSessions, .permissionDenied, .schemaMismatch,
        ])
        XCTAssertEqual(health.map(\.sourcePresent), [false, true, true, true])
        XCTAssertFalse(health[0].state.isIssue)
        XCTAssertTrue(health[2].state.isIssue)
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

    func testCommentsAndShortRowsAreSkipped() {
        let text = "# header\nclaude\tpermission\n\n"
        XCTAssertTrue(AttentionReader.parse(text, nowMs: now).isEmpty)
    }
}
