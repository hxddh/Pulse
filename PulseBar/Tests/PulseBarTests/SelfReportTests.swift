import XCTest
@testable import PulseBar

/// 2.8 Progress — the agent's own plan, words, and errors.
///
/// The most valuable structure in a transcript is the one the agent writes
/// for itself: its todo list. It used to be filtered out wholesale because
/// plan-step titles once polluted the tray hero. These tests hold the new
/// deal: the structure is read on purpose, into fields that are not the
/// hero, under self-report rules — sanitized, aged, and never Waiting.
final class SelfReportTests: XCTestCase {

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

    func testSelfReportFreshnessIsOneRuleForEverySurface() {
        // Codex review on #74: Details showed "Current step" past the 30
        // minutes where the story line had already withdrawn it. Both now
        // read this one property.
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.harvestMs = Int64(Date().timeIntervalSince1970 * 1000) - 5 * 60 * 1000
        XCTAssertTrue(row.selfReportFresh)
        row.harvestMs = Int64(Date().timeIntervalSince1970 * 1000) - 31 * 60 * 1000
        XCTAssertFalse(row.selfReportFresh, "Details and the story line share this gate")
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

    // MARK: - The story line: informs, ages, never implies Waiting

    @MainActor
    private func storyRow(step: String = "Running the gates") -> AgentRow {
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.task = "Fix the auth module"
        row.planStep = step
        row.liveProcess = true
        row.harvestMs = now
        return row
    }

    @MainActor
    func testTheStoryLeadsWithTheCurrentStep() {
        let store = StatusStore()
        store.language = .en
        let line = store.rowStoryLine(storyRow())
        XCTAssertTrue(line.contains("Running the gates"), line)
    }

    @MainActor
    func testAStaleStepIsNotQuotedAsNow() {
        let store = StatusStore()
        store.language = .en
        var row = storyRow()
        row.harvestMs = Int64(Date().timeIntervalSince1970 * 1000) - 31 * 60 * 1000
        XCTAssertFalse(
            store.rowStoryLine(row).contains("Running the gates"),
            "a 31-minute-old plan is stale wearing fresh clothes"
        )
    }

    @MainActor
    func testWaitingStillOwnsTheRowAndAStepNeverImpliesWaiting() {
        let store = StatusStore()
        store.language = .en
        var row = storyRow()
        row.waiting = true
        row.waitKind = "Permission"
        row.waitMessage = "Approve deploy?"
        XCTAssertFalse(store.rowStoryLine(row).contains("Running the gates"))
        XCTAssertFalse(row.waiting == false, "nothing here may write Waiting either way")
    }
}
