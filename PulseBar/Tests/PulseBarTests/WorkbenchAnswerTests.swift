import XCTest
@testable import PulseBar

/// 3.0 — the answer verb's routing and the command it builds. Everything here
/// is pure: the store method that copies to the clipboard is a thin shell
/// over these functions, and the invariant under test is the same one the
/// product states — Pulse builds the command, the user runs it.
final class WorkbenchAnswerTests: XCTestCase {

    private let sid = "550e8400-e29b-41d4-a716-446655440000"

    // MARK: - Routing

    func testAFullRequestAlwaysWinsTheChannel() {
        // Even a remote permission wait routes to Respond when the request
        // file is attached — that channel has a receipt, nothing else does.
        XCTAssertEqual(
            WorkbenchAnswer.channel(
                agent: .codex, isRemote: true, waiting: true,
                waitKind: "Permission", sessionID: "", hasRespondRequest: true
            ),
            .respond
        )
    }

    func testALocalClaudeQuestionGetsTheResumeChannel() {
        XCTAssertEqual(
            WorkbenchAnswer.channel(
                agent: .claude, isRemote: false, waiting: true,
                waitKind: "Input", sessionID: sid, hasRespondRequest: false
            ),
            .resume
        )
    }

    func testARowThatIsNotWaitingHasNoChannelAtAll() {
        XCTAssertNil(
            WorkbenchAnswer.channel(
                agent: .claude, isRemote: false, waiting: false,
                waitKind: "", sessionID: sid, hasRespondRequest: false
            )
        )
    }

    func testAPermissionWaitWithoutARequestIsFocusOnly() {
        // The vendor's own prompt is already in front of the user; a second
        // answer box racing it would be the blind approve in disguise.
        XCTAssertEqual(
            WorkbenchAnswer.channel(
                agent: .claude, isRemote: false, waiting: true,
                waitKind: "Permission", sessionID: sid, hasRespondRequest: false
            ),
            .focusOnly
        )
    }

    func testARemoteQuestionCannotBeResumedFromHere() {
        // The session's terminal is on another machine; a prefilled command
        // here would resume nothing.
        XCTAssertEqual(
            WorkbenchAnswer.channel(
                agent: .claude, isRemote: true, waiting: true,
                waitKind: "Input", sessionID: sid, hasRespondRequest: false
            ),
            .focusOnly
        )
    }

    func testAnUnverifiedVendorNeverGetsAPrefilledCommand() {
        XCTAssertEqual(
            WorkbenchAnswer.channel(
                agent: .codex, isRemote: false, waiting: true,
                waitKind: "Input", sessionID: sid, hasRespondRequest: false
            ),
            .focusOnly
        )
    }

    func testABadSessionIDDowngradesToFocusOnly() {
        XCTAssertEqual(
            WorkbenchAnswer.channel(
                agent: .claude, isRemote: false, waiting: true,
                waitKind: "Input", sessionID: "id; rm -rf ~", hasRespondRequest: false
            ),
            .focusOnly
        )
    }

    // MARK: - The session id's shape gate

    func testARealUUIDPassesTheGate() {
        XCTAssertTrue(WorkbenchAnswer.validSessionID(sid))
        XCTAssertTrue(WorkbenchAnswer.validSessionID("abc_123.v2"))
    }

    func testAnythingOutsideTheAlphabetIsRefused() {
        XCTAssertFalse(WorkbenchAnswer.validSessionID(""))
        XCTAssertFalse(WorkbenchAnswer.validSessionID("has space"))
        XCTAssertFalse(WorkbenchAnswer.validSessionID("id;evil"))
        XCTAssertFalse(WorkbenchAnswer.validSessionID("id$(cmd)"))
        XCTAssertFalse(WorkbenchAnswer.validSessionID("id`cmd`"))
        XCTAssertFalse(WorkbenchAnswer.validSessionID("会话"))
        XCTAssertFalse(WorkbenchAnswer.validSessionID(String(repeating: "a", count: 129)))
    }

    // MARK: - The command itself

    func testAnEmptyReplyBuildsABareResume() {
        XCTAssertEqual(
            WorkbenchAnswer.resumeCommand(sessionID: sid, answer: "   \n"),
            "claude --resume \(sid)"
        )
    }

    func testAReplyRidesAsOneSingleQuotedArgument() {
        XCTAssertEqual(
            WorkbenchAnswer.resumeCommand(sessionID: sid, answer: "yes, ship it"),
            "claude --resume \(sid) 'yes, ship it'"
        )
    }

    func testASingleQuoteInTheReplyCannotEscapeTheQuoting() {
        XCTAssertEqual(
            WorkbenchAnswer.resumeCommand(sessionID: sid, answer: "it's done"),
            "claude --resume \(sid) 'it'\\''s done'"
        )
    }

    func testShellMetacharactersStayLiteralInsideTheQuotes() {
        let quoted = WorkbenchAnswer.shellQuoted("$(evil) `evil` ; && | > $HOME")
        XCTAssertTrue(quoted.hasPrefix("'"))
        XCTAssertTrue(quoted.hasSuffix("'"))
        // No bare single quote anywhere between the outer pair: once every
        // '\'' escape sequence is removed, no quote may remain.
        let interior = String(quoted.dropFirst().dropLast())
        let cleaned = interior.replacingOccurrences(of: "'\\''", with: "")
        XCTAssertFalse(cleaned.contains("'"), quoted)
    }

    func testABadSessionIDBuildsNothing() {
        XCTAssertNil(WorkbenchAnswer.resumeCommand(sessionID: "id evil", answer: "hi"))
    }
}
