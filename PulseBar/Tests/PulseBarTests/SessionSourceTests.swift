import XCTest
@testable import PulseBar

/// 5.0-α — the merge contract at the engine boundary. The observed pipeline
/// keeps its behavior by construction (single source = verbatim passthrough,
/// held by the whole existing suite); what needs its own tests is the
/// contract a second producer will rely on in 5.0-β.
@MainActor
final class SessionSourceTests: XCTestCase {

    private final class StubSource: SessionSource {
        let sourceID: String
        var sessions: [AgentRow]
        init(_ id: String, _ rows: [AgentRow]) {
            sourceID = id
            sessions = rows
        }
    }

    private func row(_ key: String, agent: AgentID = .claude) -> AgentRow {
        AgentRow(rowKey: key, agent: agent)
    }

    func testASingleSourceIsAVerbatimPassthrough() {
        let observed = ObservedSessionSource()
        let rows = [row("claude|b"), row("claude|a"), row("codex|c", agent: .codex)]
        observed.replaceSessions(rows)
        let merged = SessionSourceCoordinator(sources: [observed]).merged()
        XCTAssertEqual(merged.map(\.rowKey), ["claude|b", "claude|a", "codex|c"],
                       "order is the source's own — the merge is a supply, not a layout")
        XCTAssertEqual(merged, rows)
    }

    func testRegistrationOrderRanksSourcesAndOrderWithinEachSurvives() {
        let observed = StubSource("observed", [row("o1"), row("o2")])
        let managed = StubSource("managed", [row("m1"), row("m2")])
        let coordinator = SessionSourceCoordinator(sources: [observed])
        coordinator.register(managed)
        XCTAssertEqual(coordinator.merged().map(\.rowKey), ["o1", "o2", "m1", "m2"])
    }

    func testARowKeyCollisionGoesToTheFirstRegisteredSource() {
        var observedRow = row("claude|same")
        observedRow.task = "the observed truth"
        var managedRow = row("claude|same")
        managedRow.task = "a later claim"
        let coordinator = SessionSourceCoordinator(sources: [
            StubSource("observed", [observedRow]),
            StubSource("managed", [managedRow]),
        ])
        let merged = coordinator.merged()
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].task, "the observed truth",
                       "the observed pipeline stays ground truth for a key it also produces")
    }

    func testRegisteringTheSameSourceTwiceIsIdempotent() {
        let source = StubSource("managed", [row("m1")])
        let coordinator = SessionSourceCoordinator()
        coordinator.register(source)
        coordinator.register(source)
        XCTAssertEqual(coordinator.sources.count, 1)
        XCTAssertEqual(coordinator.merged().count, 1)
    }

    func testThePatchPathMutatesAndReportsTheMutatorsOwnAnswer() {
        let observed = ObservedSessionSource()
        observed.replaceSessions([row("claude|s1")])
        let changed = observed.patchSessions { rows in
            rows[0].liveTool = "Edit"
            return true
        }
        XCTAssertTrue(changed)
        XCTAssertEqual(observed.sessions[0].liveTool, "Edit")
        let unchanged = observed.patchSessions { _ in false }
        XCTAssertFalse(unchanged)
    }
}
