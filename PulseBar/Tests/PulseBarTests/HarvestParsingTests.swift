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

    func testAgentAliasMapping() {
        XCTAssertEqual(ActivityHarvest.mapAgent("amazon-q"), .amazonQ)
        XCTAssertEqual(ActivityHarvest.mapAgent("auggie"), .augment)
        XCTAssertEqual(ActivityHarvest.mapAgent("factory-droid"), .droid)
        XCTAssertEqual(ActivityHarvest.mapAgent("cursor_agent"), .cursorAgent)
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
