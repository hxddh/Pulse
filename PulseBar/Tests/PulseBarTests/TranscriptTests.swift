import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

// Transcripts: the shared transcript reader, dialects and the plan facts read from them.

/// 4.0-α — a session transcript is parsed by shape, bounded
/// at every edge, and sanitized per entry. These tests pin each rule with
/// vendor-real line shapes; the file-window behaviour runs against a real
/// temporary file at the bottom.
final class TranscriptReaderTests: XCTestCase {

    private func parse(_ lines: [String], truncatedHead: Bool = false) -> TranscriptReader.Excerpt {
        TranscriptReader.parse(
            data: Data((lines.joined(separator: "\n") + "\n").utf8),
            truncatedHead: truncatedHead
        )
    }

    // MARK: - Claude-family shapes

    func testAClaudeUserTurnAndAssistantReplyComeOutInOrder() {
        let excerpt = parse([
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"fix the bug"}]},"timestamp":"2026-08-26T02:00:01.000Z"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Looking at it."}]}}"#,
        ])
        XCTAssertEqual(excerpt.entries.map(\.kind), [.user, .agent])
        XCTAssertEqual(excerpt.entries[0].text, "fix the bug")
        XCTAssertEqual(excerpt.entries[0].tsMs, 1_787_709_601_000)
        XCTAssertEqual(excerpt.entries[1].text, "Looking at it.")
        XCTAssertEqual(excerpt.unparsedLines, 0)
    }

    func testAPlainStringContentIsStillAMessage() {
        let excerpt = parse([
            #"{"type":"user","message":{"role":"user","content":"just a string"}}"#,
        ])
        XCTAssertEqual(excerpt.entries.first?.text, "just a string")
    }

    func testAToolUseBlockBecomesAToolEntryWithItsTarget() {
        let excerpt = parse([
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/repo/Main.swift"}}]}}"#,
        ])
        XCTAssertEqual(excerpt.entries.count, 1)
        XCTAssertEqual(excerpt.entries[0].kind, .tool)
        XCTAssertEqual(excerpt.entries[0].toolName, "Edit")
        XCTAssertEqual(excerpt.entries[0].text, "/repo/Main.swift")
    }

    func testAFailedToolResultSurvivesEvenWhenSilentSuccessesAreDropped() {
        let excerpt = parse([
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"","is_error":false}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"compile failed","is_error":true}]}}"#,
        ])
        XCTAssertEqual(excerpt.entries.count, 1)
        XCTAssertTrue(excerpt.entries[0].isError)
        XCTAssertEqual(excerpt.entries[0].text, "compile failed")
    }

    func testAToolResultWithBlockContentReadsItsTextBlock() {
        let excerpt = parse([
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":[{"type":"text","text":"3 files changed"}]}]}}"#,
        ])
        XCTAssertEqual(excerpt.entries.first?.text, "3 files changed")
    }

    // MARK: - Codex shapes

    func testCodexEventMessagesMapToBothSpeakers() {
        let excerpt = parse([
            #"{"type":"event_msg","payload":{"type":"user_message","message":"run the tests"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"They pass."}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","count":512}}"#,
        ])
        XCTAssertEqual(excerpt.entries.map(\.kind), [.user, .agent])
        XCTAssertEqual(excerpt.unparsedLines, 0, "bookkeeping is not an unrecognized line")
    }

    func testACodexResponseItemUnwrapsToItsInnerMessage() {
        let excerpt = parse([
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}}"#,
        ])
        XCTAssertEqual(excerpt.entries.first?.kind, .agent)
        XCTAssertEqual(excerpt.entries.first?.text, "done")
    }

    // MARK: - Generic shape and the honest counters

    func testAGenericRoleContentRecordParses() {
        let excerpt = parse([#"{"role":"user","content":"hello"}"#])
        XCTAssertEqual(excerpt.entries.first?.kind, .user)
    }

    func testANonJSONLineIsCountedNeverGuessedAt() {
        let excerpt = parse([
            "not json at all",
            #"{"role":"user","content":"real"}"#,
        ])
        XCTAssertEqual(excerpt.unparsedLines, 1)
        XCTAssertEqual(excerpt.entries.count, 1)
    }

    func testATornFirstLineIsSkippedInATruncatedWindow() {
        let excerpt = parse([
            #"ext":"the back half of a record"}]}}"#,
            #"{"role":"user","content":"whole"}"#,
        ], truncatedHead: true)
        XCTAssertEqual(excerpt.entries.count, 1)
        XCTAssertEqual(excerpt.entries[0].text, "whole")
        XCTAssertEqual(excerpt.unparsedLines, 0, "the torn half is skipped, not counted against the file")
        XCTAssertTrue(excerpt.truncatedHead)
    }

    func testTheEntryCapKeepsTheNewestAndSaysSo() {
        let lines = (0..<(TranscriptReader.maxEntries + 20)).map {
            #"{"role":"user","content":"m\#($0)"}"#
        }
        let excerpt = parse(lines)
        XCTAssertTrue(excerpt.entriesCapped)
        XCTAssertEqual(excerpt.entries.count, TranscriptReader.maxEntries)
        XCTAssertEqual(excerpt.entries.last?.text, "m\(TranscriptReader.maxEntries + 19)")
        XCTAssertEqual(excerpt.entries.first?.text, "m20", "the oldest fall off the front")
    }

    func testEveryRenderedStringPassesTheSanitizer() {
        let excerpt = parse([
            #"{"role":"assistant","content":"the key is sk-proj-abcdefghijklmnop123456"}"#,
        ])
        let text = excerpt.entries.first?.text ?? ""
        XCTAssertFalse(text.contains("sk-proj-abcdefghijklmnop123456"))
        XCTAssertTrue(text.contains(ContentSanitizer.replacement))
    }

    func testAnOverlongEntryIsBoundedWithAVisibleEllipsis() {
        let long = String(repeating: "a", count: TranscriptReader.maxEntryChars + 500)
        let excerpt = parse([#"{"role":"user","content":"\#(long)"}"#])
        let text = excerpt.entries.first?.text ?? ""
        XCTAssertEqual(text.count, TranscriptReader.maxEntryChars + 1)
        XCTAssertTrue(text.hasSuffix("…"))
    }

    func testANumericSecondsTimestampBecomesMilliseconds() {
        let excerpt = parse([#"{"role":"user","content":"x","timestamp":1787709601}"#])
        XCTAssertEqual(excerpt.entries.first?.tsMs, 1_787_709_601_000)
    }

    // MARK: - The real file window

    func testReadingARealFileReportsItsSizesAndTailTruncation() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        // Enough lines to exceed the tail window, so the head must be cut
        // and the reader must say so.
        let filler = String(repeating: "x", count: 400)
        var lines: [String] = []
        for index in 0..<2000 {
            lines.append(#"{"role":"user","content":"\#(filler) \#(index)"}"#)
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        XCTAssertGreaterThan(data.count, TranscriptReader.tailWindowBytes)
        try data.write(to: url)

        let excerpt = try XCTUnwrap(TranscriptReader.read(path: url.path))
        XCTAssertTrue(excerpt.truncatedHead)
        XCTAssertEqual(excerpt.fileBytes, data.count)
        XCTAssertLessThanOrEqual(excerpt.windowBytes, TranscriptReader.tailWindowBytes)
        XCTAssertEqual(excerpt.entries.count, TranscriptReader.maxEntries)
        XCTAssertTrue(excerpt.entries.last?.text.hasSuffix("1999") ?? false,
                      "the tail of the file is the tail of the view")
    }

    func testAMissingFileIsNilNotAnEmptyExcerpt() {
        XCTAssertNil(TranscriptReader.read(path: "/nonexistent/pulse-\(UUID().uuidString).jsonl"))
        XCTAssertNil(TranscriptReader.read(path: ""))
    }

    func testASmallFileIsReadWholeWithNothingCut() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-transcript-small-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"role":"user","content":"only line"}"#.utf8).write(to: url)
        let excerpt = try XCTUnwrap(TranscriptReader.read(path: url.path))
        XCTAssertFalse(excerpt.truncatedHead)
        XCTAssertEqual(excerpt.entries.count, 1)
    }
}

/// 12.3 γ — vendor formats are dialects in one table, not branches inside
/// the generic parser. These pin the dispatch; the parsing itself stays
/// covered by the hero-value suites and the native fixture wall.
final class TranscriptDialectTests: XCTestCase {
    func testEachVendorPathIsClaimedByItsOwnDialect() {
        XCTAssertTrue(TranscriptDialects.dialect(for: "/Users/me/.codex/sessions/2026/rollout-1.jsonl") is CodexDialect)
        XCTAssertTrue(TranscriptDialects.dialect(for: "/Users/me/.pi/agent/sessions/--x--/s.jsonl") is PiDialect)
        XCTAssertTrue(TranscriptDialects.dialect(for: "/Users/me/.pi/agent/sessions/--x--/s.NDJSON") is PiDialect)
        XCTAssertTrue(TranscriptDialects.dialect(for: "/Users/me/.gemini/tmp/abc/chats/session.json") is GeminiDialect)
    }

    func testEverythingElseGoesToTheGenericWalker() {
        XCTAssertNil(TranscriptDialects.dialect(for: "/Users/me/.claude/projects/-Users-me-x/s.jsonl"))
        XCTAssertNil(TranscriptDialects.dialect(for: "/Users/me/.codex/config.toml"))
        XCTAssertNil(TranscriptDialects.dialect(for: "/Users/me/.gemini/settings.json"))
    }

    func testAnOfficialPiEnvelopeWithoutAPromptIsAnAnswerNotAFallThrough() {
        // An official Pi header with nothing a user said must yield "no facts",
        // never the generic walker's cwd-only row.
        let header = #"{"type":"session","version":3,"id":"abc","timestamp":"2026-01-01T00:00:00Z","cwd":"/Users/me/p"}"#
        let facts = NativeActivityHarvest.parseFacts(
            header, structured: true, path: "/Users/me/.pi/agent/sessions/--Users-me-p--/s.jsonl"
        )
        if NativeActivityHarvest.piLooksOfficial(header) {
            XCTAssertTrue(facts.isEmpty)
        }
    }

    func testTheScanMemoryHasOneLockedOwner() {
        HarvestMemory.memory.withValue { $0.dashPaths["x-y"] = (path: "/x/y", verified: true) }
        XCTAssertEqual(NativeActivityHarvest.dashPathCache["x-y"]?.path, "/x/y")
        NativeActivityHarvest.dashPathCache.removeAll()
        XCTAssertTrue(HarvestMemory.memory.snapshot.dashPaths.isEmpty)
    }
}

/// 2.8 Progress — the agent's own plan, words, and errors.
///
/// The most valuable structure in a transcript is the one the agent writes
/// for itself: its todo list. It used to be filtered out wholesale because
/// plan-step titles once polluted the tray hero. These tests hold the new
/// deal: the structure is read on purpose, into fields that are not the
/// hero, under self-report rules — sanitized, aged, and never Waiting.
final class TranscriptPlanTests: XCTestCase {

    private let now: Int64 = 1_800_000_000_000
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-selfreport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func writeClaude(_ lines: [String], file: String = "sess-plan.jsonl") throws -> URL {
        let session = home
            .appendingPathComponent(".claude/projects/-Users-me-code-Pulse", isDirectory: true)
            .appendingPathComponent(file)
        try FileManager.default.createDirectory(
            at: session.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try (lines.joined(separator: "\n") + "\n").write(to: session, atomically: true, encoding: .utf8)
        return session
    }

    private func claudeRow(_ lines: [String]) throws -> ActivityHarvest.Row {
        _ = try writeClaude(lines)
        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.claude])
        return try XCTUnwrap(result.rows.first { $0.id == .claude })
    }

    private let userLine =
        #"{"type":"user","message":{"role":"user","content":"Fix the auth module"},"sessionId":"sess-plan"}"#

    private func todoLine(_ todos: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":["# + todos + #"]}}]}}"#
    }

    // MARK: - The plan becomes facts (Claude family)

    func testTheTodoListBecomesPlanFacts() throws {
        let row = try claudeRow([
            userLine,
            todoLine(#"{"content":"Fix the parser","status":"completed","activeForm":"Fixing the parser"},{"content":"Add the tests","status":"completed","activeForm":"Adding the tests"},{"content":"Run the gates","status":"in_progress","activeForm":"Running the gates"},{"content":"Write the docs","status":"pending","activeForm":"Writing the docs"}"#),
        ])
        XCTAssertEqual(row.progressDone, 2)
        XCTAssertEqual(row.progressTotal, 4)
        XCTAssertEqual(row.planStep, "Running the gates", "activeForm describes now; content is the imperative")
        XCTAssertEqual(row.planSteps.count, 4)
        XCTAssertEqual(row.planSteps[0].state, .done)
        XCTAssertEqual(row.planSteps[2].state, .current)
        XCTAssertEqual(row.planSteps[3].state, .pending)
        XCTAssertEqual(row.planSteps[3].text, "Write the docs")
    }

    func testTheLatestListWinsBecauseAPlanIsAStateNotAnEvent() throws {
        let row = try claudeRow([
            userLine,
            todoLine(#"{"content":"Fix the parser","status":"in_progress","activeForm":"Fixing the parser"}"#),
            todoLine(#"{"content":"Fix the parser","status":"completed","activeForm":"Fixing the parser"},{"content":"Add the tests","status":"in_progress","activeForm":"Adding the tests"}"#),
        ])
        XCTAssertEqual(row.progressDone, 1)
        XCTAssertEqual(row.progressTotal, 2)
        XCTAssertEqual(row.planStep, "Adding the tests")
    }

    func testAFinishedListHasNoCurrentStepAndNoneIsInvented() throws {
        let row = try claudeRow([
            userLine,
            todoLine(#"{"content":"Fix the parser","status":"completed","activeForm":"Fixing the parser"},{"content":"Add the tests","status":"completed","activeForm":"Adding the tests"}"#),
        ])
        XCTAssertEqual(row.progressDone, 2)
        XCTAssertEqual(row.progressTotal, 2)
        XCTAssertEqual(row.planStep, "", "a finished list has no now")
    }

    func testCountsComeFromTheWholeListWhileTheChecklistIsBounded() throws {
        let items = (0..<9).map {
            #"{"content":"Done step \#($0)","status":"completed"}"#
        } + [
            #"{"content":"The live one","status":"in_progress","activeForm":"Doing the live one"}"#,
            #"{"content":"Still ahead","status":"pending"}"#,
            #"{"content":"Also ahead","status":"pending"}"#,
        ]
        let row = try claudeRow([userLine, todoLine(items.joined(separator: ","))])
        XCTAssertEqual(row.progressDone, 9, "counts are the whole list, never the capped view")
        XCTAssertEqual(row.progressTotal, 12)
        XCTAssertEqual(row.planSteps.count, NativeActivityHarvest.maxPlanSteps)
        XCTAssertTrue(
            row.planSteps.contains { $0.state == .current },
            "bounding drops oldest finished items first, never the live one"
        )
    }

    func testTheCurrentItemSurvivesBoundingWhereverItSits() throws {
        // Codex review on #74: the old leading-prefix loop stopped at the
        // first non-done item, so eight pendings ahead of the current step
        // truncated the current step away — a checklist with no ▸ while
        // planStep names one.
        let items = (0..<9).map { #"{"content":"Ahead \#($0)","status":"pending"}"# }
            + [#"{"content":"The live one","status":"in_progress","activeForm":"Doing the live one"}"#]
        let row = try claudeRow([userLine, todoLine(items.joined(separator: ","))])
        XCTAssertEqual(row.progressTotal, 10)
        XCTAssertEqual(row.planStep, "Doing the live one")
        XCTAssertEqual(row.planSteps.count, NativeActivityHarvest.maxPlanSteps)
        XCTAssertTrue(
            row.planSteps.contains { $0.state == .current },
            "the checklist must not contradict its own planStep"
        )
    }

    func testATranscriptWithoutTodosInventsNothing() throws {
        let row = try claudeRow([
            userLine,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#,
        ])
        XCTAssertEqual(row.progressTotal, 0)
        XCTAssertEqual(row.planStep, "")
        XCTAssertTrue(row.planSteps.isEmpty)
        XCTAssertEqual(row.lastWord, "")
        XCTAssertEqual(row.lastErrorText, "")
    }

    // MARK: - Last word and last error (Claude family)

    func testTheLatestAssistantLineAndTheLatestFailureAreQuoted() throws {
        let row = try claudeRow([
            userLine,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Starting on the parser."}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"error: missing semicolon\nnote: expanded from macro"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Tests are green.\nMoving to the docs next."}]}}"#,
        ])
        XCTAssertEqual(row.lastWord, "Tests are green.", "latest assistant text, first line only")
        XCTAssertEqual(row.lastErrorText, "error: missing semicolon", "the error's own first line, not a count")
    }

    func testAToolUseOnlyAssistantMessageIsNotAWord() throws {
        let row = try claudeRow([
            userLine,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Looking at the failure."}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"swift test"}}]}}"#,
        ])
        XCTAssertEqual(row.lastWord, "Looking at the failure.", "a tool call is an action, not a word")
    }

    func testSelfReportIsSanitizedAndBounded() throws {
        let secret = "Deploying with key Bearer abc123secretvalue " + String(repeating: "x", count: 400)
        let row = try claudeRow([
            userLine,
            todoLine(#"{"content":"\#(secret)","status":"in_progress"}"#),
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(secret)"}]}}"#,
        ])
        XCTAssertFalse(row.planStep.contains("abc123secretvalue"), row.planStep)
        XCTAssertFalse(row.lastWord.contains("abc123secretvalue"), row.lastWord)
        XCTAssertLessThanOrEqual(row.planStep.count, NativeActivityHarvest.maxPlanStepLength)
        XCTAssertLessThanOrEqual(row.lastWord.count, NativeActivityHarvest.maxSelfReportLength)
    }

    func testTheSelfReportScanIsNotGatedByAVendorWhitelist() throws {
        // 2.9: Copilot is deliberately NOT in usesTranscriptUserPrompt — before
        // this, the reverse scan never ran on its transcripts even when the
        // exact same shapes were right there. The scanner matches shapes,
        // not vendor names.
        let session = home
            .appendingPathComponent(".copilot/threads", isDirectory: true)
            .appendingPathComponent("t1.jsonl")
        try FileManager.default.createDirectory(
            at: session.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let lines = [
            #"{"sessionId":"copilot-1","cwd":"/work/repo"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"Run the tests","status":"in_progress"}]}}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Tests are green."}]}}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.copilot])
        let row = try XCTUnwrap(result.rows.first { $0.id == .copilot })
        XCTAssertEqual(row.progressTotal, 1)
        XCTAssertEqual(row.planStep, "Run the tests")
        XCTAssertEqual(row.lastWord, "Tests are green.")
    }

    // MARK: - Codex: update_plan and event messages

    func testCodexUpdatePlanAndAgentMessageBecomeFacts() throws {
        let session = home
            .appendingPathComponent(".codex/sessions/2026/08/24", isDirectory: true)
            .appendingPathComponent("rollout-plan.jsonl")
        try FileManager.default.createDirectory(
            at: session.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let arguments = #"{\"plan\":[{\"step\":\"Read the schema\",\"status\":\"completed\"},{\"step\":\"Write the migration\",\"status\":\"in_progress\"},{\"step\":\"Run it\",\"status\":\"pending\"}]}"#
        let lines = [
            #"{"type":"session_meta","payload":{"session_id":"plan-1","cwd":"/Users/me/Pulse"},"timestamp":1700000000}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Migrate the schema"}]},"timestamp":1700000001}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"update_plan","arguments":"\#(arguments)"},"timestamp":1700000002}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"Schema read; writing the migration now."},"timestamp":1700000003}"#,
            #"{"type":"event_msg","payload":{"type":"error","message":"migration failed: duplicate column"},"timestamp":1700000004}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: session, atomically: true, encoding: .utf8)

        let result = NativeActivityHarvest.scan(home: home, agentFilter: [.codex])
        let row = try XCTUnwrap(result.rows.first { $0.id == .codex })
        XCTAssertEqual(row.task, "Migrate the schema", "the plan is never the hero (the old rule stands)")
        XCTAssertEqual(row.progressDone, 1)
        XCTAssertEqual(row.progressTotal, 3)
        XCTAssertEqual(row.planStep, "Write the migration")
        XCTAssertEqual(row.planSteps.count, 3)
        XCTAssertEqual(row.lastWord, "Schema read; writing the migration now.")
        XCTAssertEqual(row.lastErrorText, "migration failed: duplicate column")
    }
}
