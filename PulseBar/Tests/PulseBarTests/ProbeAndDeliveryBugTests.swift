import XCTest
@testable import PulseBar

/// Regressions for two defects found by reading 0.99.0.
///
/// Both had the same shape: something that looked verified was not. One test
/// asserted a tool's output format the tool does not produce; one dictionary
/// assumed keys could not collide when two independent lists fed it.
final class ProbeAndDeliveryBugTests: XCTestCase {

    // MARK: - lsof workspace recovery

    /// The end-to-end shape: a real `-Ffpn -a -d cwd` reply for two processes,
    /// one of which lsof could not resolve.
    func testRealLsofReplyYieldsAWorkspacePerResolvableProcess() {
        let output = """
        p101
        fcwd
        n/Users/me/code/Pulse
        p202
        fcwd
        n/Users/me/code/Other
        p303
        fcwd
        n/Users/me/code/Locked (readlink: Permission denied)
        """
        let parsed = ProcessProbe.parseWorkingDirectories(output)
        XCTAssertEqual(parsed[101], "/Users/me/code/Pulse")
        XCTAssertEqual(parsed[202], "/Users/me/code/Other")
        XCTAssertEqual(
            ProcessProbe.usefulWorkingDirectory(parsed[303] ?? ""), "",
            "an lsof error annotation is not a workspace"
        )
    }

    func testUnreadableDirectoryAnnotationIsRejected() {
        XCTAssertEqual(
            ProcessProbe.usefulWorkingDirectory("/Users/me/x (readlink: Permission denied)"),
            ""
        )
        XCTAssertEqual(
            ProcessProbe.usefulWorkingDirectory("/Users/me/x (stat: No such file or directory)"),
            ""
        )
        XCTAssertEqual(
            ProcessProbe.usefulWorkingDirectory("/Users/me/code/Pulse"),
            "/Users/me/code/Pulse"
        )
    }

    /// A directory whose name simply contains a parenthesis is still a
    /// workspace — the annotation check is anchored, not a blanket ban.
    func testAnOrdinaryDirectoryWithParenthesesIsStillAWorkspace() {
        XCTAssertFalse(ProcessProbe.isLsofErrorAnnotated("/Users/me/Documents/Work (old)"))
        XCTAssertEqual(
            ProcessProbe.usefulWorkingDirectory("/Users/me/Documents/Work (old)"),
            "/Users/me/Documents/Work (old)"
        )
    }

    // MARK: - Waiting delivery must not trap on a duplicate row key

    /// A queued edge and a fresh edge for the same session used to reach
    /// `Dictionary(uniqueKeysWithValues:)` together and crash the app.
    @MainActor
    func testAQueuedRowAndAFreshEdgeForTheSameSessionDoNotCrash() {
        var queued = AgentRow(rowKey: "codex|abc", agent: .codex)
        queued.waiting = true
        queued.waitSinceMs = 1_000
        queued.task = "the queued copy"

        var fresh = queued
        fresh.waitSinceMs = 9_000
        fresh.task = "the newer wait"

        let rows = StatusStore.waitingDeliveryRows(edges: [fresh], queued: [queued])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.task, "the newer wait", "the fresh edge wins")
    }

    @MainActor
    func testDistinctSessionsAreAllDelivered() {
        var a = AgentRow(rowKey: "codex|a", agent: .codex)
        a.waiting = true
        var b = AgentRow(rowKey: "claude|b", agent: .claude)
        b.waiting = true
        var c = AgentRow(rowKey: "cursor|c", agent: .cursor)
        c.waiting = true

        let rows = StatusStore.waitingDeliveryRows(edges: [a, b], queued: [c])
        XCTAssertEqual(Set(rows.map(\.rowKey)), ["codex|a", "claude|b", "cursor|c"])
    }

    @MainActor
    func testNoEdgesAndNoQueueIsEmpty() {
        XCTAssertTrue(StatusStore.waitingDeliveryRows(edges: [], queued: []).isEmpty)
    }
}
