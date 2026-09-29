import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest
@testable import PulseRespond

/// Respond (scene AR) — attachment rules for the full requests this Mac's
/// agents are holding for.
///
/// The one thing every assertion protects: a verdict control must never appear
/// on a row that the verdict could not actually answer.
final class StatusStoreRespondTests: XCTestCase {

    private let now: Int64 = 1_800_000_000_000

    @MainActor
    private func row(
        key: String = "claude|s1",
        agent: AgentID = .claude,
        session: String = "s1"
    ) -> AgentRow {
        var row = AgentRow(rowKey: key, agent: agent)
        row.observationSource = .session
        row.sessionID = session
        row.waiting = true
        return row
    }

    @MainActor
    private func inbound(
        id: String = "toolu_1",
        agent: AgentID = .claude,
        session: String = "s1",
        receivedAtMs: Int64 = 0
    ) -> RespondSpool.InboundRequest {
        RespondSpool.InboundRequest(
            request: PermissionRequest(
                id: id,
                agent: agent,
                host: "thismac",
                session: session,
                fullRequest: #"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#,
                truncated: false,
                receivedAtMs: receivedAtMs
            ),
            toolName: "Bash",
            expiresAtMs: now + 60_000
        )
    }

    @MainActor
    func testThisMacsOwnRequestAttachesToItsRow() {
        let matched = StatusStore.matchRespondInbound([inbound()], rows: [row()])
        XCTAssertEqual(
            matched["claude|s1"]?.request.id,
            "toolu_1",
            "the whole point of 2.4: on one Mac, Respond used to attach to nothing"
        )
    }

    @MainActor
    func testARequestStillHonoursAgentAndSession() {
        XCTAssertTrue(
            StatusStore.matchRespondInbound([inbound(agent: .codex)], rows: [row(agent: .claude)]).isEmpty
        )
        XCTAssertTrue(
            StatusStore.matchRespondInbound([inbound(session: "s2")], rows: [row(session: "s1")]).isEmpty
        )
    }

    @MainActor
    func testARequestWithoutAHostAttachesToNothing() {
        var request = inbound()
        request.request.host = ""
        XCTAssertTrue(StatusStore.matchRespondInbound([request], rows: [row()]).isEmpty)
    }

    @MainActor
    func testNewestRequestWinsWhenTwoAttach() {
        let older = inbound(id: "toolu_old", receivedAtMs: now - 60_000)
        let newer = inbound(id: "toolu_new", receivedAtMs: now)
        let matched = StatusStore.matchRespondInbound([older, newer], rows: [row()])
        XCTAssertEqual(matched["claude|s1"]?.request.id, "toolu_new")
    }

    @MainActor
    func testEmptySessionOnEitherSideStillMatchesByAgent() {
        let matched = StatusStore.matchRespondInbound([inbound(session: "")], rows: [row(session: "s1")])
        XCTAssertEqual(matched.count, 1, "a hook may not know its session id")
    }

    /// E-2: the matcher used to run over `snapshot.rows`, which the tray
    /// window has already clipped. A permission request on an agent pushed
    /// out of the visible list lost every Respond control it had.
    @MainActor
    func testARowOutsideTheVisibleWindowStillGetsItsControls() {
        // The window is a display budget; the hook holding for this request
        // has no idea what the tray decided to draw.
        let hidden = row(key: "claude|s9", session: "s9")
        let matched = StatusStore.matchRespondInbound(
            [inbound(id: "toolu_hidden", session: "s9")],
            rows: [hidden]
        )
        XCTAssertEqual(matched["claude|s9"]?.request.id, "toolu_hidden")
    }

    // MARK: - H-1 · the verdict answers the request that was on screen

    @MainActor
    func testAllowRefusesARequestThatReplacedTheShownOne() {
        let shownA = StatusStore.RespondShown(inbound(id: "toolu_A", receivedAtMs: 1))
        // A newer request B arrived on the same row between draw and click.
        let matched = StatusStore.matchRespondInbound(
            [inbound(id: "toolu_A", receivedAtMs: 1), inbound(id: "toolu_B", receivedAtMs: 2)],
            rows: [row()]
        )
        let attached = matched["claude|s1"]
        XCTAssertEqual(attached?.request.id, "toolu_B")
        XCTAssertNil(StatusStore.respondTarget(attached: attached, shown: shownA, allow: true))
        XCTAssertNil(StatusStore.respondTarget(attached: attached, shown: shownA, allow: false))
    }

    @MainActor
    func testAllowAnswersTheShownRequest() {
        let a = inbound(id: "toolu_A")
        let target = StatusStore.respondTarget(attached: a, shown: .init(a), allow: true)
        XCTAssertEqual(target?.request.id, "toolu_A")
    }

    @MainActor
    func testAllowNeverResolvesWithoutAShownRequest() {
        XCTAssertNil(StatusStore.respondTarget(attached: inbound(), shown: nil, allow: true))
    }

    @MainActor
    func testDenyWithoutAShownRequestAnswersWhateverIsAttached() {
        XCTAssertEqual(
            StatusStore.respondTarget(attached: inbound(), shown: nil, allow: false)?.request.id,
            "toolu_1"
        )
    }

    @MainActor
    func testSameIDWithDifferentContentIsNotTheShownRequest() {
        let a = inbound(id: "toolu_A")
        var edited = a
        edited.request.fullRequest = #"{"tool_name":"Bash","tool_input":{"command":"rm -rf ~"}}"#
        XCTAssertNil(StatusStore.respondTarget(attached: edited, shown: .init(a), allow: true))
    }
}
