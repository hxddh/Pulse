import CryptoKit
import XCTest
@testable import PulseBar

/// The respond spool is the first file surface whose contents can make an
/// agent *act*, so these tests are less about parsing and more about the
/// refusals: mismatched digests, missing keys, hostile ids, expired files.
final class RespondSpoolTests: XCTestCase {

    private let now: Int64 = 1_800_000_000_000
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-respond-spool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        RespondSpool.rootOverride = root
    }

    override func tearDownWithError() throws {
        RespondSpool.rootOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    @discardableResult
    private func writeRequestFile(
        host: String = "devbox",
        id: String = "toolu_x",
        agent: String = "claude",
        payload: String = "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls -la\"}}",
        digest: String? = nil,
        expiresAtMs: Int64? = nil
    ) throws -> URL {
        let directory = root.appendingPathComponent("requests.d/\(host)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let object: [String: Any] = [
            "v": 1,
            "request_id": id,
            "agent": agent,
            "host": host,
            "session": "s1",
            "cwd": "/w",
            "tool_name": "Bash",
            "raised_at_ms": NSNumber(value: now - 1_000),
            "expires_at_ms": NSNumber(value: expiresAtMs ?? (now + 60_000)),
            "payload_b64": Data(payload.utf8).base64EncodedString(),
            "digest": digest ?? RespondDigest.of(payload),
            "truncated": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let url = directory.appendingPathComponent("\(id).json")
        try data.write(to: url)
        return url
    }

    private func writeSecret(host: String = "devbox", key: String = "sekrit\n") throws {
        let directory = root.appendingPathComponent("secrets", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(key.utf8).write(to: directory.appendingPathComponent("\(host).key"))
    }

    private func verdict(
        id: String = "toolu_x",
        digest: String = RespondDigest.of("x"),
        host: String = "devbox",
        allow: Bool = true,
        expiresAtMs: Int64? = nil
    ) -> RespondVerdict {
        RespondVerdict(
            requestID: id,
            digest: digest,
            agent: AgentID.claude.rawValue,
            host: host,
            allow: allow,
            decidedAtMs: now,
            expiresAtMs: expiresAtMs ?? (now + 90_000)
        )
    }

    // MARK: - Reading requests

    func testARequestFileBecomesAFullPermissionRequest() throws {
        let payload = "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls -la\"}}"
        try writeRequestFile(payload: payload)
        let inbound = RespondSpool.readInboundRequests(nowMs: now)
        XCTAssertEqual(inbound.count, 1)
        let first = try XCTUnwrap(inbound.first)
        XCTAssertEqual(first.request.id, "toolu_x")
        XCTAssertEqual(first.request.agent, .claude)
        XCTAssertEqual(first.request.host, "devbox")
        XCTAssertEqual(first.request.session, "s1")
        XCTAssertEqual(first.request.fullRequest, payload, "the payload must survive byte for byte")
        XCTAssertFalse(first.request.truncated)
        XCTAssertGreaterThan(first.request.receivedAtMs, 0, "receivedAtMs is the local landing time")
        XCTAssertTrue(first.request.canOfferAllow, "a verified full request may offer Allow")
        XCTAssertEqual(first.toolName, "Bash")
        XCTAssertEqual(first.expiresAtMs, now + 60_000)
    }

    /// A payload whose digest does not match is an abbreviation of unknown
    /// shape — deniable, never approvable.
    func testADigestMismatchMarksTruncatedAndBlocksAllow() throws {
        try writeRequestFile(digest: RespondDigest.of("something else entirely"))
        let inbound = RespondSpool.readInboundRequests(nowMs: now)
        let first = try XCTUnwrap(inbound.first)
        XCTAssertTrue(first.request.truncated)
        XCTAssertFalse(first.request.canOfferAllow)
        var store = RespondDecisionStore()
        XCTAssertNil(
            store.decide(first.request, allow: true, nowMs: now),
            "a request that failed its digest check must never produce an Allow"
        )
        XCTAssertNotNil(
            store.decide(first.request, allow: false, nowMs: now),
            "deny stays available — refusing the unverified is safe"
        )
    }

    func testAnExpiredRequestIsNotReturned() throws {
        try writeRequestFile(id: "toolu_dead", expiresAtMs: now - 1)
        try writeRequestFile(id: "toolu_live", expiresAtMs: now + 60_000)
        let inbound = RespondSpool.readInboundRequests(nowMs: now)
        XCTAssertEqual(inbound.map { $0.request.id }, ["toolu_live"])
    }

    /// An agent string Pulse does not know is skipped, not guessed: a verdict
    /// must name who it answers, and a guess could name the wrong one.
    func testAnUnknownAgentStringIsSkippedNotGuessed() throws {
        try writeRequestFile(id: "toolu_alien", agent: "martian")
        XCTAssertTrue(RespondSpool.readInboundRequests(nowMs: now).isEmpty)
    }

    // MARK: - Writing verdicts

    func testWriteVerdictWithoutASecretFailsClosed() {
        XCTAssertFalse(
            RespondSpool.writeVerdict(verdict()),
            "no key means no opt-in; the verdict must never reach disk"
        )
        XCTAssertFalse(RespondSpool.hostHasSecret("devbox"))
        let verdictsDir = root.appendingPathComponent("verdicts.d/devbox")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: verdictsDir.path)) ?? []
        XCTAssertTrue(names.isEmpty)
    }

    func testAnEmptyKeyFileIsNotAnOptIn() throws {
        try writeSecret(key: "\n")
        XCTAssertFalse(RespondSpool.hostHasSecret("devbox"))
        XCTAssertFalse(RespondSpool.writeVerdict(verdict()))
    }

    func testWriteVerdictWritesAllFieldsAndAVerifiableHmac() throws {
        try writeSecret(key: "sekrit\n")
        XCTAssertTrue(RespondSpool.hostHasSecret("devbox"))
        let subject = verdict(digest: RespondDigest.of("payload"), allow: true)
        XCTAssertTrue(RespondSpool.writeVerdict(subject))

        let url = root.appendingPathComponent("verdicts.d/devbox/toolu_x.json")
        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["request_id"] as? String, "toolu_x")
        XCTAssertEqual(object["digest"] as? String, subject.digest)
        XCTAssertEqual(object["agent"] as? String, "claude")
        XCTAssertEqual(object["host"] as? String, "devbox")
        XCTAssertEqual(object["allow"] as? Bool, true)
        XCTAssertEqual((object["decided_at_ms"] as? NSNumber)?.int64Value, subject.decidedAtMs)
        XCTAssertEqual((object["expires_at_ms"] as? NSNumber)?.int64Value, subject.expiresAtMs)

        // Recompute the MAC the way the remote consumer would: canonical
        // string, key with the trailing newline trimmed.
        let message = "v1\n" + subject.requestID + "\n" + subject.digest + "\n"
            + subject.agent + "\n" + subject.host + "\n"
            + (subject.allow ? "allow" : "deny") + "\n"
            + String(subject.decidedAtMs) + "\n" + String(subject.expiresAtMs)
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8), using: SymmetricKey(data: Data("sekrit".utf8))
        )
        let expected = mac.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(object["hmac"] as? String, expected)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
    }

    /// Verdicts go into `verdicts.d` only. `requests.d` syncs the other way,
    /// so anything written there would be pushed back out to remote machines.
    func testAVerdictIsNeverWrittenIntoRequestsDotD() throws {
        try writeSecret()
        XCTAssertTrue(RespondSpool.writeVerdict(verdict()))
        let requestsDir = root.appendingPathComponent("requests.d")
        var names: [String] = []
        if let walker = FileManager.default.enumerator(atPath: requestsDir.path) {
            while let entry = walker.nextObject() as? String { names.append(entry) }
        }
        XCTAssertTrue(names.isEmpty, "requests.d must stay inbound-only, got \(names)")
    }

    // MARK: - Cleanup

    func testCleanupRemovesExpiredFilesAndKeepsLiveOnes() throws {
        let hour: Int64 = 60 * 60 * 1000
        let deadRequest = try writeRequestFile(id: "toolu_dead", expiresAtMs: now - 2 * hour)
        let liveRequest = try writeRequestFile(id: "toolu_live", expiresAtMs: now + 60_000)
        try writeSecret()
        XCTAssertTrue(RespondSpool.writeVerdict(verdict(id: "verdict_dead", expiresAtMs: now - 2 * hour)))
        XCTAssertTrue(RespondSpool.writeVerdict(verdict(id: "verdict_live", expiresAtMs: now + 60_000)))

        RespondSpool.cleanup(nowMs: now)

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: deadRequest.path))
        XCTAssertTrue(fm.fileExists(atPath: liveRequest.path), "the grace window protects live files")
        let verdictsDir = root.appendingPathComponent("verdicts.d/devbox")
        XCTAssertFalse(fm.fileExists(atPath: verdictsDir.appendingPathComponent("verdict_dead.json").path))
        XCTAssertTrue(fm.fileExists(atPath: verdictsDir.appendingPathComponent("verdict_live.json").path))
    }

    /// Just-expired files survive: the grace hour exists so the sync tool can
    /// still carry the file's fate back before the evidence disappears.
    func testCleanupHonoursTheGraceWindow() throws {
        let inGrace = try writeRequestFile(id: "toolu_grace", expiresAtMs: now - 60_000)
        RespondSpool.cleanup(nowMs: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inGrace.path))
    }

    // MARK: - Hostile names

    /// A request id is remote-controlled text that becomes a local file name.
    func testAHostileRequestIdCannotEscapeTheSpool() throws {
        try writeSecret()
        XCTAssertTrue(RespondSpool.writeVerdict(verdict(id: "../../../escape")))
        let hostDir = root.appendingPathComponent("verdicts.d/devbox")
        let names = try FileManager.default.contentsOfDirectory(atPath: hostDir.path)
        XCTAssertEqual(names, [".._.._.._escape.json"], "every unsafe character becomes _")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.deletingLastPathComponent().appendingPathComponent("escape.json").path
            ),
            "nothing may land outside the spool"
        )
    }

    func testSanitizeNeverProducesATraversalComponent() {
        XCTAssertEqual(RespondSpool.sanitizeComponent(".."), "_")
        XCTAssertEqual(RespondSpool.sanitizeComponent("."), "_")
        XCTAssertEqual(RespondSpool.sanitizeComponent(""), "_")
        XCTAssertEqual(RespondSpool.sanitizeComponent("a/b\\c d"), "a_b_c_d")
        XCTAssertEqual(RespondSpool.sanitizeComponent("toolu_01AB.x-y"), "toolu_01AB.x-y")
        XCTAssertLessThanOrEqual(
            RespondSpool.sanitizeComponent(String(repeating: "x", count: 500)).count, 120
        )
    }
}
