import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

// 23.0 removed the observation, work and compute lines (and the CPU and
// memory facts they rendered) with `RowNarrator`; what a row says is pinned
// in `ExplainTests`. The focus-honesty rule below stays.

/// A workspace the disk could not confirm must not be offered as a landing.
final class BestEffortWorkspaceTests: XCTestCase {
    @MainActor
    func testAnUnverifiedWorkspaceDropsToAppPrecision() {
        let env = TerminalFocus.Environment(
            warpRunning: true,
            ttyHostRunning: true,
            allowTTYAutomation: true
        )
        let verified = TerminalFocus.focusTier(
            tty: "", viaWarp: false, hostApp: .cursor,
            workspace: "/Users/me/my-project", workspaceVerified: true, env: env
        )
        let guessed = TerminalFocus.focusTier(
            tty: "", viaWarp: false, hostApp: .cursor,
            workspace: "/Users/me/my/project", workspaceVerified: false, env: env
        )
        if case .hostWorkspace = verified {} else {
            XCTFail("a confirmed path still lands on the workspace: \(String(describing: verified))")
        }
        if case .hostApp = guessed {} else {
            XCTFail("an unconfirmed decode must not open a folder: \(String(describing: guessed))")
        }
    }
}
