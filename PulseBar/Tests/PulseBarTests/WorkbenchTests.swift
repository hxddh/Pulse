import XCTest
@testable import PulseBar

/// 3.0-β Mission Control — what the workbench may do and what it may not.
///
/// The window is view code and lives or dies by hand; what these tests hold
/// is the one piece with rules worth freezing: the diff loader, which must
/// keep the measurement's read-only discipline (plumbing verb, bounded
/// output) even though it now carries content instead of counts.
final class WorkbenchTests: XCTestCase {

    func testThePatchKeepsTheReadOnlyVerbAndItsEnvironment() {
        let previous = WorkspaceEffect.runner
        defer { WorkspaceEffect.runner = previous }
        var seen: [[String]] = []
        WorkspaceEffect.runner = { _, command in
            seen.append(command)
            return ProcessIO.Result(
                stdout: Data("diff --git a/f b/f\n".utf8),
                stderr: Data(), status: 0, timedOut: false
            )
        }
        let patch = WorkspaceEffect.patch(root: "/repo")
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.first, "diff-index",
                       "the workbench diff stays inside the measurement's verb set — porcelain diff writes the index (2.7's lesson)")
        XCTAssertEqual(patch?.text.contains("diff --git"), true)
        XCTAssertEqual(patch?.truncated, false)
    }

    func testThePatchIsBoundedAndSaysSo() {
        let previous = WorkspaceEffect.runner
        defer { WorkspaceEffect.runner = previous }
        WorkspaceEffect.runner = { _, _ in
            ProcessIO.Result(
                stdout: Data(String(repeating: "x", count: WorkspaceEffect.maxPatchBytes + 500).utf8),
                stderr: Data(), status: 0, timedOut: false
            )
        }
        let patch = WorkspaceEffect.patch(root: "/repo")
        XCTAssertEqual(patch?.truncated, true, "a cut view must say it was cut")
        XCTAssertEqual(patch?.text.utf8.count, WorkspaceEffect.maxPatchBytes)
    }

    func testAFailedOrTimedOutPatchShowsNothingRatherThanSomethingInvented() {
        let previous = WorkspaceEffect.runner
        defer { WorkspaceEffect.runner = previous }
        WorkspaceEffect.runner = { _, _ in
            ProcessIO.Result(stdout: Data("partial".utf8), stderr: Data(), status: 128, timedOut: false)
        }
        XCTAssertNil(WorkspaceEffect.patch(root: "/repo"))
        WorkspaceEffect.runner = { _, _ in
            ProcessIO.Result(stdout: Data(), stderr: Data(), status: 0, timedOut: true)
        }
        XCTAssertNil(WorkspaceEffect.patch(root: "/repo"))
    }
}
