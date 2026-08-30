import XCTest
@testable import PulseBar

/// 5.0-β — the managed runtime's deterministic core: the state machine the
/// stream drives, the argv a turn runs, the NDJSON reassembly, and the
/// model→row mapping. The process half gets the real-machine script
/// (scripts/qa_managed_session.sh); everything here runs on fixtures.
final class ManagedSessionTests: XCTestCase {

    private let now: Int64 = 1_800_000_000_000

    private func model(task: String = "fix the login bug") -> ManagedSession.Model {
        ManagedSession.Model(id: "m1", task: task, root: "/tmp/wt", isWorktree: true, nowMs: now)
    }

    private func apply(_ m: inout ManagedSession.Model, _ json: String) {
        for event in ClaudeManagedRuntime.decode(line: Data(json.utf8)) {
            m.apply(event: event, nowMs: now + 1000)
        }
    }

    // MARK: - The state machine

    func testTheInitEventNamesTheSessionAndModel() {
        var m = model()
        apply(&m, #"{"type":"system","subtype":"init","session_id":"abc-123","model":"claude-fable-5"}"#)
        XCTAssertEqual(m.continuationID, "abc-123")
        XCTAssertEqual(m.modelName, "claude-fable-5")
    }

    func testAssistantEventsBecomeConversationEntriesThroughTheOneParser() {
        var m = model()
        apply(&m, #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Looking."},{"type":"tool_use","name":"Edit","input":{"file_path":"/repo/a.swift"}}]}}"#)
        XCTAssertEqual(m.entries.map(\.kind), [.agent, .tool])
        XCTAssertEqual(m.currentTool, "Edit")
    }

    func testAFailedToolResultLandsInLastError() {
        var m = model()
        apply(&m, #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"build failed","is_error":true}]}}"#)
        XCTAssertEqual(m.lastErrorText, "build failed")
    }

    func testAResultEventEndsTheTurnAndAccumulatesCostAndTokens() {
        var m = model()
        m.status = .running
        apply(&m, #"{"type":"result","subtype":"success","is_error":false,"result":"done","total_cost_usd":0.25,"usage":{"input_tokens":100,"output_tokens":50},"session_id":"abc"}"#)
        XCTAssertEqual(m.status, .idle)
        XCTAssertEqual(m.turns, 1)
        XCTAssertEqual(m.totalCostUSD, 0.25, accuracy: 0.0001)
        XCTAssertEqual(m.tokensIn, 100)
        XCTAssertEqual(m.tokensOut, 50)
        XCTAssertEqual(m.lastResultText, "done")
        XCTAssertEqual(m.continuationID, "abc")
        XCTAssertEqual(m.currentTool, "", "the turn is over; nothing is running now")
    }

    func testAnErrorResultIsAFailedTurnWithItsReason() {
        var m = model()
        m.status = .running
        apply(&m, #"{"type":"result","subtype":"error_max_turns","is_error":true,"total_cost_usd":0.1}"#)
        XCTAssertEqual(m.status, .failed("error_max_turns"))
        XCTAssertEqual(m.errorResults, 1)
        XCTAssertEqual(m.lastErrorText, "error_max_turns")
    }

    func testUnknownEventsAndNonJSONLinesAreCountedApart() {
        var m = model()
        apply(&m, #"{"type":"stream_event","payload":{}}"#)
        apply(&m, "not json")
        XCTAssertEqual(m.unknownEvents, 1)
        XCTAssertEqual(m.unparsedLines, 1)
        XCTAssertTrue(m.entries.isEmpty)
    }

    func testTheTitleIsTheTasksFirstLineSanitizedAndBounded() {
        let m = model(task: "deploy with key sk-proj-abcdefghijklmnop123\nsecond line")
        XCTAssertFalse(m.title.contains("sk-proj-abcdefghijklmnop123"))
        XCTAssertFalse(m.title.contains("second line"))
    }

    // MARK: - The argv a turn runs

    func testTheFirstTurnArgvCarriesThePromptAsOneArgument() {
        XCTAssertEqual(
            ClaudeManagedRuntime.arguments(prompt: "fix it; $(echo owned)", continuation: nil),
            ["-p", "fix it; $(echo owned)", "--output-format", "stream-json", "--verbose"],
            "argv, never a shell — metacharacters are just characters"
        )
    }

    func testAResumeTurnAppendsTheSessionIdAfterTheShapeGate() {
        let args = ClaudeManagedRuntime.arguments(prompt: "continue", continuation: "abc-123")
        XCTAssertEqual(args.map { Array($0.suffix(2)) }, ["--resume", "abc-123"])
        XCTAssertNil(
            ClaudeManagedRuntime.arguments(prompt: "continue", continuation: "bad id"),
            "a malformed id refuses the turn rather than improvising a fresh session"
        )
        XCTAssertNil(ClaudeManagedRuntime.arguments(prompt: "   ", continuation: nil))
    }

    func testExecutableLookupTakesTheFirstCandidateThatExists() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(
            ClaudeManagedRuntime.executable(fileExists: { $0 == home + "/.local/bin/claude" }),
            home + "/.local/bin/claude"
        )
        XCTAssertNil(ClaudeManagedRuntime.executable(fileExists: { _ in false }))
    }

    // MARK: - NDJSON reassembly

    func testASplitEventReassemblesAcrossChunks() {
        var buffer = ManagedSession.LineBuffer()
        XCTAssertTrue(buffer.lines(from: Data(#"{"type":"sys"#.utf8)).isEmpty)
        let lines = buffer.lines(from: Data("tem\"}\n{\"a\":1}\n".utf8))
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(String(decoding: lines[0], as: UTF8.self), #"{"type":"system"}"#)
        XCTAssertNil(buffer.flush())
    }

    func testTheFlushHandsBackAnUnterminatedFinalLine() {
        var buffer = ManagedSession.LineBuffer()
        _ = buffer.lines(from: Data("{\"a\":1}".utf8))
        XCTAssertEqual(buffer.flush().map { String(decoding: $0, as: UTF8.self) }, "{\"a\":1}")
        XCTAssertNil(buffer.flush(), "flushed means gone")
    }

    // MARK: - Model → row

    func testTheRowCarriesFirstPartyFactsAndTheManagedIdentity() {
        var m = model()
        m.status = .running
        m.continuationID = "abc"
        m.modelName = "claude-fable-5"
        m.currentTool = "Bash"
        m.tokensIn = 10
        m.tokensOut = 5
        m.lastEventMs = now + 5000
        let row = ManagedSessionSource.row(for: m)
        XCTAssertEqual(row.rowKey, "managed|m1")
        XCTAssertTrue(row.isManaged)
        XCTAssertEqual(row.agent, .claude)
        XCTAssertTrue(row.liveProcess)
        XCTAssertEqual(row.tool, "Bash")
        XCTAssertEqual(row.workspaceRoot, "/tmp/wt",
                       "a Pulse-created worktree is disk-confirmed by construction")
        XCTAssertEqual(row.harvestMs, now + 5000)
        XCTAssertEqual(row.observationSource, .session)
    }

    func testAManagedRowKeyCanNeverCollideWithAnObservedOne() {
        // Observed keys are agent|session or agent|project shapes; the
        // managed namespace is its own prefix.
        let row = ManagedSessionSource.row(for: model())
        XCTAssertTrue(row.rowKey.hasPrefix("managed|"))
    }
}
