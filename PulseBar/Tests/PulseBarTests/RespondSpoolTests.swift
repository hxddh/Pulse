import CryptoKit
import XCTest
@testable import PulseBar

/// The respond spool is the first file surface whose contents can make an
/// agent *act*, so these tests are less about parsing and more about the
/// refusals: mismatched digests, missing keys, hostile ids, expired files.
final class RespondSpoolTests: XCTestCase {

    private let now: Int64 = 1_800_000_000_000
    /// Stand-in for the Pulse support directory — the outbound secret lives
    /// here, *beside* the spool root, exactly like production.
    private var base: URL!
    private var root: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-respond-spool-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("respond.d", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        RespondSpool.rootOverride = root
    }

    override func tearDownWithError() throws {
        RespondSpool.rootOverride = nil
        try? FileManager.default.removeItem(at: base)
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

    // MARK: - Answered end (this machine runs the agent)

    private func writeOutboundSecret(_ key: String = "sekrit\n") throws {
        try Data(key.utf8).write(to: base.appendingPathComponent("respond-secret.key"))
    }

    private func canonical(
        id: String, digest: String, agent: String = "claude", host: String = "devbox",
        allow: Bool, decided: Int64, expires: Int64
    ) -> String {
        "v1\n\(id)\n\(digest)\n\(agent)\n\(host)\n\(allow ? "allow" : "deny")\n\(decided)\n\(expires)"
    }

    private func hmacHex(message: String, key: String = "sekrit") -> String {
        HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8), using: SymmetricKey(data: Data(key.utf8))
        ).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private func writeInboundVerdictFile(
        id: String = "toolu_x",
        digest: String,
        allow: Bool = true,
        decidedAtMs: Int64? = nil,
        expiresAtMs: Int64? = nil,
        hmacOverride: String? = nil
    ) throws -> URL {
        let directory = root.appendingPathComponent("verdicts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let decided = decidedAtMs ?? now
        let expires = expiresAtMs ?? (now + 90_000)
        let object: [String: Any] = [
            "v": 1,
            "request_id": id,
            "digest": digest,
            "agent": "claude",
            "host": "devbox",
            "allow": allow,
            "decided_at_ms": NSNumber(value: decided),
            "expires_at_ms": NSNumber(value: expires),
            "hmac": hmacOverride ?? hmacHex(
                message: canonical(id: id, digest: digest, allow: allow, decided: decided, expires: expires)
            ),
        ]
        let url = directory.appendingPathComponent("\(id).json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }

    private func claim(
        _ id: String, digest: String, truncated: Bool = false, nowMs: Int64? = nil
    ) -> Bool? {
        RespondSpool.claimVerdict(
            requestID: id, digest: digest, agent: "claude", host: "devbox",
            truncated: truncated, nowMs: nowMs ?? now
        )
    }

    func testWriteOutboundRequestWritesTheSchemaVerbatimAt0600() throws {
        let payload = Data("{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf x\"}}".utf8)
        XCTAssertTrue(RespondSpool.writeOutboundRequest(
            requestID: "toolu_x", agent: "claude", host: "devbox", session: "s1",
            cwd: "/w", toolName: "Bash", payload: payload,
            nowMs: now, expiresAtMs: now + 60_000
        ))
        let url = root.appendingPathComponent("requests/toolu_x.json")
        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["request_id"] as? String, "toolu_x")
        XCTAssertEqual(object["agent"] as? String, "claude")
        XCTAssertEqual(object["host"] as? String, "devbox")
        XCTAssertEqual(object["session"] as? String, "s1")
        XCTAssertEqual(object["cwd"] as? String, "/w")
        XCTAssertEqual(object["tool_name"] as? String, "Bash")
        XCTAssertEqual((object["raised_at_ms"] as? NSNumber)?.int64Value, now)
        XCTAssertEqual((object["expires_at_ms"] as? NSNumber)?.int64Value, now + 60_000)
        XCTAssertEqual(object["truncated"] as? Bool, false)
        let b64 = try XCTUnwrap(object["payload_b64"] as? String)
        XCTAssertEqual(Data(base64Encoded: b64), payload, "verbatim bytes must round-trip")
        XCTAssertEqual(object["digest"] as? String, RespondDigest.of(payload))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
    }

    func testClaimVerdictAcceptsAValidVerdictExactlyOnce() throws {
        try writeOutboundSecret()
        let digest = RespondDigest.of(Data("payload".utf8))
        try writeInboundVerdictFile(digest: digest, allow: true)
        XCTAssertEqual(claim("toolu_x", digest: digest), true)
        let directory = root.appendingPathComponent("verdicts")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("toolu_x.json").path),
            "the rename is the claim"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("toolu_x.json.used").path)
        )
        XCTAssertNil(claim("toolu_x", digest: digest), "exactly once — no second answer from one file")
    }

    func testClaimVerdictRejectsATamperedHmacAndKeepsItConsumed() throws {
        try writeOutboundSecret()
        let digest = RespondDigest.of(Data("payload".utf8))
        try writeInboundVerdictFile(digest: digest, hmacOverride: String(repeating: "0", count: 64))
        XCTAssertNil(claim("toolu_x", digest: digest))
        let directory = root.appendingPathComponent("verdicts")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("toolu_x.json.used").path),
            "a bad verdict stays consumed — never re-read on the next poll"
        )
        // A fresh, valid verdict can still land and be claimed: the rename
        // replaces the .used remnant.
        try writeInboundVerdictFile(digest: digest, allow: false)
        XCTAssertEqual(claim("toolu_x", digest: digest), false)
    }

    func testClaimVerdictRejectsExpiredAndNotYetPlausibleTimestamps() throws {
        try writeOutboundSecret()
        let digest = RespondDigest.of(Data("payload".utf8))
        // Expired past the 5-minute tolerance (boundary: now == expires + skew).
        try writeInboundVerdictFile(id: "toolu_old", digest: digest, expiresAtMs: now - 300_000)
        XCTAssertNil(claim("toolu_old", digest: digest))
        // Decided too far in the future for any plausible clock.
        try writeInboundVerdictFile(id: "toolu_future", digest: digest, decidedAtMs: now + 300_001)
        XCTAssertNil(claim("toolu_future", digest: digest))
        // Inside the tolerance both ways: accepted — skew must not make a
        // slightly-off clock reject every genuine verdict.
        try writeInboundVerdictFile(
            id: "toolu_skew", digest: digest,
            decidedAtMs: now + 299_999, expiresAtMs: now - 299_999
        )
        XCTAssertEqual(claim("toolu_skew", digest: digest), true)
    }

    func testClaimVerdictNeverReturnsAllowForATruncatedRequest() throws {
        try writeOutboundSecret()
        let digest = RespondDigest.of(Data("payload".utf8))
        try writeInboundVerdictFile(id: "toolu_a", digest: digest, allow: true)
        XCTAssertNil(
            claim("toolu_a", digest: digest, truncated: true),
            "an allow must never answer a request whose full content was not captured"
        )
        try writeInboundVerdictFile(id: "toolu_d", digest: digest, allow: false)
        XCTAssertEqual(
            claim("toolu_d", digest: digest, truncated: true), false,
            "deny stays available — refusing the unverified is the safe direction"
        )
    }

    func testWriteOutboundRequestCleansUpStaleSpoolFiles() throws {
        let fm = FileManager.default
        let requests = root.appendingPathComponent("requests", isDirectory: true)
        let verdicts = root.appendingPathComponent("verdicts", isDirectory: true)
        try fm.createDirectory(at: requests, withIntermediateDirectories: true)
        try fm.createDirectory(at: verdicts, withIntermediateDirectories: true)
        let hour: Int64 = 3_600_000
        let stale = requests.appendingPathComponent("stale.json")
        try JSONSerialization.data(
            withJSONObject: ["expires_at_ms": NSNumber(value: now - 2 * hour)]
        ).write(to: stale)
        let used = verdicts.appendingPathComponent("old.json.used")
        try Data("{}".utf8).write(to: used)
        try fm.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: Double(now - 2 * hour) / 1000)],
            ofItemAtPath: used.path
        )
        XCTAssertTrue(RespondSpool.writeOutboundRequest(
            requestID: "toolu_new", agent: "claude", host: "devbox", session: "",
            cwd: "", toolName: "Bash", payload: Data("x".utf8),
            nowMs: now, expiresAtMs: now + 60_000
        ))
        XCTAssertFalse(fm.fileExists(atPath: stale.path), "a request an hour past its expiry is gone")
        XCTAssertFalse(fm.fileExists(atPath: used.path), "an hour-old .used remnant is gone")
        XCTAssertTrue(fm.fileExists(atPath: requests.appendingPathComponent("toolu_new.json").path))
    }
}
