import Foundation

/// Respond (scene AR) — deliver the user's own decision to a permission
/// request an agent on this Mac is holding for. See docs/respond-protocol.md for the file protocol and
/// AGENTS.md for the invariant this must never cross: no judgment transfer,
/// no blind approve, and every failure falls open to the vendor's own prompt.
extension StatusStore {
    /// Match inbound full requests to rows. Called on the main thread after
    /// every applyScan with spool contents read on the scan queue.
    ///
    /// A request attaches only to a row of the same agent (and session, when
    /// both name one): a verdict must go back to the hook that is holding.
    /// - Parameter rows: **every** row this scan produced, not the windowed
    ///   `snapshot.rows`. The window is a display budget; a request whose row
    ///   fell outside it is still a request the hook is holding for.
    func refreshRespondInbound(
        _ inbound: [RespondSpool.InboundRequest],
        rows: [AgentRow]
    ) {
        let byRowKey = Self.matchRespondInbound(inbound, rows: rows)
        if byRowKey != respondInboundByRowKey {
            respondInboundByRowKey = byRowKey
        }
        // The note used to vanish the moment the request file was swept —
        // which is exactly when the receipt becomes worth reading. Keep a
        // decided row for a short while on its own clock instead.
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // 12.4: build the next value, publish only a change — every scan
        // passes through here, and an unchanged write still redraws every
        // surface observing the store.
        var decided = respondDecided.filter { nowMs - $0.value.decidedAtMs < Self.decidedNoteLifetimeMs }
        for key in decided.keys {
            decided[key]?.fate = fateOf(rowKey: key, nowMs: nowMs)
        }
        if respondDecided != decided { respondDecided = decided }
        let sent = Set(decided.keys)
        if respondVerdictSentRowKeys != sent { respondVerdictSentRowKeys = sent }
    }

    /// How long a decided row keeps saying what became of its verdict.
    /// Long enough to read on the next scan or two, short enough that a row
    /// does not carry yesterday's receipt.
    static let decidedNoteLifetimeMs: Int64 = 120 * 1000

    /// A verdict this Mac wrote, and what has become of it.
    struct DecidedVerdict: Equatable {
        var requestID: String
        var decidedAtMs: Int64
        var allow: Bool
        var fate: RespondSpool.VerdictFate = .waiting
    }

    private func fateOf(rowKey: String, nowMs: Int64) -> RespondSpool.VerdictFate {
        guard let decided = respondDecided[rowKey] else { return .unknown }
        let fate = RespondSpool.localVerdictFate(requestID: decided.requestID, nowMs: nowMs)
        // `.unknown` after a sweep is not news; keep the last real answer
        // rather than downgrading a receipt the user already earned.
        if fate == .unknown { return decided.fate }
        return fate
    }

    /// The sentence for a row whose verdict is already written.
    ///
    /// This is the whole point of 2.5: "Pulse wrote a file" and "the agent
    /// took it" are different facts, and only the second one is a receipt.
    func respondFateNote(_ row: AgentRow) -> String? {
        guard let decided = respondDecided[row.rowKey] else { return nil }
        switch decided.fate {
        case .taken: return tr(.respondTakenNote)
        case .expired: return tr(.respondExpiredUnclaimedNote)
        case .waiting, .unknown:
            return tr(.respondWaitingNote)
        }
    }

    /// Pure matcher, so the attachment rules can be pinned by tests without
    /// seeding a snapshot.
    static func matchRespondInbound(
        _ inbound: [RespondSpool.InboundRequest],
        rows: [AgentRow]
    ) -> [String: RespondSpool.InboundRequest] {
        var byRowKey: [String: RespondSpool.InboundRequest] = [:]
        for candidate in inbound {
            let request = candidate.request
            guard !request.host.isEmpty else { continue }
            let match = rows.first { row in
                guard row.agent == request.agent else { return false }
                if !request.session.isEmpty, !row.sessionID.isEmpty {
                    return row.sessionID == request.session
                }
                return true
            }
            guard let row = match else { continue }
            // Prefer the newest request when two attach to the same row.
            if let existing = byRowKey[row.rowKey],
               existing.request.receivedAtMs >= request.receivedAtMs {
                continue
            }
            byRowKey[row.rowKey] = candidate
        }
        return byRowKey
    }

    func respondRequest(for row: AgentRow) -> RespondSpool.InboundRequest? {
        respondInboundByRowKey[row.rowKey]
    }

    func respondVerdictSent(_ row: AgentRow) -> Bool {
        respondVerdictSentRowKeys.contains(row.rowKey)
    }

    /// Deny is always safe: refusing something you have not fully read cannot
    /// be regretted the way approving it can.
    func respondDeny(_ row: AgentRow, shown: RespondShown? = nil) {
        writeRespondVerdict(row, allow: false, shown: shown)
    }

    /// Deny straight off the banner, where the interruption actually arrived.
    ///
    /// Keyed by row rather than by an `AgentRow` because the notification only
    /// ever carried the key. A request that has since expired or been claimed
    /// simply finds nothing to answer, which `writeRespondVerdict` already
    /// reports honestly.
    func respondDeny(rowKey: String) {
        guard let row = allRowsForDisplay.first(where: { $0.rowKey == rowKey }) else { return }
        respondDeny(row)
    }

    /// Is there a full request attached to this row right now? Decides whether
    /// the banner is allowed to offer Deny at all.
    func canRespondFromBanner(_ row: AgentRow) -> Bool {
        respondInboundByRowKey[row.rowKey] != nil && !respondVerdictSentRowKeys.contains(row.rowKey)
    }

    /// Allow goes through the model's own gate: `decide(allow: true)` returns
    /// nil for a truncated or empty request, and this method reports failure
    /// rather than pretending.
    ///
    /// `shown` is not optional: an approval is only ever for the request the
    /// user was looking at. See `RespondShown`.
    func respondAllow(_ row: AgentRow, shown: RespondShown) {
        writeRespondVerdict(row, allow: true, shown: shown)
    }

    /// The request a verdict is about, as the button that sends it rendered it.
    ///
    /// Requests are re-matched to rows on every scan and a newer one replaces
    /// the old on the same row. Resolving the request again at click time
    /// therefore could sign one that arrived between drawing and clicking —
    /// the user read A and approved B. A verdict carries what was on screen,
    /// and one that no longer matches what is attached is refused.
    struct RespondShown: Equatable {
        var requestID: String
        var digest: String

        init(_ inbound: RespondSpool.InboundRequest) {
            requestID = inbound.request.id
            digest = inbound.request.digest
        }

        /// 19.0: as carried back by a card's click (`RowCardModel.Action`).
        init(requestID: String, digest: String) {
            self.requestID = requestID
            self.digest = digest
        }
    }

    /// Pure resolution of which request a click may answer. Nil means refuse.
    ///
    /// Allow without `shown` never resolves. Deny without `shown` (tray row,
    /// banner) may answer whatever is attached: refusing something unread is
    /// the safe move the product promises is always available.
    static func respondTarget(
        attached: RespondSpool.InboundRequest?,
        shown: RespondShown?,
        allow: Bool
    ) -> RespondSpool.InboundRequest? {
        guard let attached else { return nil }
        guard let shown else { return allow ? nil : attached }
        return RespondShown(attached) == shown ? attached : nil
    }

    /// The full request, and Allow beside it, live in the row's own Respond
    /// card (scene AR): reveal the row in the tray with its card open.
    func openRespond(_ row: AgentRow) {
        requestTrayReveal(rowKey: row.rowKey)
    }

    /// Every exit from here is visible.
    ///
    /// Refusal and a failed write used to leave through `debug.log` alone, so
    /// pressing Deny — the button this product promises is always available,
    /// because refusing something you have not fully read is the safe move —
    /// looked exactly like pressing a button that does nothing. Failure is
    /// still fail-open: the agent falls back to its own prompt, which is what
    /// the sentence says.
    private func writeRespondVerdict(_ row: AgentRow, allow: Bool, shown: RespondShown?) {
        guard let attached = respondInboundByRowKey[row.rowKey] else {
            noteRowAction(row.rowKey, tr(.respondRequestGone))
            return
        }
        guard let inbound = Self.respondTarget(attached: attached, shown: shown, allow: allow) else {
            DebugLog.write("respond refuse allow=\(allow) key=\(row.rowKey) reason=request-changed")
            noteRowAction(row.rowKey, tr(.respondRequestChanged))
            return
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var decisions = RespondDecisionStore()
        guard let verdict = decisions.decide(inbound.request, allow: allow, nowMs: nowMs) else {
            DebugLog.write("respond refuse allow=\(allow) key=\(row.rowKey) canOfferAllow=false")
            noteRowAction(row.rowKey, tr(.respondRefused))
            return
        }
        let written = RespondSpool.writeVerdict(verdict)
        DebugLog.write("respond verdict allow=\(allow) written=\(written)")
        if written {
            respondDecided[row.rowKey] = DecidedVerdict(
                requestID: verdict.requestID,
                decidedAtMs: nowMs,
                allow: allow
            )
            respondVerdictSentRowKeys.insert(row.rowKey)
        } else {
            noteRowAction(row.rowKey, tr(.respondWriteFailed))
        }
    }
}
