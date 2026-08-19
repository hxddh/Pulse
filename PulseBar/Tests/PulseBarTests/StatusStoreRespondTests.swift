import XCTest
@testable import PulseBar

/// Respond (scene AR) — attachment rules for inbound full requests.
///
/// The one thing every assertion protects: a verdict control must never appear
/// on a row that the verdict could not actually answer. A local row's hook
/// will not collect anything; another host's row is another machine.
@MainActor
final class StatusStoreRespondTests: XCTestCase {

    private let now: Int64 = 1_800_000_000_000

    private func remoteRow(
        key: String = "claude|s1@devbox",
        agent: AgentID = .claude,
        host: String = "devbox",
        session: String = "s1"
    ) -> AgentRow {
        var row = AgentRow(rowKey: key, agent: agent)
        row.host = host
        row.observationSource = .remote
        row.sessionID = session
        row.waiting = true
        return row
    }

    private func inbound(
        id: String = "toolu_1",
        agent: AgentID = .claude,
        host: String = "devbox",
        session: String = "s1",
        receivedAtMs: Int64 = 0
    ) -> RespondSpool.InboundRequest {
        RespondSpool.InboundRequest(
            request: PermissionRequest(
                id: id,
                agent: agent,
                host: host,
                session: session,
                fullRequest: #"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#,
                truncated: false,
                receivedAtMs: receivedAtMs
            ),
            toolName: "Bash",
            expiresAtMs: now + 60_000
        )
    }

    func testRequestAttachesToItsRemoteRow() {
        let matched = StatusStore.matchRespondInbound([inbound()], rows: [remoteRow()])
        XCTAssertEqual(matched["claude|s1@devbox"]?.request.id, "toolu_1")
    }

    /// A request that arrived from another machine must not land on a row
    /// this Mac is observing: the hook waiting for that verdict is over there.
    func testARemoteRequestNeverAttachesToALocalRow() {
        var local = remoteRow(key: "claude|s1", host: "", session: "s1")
        local.observationSource = .session
        local.host = ""
        let matched = StatusStore.matchRespondInbound([inbound()], rows: [local])
        XCTAssertTrue(matched.isEmpty, "the hook holding for this one is on another machine")
    }

    func testAnotherHostsRowDoesNotCollect() {
        let other = remoteRow(key: "claude|s1@laptop", host: "laptop")
        let matched = StatusStore.matchRespondInbound([inbound()], rows: [other])
        XCTAssertTrue(matched.isEmpty, "host is part of the binding, not a display detail")
    }

    func testSessionMismatchDoesNotCollect() {
        let matched = StatusStore.matchRespondInbound(
            [inbound(session: "s2")],
            rows: [remoteRow(session: "s1")]
        )
        XCTAssertTrue(matched.isEmpty)
    }

    func testNewestRequestWinsWhenTwoAttach() {
        let older = inbound(id: "toolu_old", receivedAtMs: now - 60_000)
        let newer = inbound(id: "toolu_new", receivedAtMs: now)
        let matched = StatusStore.matchRespondInbound([older, newer], rows: [remoteRow()])
        XCTAssertEqual(matched["claude|s1@devbox"]?.request.id, "toolu_new")
    }

    func testEmptySessionOnEitherSideStillMatchesByHostAndAgent() {
        let matched = StatusStore.matchRespondInbound(
            [inbound(session: "")],
            rows: [remoteRow(session: "s1")]
        )
        XCTAssertEqual(matched.count, 1, "a v1 remote hook may not know its session id")
    }

    // MARK: 2.4 · this Mac's own requests

    private func localRow(
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

    private func localInbound(
        id: String = "toolu_local",
        agent: AgentID = .claude,
        session: String = "s1"
    ) -> RespondSpool.InboundRequest {
        var request = inbound(id: id, agent: agent, host: "thismac", session: session)
        request.isLocal = true
        return request
    }

    func testThisMacsOwnRequestAttachesToItsLocalRow() {
        let matched = StatusStore.matchRespondInbound([localInbound()], rows: [localRow()])
        XCTAssertEqual(
            matched["claude|s1"]?.request.id,
            "toolu_local",
            "the whole point of 2.4: on one Mac, Respond used to attach to nothing"
        )
    }

    func testALocalRequestNeverAttachesToARemoteRow() {
        let matched = StatusStore.matchRespondInbound([localInbound()], rows: [remoteRow()])
        XCTAssertTrue(matched.isEmpty, "the hook holding for this one is here, not on devbox")
    }

    func testALocalRequestStillHonoursAgentAndSession() {
        XCTAssertTrue(
            StatusStore.matchRespondInbound(
                [localInbound(agent: .codex)], rows: [localRow(agent: .claude)]
            ).isEmpty
        )
        XCTAssertTrue(
            StatusStore.matchRespondInbound(
                [localInbound(session: "s2")], rows: [localRow(session: "s1")]
            ).isEmpty
        )
    }

    func testLocalAndRemoteRequestsDoNotCrossOver() {
        let rows = [localRow(), remoteRow()]
        let matched = StatusStore.matchRespondInbound([localInbound(), inbound()], rows: rows)
        XCTAssertEqual(matched["claude|s1"]?.request.id, "toolu_local")
        XCTAssertEqual(matched["claude|s1@devbox"]?.request.id, "toolu_1")
    }
}
