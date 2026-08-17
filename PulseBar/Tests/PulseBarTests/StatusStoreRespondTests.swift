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

    func testALocalRowNeverGetsARespondControl() {
        var local = remoteRow(key: "claude|s1", host: "", session: "s1")
        local.observationSource = .session
        local.host = ""
        let matched = StatusStore.matchRespondInbound([inbound()], rows: [local])
        XCTAssertTrue(matched.isEmpty, "local rows never hold; offering an answer would be a lie")
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
}
