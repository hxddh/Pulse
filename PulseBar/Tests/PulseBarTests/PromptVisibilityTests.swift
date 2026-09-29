import XCTest
@testable import PulseBar

/// Is the prompt already in front of the user? The hook receiver records the
/// answer in attention column 8 (`front`), so a blocked prompt already on
/// screen gets no banner. The walk is pure: the parent lookup is injected.
final class PromptVisibilityTests: XCTestCase {

    // MARK: - Is the prompt in front of the user?

    /// app 4321 → shell 900 → agent 500 → this hook 100.
    private let chain: [Int32: Int32] = [100: 500, 500: 900, 900: 4321, 4321: 1]

    func testTheFrontmostTerminalIsRecognisedThroughTheWholeChain() {
        XCTAssertEqual(
            PromptVisibility.isAncestor(4321, of: 100, parentOf: { self.chain[$0] }),
            true
        )
    }

    func testAnUnrelatedFrontmostAppIsNotAnAncestor() {
        // Zoom is in front; the agent's terminal is somewhere behind it.
        XCTAssertEqual(
            PromptVisibility.isAncestor(7777, of: 100, parentOf: { self.chain[$0] }),
            false,
            "the walk reached launchd without meeting it"
        )
    }

    func testADetachedChainReachingLaunchdIsUnknownNotFalse() {
        // hook 100 → agent 500 → shell 900 → tmux server 950 → launchd.
        // The terminal the user reads it in is not on this chain at all, so
        // reaching launchd proves nothing about whether they are looking.
        let tmux: [Int32: Int32] = [100: 500, 500: 900, 900: 950, 950: 1]
        XCTAssertNil(
            PromptVisibility.isAncestor(4321, of: 100, parentOf: { tmux[$0] }, isApp: { _ in false })
        )
    }

    func testAChainThroughAnAppReachingLaunchdIsFalse() {
        XCTAssertEqual(
            PromptVisibility.isAncestor(7777, of: 100, parentOf: { self.chain[$0] }, isApp: { $0 == 4321 }),
            false
        )
    }

    func testAProcessIsItsOwnAncestor() {
        XCTAssertEqual(
            PromptVisibility.isAncestor(100, of: 100, parentOf: { self.chain[$0] }),
            true
        )
    }

    func testAnUnreadableLinkIsUnknownNotFalse() {
        // "Could not tell" must never be spent as proof the user is looking
        // elsewhere — that would freeze an agent in front of a present user.
        XCTAssertNil(PromptVisibility.isAncestor(4321, of: 100, parentOf: { _ in nil }))
    }

    func testACycleTerminatesAsUnknown() {
        let loop: [Int32: Int32] = [100: 200, 200: 300, 300: 100]
        XCTAssertNil(PromptVisibility.isAncestor(4321, of: 100, parentOf: { loop[$0] }))
    }

    func testAChainTooLongToBeRealIsUnknown() {
        // Every parent is one lower, so the walk never reaches 1 and never
        // repeats: only the depth bound can stop it.
        XCTAssertNil(
            PromptVisibility.isAncestor(4321, of: 5000, parentOf: { $0 - 1 })
        )
    }

    func testNoFrontmostAppMeansUnknown() {
        XCTAssertNil(
            PromptVisibility.promptIsFrontmost(
                selfPID: 100, frontmost: nil, parentOf: { self.chain[$0] }
            )
        )
        XCTAssertNil(
            PromptVisibility.promptIsFrontmost(
                selfPID: 100, frontmost: 0, parentOf: { self.chain[$0] }
            )
        )
    }

    func testPromptVisibilityUsesTheChain() {
        XCTAssertEqual(
            PromptVisibility.promptIsFrontmost(
                selfPID: 100, frontmost: 4321, parentOf: { self.chain[$0] }, isApp: { $0 == 4321 }
            ),
            true
        )
        XCTAssertEqual(
            PromptVisibility.promptIsFrontmost(
                selfPID: 100, frontmost: 7777, parentOf: { self.chain[$0] }, isApp: { $0 == 4321 }
            ),
            false
        )
    }

    /// The real reader, against this very process. It must not crash, must not
    /// hang, and must agree with `getppid()`.
    func testTheRealParentLookupAgreesWithTheKernel() throws {
        let parent = try XCTUnwrap(PromptVisibility.parentPID(of: getpid()))
        XCTAssertEqual(parent, getppid())
    }
}
