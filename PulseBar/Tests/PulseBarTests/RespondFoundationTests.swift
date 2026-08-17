import XCTest
@testable import PulseBar

/// 1.1 Respond — the parts that do not depend on an unverified vendor contract.
///
/// Nothing here makes Pulse able to answer an agent; that waits on plan-1.1
/// P0-0. What it pins down is the shape of a decision, because this is the
/// first version where being wrong means an agent *does* something rather than
/// a row *says* something.
final class RespondFoundationTests: XCTestCase {

    private let now: Int64 = 1_800_000_000_000

    private func request(
        id: String = "req-1",
        agent: AgentID = .claude,
        full: String = "Bash: ls -la /Users/me/code",
        truncated: Bool = false,
        host: String = ""
    ) -> PermissionRequest {
        PermissionRequest(
            id: id, agent: agent, host: host, session: "s1",
            fullRequest: full, truncated: truncated, receivedAtMs: now
        )
    }

    // MARK: - Reach is about the hook, not about capability

    /// `HooksInstaller` puts Pulse on Claude's `PermissionRequest` event, so
    /// Pulse's code runs at the decision point. That is all this says.
    func testOnlyClaudeCurrentlyRunsAtTheDecisionPoint() {
        XCTAssertEqual(AgentID.claude.respondReach, .hookSite)
        for agent in AgentID.allCases where agent != .claude {
            XCTAssertEqual(
                agent.respondReach, .none,
                "\(agent.rawValue) must not advertise reach it does not have"
            )
        }
    }

    // MARK: - Allow requires having seen the whole thing

    func testAllowIsOfferedOnlyWhenTheWholeRequestIsPresent() {
        XCTAssertTrue(request().canOfferAllow)
        XCTAssertFalse(request(truncated: true).canOfferAllow, "an abbreviation must not be approved")
        XCTAssertFalse(request(full: "").canOfferAllow)
        XCTAssertFalse(request(full: "   \n ").canOfferAllow)
    }

    func testATruncatedRequestCannotProduceAnAllowVerdictEvenIfAsked() {
        var store = RespondDecisionStore()
        XCTAssertNil(
            store.decide(request(truncated: true), allow: true, nowMs: now),
            "the refusal has to live in the model, not only in the button"
        )
        XCTAssertTrue(store.pending.isEmpty)
    }

    /// Refusing something you have not fully read is safe, and is the whole
    /// point of being able to answer at all when the text did not survive.
    func testDenyIsAlwaysAvailable() throws {
        var store = RespondDecisionStore()
        let verdict = try XCTUnwrap(store.decide(request(truncated: true), allow: false, nowMs: now))
        XCTAssertFalse(verdict.allow)
    }

    // MARK: - A verdict answers one request, once

    func testAVerdictIsConsumedByTheRequestItAnswers() throws {
        var store = RespondDecisionStore()
        let req = request()
        _ = store.decide(req, allow: true, nowMs: now)
        let taken = try XCTUnwrap(store.take(for: req, nowMs: now))
        XCTAssertTrue(taken.allow)
        XCTAssertNil(store.take(for: req, nowMs: now), "single use — a decision is not a standing rule")
    }

    /// Same id, different content: the request changed under the verdict.
    func testAVerdictDoesNotCarryOverToDifferentContentWithTheSameId() {
        var store = RespondDecisionStore()
        _ = store.decide(request(full: "Bash: ls -la"), allow: true, nowMs: now)
        XCTAssertNil(
            store.take(for: request(full: "Bash: rm -rf /"), nowMs: now),
            "an approval is bound to what it approved"
        )
    }

    /// Same content, different request: an identical ask tomorrow is a new ask.
    func testAVerdictDoesNotCarryOverToAnotherRequestWithTheSameContent() {
        var store = RespondDecisionStore()
        _ = store.decide(request(id: "req-1"), allow: true, nowMs: now)
        XCTAssertNil(store.take(for: request(id: "req-2"), nowMs: now))
    }

    /// Same id, same content, different machine: a verdict decided for devbox
    /// must never be replayable onto another host that happened to raise a
    /// request with the same vendor id. Id uniqueness across machines is a
    /// vendor accident, not a guarantee Pulse may lean on.
    func testAVerdictDoesNotCarryOverToTheSameRequestOnAnotherHost() throws {
        var store = RespondDecisionStore()
        let verdict = try XCTUnwrap(
            store.decide(request(host: "devbox"), allow: true, nowMs: now)
        )
        XCTAssertEqual(verdict.host, "devbox")
        XCTAssertNil(
            store.take(for: request(host: "buildbox"), nowMs: now),
            "a verdict is bound to the machine it was decided for"
        )
    }

    /// Same id, same content, different agent: the verdict names who it
    /// answers, and a different agent presenting the same id is a new ask.
    func testAVerdictDoesNotCarryOverToAnotherAgentWithTheSameId() throws {
        var store = RespondDecisionStore()
        let verdict = try XCTUnwrap(
            store.decide(request(agent: .claude), allow: true, nowMs: now)
        )
        XCTAssertEqual(verdict.agent, AgentID.claude.rawValue)
        XCTAssertNil(
            store.take(for: request(agent: .codex), nowMs: now),
            "a verdict is bound to the agent it was decided for"
        )
    }

    func testAnUncollectedVerdictExpires() {
        var store = RespondDecisionStore()
        let req = request()
        _ = store.decide(req, allow: true, nowMs: now)
        let later = now + RespondDecisionStore.defaultTtlMs + 1
        XCTAssertNil(
            store.take(for: req, nowMs: later),
            "someone who walked away must not find their approval still armed"
        )
        XCTAssertTrue(store.pending.isEmpty)
    }

    func testChangingYourMindReplacesTheEarlierAnswer() throws {
        var store = RespondDecisionStore()
        let req = request()
        _ = store.decide(req, allow: true, nowMs: now)
        _ = store.decide(req, allow: false, nowMs: now + 10)
        XCTAssertEqual(store.pending.count, 1)
        let taken = try XCTUnwrap(store.take(for: req, nowMs: now + 20))
        XCTAssertFalse(taken.allow, "the newest answer is the user's actual intent")
    }

    func testPendingVerdictsAreBounded() {
        var store = RespondDecisionStore()
        for index in 0..<(RespondDecisionStore.maxPending + 20) {
            _ = store.decide(request(id: "req-\(index)"), allow: false, nowMs: now)
        }
        XCTAssertLessThanOrEqual(store.pending.count, RespondDecisionStore.maxPending)
    }

    // MARK: - Who is actually waiting

    /// The case 1.0 created: a request from another machine, and someone
    /// sitting at this one who can answer it.
    func testARemoteRequestIsHeldWhileTheUserIsHere() {
        XCTAssertTrue(RespondHold.shouldHold(isRemote: true, idleSeconds: 3))
    }

    /// The regression this rule exists to prevent: freezing an agent in front
    /// of the person whose own prompt was about to appear anyway.
    func testALocalRequestIsNeverHeldWhileTheUserIsAtTheKeyboard() {
        XCTAssertFalse(RespondHold.shouldHold(isRemote: false, idleSeconds: 1))
    }

    func testNothingIsHeldWhenNobodyIsThereToAnswer() {
        XCTAssertFalse(
            RespondHold.shouldHold(isRemote: true, idleSeconds: 10 * 60),
            "holding for an absent user is a freeze with no audience"
        )
        XCTAssertFalse(RespondHold.shouldHold(isRemote: false, idleSeconds: 10 * 60))
    }

    func testTheAwayThresholdIsTheBoundary() {
        let threshold = RespondHold.defaultAwayAfterSeconds
        XCTAssertTrue(RespondHold.shouldHold(isRemote: true, idleSeconds: threshold - 0.1))
        XCTAssertFalse(RespondHold.shouldHold(isRemote: true, idleSeconds: threshold))
    }

    // MARK: - Digest

    func testTheDigestIsStableAndContentBound() {
        XCTAssertEqual(RespondDigest.of("Bash: ls"), RespondDigest.of("Bash: ls"))
        XCTAssertNotEqual(RespondDigest.of("Bash: ls"), RespondDigest.of("Bash: ls "))
        XCTAssertEqual(RespondDigest.of("x").count, 64)
    }
}
