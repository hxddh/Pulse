import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

/// 0.98 Ground Truth — the collector can be held to account.
///
/// Every test here runs the real `NativeActivityHarvest.scan` against real
/// files at real paths. They cover the four things that made 0.96.1 through
/// 0.97.2 ship green with a wrong tray hero, plus the counting and fairness
/// defects found beside them.
final class GroundTruthTests: XCTestCase {

    private func makeHome(_ label: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-ground-truth-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ text: String, to home: URL, _ relative: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - A starved budget is not an empty source

    /// Regression: when the global byte budget ran low (but not to zero),
    /// `reserve` refused the file read silently, the adapter classified as
    /// `no_sessions`, and mergePartialRows treated that as a trusted empty —
    /// clearing the previous good rows. A refused read must classify as
    /// `failed` so the last snapshot survives.
    func testABudgetDenialNeverReportsNoSessions() throws {
        let home = try makeHome("budget")
        defer { try? FileManager.default.removeItem(at: home) }
        let lines = [
            #"{"sessionId":"gt-b","title":"Real session","cwd":"/tmp/gt-budget"}"#,
            #"{"sessionId":"gt-b","role":"user","content":"Do the thing"}"#,
        ].joined(separator: "\n") + "\n"
        try write(lines, to: home, ".openhands/session.jsonl")

        // Sanity: a normal budget observes the session.
        let healthy = NativeActivityHarvest.scan(home: home, agentFilter: [.openhands])
        XCTAssertEqual(healthy.health.first { $0.id == .openhands }?.state, .observed)

        // Low-but-not-empty: the budget is alive, the file just does not fit.
        let starved = NativeActivityHarvest.scan(
            home: home,
            agentFilter: [.openhands],
            totalBudgetBytes: 8
        )
        let health = try XCTUnwrap(starved.health.first { $0.id == .openhands })
        XCTAssertNotEqual(
            health.state, .noSessions,
            "a refused read says something about resources, not about sessions"
        )
        XCTAssertEqual(health.state, .failed, "failed keeps the previous rows through the partial merge")
    }

    // MARK: - Hero selection is ordinal, not lexical

    /// The regression that cost four releases: a long vendor headline beat a
    /// short real goal because `preferTask` ended in a length comparison.
    func testShortUserPromptBeatsLongVendorHeadline() throws {
        let home = try makeHome("origin")
        defer { try? FileManager.default.removeItem(at: home) }
        let lines = [
            #"{"sessionId":"gt-1","title":"Session 4 — automated maintenance sweep across the whole repository","cwd":"/tmp/gt-origin"}"#,
            #"{"sessionId":"gt-1","role":"user","content":"Fix it"}"#,
        ].joined(separator: "\n") + "\n"
        try write(lines, to: home, ".openhands/session.jsonl")

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.openhands])
        let row = try XCTUnwrap(result.rows.first { $0.id == .openhands })
        XCTAssertEqual(
            row.task, "Fix it",
            "a user turn outranks a cache headline regardless of length"
        )
    }

    /// The same comparison in the other direction: when nothing better exists,
    /// the headline is still a legitimate hero.
    func testVendorHeadlineSurvivesWhenThereIsNoUserTurn() throws {
        let home = try makeHome("headline")
        defer { try? FileManager.default.removeItem(at: home) }
        try write(
            #"{"sessionId":"gt-2","title":"Automated maintenance sweep","cwd":"/tmp/gt-headline"}"#,
            to: home,
            ".openhands/session.json"
        )

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.openhands])
        let row = try XCTUnwrap(result.rows.first { $0.id == .openhands })
        XCTAssertEqual(row.task, "Automated maintenance sweep")
    }

    func testTaskOriginRanksUserGoalsOverVendorChrome() {
        XCTAssertLessThan(NativeActivityHarvest.TaskOrigin.chrome, .cacheTitle)
        XCTAssertLessThan(NativeActivityHarvest.TaskOrigin.cacheTitle, .toolTitle)
        XCTAssertLessThan(NativeActivityHarvest.TaskOrigin.toolTitle, .userPrompt)
        XCTAssertLessThan(NativeActivityHarvest.TaskOrigin.userPrompt, .sessionName)
    }

    // MARK: - One chrome vocabulary

    /// `isChromeTask` knew about `cascade session`; the copy inlined in
    /// `makeRows` did not, so the same placeholder was chrome in a merge and a
    /// legitimate hero at row admission.
    func testPlaceholderTitleIsRejectedAtRowAdmission() throws {
        let home = try makeHome("chrome")
        defer { try? FileManager.default.removeItem(at: home) }
        try write(
            #"{"sessionId":"gt-3","title":"Cascade session"}"#,
            to: home,
            ".openhands/session.json"
        )

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.openhands])
        XCTAssertFalse(
            result.rows.contains { $0.task.lowercased() == "cascade session" },
            "a vendor placeholder with no other fact is not a session"
        )
    }

    // MARK: - Counts are exact or unknown

    func testWholeFileWindowStillCountsRecords() throws {
        let home = try makeHome("records-small")
        defer { try? FileManager.default.removeItem(at: home) }
        let line = #"{"sessionId":"gt-4","role":"user","content":"Small transcript","cwd":"/tmp/gt-small"}"#
        try write(
            Array(repeating: line, count: 12).joined(separator: "\n") + "\n",
            to: home,
            ".openhands/session.jsonl"
        )

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.openhands])
        let row = try XCTUnwrap(result.rows.first { $0.id == .openhands })
        XCTAssertEqual(row.records, 12, "an untruncated file reports its real record count")
    }

    // MARK: - Installed is not the same as running

    /// A menu-bar app launched by Finder/launchd inherits
    /// `/usr/bin:/bin:/usr/sbin:/sbin`, so an agent installed in `~/.local/bin`
    /// used to report `source_absent` ("not installed") instead of
    /// `no_sessions` ("installed, nothing running").
    func testInstalledCLIIsFoundUnderLaunchdMinimalPath() throws {
        let home = try makeHome("path")
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("pulse-fixture-cli")
        try "#!/bin/sh\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: tool.path
        )

        let launchdPath = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        XCTAssertTrue(
            NativeActivityHarvest.executableExists(
                "pulse-fixture-cli", home: home, environment: launchdPath
            )
        )
        XCTAssertFalse(
            NativeActivityHarvest.executableExists(
                "pulse-fixture-not-installed", home: home, environment: launchdPath
            )
        )
    }

    func testCommandSearchPathsCoverTheCommonInstallRoots() {
        let home = URL(fileURLWithPath: "/Users/fixture")
        let paths = NativeActivityHarvest.commandSearchPaths(
            home: home,
            environment: ["PATH": "/usr/bin:/bin"]
        )
        XCTAssertTrue(paths.contains("/opt/homebrew/bin"))
        XCTAssertTrue(paths.contains("/usr/local/bin"))
        XCTAssertTrue(paths.contains("/Users/fixture/.local/bin"))
        XCTAssertTrue(paths.contains("/Users/fixture/.bun/bin"))
        XCTAssertEqual(paths.count, Set(paths).count, "search paths are de-duplicated")
    }

    // MARK: - Budget starvation rotates

    /// Adapter order was the literal order of `descriptors()`, so a budget
    /// cutoff always fell in the same place and the tail adapters were
    /// `unscanned` on every refresh, forever.
    func testStartCursorRotatesWhichAdapterGoesFirst() throws {
        let home = try makeHome("rotate")
        defer { try? FileManager.default.removeItem(at: home) }

        let filter: Set<AgentID> = [.claude, .codex, .openhands]
        let first = NativeActivityHarvest.scan(home: home, agentFilter: filter, startCursor: 0)
        let rotated = NativeActivityHarvest.scan(home: home, agentFilter: filter, startCursor: 1)
        let firstOrder = first.health.map(\.id)
        let rotatedOrder = rotated.health.map(\.id)

        XCTAssertEqual(firstOrder.count, 3)
        XCTAssertEqual(Set(firstOrder), Set(rotatedOrder), "rotation reorders, it never drops")
        XCTAssertNotEqual(
            firstOrder.first, rotatedOrder.first,
            "the next scan starts where the previous one gave up"
        )
    }

    /// The cursor names a place in the stable adapter list. When the
    /// supervisor defers a different set next scan, it still resumes at the
    /// adapter that was cut off, not at whatever now sits at the same index.
    func testRotationResumesAtTheSameAdapterWhenTheFilterChanges() {
        // Stable indices of the adapters this pass attempts; 4 was cut off
        // last time. Adapter 2 is now deferred, which shifts every index in
        // the filtered list — the old code would have started at 5.
        XCTAssertEqual(
            NativeActivityHarvest.rotationOffset(filteredStableIndices: [0, 1, 3, 4, 5], cursor: 4), 3
        )
        // The cut-off adapter itself is deferred now: start at the next one.
        XCTAssertEqual(
            NativeActivityHarvest.rotationOffset(filteredStableIndices: [0, 1, 5], cursor: 4), 2
        )
        // Past the end wraps to the head.
        XCTAssertEqual(
            NativeActivityHarvest.rotationOffset(filteredStableIndices: [0, 1], cursor: 9), 0
        )
    }

    func testCompleteScanRewindsTheCursor() throws {
        let home = try makeHome("cursor")
        defer { try? FileManager.default.removeItem(at: home) }
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.openhands])
        XCTAssertEqual(
            result.nextCursor, 0,
            "a pass that reached every adapter starts the next one at the head"
        )
    }

    // MARK: - The collector explains itself

    func testExplainNamesTheRecordKindBehindTheHero() throws {
        let home = try makeHome("explain-hero")
        defer { try? FileManager.default.removeItem(at: home) }
        try write(
            #"{"sessionId":"gt-6","role":"user","content":"Explain the hero","cwd":"/tmp/gt-explain"}"#,
            to: home,
            ".openhands/session.json"
        )

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.openhands])
        let health = try XCTUnwrap(result.health.first { $0.id == .openhands })
        XCTAssertEqual(health.explain.heroOrigin, "user_prompt")
        XCTAssertEqual(health.explain.emptyReason, "")
        XCTAssertGreaterThan(health.explain.filesRead, 0)
        XCTAssertGreaterThan(health.explain.bytesRead, 0)
        XCTAssertTrue(health.explain.summary.contains("hero=user_prompt"))
    }

    func testExplainSaysWhyThereIsNoHero() throws {
        let home = try makeHome("explain-empty")
        defer { try? FileManager.default.removeItem(at: home) }

        // Continue has no CLI needle, so an empty home can only be
        // `source_absent` — the reason stays deterministic on any runner.
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.continue_])
        let health = try XCTUnwrap(result.health.first { $0.id == .continue_ })
        XCTAssertEqual(health.state, .sourceAbsent)
        XCTAssertEqual(health.explain.emptyReason, "no_source")
        XCTAssertEqual(health.explain.heroOrigin, "")
    }

    func testExplainFlagsATruncatedRead() throws {
        let home = try makeHome("explain-truncated")
        defer { try? FileManager.default.removeItem(at: home) }
        let filler = String(repeating: "padding ", count: 160)
        var lines = [
            #"{"sessionId":"gt-7","role":"user","content":"Truncated goal","cwd":"/tmp/gt-trunc"}"#
        ]
        for index in 0..<900 {
            lines.append(#"{"sessionId":"gt-7","type":"note","index":\#(index),"text":"\#(filler)"}"#)
        }
        try write(lines.joined(separator: "\n") + "\n", to: home, ".openhands/session.jsonl")

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.openhands])
        let health = try XCTUnwrap(result.health.first { $0.id == .openhands })
        XCTAssertTrue(health.explain.truncated)
        XCTAssertTrue(health.explain.summary.contains("truncated"))
    }

    // MARK: - 2.2 · which sessions the read budget is spent on

    /// Regression (B-8 / `H-M2`): the bounded walk read transcripts in
    /// whatever order the filesystem handed them back, and stopped when it hit
    /// its cap. Filesystem order is neither time order nor stable, so on a
    /// heavy user's machine — Claude and Codex cross the cap within a couple
    /// of months — "was the session you are actually running scanned?" was a
    /// question about directory layout. Pi was fixed for exactly this in 0.97
    /// and the fix was never generalised.
    ///
    /// The rows read must therefore be the newest ones, contiguously: a gap
    /// in the sequence means something older displaced something newer.
    func testTheReadBudgetIsSpentOnTheNewestSessions() throws {
        let home = try makeHome("mtime-order")
        defer { try? FileManager.default.removeItem(at: home) }

        let total = 500
        let clock = Date()
        for index in 0..<total {
            let id = String(format: "gt-order-%03d", index)
            let relative = ".openhands/sessions/\(id).jsonl"
            try write(
                #"{"sessionId":"\#(id)","role":"user","content":"Session \#(id)","cwd":"/tmp/gt-order"}"# + "\n",
                to: home,
                relative
            )
            // 0 is the newest, `total - 1` the oldest; all inside the
            // freshness window so nothing is skipped for age.
            try FileManager.default.setAttributes(
                [.modificationDate: clock.addingTimeInterval(-60 * Double(index))],
                ofItemAtPath: home.appendingPathComponent(relative).path
            )
        }

        // Generous deadlines: this asserts which files were chosen, not how
        // fast the runner is.
        let result = NativeActivityHarvest.scan(
            home: home,
            agentDeadlineSeconds: 60,
            totalDeadlineSeconds: 120,
            agentFilter: [.openhands]
        )
        let indices = result.rows
            .filter { $0.id == .openhands }
            .compactMap { Int($0.sessionID.dropFirst("gt-order-".count)) }
            .sorted()

        XCTAssertFalse(indices.isEmpty, "the adapter read something")
        XCTAssertLessThan(
            indices.count, total,
            "the per-agent file cap must actually bite, or this proves nothing"
        )
        XCTAssertEqual(indices.first, 0, "the newest session is never the one left out")
        XCTAssertEqual(
            indices, Array(0..<indices.count),
            "the sessions read are exactly the newest N — a gap means an older file took a live one's place"
        )
    }

    // MARK: - 2.2 · Waiting is never inferred from prose

    /// Regression (B-11 / `H-M5`): the free-text fallback parser raised
    /// `skill=pending` from a `"status": "waiting"` regex match. It runs on
    /// `.md` / `.txt` / `.log` files and on JSON no real parser could read,
    /// where it cannot tell a session's own state from one quoted inside it —
    /// so a design note describing the attention bridge lit a red lamp.
    ///
    /// Waiting comes from hooks or a structured `skill=pending`, never from
    /// inference. The fallback may still supply display fields.
    func testAQuotedStatusInProseNeverLightsWaiting() throws {
        let home = try makeHome("prose-pending")
        defer { try? FileManager.default.removeItem(at: home) }
        // Deliberately not a JSON document and with no line that parses as
        // one: this is the path where only the regex fallback runs.
        let note = """
        # Attention bridge notes

        A raised event carries "sessionId": "gt-prose-1" and "cwd": "/tmp/gt-prose"
        alongside "status": "waiting" — written here as documentation of the
        wire format, not as a statement about this machine.
        """
        try write(note, to: home, ".openhands/notes.md")

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.openhands])
        let row = try XCTUnwrap(result.rows.first { $0.id == .openhands })
        XCTAssertEqual(row.cwd, "/tmp/gt-prose", "display fields still travel")
        XCTAssertNotEqual(
            row.skill, "pending",
            "a status quoted in prose is not this session's status"
        )
    }
}
