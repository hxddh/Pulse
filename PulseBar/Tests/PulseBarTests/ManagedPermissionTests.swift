import XCTest
@testable import PulseBar

/// 6.0-β — the permission channel: the MCP dialect with an injected
/// decision, the spool's identity and single-use rules, the timeout that
/// denies, and the Respond gate holding at the fleet.
final class ManagedPermissionTests: XCTestCase {

    private var spool: URL!

    override func setUpWithError() throws {
        spool = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-perm-\(UUID().uuidString)", isDirectory: true)
        ManagedPermission.spoolDirectoryOverride = spool
    }

    override func tearDownWithError() throws {
        ManagedPermission.spoolDirectoryOverride = nil
        if let spool { try? FileManager.default.removeItem(at: spool) }
    }

    private func json(_ line: String?) throws -> [String: Any] {
        let data = try XCTUnwrap(line?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func instantAllow(_ request: ManagedPermission.Request) -> ManagedPermission.Verdict {
        .init(id: request.id, allow: true, message: "")
    }

    // MARK: - The dialect

    func testInitializeAnswersWithTheServerIdentity() throws {
        let reply = try json(ManagedPermission.handle(
            line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            managedID: "m1", nowMs: 1, decide: instantAllow
        ))
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05")
        let info = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(info["name"] as? String, "pulse-permission")
    }

    func testToolsListOffersExactlyTheApproveTool() throws {
        let reply = try json(ManagedPermission.handle(
            line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            managedID: "m1", nowMs: 1, decide: instantAllow
        ))
        let tools = try XCTUnwrap((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.map { $0["name"] as? String }, ["approve"])
    }

    func testAnAllowedCallEchoesTheOriginalInputUnchanged() throws {
        let reply = try json(ManagedPermission.handle(
            line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"approve","arguments":{"tool_name":"Bash","input":{"command":"ls -la"}}}}"#,
            managedID: "m1", nowMs: 1, decide: instantAllow
        ))
        let content = try XCTUnwrap((reply["result"] as? [String: Any])?["content"] as? [[String: Any]])
        let payload = try json(content.first?["text"] as? String)
        XCTAssertEqual(payload["behavior"] as? String, "allow")
        XCTAssertEqual((payload["updatedInput"] as? [String: Any])?["command"] as? String, "ls -la")
    }

    func testADeniedCallCarriesItsMessage() throws {
        let reply = try json(ManagedPermission.handle(
            line: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"approve","arguments":{"tool_name":"Bash","input":{}}}}"#,
            managedID: "m1", nowMs: 1,
            decide: { .init(id: $0.id, allow: false, message: "nope") }
        ))
        let content = try XCTUnwrap((reply["result"] as? [String: Any])?["content"] as? [[String: Any]])
        let payload = try json(content.first?["text"] as? String)
        XCTAssertEqual(payload["behavior"] as? String, "deny")
        XCTAssertEqual(payload["message"] as? String, "nope")
    }

    func testTheDecisionSeesTheToolNameAndFullInput() {
        var seen: ManagedPermission.Request?
        _ = ManagedPermission.handle(
            line: #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"approve","arguments":{"tool_name":"Edit","input":{"file_path":"/a"}}}}"#,
            managedID: "m7", nowMs: 42,
            decide: { seen = $0; return .init(id: $0.id, allow: false, message: "") }
        )
        XCTAssertEqual(seen?.toolName, "Edit")
        XCTAssertEqual(seen?.managedID, "m7")
        XCTAssertEqual(seen?.inputJSON, #"{"file_path":"\/a"}"#)
        XCTAssertEqual(seen?.truncated, false)
    }

    func testAnOversizeInputIsTruncatedAndLosesAllow() {
        let big = String(repeating: "x", count: ManagedPermission.maxInputBytes + 100)
        var seen: ManagedPermission.Request?
        _ = ManagedPermission.handle(
            line: #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"approve","arguments":{"tool_name":"Write","input":{"content":"\#(big)"}}}}"#,
            managedID: "m1", nowMs: 1,
            decide: { seen = $0; return .init(id: $0.id, allow: false, message: "") }
        )
        XCTAssertEqual(seen?.truncated, true)
        XCTAssertEqual(seen?.canOfferAllow, false)
    }

    func testANotificationGetsNoResponseAndAnUnknownMethodGetsAnError() throws {
        XCTAssertNil(ManagedPermission.handle(
            line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            managedID: "m1", nowMs: 1, decide: instantAllow
        ))
        let reply = try json(ManagedPermission.handle(
            line: #"{"jsonrpc":"2.0","id":9,"method":"resources/list"}"#,
            managedID: "m1", nowMs: 1, decide: instantAllow
        ))
        XCTAssertNotNil(reply["error"])
    }

    // MARK: - The spool

    func testTheSpoolRoundTripsAndFilenameDecidesIdentity() throws {
        let request = ManagedPermission.Request(
            id: "r1", managedID: "m1", toolName: "Bash",
            inputJSON: "{}", truncated: false, createdMs: 1
        )
        XCTAssertTrue(ManagedPermission.writeRequest(request))
        XCTAssertEqual(ManagedPermission.readRequests(), [request])
        try FileManager.default.moveItem(
            at: ManagedPermission.requestsDirectory().appendingPathComponent("r1.json"),
            to: ManagedPermission.requestsDirectory().appendingPathComponent("r2.json")
        )
        XCTAssertTrue(ManagedPermission.readRequests().isEmpty)
    }

    func testAVerdictIsSingleUse() {
        ManagedPermission.writeVerdict(.init(id: "v1", allow: true, message: ""))
        XCTAssertEqual(ManagedPermission.takeVerdict(id: "v1")?.allow, true)
        XCTAssertNil(ManagedPermission.takeVerdict(id: "v1"), "taken means gone")
    }

    func testBlockingDecideReturnsTheVerdictAndCleansItsRequest() {
        let request = ManagedPermission.Request(
            id: "r1", managedID: "m1", toolName: "Bash",
            inputJSON: "{}", truncated: false, createdMs: 1
        )
        ManagedPermission.writeVerdict(.init(id: "r1", allow: true, message: ""))
        let verdict = ManagedPermission.blockingDecide(request, pollMs: 10, timeoutMs: 2_000)
        XCTAssertTrue(verdict.allow)
        XCTAssertTrue(ManagedPermission.readRequests().isEmpty,
                      "the ask never outlives its answer")
    }

    func testSilenceDeniesAtTheDeadline() {
        let request = ManagedPermission.Request(
            id: "r1", managedID: "m1", toolName: "Bash",
            inputJSON: "{}", truncated: false, createdMs: 1
        )
        let verdict = ManagedPermission.blockingDecide(request, pollMs: 10, timeoutMs: 100)
        XCTAssertFalse(verdict.allow)
        XCTAssertEqual(verdict.message, "timeout")
        XCTAssertTrue(ManagedPermission.readRequests().isEmpty)
    }

    // MARK: - The fleet holds the Respond gate

    @MainActor
    func testTheFleetRefusesToAllowATruncatedRequest() {
        ManagedPermission.writeRequest(.init(
            id: "r1", managedID: "m1", toolName: "Write",
            inputJSON: "cut…", truncated: true, createdMs: 1
        ))
        let fleet = ManagedFleet()
        fleet.refreshPermissions()
        XCTAssertEqual(fleet.pendingPermissions.count, 1)
        fleet.decidePermission(id: "r1", allow: true)
        XCTAssertEqual(ManagedPermission.takeVerdict(id: "r1")?.allow, false,
                       "allow beside a truncated request is the blind approve")
    }

    func testTheConfigNamesOurOwnBinaryAndTheServerFlag() throws {
        ManagedSession.stateDirectoryOverride = spool
        defer { ManagedSession.stateDirectoryOverride = nil }
        let path = try XCTUnwrap(ManagedPermission.ensureConfig(managedID: "m1"))
        let config = try json(String(data: Data(contentsOf: URL(fileURLWithPath: path)), encoding: .utf8))
        let server = try XCTUnwrap(
            ((config["mcpServers"] as? [String: Any])?["pulse"] as? [String: Any])
        )
        XCTAssertEqual(server["args"] as? [String], ["--permission-server"])
        let env = try XCTUnwrap(server["env"] as? [String: String])
        XCTAssertEqual(env["PULSE_MANAGED_ID"], "m1")
        XCTAssertFalse((server["command"] as? String ?? "").isEmpty)
    }
}
