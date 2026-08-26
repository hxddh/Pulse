import XCTest
@testable import PulseBar

/// 4.0-β — the pure half of delivery and dispatch. The AppleScript execution
/// itself only a real machine can verify (scripts/qa_workbench_actuation.sh);
/// what tests can pin is everything that decides what reaches it: the
/// escaping, the collapsing, the command, and the routing.
final class WorkbenchActuationTests: XCTestCase {

    private let sid = "550e8400-e29b-41d4-a716-446655440000"

    // MARK: - The reply that will be typed

    func testANewlineCollapsesInsteadOfSubmittingHalfAReply() {
        XCTAssertEqual(
            WorkbenchActuation.collapsedReply("line one\nline two\r\nthree\ttabbed"),
            "line one line two three tabbed"
        )
    }

    func testTheReplyIsBoundedForPerCharacterDelivery() {
        let long = String(repeating: "a", count: WorkbenchActuation.maxReplyChars + 100)
        XCTAssertEqual(
            WorkbenchActuation.collapsedReply(long).count,
            WorkbenchActuation.maxReplyChars
        )
    }

    func testAppleScriptQuotingEscapesQuotesAndBackslashes() {
        XCTAssertEqual(
            WorkbenchActuation.appleScriptQuoted(#"say "hi" \ done"#),
            #""say \"hi\" \\ done""#
        )
    }

    // MARK: - The dispatch command

    func testDispatchQuotesRootAndTask() {
        XCTAssertEqual(
            WorkbenchActuation.dispatchCommand(root: "/Users/me/proj", task: "fix the bug"),
            "cd '/Users/me/proj' && claude 'fix the bug'"
        )
    }

    func testAnEmptyTaskStartsABareSession() {
        XCTAssertEqual(
            WorkbenchActuation.dispatchCommand(root: "/Users/me/proj", task: "  "),
            "cd '/Users/me/proj' && claude"
        )
    }

    func testATaskWithAQuoteCannotEscapeItsArgument() {
        XCTAssertEqual(
            WorkbenchActuation.dispatchCommand(root: "/r", task: "it's urgent"),
            "cd '/r' && claude 'it'\\''s urgent'"
        )
    }

    func testARelativeOrTrivialRootNeverReachesAShell() {
        XCTAssertNil(WorkbenchActuation.dispatchCommand(root: "relative/path", task: "x"))
        XCTAssertNil(WorkbenchActuation.dispatchCommand(root: "", task: "x"))
        XCTAssertNil(WorkbenchActuation.dispatchCommand(root: "/", task: "x"))
        XCTAssertNil(WorkbenchActuation.dispatchCommand(root: "/tmp", task: "x"))
    }

    // MARK: - Routing with the type channel

    func testTypingBeatsTheResumeCommandWhenTheTabIsAddressable() {
        XCTAssertEqual(
            WorkbenchAnswer.channel(
                agent: .claude, isRemote: false, waiting: true,
                waitKind: "Input", sessionID: sid,
                hasRespondRequest: false, canType: true
            ),
            .type
        )
    }

    func testTypingIsVendorBlindWhereResumeWasNot() {
        // Codex has no trusted resume flag, but typing answers its prompt
        // the same as anyone's — the channel is about the tab, not the CLI.
        XCTAssertEqual(
            WorkbenchAnswer.channel(
                agent: .codex, isRemote: false, waiting: true,
                waitKind: "Input", sessionID: "", hasRespondRequest: false, canType: true
            ),
            .type
        )
    }

    func testARespondRequestStillOutranksTyping() {
        XCTAssertEqual(
            WorkbenchAnswer.channel(
                agent: .claude, isRemote: false, waiting: true,
                waitKind: "Input", sessionID: sid,
                hasRespondRequest: true, canType: true
            ),
            .respond
        )
    }

    func testAPermissionWaitRefusesKeystrokesEvenWithTheGrant() {
        // Typing at a y/n prompt would be the blind approve with extra steps.
        XCTAssertEqual(
            WorkbenchAnswer.channel(
                agent: .claude, isRemote: false, waiting: true,
                waitKind: "Permission", sessionID: sid,
                hasRespondRequest: false, canType: true
            ),
            .focusOnly
        )
    }

    func testWithoutTheGateTheOldRoutingStands() {
        XCTAssertEqual(
            WorkbenchAnswer.channel(
                agent: .claude, isRemote: false, waiting: true,
                waitKind: "Input", sessionID: sid,
                hasRespondRequest: false, canType: false
            ),
            .resume
        )
    }

    // MARK: - The precision gate on the store

    @MainActor
    func testOnlyATTYTierRowWithTheGrantCanTakeTypedDelivery() {
        let store = StatusStore()
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.waiting = true
        row.tty = "ttys004"
        store.allowWorkbenchActuation = true

        row.focusTier = .tty
        XCTAssertTrue(store.workbenchCanType(row))

        // App-level focus cannot promise where keystrokes land.
        row.focusTier = .warp
        XCTAssertFalse(store.workbenchCanType(row))
        row.focusTier = .hostApp(.vsCode)
        XCTAssertFalse(store.workbenchCanType(row))
        row.focusTier = nil
        XCTAssertFalse(store.workbenchCanType(row))

        // The switch is the consent — off refuses even a perfect tab.
        row.focusTier = .tty
        store.allowWorkbenchActuation = false
        XCTAssertFalse(store.workbenchCanType(row))
    }
}
