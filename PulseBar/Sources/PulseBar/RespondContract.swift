import CoreGraphics
import CryptoKit
import Foundation

/// Where Pulse stands in an agent's permission decision.
///
/// `hookSite` means Pulse's code is executed at the moment the decision is
/// made — which `HooksInstaller` already arranges for Claude via the
/// `PermissionRequest` event. **Being executed there is not the same as being
/// able to answer.** Whether a reply can carry a verdict is a vendor contract
/// question, and it is deliberately unanswered until `qa_respond_contract.sh`
/// has been run on a real machine (plan-1.1 P0-0).
enum RespondReach: String, Equatable {
    /// Pulse never runs at this agent's decision point. Observation only.
    case none
    /// Pulse runs at the decision point. Whether its reply is honoured is
    /// unverified, so nothing may advertise responding for this agent yet.
    case hookSite
}

extension AgentID {
    /// Reach is a statement about the installed hook, not about capability.
    var respondReach: RespondReach {
        switch self {
        case .claude:
            return .hookSite
        default:
            return .none
        }
    }
}

/// A permission request Pulse has been told about.
///
/// `digest` is over the *complete* request text. It exists so a verdict can be
/// bound to the exact thing it answered: a decision that only carried an id
/// could be replayed onto a later request that reused it, and a decision that
/// only carried a digest could be replayed onto an identical request tomorrow.
/// Both bindings are required.
struct PermissionRequest: Equatable {
    var id: String
    var agent: AgentID
    /// Empty means this Mac.
    var host: String = ""
    var session: String = ""
    /// The complete request as the vendor stated it, or empty if it never
    /// arrived. Never abbreviated for storage — the point of holding it is
    /// that an abbreviation must not be approved.
    var fullRequest: String = ""
    /// The vendor (or the transport) gave us less than the whole thing.
    var truncated: Bool = false
    var receivedAtMs: Int64 = 0

    var digest: String { RespondDigest.of(fullRequest) }

    /// Whether an **Allow** control may be offered for this request.
    ///
    /// Deny and "go look" are always available: refusing something you have
    /// not fully read is safe, and looking is what Pulse has always done.
    /// Approving something you have not fully read is the one action that
    /// cannot be taken back, so it requires the whole request to be present.
    var canOfferAllow: Bool {
        !truncated && !fullRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum RespondDigest {
    /// Hex SHA-256 of the exact request text.
    static func of(_ text: String) -> String {
        of(Data(text.utf8))
    }

    /// Hex SHA-256 of exact bytes — the outbound spool digests the verbatim
    /// hook stdin before anything ever decodes it.
    static func of(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// A decision the user made, bound to the request it answered.
struct RespondVerdict: Equatable {
    var requestID: String
    var digest: String
    /// Which agent and which machine this verdict is for. Vendor request ids
    /// look globally unique, but nothing *guarantees* they are — and a
    /// security property must never rest on a vendor's id scheme. Without
    /// these bindings, a verdict synced back to the wrong host (or picked up
    /// by a different agent that happened to reuse the id) would answer a
    /// request the user never saw.
    var agent: String
    var host: String
    var allow: Bool
    var decidedAtMs: Int64
    var expiresAtMs: Int64

    func isUsable(nowMs: Int64) -> Bool { nowMs < expiresAtMs }

    /// All four bindings must hold. Any one alone is replayable.
    func answers(_ request: PermissionRequest) -> Bool {
        requestID == request.id && digest == request.digest
            && agent == request.agent.rawValue && host == request.host
    }
}

/// Verdicts waiting to be collected, exactly once each.
///
/// 1.0's worst case, if someone could write Pulse's inbox, was a false lamp.
/// A verdict is a different class of thing: it can cause an agent to act. So
/// this store is deliberately mean — every verdict is single-use, short-lived,
/// and bound to both the request id and the request's content.
struct RespondDecisionStore: Equatable {
    /// A verdict nobody collected is stale within a minute or two; a user who
    /// walked away should not find their approval still armed later.
    static let defaultTtlMs: Int64 = 90 * 1000
    /// A hard ceiling so a misbehaving writer cannot grow this without bound.
    static let maxPending = 64

    private(set) var pending: [RespondVerdict] = []

    /// Record a decision. Replaces any earlier verdict for the same request —
    /// the newest answer is the user's actual intent.
    mutating func decide(
        _ request: PermissionRequest,
        allow: Bool,
        nowMs: Int64,
        ttlMs: Int64 = defaultTtlMs
    ) -> RespondVerdict? {
        // Approving something Pulse could not fully show is the one thing this
        // version must never make possible, including by accident.
        if allow && !request.canOfferAllow { return nil }
        let verdict = RespondVerdict(
            requestID: request.id,
            digest: request.digest,
            agent: request.agent.rawValue,
            host: request.host,
            allow: allow,
            decidedAtMs: nowMs,
            expiresAtMs: nowMs + max(0, ttlMs)
        )
        // Replacement matches on requestID alone, deliberately. The new
        // verdict carries its own (possibly different) digest, so nothing
        // stale survives the swap — and `answers(_:)` re-checks all four
        // bindings at consumption time. Matching on digest here would only
        // let two verdicts for "the same request, different content" coexist,
        // which is exactly the ambiguity this store exists to prevent.
        pending.removeAll { $0.requestID == verdict.requestID }
        pending.append(verdict)
        if pending.count > Self.maxPending {
            pending.removeFirst(pending.count - Self.maxPending)
        }
        return verdict
    }

    /// Collect the verdict for a request, if there is a live one that actually
    /// answers it. The verdict is consumed whether or not it is used again.
    mutating func take(for request: PermissionRequest, nowMs: Int64) -> RespondVerdict? {
        prune(nowMs: nowMs)
        guard let index = pending.firstIndex(where: {
            $0.answers(request) && $0.isUsable(nowMs: nowMs)
        }) else { return nil }
        return pending.remove(at: index)
    }

    mutating func prune(nowMs: Int64) {
        pending.removeAll { !$0.isUsable(nowMs: nowMs) }
    }
}

/// Whether an agent should be made to wait for the user, or let straight
/// through to the vendor's own prompt.
///
/// The naive version of this feature holds every request so the user can
/// answer from the tray. That is a regression for the case that matters most:
/// someone whose agent now freezes for N seconds before showing the prompt
/// that was already going to appear in front of them.
///
/// 2.0 approximated "the prompt is in front of them" with **"is anyone
/// touching this Mac"**, and additionally refused to hold for a local agent at
/// all. Both were wrong in the product's own headline scene — someone in a
/// meeting, or writing a document, is touching this Mac while six terminal
/// windows sit behind a full-screen app. `isPresent` says yes; the prompt is
/// nowhere near them; and because the agent is local, Respond declined to
/// help. That combination is why the one verb change this product has ever
/// shipped was unreachable for anyone with a single Mac.
///
/// The question is now asked directly. Holding pays exactly when the user
/// **cannot already see** the prompt.
enum RespondHold {
    /// How long without input before Pulse stops assuming you are here.
    static let defaultAwayAfterSeconds: Double = 120

    /// - Parameter promptIsFrontmost: `nil` for "could not be established".
    ///   Not knowing is not proof, and the cost of a wrong hold is a frozen
    ///   agent in front of a present user — so unknown lets the request
    ///   straight through, which is exactly what 2.3 did.
    /// `promptIsFrontmost` is an autoclosure: an absent user is decided
    /// without ever asking the window server, so the common case costs
    /// nothing. Forwarding another autoclosure into it stays lazy, because
    /// `@autoclosure` captures the expression rather than its value.
    static func shouldHold(
        idleSeconds: Double,
        promptIsFrontmost: @autoclosure () -> Bool?,
        awayAfterSeconds: Double = defaultAwayAfterSeconds
    ) -> Bool {
        // Nobody is here. The prompt would appear to an empty chair, and
        // whoever comes back can answer from Pulse instead of hunting for the
        // window it appeared in. This half is 2.0's rule, unchanged.
        if idleSeconds >= awayAfterSeconds { return true }
        // Someone is here. Hold only where it can be *shown* that they are
        // looking somewhere else.
        guard let visible = promptIsFrontmost() else { return false }
        return !visible
    }
}

/// Is anyone at this Mac right now?
///
/// Ambient input age only — how long since *any* input, never what the input
/// was. No Accessibility or Input Monitoring permission is involved, and no
/// keystroke ever reaches Pulse.
enum UserPresence {
    /// Event kinds worth treating as "someone is here". The shortest age wins.
    private static let watched: [CGEventType] = [
        .keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel,
    ]

    static var idleSeconds: Double {
        watched
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min() ?? 0
    }

    static func isPresent(awayAfterSeconds: Double = RespondHold.defaultAwayAfterSeconds) -> Bool {
        idleSeconds < awayAfterSeconds
    }
}
