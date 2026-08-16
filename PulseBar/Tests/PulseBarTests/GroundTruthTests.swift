import XCTest
@testable import PulseBar

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

    /// **This assertion was reversed in 1.1, deliberately.**
    ///
    /// 0.98 asserted that a file past the window reports `0` — unknown — because
    /// counting the newlines of a head+tail window is a floor, and EXPERIENCE
    /// forbids presenting a floor as a total (数量不估算).
    ///
    /// 1.1 did not weaken that rule; it removed the reason for it. The session
    /// digest folds the bytes between the head and the tail once, as they go
    /// past, so once it has reached the end of the file the count is the file's
    /// count. That is not an estimate — it is the exact number, from having
    /// actually read every record.
    ///
    /// The rule still binds while the digest is *behind*: a partial fold must
    /// not stand in for a total, which is why the collector only takes the
    /// digest's answer when `caughtUp` is true. `SessionDigestTests` pins that
    /// half, and the slices-equal-whole invariant pins the counting itself.
    func testALargeTranscriptReportsAnExactRecordCount() throws {
        let home = try makeHome("records-large")
        defer { try? FileManager.default.removeItem(at: home) }
        let filler = String(repeating: "padding ", count: 160)
        var lines = [
            #"{"sessionId":"gt-5","role":"user","content":"Large transcript goal","cwd":"/tmp/gt-large"}"#
        ]
        for index in 0..<900 {
            lines.append(
                #"{"sessionId":"gt-5","type":"note","index":\#(index),"text":"\#(filler)"}"#
            )
        }
        try write(lines.joined(separator: "\n") + "\n", to: home, ".openhands/session.jsonl")

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.openhands])
        let row = try XCTUnwrap(result.rows.first { $0.id == .openhands })
        XCTAssertEqual(
            row.records, lines.count,
            "the digest read the middle of the file, so the count is exact rather than unknown"
        )
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
}
