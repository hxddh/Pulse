import CryptoKit
import XCTest
@testable import PulseBar

/// 2.4 Answer Here — the one verb change this product has shipped, made
/// reachable by someone with a single Mac.
///
/// Two things had to change. The gate stopped asking "is anyone touching this
/// Mac" (which is true in a meeting, while six terminals sit behind a
/// full-screen app) and started asking whether the prompt is actually in
/// front of the user. And the spool, which read only what a partner Mac's
/// sync tool delivered, now also reads what an agent on this Mac raised and
/// is still holding for.
final class AnswerHereTests: XCTestCase {

    private let now: Int64 = 1_800_000_000_000
    private var base: URL!
    private var root: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-answer-here-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("respond.d", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        RespondSpool.rootOverride = root
    }

    override func tearDownWithError() throws {
        RespondSpool.rootOverride = nil
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - Is the prompt in front of the user?

    /// app 4321 → shell 900 → agent 500 → this hook 100.
    private let chain: [Int32: Int32] = [100: 500, 500: 900, 900: 4321, 4321: 1]

    func testTheFrontmostTerminalIsRecognisedThroughTheWholeChain() {
        XCTAssertEqual(
            PromptVisibility.isAncestor(4321, of: 100, parentOf: { self.chain[$0] }),
            true
        )
    }

    func testAnUnrelatedFrontmostAppIsNotAnAncestor() {
        // Zoom is in front; the agent's terminal is somewhere behind it.
        XCTAssertEqual(
            PromptVisibility.isAncestor(7777, of: 100, parentOf: { self.chain[$0] }),
            false,
            "the walk reached launchd without meeting it"
        )
    }

    func testAProcessIsItsOwnAncestor() {
        XCTAssertEqual(
            PromptVisibility.isAncestor(100, of: 100, parentOf: { self.chain[$0] }),
            true
        )
    }

    func testAnUnreadableLinkIsUnknownNotFalse() {
        // "Could not tell" must never be spent as proof the user is looking
        // elsewhere — that would freeze an agent in front of a present user.
        XCTAssertNil(PromptVisibility.isAncestor(4321, of: 100, parentOf: { _ in nil }))
    }

    func testACycleTerminatesAsUnknown() {
        let loop: [Int32: Int32] = [100: 200, 200: 300, 300: 100]
        XCTAssertNil(PromptVisibility.isAncestor(4321, of: 100, parentOf: { loop[$0] }))
    }

    func testAChainTooLongToBeRealIsUnknown() {
        // Every parent is one lower, so the walk never reaches 1 and never
        // repeats: only the depth bound can stop it.
        XCTAssertNil(
            PromptVisibility.isAncestor(4321, of: 5000, parentOf: { $0 - 1 })
        )
    }

    func testNoFrontmostAppMeansUnknown() {
        XCTAssertNil(
            PromptVisibility.promptIsFrontmost(
                selfPID: 100, frontmost: nil, parentOf: { self.chain[$0] }
            )
        )
        XCTAssertNil(
            PromptVisibility.promptIsFrontmost(
                selfPID: 100, frontmost: 0, parentOf: { self.chain[$0] }
            )
        )
    }

    func testPromptVisibilityUsesTheChain() {
        XCTAssertEqual(
            PromptVisibility.promptIsFrontmost(
                selfPID: 100, frontmost: 4321, parentOf: { self.chain[$0] }
            ),
            true
        )
        XCTAssertEqual(
            PromptVisibility.promptIsFrontmost(
                selfPID: 100, frontmost: 7777, parentOf: { self.chain[$0] }
            ),
            false
        )
    }

    /// The real reader, against this very process. It must not crash, must not
    /// hang, and must agree with `getppid()`.
    func testTheRealParentLookupAgreesWithTheKernel() throws {
        let parent = try XCTUnwrap(PromptVisibility.parentPID(of: getpid()))
        XCTAssertEqual(parent, getppid())
    }

    // MARK: - The local opt-in

    func testTheSwitchIsTheKeyFile() throws {
        XCTAssertFalse(RespondSpool.localHasSecret(), "off until asked for")
        XCTAssertTrue(RespondSpool.setLocalAnsweringEnabled(true))
        XCTAssertTrue(RespondSpool.localHasSecret())
        let attrs = try FileManager.default.attributesOfItem(
            atPath: RespondSpool.localSecretURL.path
        )
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        RespondSpool.setLocalAnsweringEnabled(false)
        XCTAssertFalse(RespondSpool.localHasSecret(), "turning it off stops every hold")
    }

    func testEnablingTwiceKeepsTheSameKey() throws {
        XCTAssertTrue(RespondSpool.setLocalAnsweringEnabled(true))
        let first = try Data(contentsOf: RespondSpool.localSecretURL)
        XCTAssertTrue(RespondSpool.setLocalAnsweringEnabled(true))
        let second = try Data(contentsOf: RespondSpool.localSecretURL)
        XCTAssertEqual(first, second, "a rotated key would orphan a verdict already in flight")
    }

    func testTheGeneratedKeySurvivesTheNewlineTrim() throws {
        // `keyBytes` trims trailing newline bytes so a hand-made key matches
        // its copy on the other Mac. Raw random bytes ending in 0x0A would be
        // silently trimmed into a different key than the one written, so the
        // generated key is hex text.
        XCTAssertTrue(RespondSpool.setLocalAnsweringEnabled(true))
        let raw = try Data(contentsOf: RespondSpool.localSecretURL)
        XCTAssertEqual(raw.count, 64)
        XCTAssertTrue(
            raw.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) },
            "hex only, so no trailing byte can ever be trimmed"
        )
    }

    func testEitherKeyIsAnOptIn() throws {
        XCTAssertFalse(RespondSpool.hasAnyKey())
        RespondSpool.setLocalAnsweringEnabled(true)
        XCTAssertTrue(RespondSpool.hasAnyKey(), "a single-Mac install opted in with no partner")
    }

    // MARK: - This Mac's own requests, read back

    @discardableResult
    private func writeLocalRequestFile(
        id: String = "toolu_local",
        host: String = "thismac",
        agent: String = "claude",
        payload: String = #"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#,
        expiresAtMs: Int64? = nil
    ) throws -> URL {
        let directory = root.appendingPathComponent("requests", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = Data(payload.utf8)
        let object: [String: Any] = [
            "v": 1,
            "request_id": id,
            "agent": agent,
            "host": host,
            "session": "s1",
            "cwd": "/work/project",
            "tool_name": "Bash",
            "raised_at_ms": now,
            "expires_at_ms": expiresAtMs ?? (now + 60_000),
            "payload_b64": bytes.base64EncodedString(),
            "digest": RespondDigest.of(bytes),
            "truncated": false,
        ]
        let url = directory.appendingPathComponent("\(id).json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }

    func testTheFlatTreeIsReadAndMarkedLocal() throws {
        try writeLocalRequestFile()
        let found = RespondSpool.readLocalRequests(nowMs: now, host: "thismac")
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].isLocal)
        XCTAssertEqual(found[0].request.id, "toolu_local")
        XCTAssertTrue(found[0].request.canOfferAllow, "the whole request is here")
    }

    func testAFileClaimingAnotherHostIsNotAdopted() throws {
        try writeLocalRequestFile(host: "someoneelse")
        XCTAssertTrue(
            RespondSpool.readLocalRequests(nowMs: now, host: "thismac").isEmpty,
            "guessing who is asking is how a verdict answers the wrong thing"
        )
    }

    func testAnExpiredLocalRequestIsSkipped() throws {
        try writeLocalRequestFile(expiresAtMs: now - 1)
        XCTAssertTrue(RespondSpool.readLocalRequests(nowMs: now, host: "thismac").isEmpty)
    }

    func testWithoutAHostNothingIsRead() throws {
        try writeLocalRequestFile()
        XCTAssertTrue(RespondSpool.readLocalRequests(nowMs: now, host: "").isEmpty)
    }

    // MARK: - The local verdict round trip

    private func localRequest(id: String = "toolu_local") throws -> PermissionRequest {
        try writeLocalRequestFile(id: id)
        let found = RespondSpool.readLocalRequests(nowMs: now, host: "thismac")
        return try XCTUnwrap(found.first).request
    }

    func testALocalVerdictIsClaimedByTheWaitingHook() throws {
        RespondSpool.setLocalAnsweringEnabled(true)
        let request = try localRequest()
        var store = RespondDecisionStore()
        let verdict = try XCTUnwrap(store.decide(request, allow: false, nowMs: now))
        XCTAssertTrue(RespondSpool.writeVerdict(verdict, local: true))

        let allow = RespondSpool.claimVerdict(
            requestID: request.id, digest: request.digest,
            agent: request.agent.rawValue, host: request.host, nowMs: now
        )
        XCTAssertEqual(allow, false, "the hook collected the user's own refusal")
    }

    func testALocalVerdictIsSingleUse() throws {
        RespondSpool.setLocalAnsweringEnabled(true)
        let request = try localRequest()
        var store = RespondDecisionStore()
        let verdict = try XCTUnwrap(store.decide(request, allow: false, nowMs: now))
        RespondSpool.writeVerdict(verdict, local: true)
        _ = RespondSpool.claimVerdict(
            requestID: request.id, digest: request.digest,
            agent: request.agent.rawValue, host: request.host, nowMs: now
        )
        XCTAssertNil(
            RespondSpool.claimVerdict(
                requestID: request.id, digest: request.digest,
                agent: request.agent.rawValue, host: request.host, nowMs: now
            ),
            "the rename IS the claim"
        )
    }

    func testWithoutTheLocalKeyNoLocalVerdictIsWritten() throws {
        let request = try localRequest()
        var store = RespondDecisionStore()
        let verdict = try XCTUnwrap(store.decide(request, allow: false, nowMs: now))
        XCTAssertFalse(
            RespondSpool.writeVerdict(verdict, local: true),
            "no key, no verdict on disk — fail closed"
        )
    }

    /// The property the local key exists to preserve: `verdicts/` is exactly
    /// the directory a partner Mac's answers sync *into*, so a file arriving
    /// over a compromised share must still be unusable.
    func testAVerdictSignedWithNeitherHeldKeyIsRefused() throws {
        RespondSpool.setLocalAnsweringEnabled(true)
        let request = try localRequest()
        let directory = root.appendingPathComponent("verdicts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let message = "v1\n\(request.id)\n\(request.digest)\n\(request.agent.rawValue)"
            + "\n\(request.host)\nallow\n\(now)\n\(now + 90_000)"
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: Data("a-key-this-mac-does-not-hold".utf8))
        )
        let object: [String: Any] = [
            "v": 1,
            "request_id": request.id,
            "digest": request.digest,
            "agent": request.agent.rawValue,
            "host": request.host,
            "allow": true,
            "decided_at_ms": now,
            "expires_at_ms": now + 90_000,
            "hmac": mac.map { String(format: "%02x", $0) }.joined(),
        ]
        try JSONSerialization.data(withJSONObject: object)
            .write(to: directory.appendingPathComponent("\(request.id).json"))

        XCTAssertNil(
            RespondSpool.claimVerdict(
                requestID: request.id, digest: request.digest,
                agent: request.agent.rawValue, host: request.host, nowMs: now
            ),
            "adding the local path must not weaken the remote one"
        )
    }

    func testALocalAllowStillNeedsTheWholeRequest() throws {
        RespondSpool.setLocalAnsweringEnabled(true)
        var request = try localRequest()
        request.truncated = true
        var store = RespondDecisionStore()
        XCTAssertNil(
            store.decide(request, allow: true, nowMs: now),
            "canOfferAllow is not relaxed for being on the same machine"
        )
        XCTAssertNotNil(
            store.decide(request, allow: false, nowMs: now),
            "refusing what you could not read stays available"
        )
    }
}
