import Foundation

/// What a scan's Waiting rows mean for notification delivery — as a value.
///
/// Which rows qualify and whether the rate limit allows a banner now — one
/// banner per wait, never a summary: this planner is fed only
/// facts, and `WaitNotifier` carries out the plan it returns, so the rules
/// are testable without a store.
struct WaitingDelivery: Equatable {
    enum Plan: Equatable {
        /// No row qualifies.
        case nothing
        /// Rate-limited: queue these and try again after `retryAfterMs`.
        case hold([AgentRow], retryAfterMs: Int64)
        /// Post `first` now; queue `later` — at most one banner per
        /// `minimumIntervalMs`, even when one scan finds several waits.
        case post(AgentRow, later: [AgentRow])
    }
    /// Never re-arm a retry sooner than this.
    static let minimumRetryMs: Int64 = 250

    /// Row keys whose active Waiting event the user already ignored.
    var acknowledged: Set<String>
    /// Row keys Notification Center has not answered for yet.
    var inFlight: Set<String>
    /// `WaitLedger.canDeliver` for this instant.
    var canDeliverNow: Bool
    var msSinceLastNotification: Int64
    var minimumIntervalMs: Int64
    /// Row keys whose in-front hold is over (`WaitLedger.frontDueKeys`):
    /// raised while their prompt was in front, still open, app no longer
    /// in front.
    var frontDue: Set<String> = []

    func plan(_ rows: [AgentRow]) -> Plan {
        let eligible = rows.filter { row in
            row.isBlocked
                // The prompt was already in front of the user when it
                // was raised — the lamp says so; a banner and a sound would
                // only interrupt someone who is looking at it — unless
                // it is still open after `deferAfterMs` and its app has left
                // the front (`deferred`).
                && (row.wait?.inFront != true || frontDue.contains(row.rowKey))
                && !acknowledged.contains(row.rowKey)
                && !inFlight.contains(row.rowKey)
        }
        // One per row key, first wins, in the rows' order (waits first).
        var seen = Set<String>()
        let candidates = eligible.filter { seen.insert($0.rowKey).inserted }
        guard let first = candidates.first else { return .nothing }
        guard canDeliverNow else {
            return .hold(
                candidates,
                retryAfterMs: max(minimumIntervalMs - msSinceLastNotification, Self.minimumRetryMs)
            )
        }
        return .post(first, later: Array(candidates.dropFirst()))
    }

    // MARK: - The deferred banner

    /// How long a wait raised in front of the person is left to them before
    /// it may have a banner.
    static let deferAfterMs: Int64 = 30_000

    /// Waits raised while their prompt was in front that are due a second
    /// look now: still open, announced (not the launch replay's), not
    /// ignored, never bannered, and at least `deferAfterMs` old
    /// by the hook's clock (the ledger's first sight when the hook's is
    /// unknown). The caller asks whether their app is still in front and
    /// marks the ones that are not `frontDue`; they get one banner. Pure.
    static func deferred(rows: [AgentRow], ledger: WaitLedger, nowMs: Int64) -> [AgentRow] {
        rows.filter { row in
            guard let wait = row.wait, wait.inFront,
                  let open = ledger.waits[row.rowKey],
                  open.announce, !open.frontDue, !open.notified, !open.dismissed
            else { return false }
            let since = wait.sinceMs > 0 ? wait.sinceMs : open.seenMs
            return since > 0 && nowMs - since >= deferAfterMs
        }
    }
}

/// One "needs you" banner's words, as a value: who and where in the title
/// (`Claude · Pulse`), the session's task in the subtitle, and in the body
/// what it asks (`Permission · Bash: npm run build`). Each session is its own
/// thread in Notification Center, so a second ask from the same session
/// stacks with its first and never with another session's. Pure.
struct WaitingBanner: Equatable {
    var title: String
    var subtitle: String
    var body: String
    var threadID: String

    /// Notification Center's group for one session's banners.
    static func thread(rowKey: String) -> String { "pulse.waiting." + rowKey }

    static func make(_ row: AgentRow, lang: ResolvedLanguage) -> WaitingBanner {
        let project = TitleHeuristics.shortProject(row.project.isEmpty ? row.cwd : row.project)
        let title = project.isEmpty ? row.agent.displayName : "\(row.agent.displayName) · \(project)"
        let task = row.usefulTask.map { clip($0) } ?? ""
        return WaitingBanner(title: title, subtitle: task, body: body(row, lang: lang), threadID: thread(rowKey: row.rowKey))
    }

    /// `Permission · Approve shell command` — the reason and the ask; the
    /// reason alone when the agent did not say.
    static func body(_ row: AgentRow, lang: ResolvedLanguage) -> String {
        let kind = row.wait?.kind ?? ""
        var bits = [kind.isEmpty ? L10n.t(.needsYou, lang) : L10n.waitKind(kind, lang)]
        let ask = (row.wait?.ask ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !ask.isEmpty { bits.append(clip(ask)) }
        return bits.joined(separator: " · ")
    }

    private static func clip(_ text: String) -> String {
        text.count > 120 ? String(text.prefix(119)) + "…" : text
    }
}
